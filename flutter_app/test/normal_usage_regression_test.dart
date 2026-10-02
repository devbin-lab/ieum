import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;

class CountingApi extends AutoMergeApi {
  @override
  bool includes(String child, String ancestor) {
    final pending = <String>[child], visited = <String>{};
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      if (next == ancestor) return true;
      if (visited.add(next)) pending.addAll(parents[next] ?? const []);
    }
    return false;
  }
}

class CanonicalCaseApi extends CountingApi {
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    // GitHub accepts repository parameter casing and returns canonical URLs.
    final result = await super.call(
      method,
      path.replaceFirst(
        RegExp(r'^/repos/team/data', caseSensitive: false),
        '/repos/team/data',
      ),
      query: query,
      body: body,
    );
    // The stored repository name may itself use capital letters.
    for (final pr in prs) {
      pr['html_url'] = (pr['html_url'] as String).replaceFirst(
        '/team/data/',
        '/team/Data/',
      );
      pr['head']['repo']['full_name'] = 'team/Data';
    }
    return result;
  }
}

class SetupApi extends CountingApi {
  String defaultBranch = 'main';
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    const root = '/repos/team/data';
    if (path == root) {
      final repo = await super.call(method, path, query: query, body: body);
      return {
        ...repo as Map,
        'default_branch': defaultBranch,
        'full_name': 'team/Data',
      };
    }
    if (path == '$root/branches') {
      return refs.keys.map((branch) => {'name': branch}).toList();
    }
    if (path.startsWith('$root/contents/') && refs.isEmpty) {
      if (method == 'GET') throw const GitHubFailure('empty repository', 404);
      expect(
        body!.containsKey('branch'),
        isFalse,
        reason: 'The first commit must initialize GitHub\'s default branch.',
      );
      refs[defaultBranch] = 'c0';
      files[defaultBranch] = {};
      body = {...body, 'branch': defaultBranch};
    }
    return super.call(method, path, query: query, body: body);
  }
}

Map<String, dynamic> input(String title) => {
  'title': title,
  'part': '기획',
  'priority': 'normal',
  'assigneeId': 'gh-1',
  'reviewerId': 'gh-1',
  'assignedDate': '2026-10-03',
  'dueDate': '',
  'description': '',
};

