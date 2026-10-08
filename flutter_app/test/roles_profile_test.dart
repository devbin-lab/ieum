import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/app_update.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/profile_service.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/roles_panel.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/update_ui.dart';

import 'github_sync_test.dart' show FakeGitHubApi, idle;
import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'project_test.dart' show member, task;
import 'github_oauth_test.dart' show MemoryVault;

import 'package:ieum_flutter/github_oauth.dart';

import 'app_update_test.dart' show FakeUpdates;
import 'v020_store_test.dart' show legacyFourStages;

const config = GitHubConfig(repository: 'team/data', enabled: true);
const reviewerRole = ProjectRole('role-reviewer', '검토 전담', {'task.review'});

class RacingApi extends FakeGitHubApi {
  bool race = false;
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (race && method == 'PUT' && path.endsWith('.ieum/project.json')) {
      race = false;
      final file = files['main']!['.ieum/project.json']!;
      final data =
          jsonDecode(utf8.decode(base64Decode(file['content']))) as Map;
      data['name'] = '동시에 바뀐 프로젝트 이름';
      file['content'] = base64Encode(utf8.encode(jsonEncode(data)));
      file['sha'] = 'concurrent-sha';
    }
    return super.call(method, path, query: query, body: body);
  }
}

class MultiProjectApi implements GitHubApi {
  final first = FakeGitHubApi(), second = FakeGitHubApi();
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) => (path.startsWith('/repos/team/second') ? second : first).call(
    method,
    path.replaceFirst('/repos/team/second', '/repos/team/data'),
    query: query,
    body: body,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GitHubSession sessionFor(GitHubApi api) => GitHubSession(
    api: api,
    oauth: GitHubOAuth(vault: MemoryVault()),
  );
  Future<void> write(GitHubSession session, ProjectManifest project) async {
    final existing = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      project.json,
      sha: existing?['sha'],
      message: 'fixture',
    );
  }

  ProjectManifest withGuest(
    ProjectManifest project, {
    String role = 'worker',
    List<ProjectRole> roles = const [],
  }) => ProjectManifest(
    project.id,
    project.name,
    project.ownerId,
    [
      ...project.people,
      Person.fromJson({
        ...member(
          2,
          const {'pending', 'disabled'}.contains(role) ? role : 'unassigned',
        ).json,
        'parts': [
          if (project.parts.contains('기획')) '기획',
          for (final part in roles)
            if (part.id == role && project.parts.contains(part.name)) part.name,
        ],
      }),
    ],
    roles: roles,
    parts: project.parts,
    unifiedParts: project.unifiedParts,
    workflowSheet: project.workflowSheet,
    workflowStages: project.workflowStages,
    workflowAutomation: project.workflowAutomation,
  );

  test('legacy fine grants and review do not restrict shared work while completion locks content', () {
    final project = ProjectManifest(
      'p',
      '팀',
      'gh-1',
      [member(1, 'owner'), member(2, reviewerRole.id)],
      roles: [reviewerRole],
      parts: const ['기획'],
      workflowAutomation: const WorkflowAutomation(reviewEnabled: true),
      workflowStages: legacyFourStages,
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: member(1, 'owner'),
    );
    addTearDown(store.dispose);
    final created = store.save(
      task(member(1, 'owner'), member(2, reviewerRole.id)),
    );
    store.setMeta('profile', 'gh-2');
    expect(store.actor.parts, containsAll(['검토 전담', '기획']));
    expect(store.actor.role, 'unassigned');
    expect(store.canCreate, isTrue);
    expect(store.canEditContent(created), isTrue);
    expect(store.actor.has('role.manage'), isFalse);
    expect(store.actor.has('member.manage'), isFalse);
    store.transition(
      created.id,
      'doing',
      expectedVersion: store.find(created.id).version,
    );
    store.transition(
      created.id,
      'review',
      expectedVersion: store.find(created.id).version,
    );
    store.setMeta('profile', 'gh-2');
    expect(store.canEditContent(store.find(created.id)), isTrue);
    store.transition(
      created.id,
      'done',
      expectedVersion: store.find(created.id).version,
    );
    expect(store.canEdit(store.find(created.id)), isFalse);
    store.setMeta('profile', 'gh-1');
    expect(store.canEdit(store.find(created.id)), isFalse);
  });

  test('same active member may work and review independently of historical fine grants', () {
    const onlyWork = ProjectRole('role-work', '진행 전담', {'task.work'});
    final project = ProjectManifest(
      'p',
      '팀',
      'gh-1',
      [member(1, 'owner'), member(2, onlyWork.id)],
      roles: [onlyWork],
      parts: const ['기획'],
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: member(1, 'owner'),
    );
    addTearDown(store.dispose);
    final saved = store.save(
      task(member(2, onlyWork.id), member(2, onlyWork.id)),
    );
    expect(saved.assigneeId, saved.reviewerId);
    expect(store.member('gh-2').canWork, isTrue);
    expect(store.member('gh-2').canReview, isTrue);
    expect(store.member('gh-2').has('role.manage'), isFalse);
  });

  test('role definitions round-trip without trusting standalone member permissions', () {
    final project = ProjectManifest(
      'p',
      '팀',
      'gh-1',
      [member(1, 'owner'), member(2, reviewerRole.id)],
      roles: [reviewerRole],
    );
    final restored = ProjectManifest.fromJson(project.json);
    expect(restored.people.last.canReview, isTrue);
    expect(restored.people.last.canWork, isFalse);
    expect(
      Person.fromJson({
        ...restored.people.last.json,
        'permissions': permissionLabels.keys.toList(),
      }).active,
      isFalse,
    );
    expect(
      () => ProjectManifest.fromJson({...project.json, 'roles': []}),
      throwsStateError,
    );
    expect(
      () => ProjectRole.fromJson({
        ...reviewerRole.json,
        'permissions': ['unknown'],
      }),
      throwsStateError,
    );
  });

  test('explicit management grants delegate part operations without owner promotion', () async {
    final api = FakeGitHubApi();
    final session = sessionFor(api);
    addTearDown(session.signOut);
    await session.signIn();
    var project = await session.createProject(config, '팀', '개설자');
    const delegate = ProjectRole('role-delegate', '역할 설계자', {
      'role.manage',
      'member.manage',
      'task.review',
    });
    project = await session.savePermissionPart(config, delegate);
    project = await session.savePermissionPart(config, reviewerRole);
    await write(
      session,
      withGuest(project, role: delegate.id, roles: project.roles),
    );
    api.identityId = 2;
    api.identityLogin = 'guest';
    await session.signIn();
    final actor = (await session.loadProject(config)).people.last;
    expect(actor.has('role.manage'), isTrue);
    expect(actor.has('member.manage'), isTrue);
    expect(actor.role, 'unassigned');
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-second', '추가 검토', {'task.review'}),
    );
    expect(project.roles.last.permissions, isEmpty);
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-admin', '관리자 사칭', {'task.create'}),
    );
    expect(project.roles.last.permissions, isEmpty);
    expect(project.ownerId, 'gh-1');
    await expectLater(
      session.assign(config, member(2, 'manager')),
      throwsA(isA<GitHubFailure>()),
    );
    await session.deletePermissionPart(config, delegate.id);
    await expectLater(
      session.savePermissionPart(config, delegate),
      throwsA(isA<GitHubFailure>()),
    );
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.signIn();
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-second', '추가 검토', {'member.manage'}),
    );
    expect(project.roles.last.permissions, {'member.manage'});
    await session.deletePermissionPart(config, 'role-second');
    expect(
      (await session.loadProject(config)).roles
          .any((r) => r.id == 'role-second'),
      isFalse,
    );
  });

  test(
    'part assignment preserves identity and queued work blocks deactivation',
    () async {
      final api = FakeGitHubApi();
      final session = sessionFor(api);
      addTearDown(session.signOut);
      await session.signIn();
      var project = await session.createProject(config, '팀', '개설자');
      project = await session.savePermissionPart(config, reviewerRole);
      await write(session, withGuest(project, roles: project.roles));
      final original = (await session.loadProject(config)).people.last;
      final assigned = await session.assign(
        config,
        Person.fromJson({
          ...original.json,
          'parts': [reviewerRole.name],
        }),
        expectedMember: original,
      );
      expect(assigned.roles.single.id, reviewerRole.id);
      expect(assigned.people.last.parts, [reviewerRole.name]);
      expect(assigned.people.last.name, original.name);
      expect(assigned.people.last.id, original.id);
      // PR ownership alone is enough to block loss of workflow rights.
      api.prs.add({
        'number': 1,
        'state': 'open',
        'base': {'ref': 'main'},
        'head': {'ref': 'ieum/tasks/guest/TASK-1'},
        'user': {'id': 2},
      });
      await expectLater(
        session.setMemberEnabled(config, original.id, false),
        throwsA(isA<GitHubFailure>()),
      );
      api.prs.clear();
      final inactive = await session.setMemberEnabled(
        config,
        original.id,
        false,
      );
      expect(inactive.people.last.enabled, isFalse);
      expect(inactive.people.last.parts, [reviewerRole.name]);
    },
  );

  test('rename retries SHA races and preserves identity, role, parts and other edits', () async {
    final api = RacingApi();
    final session = sessionFor(api);
    addTearDown(session.signOut);
    await session.signIn();
    var project = await session.createProject(config, '팀', '개설자');
    await write(session, withGuest(project));
    final branch = session.branchFor(project.people.first);
    await session.ensureBranch(config, branch);
    final originalRefs = api.refs.keys.toSet();
    api.race = true;
    project = await session.rename(
      config,
      '바뀐 이름',
      expectedProjectId: project.id,
    );
    expect(project.name, '동시에 바뀐 프로젝트 이름');
    expect(project.people.first.name, '바뀐 이름');
    expect(project.people.first.id, 'gh-1');
    expect(project.people.first.role, 'owner');
    expect(project.people.first.parts, isEmpty);
    expect(project.people.last.name, '참여자');
    expect(api.refs.keys.toSet(), originalRefs);
    await expectLater(
      session.rename(config, '다른 프로젝트', expectedProjectId: 'wrong'),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test('profile rename commits to every saved project and persists only failed targets', () async {
    final api = MultiProjectApi();
    final session = sessionFor(api);
    final directory = Directory.systemTemp.createTempSync('ieum-profile-');
    addTearDown(() {
      session.signOut();
      directory.deleteSync(recursive: true);
    });
    await session.signIn();
    const second = GitHubConfig(repository: 'team/second', enabled: true);
    final a = await session.createProject(config, '첫 프로젝트', '개설자');
    final b = await session.createProject(second, '다음 프로젝트', '개설자');
    final file = File('${directory.path}/catalog.json');
    final catalog = ProjectCatalog(file);
    for (final (project, cfg) in [(a, config), (b, second)]) {
      catalog.remember(
        'gh-1',
        SavedProject(
          path: '${directory.path}/${project.id}.sqlite',
          name: project.name,
          projectId: project.id,
          config: cfg,
        ),
      );
    }
    api.second.failWrite = true;
    final notice = await renameParticipatingProjects(catalog, session, '공통 이름');
    expect(notice, contains('전송 대기'));
    expect((await session.loadProject(config)).people.first.name, '공통 이름');
    expect((await session.loadProject(second)).people.first.name, '개설자');
    final reopened = ProjectCatalog(file);
    expect(reopened.nameFor('gh-1'), '공통 이름');
    expect(reopened.nameFor('gh-2'), isNull);
    expect(reopened.pendingNames('gh-1'), ['${second.slug}|${b.id}']);
    api.second.failWrite = false;
    expect(
      await renameParticipatingProjects(reopened, session, '공통 이름'),
      contains('2개'),
    );
    expect(reopened.pendingNames('gh-1'), isEmpty);
    expect((await session.loadProject(second)).people.first.name, '공통 이름');
  });

  test('copied project IDs in different repositories still receive separate name commits', () async {
    final api = MultiProjectApi();
    final session = sessionFor(api);
    final directory = Directory.systemTemp.createTempSync(
      'ieum-copied-profile-',
    );
    addTearDown(() {
      session.signOut();
      directory.deleteSync(recursive: true);
    });
    await session.signIn();
    const second = GitHubConfig(repository: 'team/second', enabled: true);
    final first = await session.createProject(config, '원본 프로젝트', '이름');
    final copy = ProjectManifest(
      first.id,
      '복제 프로젝트',
      first.ownerId,
      first.people,
    );
    await session.writeJson(
      second,
      '.ieum/project.json',
      copy.json,
      message: 'fixture',
    );
    final catalog = ProjectCatalog(File('${directory.path}/catalog.json'));
    catalog.remember(
      'gh-1',
      SavedProject(
        path: '${directory.path}/first.sqlite',
        name: first.name,
        projectId: first.id,
        config: config,
      ),
    );
    catalog.remember(
      'gh-1',
      SavedProject(
        path: '${directory.path}/copy.sqlite',
        name: copy.name,
        projectId: copy.id,
        config: second,
      ),
    );
    expect(
      await renameParticipatingProjects(catalog, session, '동일 이름'),
      contains('2개'),
    );
    expect((await session.loadProject(config)).people.first.name, '동일 이름');
    expect((await session.loadProject(second)).people.first.name, '동일 이름');
  });

  test('part recipient completes a simulated task PR using the current saved workflow', () async {
    final api = AutoMergeApi();
    final session = sessionFor(api);
    addTearDown(session.signOut);
    await session.signIn();
    var project = await session.createProject(config, '검토 흐름', '개설자');
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    project = await session.savePermissionPart(config, reviewerRole);
    project = await session.saveWorkflowDefinition(
      config,
      legacyFourStages,
      const WorkflowSheet(
        nodes: [
          WorkflowSheetNode('todo', 'todo'),
          WorkflowSheetNode('doing', 'doing'),
          WorkflowSheetNode('review', 'review'),
          WorkflowSheetNode('done', 'done'),
        ],
        routes: [
          WorkflowSheetRoute(id: 'start', from: 'todo', to: 'doing'),
          WorkflowSheetRoute(
            id: 'submit',
            from: 'doing',
            to: 'review',
            destination: 'part:role-reviewer',
          ),
          WorkflowSheetRoute(
            id: 'approve',
            from: 'review',
            to: 'done',
            source: 'part:role-reviewer',
            action: 'approve',
          ),
        ],
      ),
      expectedProjectId: project.id,
      expectedStages: project.workflowStages,
      expectedSheet: project.workflowSheet,
    );
    project = withGuest(project, role: reviewerRole.id, roles: project.roles);
    await write(session, project);
    final owner = TaskStore(
      ':memory:',
      project: project,
      identity: member(1, 'owner'),
    );
    owner.setMeta('github.config', jsonEncode(config.toJson()));
    owner.setMeta('github.login', 'tester');
    final ownerSync = GitHubSync(owner, publisher: GitHubPublisher(api));
    addTearDown(() {
      ownerSync.dispose();
      owner.dispose();
    });
    final created = owner.save(
      task(member(1, 'owner'), member(2, reviewerRole.id)),
    );
    await idle(ownerSync);
    owner.transition(
      created.id,
      'doing',
      expectedVersion: owner.find(created.id).version,
    );
    await idle(ownerSync);
    owner.transition(
      created.id,
      'review',
      expectedVersion: owner.find(created.id).version,
    );
    await idle(ownerSync);
    await ownerSync.quiesce();
    api.identityId = 2;
    api.identityLogin = 'guest';
    final guest = TaskStore(
      ':memory:',
      project: project,
      identity: member(2, reviewerRole.id),
    );
    guest.setMeta('github.config', jsonEncode(config.toJson()));
    guest.setMeta('github.login', 'guest');
    final guestSync = GitHubSync(guest, publisher: GitHubPublisher(api));
    addTearDown(() {
      guestSync.dispose();
      guest.dispose();
    });
    await guestSync.connect(config);
    await idle(guestSync);
    expect(guest.find(created.id).status, 'review');
    expect(guest.canEditContent(guest.find(created.id)), isTrue);
    guest.transition(
      created.id,
      'done',
      expectedVersion: guest.find(created.id).version,
    );
    await idle(guestSync);
    expect(guest.baseline[created.id]!.status, 'done');
    expect(api.prs.last['merged'], isTrue);
    expect(api.prs.last['user']['id'], 2);
  });

  testWidgets(
    'small settings exposes update and profile change; titlebar contains neither',
    (tester) async {
      tester.view.physicalSize = const Size(480, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      final api = FakeGitHubApi();
      final session = sessionFor(api);
      await session.signIn();
      final project = await session.createProject(config, '팀', '개설자');
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: session.named('개설자'),
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      final directory = Directory.systemTemp.createTempSync(
        'ieum-update-profile-',
      );
      final updater = AppUpdater(
        source: FakeUpdates(),
        root: directory,
        currentVersion: '0.4.0',
      );
      addTearDown(() {
        updater.dispose();
        sync.dispose();
        store.dispose();
        session.signOut();
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        UpdateScope(
          updater: updater,
          restart: () async {},
          child: IeumApp(store: store, sync: sync, session: session),
        ),
      );
      expect(find.byKey(const Key('app-update-button')), findsNothing);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const Key('sidebar-account'))) +
            const Offset(18, 18),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('app-update-button')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('window-titlebar')),
          matching: find.byKey(const Key('app-update-button')),
        ),
        findsNothing,
      );
      await tester.ensureVisible(find.byKey(const Key('change-account-name')));
      await tester.tap(find.byKey(const Key('change-account-name')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('account-display-name')),
        '새 이름',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '변경'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(store.actor.name, '새 이름');
      expect(tester.takeException(), isNull);
      // Name-only part editor stays usable in a short/narrow window.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RolesPanel(store: store, sync: sync, session: session),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('add-role')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('role-name')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byKey(const Key('role-name')), 'QA');
      expect(find.byKey(const Key('permission-task.review')), findsNothing);
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(store.project!.roles.single.name, 'QA');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
