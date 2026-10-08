import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_policy_test.dart' as policy;

const _qa = Person(
  'gh-6',
  'QA 담당자',
  'Q',
  'unassigned',
  0,
  parts: ['QA'],
  login: 'qa',
);
const _stages = [
  WorkflowStage('todo', '등록', category: 'todo', initial: true),
  WorkflowStage('doing', '작업 중', category: 'inProgress'),
  WorkflowStage(
    'stage-qa',
    'QA 검토',
    category: 'inProgress',
    editPolicy: 'locked',
  ),
  WorkflowStage(
    'stage-pd',
    'PD 승인',
    category: 'inProgress',
    editPolicy: 'locked',
  ),
  WorkflowStage('stage-closed', '완료', category: 'done'),
  WorkflowStage('stage-cancelled', '취소', category: 'done'),
];
const _routes = [
  WorkflowSheetRoute(
    id: 'start',
    from: 'todo',
    to: 'doing',
    name: '작업 시작',
    destination: 'part:role-plan',
    person: 'gh-2',
  ),
  WorkflowSheetRoute(
    id: 'qa-submit',
    from: 'doing',
    to: 'stage-qa',
    name: 'QA 검토 요청',
    source: 'part:role-plan',
    destination: 'part:role-qa',
    operation: 'submit',
  ),
  WorkflowSheetRoute(
    id: 'qa-pass',
    from: 'stage-qa',
    to: 'stage-pd',
    name: 'PD 승인 요청',
    action: 'approve',
    source: 'part:role-qa',
    destination: 'part:role-pd',
    operation: 'accept',
  ),
  WorkflowSheetRoute(
    id: 'qa-return',
    from: 'stage-qa',
    to: 'doing',
    name: '기획에 반려',
    action: 'reject',
    source: 'part:role-qa',
    assignment: 'assignee',
  ),
  WorkflowSheetRoute(
    id: 'pd-pass',
    from: 'stage-pd',
    to: 'stage-closed',
    name: '최종 승인',
    action: 'approve',
    source: 'part:role-pd',
    assignment: 'keep',
  ),
  WorkflowSheetRoute(
    id: 'reopen',
    from: 'stage-closed',
    to: 'doing',
    name: '작업 재개',
    assignment: 'assignee',
    operation: 'reopen',
  ),
];

ProjectManifest _project({
  List<WorkflowStage> stages = _stages,
  List<WorkflowSheetRoute> routes = _routes,
  List<WorkflowSheetNode>? nodes,
}) => ProjectManifest(
  'jira-engine-project',
  '일반 워크플로',
  policy.admin.id,
  [
    policy.admin,
    policy.planner,
    policy.director,
    policy.otherDirector,
    policy.artist,
    _qa,
  ],
  roles: const [
    ProjectRole('role-plan', '기획', {}),
    ProjectRole('role-pd', 'PD', {}),
    ProjectRole('role-art', '아트', {}),
    ProjectRole('role-qa', 'QA', {}),
  ],
  parts: const ['기획', 'PD', '아트', 'QA'],
  unifiedParts: true,
  workflowStages: stages,
  workflowSheet: WorkflowSheet(
    nodes:
        nodes ??
        [
          for (var i = 0; i < stages.length; i++)
            WorkflowSheetNode(stages[i].id, stages[i].id, x: i * 180),
        ],
    routes: routes,
  ),
);

WorkTask _seed({
  String status = 'todo',
  String target = 'part:role-plan',
  String person = 'gh-2',
  String route = '',
  String completedDate = '',
}) => WorkTask.fromJson({
  ...policy.draft(),
  'id': 'task-jira-engine',
  'status': status,
  'workflowTarget': target,
  'workflowPerson': person,
  'workflowRoute': route,
  'completedDate': completedDate,
  'reworkReason': '',
  'version': 1,
  'updatedAt': '2026-10-07T00:00:00Z',
});

TaskStore _store({
  ProjectManifest? project,
  Person actor = policy.planner,
  WorkTask? seed,
}) {
  final store = TaskStore(
    ':memory:',
    project: project ?? _project(),
    identity: actor,
    seed: seed == null ? [] : [seed.data],
  );
  addTearDown(store.dispose);
  return store;
}

WorkTask _move(
  TaskStore store,
  WorkTask task,
  String stage, {
  String? route,
  String comment = '',
}) {
  store.confirmHandoff(
    store.planHandoff(task, stage, routeId: route),
    reason: comment,
  );
  return store.find(task.id);
}

