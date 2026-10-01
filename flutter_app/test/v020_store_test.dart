import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

const owner = Person('gh-1', '개설자', '개', 'owner', 0, login: 'owner');
const worker = Person('gh-2', '기획자', '기', 'worker', 0, login: 'worker');
const reviewer = Person('gh-3', '검토자', '검', 'worker', 0, login: 'reviewer');
const project = ProjectManifest('project-v020', '테스트', 'gh-1', [
  owner,
  worker,
  reviewer,
]);

Map<String, dynamic> draft({String title = '작업', String reviewerId = 'gh-3'}) =>
    {
      'title': title,
      'part': '기획',
      'assigneeId': worker.id,
      'reviewerId': reviewerId,
      'priority': 'normal',
      'assignedDate': '2026-10-01',
      'dueDate': '',
      'description': '',
    };

Map<String, dynamic> snapshot(
  Iterable<WorkTask> tasks, [
  String revision = 'main-2',
]) => {
  'schemaVersion': 1,
  'projectId': project.id,
  'revision': revision,
  'tasks': tasks.map((task) => task.data).toList(),
};

class InterleavedStore extends TaskStore {
  InterleavedStore(super.path) : super(project: project, identity: owner);
  void Function()? beforeTransaction;
  @override
  T transaction<T>(T Function() work) {
    final hook = beforeTransaction;
    beforeTransaction = null;
    hook?.call();
    return super.transaction(work);
  }
}

