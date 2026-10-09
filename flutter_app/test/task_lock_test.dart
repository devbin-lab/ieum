import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/project_schedule_view.dart';

import 'part_workflow_test_fixtures.dart';
import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;

Map<String, dynamic> draft() => {
  'title': '잠금 검사',
  'part': '기획',
  'priority': 'normal',
  'assigneeId': routeWorker.id,
  'reviewerId': routeReviewer.id,
  'assignedDate': '2026-09-29',
  'dueDate': '2026-10-03',
  'description': '',
};

TaskStore storeFor(Person identity, {WorkTask? task}) {
  final store = TaskStore(
    ':memory:',
    project: personalReviewProject,
    identity: identity,
    seed: task == null ? const [] : [task.data],
  );
  if (task != null) store.put(task, table: 'baseline_tasks');
  addTearDown(store.dispose);
  return store;
}

Map<String, dynamic> snapshot(WorkTask task) => {
  'schemaVersion': 1,
  'projectId': personalReviewProject.id,
  'revision': 'next-main',
  'tasks': [task.data],
};

void validate(Person actor, WorkTask next, WorkTask current) =>
    validateTaskMutation(
      actor: actor,
      next: next,
      current: current,
      workflowProject: personalReviewProject,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'existing task fields remain compatible and calendar interval is inclusive',
    () {
      final store = storeFor(routeWorker);
      final task = store.save(draft());
      final legacy = WorkTask.fromJson(
        {...task.data}
          ..remove('lockedBy')
          ..remove('comments'),
      );
      expect(legacy.isLocked, isFalse);
      expect(legacy.comments, isEmpty);
      for (final date in [
        '2026-09-29',
        '2026-09-30',
        '2026-10-01',
        '2026-10-03',
      ]) {
        expect(taskScheduledOn(task, DateTime.parse(date)), isTrue);
      }
      expect(taskScheduledOn(task, DateTime(2026, 9, 28)), isFalse);
      expect(taskScheduledOn(task, DateTime(2026, 10, 4)), isFalse);
      expect(
        taskScheduledOn(task.copy({'dueDate': ''}), DateTime(2026, 9, 29)),
        isTrue,
      );
      expect(
        taskScheduledOn(task.copy({'dueDate': ''}), DateTime(2026, 9, 30)),
        isFalse,
      );
    },
  );

  test('saved automation never runs and rejection is unavailable', () {
    final store = storeFor(routeWorker);
    final task = store.save(draft());
    expect(store.project!.workflowSheet!.routes, isEmpty);
    expect(store.availableTransfers(task), isEmpty);
    expect(
      () => store.transition(
        task.id,
        'doing',
        routeId: 'manual-return',
        expectedVersion: 1,
      ),
      throwsStateError,
    );
    expect(
      () => store.transition(
        task.id,
        'doing',
        routeId: 'start',
        expectedVersion: 1,
      ),
      throwsStateError,
    );
    store.transition(task.id, 'doing', expectedVersion: 1);
    expect(store.find(task.id).workflowRoute, 'manual-start');
  });

  test('creation lock and claiming lock prohibit all other task mutations', () {
    final owner = storeFor(routeWorker);
    final task = owner.save({...draft(), 'lockedBy': routeWorker.id});
    expect(task.lockedBy, routeWorker.id);
    for (final person in [routeReviewer, routeOwner]) {
      final other = storeFor(person, task: task);
      expect(other.tasks.single.id, task.id);
      expect(other.canEdit(task), isFalse);
      expect(other.canDelete(task), isFalse);
      expect(other.canArchive(task), isFalse);
      expect(other.canActOnTask(task), isFalse);
      expect(other.availableHandoffs(task), isEmpty);
      expect(other.availableTransfers(task), isEmpty);
      expect(
        () => other.save({...task.data, 'title': '가로채기'}, expectedVersion: 1),
        throwsStateError,
      );
      expect(
        () => other.transition(task.id, 'doing', expectedVersion: 1),
        throwsStateError,
      );
      expect(
        () => other.setTaskLocked(task.id, false, expectedVersion: 1),
        throwsStateError,
      );
      expect(
        () => other.setTaskLocked(task.id, true, expectedVersion: 1),
        throwsStateError,
      );
      expect(
        () => other.deleteTask(task.id, expectedVersion: 1),
        throwsStateError,
      );
      expect(
        () => other.setArchived(task.id, true, expectedVersion: 1),
        throwsStateError,
      );
      expect(
        () => other.recoverTask(
          task.id,
          stageId: 'doing',
          personId: person.id,
          expectedVersion: 1,
        ),
        throwsStateError,
      );
      final comment = other.addTaskComment(
        task.id,
        '수정 의견',
        expectedVersion: 1,
      );
      expect(comment.lockedBy, routeWorker.id);
      expect(comment.comments.single['authorId'], person.id);
      validate(person, comment, task);
    }
    final unlocked = owner.setTaskLocked(task.id, false, expectedVersion: 1);
    expect(unlocked.isLocked, isFalse);
    final other = storeFor(routeReviewer, task: unlocked);
    final claimed = other.setTaskLocked(
      task.id,
      true,
      expectedVersion: unlocked.version,
    );
    expect(claimed.lockedBy, routeReviewer.id);
  });

  test(
    'locked handoff requires one person and transfers exclusive edit access',
    () {
      final store = storeFor(routeWorker);
      var task = store.save({...draft(), 'lockedBy': routeWorker.id});
      store.transition(task.id, 'doing', expectedVersion: task.version);
      task = store.find(task.id);
      final broad = store.planHandoff(
        task,
        'todo',
        routeId: 'manual-handoff',
        receiverGroup: 'part:role-pd',
      );
      expect(broad.lockOnHandoff, isTrue);
      expect(broad.hasRecipientSelection, isFalse);
      expect(() => store.confirmHandoff(broad), throwsStateError);
      final plan = broad.withReceiver('part:role-pd', routeReviewer.id);
      expect(plan.hasRecipientSelection, isTrue);
      store.confirmHandoff(plan, reason: '이어 작업해 주세요.');
      final received = store.find(task.id);
      expect(received.status, 'todo');
      expect(received.lockedBy, routeReviewer.id);
      expect(received.workflowPerson, routeReviewer.id);
      expect(store.canEdit(received), isFalse);
      expect(store.canSetTaskLock(received), isFalse);
      validate(routeWorker, received, task);
      final nextStore = storeFor(routeReviewer, task: received);
      expect(nextStore.canEdit(received), isTrue);
      expect(nextStore.isAssignedToMe(received), isTrue);
      final edited = nextStore.save({
        ...received.data,
        'description': 'PD 수정',
      }, expectedVersion: received.version);
      expect(edited.lockedBy, routeReviewer.id);
      expect(() => store.confirmHandoff(plan), throwsStateError);
      validate(routeReviewer, edited, received);
    },
  );

  test('recipient may unlock or explicitly hand off without a lock', () {
    final store = storeFor(routeWorker);
    var task = store.save({...draft(), 'lockedBy': routeWorker.id});
    store.transition(task.id, 'doing', expectedVersion: task.version);
    task = store.find(task.id);
    final plan = store
        .planHandoff(
          task,
          'todo',
          routeId: 'manual-handoff',
          receiverGroup: 'part:role-pd',
        )
        .withLock(false);
    store.confirmHandoff(plan);
    final received = store.find(task.id);
    expect(received.isLocked, isFalse);
    expect(store.canEdit(received), isTrue);
    expect(storeFor(routeReviewer, task: received).canEdit(received), isTrue);
    validate(routeWorker, received, task);
  });

  test('forged lock handoff, stolen lock, bundled fields and comments are rejected', () {
    final store = storeFor(routeWorker);
    final task = store.save({...draft(), 'lockedBy': routeWorker.id});
    expect(
      () => validate(
        routeReviewer,
        task.copy({'lockedBy': routeReviewer.id, 'version': 2}),
        task,
      ),
      throwsStateError,
    );
    expect(
      () => validate(
        routeWorker,
        task.copy({'lockedBy': '', 'description': '숨긴 변경', 'version': 2}),
        task,
      ),
      throwsStateError,
    );
    expect(
      () => validate(
        routeWorker,
        task.copy({'lockedBy': routeReviewer.id, 'version': 2}),
        task,
      ),
      throwsStateError,
    );
    final commented = store.addTaskComment(
      task.id,
      '본문은 변경하지 않음',
      expectedVersion: 1,
    );
    final changed = commented.comments
        .map((c) => {...c, 'text': '위조'})
        .toList();
    expect(
      () => validate(
        routeWorker,
        commented.copy({'comments': jsonEncode(changed), 'version': 3}),
        commented,
      ),
      throwsStateError,
    );
    expect(
      () => store.addTaskComment(task.id, '', expectedVersion: 2),
      throwsStateError,
    );
    expect(
      () => store.addTaskComment(task.id, '의견', expectedVersion: 1),
      throwsStateError,
    );
    expect(
      () => store.addTaskComment(task.id, 'x' * 2001, expectedVersion: 2),
      throwsStateError,
    );
  });

  test(
    'concurrent lock and content edits conflict instead of losing changes',
    () {
      final store = storeFor(routeWorker);
      final task = store.save(draft());
      store.put(task, table: 'baseline_tasks');
      store.save({...task.data, 'description': '개인 수정'}, expectedVersion: 1);
      final remote = task.copy({'lockedBy': routeReviewer.id, 'version': 2});
      expect(store.importSnapshot(snapshot(remote)).conflicts, isNotEmpty);
      expect(store.find(task.id).description, '개인 수정');
    },
  );

  test('concurrent comments combine by ID and publishable proof keeps author isolation', () {
    final store = storeFor(routeWorker);
    final task = store.save(
      {...draft(), 'lockedBy': routeReviewer.id}..remove('lockedBy'),
    );
    store.put(task, table: 'baseline_tasks');
    store.addTaskComment(task.id, '기획 의견', expectedVersion: 1);
    final remoteStore = storeFor(routeReviewer, task: task);
    final remote = remoteStore.addTaskComment(
      task.id,
      'PD 의견',
      expectedVersion: 1,
    );
    final result = store.importSnapshot(snapshot(remote));
    expect(result.applied, isTrue);
    final merged = store.find(task.id);
    expect(merged.comments, hasLength(2));
    expect(merged.version, 3);
    validate(routeWorker, merged, remote);
    expect(() => validate(routeReviewer, merged, remote), throwsStateError);
  });

  test('offline create, lock, edit, comment and locked handoff merge through GitHub', () async {
    final api = AutoMergeApi();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    await session.signIn(token: 'test-only');
    await session.writeJson(
      config,
      '.ieum/project.json',
      personalReviewProject.json,
      message: 'Fixture',
    );
    api.identityId = 2;
    api.identityLogin = routeWorker.login;
    final store = storeFor(routeWorker);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', routeWorker.login);
    var task = store.save(draft());
    task = store.setTaskLocked(task.id, true, expectedVersion: 1);
    task = store.save({
      ...task.data,
      'description': '최종 초안',
    }, expectedVersion: task.version);
    task = store.addTaskComment(
      task.id,
      '다음 담당자에게 전달합니다.',
      expectedVersion: task.version,
    );
    store.transition(task.id, 'doing', expectedVersion: task.version);
    task = store.find(task.id);
    final plan = store.planHandoff(
      task,
      'todo',
      routeId: 'manual-handoff',
      receiverPerson: routeReviewer.id,
    );
    store.confirmHandoff(plan);
    expect(parseWorkflowRevisions(store.changes.single['steps']), hasLength(6));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(sync.dispose);
    await sync.cycle();
    await idle(sync);
    expect(sync.autoMergeErrors, isEmpty);
    expect(sync.jobs.single['state'], 'merged');
    expect(store.baseline[task.id]!.lockedBy, routeReviewer.id);
    expect(store.baseline[task.id]!.comments, hasLength(1));
  });
}
