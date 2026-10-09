import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/draft_guard.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/member_policy.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/permission_ui.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/role_editor.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_editor.dart';
import 'package:ieum_flutter/team_panel.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_oauth_test.dart' show MemoryVault;
import 'project_test.dart' show member, task;
import 'v020_store_test.dart' show legacyFourStages;

const config = GitHubConfig(repository: 'team/data', enabled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AutoMergeApi api;
  late GitHubSession session;
  late ProjectManifest project;
  Future<void> persist(ProjectManifest next) async {
    final file = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      next.json,
      sha: file!['sha'],
      message: 'isolated test fixture',
    );
    project = next.partWorkflowView;
  }

  setUp(() async {
    api = AutoMergeApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn(token: 'mock-only');
    project = await session.createProject(config, 'UIUX 테스트', '관리자');
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    await persist(
      ProjectManifest.fromJson({
        ...project.json,
        'workflowStages': legacyFourStages.map((s) => s.json).toList(),
        'workflowSheet': WorkflowSheet.defaultFor([
          'todo',
          'doing',
          'review',
          'done',
        ]).json,
        'members': [
          ...project.people.map((p) => p.json),
          member(2, 'unassigned').json,
          {...member(3, 'unassigned').json, 'parts': <String>[]},
        ],
      }),
    );
  });
  tearDown(() => session.signOut());

  test('legacy disabled and pending have no inferred role; filters are independent and stable', () {
    final old = Person.fromJson(
      {...member(4, 'disabled').json}..remove('assignedRole'),
    );
    expect(memberRoleLabel(old), '이전 역할 정보 없음');
    expect(memberRoleLabel(member(5, 'pending')), '미배정');
    expect(memberState(old), 'disabled');
    final people = [member(3, 'viewer'), member(2, 'worker'), old];
    expect(
      filterMembers(
        people,
        query: '  GUEST  ',
        role: 'worker',
        state: 'active',
        part: '기획',
      ).single.id,
      'gh-2',
    );
    expect(filterMembers(people, role: 'viewer', state: 'disabled'), isEmpty);
    expect(filterMembers(people).map((p) => p.id), ['gh-2', 'gh-3', 'gh-4']);
    expect(
      canAssignMember(
        project.people.first,
        project.people.first,
        project.ownerId,
      ),
      isTrue,
    );
    expect(
      canAssignMember(
        member(3, 'viewer'),
        member(2, 'worker'),
        project.ownerId,
      ),
      isFalse,
    );
  });

  test('manual import requires trust and active membership while automatic read-only pull remains valid', () {
    final inactiveProject = ProjectManifest.fromJson({
      ...project.json,
      'members': [
        for (final p in project.people)
          {...p.json, if (p.id == 'gh-3') 'enabled': false},
      ],
    });
    final inactive = TaskStore(
      ':memory:',
      project: inactiveProject,
      identity: member(3, 'unassigned'),
    );
    final owner = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    addTearDown(() {
      inactive.dispose();
      owner.dispose();
    });
    final snapshot = {
      'schemaVersion': 1,
      'projectId': project.id,
      'revision': 'main-test',
      'tasks': [],
    };
    expect(
      () => inactive.importManualSnapshot(snapshot, trusted: true),
      throwsStateError,
    );
    expect(
      () => owner.importManualSnapshot(snapshot, trusted: false),
      throwsStateError,
    );
    expect(inactive.importSnapshot(snapshot).applied, isTrue);
    expect(owner.importManualSnapshot(snapshot, trusted: true).applied, isTrue);
    expect(
      () => owner.importManualSnapshot({
        ...snapshot,
        'projectId': 'other',
      }, trusted: true),
      throwsStateError,
    );
  });

  test('stale target/project and revoked actor cannot change roles; no remote writes', () async {
    final base = project.people[1];
    await persist(
      ProjectManifest.fromJson({
        ...project.json,
        'members': [
          for (final p in project.people)
            {...p.json, if (p.id == base.id) 'name': '원격 새 이름'},
        ],
      }),
    );
    final writes = api.writes;
    await expectLater(
      session.assign(
        config,
        member(2, 'viewer'),
        expectedProjectId: project.id,
        expectedMember: base,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.assign(
        config,
        member(2, 'viewer'),
        expectedProjectId: 'another-project',
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    api.identityId = 2;
    api.identityLogin = 'guest';
    await session.signIn(token: 'mock-only');
    await expectLater(
      session.assign(config, member(3, 'worker')),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
  });

  test('part draft detects a remote rename and cannot overwrite the latest definition', () async {
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-qa', 'QA', {}),
    );
    final before = project.roles.singleWhere((r) => r.id == 'role-qa');
    await session.savePermissionPart(
      config,
      const ProjectRole('role-qa', 'QA 최신', {}),
      expectedPart: before,
    );
    final writes = api.writes;
    await expectLater(
      session.savePermissionPart(
        config,
        const ProjectRole('role-qa', '초안', {}),
        expectedPart: before,
        expectedProjectId: project.id,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
  });

  test('deactivation checks current work and configured recipients through both status and assignment APIs', () async {
    final base = project.workflowSheet!;
    project = await session.saveWorkflowSheet(
      config,
      WorkflowSheet(
        nodes: base.nodes,
        routes: [
          for (final r in base.routes)
            WorkflowSheetRoute(
              id: r.id,
              from: r.from,
              to: r.to,
              action: r.action,
              person: r.id == 'default-next-0' ? 'gh-2' : '',
            ),
        ],
      ),
      expectedSheet: base,
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    addTearDown(store.dispose);
    var created = store.save(
      task(member(2, 'unassigned'), project.people.first),
    );
    store.transition(created.id, 'doing', expectedVersion: created.version);
    created = store.find(created.id);
    api.addMainProposal(store.exportChanges(), created.id);
    final writes = api.writes;
    await expectLater(
      session.setMemberEnabled(config, 'gh-2', false),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.assign(
        config,
        Person.fromJson({
          ...project.people.firstWhere((p) => p.id == 'gh-2').json,
          'enabled': false,
        }),
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    store.transition(created.id, 'review', expectedVersion: created.version);
    store.transition(
      created.id,
      'done',
      expectedVersion: store.find(created.id).version,
    );
    api.addMainProposal(store.exportChanges(), created.id);
    project = await session.saveWorkflowSheet(
      config,
      WorkflowSheet.defaultFor(
        project.workflowStages.map((s) => s.id).toList(),
      ),
      expectedSheet: project.workflowSheet,
    );
    final next = await session.setMemberEnabled(config, 'gh-2', false);
    expect(next.people.firstWhere((p) => p.id == 'gh-2').enabled, isFalse);
  });

  test('administrator recovery transfers current processing before participant deactivation', () async {
    final base = project.workflowSheet!;
    project = await session.saveWorkflowSheet(
      config,
      WorkflowSheet(
        nodes: base.nodes,
        routes: [
          for (final r in base.routes)
            WorkflowSheetRoute(
              id: r.id,
              from: r.from,
              to: r.to,
              action: r.action,
              person: r.id == 'default-next-0' ? 'gh-2' : '',
            ),
        ],
      ),
      expectedSheet: base,
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    addTearDown(store.dispose);
    final created = store.save(
      task(member(2, 'unassigned'), project.people.first),
    );
    store.transition(created.id, 'doing', expectedVersion: created.version);
    api.addMainProposal(store.exportChanges(), created.id);
    await expectLater(
      session.setMemberEnabled(config, 'gh-2', false),
      throwsA(isA<GitHubFailure>()),
    );
    store.recoverTask(
      created.id,
      stageId: 'todo',
      personId: project.ownerId,
      expectedVersion: store.find(created.id).version,
    );
    api.addMainProposal(store.exportChanges(), created.id);
    project = await session.saveWorkflowSheet(
      config,
      WorkflowSheet.defaultFor(
        project.workflowStages.map((s) => s.id).toList(),
      ),
      expectedSheet: project.workflowSheet,
    );
    final next = await session.setMemberEnabled(config, 'gh-2', false);
    expect(next.people.firstWhere((p) => p.id == 'gh-2').active, isFalse);
    expect(store.find(created.id).workflowPerson, project.ownerId);
    expect(store.find(created.id).status, 'todo');
  });

  test(
    'part deletion refuses a changed definition and a cross-project target',
    () async {
      const part = ProjectRole('role-review', '검토', {});
      project = await session.savePermissionPart(config, part);
      final before = project.roles.singleWhere((r) => r.id == part.id);
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-review', '검토 최신', {}),
        expectedPart: before,
      );
      final writes = api.writes;
      await expectLater(
        session.deletePermissionPart(
          config,
          part.id,
          expectedPart: before,
          expectedProjectId: project.id,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.deletePermissionPart(
          config,
          part.id,
          expectedProjectId: 'other',
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
      expect(
        (await session.loadProject(config)).roles
            .singleWhere((r) => r.id == part.id)
            .name,
        '검토 최신',
      );
    },
  );

  test('legacy inactive activation requires explicit role; owner protection remains', () async {
    await persist(
      ProjectManifest.fromJson({
        ...project.json,
        'members': [project.people.first.json, member(2, 'disabled').json],
      }),
    );
    await expectLater(
      session.setMemberEnabled(config, 'gh-2', true),
      throwsA(isA<GitHubFailure>()),
    );
    final next = await session.assign(config, member(2, 'unassigned'));
    expect(next.people.where((p) => p.id == 'gh-2').single.active, isTrue);
    await expectLater(
      session.setMemberEnabled(config, project.ownerId, false),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test(
    'existing registration request can be rejected only in its own project',
    () async {
      api.identityId = 4;
      api.identityLogin = 'newcomer';
      await session.signIn(token: 'mock-only');
      await session.register(config, project, '가입 요청자');
      api.identityId = 1;
      api.identityLogin = 'tester';
      await session.signIn(token: 'mock-only');
      final request = (await session.requests(config)).single;
      await expectLater(
        session.rejectRequest(config, request, expectedProjectId: 'other'),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.prs.last['state'], 'open');
      await session.rejectRequest(
        config,
        request,
        expectedProjectId: project.id,
      );
      expect(api.prs.last['state'], 'closed');
      await expectLater(
        session.rejectRequest(config, request, expectedProjectId: project.id),
        throwsA(isA<GitHubFailure>()),
      );
    },
  );

  testWidgets(
    'role save failure keeps draft, prevents double submit and guards Escape/discard',
    (tester) async {
      Completer<void>? waiting;
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showProjectRoleDialog(
                ctx,
                project.people.first,
                onSave: (_) async {
                  calls++;
                  waiting = Completer<void>();
                  await waiting!.future;
                },
              ),
              child: const Text('편집'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('편집'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), '보존할 초안');
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-role')))
            .onPressed,
        isNull,
      );
      waiting!.completeError(StateError('mock offline'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('role-name')))
            .controller!
            .text,
        '보존할 초안',
      );
      expect(find.textContaining('mock offline'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('변경 버리기'), findsOneWidget);
      await tester.tap(find.text('계속 편집'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pump();
      waiting!.complete();
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byKey(const Key('role-name')), findsNothing);
    },
  );

  testWidgets(
    'native window close preserves draft on continue and destroys only after discard',
    (tester) async {
      var destroyed = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            if (call.method == 'destroy') destroyed++;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('window_manager'),
              null,
            ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showProjectRoleDialog(
                ctx,
                project.people.first,
                onSave: (_) async => throw StateError('mock native offline'),
              ),
              child: const Text('편집'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('편집'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), '종료 보호 초안');
      await tester.pump();
      final dynamic guard = tester.state(find.byType(DraftGuard));
      guard.onWindowClose();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '저장').last);
      await tester.pumpAndSettle();
      expect(destroyed, 0);
      expect(find.textContaining('mock native offline'), findsOneWidget);
      guard.onWindowClose();
      await tester.pumpAndSettle();
      await tester.tap(find.text('계속 편집'));
      await tester.pumpAndSettle();
      expect(destroyed, 0);
      expect(find.byKey(const Key('role-name')), findsOneWidget);
      guard.onWindowClose();
      await tester.pumpAndSettle();
      await tester.tap(find.text('변경 버리기'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      expect(destroyed, 1);
      expect(find.byKey(const Key('role-name')), findsNothing);
    },
  );

  testWidgets(
    'member confirmation cannot be duplicated and cancellation leaves draft retryable',
    (tester) async {
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-plan', '기획', {}),
      );
      project = await session.assign(
        config,
        Person.fromJson({
          ...project.people.firstWhere((p) => p.id == 'gh-2').json,
          'parts': <String>[],
        }),
      );
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      addTearDown(() {
        sync.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TeamPanel(store: store, sync: sync, session: session),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('member-actions-gh-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('파트 배정'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('member-part-기획')));
      await tester.tap(find.byKey(const Key('member-part-기획')));
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('save-member')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('참여자 설정 변경'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '취소').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-member')))
            .onPressed,
        isNotNull,
      );
      expect(store.member('gh-2').role, 'unassigned');
      expect(store.member('gh-2').parts, isEmpty);
      await tester.tap(find.byKey(const Key('save-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await tester.pumpAndSettle();
      expect(store.member('gh-2').role, 'unassigned');
      expect(store.member('gh-2').parts, ['기획']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Tab, Shift+Tab and Space reach and change a permitted checkbox',
    (tester) async {
      final permissions = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (ctx, update) => Scaffold(
              body: SingleChildScrollView(
                child: RolePermissionGroups(
                  permissions: permissions,
                  actor: project.people.first,
                  onChanged: (id, value) => update(() {
                    if (value) {
                      permissions.add(id);
                    } else {
                      permissions.remove(id);
                    }
                  }),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(permissions, {'member.manage'});
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(permissions, {'member.manage', 'role.manage'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(permissions, {'role.manage'});
    },
  );

  testWidgets(
    'task editor unsaved exit supports continue, discard and saving',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      addTearDown(store.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => TaskEditor(store: store),
              ),
              child: const Text('새 작업'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('새 작업'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('task-title')), '유실 방지');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('계속 편집'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('task-title')))
            .controller!
            .text,
        '유실 방지',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();
      expect(store.tasks.single.title, '유실 방지');
      await tester.tap(find.text('새 작업'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('task-title')), '버릴 초안');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('변경 버리기'));
      await tester.pumpAndSettle();
      expect(store.tasks.length, 1);
      expect(find.byKey(const Key('task-title')), findsNothing);
    },
  );

  testWidgets(
    'management summary is read-only and settings navigation has separate scopes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RolePermissionGroups(permissions: {'member.manage'}),
            ),
          ),
        ),
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byKey(const Key('permission-search')), findsNothing);
      expect(find.text('참여자 관리'), findsOneWidget);
      expect(find.text('역할 관리'), findsOneWidget);
      expect(find.byKey(const Key('permission-task.work')), findsNothing);
      expect(find.byKey(const Key('permission-task.integrate')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsShell(
            personal: true,
            selected: SettingsSection.general,
            onSelected: (_) {},
            contentBuilder: (_) => const Text('계정 정보'),
          ),
        ),
      );
      expect(find.byKey(const Key('settings-team')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsShell(
            personal: false,
            projectName: '프로젝트 A',
            selected: SettingsSection.team,
            onSelected: (_) {},
            contentBuilder: (_) => const Text('구성원'),
          ),
        ),
      );
      expect(find.byKey(const Key('settings-general')), findsNothing);
      expect(find.text('프로젝트 A · 프로젝트 설정'), findsOneWidget);
    },
  );

  testWidgets(
    'participants layouts, keyboard detail/focus return, related tasks and empty filter results',
    (tester) async {
      await persist(
        ProjectManifest.fromJson({
          ...project.json,
          'members': [
            project.people.first.json,
            {
              ...member(2, 'unassigned').json,
              'name': '아주 긴 이름을 쓰는 참여자와 프로젝트 역할 배정 검증용 이름',
            },
            {...member(3, 'unassigned').json, 'login': 'viewer-account'},
          ],
        }),
      );
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      store.setMeta('github.login', 'tester');
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      addTearDown(() {
        sync.dispose();
        store.dispose();
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      if (Platform.environment['IEUM_CAPTURE_UIUX'] == '1') {
        for (final font in [
          ('Malgun Gothic', 'C:/Windows/Fonts/malgun.ttf'),
          (
            'MaterialIcons',
            'C:/Users/devbin0318/develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ]) {
          final loader = FontLoader(font.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(font.$2).readAsBytesSync()),
              ),
            );
          await tester.runAsync(loader.load);
        }
      }
      String related = '';
      final boundary = GlobalKey();
      Future<void> render(Size size, double scale) async {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              fontFamily: 'Malgun Gothic',
              scaffoldBackgroundColor: Colors.white,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: RepaintBoundary(
                  key: boundary,
                  child: ColoredBox(
                    color: Colors.white,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: TeamPanel(
                        store: store,
                        sync: sync,
                        session: session,
                        onOpenTasks: (id) => related = id,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('참여자 목록을 새로고침하지 못했습니다.'), findsNothing);
      }

      for (final size in [
        const Size(1440, 900),
        const Size(1280, 800),
        const Size(1024, 800),
        const Size(480, 420),
      ]) {
        await render(size, size.width == 480 ? 1.4 : 1);
        await tester.ensureVisible(find.byKey(const Key('participant-gh-2')));
        final row = tester.widget<ListTile>(
          find.byKey(const Key('participant-gh-2')),
        );
        row.focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('관련 작업 0건'), findsOneWidget);
        if (size.width >= 1024) {
          if (Platform.environment['IEUM_CAPTURE_UIUX'] == '1') {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                '../.local/uiux-qa/participants-${size.width.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.tap(find.byKey(const Key('close-participant-detail')));
          await tester.pump();
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        expect(row.focusNode!.hasFocus, isTrue);
      }
      await render(const Size(1024, 800), 1.3);
      await tester.enterText(
        find.byKey(const Key('participant-search')),
        '  GUEST ',
      );
      await tester.pump();
      expect(find.byKey(const Key('participant-gh-1')), findsNothing);
      await tester.tap(find.byKey(const Key('participant-gh-2')));
      await tester.pump();
      await tester.ensureVisible(find.text('관련 작업 보기'));
      await tester.tap(find.text('관련 작업 보기'));
      await tester.pump();
      expect(related, 'gh-2');
      await tester.enterText(
        find.byKey(const Key('participant-search')),
        '없는참여자',
      );
      await tester.pump();
      expect(find.byKey(const Key('close-participant-detail')), findsNothing);
      expect(find.textContaining('검색 결과가 없습니다.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('participant-filter-reset')));
      await tester.pump();
      expect(find.byKey(const Key('participant-gh-1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
