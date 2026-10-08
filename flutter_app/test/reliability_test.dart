import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'v020_sync_test.dart' show ReliabilityApi;
import 'github_sync_test.dart' show idle;

void main() {
  late ReliabilityApi api;
  late GitHubSession session;
  late TaskStore store;
  late GitHubSync sync;
  const config = GitHubConfig(repository: 'team/data', enabled: true);
  Map<String, dynamic> fields(String title) => {
    'title': title,
    'part': '기획',
    'priority': 'normal',
    'assigneeId': 'gh-1',
    'reviewerId': 'gh-1',
    'assignedDate': '2026-10-01',
    'dueDate': '',
    'description': '',
  };
  setUp(() async {
    api = ReliabilityApi();
    session = GitHubSession(api: api);
    await session.signIn(token: 'test-only');
    await session.createProject(config, 'audit', 'owner');
    final project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    store = TaskStore(
      ':memory:',
      project: project,
      identity: session.named('owner'),
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'tester');
    sync = GitHubSync(store, publisher: GitHubPublisher(api));
  });
  tearDown(() {
    sync.dispose();
    store.dispose();
    session.signOut();
  });

  test('non-task corrupt file does not block healthy tasks or automatic integration', () async {
    api.inject('invalid path', '{');
    final remote = WorkTask.fromJson({
      ...fields('healthy'),
      'id': 'healthy',
      'status': 'todo',
      'completedDate': '',
      'reworkReason': '',
      'version': 1,
      'updatedAt': '2026-10-01T00:00:00Z',
    });
    api.addMainProposal({
      'schemaVersion': 1,
      'projectId': store.project!.id,
      'authorId': 'gh-1',
      'githubLogin': 'other',
      'changes': [
        {'taskId': remote.id, 'task': remote.data, 'base': null},
      ],
    }, remote.id);
    await sync.pullLatest();
    expect(store.find('healthy').title, 'healthy');
    expect(store.meta('github.pullRevision'), isNotEmpty);
    expect(sync.pullMessage, contains('격리'));
    store.save(fields('valid new local task'));
    await idle(sync);
    expect(api.prs, hasLength(1));
    expect(api.prs.single['state'], 'closed');
    expect(sync.autoMergeErrors, isEmpty);
    await sync.cycle(retryFailed: true);
    expect(api.prs.single['state'], 'closed');
    expect(store.tasks.any((t) => t.id == 'healthy'), isTrue);
  });

  test(
    'malformed queue is preserved for recovery while synchronization continues',
    () async {
      store.db.execute('INSERT INTO github_queue VALUES (?,?)', [
        'poison',
        '{',
      ]);
      final before = api.calls.length;
      sync.start();
      await idle(sync);
      expect(api.calls.length, greaterThan(before));
      expect(store.db.select('SELECT * FROM sync_recovery'), hasLength(1));
      expect(sync.jobs, isEmpty);
      expect(sync.busy, isFalse);
      expect(sync.pulling, isFalse);
      // Recovery requires repairing/quarantining the local row, not retrying.
      store.db.execute('DELETE FROM github_queue WHERE id=?', ['poison']);
      await sync.cycle(retryFailed: true);
      expect(api.calls.length, greaterThan(before));
    },
  );

  test('damaged task queue is rebuilt from the durable local task', () async {
    store.setMeta(
      'github.config',
      jsonEncode({...config.toJson(), 'enabled': false}),
    );
    final task = store.save(fields('보존된 개인 작업'));
    store.db.execute('UPDATE github_queue SET body=? WHERE id=?', [
      '{',
      task.id,
    ]);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    await sync.cycle();
    await idle(sync);
    expect(store.find(task.id).title, '보존된 개인 작업');
    expect(store.baseline[task.id]!.title, '보존된 개인 작업');
    expect(sync.jobs.single['state'], 'merged');
    final archived = jsonDecode(
      store.db.select('SELECT body FROM sync_recovery').single['body']
          as String,
    );
    expect(archived['raw'], '{');
  });

  test('damaged receipt cannot prevent a healthy task from merging', () async {
    store.db.execute('INSERT INTO github_sent VALUES (?,?)', ['damaged', '{']);
    final task = store.save(fields('정상 통합'));
    await idle(sync);
    expect(store.baseline[task.id]!.title, '정상 통합');
    expect(store.db.select('SELECT * FROM sync_recovery'), hasLength(1));
    expect(sync.jobs.single['state'], 'merged');
  });

  test(
    'confirmed task receipts remain bounded while all revisions reach main',
    () async {
      var task = store.save(fields('연속 변경'));
      await idle(sync);
      for (var index = 0; index < 8; index++) {
        task = store.save({
          ...task.data,
          'description': '수정 $index',
        }, expectedVersion: task.version);
        await idle(sync);
      }
      expect(store.baseline[task.id]!.description, '수정 7');
      expect(api.prs.where((p) => p['merged'] == true), hasLength(9));
      expect(store.db.select('SELECT * FROM github_sent'), hasLength(1));
    },
  );

  test('ownership transfer preserves project identity and moves membership authority to the new owner', () async {
    Future<Person> join(int id, String role) async {
      api.identityId = id;
      api.identityLogin = 'guest$id';
      await session.signIn(token: 'test-only');
      await session.register(
        config,
        await session.loadProject(config),
        '참여자$id',
      );
      final request = (await session.requests(config))
          .singleWhere((r) => r['member']['id'] == 'gh-$id');
      api.identityId = 1;
      api.identityLogin = 'tester';
      await session.signIn(token: 'test-only');
      final member = Person.fromJson({
        ...request['member'] as Map,
        'role': 'unassigned',
        'parts': ['기획'],
      });
      final manifest = await session.assign(config, member, request: request);
      store.updateProject(manifest);
      return member;
    }

    final nextOwner = await join(2, 'manager');
    final original = store.project!;
    final transferred = await session.transferOwnership(config, nextOwner.id);
    expect(transferred.ownerId, 'gh-2');
    expect(transferred.founderId, original.founderId);
    store.updateProject(transferred);
    expect(store.owns, isFalse);
    expect(store.manages, isFalse);
    await sync.connect(config);
    await idle(sync);
    // The previous owner becomes a normal participant; management moves too.
    api.identityId = 3;
    api.identityLogin = 'guest3';
    await session.signIn(token: 'test-only');
    await session.register(config, transferred, '참여자3');
    final request = (await session.requests(config)).single;
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.signIn(token: 'test-only');
    final worker = Person.fromJson({
      ...request['member'] as Map,
      'role': 'unassigned',
    });
    await expectLater(
      session.assign(config, worker, request: request),
      throwsA(isA<GitHubFailure>()),
    );
    api.identityId = 2;
    api.identityLogin = 'guest2';
    await session.signIn(token: 'test-only');
    final manifest = await session.assign(config, worker, request: request);
    expect(
      manifest.people.any((p) => p.id == 'gh-3' && p.role == 'unassigned'),
      isTrue,
    );
    await expectLater(
      session.assign(
        config,
        Person.fromJson({...worker.json, 'role': 'manager'}),
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(
      () => store.updateProject(
        ProjectManifest.fromJson({...manifest.json, 'founderId': 'gh-99'}),
      ),
      throwsStateError,
    );
  });

  test(
    'member with unfinished assignments cannot be disabled before handoff',
    () async {
      final task = store.save(fields('진행 중 배정'));
      await idle(sync);
      final owner = store.project!.people.single;
      final worker = Person.fromJson({
        'id': 'gh-2',
        'login': 'guest2',
        'name': '작업자',
        'role': 'unassigned',
        'parts': <String>[],
      });
      final manifest = ProjectManifest.fromJson({
        ...store.project!.json,
        'members': [owner.json, worker.json],
      });
      final file = await session.readJson(config, '.ieum/project.json');
      await session.writeJson(
        config,
        '.ieum/project.json',
        manifest.json,
        sha: file!['sha'],
        message: 'fixture',
      );
      store.updateProject(manifest);
      store.recoverTask(
        task.id,
        stageId: 'todo',
        personId: worker.id,
        expectedVersion: task.version,
      );
      await idle(sync);
      await expectLater(
        session.setMemberEnabled(config, worker.id, false),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'blocker',
            contains('인수인계'),
          ),
        ),
      );
      expect(
        (await session.loadProject(config)).people.last.role,
        'unassigned',
      );
      store.recoverTask(
        task.id,
        stageId: 'todo',
        personId: owner.id,
        expectedVersion: store.find(task.id).version,
      );
      await idle(sync);
      expect(
        (await session.setMemberEnabled(
          config,
          worker.id,
          false,
        )).people.last.active,
        isFalse,
      );
    },
  );
}