Map<String, dynamic> _snapshot(
  WorkTask task, {
  String revision = 'remote-v2',
}) => {
  'schemaVersion': 1,
  'projectId': 'jira-engine-project',
  'revision': revision,
  'tasks': [task.data],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an old default-name list with explicit workflow properties is preserved',
    () {
      final raw =
          <String, dynamic>{
              ..._project().json,
              'workflowStages': [
                const WorkflowStage(
                  'todo',
                  '확인',
                  category: 'todo',
                  initial: true,
                ).json,
                const WorkflowStage('doing', '진행').json,
                const WorkflowStage('done', '완료').json,
              ],
            }
            ..remove('workflowDefaultsVersion')
            ..remove('workflowSheet');
      final parsed = ProjectManifest.fromJson(raw);
      expect(parsed.workflowStages.map((stage) => stage.id), [
        'todo',
        'doing',
        'done',
      ]);
      expect(parsed.workflowStages.map((stage) => stage.name), [
        '확인',
        '진행',
        '완료',
      ]);
      expect(parsed.initialStatusId, 'todo');
      expect(parsed.workflowStages.first.category, 'todo');
      expect(parsed.workflowStages.first.initial, isTrue);
    },
  );

  test('the explicit registration status survives visual order changes', () {
    final store = _store(project: _project(stages: _stages.reversed.toList()));
    expect(store.project!.initialStatusId, 'todo');
    expect(store.canCreate, isTrue);
    final first = store.save(policy.draft());
    expect(first.status, 'todo');
    store.updateProject(
      _project(
        stages: [
          _stages[4],
          _stages[1],
          _stages[0],
          ..._stages.skip(2).where((s) => s.id != 'stage-closed'),
        ],
      ),
    );
    expect(store.save({...policy.draft(), 'title': '두번째 작업'}).status, 'todo');
  });

  test(
    'completion and content policy use categories rather than status IDs',
    () {
      final project = _project(
        stages: [
          const WorkflowStage(
            'done',
            '시작',
            category: 'todo',
            editPolicy: 'recipients',
            initial: true,
          ),
          const WorkflowStage('stage-closed', '종료', category: 'done'),
          const WorkflowStage('stage-cancelled', '취소', category: 'done'),
        ],
        routes: const [],
      );
      final store = _store(project: project);
      final created = store.save(policy.draft());
      expect(created.status, 'done');
      expect(created.completedDate, isEmpty);
      expect(store.isCompleted(created), isFalse);
      expect(store.canEditContent(created), isTrue);
      for (final status in ['stage-closed', 'stage-cancelled']) {
        final complete = created.copy({
          'status': status,
          'completedDate': '2026-10-07',
        });
        expect(store.isCompleted(complete), isTrue);
        expect(store.canEditContent(complete), isFalse);
      }
    },
  );

  test('QA and PD presets preserve recipients while unfinished content remains collaborative', () {
    final store = _store();
    var task = _move(store, store.save(policy.draft()), 'doing');
    task = _move(store, task, 'stage-qa');
    expect(store.canEditContent(task), isTrue);
    expect(store.availableHandoffs(task).single.routeId, 'manual-finish');
    store.setMeta('profile', _qa.id);
    expect(store.canEditContent(task), isTrue);
    expect(store.availableHandoffs(task).map((p) => p.buttonLabel), [
      '최종 완료',
      'PD 승인 요청',
      '기획에 반려',
    ]);
    expect(
      () => store.save({
        ...task.data,
        'title': '제출 후 수정',
      }, expectedVersion: task.version),
      returnsNormally,
    );
    task = store.find(task.id);
    task = _move(store, task, 'stage-pd');
    store.setMeta('profile', policy.director.id);
    expect(store.canEditContent(task), isTrue);
    expect(
      store
          .availableHandoffs(task)
          .singleWhere((p) => p.routeId == 'pd-pass')
          .buttonLabel,
      '최종 승인',
    );
  });

  test('everyone content policy grants editing without changing routing recipients', () {
    final project = _project(
      stages: [
        for (final s in _stages)
          if (s.id == 'doing')
            WorkflowStage(
              s.id,
              s.name,
              category: s.category,
              editPolicy: 'everyone',
            )
          else
            s,
      ],
    );
    final store = _store(
      project: project,
      actor: policy.artist,
      seed: _seed(status: 'doing'),
    );
    final task = store.find('task-jira-engine');
    expect(store.canEditContent(task), isTrue);
    expect(store.availableHandoffs(task).single.routeId, 'manual-finish');
    final edited = store.save({
      ...task.data,
      'description': '공동 편집',
    }, expectedVersion: task.version);
    expect(edited.workflowTarget, task.workflowTarget);
    expect(edited.workflowPerson, policy.planner.id);
  });

  test('transition buttons remain visible and execution validators fail atomically', () {
    final required = WorkflowSheetRoute.fromJson({
      ..._routes[1].json,
      'commentRequired': true,
      'requiredFields': ['description', 'dueDate'],
    });
    final store = _store(project: _project(routes: [_routes[0], required]));
    var task = _move(
      store,
      store.save({...policy.draft(), 'description': ''}),
      'doing',
    );
    final plan = store.planHandoff(task, 'stage-qa');
    expect(plan.buttonLabel, 'QA 검토 요청');
    expect(plan.needsComment, isTrue);
    expect(plan.requiredFields, ['description', 'dueDate']);
    final activityCount = store.activity.length;
    for (final comment in ['', '검토해주세요']) {
      expect(
        () => store.confirmHandoff(plan, reason: comment),
        throwsStateError,
      );
      expect(store.find(task.id).version, task.version);
      expect(store.find(task.id).same(task), isTrue);
      expect(store.activity.length, activityCount);
      expect(store.records('github_queue'), isEmpty);
    }
    task = store.save({
      ...task.data,
      'description': '검토 범위',
    }, expectedVersion: task.version);
    expect(
      () => store.confirmHandoff(
        store.planHandoff(task, 'stage-qa'),
        reason: '검토해주세요',
      ),
      throwsStateError,
    );
    task = store.save({
      ...task.data,
      'dueDate': '2026-10-21',
    }, expectedVersion: task.version);
    task = _move(store, task, 'stage-qa', comment: '검토해주세요');
    expect(task.reworkReason, '검토해주세요');
    expect(task.workflowTarget, 'part:role-qa');
  });

  test('keep converts a legacy reviewer into the same explicit recipient', () {
    final route = const WorkflowSheetRoute(
      id: 'keep',
      from: 'review',
      to: 'doing',
      assignment: 'keep',
    );
    final project = _project(
      stages: policy.legacyReviewStages,
      routes: [route],
    );
    final original = _seed(status: 'review', target: 'legacy', person: '');
    final store = _store(
      project: project,
      actor: policy.director,
      seed: original,
    );
    final next = _move(store, original, 'doing');
    expect(next.assigneeId, policy.planner.id);
    expect(next.workflowTarget, isEmpty);
    expect(next.workflowPerson, policy.director.id);
    expect(store.canEditContent(next), isTrue);
    store.setMeta('profile', policy.planner.id);
    expect(store.canEditContent(next), isTrue);
  });

  test(
    'keep assignee and actor assignments have distinct recipient effects',
    () {
      for (final (assignment, expectedTarget, expectedPerson) in [
        ('keep', 'part:role-pd', ''),
        ('assignee', '', policy.planner.id),
        ('actor', '', policy.director.id),
      ]) {
        final original = _seed(
          status: 'stage-pd',
          target: 'part:role-pd',
          person: '',
        );
        final route = WorkflowSheetRoute(
          id: 'assign-$assignment',
          from: 'stage-pd',
          to: 'doing',
          assignment: assignment,
        );
        final store = _store(
          project: _project(routes: [route]),
          actor: policy.director,
          seed: original,
        );
        final next = _move(store, original, 'doing');
        expect(next.workflowTarget, expectedTarget);
        expect(next.workflowPerson, expectedPerson);
        expect(next.assigneeId, policy.planner.id);
      }
    },
  );

  test(
    'custom completed issues reopen only through an explicit direct transition',
    () {
      final task = _seed(
        status: 'stage-closed',
        target: 'part:role-pd',
        person: '',
        completedDate: '2026-10-07',
      );
      final store = _store(actor: policy.director, seed: task);
      expect(store.isCompleted(task), isTrue);
      expect(store.availableHandoffs(task).single.buttonLabel, '작업 재개');
      expect(() => store.planHandoff(task, 'todo'), throwsStateError);
      final next = _move(store, task, 'doing');
      expect(store.isCompleted(next), isFalse);
      expect(next.completedDate, isEmpty);
      expect(next.workflowPerson, policy.planner.id);
      store.setMeta('profile', policy.planner.id);
      expect(store.canEditContent(next), isTrue);
    },
  );

  test('the same unfinished-state handoff can execute repeatedly with exact version checks', () {
    final route = const WorkflowSheetRoute(
      id: 'take',
      from: 'stage-pd',
      to: 'stage-pd',
      name: '검토 맡기',
      assignment: 'actor',
      operation: 'take',
    );
    final original = _seed(
      status: 'stage-pd',
      target: 'part:role-pd',
      person: '',
    );
    final store = _store(
      project: _project(routes: [route]),
      actor: policy.director,
      seed: original,
    );
    final firstPlan = store.planHandoff(original, 'stage-pd');
    var task = _move(store, original, 'stage-pd');
    expect(task.workflowPerson, policy.director.id);
    expect(() => store.confirmHandoff(firstPlan), throwsStateError);
    task = _move(store, task, 'stage-pd');
    task = _move(store, task, 'stage-pd');
    expect(task.version, 4);
    expect(store.canEditContent(task), isTrue);
    expect(store.activity, hasLength(3));
  });

  test('receiving a custom locked stage creates a review notification', () {
    final base = _seed(status: 'doing');
    final project = _project();
    final remote = applyWorkflowRoute(
      base,
      _routes[1],
      project,
    ).copy({'version': 2});
    final store = _store(project: project, actor: _qa, seed: base);
    final result = store.importSnapshot(_snapshot(remote));
    expect(result.applied, isTrue);
    expect(
      store.records('notification_inbox').single['eventType'],
      'task.review',
    );
    expect(store.records('notification_inbox').single['recipientId'], _qa.id);
    store.importSnapshot(_snapshot(remote));
    expect(store.records('notification_inbox'), hasLength(1));
  });

  test('diagram moves keep prepared confirmations valid but policy edits invalidate them', () {
    final project = _project();
    final store = _store(
      project: project,
      seed: _seed(status: 'doing'),
    );
    final task = store.find('task-jira-engine');
    final plan = store.planHandoff(task, 'stage-qa');
    store.updateProject(
      _project(
        nodes: [
          for (final n in project.workflowSheet!.nodes)
            WorkflowSheetNode(n.id, n.stageId, x: n.x + 220, y: n.y - 80),
        ],
        routes: [
          for (final r in _routes)
            WorkflowSheetRoute.fromJson({
              ...r.json,
              'labelDx': 55,
              'labelDy': 15,
            }),
        ],
      ),
    );
    expect(store.isHandoffCurrent(plan), isTrue);
    store.updateProject(
      _project(
        routes: [
          for (final r in _routes)
            if (r.id == 'qa-submit')
              WorkflowSheetRoute.fromJson({...r.json, 'commentRequired': true})
            else
              r,
        ],
      ),
    );
    expect(store.isHandoffCurrent(plan), isFalse);
    expect(() => store.confirmHandoff(plan), throwsStateError);
    expect(store.find(task.id).same(task), isTrue);
  });

  test('concurrent status and recipient mutations are kept as one conflicting handoff', () {
    final self = const WorkflowSheetRoute(
      id: 'redirect',
      from: 'todo',
      to: 'todo',
      destination: 'part:role-pd',
    );
    final project = _project(routes: [..._routes, self]);
    final base = _seed();
    final store = _store(project: project, seed: base);
    final local = _move(store, base, 'doing');
    final remote = applyWorkflowRoute(base, self, project).copy({'version': 2});
    final result = store.importSnapshot(_snapshot(remote));
    expect(result.applied, isFalse);
    expect(result.conflicts.single['field'], '워크플로 전환');
    expect(store.find(base.id).same(local), isTrue);
    expect(store.find(base.id).workflowPerson, policy.planner.id);
    expect(store.baseline[base.id]!.same(base), isTrue);
  });

  test(
    'a remote editable-state handoff merges safe independent local content',
    () {
      final project = _project();
      final base = _seed();
      final store = _store(project: project, seed: base);
      final local = store.save({
        ...base.data,
        'description': '로컬 보완 내용',
      }, expectedVersion: base.version);
      final remote = applyWorkflowRoute(
        base,
        _routes[0],
        project,
      ).copy({'version': 2});
      final result = store.importSnapshot(_snapshot(remote));
      expect(result.applied, isTrue);
      expect(result.conflicts, isEmpty);
      final merged = store.find(base.id);
      expect(merged.status, 'doing');
      expect(merged.workflowRoute, 'start');
      expect(merged.workflowPerson, policy.planner.id);
      expect(merged.description, local.description);
      expect(store.baseline[base.id]!.same(remote), isTrue);
      expect(store.canEditContent(merged), isTrue);
    },
  );

  test('remote legacy locked-state handoffs merge independent local content for collaborators', () {
    final project = _project();
    final base = _seed(status: 'doing');
    final store = _store(project: project, seed: base);
    final local = store.save({
      ...base.data,
      'description': '아직 제출되지 않은 내용',
    }, expectedVersion: base.version);
    final remote = applyWorkflowRoute(
      base,
      _routes[1],
      project,
    ).copy({'version': 2});
    final result = store.importSnapshot(_snapshot(remote));
    expect(result.applied, isTrue);
    expect(result.conflicts, isEmpty);
    expect(store.find(base.id).workflowPerson, remote.workflowPerson);
    expect(store.find(base.id).status, remote.status);
    expect(store.find(base.id).description, local.description);
    expect(store.find(base.id).description, '아직 제출되지 않은 내용');
  });

  test('a completed-state self transition preserves the original completion date on a later day', () {
    const route = WorkflowSheetRoute(
      id: 'archive-note',
      from: 'stage-closed',
      to: 'stage-closed',
      assignment: 'keep',
      name: '완료 내역 확인',
    );
    final project = _project(routes: [route]);
    final original = _seed(
      status: 'stage-closed',
      target: 'part:role-pd',
      person: '',
      completedDate: '2026-10-07',
    );
    final store = _store(
      project: project,
      actor: policy.director,
      seed: original,
    );
    final applied = applyWorkflowRoute(
      original,
      route,
      project,
      completionDate: '2026-10-08',
    );
    expect(applied.completedDate, '2026-10-07');
    final next = _move(store, original, 'stage-closed');
    expect(next.completedDate, '2026-10-07');
    expect(next.version, 2);
    expect(store.isCompleted(next), isTrue);
  });

  test('handoff to another part merges independent content without an exclusive recipient lock', () {
    final private = WorkflowSheetRoute.fromJson({
      ..._routes[0].json,
      'destination': 'part:role-pd',
      'person': policy.director.id,
    });
    final project = _project(routes: [private]);
    final base = _seed();
    final store = _store(project: project, seed: base);
    final local = store.save({
      ...base.data,
      'description': '아직 전달하지 않은 수정',
    }, expectedVersion: base.version);
    final remote = applyWorkflowRoute(
      base,
      private,
      project,
    ).copy({'version': 2});
    expect(project.isLockedStatus(remote.status), isFalse);
    expect(canEditWorkflowTask(store.actor, remote, project), isTrue);
    final result = store.importSnapshot(_snapshot(remote));
    expect(result.applied, isTrue);
    expect(result.conflicts, isEmpty);
    expect(store.find(base.id).description, local.description);
    expect(store.find(base.id).workflowPerson, policy.director.id);
    expect(store.find(base.id).status, 'doing');
    expect(store.find(base.id).description, '아직 전달하지 않은 수정');
  });

  test('collapsed validation accounts for required input satisfied before an editable destination clears it', () {
    final required = WorkflowSheetRoute.fromJson({
      ..._routes[0].json,
      'requiredFields': ['description'],
    });
    final project = _project(routes: [required]);
    final store = _store(project: project);
    final base = store.save({...policy.draft(), 'description': ''});
    store.put(base, table: 'baseline_tasks');
    var task = store.save({
      ...base.data,
      'description': '전환 시에는 작성됨',
    }, expectedVersion: base.version);
    task = _move(store, task, 'doing');
    task = store.save({
      ...task.data,
      'description': '',
    }, expectedVersion: task.version);
    expect(task.version, 4);
    expect(task.status, 'doing');
    expect(task.description, isEmpty);
    final proof = parseWorkflowRevisions(store.changes.single['steps']);
    expect(proof!.map((step) => step.version), [2, 3, 4]);
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: task,
        workflowProject: project,
        allowCollapsedTransitions: true,
        revisions: proof,
      ),
      returnsNormally,
    );
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: task,
        workflowProject: project,
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
    final locked = _project(
      routes: [required],
      stages: [
        for (final s in _stages)
          if (s.id == 'doing')
            WorkflowStage(
              s.id,
              s.name,
              category: s.category,
              editPolicy: 'locked',
            )
          else
            s,
      ],
    );
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: base,
        next: task,
        workflowProject: locked,
        allowCollapsedTransitions: true,
        revisions: proof,
      ),
      returnsNormally,
    );
  });
}
