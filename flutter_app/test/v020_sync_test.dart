import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;

class ReliabilityApi extends AutoMergeApi {
  bool loseCreatedAndMergedResponse = false;
  bool rateLimitOnce = false;
  bool narrowTrees = false;
  bool changeMergedPayload = false;
  int failTaskWrites = 0;
  Completer<void>? holdIntegrationRef;
  Completer<void>? integrationReady;
  Completer<void>? holdBlob;
  Completer<void>? blobReady;
  final pages = <String>[];

  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (holdBlob != null && path.contains('/git/blobs/')) {
      if (blobReady?.isCompleted == false) blobReady!.complete();
      await holdBlob!.future;
    }
    if (path == '/repos/team/data/git/commits' && method == 'POST') {
      calls.add('$method $path');
      final parent = (body!['parents'] as List).single as String;
      final sha = 'fence${++serial}';
      parents[sha] = [parent];
      snapshots[sha] = Map.of(snapshots[parent]!);
      return {'sha': sha};
    }
    if (holdIntegrationRef != null &&
        method == 'PATCH' &&
        path == '/repos/team/data/git/refs/heads/main' &&
        (body?['sha'] as String?)?.startsWith('integration') == true) {
      if (integrationReady?.isCompleted == false) integrationReady!.complete();
      await holdIntegrationRef!.future;
    }
    if (rateLimitOnce) {
      rateLimitOnce = false;
      calls.add('$method $path');
      throw const GitHubFailure('요청 한도', 429, Duration(minutes: 1));
    }
    if (method == 'PUT' &&
        path.contains('/contents/.ieum/changes/') &&
        failTaskWrites > 0) {
      failTaskWrites--;
      throw const GitHubFailure('일시적인 작업 전송 오류');
    }
    if (narrowTrees && path.contains('/git/trees/')) {
      calls.add('$method $path');
      final sha = path.split('/').last;
      if (sha == 'tree-main') {
        expect(query?['recursive'], isNull);
        return {
          'tree': [
            {'path': 'unrelated-large-source', 'type': 'tree', 'sha': 'large'},
            {'path': '.ieum', 'type': 'tree', 'sha': 'ieum'},
          ],
          'truncated': false,
        };
      }
      if (sha == 'ieum') {
        return {
          'tree': [
            {'path': 'changes', 'type': 'tree', 'sha': 'changes'},
          ],
          'truncated': false,
        };
      }
      if (sha == 'changes') {
        return {
          'tree': [
            {'path': 'other', 'type': 'tree', 'sha': 'author'},
          ],
          'truncated': false,
        };
      }
      if (sha == 'author') {
        return {
          'tree': [
            for (final entry in files['main']!.entries.where(
              (e) => e.key.startsWith('.ieum/changes/other/'),
            ))
              {
                'path': entry.key.split('/').last,
                'type': 'blob',
                'sha': entry.value['sha'],
                'size': 200,
              },
          ],
          'truncated': false,
        };
      }
      throw StateError('Unrelated repository tree was visited: $sha');
    }
    if (path == '/repos/team/data/pulls' && method == 'GET') {
      final result =
          await super.call(method, path, query: query, body: body) as List;
      if (query?['page'] == null) return result;
      pages.add(query!['page']!);
      final offset = (int.parse(query['page']!) - 1) * 100;
      return result.skip(offset).take(100).toList();
    }
    final result = await super.call(method, path, query: query, body: body);
    if (changeMergedPayload &&
        method == 'POST' &&
        path.endsWith('/merges') &&
        (body?['base'] as String?)?.startsWith('ieum/integrations/') == true) {
      final staged = snapshots[result['sha']]!;
      final path = staged.keys.lastWhere((p) => p.startsWith('.ieum/changes/'));
      final original = staged[path]!;
      staged[path] = {...original, 'sha': 'different-merge-result'};
    }
    if (path == '/repos/team/data/pulls' &&
        method == 'POST' &&
        loseCreatedAndMergedResponse) {
      loseCreatedAndMergedResponse = false;
      final branch = body!['head'] as String;
      final previous = refs['main']!;
      final sha = 'other-client-merge${++serial}';
      files['main'] = Map.of(files[branch]!);
      refs['main'] = sha;
      snapshots[sha] = Map.of(files['main']!);
      parents[sha] = [previous, refs[branch]!];
      result['state'] = 'closed';
      result['merged'] = true;
      throw const GitHubFailure('PR 생성 응답 유실');
    }
    return result;
  }

  void inject(String taskId, String raw) {
    final sha = 'bad${++serial}';
    final value = <String, dynamic>{
      'sha': sha,
      'encoding': 'base64',
      'content': base64Encode(utf8.encode(raw)),
    };
    files['main']!['.ieum/changes/other/$taskId.json'] = value;
    blobs[sha] = value;
    final previous = refs['main']!;
    refs['main'] = 'injected${++serial}';
    snapshots[refs['main']!] = Map.of(files['main']!);
    parents[refs['main']!] = [previous];
  }
}

