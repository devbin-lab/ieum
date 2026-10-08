import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

const _owner = Person('gh-1', '관리자', '관', 'owner', 0, login: 'owner');
const _planner = Person(
  'gh-2',
  '기획자',
  '기',
  'unassigned',
  0,
  parts: ['기획'],
  login: 'planner',
);
const _director = Person(
  'gh-3',
  'PD',
  'P',
  'unassigned',
  0,
  parts: ['PD'],
  login: 'director',
);
const _otherDirector = Person(
  'gh-4',
  '다른 PD',
  'P',
  'unassigned',
  0,
  parts: ['PD'],
  login: 'other-director',
);
const _artist = Person(
  'gh-5',
  '아트',
  '아',
  'unassigned',
  0,
  parts: ['아트'],
  login: 'artist',
);

ProjectManifest _project({String destination = ''}) {
  final defaults = WorkflowSheet.defaultFor(['todo', 'doing', 'done']);
  return ProjectManifest(
    'three-status-project',
    '세 단계 프로젝트',
    _owner.id,
    const [_owner, _planner, _director, _otherDirector, _artist],
    roles: const [
      ProjectRole('role-plan', '기획', {}),
      ProjectRole('role-pd', 'PD', {}),
      ProjectRole('role-art', '아트', {}),
    ],
    parts: const ['기획', 'PD', '아트'],
    unifiedParts: true,
    workflowSheet: WorkflowSheet(
      nodes: defaults.nodes,
      routes: [
        for (final route in defaults.routes)
          route.id == 'default-handoff'
              ? WorkflowSheetRoute.fromJson({
                  ...route.json,
                  'destination': destination,
                })
              : route,
      ],
    ),
  );
}

Map<String, dynamic> _draft() => {
  'title': '기획 작업',
  'part': '기획',
  'assigneeId': _planner.id,
  'reviewerId': _director.id,
  'priority': 'normal',
  'assignedDate': '2026-10-08',
  'dueDate': '',
  'description': '기획 작성 내용',
};

WorkTask _task({String purpose = '', String status = 'todo'}) =>
    WorkTask.fromJson({
      ..._draft(),
      'id': 'TASK-THREE',
      'status': status,
      'completedDate': '',
      'reworkReason': '',
      'workflowTarget': '',
      'workflowPerson': _planner.id,
      'workflowRoute': '',
      'workflowPurpose': purpose,
      'version': 1,
      'updatedAt': '2026-10-08T00:00:00Z',
    });

TaskStore _store({
  ProjectManifest? project,
  WorkTask? task,
  Person actor = _planner,
}) {
  final store = TaskStore(
    ':memory:',
    project: project ?? _project(),
    identity: actor,
    seed: task == null ? [] : [task.data],
  );
  addTearDown(store.dispose);
  return store;
}

