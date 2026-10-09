import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_test_fixtures.dart';

Map<String, dynamic> draft({String lock = ''}) => {
  'title': '여섯 채널 작업',
  'part': '기획',
  'assigneeId': routeWorker.id,
  'reviewerId': routeReviewer.id,
  'priority': 'normal',
  'assignedDate': '2026-10-08',
  'dueDate': '2026-10-12',
  'description': '유지할 내용',
  'lockedBy': lock,
};
TaskStore storeFor([Person actor = routeWorker]) {
  final store = TaskStore(
    ':memory:',
    project: personalReviewProject,
    identity: actor,
  );
  addTearDown(store.dispose);
  return store;
}

WorkTask move(
  TaskStore store,
  WorkTask task,
  String route, {
  String reason = '',
}) {
  final plan = store
      .availableHandoffs(task)
      .singleWhere((p) => p.routeId == route);
  store.confirmHandoff(plan, reason: reason);
  return store.find(task.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'six fixed states detach saved automation without losing raw task data',
    () {
      final store = storeFor();
      expect(store.project!.workflowStages.map((s) => s.id), [
        'todo',
        'doing',
        'review',
        'done',
        'hold',
        'drop',
      ]);
      expect(store.project!.workflowSheet!.routes, isEmpty);
      var task = store.save(draft());
      expect(task.status, 'todo');
      expect(store.availableTransfers(task), isEmpty);
      expect(task.workflowPerson, routeWorker.id);
      expect(task.creatorId, routeWorker.id);
      expect(task.initialAssigneeId, routeWorker.id);
      task = move(store, task, 'manual-start');
      expect(task.status, 'doing');
      expect(store.availableTransfers(task).single.destinationId, 'todo');
    },
  );
  test('locked handoff enters inbox then review, saves reviewer comments and proof', () {
    final store = storeFor();
    var task = store.save(draft(lock: routeWorker.id));
    final origin = task;
    task = move(store, task, 'manual-start');
    final plan = store
        .availableTransfers(task)
        .single
        .withReceiver('', routeReviewer.id)
        .withPurpose('review')
        .withLock(true);
    store.confirmHandoff(plan, reason: '검토를 부탁합니다.');
    task = store.find(task.id);
    expect(task.status, 'todo');
    expect(task.lockedBy, routeReviewer.id);
    expect(task.workflowSender, routeWorker.id);
    expect(store.canEdit(task), isFalse);
    store.setMeta('profile', routeOwner.id);
    expect(store.canEdit(task), isFalse);
    expect(store.availableHandoffs(task), isEmpty);
    store.setMeta('profile', routeReviewer.id);
    task = move(store, task, 'manual-start');
    expect(task.status, 'review');
    task = store.addTaskComment(
      task.id,
      '검토 통과',
      expectedVersion: task.version,
    );
    expect(task.comments.single['context'], 'review');
    task = move(store, task, 'manual-finish');
    expect(task.status, 'done');
    expect(task.completedDate, isNotEmpty);
    expect(task.creatorId, origin.creatorId);
    expect(task.initialAssigneeId, origin.initialAssigneeId);
    expect(task.transitionHistory.map((e) => e['to']), [
      'doing',
      'todo',
      'review',
      'done',
    ]);
    expect(task.transitionHistory[1]['comment'], '검토를 부탁합니다.');
    expect(task.transitionHistory[2]['comment'], isEmpty);
    expect(store.db.select('PRAGMA quick_check').single.values.single, 'ok');
  });
  test('review feedback uses a regular handoff to inbox and preserves original assignments', () {
    final store = storeFor();
    var task = move(store, store.save(draft()), 'manual-start');
    store.confirmHandoff(
      store
          .availableTransfers(task)
          .single
          .withReceiver('', routeReviewer.id)
          .withPurpose('review'),
    );
    task = store.find(task.id);
    store.setMeta('profile', routeReviewer.id);
    task = move(store, task, 'manual-start');
    store.confirmHandoff(
      store
          .availableTransfers(task)
          .single
          .withReceiver('', routeWorker.id)
          .withPurpose('revision'),
      reason: '코멘트를 반영하세요.',
    );
    task = store.find(task.id);
    expect(task.status, 'todo');
    expect(task.workflowPurpose, 'revision');
    store.setMeta('profile', routeWorker.id);
    task = move(store, task, 'manual-start');
    expect(task.status, 'doing');
    expect(task.reworkReason, '코멘트를 반영하세요.');
  });
  test('hold requires a reason and resumes its previous review state; drop restores inbox', () {
    final store = storeFor();
    var task = move(
      store,
      store.save(draft(lock: routeWorker.id)),
      'manual-start',
    );
    task = move(store, task, 'manual-review');
    final hold = store
        .availableHandoffs(task)
        .singleWhere((p) => p.routeId == 'manual-hold');
    expect(() => store.confirmHandoff(hold), throwsStateError);
    task = move(store, task, 'manual-hold', reason: '자료 대기');
    expect(task.status, 'hold');
    expect(task.pausedFrom, 'review');
    expect(store.canEdit(task), isFalse);
    expect(store.availableTransfers(task), isEmpty);
    task = move(store, task, 'manual-resume');
    expect(task.status, 'review');
    expect(task.pausedFrom, isEmpty);
    task = store.addTaskComment(
      task.id,
      '기록 유지',
      expectedVersion: task.version,
    );
    task = move(store, task, 'manual-drop', reason: '기획 제외');
    expect(task.status, 'drop');
    expect(task.description, '유지할 내용');
    expect(task.comments.single['text'], '기록 유지');
    expect(store.canEdit(task), isFalse);
    task = move(store, task, 'manual-restore');
    expect(task.status, 'todo');
    expect(task.description, '유지할 내용');
    expect(task.lockedBy, routeWorker.id);
    expect(task.pausedFrom, isEmpty);
  });
  test('owner can create a lock for a different initial assignee', () {
    final store = storeFor(routeOwner);
    final task = store.save(draft(lock: routeWorker.id));
    expect(task.creatorId, routeOwner.id);
    expect(task.initialAssigneeId, routeWorker.id);
    expect(task.lockedBy, routeWorker.id);
    expect(store.canEdit(task), isFalse);
    store.setMeta('profile', routeWorker.id);
    expect(store.canEdit(task), isTrue);
  });
  test('provenance and shared transition log cannot be forged by content save or upload', () {
    final store = storeFor();
    var task = store.save(draft());
    task = move(store, task, 'manual-start');
    void verify(WorkTask proposal) => validateTaskMutation(
      actor: store.actor,
      next: proposal,
      current: task,
      workflowProject: store.project,
    );
    expect(
      () => verify(
        task.copy({'creatorId': routeOwner.id, 'version': task.version + 1}),
      ),
      throwsStateError,
    );
    expect(
      () => verify(
        task.copy({
          'initialAssigneeId': routeReviewer.id,
          'version': task.version + 1,
        }),
      ),
      throwsStateError,
    );
    expect(
      () => verify(
        task.copy({'transitionHistory': '[]', 'version': task.version + 1}),
      ),
      throwsStateError,
    );
    final saved = store.save({
      ...task.data,
      'creatorId': routeOwner.id,
      'description': '수정',
    }, expectedVersion: task.version);
    expect(saved.creatorId, routeWorker.id);
    expect(saved.transitionHistory, task.transitionHistory);
  });
  test('same actor offline create, start, hold, resume and handoff replays exact proofs', () {
    final store = storeFor();
    var task = store.save(draft());
    task = move(store, task, 'manual-start');
    task = move(store, task, 'manual-hold', reason: '대기');
    task = move(store, task, 'manual-resume');
    store.confirmHandoff(
      store
          .availableTransfers(task)
          .single
          .withReceiver('', routeReviewer.id)
          .withPurpose('review'),
    );
    task = store.find(task.id);
    final change = (store.exportChanges()['changes'] as List).single as Map;
    final steps = parseWorkflowRevisions(change['steps'])!;
    expect(steps.length, 5);
    validateTaskMutation(
      actor: store.actor,
      next: task,
      workflowProject: store.project,
      allowCollapsedTransitions: true,
      revisions: steps,
    );
    final forged = task.copy({
      'transitionHistory': jsonEncode(task.transitionHistory.reversed.toList()),
    });
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        next: forged,
        workflowProject: store.project,
        allowCollapsedTransitions: true,
        revisions: steps,
      ),
      throwsStateError,
    );
  });
  test(
    'legacy original information stays unknown across edits and transitions',
    () {
      final store = storeFor();
      final data = {
        ...draft(),
        'id': 'TASK-LEGACY-ORIGIN',
        'status': 'todo',
        'completedDate': '',
        'reworkReason': '',
        'version': 1,
        'updatedAt': '2026-10-08T00:00:00Z',
      };
      final legacy = WorkTask.fromJson(data);
      store.put(legacy);
      var task = store.save({
        ...legacy.data,
        'description': '기존 작업 수정',
      }, expectedVersion: 1);
      expect(task.creatorId, isEmpty);
      expect(task.initialAssigneeId, isEmpty);
      expect(task.createdAt, isEmpty);
      task = move(store, task, 'manual-start');
      expect(task.creatorId, isEmpty);
      expect(task.transitionHistory.single['to'], 'doing');
    },
  );
  test('concurrent hold and drop are kept as a conflict instead of mixing history and state', () {
    final store = storeFor();
    var base = move(store, store.save(draft()), 'manual-start');
    store.put(base, table: 'baseline_tasks');
    final other = TaskStore(
      ':memory:',
      project: personalReviewProject,
      identity: routeWorker,
      seed: [base.data],
    );
    addTearDown(other.dispose);
    move(store, base, 'manual-hold', reason: '보류 제안');
    final remote = move(other, base, 'manual-drop', reason: '드랍 제안');
    final result = store.importSnapshot({
      'schemaVersion': 1,
      'projectId': personalReviewProject.id,
      'revision': 'next-main',
      'tasks': [remote.data],
    });
    expect(result.conflicts, isNotEmpty);
    expect(store.find(base.id).status, 'hold');
    expect(store.find(base.id).pausedFrom, 'doing');
    expect(store.find(base.id).transitionHistory.last['to'], 'hold');
  });
}
