import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/store.dart';

class FakeGitHubApi implements GitHubApi {
  final refs = <String, String>{'main': 'c0'};
  final files = <String, Map<String, Map<String, dynamic>>>{'main': {}};
  final blobs = <String, Map<String, dynamic>>{};
  final prs = <Map<String, dynamic>>[];
  final calls = <String>[];
  int writes = 0, serial = 0, identityId = 1;
  String identityLogin = 'tester';
  bool allowAdmin = true;
  final invitations = <String>[];
  bool failWrite = false, conflict = false, extraFile = false, allowPush = true;
  bool peerCreatesPr = false;
  Completer<void>? holdWrite;

  Map<String, dynamic> ref(String branch) {
    if (!refs.containsKey(branch)) throw const GitHubFailure('missing', 404);
    return {
      'object': {'sha': refs[branch]},
    };
  }

  void addMainProposal(Map<String, dynamic> proposal, String taskId) {
    final content = base64Encode(utf8.encode(jsonEncode(proposal)));
    final sha = 'blob${++serial}';
    files['main']!['.ieum/changes/other/$taskId.json'] = {
      'sha': sha,
      'content': content,
      'encoding': 'base64',
    };
    blobs[sha] = files['main']!['.ieum/changes/other/$taskId.json']!;
    refs['main'] = 'main${++serial}';
  }

  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    calls.add('$method $path');
    const root = '/repos/team/data';
    if (path == '/user') return {'login': identityLogin, 'id': identityId};
    if (path == root) {
      return {
        'permissions': {'push': allowPush, 'admin': allowAdmin},
      };
    }
    if (path.startsWith('$root/collaborators/') && method == 'PUT') {
      if (!allowAdmin) throw const GitHubFailure('no admin', 403);
      invitations.add(path.split('/').last);
      return {'id': invitations.length};
    }
    if (path.startsWith('$root/git/ref/heads/')) {
      return ref(path.substring('$root/git/ref/heads/'.length));
    }
    if (path == '$root/git/refs' && method == 'POST') {
      final branch = (body!['ref'] as String).substring('refs/heads/'.length);
      if (refs.containsKey(branch)) throw const GitHubFailure('exists', 422);
      if (refs.keys.any(
        (ref) => ref.startsWith('$branch/') || branch.startsWith('$ref/'),
      )) {
        throw const GitHubFailure('reference prefix conflict', 422);
      }
      refs[branch] = body['sha'] as String;
      files[branch] = Map.of(files['main']!);
      return ref(branch);
    }
    if (path == '$root/merges') {
      if (conflict) throw const GitHubFailure('conflict', 409);
      files[body!['base']]!.addAll(files['main']!);
      return null;
    }
    if (path.startsWith('$root/contents/')) {
      final filename = path.substring('$root/contents/'.length);
      var branch = method == 'GET' ? query!['ref']! : body!['branch'] as String;
      if (!files.containsKey(branch)) {
        branch = refs.entries.firstWhere((entry) => entry.value == branch).key;
      }
      if (method == 'GET') {
        if (!files[branch]!.containsKey(filename)) {
          throw const GitHubFailure('missing', 404);
        }
        return files[branch]![filename];
      }
      if (failWrite) throw const GitHubFailure('offline');
      if (files[branch]!.containsKey(filename) &&
          files[branch]![filename]!['sha'] != body!['sha']) {
        throw const GitHubFailure('sha changed', 409);
      }
      if (holdWrite != null) await holdWrite!.future;
      writes++;
      final sha = 'blob${++serial}';
      files[branch]![filename] = {
        'sha': sha,
        'content': body!['content'],
        'encoding': 'base64',
      };
      blobs[sha] = files[branch]![filename]!;
      refs[branch] = 'c${++serial}';
      for (final pr in prs.where((pr) => pr['head']['ref'] == branch)) {
        pr['head']['sha'] = refs[branch];
      }
      return {
        'commit': {'sha': refs[branch]},
      };
    }
    if (path == '$root/pulls') {
      if (method == 'GET') {
        return prs
            .where(
              (pr) =>
                  pr['state'] == 'open' &&
                  (query?['head'] == null ||
                      'team:${pr['head']['ref']}' == query!['head']) &&
                  (query?['base'] == null ||
                      pr['base']['ref'] == query!['base']),
            )
            .toList();
      }
      final pr = <String, dynamic>{
        'number': prs.length + 1,
        'title': body!['title'],
        'html_url': 'https://github.com/team/data/pull/${prs.length + 1}',
        'state': 'open',
        'user': {'id': identityId, 'login': identityLogin},
        'base': {'ref': body['base']},
        'head': {
          'ref': body['head'],
          'sha': refs[body['head']],
          'repo': {'full_name': 'team/data'},
        },
        'changed_files': 1,
      };
      prs.add(pr);
      if (peerCreatesPr) {
        peerCreatesPr = false;
        throw const GitHubFailure('peer already created PR', 422);
      }
      return pr;
    }
    if (path.startsWith('$root/pulls/')) {
      final parts = path.substring('$root/pulls/'.length).split('/');
      final pr = prs[int.parse(parts.first) - 1];
      if (parts.length == 1) {
        if (method == 'PATCH') pr['state'] = body!['state'];
        pr['changed_files'] = extraFile ? 2 : 1;
        return pr;
      }
      if (parts.last == 'files') {
        final branch = pr['head']['ref'];
        final filename = files[branch]!.keys.last;
        return [
          {'filename': filename, 'status': 'added', 'patch': '+ task JSON'},
          if (extraFile)
            {'filename': 'app.exe', 'status': 'added', 'patch': '+ unwanted'},
        ];
      }
      if (parts.last == 'merge') {
        if (body!['sha'] != pr['head']['sha']) {
          throw const GitHubFailure('head changed', 409);
        }
        pr['state'] = 'closed';
        files['main']!.addAll(files[pr['head']['ref']]!);
        refs['main'] = 'merged${++serial}';
        return {'merged': true};
      }
    }
    if (path.startsWith('$root/git/commits/')) {
      return {
        'tree': {'sha': 'tree-main'},
      };
    }
    if (path.startsWith('$root/git/trees/')) {
      return {
        'truncated': false,
        'tree': files['main']!.entries
            .map(
              (entry) => {
                'type': 'blob',
                'path': entry.key,
                'sha': entry.value['sha'],
                'size': 300,
              },
            )
            .toList(),
      };
    }
    if (path.startsWith('$root/git/blobs/')) return blobs[path.split('/').last];
    throw StateError('Unexpected request: $method $path');
  }
}

