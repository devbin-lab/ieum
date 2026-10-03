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
    project = next;
  }

  setUp(() async {
    api = AutoMergeApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn(token: 'mock-only');
    project = await session.createProject(config, 'UIUX 테스트', '관리자');
    await persist(
      ProjectManifest(project.id, project.name, project.ownerId, [
        ...project.people,
        member(2, 'worker'),
        member(3, 'viewer'),
      ]),
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
      isFalse,
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

  test('manual import requires trust and mutation rights while automatic read-only pull remains valid', () {
    final viewer = TaskStore(
      ':memory:',
      project: project,
      identity: member(3, 'viewer'),
    );
    final owner = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    addTearDown(() {
      viewer.dispose();
      owner.dispose();
    });
    final snapshot = {
      'schemaVersion': 1,
      'projectId': project.id,
      'revision': 'main-test',
      'tasks': [],
    };
    expect(
      () => viewer.importManualSnapshot(snapshot, trusted: true),
      throwsStateError,
    );
    expect(
      () => owner.importManualSnapshot(snapshot, trusted: false),
      throwsStateError,
    );
    expect(viewer.importSnapshot(snapshot).applied, isTrue);
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

  test('role draft detects remote edits and cannot overwrite a changed permission set', () async {
    const before = ProjectRole('role-qa', 'QA', {'task.review'});
    await session.saveRole(config, before);
    await session.saveRole(
      config,
      const ProjectRole('role-qa', 'QA 최신', {'task.work'}),
    );
    final writes = api.writes;
    await expectLater(
      session.saveRole(
        config,
        const ProjectRole('role-qa', '초안', {'task.review'}),
        expectedRole: before,
        expectedProjectId: project.id,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
  });

  test('deactivation checks unfinished work on both status and role-assignment routes', () async {
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    addTearDown(store.dispose);
    final created = store.save(task(member(2, 'worker'), project.people.first));
    api.addMainProposal(store.exportChanges(), created.id);
    final writes = api.writes;
    await expectLater(
      session.setMemberEnabled(config, 'gh-2', false),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.assign(
        config,
        Person.fromJson({...member(2, 'worker').json, 'enabled': false}),
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    api.addMainProposal({
      ...store.exportChanges(),
      'changes': [
        {
          ...store.changes.single,
          'task': {
            ...created.data,
            'status': 'done',
            'completedDate': '2026-10-03',
          },
        },
      ],
    }, created.id);
    final next = await session.setMemberEnabled(config, 'gh-2', false);
    expect(next.people[1].enabled, isFalse);
  });

  test('unfinished-work handoff permits deactivation without changing completed work', () async {
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    addTearDown(store.dispose);
    final created = store.save(task(member(2, 'worker'), project.people.first));
    api.addMainProposal(store.exportChanges(), created.id);
    await expectLater(
      session.setMemberEnabled(config, 'gh-2', false),
      throwsA(isA<GitHubFailure>()),
    );
    store.save({
      ...created.data,
      'assigneeId': project.ownerId,
    }, expectedVersion: created.version);
    api.addMainProposal(store.exportChanges(), created.id);
    final next = await session.setMemberEnabled(config, 'gh-2', false);
    expect(next.people.firstWhere((p) => p.id == 'gh-2').active, isFalse);
    expect(store.find(created.id).assigneeId, project.ownerId);
    expect(store.find(created.id).status, 'todo');
  });

  test(
    'role deletion refuses changed assignment and cross-project targets',
    () async {
      const role = ProjectRole('role-review', '검토', {'task.review'});
      project = await session.saveRole(config, role);
      final expected = project.people.where((p) => p.role == role.id).toList();
      project = await session.assign(config, member(2, role.id));
      final writes = api.writes;
      await expectLater(
        session.deleteRole(
          config,
          role.id,
          replacementRoleId: 'worker',
          expectedRole: role,
          expectedMembers: expected,
          expectedProjectId: project.id,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.deleteRole(
          config,
          role.id,
          replacementRoleId: 'worker',
          expectedProjectId: 'other',
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
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
    final next = await session.assign(config, member(2, 'worker'));
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
      await tester.tap(find.text('역할 변경'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('member-role-viewer')));
      await tester.tap(find.byKey(const Key('member-role-viewer')));
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('save-member')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('역할·상태 변경 확인'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '취소').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-member')))
            .onPressed,
        isNotNull,
      );
      expect(store.member('gh-2').role, 'worker');
      await tester.tap(find.byKey(const Key('save-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await tester.pumpAndSettle();
      expect(store.member('gh-2').role, 'viewer');
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
      await tester.enterText(
        find.byKey(const Key('permission-search')),
        '새 작업',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('permission-search')));
      await tester.pump();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(field.focusNode.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(permissions, {'task.create'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(field.focusNode.hasFocus, isTrue);
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
    'permission search is read-only and settings navigation has separate scopes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RolePermissionGroups(permissions: {'task.work'}),
            ),
          ),
        ),
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.enterText(
        find.byKey(const Key('permission-search')),
        '본인 담당',
      );
      await tester.pump();
      expect(find.text(permissionLabels['task.work']!), findsOneWidget);
      expect(find.text(permissionLabels['member.manage']!), findsNothing);
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
      expect(find.text('프로젝트 A · 이 프로젝트에만 적용'), findsOneWidget);
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
              ...member(2, 'worker').json,
              'name': '아주 긴 이름을 쓰는 참여자와 프로젝트 역할 배정 검증용 이름',
            },
            {...member(3, 'viewer').json, 'login': 'viewer-account'},
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
        expect(find.textContaining('목록 새로고침 실패'), findsNothing);
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
        expect(find.text('관련 업무 0건'), findsOneWidget);
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
      await tester.tap(find.text('관련 업무 보기'));
      await tester.pump();
      expect(related, 'gh-2');
      await tester.enterText(
        find.byKey(const Key('participant-search')),
        '없는참여자',
      );
      await tester.pump();
      expect(find.textContaining('상세를 닫았습니다'), findsOneWidget);
      expect(find.textContaining('검색 결과가 없습니다.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('participant-filter-reset')));
      await tester.pump();
      expect(find.byKey(const Key('participant-gh-1')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