WorkTask _move(
  TaskStore store,
  WorkTask task,
  String routeId, {
  String reason = '',
}) {
  final plan = store
      .availableHandoffs(task)
      .followedBy(store.availableTransfers(task))
      .singleWhere(
        (p) =>
            p.routeId ==
            switch (routeId) {
              'default-start' => 'manual-start',
              'default-finish' => 'manual-finish',
              'default-return' => 'manual-return',
              _ => routeId,
            },
      );
  store.confirmHandoff(plan, reason: reason);
  return store.find(task.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('three board states keep intent and sender while recipient starts and returns work', () {
    final store = _store();
    var task = store.save(_draft());
    expect(defaultWorkflowStages.map((s) => s.id), ['todo', 'doing', 'done']);
    expect(task.workflowPerson, _planner.id);
    expect(store.isAssignedToMe(task), isTrue);
    task = _move(store, task, 'default-start');
    final plan = store
        .availableTransfers(task)
        .singleWhere((p) => p.routeId == 'manual-handoff')
        .withPurpose('review');
    expect(store.isHandoffCurrent(plan), isTrue);
    expect(() => store.confirmHandoff(plan), throwsStateError);
    store.confirmHandoff(plan.withReceiver('part:role-pd', ''));
    task = store.find(task.id);
    expect(task.status, 'doing');
    expect(task.workflowPurpose, 'review');
    expect(
      store
          .records('notification_outbox')
          .any(
            (n) => n['eventType'] == 'task.review' && n['taskId'] == task.id,
          ),
      isTrue,
    );
    expect(task.assigneeId, _planner.id);
    expect(workflowCurrentPartLabel(task, store.project), 'PD');
    expect(store.isAssignedToMe(task), isFalse);
    expect(store.canEditContent(task), isTrue);
    expect(store.isWaitingForReview(task), isTrue);
    store.setMeta('profile', _otherDirector.id);
    expect(store.isAssignedToMe(task), isTrue);
    expect(store.canEditContent(task), isTrue);
    expect(task.status, 'doing');
    expect(task.workflowTarget, 'part:role-pd');
    expect(task.workflowPurpose, 'review');
    expect(() => _move(store, task, 'default-return'), throwsStateError);
    task = _move(store, task, 'default-return', reason: '범위를 다시 정리해 주세요.');
    expect(task.status, 'doing');
    expect(task.workflowPurpose, 'revision');
    expect(task.workflowPerson, _planner.id);
    expect(task.reworkReason, '범위를 다시 정리해 주세요.');
    expect(task.completedDate, isEmpty);
    expect(store.canEditContent(task), isTrue);
    store.setMeta('profile', _planner.id);
    expect(store.isAssignedToMe(task), isTrue);
    expect(store.canEditContent(task), isTrue);
    expect(store.activityFor(task.id).first['message'], contains('범위를 다시 정리'));
  });

  test('individual PD delivery completes only on final approval and keeps a proven queue revision', () {
    final project = _project();
    final base = _task(status: 'doing');
    final store = _store(project: project, task: base);
    final plan = store.planHandoff(
      base,
      'doing',
      routeId: 'manual-handoff',
      receiverPerson: _director.id,
      purpose: 'review',
    );
    store.confirmHandoff(plan);
    final submitted = store.find(base.id);
    final change = (store.exportChanges()['changes'] as List).single as Map;
    expect((change['task'] as Map)['workflowPurpose'], 'review');
    final revisions = parseWorkflowRevisions(change['steps'])!;
    expect(revisions.single.workflowPurpose, 'review');
    validateTaskMutation(
      actor: store.actor,
      current: base,
      next: submitted,
      workflowProject: project,
      allowCollapsedTransitions: true,
      revisions: revisions,
    );
    store.setMeta('profile', _otherDirector.id);
    expect(store.isAssignedToMe(submitted), isFalse);
    expect(store.canEditContent(submitted), isTrue);
    store.setMeta('profile', _director.id);
    final finished = _move(store, submitted, 'default-finish');
    expect(finished.status, 'done');
    expect(finished.completedDate, isNotEmpty);
    expect(store.isCompleted(finished), isTrue);
    expect(store.canEditContent(finished), isFalse);
  });

  test('selected receivers respect route restrictions and reject bare everyone or unrelated parts', () {
    final store = _store(
      project: _project(destination: 'part:role-pd'),
      task: _task(status: 'doing'),
    );
    final task = store.find('TASK-THREE');
    final plan = store.planHandoff(task, 'doing', routeId: 'default-handoff');
    expect(plan.receiverGroupOptions.keys, ['', 'part:role-pd']);
    expect(plan.receiverPersonOptions.keys, [_director.id, _otherDirector.id]);
    expect(
      store.isHandoffCurrent(plan.withReceiver('part:role-art', '')),
      isFalse,
    );
    expect(store.isHandoffCurrent(plan.withReceiver('', _artist.id)), isFalse);
    expect(
      () => store.transition(
        task.id,
        'doing',
        expectedVersion: task.version,
        routeId: 'default-handoff',
      ),
      throwsStateError,
    );
    expect(store.find(task.id).same(task), isTrue);
    store.confirmHandoff(plan.withReceiver('', _director.id));
    expect(store.find(task.id).workflowPerson, _director.id);
  });

  test('purpose guards and shared mutation validation reject forged intent and receiver changes', () {
    final project = _project(destination: 'part:role-pd');
    final task = _task(status: 'doing');
    final actor = project.people.singleWhere((p) => p.id == _planner.id);
    expect(
      availableWorkflowRoutes(
        actor,
        task,
        project,
      ).any((r) => r.action == 'reject'),
      isFalse,
    );
    expect(
      () => validateTaskMutation(
        actor: actor,
        current: task,
        next: task.copy({'workflowPurpose': 'review', 'version': 2}),
        workflowProject: project,
      ),
      throwsStateError,
    );
    final route = project.workflowSheet!.routes.singleWhere(
      (r) => r.id == 'default-handoff',
    );
    final handed = applyWorkflowRoute(
      task,
      route,
      project,
      receiverPerson: _director.id,
    ).copy({'version': 2});
    validateTaskMutation(
      actor: actor,
      current: task,
      next: handed,
      workflowProject: project,
    );
    expect(
      () => validateTaskMutation(
        actor: actor,
        current: task,
        next: handed.copy({'workflowPerson': _artist.id}),
        workflowProject: project,
      ),
      throwsStateError,
    );
    expect(
      () => validateTaskMutation(
        actor: actor,
        current: task,
        next: handed.copy({'workflowPurpose': ''}),
        workflowProject: project,
      ),
      throwsStateError,
    );
  });

  test('legacy review and revision map to progress while explicit custom categories remain respected', () {
    final base = _project();
    final legacy = ProjectManifest.fromJson({
      ...base.json,
      'workflowStages': [
        ...defaultWorkflowStages.take(2).map((s) => s.json),
        const WorkflowStage('review', '검토').json,
        defaultWorkflowStages.last.json,
      ],
      'workflowSheet': WorkflowSheet.defaultFor([
        'todo',
        'doing',
        'review',
        'done',
      ]).json,
    });
    final raw = {..._task(status: 'review').data}..remove('workflowPurpose');
    final old = WorkTask.fromJson(raw);
    expect(old.workflowPurpose, '');
    expect(workflowTaskPurpose(old, legacy), 'review');
    expect(workflowBoardCategory(old, legacy), 'inProgress');
    expect(workflowBoardCategory(_task(status: 'rework'), null), 'inProgress');
    final custom = ProjectManifest.fromJson({
      ...legacy.json,
      'workflowStages': [
        ...defaultWorkflowStages.take(2).map((s) => s.json),
        const WorkflowStage('review', '작업 검토', category: 'inProgress').json,
        defaultWorkflowStages.last.json,
      ],
    });
    expect(workflowBoardCategory(old, custom), 'inProgress');
    expect(custom.workflowStages, hasLength(4));
  });

  test('personal inbox does not treat editable everyone routes as assignment to every member', () {
    final open = _task().copy({'workflowPerson': ''});
    final store = _store(task: open);
    expect(store.isAssignedToMe(open), isTrue);
    store.setMeta('profile', _director.id);
    expect(store.canEditContent(open), isTrue);
    expect(store.isAssignedToMe(open), isFalse);
    final groupTask = open.copy({'workflowTarget': 'part:role-pd'});
    expect(store.isAssignedToMe(groupTask), isTrue);
  });

  test('remote review delivery is recognized at confirmation status, including same-status handoffs', () {
    final defaults = _project();
    const route = WorkflowSheetRoute(
      id: 'todo-review-request',
      from: 'todo',
      to: 'todo',
      assignment: 'select',
      purpose: 'review',
    );
    final project = ProjectManifest.fromJson({
      ...defaults.json,
      'workflowSheet': WorkflowSheet(
        nodes: defaults.workflowSheet!.nodes,
        routes: [...defaults.workflowSheet!.routes, route],
      ).json,
    });
    final base = _task();
    final remote = applyWorkflowRoute(
      base,
      route,
      project,
      receiverPerson: _director.id,
    ).copy({'version': 2});
    final store = _store(project: project, task: base, actor: _director);
    final snapshot = {
      'schemaVersion': 1,
      'projectId': project.id,
      'revision': 'remote-review',
      'tasks': [remote.data],
    };
    expect(store.importSnapshot(snapshot).applied, isTrue);
    expect(store.notifications.single['eventType'], 'task.review');
    store.importSnapshot(snapshot);
    expect(store.notifications, hasLength(1));
    final firstPull = _store(project: project, actor: _director);
    firstPull.importSnapshot(snapshot);
    expect(firstPull.notifications.single['eventType'], 'task.review');
    final unrelated = _store(project: project, task: base, actor: _artist);
    unrelated.importSnapshot(snapshot);
    expect(unrelated.notifications, isEmpty);
  });

  test('legacy rejection intent survives starting work while empty historical proofs remain admissible', () {
    final defaults = _project();
    final project = ProjectManifest.fromJson({
      ...defaults.json,
      'workflowStages': [
        ...defaultWorkflowStages.take(2).map((s) => s.json),
        const WorkflowStage('review', '검토').json,
        defaultWorkflowStages.last.json,
      ],
      'workflowSheet': WorkflowSheet.defaultFor([
        'todo',
        'doing',
        'review',
        'done',
      ]).json,
    });
    final returned = _task().copy({
      'workflowRoute': 'default-review-return',
      'reworkReason': '기획을 보완해 주세요.',
    });
    expect(workflowTaskPurpose(returned, project), 'revision');
    final start = project.workflowSheet!.routes.singleWhere(
      (r) => r.from == 'todo',
    );
    final modern = applyWorkflowRoute(
      returned,
      start,
      project,
    ).copy({'version': 2});
    expect(modern.workflowPurpose, 'revision');
    expect(workflowTaskPurpose(modern, project), 'revision');
    final actor = project.people.singleWhere((p) => p.id == _planner.id);
    validateTaskMutation(
      actor: actor,
      current: returned,
      next: modern,
      workflowProject: project,
    );
    final historical = modern.copy({'workflowPurpose': ''});
    validateTaskMutation(
      actor: actor,
      current: returned,
      next: historical,
      workflowProject: project,
    );
    final explicit = returned.copy({'workflowPurpose': 'revision'});
    expect(
      () => validateTaskMutation(
        actor: actor,
        current: explicit,
        next: historical,
        workflowProject: project,
      ),
      throwsStateError,
    );
  });
}
