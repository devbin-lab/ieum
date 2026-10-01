import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_gate.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi, idle;
import 'github_oauth_test.dart' show MemoryVault;

import 'package:ieum_flutter/github_oauth.dart';

const config = GitHubConfig(
  repository: 'team/data',
  enabled: true,
  autoMerge: false,
);
Person member(int id, String role) => Person.fromJson({
  'id': 'gh-$id',
  'login': id == 1 ? 'tester' : 'guest',
  'name': id == 1 ? '개설자' : '참여자',
  'role': role,
  'parts': ['기획'],
});
Map<String, dynamic> task(Person assigned, Person reviewed) => {
  'title': '빈 프로젝트의 첫 작업',
  'part': '기획',
  'priority': 'normal',
  'assigneeId': assigned.id,
  'reviewerId': reviewed.id,
  'assignedDate': '2026-10-01',
  'dueDate': '',
  'description': '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeGitHubApi api;
  late GitHubSession session;
  setUp(() {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
  });
  tearDown(() => session.signOut());

  test(
    'GitHub identity is verified; nickname does not choose role or identity',
    () async {
      await session.signIn(token: 'memory-only');
      final named = session.named('휴랑');
      expect(named.id, 'gh-1');
      expect(named.role, 'pending');
      expect(named.login, 'tester');
      expect(
        session.branchFor(named),
        matches(RegExp(r'^ieum/members/[a-z0-9-]+-gh-1$')),
      );
      expect(
        session.branchFor(member(2, 'pending')),
        isNot(session.branchFor(named)),
      );
      expect(() => session.named(' '), throwsStateError);
      session.signOut();
      expect(session.sessionToken, isEmpty);
      expect(() => session.named('휴랑'), throwsStateError);
    },
  );

  test('project creation publishes only a manifest and initializes an empty DB at chosen path', () async {
    await session.signIn();
    final manifest = await session.createProject(config, '졸업작품', '휴랑');
    expect(manifest.people.single.role, 'owner');
    expect(api.files['main']!.keys, ['.ieum/project.json']);
    await expectLater(
      session.createProject(config, '덮어쓰기', '휴랑'),
      throwsA(isA<GitHubFailure>()),
    );
    final directory = Directory.systemTemp.createTempSync('ieum-project-test-');
    final path = '${directory.path}/selected.sqlite';
    final store = TaskStore(
      path,
      project: manifest,
      identity: session.named('휴랑'),
    );
    expect(store.tasks, isEmpty);
    expect(store.notifications, isEmpty);
    expect(store.owns, isTrue);
    expect(store.filename, path);
    store.dispose();
    final reopened = TaskStore(path);
    expect(reopened.project!.id, manifest.id);
    expect(reopened.people.single.name, '휴랑');
    reopened.dispose();
    directory.deleteSync(recursive: true);
  });

  test('only repository admins create projects; missing push permissions stop registration', () async {
    await session.signIn();
    api.allowAdmin = false;
    await expectLater(
      session.createProject(config, '작품', '휴랑'),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, 0);
    api.allowPush = false;
    await expectLater(session.access(config), throwsA(isA<GitHubFailure>()));
  });

  test('joining creates a personal branch and a deduplicated membership PR; only owner assigns roles', () async {
    await session.signIn();
    final project = await session.createProject(config, '작품', '개설자');
    api.identityId = 2;
    api.identityLogin = 'guest';
    await session.signIn();
    final url = await session.register(config, project, '팀원');
    expect(url, isNotNull);
    await session.register(config, project, '팀원');
    expect(api.prs, hasLength(1));
    final requests = await session.requests(config);
    expect(requests.single['member']['id'], 'gh-2');
    final worker = Person.fromJson({
      ...requests.single['member'] as Map,
      'role': 'worker',
    });
    await expectLater(
      session.assign(config, worker, request: requests.single),
      throwsA(isA<GitHubFailure>()),
    );
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.signIn();
    final next = await session.assign(config, worker, request: requests.single);
    expect(next.people.last.role, 'worker');
    expect(api.prs.single['state'], 'closed');
    final viewer = Person.fromJson({...worker.json, 'role': 'viewer'});
    expect((await session.assign(config, viewer)).people.last.role, 'viewer');
    await expectLater(
      session.assign(config, member(1, 'worker')),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test(
    'forged GitHub IDs and changed membership requests cannot be approved',
    () async {
      await session.signIn();
      final project = await session.createProject(config, '작품', '개설자');
      api.identityId = 2;
      api.identityLogin = 'guest';
      await session.signIn();
      await session.register(config, project, '팀원');
      final requests = await session.requests(config);
      api.identityId = 1;
      api.identityLogin = 'tester';
      await session.signIn();
      api.prs.single['head']['sha'] = 'changed';
      await expectLater(
        session.assign(
          config,
          Person.fromJson({
            ...requests.single['member'] as Map,
            'role': 'worker',
          }),
          request: requests.single,
        ),
        throwsA(anything),
      );
      api.prs.single['user']['id'] = 99;
      // Restore an existing ref, then reject the claimed account identity.
      api.prs.single['head']['sha'] = api.refs[api.prs.single['head']['ref']];
      expect(await session.requests(config), isEmpty);
    },
  );

  test('repository invitations validate account names and require the project owner', () async {
    await session.signIn();
    await session.createProject(config, '작품', '개설자');
    await session.invite(config, 'guest');
    expect(api.invitations, ['guest']);
    await expectLater(session.invite(config, 'bad/name'), throwsStateError);
    api.identityId = 2;
    api.identityLogin = 'guest';
    await session.signIn();
    await expectLater(
      session.invite(config, 'someone'),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.invitations, ['guest']);
  });

  test('role permissions cover creation, assignment, review, viewer and pending accounts', () {
    final owner = member(1, 'owner');
    final worker = member(2, 'worker');
    final project = ProjectManifest('project-test', '작품', owner.id, [
      owner,
      worker,
    ]);
    final store = TaskStore(':memory:', project: project, identity: owner);
    final registered = store.save(task(worker, owner));
    store.setMeta(
      'profile',
      worker.id,
    ); // Simulates a separately authenticated test client.
    expect(() => store.setProfile(owner.id), throwsStateError);
    expect(() => store.save(task(worker, owner)), throwsStateError);
    expect(
      () => store.save({
        ...registered.data,
        'assigneeId': owner.id,
      }, expectedVersion: registered.version),
      throwsStateError,
    );
    final changed = store.save({
      ...registered.data,
      'description': '작업 결과',
    }, expectedVersion: registered.version);
    store.transition(changed.id, 'doing', expectedVersion: changed.version);
    store.transition(
      changed.id,
      'review',
      expectedVersion: store.find(changed.id).version,
    );
    expect(store.canMove(store.find(changed.id), 'done'), isFalse);
    store.setMeta('profile', owner.id);
    store.transition(
      changed.id,
      'done',
      expectedVersion: store.find(changed.id).version,
    );
    for (final role in ['viewer', 'pending', 'disabled']) {
      final limited = member(2, role);
      store.updateProject(
        ProjectManifest(project.id, project.name, owner.id, [owner, limited]),
      );
      store.setMeta('profile', limited.id);
      expect(() => store.save(task(limited, owner)), throwsStateError);
      expect(store.canEdit(store.find(changed.id)), isFalse);
      expect(store.canMove(store.find(changed.id), 'doing'), isFalse);
    }
    store.dispose();
  });

  test('remote revocation blocks queued writes even when a local cached role is privileged', () async {
    await session.signIn();
    final project = await session.createProject(config, '작품', '개설자');
    final manager = member(2, 'manager');
    final cached = ProjectManifest(project.id, project.name, project.ownerId, [
      ...project.people,
      manager,
    ]);
    final store = TaskStore(':memory:', project: cached, identity: manager);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'guest');
    store.save(task(project.people.first, project.people.first));
    api.identityId = 2;
    api.identityLogin = 'guest';
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    await sync.drain();
    expect(sync.jobs.single['state'], 'failed');
    expect(api.prs, isEmpty);
    sync.dispose();
    store.dispose();
  });

  test('two authenticated clients complete registration, task submission, review and automatic pulls', () async {
    await session.signIn();
    final initial = await session.createProject(config, '작품', '개설자');
    api.identityId = 2;
    api.identityLogin = 'guest';
    await session.signIn();
    await session.register(config, initial, '참여자');
    final request = (await session.requests(config)).single;
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.signIn();
    final worker = Person.fromJson({
      ...request['member'] as Map,
      'role': 'worker',
      'parts': ['기획'],
    });
    final project = await session.assign(config, worker, request: request);
    final owner = project.people.first;
    final ownerStore = TaskStore(':memory:', project: project, identity: owner);
    final guestStore = TaskStore(
      ':memory:',
      project: project,
      identity: worker,
    );
    for (final store in [ownerStore, guestStore]) {
      store.setMeta('github.config', jsonEncode(config.toJson()));
      store.setMeta('github.login', store.actor.login);
    }
    final publisher = GitHubPublisher(api);
    final ownerSync = GitHubSync(ownerStore, publisher: publisher);
    final guestSync = GitHubSync(guestStore, publisher: publisher);
    try {
      expect(ownerStore.partRules.first.assigneeId, worker.id);
      final created = ownerStore.save(task(worker, owner));
      await idle(ownerSync);
      await ownerSync.approve(
        await publisher.review(config, ownerSync.jobs.single['prUrl']),
      );
      api.identityId = 2;
      api.identityLogin = 'guest';
      await guestSync.pullLatest();
      expect(guestStore.find(created.id).title, created.title);
      guestStore.transition(
        created.id,
        'doing',
        expectedVersion: guestStore.find(created.id).version,
      );
      await idle(guestSync);
      guestStore.transition(
        created.id,
        'review',
        expectedVersion: guestStore.find(created.id).version,
      );
      await idle(guestSync);
      expect(guestStore.canMove(guestStore.find(created.id), 'done'), isFalse);
      api.identityId = 1;
      api.identityLogin = 'tester';
      await ownerSync.approve(
        await publisher.review(config, guestSync.jobs.single['prUrl']),
      );
      expect(ownerStore.find(created.id).status, 'review');
      ownerStore.transition(
        created.id,
        'done',
        expectedVersion: ownerStore.find(created.id).version,
      );
      await idle(ownerSync);
      await ownerSync.approve(
        await publisher.review(config, ownerSync.jobs.single['prUrl']),
      );
      api.identityId = 2;
      api.identityLogin = 'guest';
      await guestSync.pullLatest();
      expect(guestStore.find(created.id).status, 'done');
      expect(guestStore.find(created.id).completedDate, localDate());
      expect(guestStore.changes, isEmpty);
    } finally {
      ownerSync.dispose();
      guestSync.dispose();
      ownerStore.dispose();
      guestStore.dispose();
    }
  });

  testWidgets(
    'login, empty project creation, team screen and logout fit small windows without native input',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'ieum-onboarding-test-',
      );
      final placeholder = TaskStore(':memory:');
      addTearDown(() {
        placeholder.dispose();
        directory.deleteSync(recursive: true);
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      tester.view.physicalSize = const Size(1160, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        IeumApp(
          store: placeholder,
          home: ProjectGate(
            preferences: File('${directory.path}/preferences.json'),
            session: session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('이음에 로그인'), findsOneWidget);
      await tester.tap(find.text('고급 연결'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('github-advanced-login')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('github-advanced-login')));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(session.user, isNotNull);
      await tester.ensureVisible(find.byKey(const Key('project-name')));
      await tester.enterText(
        find.byKey(const Key('project-name')),
        '빈 테스트 프로젝트',
      );
      await tester.enterText(
        find.byKey(const Key('project-repository')),
        'team/data',
      );
      await tester.enterText(find.byKey(const Key('project-nickname')), '개설자');
      await tester.enterText(
        find.byKey(const Key('project-folder')),
        directory.path,
      );
      await tester.ensureVisible(find.byKey(const Key('project-submit')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('project-submit')));
        for (var attempt = 0; attempt < 100; attempt++) {
          if (File('${directory.path}/preferences.json').existsSync()) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-list')), findsOneWidget);
      expect(find.byKey(const Key('card-IE-101')), findsNothing);
      expect(find.byKey(const Key('profile')), findsNothing);
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      expect(find.text('참여자 · 역할과 권한'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.tap(find.text('로그아웃 / 프로젝트 선택'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(find.text('이음에 로그인'), findsOneWidget);
      expect(session.sessionToken, isEmpty);
      await tester.ensureVisible(
        find.byKey(const Key('github-advanced-login')),
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('github-advanced-login')));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reopen-project')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-list')), findsOneWidget);
      expect(find.byKey(const Key('profile')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
