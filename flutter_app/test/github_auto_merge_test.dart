import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi, idle;

// Models immutable commit trees and fast-forward ancestry, including the race
// after the client's last main read but before the ref update reaches GitHub.
class AutoMergeApi extends FakeGitHubApi {
  final snapshots = <String, Map<String, Map<String, dynamic>>>{'c0': {}};
  final parents = <String, List<String>>{'c0': []};
  final origins = <String, String>{'main': 'c0'};
  final commitOrigins = <String, String>{};
  bool advanceBeforeUpdate = false, protected = false, failAfterUpdate = false;
  void Function()? beforeRefUpdate;
  @override
  void addMainProposal(Map<String, dynamic> proposal, String taskId) {
    final previous = refs['main']!;
    super.addMainProposal(proposal, taskId);
    snapshots[refs['main']!] = Map.of(files['main']!);
    parents[refs['main']!] = [previous];
  }

  bool includes(String child, String ancestor) =>
      child == ancestor ||
      (parents[child] ?? []).any((p) => includes(p, ancestor));
  void capture(Map<String, String> previous) {
    for (final entry in refs.entries) {
      if (snapshots.containsKey(entry.value)) continue;
      snapshots[entry.value] = Map.of(files[entry.key]!);
      parents[entry.value] = [
        if (previous[entry.key] != null) previous[entry.key]!,
      ];
      commitOrigins[entry.value] = origins[entry.key] ?? 'c0';
    }
  }

  List<Map<String, dynamic>> changed(String base, String head) {
    final before = snapshots[commitOrigins[head] ?? base] ?? {};
    final after = snapshots[head]!;
    return [
      for (final entry in after.entries)
        if (before[entry.key]?['sha'] != entry.value['sha'])
          {
            'filename': entry.key,
            'status': before.containsKey(entry.key) ? 'modified' : 'added',
            'patch': '+ JSON',
          },
    ];
  }

  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    const root = '/repos/team/data';
    if (path == '$root/branches/main') {
      calls.add('$method $path');
      return {'protected': protected};
    }
    if (path.startsWith('$root/compare/')) {
      calls.add('$method $path');
      final parts = path.substring('$root/compare/'.length).split('...');
      return {'files': changed(parts[0], parts[1])};
    }
    if (method == 'GET' &&
        path.startsWith('$root/contents/') &&
        snapshots.containsKey(query?['ref'])) {
      calls.add('$method $path');
      final value =
          snapshots[query!['ref']]![path.substring('$root/contents/'.length)];
      if (value == null) throw const GitHubFailure('missing', 404);
      return value;
    }
    if (path == '$root/merges' &&
        (body?['base'] as String?)?.startsWith('ieum/integrations/') == true) {
      calls.add('$method $path');
      if (conflict) throw const GitHubFailure('Git 충돌', 409);
      final branch = body!['base'] as String, head = body['head'] as String;
      final previous = refs[branch]!;
      for (final change in changed(previous, head)) {
        files[branch]![change['filename']] =
            snapshots[head]![change['filename']]!;
      }
      final sha = 'integration${++serial}';
      refs[branch] = sha;
      snapshots[sha] = Map.of(files[branch]!);
      parents[sha] = [previous, head];
      return {'sha': sha};
    }
    if (path == '$root/git/refs/heads/main' && method == 'PATCH') {
      calls.add('$method $path');
      expect(body!['force'], isFalse);
      final callback = beforeRefUpdate;
      beforeRefUpdate = null;
      callback?.call();
      if (advanceBeforeUpdate) {
        advanceBeforeUpdate = false;
        final previous = refs['main']!, sha = 'concurrent${++serial}';
        refs['main'] = sha;
        snapshots[sha] = Map.of(files['main']!);
        parents[sha] = [previous];
      }
      final next = body['sha'] as String;
      if (!includes(next, refs['main']!)) {
        throw const GitHubFailure('main이 다른 클라이언트에서 변경되었습니다.', 422);
      }
      refs['main'] = next;
      files['main'] = Map.of(snapshots[next]!);
      for (final pr in prs) {
        if (includes(next, pr['head']['sha'])) {
          pr['state'] = 'closed';
          pr['merged'] = true;
        }
      }
      if (failAfterUpdate) {
        failAfterUpdate = false;
        throw const GitHubFailure('응답 유실');
      }
      return ref('main');
    }
    if (path.startsWith('$root/git/refs/heads/ieum/integrations/') &&
        method == 'DELETE') {
      calls.add('$method $path');
      final branch = path.substring('$root/git/refs/heads/'.length);
      refs.remove(branch);
      files.remove(branch);
      return null;
    }
    final previous = Map<String, String>.of(refs);
    final result = await super.call(method, path, query: query, body: body);
    if (path == '$root/git/refs' && method == 'POST') {
      origins[(body!['ref'] as String).substring('refs/heads/'.length)] =
          body['sha'];
    }
    if (path == '$root/merges') origins[body!['base']] = refs['main']!;
    capture(previous);
    return result;
  }
}