void main() {
  late TaskStore store;
  setUp(() => store = TaskStore(':memory:', project: project, identity: owner));
  tearDown(() => store.dispose());

  void move(String id, String state, {String reason = ''}) => store.transition(
    id,
    state,
    reason: reason,
    expectedVersion: store.find(id).version,
  );

  test('review locks submitted content, rejection unlocks worker, done locks everyone', () {
    final created = store.save(draft());
    store.setMeta('profile', worker.id);
    move(created.id, 'doing');
    move(created.id, 'review');
    final reviewing = store.find(created.id);
    expect(store.canEdit(reviewing), isFalse);
    expect(
      () => store.save({
        ...reviewing.data,
        'title': '검토 중 변경',
      }, expectedVersion: reviewing.version),
      throwsStateError,
    );
    expect(() => move(created.id, 'done'), throwsStateError);

    store.setMeta('profile', owner.id);
    expect(store.canEdit(reviewing), isTrue);
    expect(store.canEditContent(reviewing), isFalse);
    expect(
      () => store.save({
        ...reviewing.data,
        'description': '관리자 내용 변경',
      }, expectedVersion: reviewing.version),
      throwsStateError,
    );
    final reassigned = store.save({
      ...reviewing.data,
      'dueDate': '2026-10-07',
    }, expectedVersion: reviewing.version);
    expect(reassigned.status, 'review');

    store.setMeta('profile', reviewer.id);
    move(created.id, 'rework', reason: '내용 보완');
    store.setMeta('profile', worker.id);
    final rejected = store.find(created.id);
    expect(store.canEditContent(rejected), isTrue);
    store.save({
      ...rejected.data,
      'description': '보완 완료',
    }, expectedVersion: rejected.version);
    move(created.id, 'doing');
    move(created.id, 'review');
    store.setMeta('profile', reviewer.id);
    move(created.id, 'done');
    final completed = store.find(created.id);
    for (final actor in [worker, reviewer, owner]) {
      store.setMeta('profile', actor.id);
      expect(store.canEdit(completed), isFalse);
      expect(store.canMove(completed, 'doing'), isFalse);
      expect(
        () => store.save({
          ...completed.data,
          'title': '완료 후 변경',
        }, expectedVersion: completed.version),
        throwsStateError,
      );
    }
    expect(store.find(created.id).description, '보완 완료');
  });

  test('collapsed offline transitions require every intermediate role', () {
    final original = store.save(draft());
    final submitted = original.copy({'status': 'review', 'version': 3});
    expect(
      () => validateTaskMutation(
        actor: worker,
        current: original,
        next: submitted,
        allowCollapsedTransitions: true,
      ),
      returnsNormally,
    );
    final completed = original.copy({
      'status': 'done',
      'completedDate': '2026-10-01',
      'version': 4,
    });
    expect(
      () => validateTaskMutation(
        actor: worker,
        current: original,
        next: completed,
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
    expect(
      () => validateTaskMutation(
        actor: reviewer,
        current: original,
        next: completed,
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
    final selfReviewed = original.copy({'reviewerId': worker.id});
    expect(
      () => validateTaskMutation(
        actor: worker,
        current: selfReviewed,
        next: completed.copy({'reviewerId': worker.id}),
        allowCollapsedTransitions: true,
      ),
      returnsNormally,
    );
    expect(
      () => validateTaskMutation(
        actor: reviewer,
        current: submitted,
        next: completed.copy({'description': '검토자의 제출 내용 변경'}),
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
    expect(
      () => validateTaskMutation(
        actor: owner,
        current: submitted,
        next: submitted.copy({'description': '동일 단계 수정', 'version': 4}),
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
  });

  test(
    'revision and payload limits reject unknown fields and oversized counters',
    () {
      final task = store.save(draft());
      for (final invalid in [
        {...task.data, 'version': 9223372036854775807},
        {...task.data, 'version': 0},
        {...task.data, 'hiddenPayload': 'unexpected'},
        {...task.data, 'updatedAt': 'invalid timestamp'},
      ]) {
        expect(() => WorkTask.fromJson(invalid), throwsStateError);
      }
      expect(
        () => validateTaskMutation(
          actor: owner,
          current: task,
          next: task.copy({
            'version': task.version + maxTaskRevisionAdvance + 1,
          }),
          allowCollapsedTransitions: true,
        ),
        throwsStateError,
      );
      expect(() => nextTaskVersion(maxTaskVersion), throwsStateError);
      expect(
        () => validateTaskMutation(
          actor: owner,
          next: task.copy({'status': 'done', 'completedDate': '2026-10-01'}),
          allowCollapsedTransitions: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'two SQLite clients check expected version inside their write transaction',
    () {
      final dir = Directory.systemTemp.createTempSync('ieum-v020-store-');
      final filename = '${dir.path}/shared.sqlite';
      final first = InterleavedStore(filename);
      final second = TaskStore(filename);
      try {
        final original = first.save(draft());
        first.beforeTransaction = () => second.save({
          ...original.data,
          'title': '다른 앱이 먼저 저장',
        }, expectedVersion: original.version);
        expect(
          () => first.save({
            ...original.data,
            'title': '늦게 도착한 수정',
          }, expectedVersion: original.version),
          throwsStateError,
        );
        expect(first.find(original.id).title, '다른 앱이 먼저 저장');
        final latest = first.find(original.id);
        first.beforeTransaction = () => second.transition(
          latest.id,
          'doing',
          expectedVersion: latest.version,
        );
        expect(
          () => first.transition(
            latest.id,
            'doing',
            expectedVersion: latest.version,
          ),
          throwsStateError,
        );
        expect(first.find(latest.id).version, latest.version + 1);
      } finally {
        first.dispose();
        second.dispose();
        final resolved = dir.resolveSymbolicLinksSync();
        final temp = Directory.systemTemp.resolveSymbolicLinksSync();
        if (!resolved.startsWith('$temp${Platform.pathSeparator}') ||
            !dir.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('ieum-v020-store-')) {
          throw StateError('Unexpected test directory');
        }
        dir.deleteSync(recursive: true);
      }
    },
  );

  test('partial import applies healthy work and preserves conflicted task and baseline', () {
    final conflicted = store.save(draft(title: '첫 작업'));
    final healthy = store.save(draft(title: '둘째 작업'));
    store.importSnapshot(snapshot([conflicted, healthy], 'main-1'));
    final local = store.save({
      ...conflicted.data,
      'title': '내 수정',
    }, expectedVersion: conflicted.version);
    final remoteConflict = conflicted.copy({'title': '다른 수정', 'version': 2});
    final remoteHealthy = healthy.copy({'title': '정상 수정', 'version': 2});
    final result = store.importSnapshot(
      snapshot([remoteConflict, remoteHealthy]),
      allowPartial: true,
    );
    expect(result.applied, isTrue);
    expect(result.conflicts.single['taskId'], conflicted.id);
    expect(store.find(conflicted.id).data, local.data);
    expect(store.baseline[conflicted.id]!.data, conflicted.data);
    expect(store.find(healthy.id).title, '정상 수정');
    expect(store.baseline[healthy.id]!.data, remoteHealthy.data);
    final again = store.importSnapshot(
      snapshot([remoteConflict, remoteHealthy]),
      allowPartial: true,
    );
    expect(again.conflicts.single['taskId'], conflicted.id);
    expect(store.find(healthy.id).version, remoteHealthy.version);
  });

  test('partial snapshots preserve omitted tasks and handoff never silently combines worker content', () {
    final first = store.save(draft());
    final second = store.save(draft(title: '유지되는 작업'));
    store.importSnapshot(snapshot([first, second]));
    store.setMeta('profile', worker.id);
    final local = store.save({
      ...first.data,
      'description': '아직 올리지 않은 변경',
    }, expectedVersion: first.version);
    final handoff = first.copy({'status': 'review', 'version': 3});
    final result = store.importSnapshot(
      snapshot([handoff]),
      allowPartial: true,
    );
    expect(result.conflicts, hasLength(1));
    expect(store.find(first.id).data, local.data);
    expect(store.baseline[first.id]!.data, first.data);
    expect(store.find(second.id).data, second.data);
  });

  test(
    'paused synchronization retains pending work durably for later resume',
    () {
      store.setMeta(
        'github.config',
        jsonEncode({'repository': 'owner/tasks', 'enabled': false}),
      );
      store.setMeta('github.login', owner.login);
      final created = store.save(draft());
      final rows = store.db.select('SELECT body FROM github_queue');
      expect(rows, hasLength(1));
      final job = jsonDecode(rows.single['body'] as String);
      expect(job['taskId'], created.id);
      expect(job['state'], 'pending');
      expect(job['proposal']['changes'].single['task']['title'], created.title);
    },
  );

  test('explicit remote resolution archives pending local work and invalidates stale editors', () {
    store.setMeta(
      'github.config',
      jsonEncode({'repository': 'owner/tasks', 'enabled': false}),
    );
    final original = store.save(draft());
    store.importSnapshot(snapshot([original]));
    final edited = store.save({
      ...original.data,
      'title': '아직 올리지 않은 내용',
    }, expectedVersion: original.version);
    final remote = original.copy({'status': 'review', 'version': 3});
    store.setMeta(
      'github.pullConflicts',
      jsonEncode([
        {'taskId': original.id, 'field': '검토 잠금'},
        {'taskId': 'other-task', 'field': '다른 충돌'},
      ]),
    );
    expect(
      () => store.acceptRemoteTask(remote, expectedVersion: original.version),
      throwsStateError,
    );
    expect(store.records('conflict_backups'), isEmpty);
    store.acceptRemoteTask(remote, expectedVersion: edited.version);
    expect(store.find(original.id).same(remote), isTrue);
    expect(store.find(original.id).version, greaterThan(remote.version));
    expect(store.baseline[original.id]!.data, remote.data);
    expect(store.db.select('SELECT * FROM github_queue'), isEmpty);
    final archived = store.records('conflict_backups').single;
    expect(archived['task']['title'], edited.title);
    expect(
      archived['queue']['proposal']['changes'].single['task']['title'],
      edited.title,
    );
    expect(
      (jsonDecode(store.meta('github.pullConflicts')) as List).single['taskId'],
      'other-task',
    );
    final acceptedVersion = store.find(original.id).version;
    final advancedRemote = remote.copy({'dueDate': '2026-10-10', 'version': 4});
    store.importSnapshot(snapshot([advancedRemote]));
    expect(store.find(original.id).version, greaterThan(acceptedVersion));
    expect(store.baseline[original.id]!.version, advancedRemote.version);
  });

  test('incoming assignments and review requests create one readable local inbox event', () {
    final assigned = store.save(draft());
    final client = TaskStore(':memory:', project: project, identity: worker);
    final reviewClient = TaskStore(
      ':memory:',
      project: project,
      identity: reviewer,
    );
    try {
      client.importSnapshot(snapshot([assigned], 'main-1'));
      expect(client.unreadNotificationCount, 1);
      expect(client.notifications.single['eventType'], 'task.created');
      expect(client.notifications.single['recipientId'], worker.id);
      client.importSnapshot(snapshot([assigned], 'main-1'));
      expect(client.notifications, hasLength(1));
      client.markNotificationsRead();
      expect(client.unreadNotificationCount, 0);
      expect(client.notifications.single['read'], isTrue);
      reviewClient.importSnapshot(snapshot([assigned], 'main-1'));
      expect(reviewClient.notifications, isEmpty);
      final reviewing = assigned.copy({'status': 'review', 'version': 3});
      reviewClient.importSnapshot(snapshot([reviewing]));
      expect(reviewClient.notifications.single['eventType'], 'task.review');
      expect(reviewClient.unreadNotificationCount, 1);
      reviewClient.importSnapshot(snapshot([reviewing]));
      expect(reviewClient.notifications, hasLength(1));
      client.importSnapshot(snapshot([reviewing]));
      expect(client.notifications, hasLength(1));
      final rejected = reviewing.copy({
        'status': 'rework',
        'reworkReason': '완료 조건 보완',
        'version': 4,
      });
      client.importSnapshot(snapshot([rejected], 'main-3'));
      expect(client.notifications.first['eventType'], 'task.rework');
      expect(client.notifications.first['reason'], '완료 조건 보완');
      expect(client.unreadNotificationCount, 1);
    } finally {
      client.dispose();
      reviewClient.dispose();
    }
  });
}