Map<String, dynamic> newTask(String title) => {
  'title': title,
  'part': '기획',
  'priority': 'normal',
  'assigneeId': 'planner',
  'reviewerId': 'pm',
  'assignedDate': '2026-10-01',
  'dueDate': '2026-10-12',
  'description': '',
};

Future<void> idle(GitHubSync sync) async {
  for (var i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (!sync.busy &&
        !sync.pulling &&
        !sync.jobs.any(
          (j) => j['state'] == 'pending' || j['state'] == 'sending',
        )) {
      return;
    }
  }
  throw StateError('Sync did not become idle');
}

void main() {
  final seed =
      jsonDecode(File('assets/demo-snapshot.json').readAsStringSync())['tasks']
          as List;
  const config = GitHubConfig(repository: 'team/data', enabled: true);
  late TaskStore store;
  late FakeGitHubApi api;
  late GitHubPublisher publisher;
  late GitHubSync sync;

  setUp(() {
    store = TaskStore(':memory:', seed: seed);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'tester');
    api = FakeGitHubApi();
    publisher = GitHubPublisher(api);
    sync = GitHubSync(store, publisher: publisher);
  });
  tearDown(() {
    sync.dispose();
    store.dispose();
  });

  test('two registered tasks create separate branches and PRs without exporting DB', () async {
    final first = store.save(newTask('첫 작업'));
    final second = store.save(newTask('둘째 작업'));
    await idle(sync);
    expect(api.prs, hasLength(2));
    expect(api.prs.map((pr) => pr['head']['ref']).toSet(), {
      'ieum/tasks/tester/${first.id}',
      'ieum/tasks/tester/${second.id}',
    });
    expect(sync.jobs.every((job) => job['state'] == 'sent'), isTrue);
    expect(
      api.files.values
          .expand((value) => value.keys)
          .every((p) => p.endsWith('.json')),
      isTrue,
    );
  });

  test('new task creates PR directly without redundant PR discovery', () async {
    final task = store.save(newTask('빠른 제출'));
    await idle(sync);
    expect(api.prs, hasLength(1));
    expect(
      api.calls.where((call) => call == 'GET /repos/team/data/pulls'),
      isEmpty,
    );
    expect(
      api.calls.where(
        (call) => call == 'GET /repos/team/data/git/ref/heads/main',
      ),
      hasLength(1),
    );
    expect(
      api.calls.where((call) => call == 'POST /repos/team/data/merges'),
      isEmpty,
    );
    final before = api.calls.length;
    store.save({
      ...task.data,
      'title': '수정된 제출',
    }, expectedVersion: task.version);
    await idle(sync);
    expect(api.prs, hasLength(1));
    expect(api.calls.skip(before), contains('GET /repos/team/data/pulls'));
  });

  test(
    'existing branch at current main needs no merge before submission',
    () async {
      sync.disable();
      final task = store.save(newTask('같은 기준본'));
      final branch = 'ieum/tasks/tester/${task.id}';
      api.refs[branch] = api.refs['main']!;
      api.files[branch] = Map.of(api.files['main']!);
      final receipt = await publisher.publish(config, sync.jobs.single);
      expect(receipt.request?['head']['ref'], branch);
      expect(api.calls, isNot(contains('POST /repos/team/data/merges')));
    },
  );

  test('peer creating a PR on the new branch recovers without duplicate submission', () async {
    api.peerCreatesPr = true;
    store.save(newTask('다른 앱과 동시 제출'));
    await idle(sync);
    expect(api.prs, hasLength(1));
    expect(api.writes, 1);
    expect(sync.jobs.single['state'], 'sent');
    expect(sync.jobs.single['prUrl'], api.prs.single['html_url']);
  });

  test('uncertain response retry reuses commit and PR; state changes update same task PR', () async {
    final task = store.save(newTask('재시도'));
    await idle(sync);
    final job = Map<String, dynamic>.from(sync.jobs.single);
    final initialWrites = api.writes;
    final receipt = await publisher.publish(config, job);
    expect(receipt.prUrl, job['prUrl']);
    expect(api.writes, initialWrites);
    expect(api.prs, hasLength(1));
    store.transition(task.id, 'doing', expectedVersion: task.version);
    await idle(sync);
    expect(api.prs, hasLength(1));
    expect(api.writes, initialWrites + 1);
    expect(
      sync.jobs.single['proposal']['changes'].single['task']['status'],
      'doing',
    );
  });

  test('reverting to the baseline replaces the earlier PR proposal', () async {
    store.setProfile('pm');
    final original = store.find('IE-101');
    final edited = store.save({
      ...original.data,
      'title': '잠시 바꾼 제목',
    }, expectedVersion: original.version);
    await idle(sync);
    store.save({
      ...edited.data,
      'title': original.title,
    }, expectedVersion: edited.version);
    await idle(sync);
    expect(
      store.changes.where((change) => change['taskId'] == original.id),
      isEmpty,
    );
    expect(
      sync.jobs.single['proposal']['changes'].single['task']['title'],
      original.title,
    );
    final file = api.files['ieum/tasks/tester/${original.id}']!.values.single;
    final payload = jsonDecode(utf8.decode(base64Decode(file['content'])));
    expect(payload['changes'].single['task']['title'], original.title);
    expect(api.prs, hasLength(1));
  });

  test('failed commit preserves local task and retries; disabling prevents submissions', () async {
    api.failWrite = true;
    final task = store.save(newTask('오프라인'));
    await idle(sync);
    expect(store.find(task.id).title, '오프라인');
    expect(sync.jobs.single['state'], 'failed');
    expect(api.prs, isEmpty);
    api.failWrite = false;
    await sync.drain(retryFailed: true);
    expect(sync.jobs.single['state'], 'sent');
    sync.disable();
    store.save(newTask('로컬만'));
    expect(sync.jobs, hasLength(2));
  });

  test(
    'a newer edit while publishing is not overwritten by older completion',
    () async {
      api.holdWrite = Completer<void>();
      final task = store.save(newTask('처음 제목'));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      store.save({
        ...task.data,
        'title': '새 제목',
      }, expectedVersion: task.version);
      api.holdWrite!.complete();
      await idle(sync);
      expect(
        sync.jobs.single['proposal']['changes'].single['task']['title'],
        '새 제목',
      );
      expect(sync.jobs.single['state'], 'sent');
      expect(api.prs, hasLength(1));
      final file = api.files['ieum/tasks/tester/${task.id}']!.values.single;
      final proposal = jsonDecode(utf8.decode(base64Decode(file['content'])));
      expect(proposal['changes'].single['task']['title'], '새 제목');
    },
  );

  test(
    'app approval merges reviewed head and automatically imports main',
    () async {
      final task = store.save(newTask('승인할 작업'));
      await idle(sync);
      final review = await publisher.review(config, sync.jobs.single['prUrl']);
      await sync.approve(review);
      expect(api.prs.single['state'], 'closed');
      expect(store.baseline.containsKey(task.id), isTrue);
      expect(sync.jobs.single['state'], 'merged');
      expect(
        store.changes.where((change) => change['taskId'] == task.id),
        isEmpty,
      );
    },
  );

  test(
    'approval rejects extra files and a head changed after review',
    () async {
      store.save(newTask('검토 검증'));
      await idle(sync);
      api.extraFile = true;
      await expectLater(
        publisher.review(config, sync.jobs.single['prUrl']),
        throwsA(isA<GitHubFailure>()),
      );
      api.extraFile = false;
      final review = await publisher.review(config, sync.jobs.single['prUrl']);
      api.prs.single['head']['sha'] = 'someone-else-changed-head';
      await expectLater(
        publisher.approve(config, review),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.prs.single['state'], 'open');
    },
  );

  test('automatic pull isolates conflicting local edits and records remote revision', () async {
    sync.dispose();
    final original = store.find('IE-101');
    store.setProfile('pm');
    store.save({
      ...original.data,
      'title': '개인 제목',
    }, expectedVersion: original.version);
    final remote = original.copy({
      'title': '팀 제목',
      'version': original.version + 1,
    });
    api.addMainProposal({
      'schemaVersion': 1,
      'projectId': 'ieum-demo',
      'changes': [
        {'task': remote.data},
      ],
    }, remote.id);
    sync = GitHubSync(store, publisher: publisher);
    await sync.pullLatest();
    expect(store.find(original.id).title, '개인 제목');
    expect(store.baseline[original.id]!.title, original.title);
    expect(sync.pullMessage, contains('충돌'));
    expect(store.meta('github.pullRevision'), isNotEmpty);
    expect(store.meta('github.pullConflicts'), isNotEmpty);
  });

  test(
    'submission queue survives reopening and stores no session token',
    () async {
      final folder = Directory.systemTemp.createTempSync('ieum-github-');
      final local = TaskStore('${folder.path}/tasks.sqlite', seed: seed);
      final service = GitHubSync(local, publisher: publisher);
      try {
        await service.connect(config, token: 'test-session-secret');
        await idle(service);
        api.failWrite = true;
        local.save(newTask('재시작 대기'));
        await idle(service);
        expect(service.jobs.single['state'], 'failed');
        expect(
          local.db
              .select('SELECT value FROM metadata')
              .any(
                (row) =>
                    (row['value'] as String).contains('test-session-secret'),
              ),
          isFalse,
        );
        service.dispose();
        local.dispose();
        final reopened = TaskStore('${folder.path}/tasks.sqlite');
        final resumed = GitHubSync(reopened, publisher: publisher);
        try {
          api.failWrite = false;
          await resumed.drain(retryFailed: true);
          expect(resumed.jobs.single['state'], 'sent');
        } finally {
          resumed.dispose();
          reopened.dispose();
        }
      } finally {
        folder.deleteSync(recursive: true);
      }
    },
  );

  test('invalid branch, main-as-head, wrong identity and repository changes stop submission', () async {
    expect(
      () => const GitHubConfig(
        repository: 'team/data',
        branch: 'main',
      ).validate(),
      throwsStateError,
    );
    expect(
      () => const GitHubConfig(
        repository: 'team/data',
        base: '../main',
      ).validate(),
      throwsStateError,
    );
    store.save(newTask('대상 검증'));
    await idle(sync);
    final job = Map<String, dynamic>.from(sync.jobs.single);
    await expectLater(
      publisher.publish(config, {...job, 'githubLogin': 'another-user'}),
      throwsA(isA<GitHubFailure>()),
    );
    api.allowPush = false;
    await expectLater(publisher.check(config), throwsA(isA<GitHubFailure>()));
    expect(api.prs, hasLength(1));
  });
}
