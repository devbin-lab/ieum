import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/team_panel.dart';
import 'package:ieum_flutter/popup_ui.dart';

import 'github_sync_test.dart' show idle;
import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'project_test.dart' show member, task;

const config = GitHubConfig(repository: 'team/data', enabled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AutoMergeApi api;
  late GitHubSession session;
  late ProjectManifest project;
  setUp(() async {
    api = AutoMergeApi();
    session = GitHubSession(api: api);
    await session.signIn(token: 'test-only');
    project = await session.createProject(config, '상태 관리', '개설자');
    project = ProjectManifest(
      project.id,
      project.name,
      project.ownerId,
      [...project.people, member(2, 'worker'), member(3, 'manager')],
      parts: const ['기획', 'QA'],
    );
    final file = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      project.json,
      sha: file!['sha'],
      message: 'fixture',
    );
  });
  tearDown(() => session.signOut());

  test(
    'inactive status retains role and blocks legacy and current permissions',
    () {
      const role = ProjectRole('role-qa', 'QA', {'task.work', 'task.review'});
      final person = Person.fromJson({
        ...member(2, role.id).json,
        'enabled': false,
      }).resolved([role]);
      expect(person.role, role.id);
      expect(person.roleLabel, 'QA');
      expect(person.enabled, isFalse);
      expect(person.active, isFalse);
      expect(person.canWork, isFalse);
      expect(person.canReview, isFalse);
      expect(person.json['role'], 'disabled');
      expect(person.json['assignedRole'], role.id);
      expect(Person.fromJson(person.json).resolved([role]).role, role.id);
      final oldFields = {...person.json}
        ..remove('enabled')
        ..remove('assignedRole');
      expect(Person.fromJson(oldFields).active, isFalse);
      expect(
        Person.fromJson({...member(2, 'worker').json}..remove('enabled'))
            .active,
        isTrue,
      );
    },
  );

  test('owner can deactivate and reactivate while retaining parts; other members cannot and owner stays active', () async {
    project = await session.setMemberEnabled(config, 'gh-2', false);
    final worker = project.people.firstWhere((p) => p.id == 'gh-2');
    expect(worker.role, 'unassigned');
    expect(worker.active, isFalse);
    expect(worker.parts, ['기획']);
    await expectLater(
      session.setMemberEnabled(config, 'gh-1', false),
      throwsA(isA<GitHubFailure>()),
    );
    project = await session.setMemberEnabled(config, 'gh-2', true);
    expect(project.people.firstWhere((p) => p.id == 'gh-2').canWork, isTrue);
    api.identityId = 2;
    await session.signIn(token: 'worker');
    await expectLater(
      session.setMemberEnabled(config, 'gh-3', false),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test(
    'member management alone cannot change activation through role assignment',
    () async {
      const delegate = ProjectRole('role-members', '참여자 배정', {
        'member.manage',
        'task.work',
        'task.review',
      });
      project = ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, 'worker'), member(3, delegate.id)],
        parts: const ['기획'],
        roles: [delegate],
      );
      final file = await session.readJson(config, '.ieum/project.json');
      await session.writeJson(
        config,
        '.ieum/project.json',
        project.json,
        sha: file!['sha'],
        message: 'fixture',
      );
      api.identityId = 3;
      await session.signIn(token: 'delegate');
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
      await expectLater(
        session.assign(
          config,
          Person(
            'gh-2',
            '팀원',
            '',
            'disabled',
            0,
            login: member(2, 'worker').login,
            parts: ['기획'],
          ),
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(
        (await session.loadProject(config)).people
            .firstWhere((p) => p.id == 'gh-2')
            .active,
        isTrue,
      );
    },
  );

  test(
    'legacy delegated status grants no longer allow participation management',
    () async {
      const statusRole = ProjectRole('role-status', '참여자 상태 관리자', {
        'member.status',
      });
      project = ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, 'worker'), member(3, statusRole.id)],
        parts: const ['기획'],
        roles: [statusRole],
      );
      final file = await session.readJson(config, '.ieum/project.json');
      await session.writeJson(
        config,
        '.ieum/project.json',
        project.json,
        sha: file!['sha'],
        message: 'fixture',
      );
      api.identityId = 3;
      await session.signIn(token: 'status-admin');
      await expectLater(
        session.setMemberEnabled(config, 'gh-2', false),
        throwsA(isA<GitHubFailure>()),
      );
      final changed = await session.loadProject(config);
      expect(changed.people.firstWhere((p) => p.id == 'gh-2').active, isTrue);
      expect(changed.people.firstWhere((p) => p.id == 'gh-3').canWork, isTrue);
      await expectLater(
        session.setMemberEnabled(config, 'gh-1', false),
        throwsA(isA<GitHubFailure>()),
      );
    },
  );

  test('queued work from stale active client cannot upload after remote deactivation and can resume after activation', () async {
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
    final created = owner.save(task(member(2, 'worker'), member(1, 'owner')));
    await idle(ownerSync);
    await ownerSync.quiesce();
    api.identityId = 2;
    api.identityLogin = 'guest';
    final guest = TaskStore(
      ':memory:',
      project: project,
      identity: member(2, 'worker'),
    );
    guest.setMeta('github.config', jsonEncode(config.toJson()));
    guest.setMeta('github.login', 'guest');
    final sync = GitHubSync(guest, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      guest.dispose();
    });
    await sync.connect(config);
    await idle(sync);
    await sync.quiesce();
    guest.transition(
      created.id,
      'doing',
      expectedVersion: guest.find(created.id).version,
    );
    api.identityId = 1;
    api.identityLogin = 'tester';
    // Simulate a remote/historical deactivation independently of the new handoff guard.
    final savedManifest = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      {
        ...savedManifest!['data'],
        'members': [
          for (final p in (savedManifest['data']['members'] as List))
            if (p['id'] == 'gh-2')
              {
                ...p,
                'role': 'disabled',
                'assignedRole': 'worker',
                'enabled': false,
              }
            else
              p,
        ],
      },
      sha: savedManifest['sha'],
      message: 'mock remote deactivation',
    );
    final writes = api.writes;
    final count = api.prs.length;
    api.identityId = 2;
    api.identityLogin = 'guest';
    sync.resume();
    await idle(sync);
    expect(sync.jobs.single['state'], 'failed');
    expect(api.writes, writes);
    expect(api.prs.length, count);
    await sync.pullLatest();
    expect(guest.actor.active, isFalse);
    expect(guest.canEditContent(guest.find(created.id)), isFalse);
    expect(
      () => guest.transition(
        created.id,
        'review',
        expectedVersion: guest.find(created.id).version,
      ),
      throwsStateError,
    );
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.setMemberEnabled(config, 'gh-2', true);
    api.identityId = 2;
    api.identityLogin = 'guest';
    await sync.cycle(retryFailed: true);
    await idle(sync);
    expect(sync.jobs.single['state'], 'merged');
    expect(guest.baseline[created.id]!.status, 'doing');
  });

  test(
    'already uploaded PR cannot integrate after author becomes inactive',
    () async {
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
      final created = owner.save(task(member(2, 'worker'), member(1, 'owner')));
      await idle(ownerSync);
      await ownerSync.quiesce();
      api.identityId = 2;
      api.identityLogin = 'guest';
      final guest = TaskStore(
        ':memory:',
        project: project,
        identity: member(2, 'worker'),
      );
      guest.setMeta(
        'github.config',
        jsonEncode({...config.toJson(), 'autoMerge': false}),
      );
      guest.setMeta('github.login', 'guest');
      final sync = GitHubSync(guest, publisher: GitHubPublisher(api));
      addTearDown(() {
        sync.dispose();
        guest.dispose();
      });
      await sync.connect(
        GitHubConfig.fromJson({...config.toJson(), 'autoMerge': false}),
      );
      await idle(sync);
      guest.transition(
        created.id,
        'doing',
        expectedVersion: guest.find(created.id).version,
      );
      await idle(sync);
      await sync.quiesce();
      final url = api.prs.last['html_url'] as String;
      api.identityId = 1;
      api.identityLogin = 'tester';
      // Simulate a remote/historical deactivation independently of the new handoff guard.
      final savedManifest = await session.readJson(
        config,
        '.ieum/project.json',
      );
      await session.writeJson(
        config,
        '.ieum/project.json',
        {
          ...savedManifest!['data'],
          'members': [
            for (final p in (savedManifest['data']['members'] as List))
              if (p['id'] == 'gh-2')
                {
                  ...p,
                  'role': 'disabled',
                  'assignedRole': 'worker',
                  'enabled': false,
                }
              else
                p,
          ],
        },
        sha: savedManifest['sha'],
        message: 'mock remote deactivation',
      );
      final revision = api.refs['main'];
      await expectLater(
        GitHubPublisher(api).integrateTask(
          config,
          url,
          projectId: project.id,
          founderId: project.founderId,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.refs['main'], revision);
      expect(api.prs.last['state'], 'open');
    },
  );

  testWidgets(
    'member editor saves multiple parts and applies workflow participant status',
    (tester) async {
      tester.view.physicalSize = const Size(480, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => false,
          );
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: member(1, 'owner'),
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
      await tester.ensureVisible(find.byKey(const Key('member-actions-gh-2')));
      await tester.tap(find.byKey(const Key('member-actions-gh-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('파트 배정').first);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('member-part-기획')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-member')))
            .onPressed,
        isNull,
      );

      await tester.ensureVisible(find.byKey(const Key('member-part-QA')));
      await tester.tap(find.byKey(const Key('member-part-QA')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('member-part-QA')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-member')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('save-member')));
      await tester.pumpAndSettle();
      expect(find.textContaining('소속 파트: 기획 → 기획, QA'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '취소').last);
      await tester.pumpAndSettle();
      expect(store.member('gh-2').parts, ['기획']);
      expect(
        tester
            .widget<FilterChip>(find.byKey(const Key('member-part-QA')))
            .selected,
        isTrue,
      );

      await tester.ensureVisible(find.byKey(const Key('member-part-기획')));
      await tester.tap(find.byKey(const Key('member-part-기획')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await tester.pumpAndSettle();
      final saved = store.member('gh-2');
      expect(saved.parts, ['QA']);
      expect(saved.role, 'unassigned');
      expect(saved.permissions, containsAll(workerPermissions));
      expect(saved.enabled, isTrue);
      expect(
        (await session.loadProject(config)).people
            .firstWhere((p) => p.id == 'gh-2')
            .parts,
        ['QA'],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'member editor adds a name-only part inline and preserves inactive state',
    (tester) async {
      tester.view.physicalSize = const Size(480, 620);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => false,
          );
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: member(1, 'owner'),
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      store.setMeta('github.login', 'tester');
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
      await tester.ensureVisible(find.byKey(const Key('member-actions-gh-2')));
      await tester.tap(find.byKey(const Key('member-actions-gh-2')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('파트 배정').first);
      await tester.tap(find.text('파트 배정').first);
      await tester.pumpAndSettle();
      expect(find.text('담당 파트'), findsNothing);
      expect(find.byKey(const Key('member-role')), findsNothing);
      expect(
        find.descendant(
          of: find.byType(IeumDialog),
          matching: find.byType(IeumSelect),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('member-role-unassigned')), findsNothing);
      expect(find.byKey(const Key('member-role-worker')), findsNothing);
      await tester.ensureVisible(find.byKey(const Key('member-add-role')));
      await tester.tap(find.byKey(const Key('member-add-role')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), 'QA 검토');
      expect(find.byKey(const Key('permission-task.review')), findsNothing);
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(store.project!.roles.any((r) => r.name == 'QA 검토'), isTrue);
      await tester.ensureVisible(find.byKey(const Key('member-disabled')));
      await tester.tap(find.byKey(const Key('member-disabled')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await tester.pumpAndSettle();
      expect(store.member('gh-2').parts, contains('QA 검토'));
      expect(store.member('gh-2').enabled, isFalse);
      expect(store.member('gh-2').active, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