void main() {
  late AutoMergeApi api;
  late GitHubSession session;
  late TaskStore store;
  late GitHubSync sync;
  const config = GitHubConfig(repository: 'team/data', enabled: true);
  Map<String, dynamic> task(String title) => {
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
    api = AutoMergeApi();
    session = GitHubSession(api: api);
    await session.signIn(token: 'test-only');
    final project = await session.createProject(config, '자동 통합 테스트', '개설자');
    store = TaskStore(
      ':memory:',
      project: project,
      identity: session.named('개설자'),
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
  Future<WorkTask> staged(String title) async {
    sync.setAutoMerge(false);
    final saved = store.save(task(title));
    await idle(sync);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    return saved;
  }

  void rewrite(String branch, void Function(Map<String, dynamic>) edit) {
    final path = filesPath(branch);
    final file = api.files[branch]![path]!;
    final data = jsonDecode(
      utf8.decode(base64Decode(file['content'])),
    ) as Map<String, dynamic>;
    edit(data);
    final sha = 'rewritten${++api.serial}';
    final value = {
      'sha': sha,
      'encoding': 'base64',
      'content': base64Encode(utf8.encode(jsonEncode(data))),
    };
    api.files[branch]![path] = value;
    api.blobs[sha] = value;
    final previous = api.refs[branch]!;
    final head = 'rewrite${++api.serial}';
    api.refs[branch] = head;
    api.snapshots[head] = Map.of(api.files[branch]!);
    api.parents[head] = [previous];
    api.commitOrigins[head] = api.origins[branch]!;
    api.prs.single['head']['sha'] = head;
  }

  String branchOf(WorkTask value) => 'ieum/tasks/tester/${value.id}';

  test('normal task registration automatically integrates and imports without manager approval', () async {
    final saved = store.save(task('자동 통합'));
    await idle(sync);
    expect(api.prs.single['merged'], isTrue);
    expect(sync.jobs.single['state'], 'merged');
    expect(store.baseline[saved.id]!.title, '자동 통합');
    expect(
      api.refs.keys.where((r) => r.startsWith('ieum/integrations/')),
      isEmpty,
    );
    final current = store.find(saved.id);
    store.transition(saved.id, 'doing', expectedVersion: current.version);
    await idle(sync);
    expect(api.prs, hasLength(2));
    expect(store.baseline[saved.id]!.status, 'doing');
  });
  test(
    'manual toggle retains PRs, enabling resumes automatic integration',
    () async {
      sync.setAutoMerge(false);
      store.save(task('수동 대기'));
      await idle(sync);
      expect(api.prs.single['state'], 'open');
      sync.setAutoMerge(true);
      await idle(sync);
      expect(api.prs.single['merged'], isTrue);
    },
  );
  test('forged author cannot change main', () async {
    final value = await staged('기준 검증');
    final original = api.refs['main'];
    rewrite(branchOf(value), (data) => data['authorId'] = 'gh-999');
    await sync.cycle();
    expect(api.refs['main'], original);
    expect(sync.autoMergeErrors, isNotEmpty);
    expect(api.prs.single['state'], 'open');
  });
  test(
    'stale same-task proposal stays open when main already changed',
    () async {
      final value = store.save(task('최초 내용'));
      await idle(sync);
      sync.setAutoMerge(false);
      final current = store.find(value.id);
      store.save({
        ...current.data,
        'title': '오래된 기준의 수정',
      }, expectedVersion: current.version);
      await idle(sync);
      final base = store.baseline[value.id]!;
      final remote = base.copy({
        'title': '다른 사람이 먼저 반영한 수정',
        'version': base.version + 10,
      });
      api.addMainProposal({
        'schemaVersion': 1,
        'projectId': store.project!.id,
        'githubLogin': 'other',
        'changes': [
          {'task': remote.data},
        ],
      }, value.id);
      final original = api.refs['main'];
      store.setMeta('github.config', jsonEncode(config.toJson()));
      await sync.cycle();
      expect(api.refs['main'], original);
      expect(api.prs.last['state'], 'open');
      expect(sync.autoMergeErrors.values.single, contains('같은 작업'));
      expect(sync.pullMessage, contains('충돌'));
      expect(store.find(value.id).title, '오래된 기준의 수정');
    },
  );
  test('edit during integration preserves both submissions and rebases the newer edit', () async {
    api.beforeRefUpdate = () {
      final current = store.tasks.single;
      store.save({
        ...current.data,
        'description': '통합 중 추가한 내용',
      }, expectedVersion: current.version);
    };
    final value = store.save(task('연속 수정'));
    await idle(sync);
    expect(api.prs, hasLength(2));
    expect(api.prs.every((p) => p['merged'] == true), isTrue);
    expect(store.baseline[value.id]!.description, '통합 중 추가한 내용');
    expect(store.db.select('SELECT body FROM github_sent'), hasLength(2));
    expect(sync.jobs.single['state'], 'merged');
  });
  test('worker handoff and reviewer completion integrate with their own identities', () async {
    final worker = Person.fromJson({
      'id': 'gh-2',
      'name': '작업자',
      'login': 'worker',
      'role': 'worker',
      'parts': ['기획'],
    });
    final manifest = ProjectManifest(
      store.project!.id,
      store.project!.name,
      store.project!.ownerId,
      [...store.project!.people, worker],
    );
    final content = {
      'encoding': 'base64',
      'sha': 'manifest-worker',
      'content': base64Encode(utf8.encode(jsonEncode(manifest.json))),
    };
    api.files['main']!['.ieum/project.json'] = content;
    api.snapshots[api.refs['main']]!['.ieum/project.json'] = content;
    store.updateProject(manifest);
    final value = store.save({...task('담당자 연계'), 'assigneeId': worker.id});
    await idle(sync);
    api.identityId = 2;
    api.identityLogin = 'worker';
    final workerStore = TaskStore(
      ':memory:',
      project: manifest,
      identity: worker,
    );
    workerStore.setMeta('github.config', jsonEncode(config.toJson()));
    workerStore.setMeta('github.login', 'worker');
    final workerSync = GitHubSync(workerStore, publisher: GitHubPublisher(api));
    try {
      await workerSync.pullLatest();
      workerStore.transition(
        value.id,
        'doing',
        expectedVersion: workerStore.find(value.id).version,
      );
      await idle(workerSync);
      workerStore.transition(
        value.id,
        'review',
        expectedVersion: workerStore.find(value.id).version,
      );
      await idle(workerSync);
      expect(workerStore.baseline[value.id]!.status, 'review');
      expect(api.prs.every((p) => p['merged'] == true), isTrue);
      api.identityId = 1;
      api.identityLogin = 'tester';
      await sync.pullLatest();
      store.transition(
        value.id,
        'done',
        expectedVersion: store.find(value.id).version,
      );
      await idle(sync);
      expect(store.baseline[value.id]!.status, 'done');
      expect(store.baseline[value.id]!.completedDate, isNotEmpty);
    } finally {
      workerSync.dispose();
      workerStore.dispose();
    }
  });
  test('concurrent main advance after validation is rejected by fast-forward guard and retried', () async {
    await staged('동시 통합');
    api.advanceBeforeUpdate = true;
    await sync.cycle();
    expect(api.prs.single['state'], 'open');
    expect(sync.autoMergeErrors, isNotEmpty);
    expect(
      api.files['main']!.keys.where((p) => p.startsWith('.ieum/changes/')),
      isEmpty,
    );
    await sync.cycle();
    expect(api.prs.single['merged'], isTrue);
    expect(sync.autoMergeErrors, isEmpty);
  });
  test(
    'protected branch, Git conflicts and unexpected file leave PR pending',
    () async {
      await staged('보호 규칙');
      final original = api.refs['main'];
      api.protected = true;
      await sync.cycle();
      expect(api.refs['main'], original);
      api.protected = false;
      api.conflict = true;
      await sync.cycle();
      expect(api.refs['main'], original);
      api.conflict = false;
      api.extraFile = true;
      await sync.cycle();
      expect(api.refs['main'], original);
      expect(api.prs.single['state'], 'open');
      expect(
        api.refs.keys.where((r) => r.startsWith('ieum/integrations/')),
        isEmpty,
      );
    },
  );
  test('lost successful merge response is recovered from main without losing local changes', () async {
    final value = await staged('응답 복구');
    api.failAfterUpdate = true;
    await sync.cycle();
    expect(api.prs.single['merged'], isTrue);
    expect(store.baseline[value.id]!.title, '응답 복구');
    expect(sync.jobs.single['state'], 'merged');
    await sync.cycle();
    expect(sync.autoMergeErrors, isEmpty);
  });
  test(
    'draft tasks and membership PRs are not automatically approved',
    () async {
      await staged('초안');
      api.prs.single['draft'] = true;
      await sync.cycle();
      expect(api.prs.single['state'], 'open');
      expect(sync.autoMergeErrors.values.single, contains('초안'));
      api.prs.single['head']['ref'] = 'ieum/members/tester-gh-1';
      api.prs.single['draft'] = false;
      await sync.cycle();
      expect(api.prs.single['state'], 'open');
    },
  );
}

String filesPath(String branch) =>
    '.ieum/changes/tester/${branch.split('/').last}.json';