void main() {
  late ReliabilityApi api;
  late GitHubSession session;
  late TaskStore store;
  late GitHubPublisher publisher;
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
  Map<String, dynamic> proposal(WorkTask task) => {
    'schemaVersion': 1,
    'projectId': store.project!.id,
    'authorId': 'gh-1',
    'githubLogin': 'other',
    'changes': [
      {'taskId': task.id, 'task': task.data, 'base': null},
    ],
  };
  WorkTask remote(String id, String title) => WorkTask.fromJson({
    ...fields(title),
    'id': id,
    'status': 'todo',
    'completedDate': '',
    'reworkReason': '',
    'version': 1,
    'updatedAt': '2026-10-01T00:00:00Z',
  });
  setUp(() async {
    api = ReliabilityApi();
    session = GitHubSession(api: api);
    await session.signIn(token: 'test-only');
    final project = await session.createProject(config, '복구 검증', '개설자');
    store = TaskStore(
      ':memory:',
      project: project,
      identity: session.named('개설자'),
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'tester');
    publisher = GitHubPublisher(api);
    sync = GitHubSync(store, publisher: publisher);
  });
  tearDown(() {
    sync.dispose();
    store.dispose();
    session.signOut();
  });

  test('idle ten-second cycle uses two lightweight reads and no manifest downloads', () async {
    await sync.cycle();
    final before = api.calls.length;
    await sync.cycle(background: true);
    expect(GitHubSync.pollInterval, const Duration(seconds: 10));
    expect(api.calls.skip(before), [
      'GET /repos/team/data/git/ref/heads/main',
      'GET /repos/team/data/pulls',
    ]);
  });

  test(
    'all open PR pages are visible including the oldest held request',
    () async {
      for (var i = 0; i < 205; i++) {
        api.prs.add({
          'number': i + 1,
          'state': 'open',
          'html_url': 'https://github.com/team/data/pull/${i + 1}',
          'base': {'ref': 'main'},
          'head': {'ref': 'ieum/tasks/tester/t$i'},
        });
      }
      final requests = await publisher.openRequests(config);
      expect(requests, hasLength(205));
      expect(api.pages, ['1', '2', '3']);
      expect(requests.first['number'], 1);
    },
  );

  test(
    '1,001 task files import and only the IEUM subtree is traversed',
    () async {
      api.narrowTrees = true;
      for (var i = 0; i < 1001; i++) {
        final task = remote('T$i', '작업 $i');
        api.addMainProposal(proposal(task), task.id);
      }
      await sync.pullLatest();
      expect(store.tasks, hasLength(1001));
      expect(store.meta('github.pullRevision'), api.refs['main']);
      expect(api.calls.any((c) => c.endsWith('/large')), isFalse);
    },
  );

  test('malformed, oversized and invalid-version files quarantine only affected tasks', () async {
    api.inject('broken', '{');
    api.inject(
      'large',
      jsonEncode({
        ...proposal(remote('large', '대형')),
        'padding': 'x' * (1024 * 1024),
      }),
    );
    final poison = proposal(remote('poison', '범위 초과'));
    poison['changes'][0]['task'] = {
      ...poison['changes'][0]['task'],
      'version': 9223372036854775807,
    };
    api.inject('poison', jsonEncode(poison));
    api.addMainProposal(proposal(remote('healthy', '정상 작업')), 'healthy');
    await sync.pullLatest();
    expect(store.tasks.map((t) => t.id), ['healthy']);
    expect(jsonDecode(store.meta('github.quarantined')), hasLength(3));
    expect(sync.pullMessage, contains('3건'));
    final saved = store.save(fields('다른 정상 작업'));
    await idle(sync);
    expect(store.baseline[saved.id], isNotNull);
    expect(api.prs.last['merged'], isTrue);
  });

  test('a proposal for a quarantined task cannot use a missing base to overwrite it', () async {
    sync.setAutoMerge(false);
    final saved = store.save(fields('손상 작업'));
    await idle(sync);
    api.inject(saved.id, '{');
    final before = api.refs['main'];
    await expectLater(
      publisher.integrateTask(
        config,
        sync.jobs.single['prUrl'],
        projectId: store.project!.id,
        ownerId: store.project!.ownerId,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.refs['main'], before);
  });

  test(
    'manual approval uses the same author validation as automatic integration',
    () async {
      sync.setAutoMerge(false);
      store.save(fields('위조 검증'));
      await idle(sync);
      api.prs.single['user'] = {'id': 999, 'login': 'forged'};
      final reviewed = await publisher.review(
        config,
        sync.jobs.single['prUrl'],
      );
      final before = api.refs['main'];
      await expectLater(sync.approve(reviewed), throwsA(isA<GitHubFailure>()));
      expect(api.refs['main'], before);
      expect(api.prs.single['state'], 'open');
    },
  );

  test(
    'closed unmerged PR is resubmitted instead of remaining sent forever',
    () async {
      sync.setAutoMerge(false);
      store.save(fields('닫힌 요청 복구'));
      await idle(sync);
      api.prs.single['state'] = 'closed';
      await sync.cycle();
      await idle(sync);
      expect(api.prs, hasLength(2));
      expect(api.prs.last['state'], 'open');
      expect(sync.jobs.single['prUrl'], endsWith('/2'));
    },
  );

  test('lost PR creation response after peer merge reconciles failed queue from main', () async {
    api.loseCreatedAndMergedResponse = true;
    final saved = store.save(fields('불명확 응답 복구'));
    await idle(sync);
    expect(sync.jobs.single['state'], 'failed');
    await sync.cycle(retryFailed: true);
    await idle(sync);
    expect(sync.jobs.single['state'], 'merged');
    expect(store.baseline[saved.id], isNotNull);
    expect(api.prs, hasLength(1));
    expect(api.writes, 2); // Initial project manifest plus one task payload.
  });

  test('paused saves and legacy unqueued edits submit after synchronization resumes', () async {
    sync.disable();
    final task = store.save(fields('일시 중지 중 저장'));
    expect(sync.jobs.single['state'], 'pending');
    expect(api.prs, isEmpty);
    store.db.execute('DELETE FROM github_queue'); // Upgrade from pre-0.2 data.
    store.setMeta('github.config', jsonEncode(config.toJson()));
    await sync.cycle();
    await idle(sync);
    expect(store.baseline[task.id], isNotNull);
    expect(sync.jobs.single['state'], 'merged');
  });

  test('server retry delay blocks repeated requests and respects both header forms', () async {
    api.rateLimitOnce = true;
    await sync.cycle();
    final after = api.calls.length;
    await sync.cycle(retryFailed: true);
    expect(api.calls.length, after);
    expect(sync.retryAt, isNotNull);
    final now = DateTime.utc(2026, 10, 1);
    expect(
      githubRetryDelay(429, '45', null, null, now: now),
      const Duration(seconds: 45),
    );
    expect(
      githubRetryDelay(
        403,
        null,
        '0',
        '${now.millisecondsSinceEpoch ~/ 1000 + 60}',
        now: now,
      ),
      const Duration(seconds: 61),
    );
    expect(
      githubRetryDelay(
        403,
        'Thu, 01 Oct 2026 00:02:00 GMT',
        null,
        null,
        now: now,
      ),
      const Duration(minutes: 2),
    );
  });

  test(
    'failed task backs off without starving another healthy submission',
    () async {
      api.failTaskWrites = 1;
      final failed = store.save(fields('재시도 대기'));
      final healthy = store.save(fields('다음 정상 작업'));
      await idle(sync);
      final job = sync.jobs.singleWhere((j) => j['taskId'] == failed.id);
      expect(job['state'], 'failed');
      expect(DateTime.parse(job['retryAt']).isAfter(DateTime.now()), isTrue);
      expect(store.baseline[healthy.id], isNotNull);
      final writes = api.writes;
      await sync.cycle(retryFailed: true, background: true);
      expect(api.writes, writes);
      await sync.drain(retryFailed: true);
      await idle(sync);
      expect(store.baseline[failed.id], isNotNull);
    },
  );

  test(
    'prospective merge must preserve the exact validated task payload',
    () async {
      sync.setAutoMerge(false);
      store.save(fields('통합 결과 검증'));
      await idle(sync);
      final before = api.refs['main'];
      api.changeMergedPayload = true;
      await expectLater(
        publisher.integrateTask(
          config,
          sync.jobs.single['prUrl'],
          projectId: store.project!.id,
          ownerId: store.project!.ownerId,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.refs['main'], before);
      expect(api.prs.single['state'], 'open');
      expect(
        api.refs.keys.where((r) => r.startsWith('ieum/integrations/')),
        isEmpty,
      );
    },
  );

  test(
    'oversized outgoing proposal is rejected before any task content write',
    () async {
      sync.disable();
      store.save(fields('대형 변경안'));
      final job = Map<String, dynamic>.from(sync.jobs.single);
      job['proposal'] = {
        ...Map<String, dynamic>.from(job['proposal']),
        'padding': 'x' * (1024 * 1024),
      };
      final before = api.writes;
      await expectLater(
        publisher.publish(config, job),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, before);
      expect(api.prs, isEmpty);
    },
  );

  test(
    'accepting remote archives local conflict and closes the discarded task PR',
    () async {
      final saved = store.save(fields('처음 내용'));
      await idle(sync);
      sync.setAutoMerge(false);
      final local = store.find(saved.id);
      store.save({
        ...local.data,
        'title': '개인 수정',
      }, expectedVersion: local.version);
      await idle(sync);
      final remoteTask = store.baseline[saved.id]!.copy({
        'title': '통합된 수정',
        'version': 10,
      });
      api.addMainProposal(proposal(remoteTask), saved.id);
      await sync.pullLatest();
      expect(store.meta('github.pullConflicts'), isNotEmpty);
      await sync.acceptRemote(
        saved.id,
        expectedVersion: store.find(saved.id).version,
      );
      expect(store.find(saved.id).title, '통합된 수정');
      expect(api.prs.last['state'], 'closed');
      expect(sync.jobs, isEmpty);
      expect(store.db.select('SELECT * FROM conflict_backups'), hasLength(1));
      expect(store.meta('github.pullConflicts'), isEmpty);
    },
  );

  test(
    'accept remote fences a late integration that already observed the PR open',
    () async {
      final saved = store.save(fields('통합된 원본'));
      await idle(sync);
      sync.setAutoMerge(false);
      final local = store.find(saved.id);
      store.save({
        ...local.data,
        'title': '포기할 개인 수정',
      }, expectedVersion: local.version);
      await idle(sync);
      api.holdIntegrationRef = Completer<void>();
      api.integrationReady = Completer<void>();
      final inFlight = publisher.integrateTask(
        config,
        sync.jobs.single['prUrl'],
        projectId: store.project!.id,
        ownerId: store.project!.ownerId,
      );
      final rejected = expectLater(inFlight, throwsA(isA<GitHubFailure>()));
      await api.integrationReady!.future;
      await sync.acceptRemote(
        saved.id,
        expectedVersion: store.find(saved.id).version,
      );
      final fence = api.refs['main'];
      api.holdIntegrationRef!.complete();
      await rejected;
      expect(api.refs['main'], fence);
      expect(store.find(saved.id).title, '통합된 원본');
      expect(store.db.select('SELECT * FROM conflict_backups'), hasLength(1));
      expect(api.prs.last['state'], 'closed');
    },
  );

  test('switching during first import cancels remaining reads without accepting partial data', () async {
    for (var i = 0; i < 5; i++) {
      api.addMainProposal(proposal(remote('R$i', '원격 작업 $i')), 'R$i');
    }
    api.holdBlob = Completer<void>();
    api.blobReady = Completer<void>();
    final reading = sync.pullLatest();
    await api.blobReady!.future;
    final pausing = sync.quiesce();
    api.holdBlob!.complete();
    await Future.wait([reading, pausing]);
    expect(api.calls.where((c) => c.contains('/git/blobs/')), hasLength(1));
    expect(store.tasks, isEmpty);
    expect(store.meta('github.pullRevision'), isEmpty);
    sync.resume();
    await idle(sync);
    expect(store.tasks, hasLength(5));
  });

  test('quiesce finishes an in-flight write without starting a merge or touching a closed DB', () async {
    api.holdWrite = Completer<void>();
    store.save(fields('프로젝트 전환 중 전송'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    var stopped = false;
    final stop = sync.quiesce().then((_) => stopped = true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(stopped, isFalse);
    api.holdWrite!.complete();
    await stop;
    expect(sync.busy || sync.pulling, isFalse);
    expect(api.prs.single['state'], 'open');
    final count = api.calls.length;
    await sync.cycle();
    expect(api.calls.length, count);
    sync.resume();
    await idle(sync);
    expect(api.prs.single['merged'], isTrue);
  });
}
