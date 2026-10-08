import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'v020_store_test.dart' show project, owner, worker, reviewer, draft;

ProjectManifest openProject({
  WorkflowAutomation automation = const WorkflowAutomation(),
}) => ProjectManifest.fromJson({
  ...project.json,
  'roles': [
    const ProjectRole('role-work-only', '작업 담당', {'task.work'}).json,
  ],
  'members': [
    owner.json,
    {
      ...worker.json,
      'parts': ['기획'],
    },
    {
      ...reviewer.json,
      'parts': ['QA'],
    },
    const Person(
      'gh-4',
      '다른 작업자',
      '작',
      'role-work-only',
      0,
      login: 'worker4',
    ).json,
    const Person(
      'gh-5',
      '비활성 참여자',
      '비',
      'viewer',
      0,
      login: 'viewer5',
      enabled: false,
    ).json,
  ],
  'workflowAutomation': automation.json,
}).partWorkflowView;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('untouched unversioned three-stage defaults migrate once without rewriting explicit project choices', () {
    final old = Map<String, dynamic>.from(project.json)
      ..remove('workflowDefaultsVersion')
      ..['workflowStages'] = [
        const WorkflowStage('todo', '확인').json,
        const WorkflowStage('doing', '진행').json,
        const WorkflowStage('done', '완료').json,
      ]
      ..['workflowAutomation'] = const WorkflowAutomation().json;
    final migrated = ProjectManifest.fromJson(old);
    expect(migrated.workflowStages.map((s) => s.name), ['확인중', '진행중', '완료']);
    expect(migrated.json['workflowDefaultsVersion'], 2);
    expect(ProjectManifest.fromJson(migrated.json).json, migrated.json);
    expect(
      old.containsKey('workflowDefaultsVersion'),
      isFalse,
      reason:
          'Read normalization does not mutate the original remote document.',
    );
    expect((old['workflowStages'] as List).length, 3);
    final deletedReview = ProjectManifest.fromJson({
      ...migrated.json,
      'workflowStages': old['workflowStages'],
      'workflowAutomation': const WorkflowAutomation().json,
    });
    expect(deletedReview.workflowStages.map((s) => s.id), [
      'todo',
      'doing',
      'done',
    ]);
    final customized = ProjectManifest.fromJson({
      ...old,
      'workflowAutomation': const WorkflowAutomation(
        connections: [WorkflowConnection('todo', 'doing', assignedOnly: true)],
      ).json,
    });
    expect(customized.workflowStages.map((s) => s.id), [
      'todo',
      'doing',
      'done',
    ]);
    expect(
      customized.workflowAutomation.connections.single.assignedOnly,
      isTrue,
    );
    for (final changed in [
      [...(old['workflowStages'] as List).reversed],
      [
        const WorkflowStage('todo', '시작').json,
        ...(old['workflowStages'] as List).skip(1),
      ],
      [
        ...(old['workflowStages'] as List),
        const WorkflowStage('stage-extra', '추가').json,
      ],
    ]) {
      final preserved = ProjectManifest.fromJson({
        ...old,
        'workflowStages': changed,
      });
      expect(preserved.workflowStages.map((s) => s.json), changed);
    }
    final disabled = ProjectManifest.fromJson({
      ...old,
      'workflowAutomation': const WorkflowAutomation(
        disabledConnections: ['todo/advance'],
      ).json,
    });
    expect(disabled.workflowStages.map((s) => s.id), ['todo', 'doing', 'done']);
    final older = ProjectManifest.fromJson({
      ...old,
      'workflowDefaultsVersion': 1,
    });
    expect(older.workflowStages.map((s) => s.id), ['todo', 'doing', 'done']);
  });

  test('explicit legacy catalog and generated links preserve the four-stage open worker flow', () {
    final p = openProject();
    expect(p.workflowStages.map((s) => s.name), ['확인중', '진행중', '검토', '완료']);
    expect(
      p.workflowSheet!.routes.map(
        (c) =>
            '${p.workflowSheet!.stageFor(c.from)}/${c.action}/${p.workflowSheet!.stageFor(c.to)}',
      ),
      [
        'todo/advance/doing',
        'doing/advance/review',
        'review/approve/done',
        'review/reject/todo',
      ],
    );
    expect(
      p.workflowSheet!.routes.every(
        (c) => c.source.isEmpty && c.destination.isEmpty,
      ),
      isTrue,
    );
    expect(p.workflowSheet!.routes.every((c) => c.person.isEmpty), isTrue);
    final restored = ProjectManifest.fromJson(p.json);
    expect(restored.workflowSheet!.json, p.workflowSheet!.json);
    final missing = Map<String, dynamic>.from(project.json)
      ..remove('workflowStages')
      ..remove('workflowStagesConfigured')
      ..remove('workflowAutomation');
    expect(ProjectManifest.fromJson(missing).workflowStages.map((s) => s.id), [
      'todo',
      'doing',
      'done',
    ]);
    final legacy = ProjectManifest.fromJson({
      ...project.json,
      'workflowStages': [
        const WorkflowStage('todo', '확인').json,
        const WorkflowStage('doing', '진행').json,
        const WorkflowStage('done', '완료').json,
      ],
      'workflowAutomation': const WorkflowAutomation().json,
    });
    expect(legacy.workflowStages.map((s) => s.id), ['todo', 'doing', 'done']);
  });

  test('active collaborators edit unfinished work including review while completed work stays protected', () {
    final p = openProject();
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    final task = store.save(draft());
    store.setMeta('profile', 'gh-4');
    expect(
      store.actor.canReview,
      isTrue,
      reason:
          'Review is governed by the route instead of a separate fine grant.',
    );
    void move(String status, {String reason = ''}) => store.transition(
      task.id,
      status,
      reason: reason,
      expectedVersion: store.find(task.id).version,
    );
    void edit(String description) {
      final current = store.find(task.id);
      expect(store.canEditContent(current), isTrue);
      expect(store.canActOnTask(current), isTrue);
      store.save({
        ...current.data,
        'description': description,
      }, expectedVersion: current.version);
    }

    edit('확인중 내용 수정');
    move('doing');
    edit('진행중 내용 수정');
    move('review');
    final submitted = store.find(task.id);
    expect(store.canEditContent(submitted), isTrue);
    expect(
      () => store.save({
        ...submitted.data,
        'description': '검토 내용 수정',
      }, expectedVersion: submitted.version),
      returnsNormally,
    );
    expect(() => move('todo'), throwsStateError);
    move('todo', reason: '작업 보완');
    expect(store.find(task.id).assigneeId, worker.id);
    expect(store.find(task.id).reworkReason, '작업 보완');
    move('doing');
    move('review');
    move('done');
    final completed = store.find(task.id);
    expect(store.canEditContent(completed), isFalse);
    expect(store.canMove(completed, 'todo'), isFalse);
    expect(
      () => store.save({
        ...completed.data,
        'description': '완료 이후 수정',
      }, expectedVersion: completed.version),
      throwsStateError,
    );
  });

  test('shared validation allows review collaboration and rejects inactive authors and edits after completion', () {
    final p = openProject();
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    final task = store.save(draft());
    final actor = p.people.firstWhere((person) => person.id == 'gh-4');
    final inactive = p.people.last;
    void validate(
      Person person,
      WorkTask current,
      WorkTask next, {
      bool collapsed = false,
    }) => validateTaskMutation(
      actor: person,
      current: current,
      next: next,
      allowCollapsedTransitions: collapsed,
      customStages: p.workflowStages.map((s) => s.id).toList(),
      workflowConnections: p.workflowConnections,
      workflowProject: p,
    );
    final sheet = p.workflowSheet!;
    final progressed = applyWorkflowRoute(
      task,
      sheet.outgoing('todo').single,
      p,
    ).copy({'version': 2});
    final submitted = applyWorkflowRoute(
      progressed,
      sheet.outgoing('doing').single,
      p,
    ).copy({'version': 3});
    expect(isWorkflowRecipient(actor, submitted, p), isTrue);
    final edited = submitted.copy({
      'description': '다른 작업자의 검토 수정',
      'version': 4,
    });
    expect(() => validate(actor, submitted, edited), returnsNormally);
    expect(() => validate(inactive, submitted, edited), throwsStateError);
    final returned = applyWorkflowRoute(
      submitted,
      sheet.outgoing('review').firstWhere((r) => r.action == 'reject'),
      p,
      reason: '보완',
    ).copy({'version': 4});
    expect(() => validate(actor, submitted, returned), returnsNormally);
    expect(() => validate(inactive, submitted, returned), throwsStateError);
    final complete =
        applyWorkflowRoute(
          submitted,
          sheet.outgoing('review').firstWhere((r) => r.action == 'approve'),
          p,
          completionDate: '2026-10-06',
        ).copy({
          'description': '오프라인 단계 진행과 수정',
          'completedDate': '2026-10-06',
          'version': 5,
        });
    expect(
      () =>
          validate(actor, task, complete.copy({'version': 4}), collapsed: true),
      throwsStateError,
      reason: 'Three transitions and a content save consume four revisions.',
    );
    expect(
      () => validate(actor, task, complete, collapsed: true),
      returnsNormally,
    );
    expect(
      () => validate(inactive, task, complete, collapsed: true),
      throwsStateError,
    );
    expect(
      () => validate(
        actor,
        complete,
        complete.copy({'description': '잠긴 작업', 'version': 6}),
      ),
      throwsStateError,
    );
    store.setMeta('profile', inactive.id);
    store.put(submitted);
    expect(store.canEditContent(submitted), isFalse);
    expect(store.canMove(submitted, 'done'), isFalse);
    expect(store.canActOnTask(submitted), isFalse);
  });

  test('saved part conditions stay optional while common actions and editing allow all active members', () {
    final initial = openProject();
    final planning = initial.roles.firstWhere((r) => r.name == '기획').id;
    final qa = initial.roles.firstWhere((r) => r.name == 'QA').id;
    final p = ProjectManifest.fromJson({
      ...initial.json,
      'workflowSheet': WorkflowSheet(
        nodes: const [
          WorkflowSheetNode('todo', 'todo'),
          WorkflowSheetNode('doing', 'doing'),
          WorkflowSheetNode('review', 'review'),
          WorkflowSheetNode('done', 'done'),
        ],
        routes: [
          WorkflowSheetRoute(
            id: 'start',
            from: 'todo',
            to: 'doing',
            source: 'part:$planning',
            destination: 'part:$planning',
            person: worker.id,
          ),
          WorkflowSheetRoute(
            id: 'submit',
            from: 'doing',
            to: 'review',
            source: 'part:$planning',
            destination: 'part:$qa',
            person: reviewer.id,
          ),
          WorkflowSheetRoute(
            id: 'approve',
            from: 'review',
            to: 'done',
            source: 'part:$qa',
            action: 'approve',
          ),
          WorkflowSheetRoute(
            id: 'reject',
            from: 'review',
            to: 'todo',
            source: 'part:$qa',
            destination: 'part:$planning',
            person: worker.id,
            action: 'reject',
          ),
        ],
      ).json,
    });
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    final task = store.save(draft());
    store.setMeta('profile', 'gh-4');
    expect(store.canMove(task, 'doing'), isTrue);
    expect(store.canEditContent(task), isTrue);
    store.setMeta('profile', worker.id);
    store.transition(task.id, 'doing', expectedVersion: task.version);
    store.transition(
      task.id,
      'review',
      expectedVersion: store.find(task.id).version,
    );
    final submitted = store.find(task.id);
    for (final member in p.people) {
      expect(
        canEditTaskContent(member, submitted, workflowProject: p),
        member.active,
      );
    }
    store.setMeta('profile', 'gh-4');
    expect(store.canMove(submitted, 'done'), isTrue);
    store.setMeta('profile', reviewer.id);
    expect(store.canMove(submitted, 'done'), isTrue);
    expect(store.canEditContent(submitted), isTrue);
    final restrictedParts = const WorkflowAutomation(
      connections: [
        WorkflowConnection(
          'review',
          'todo',
          action: 'reject',
          actor: 'reviewer',
          actorParts: ['QA'],
        ),
      ],
    ).resolve(p.workflowStages);
    expect(isOpenWorkflowStage(submitted, restrictedParts), isFalse);
  });

  test('explicit legacy connections stay restricted; contradictory all-worker assignment is rejected', () {
    const link = WorkflowConnection(
      'review',
      'done',
      action: 'approve',
      actor: 'reviewer',
    );
    expect(WorkflowConnection.fromJson(link.json).allWorkers, isFalse);
    const open = WorkflowConnection(
      'review',
      'done',
      action: 'approve',
      actor: 'reviewer',
      allWorkers: true,
    );
    expect(WorkflowConnection.fromJson(open.json).allWorkers, isTrue);
    expect(
      () => WorkflowConnection.fromJson({...open.json, 'allWorkers': 'true'}),
      throwsStateError,
    );
    expect(
      () => WorkflowConnection.fromJson({...open.json, 'assignedOnly': true}),
      throwsStateError,
    );
    final redirected = const WorkflowAutomation(
      reviewEnabled: true,
      connections: [WorkflowConnection('doing', 'done', allWorkers: true)],
    ).resolve(defaultWorkflowStages).firstWhere((c) => c.from == 'doing');
    expect(redirected.to, 'review');
    expect(redirected.allWorkers, isTrue);
  });
}