Future<(GitHubSession, TaskStore, GitHubSync)> setup(
  AutoMergeApi api,
  GitHubConfig config,
) async {
  final session = GitHubSession(api: api);
  await session.signIn(token: 'audit-fake-token');
  final manifest = await session.createProject(config, '정상 사용 시험', '개설자');
  final store = TaskStore(
    ':memory:',
    project: manifest,
    identity: session.named('개설자'),
  );
  store.setMeta('github.config', jsonEncode(config.toJson()));
  store.setMeta('github.login', 'tester');
  final sync = GitHubSync(store, publisher: GitHubPublisher(api));
  return (session, store, sync);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const normal = GitHubConfig(repository: 'team/data', enabled: true);

  test('repository normalization preserves branch casing', () {
    const config = GitHubConfig(
      repository: 'HTTPS://GitHub.com/Team/Data.GIT/',
      base: 'Release/Stable',
    );
    expect(config.slug, 'team/data');
    expect(config.base, 'Release/Stable');
    config.validate();
  });

  test('empty repositories initialize the actual default branch', () async {
    final api = SetupApi()..defaultBranch = 'master';
    api.refs.clear();
    api.files.clear();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    await session.signIn(token: 'audit-fake-token');
    final config = await session.resolveRepository(normal);
    expect(config.base, 'master');
    await session.createProject(config, '빈 저장소', '개설자');
    expect(api.refs.keys, ['master']);
    expect((await session.loadProject(config)).people.single.id, 'gh-1');
  });

  test('a missing explicit branch in an existing repository does not create another project', () async {
    final api = SetupApi()..defaultBranch = 'master';
    api.refs['master'] = api.refs.remove('main')!;
    api.files['master'] = api.files.remove('main')!;
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    await session.signIn(token: 'audit-fake-token');
    await expectLater(
      session.createProject(normal, '잘못된 기준 브랜치', '개설자'),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, 0);
  });

  test('30 ordinary registrations and 360 idle poll ticks complete', () async {
    final api = CountingApi();
    final (session, store, sync) = await setup(api, normal);
    addTearDown(() {
      sync.dispose();
      store.dispose();
      session.signOut();
    });
    api.calls.clear();
    for (var i = 0; i < 30; i++) {
      store.save(input('정상 작업 ${i + 1}'));
      await idle(sync);
      for (var tick = 0; tick < 12; tick++) {
        await sync.cycle(retryFailed: true, background: true);
      }
    }
    expect(api.calls.length, lessThan(5000));
    expect(store.tasks, hasLength(30));
    expect(api.prs, hasLength(30));
    expect(api.prs.every((p) => p['merged'] == true), isTrue);
    expect(sync.jobs.every((j) => j['state'] == 'merged'), isTrue);
    expect(sync.autoMergeErrors, isEmpty);
  });

  test('valid repository casing must not prevent task integration', () async {
    final api = CanonicalCaseApi();
    const mixed = GitHubConfig(repository: 'team/Data', enabled: true);
    final (session, store, sync) = await setup(api, mixed);
    addTearDown(() {
      sync.dispose();
      store.dispose();
      session.signOut();
    });
    store.save(input('대소문자 입력 시험'));
    await idle(sync);
    for (var i = 0; i < 3; i++) {
      await sync.cycle(retryFailed: true);
    }
    expect(
      api.prs.single['merged'],
      isTrue,
      reason: 'A valid case variation in the repository field must still integrate the app-created PR.',
    );
  });

  test(
    '30 ordinary offline registrations resume and integrate after reconnect',
    () async {
      final api = CountingApi();
      final (session, store, sync) = await setup(api, normal);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        session.signOut();
      });
      store.setMeta(
        'github.config',
        jsonEncode({...normal.toJson(), 'enabled': false}),
      );
      for (var i = 0; i < 30; i++) {
        store.save(input('오프라인 정상 작업 ${i + 1}'));
      }
      await sync.connect(normal);
      await idle(sync);
      await sync.cycle(retryFailed: true);
      expect(store.tasks, hasLength(30));
      expect(api.prs, hasLength(30));
      expect(sync.jobs.every((job) => job['state'] == 'merged'), isTrue);
      expect(sync.autoMergeErrors, isEmpty);
    },
  );

  test('valid repository casing must not hide app-created membership requests', () async {
    final api = CanonicalCaseApi();
    const mixed = GitHubConfig(repository: 'team/Data', enabled: true);
    final (session, store, sync) = await setup(api, mixed);
    addTearDown(() {
      sync.dispose();
      store.dispose();
      session.signOut();
    });
    api.identityId = 2;
    api.identityLogin = 'worker';
    await session.signIn(token: 'audit-fake-token');
    await session.register(mixed, store.project!, '정상 참여자');
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.signIn(token: 'audit-fake-token');
    final requests = await session.requests(mixed);
    expect(
      requests,
      hasLength(1),
      reason:
          'Canonical repository casing must not silently hide valid requests.',
    );
  });

  test(
    'new empty repository should have a supported project creation path',
    () async {
      final api = SetupApi();
      api.refs.clear();
      api.files.clear();
      final session = GitHubSession(api: api);
      addTearDown(session.signOut);
      await session.signIn(token: 'audit-fake-token');
      Object? error;
      try {
        await session.createProject(normal, '첫 프로젝트', '개설자');
      } catch (e) {
        error = e;
      }
      expect(
        error,
        isNull,
        reason: 'The setup screen accepts this repository without offering initialization guidance.',
      );
      expect(api.files['main']!.keys, ['.ieum/project.json']);
      expect((await session.loadProject(normal)).people.single.id, 'gh-1');
    },
  );

  test(
    'repository default branch master should have a usable setup path',
    () async {
      final api = SetupApi()..defaultBranch = 'master';
      api.refs.remove('main');
      api.refs['master'] = 'c0';
      api.files['master'] = api.files.remove('main')!;
      final session = GitHubSession(api: api);
      addTearDown(session.signOut);
      await session.signIn(token: 'audit-fake-token');
      Object? error;
      final resolved = await session.resolveRepository(normal);
      expect(resolved.base, 'master');
      try {
        await session.createProject(resolved, '첫 프로젝트', '개설자');
      } catch (e) {
        error = e;
      }
      expect(
        error,
        isNull,
        reason: 'The ordinary project form offers no base-branch selection or automatic detection.',
      );
      expect((await session.loadProject(resolved)).people.single.id, 'gh-1');
    },
  );

  test(
    'same numeric GitHub account after username change must resume saved queue',
    () async {
      final api = CountingApi();
      final (session, store, sync) = await setup(api, normal);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        session.signOut();
      });
      store.setMeta(
        'github.config',
        jsonEncode({...normal.toJson(), 'enabled': false}),
      );
      store.save(input('이름 변경 전 저장된 정상 작업'));
      api.identityLogin = 'new-login';
      await sync.connect(normal);
      await idle(sync);
      await sync.cycle(retryFailed: true);
      expect(
        sync.jobs.single['state'],
        'merged',
        reason: 'Numeric identity is unchanged; ordinary reconnect should resume the queue.',
      );
    },
  );

  test(
    'ordinary complete rework workflow and offline content editing converge',
    () async {
      final api = CountingApi();
      final (session, store, sync) = await setup(api, normal);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        session.signOut();
      });
      final saved = store.save(input('재작업 흐름'));
      await idle(sync);
      void move(String status, {String reason = ''}) => store.transition(
        saved.id,
        status,
        reason: reason,
        expectedVersion: store.find(saved.id).version,
      );
      move('doing');
      await idle(sync);
      move('review');
      await idle(sync);
      move('rework', reason: '일반 검토 의견');
      await idle(sync);
      store.setMeta(
        'github.config',
        jsonEncode({...normal.toJson(), 'enabled': false}),
      );
      move('doing');
      final current = store.find(saved.id);
      store.save({
        ...current.data,
        'description': '오프라인에서 정상 수정',
      }, expectedVersion: current.version);
      move('review');
      await sync.connect(normal);
      await idle(sync);
      move('done');
      await idle(sync);
      expect(store.baseline[saved.id]!.status, 'done');
      expect(store.baseline[saved.id]!.description, '오프라인에서 정상 수정');
      expect(sync.jobs.single['state'], 'merged');
    },
  );

  test(
    'same GitHub account can integrate its PR opened before a username change',
    () async {
      final api = CountingApi();
      final (session, store, sync) = await setup(api, normal);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        session.signOut();
      });
      sync.setAutoMerge(false);
      store.save(input('이름 변경 전 열린 PR'));
      await idle(sync);
      expect(sync.jobs.single['state'], 'sent');
      api.identityLogin = 'new-login';
      api.prs.single['user']['login'] = 'new-login';
      await sync.connect(normal);
      await idle(sync);
      await sync.cycle(retryFailed: true);
      expect(sync.jobs.single['state'], 'merged');
      expect(sync.autoMergeErrors, isEmpty);
    },
  );

  test('username changes do not discard pending membership requests', () async {
    final api = CountingApi();
    final (session, store, sync) = await setup(api, normal);
    addTearDown(() {
      sync.dispose();
      store.dispose();
      session.signOut();
    });
    api.identityId = 2;
    api.identityLogin = 'worker';
    await session.signIn(token: 'audit-fake-token');
    await session.register(normal, store.project!, '참여자');
    api.prs.single['user']['login'] = 'new-worker';
    api.identityId = 1;
    api.identityLogin = 'tester';
    await session.signIn(token: 'audit-fake-token');
    final requests = await session.requests(normal);
    expect(requests, hasLength(1));
    expect(requests.single['member']['id'], 'gh-2');
    expect(requests.single['member']['login'], 'new-worker');
    final person = Person.fromJson({
      ...requests.single['member'] as Map<String, dynamic>,
      'role': 'worker',
    });
    final updated = await session.assign(
      normal,
      person,
      request: requests.single,
    );
    expect(
      updated.people.singleWhere((p) => p.id == 'gh-2').login,
      'new-worker',
    );
  });

  test(
    'a different numeric GitHub account cannot publish a saved project queue',
    () async {
      final api = CountingApi();
      final (session, store, sync) = await setup(api, normal);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        session.signOut();
      });
      store.setMeta(
        'github.config',
        jsonEncode({...normal.toJson(), 'enabled': false}),
      );
      store.save(input('원래 계정 작업'));
      api.identityId = 2;
      await expectLater(
        GitHubPublisher(api).publish(normal, sync.jobs.single),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.prs, isEmpty);
    },
  );

  test(
    'an old mixed-case repository queue keeps working after an app update',
    () async {
      final api = CanonicalCaseApi();
      final (session, store, sync) = await setup(api, normal);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        session.signOut();
      });
      store.setMeta(
        'github.config',
        jsonEncode({...normal.toJson(), 'enabled': false}),
      );
      store.save(input('이전 버전 대기열'));
      // A valid queue produced by 0.3.0 retains the original input casing.
      final legacy = {
        ...sync.jobs.single,
        'repository': 'Team/Data',
        'configuration': {...normal.toJson(), 'repository': 'Team/Data'},
      };
      store.db.execute('UPDATE github_queue SET body=? WHERE id=?', [
        jsonEncode(legacy),
        legacy['taskId'],
      ]);
      await sync.connect(normal);
      await idle(sync);
      expect(sync.jobs.single['state'], 'merged');
      expect(sync.autoMergeErrors, isEmpty);
    },
  );
}
