import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_policy_test.dart'
    show admin, artist, configured, director, draft, planner, routes;

void main() {
  test('a recipient rejection followed by metadata editing validates as a collapsed change', () {
    final project = configured(
      links: [
        for (final route in routes)
          if (route.id == 'reject')
            const WorkflowSheetRoute(
              id: 'reject',
              from: 'review',
              to: 'doing',
              source: 'part:role-pd',
              destination: 'part:role-pd',
              person: 'gh-3',
              action: 'reject',
            )
          else
            route,
      ],
    );
    final store = TaskStore(':memory:', project: project, identity: planner);
    addTearDown(store.dispose);
    var task = store.save(draft());
    store.transition(task.id, 'doing', expectedVersion: task.version);
    task = store.find(task.id);
    store.transition(task.id, 'review', expectedVersion: task.version);
    final base = store.find(task.id);
    store.setMeta('profile', director.id);
    store.transition(
      base.id,
      'doing',
      expectedVersion: base.version,
      reason: '범위 확인 후 수정',
    );
    final returned = store.find(base.id);
    final next = store.save({
      ...returned.data,
      'priority': 'high',
    }, expectedVersion: returned.version);
    expect(next.version, base.version + 2);
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: next,
        workflowProject: store.project,
        allowCollapsedTransitions: true,
      ),
      returnsNormally,
    );
    final forged = base.copy({'priority': 'high', 'version': base.version + 2});
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: forged,
        workflowProject: store.project,
        allowCollapsedTransitions: true,
      ),
      returnsNormally,
    );
  });

  test('editing a legacy registration assignee preserves the current personal recipient', () {
    final store = TaskStore(
      ':memory:',
      project: configured(),
      identity: planner,
    );
    addTearDown(store.dispose);
    final task = store.save(draft()).copy({
      'workflowTarget': 'legacy',
      'workflowPerson': '',
      'workflowRoute': '',
    });
    store.put(task);
    final reassigned = store.save({
      ...task.data,
      'assigneeId': director.id,
    }, expectedVersion: task.version);
    expect(reassigned.assigneeId, director.id);
    expect(reassigned.workflowPerson, planner.id);
    expect(reassigned.workflowTarget, isEmpty);
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: task,
        next: task.copy({
          'assigneeId': director.id,
          'version': task.version + 2,
        }),
        workflowProject: store.project,
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
    final edited = store.save({
      ...reassigned.data,
      'priority': 'high',
    }, expectedVersion: reassigned.version);
    expect(edited.priority, 'high');
  });

  WorkTask move(
    TaskStore store,
    WorkTask task,
    String stage, {
    String reason = '',
  }) {
    store.confirmHandoff(store.planHandoff(task, stage), reason: reason);
    return store.find(task.id);
  }

  test('changed reviewer cannot reuse an inactive unchanged assignee ID', () {
    final project = configured(
      people: [
        admin,
        Person(
          planner.id,
          planner.name,
          planner.initials,
          planner.role,
          0,
          login: planner.login,
          parts: planner.parts,
          enabled: false,
        ),
        director,
        artist,
      ],
    );
    final base = WorkTask.fromJson({
      ...draft(),
      'id': 'TASK-inactive-shared-id',
      'status': 'doing',
      'completedDate': '',
      'reworkReason': '',
      'workflowTarget': '',
      'workflowPerson': '',
      'workflowRoute': '',
      'version': 1,
      'updatedAt': '2026-10-07T00:00:00Z',
    });
    final next = base.copy({'reviewerId': planner.id, 'version': 2});
    expect(
      () => validateTaskMutation(
        actor: project.people.first,
        current: base,
        next: next,
        workflowProject: project,
      ),
      throwsStateError,
    );
  });

  test('collapsed administrator recovery and subsequent content edit is admissible', () {
    final store = TaskStore(
      ':memory:',
      project: configured(),
      identity: planner,
    );
    addTearDown(store.dispose);
    var task = move(store, move(store, store.save(draft()), 'doing'), 'review');
    store.setMeta('profile', director.id);
    final base = task = move(store, task, 'done');
    store.setMeta('profile', admin.id);
    store.recoverTask(
      task.id,
      stageId: 'doing',
      personId: planner.id,
      expectedVersion: task.version,
    );
    task = store.find(task.id);
    final next = store.save({
      ...task.data,
      'title': '회수 후 수정',
    }, expectedVersion: task.version);
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: next,
        workflowProject: store.project,
        allowCollapsedTransitions: true,
      ),
      returnsNormally,
    );
  });

  test(
    'collapsed administrator recovery and following route is admissible',
    () {
      final store = TaskStore(
        ':memory:',
        project: configured(),
        identity: planner,
      );
      addTearDown(store.dispose);
      var task = move(
        store,
        move(store, store.save(draft()), 'doing'),
        'review',
      );
      store.setMeta('profile', director.id);
      final base = task = move(store, task, 'done');
      store.setMeta('profile', admin.id);
      store.recoverTask(
        task.id,
        stageId: 'doing',
        personId: planner.id,
        expectedVersion: task.version,
      );
      task = store.find(task.id);
      final next = move(store, task, 'review');
      expect(
        () => validateTaskMutation(
          actor: store.actor,
          current: base,
          next: next,
          workflowProject: store.project,
          allowCollapsedTransitions: true,
        ),
        returnsNormally,
      );
    },
  );

  test(
    'collapsed administrator rejection and later reassignment is admissible',
    () {
      final store = TaskStore(
        ':memory:',
        project: configured(),
        identity: planner,
      );
      addTearDown(store.dispose);
      final base = move(
        store,
        move(store, store.save(draft()), 'doing'),
        'review',
      );
      store.setMeta('profile', admin.id);
      final returned = move(store, base, 'todo', reason: '확인 요청');
      final next = store.save({
        ...returned.data,
        'reviewerId': artist.id,
      }, expectedVersion: returned.version);
      expect(
        () => validateTaskMutation(
          actor: store.actor,
          current: base,
          next: next,
          workflowProject: store.project,
          allowCollapsedTransitions: true,
        ),
        returnsNormally,
      );
    },
  );

  test(
    'collapsed administrator rejection and recovery preserves the new comment',
    () {
      final store = TaskStore(
        ':memory:',
        project: configured(),
        identity: planner,
      );
      addTearDown(store.dispose);
      final base = move(
        store,
        move(store, store.save(draft()), 'doing'),
        'review',
      );
      store.setMeta('profile', admin.id);
      final returned = move(store, base, 'todo', reason: '반려 후 재배정');
      store.recoverTask(
        returned.id,
        stageId: 'doing',
        personId: artist.id,
        expectedVersion: returned.version,
      );
      final next = store.find(returned.id);
      expect(next.workflowRoute, 'admin-recovery');
      expect(next.workflowPerson, artist.id);
      expect(next.reworkReason, '반려 후 재배정');
      expect(next.version, base.version + 2);
      expect(
        () => validateTaskMutation(
          actor: store.actor,
          current: base,
          next: next,
          workflowProject: store.project,
          allowCollapsedTransitions: true,
        ),
        returnsNormally,
      );
    },
  );

  test('collapsed recovery alone cannot invent a rejection comment', () {
    final store = TaskStore(
      ':memory:',
      project: configured(),
      identity: planner,
    );
    addTearDown(store.dispose);
    var task = move(store, move(store, store.save(draft()), 'doing'), 'review');
    store.setMeta('profile', director.id);
    final base = task = move(store, task, 'done');
    store.setMeta('profile', admin.id);
    store.recoverTask(
      task.id,
      stageId: 'doing',
      personId: artist.id,
      expectedVersion: task.version,
    );
    final forged = store.find(task.id).copy({
      'version': base.version + 2,
      'reworkReason': '반려 없이 만들어 낸 의견',
    });
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: forged,
        workflowProject: store.project,
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
  });
}
