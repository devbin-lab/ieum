import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_policy_test.dart' as policy;

ProjectManifest openProject() => policy.configured(
  links: WorkflowSheet.defaultFor(['todo', 'doing', 'review', 'done']).routes,
);

WorkTask move(TaskStore store, WorkTask task, String stage) {
  store.confirmHandoff(store.planHandoff(task, stage));
  return store.find(task.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('receiver part membership changes invalidate the final confirmation snapshot', () {
    final store = TaskStore(
      ':memory:',
      project: policy.configured(),
      identity: policy.planner,
    );
    addTearDown(store.dispose);
    final task = move(store, store.save(policy.draft()), 'doing');
    final plan = store.planHandoff(task, 'review');
    expect(plan.recipientLabel, 'PD 전체');
    store.updateProject(
      policy.configured(
        people: [
          policy.admin,
          policy.planner,
          Person(
            policy.director.id,
            policy.director.name,
            'P',
            'unassigned',
            0,
            login: policy.director.login,
            parts: ['아트'],
          ),
          policy.otherDirector,
          policy.artist,
        ],
      ),
    );
    expect(
      store.canMove(task, 'review'),
      isTrue,
      reason: 'The other active PD still makes this route available.',
    );
    expect(store.isHandoffCurrent(plan), isFalse);
    expect(() => store.confirmHandoff(plan), throwsStateError);
    expect(store.find(task.id).same(task), isTrue);
  });

  test(
    'available handoffs expose only direct routes without changing stored data',
    () {
      final store = TaskStore(
        ':memory:',
        project: openProject(),
        identity: policy.artist,
      );
      addTearDown(store.dispose);
      final task = store.save({...policy.draft(), 'title': '확인할 작업'});
      final activityCount = store.activity.length;
      final plans = store.availableHandoffs(task);
      expect(plans.map((p) => p.destinationId), ['doing']);
      final plan = plans.single;
      expect(plan.title, '확인할 작업');
      expect(plan.taskTitle, plan.title);
      expect(plan.sourceName, '확인중');
      expect(plan.destinationName, '진행중');
      expect(plan.recipientLabel, '모든 작업자');
      expect(plan.editWarning, isEmpty);
      expect(store.isHandoffCurrent(plan), isTrue);
      expect(() => store.planHandoff(task, 'review'), throwsStateError);
      expect(() => store.planHandoff(task, 'todo'), throwsStateError);
      expect(store.find(task.id).same(task), isTrue);
      expect(store.activity.length, activityCount);
      store.confirmHandoff(plan);
      final doing = store.find(task.id);
      expect(doing.status, 'doing');
      expect(
        store.availableHandoffs(task).single.sourceId,
        'doing',
        reason:
            'Buttons read the current revision even when passed an old row.',
      );
      final review = store.planHandoff(
        doing,
        'doing',
        routeId: 'manual-handoff',
        receiverPerson: policy.director.id,
        purpose: 'review',
      );
      expect(review.recipientLabel, policy.director.name);
      expect(review.editWarning, contains('모든 활성 참여자'));
      store.confirmHandoff(review);
      final submitted = store.find(task.id);
      expect(
        store
            .availableHandoffs(submitted)
            .map((p) => '${p.action}/${p.destinationId}'),
        ['approve/done'],
      );
      expect(store.canEditContent(submitted), isTrue);
      final complete = store.planHandoff(submitted, 'done');
      expect(complete.isCompletion, isTrue);
      expect(complete.recipientLabel, '처리 종료');
      expect(complete.editWarning, contains('관리자 회수'));
      store.confirmHandoff(complete);
      expect(store.availableHandoffs(store.find(task.id)), isEmpty);
    },
  );

  test(
    'same-stage destinations with different recipients require an exact route',
    () {
      final private = const WorkflowSheetRoute(
        id: 'private-submit',
        from: 'doing',
        to: 'review',
        source: 'part:role-plan',
        destination: 'part:role-pd',
        person: 'gh-3',
      );
      final store = TaskStore(
        ':memory:',
        project: policy.configured(links: [...policy.routes, private]),
        identity: policy.planner,
      );
      addTearDown(store.dispose);
      final task = move(store, store.save(policy.draft()), 'doing');
      final plans = store
          .availableHandoffs(task)
          .where((p) => p.destinationId == 'review');
      expect(plans.map((p) => p.routeId), ['submit', 'private-submit']);
      expect(plans.map((p) => p.recipientLabel), [
        'PD 전체',
        policy.director.name,
      ]);
      expect(() => store.planHandoff(task, 'review'), throwsStateError);
      final personalPlan = store.planHandoff(
        task,
        'review',
        routeId: private.id,
      );
      expect(personalPlan.editWarning, isEmpty);
      store.confirmHandoff(personalPlan);
      final submitted = store.find(task.id);
      expect(submitted.workflowPerson, policy.director.id);
      expect(store.canEditContent(submitted), isTrue);
      store.setMeta('profile', policy.otherDirector.id);
      expect(store.availableHandoffs(submitted), isNotEmpty);
      expect(store.isAssignedToMe(submitted), isFalse);
    },
  );

  test('rejection confirmation needs a comment and atomically records its return recipient', () {
    final links = [
      for (final route in policy.routes)
        if (route.id == 'reject')
          const WorkflowSheetRoute(
            id: 'reject',
            from: 'review',
            to: 'todo',
            action: 'reject',
            source: 'part:role-pd',
            destination: 'part:role-art',
            person: 'gh-5',
          )
        else
          route,
    ];
    final store = TaskStore(
      ':memory:',
      project: policy.configured(links: links),
      identity: policy.planner,
    );
    addTearDown(store.dispose);
    final submitted = move(
      store,
      move(store, store.save(policy.draft()), 'doing'),
      'review',
    );
    store.setMeta('profile', policy.director.id);
    final plan = store.planHandoff(submitted, 'todo', action: 'reject');
    expect(plan.isRejection, isTrue);
    expect(plan.recipientLabel, policy.artist.name);
    expect(plan.editWarning, isEmpty);
    expect(() => store.confirmHandoff(plan), throwsStateError);
    expect(store.find(submitted.id).same(submitted), isTrue);
    expect(store.isHandoffCurrent(plan), isTrue);
    store.confirmHandoff(plan, reason: '  내용을 보완하세요.  ');
    final returned = store.find(submitted.id);
    expect(returned.status, 'todo');
    expect(returned.workflowTarget, 'part:role-art');
    expect(returned.workflowPerson, policy.artist.id);
    expect(
      returned.assigneeId,
      submitted.assigneeId,
      reason: 'The historical assignee is separate from the current recipient.',
    );
    expect(returned.reworkReason, '내용을 보완하세요.');
    expect(returned.version, submitted.version + 1);
    store.setMeta('profile', policy.artist.id);
    expect(store.canEditContent(returned), isTrue);
  });

  test('missing connections retain shared actions and administrator recovery remains restricted', () {
    final store = TaskStore(
      ':memory:',
      project: policy.configured(links: []),
      identity: policy.planner,
    );
    addTearDown(store.dispose);
    final task = store.save(policy.draft());
    expect(store.availableHandoffs(task).single.routeId, 'manual-start');
    expect(store.planHandoff(task, 'doing').routeId, 'manual-start');
    final orphan = task.copy({'status': 'stage-removed'});
    store.put(orphan);
    expect(store.availableHandoffs(orphan).single.routeId, 'manual-finish');
    expect(
      () => store.recoverTask(
        orphan.id,
        stageId: 'todo',
        personId: policy.planner.id,
        expectedVersion: orphan.version,
      ),
      throwsStateError,
    );
    store.setMeta('profile', policy.admin.id);
    store.recoverTask(
      orphan.id,
      stageId: 'todo',
      personId: policy.planner.id,
      expectedVersion: orphan.version,
    );
    expect(store.find(task.id).status, 'todo');
    expect(store.find(task.id).workflowPerson, policy.planner.id);
  });

  test('task revision, account and route edits invalidate final confirmation without partial writes', () {
    final store = TaskStore(
      ':memory:',
      project: openProject(),
      identity: policy.planner,
    );
    addTearDown(store.dispose);
    final task = store.save(policy.draft());
    final first = store.planHandoff(task, 'doing');
    final edited = store.save({
      ...task.data,
      'description': '확인창이 열린 사이 수정',
    }, expectedVersion: task.version);
    expect(store.isHandoffCurrent(first), isFalse);
    expect(() => store.confirmHandoff(first), throwsStateError);
    expect(store.find(task.id).same(edited), isTrue);
    final accountPlan = store.planHandoff(edited, 'doing');
    store.setMeta('profile', policy.artist.id);
    expect(store.canMove(edited, 'doing'), isTrue);
    expect(store.isHandoffCurrent(accountPlan), isFalse);
    expect(() => store.confirmHandoff(accountPlan), throwsStateError);
    final stagePlan = store.planHandoff(edited, 'doing');
    store.updateProject(policy.configured(links: []));
    expect(store.isHandoffCurrent(stagePlan), isFalse);
    expect(() => store.confirmHandoff(stagePlan), throwsStateError);
    expect(store.find(task.id).version, edited.version);
  });

  test(
    'card layout moves retain confirmation while policy changes invalidate it',
    () {
      final store = TaskStore(
        ':memory:',
        project: policy.configured(),
        identity: policy.planner,
      );
      addTearDown(store.dispose);
      final task = move(store, store.save(policy.draft()), 'doing');
      final plan = store.planHandoff(task, 'review');
      store.updateProject(
        ProjectManifest.fromJson({
          ...store.project!.json,
          'workflowSheet': WorkflowSheet(
            nodes: [
              for (final node in policy.nodes)
                WorkflowSheetNode(node.id, node.stageId, x: 150, y: 30),
            ],
            routes: policy.routes,
          ).json,
        }),
      );
      expect(store.isHandoffCurrent(plan), isTrue);
      store.confirmHandoff(plan);
      expect(store.find(task.id).workflowTarget, 'part:role-pd');
    },
  );

  test('a second SQLite client invalidates confirmation inside the write transaction', () {
    final dir = Directory.systemTemp.createTempSync('ieum-handoff-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final filename = '${dir.path}/project.sqlite';
    final first = TaskStore(
      filename,
      project: openProject(),
      identity: policy.admin,
    );
    final second = TaskStore(
      filename,
      project: openProject(),
      identity: policy.admin,
    );
    addTearDown(second.dispose);
    addTearDown(first.dispose);
    final task = first.save(policy.draft());
    final plan = first.planHandoff(task, 'doing');
    final changed = second.save({
      ...task.data,
      'title': '다른 창에서 수정',
    }, expectedVersion: task.version);
    expect(() => first.confirmHandoff(plan), throwsStateError);
    expect(first.find(task.id).title, changed.title);
    expect(first.find(task.id).status, 'todo');
    expect(first.find(task.id).version, changed.version);
  });
}
