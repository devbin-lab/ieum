import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'v020_store_test.dart' show project, owner, worker, reviewer, draft;

ProjectManifest reviewProject({
  String returnAssigneeId = 'gh-4',
  bool partWide = false,
}) => ProjectManifest.fromJson({
  ...project.json,
  'members': [
    {
      ...owner.json,
      'parts': ['기획', 'QA'],
    },
    {
      ...worker.json,
      'role': 'unassigned',
      'parts': ['기획'],
    },
    {
      ...reviewer.json,
      'role': 'unassigned',
      'parts': ['QA'],
    },
    const Person(
      'gh-4',
      '두 번째 기획자',
      '기',
      'unassigned',
      0,
      login: 'planner2',
      parts: ['기획'],
    ).json,
    const Person(
      'gh-5',
      '다른 검토자',
      '검',
      'unassigned',
      0,
      login: 'reviewer2',
      parts: ['QA'],
    ).json,
  ],
  'roles': [
    const ProjectRole('role-plan', '기획', {}).json,
    const ProjectRole('role-qa', 'QA', {}).json,
  ],
  'parts': ['기획', 'QA'],
  'partsUnified': true,
  'workflowStages': [
    ...defaultWorkflowStages.take(2).map((s) => s.json),
    const WorkflowStage('review', '검토').json,
    defaultWorkflowStages.last.json,
  ],
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
        source: 'part:role-plan',
        destination: 'part:role-plan',
        person: worker.id,
      ),
      WorkflowSheetRoute(
        id: 'submit',
        from: 'doing',
        to: 'review',
        source: 'part:role-plan',
        destination: 'part:role-qa',
        person: partWide ? '' : reviewer.id,
      ),
      const WorkflowSheetRoute(
        id: 'approve',
        from: 'review',
        to: 'done',
        source: 'part:role-qa',
        action: 'approve',
      ),
      WorkflowSheetRoute(
        id: 'reject',
        from: 'review',
        to: 'doing',
        source: 'part:role-qa',
        destination: 'part:role-plan',
        person: returnAssigneeId,
        action: 'reject',
      ),
    ],
  ).json,
});

WorkTask submittedTask(ProjectManifest p, String id) {
  final initial = WorkTask.fromJson({
    ...draft(),
    'id': id,
    'status': 'todo',
    'version': 1,
    'updatedAt': '2026-10-06T00:00:00Z',
    'completedDate': '',
    'reworkReason': '',
    'workflowTarget': '',
    'workflowPerson': worker.id,
    'workflowRoute': '',
  });
  final progressed = applyWorkflowRoute(
    initial,
    p.workflowSheet!.outgoing('todo').single,
    p,
  );
  return applyWorkflowRoute(
    progressed,
    p.workflowSheet!.outgoing('doing').single,
    p,
  ).copy({'version': 3});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('review moved to the first column does not become the initial task stage or restrict shared completion', () {
    final p = ProjectManifest.fromJson({
      ...project.json,
      'workflowStages': [
        const WorkflowStage('review', '검토').json,
        ...defaultWorkflowStages
            .where((s) => s.id != 'review')
            .map((s) => s.json),
      ],
    }).partWorkflowView;
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    expect(store.canCreate, isTrue);
    final created = store.save(draft());
    expect(created.status, 'todo');
    expect(store.workflowFlowLabel, '확인중 → 진행중 → 검토 → 완료');
    store.setMeta('profile', worker.id);
    store.transition(created.id, 'doing', expectedVersion: created.version);
    expect(store.canMove(store.find(created.id), 'done'), isTrue);
    store.transition(
      created.id,
      'review',
      expectedVersion: store.find(created.id).version,
    );
    expect(
      () => validateTaskMutation(
        actor: owner,
        next: created.copy({'status': 'review'}),
        customStages: p.workflowStages.map((s) => s.id).toList(),
        workflowConnections: p.workflowConnections,
        workflowProject: p,
      ),
      throwsStateError,
    );
  });

  test('review-only and done-only projects cannot create tasks; ordinary initial stages skip both specials', () {
    final p = ProjectManifest.fromJson({
      ...project.json,
      'workflowStages': [const WorkflowStage('review', '검토').json],
    }).partWorkflowView;
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    expect(store.canCreate, isFalse);
    expect(() => store.save(draft()), throwsStateError);
    final reviewing = WorkTask.fromJson({
      ...draft(),
      'id': 'TASK-only-review',
      'status': 'review',
      'version': 1,
      'updatedAt': '2026-10-06T00:00:00Z',
      'completedDate': '',
      'reworkReason': '',
    });
    expect(
      () => validateTaskMutation(
        actor: owner,
        next: reviewing,
        customStages: ['review'],
        workflowConnections: p.workflowConnections,
        workflowProject: p,
      ),
      throwsStateError,
    );
    store.updateProject(
      ProjectManifest.fromJson({
        ...project.json,
        'workflowStages': [const WorkflowStage('done', '완료').json],
      }).partWorkflowView,
    );
    expect(store.canCreate, isFalse);
    expect(() => store.save(draft()), throwsStateError);
    store.updateProject(
      ProjectManifest.fromJson({
        ...project.json,
        'workflowStages': [
          const WorkflowStage('review', '검토').json,
          defaultWorkflowStages.last.json,
          defaultWorkflowStages.first.json,
        ],
      }),
    );
    final created = store.save(draft());
    expect(created.status, 'todo');
    expect(created.completedDate, isEmpty);
  });

  test('legacy virtual review remains readable without turning a stage named review into the special review ID', () {
    final p = ProjectManifest.fromJson({
      ...project.json,
      'workflowStages': [
        ...defaultWorkflowStages.take(2).map((s) => s.json),
        const WorkflowStage('stage-existing-review', '검토').json,
        defaultWorkflowStages.last.json,
      ],
      'workflowAutomation': const WorkflowAutomation(
        reviewEnabled: true,
        reworkEnabled: true,
        connections: [
          WorkflowConnection(
            'review',
            'rework',
            action: 'reject',
            actor: 'reviewer',
            actorParts: ['QA'],
            assignedOnly: true,
          ),
        ],
      ).json,
    });
    expect(p.workflowStages.map((s) => s.id), [
      'todo',
      'doing',
      'stage-existing-review',
      'done',
    ]);
    expect(p.workflowStages.any((s) => s.id == 'review'), isFalse);
    expect(
      p.workflowStages.firstWhere((s) => s.id == 'stage-existing-review').name,
      '검토',
    );
    expect(p.workflowAutomation.reworkEnabled, isFalse);
    expect(
      p.workflowConnections.any((c) => c.from == 'rework' || c.to == 'rework'),
      isFalse,
    );
    final rejection = p.workflowConnections.firstWhere(
      (c) => c.action == 'reject',
    );
    expect(rejection.to, 'doing');
    expect(rejection.actorParts, ['QA']);
    expect(rejection.assignedOnly, isTrue);
    expect(ProjectManifest.fromJson(p.json).json, p.json);
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    var task = store.save(draft());
    store.transition(task.id, 'doing', expectedVersion: task.version);
    task = store.find(task.id);
    store.transition(
      task.id,
      'stage-existing-review',
      expectedVersion: task.version,
    );
    task = store.find(task.id);
    expect(store.canEditContent(task), isTrue);
    expect(store.canMove(task, 'done'), isTrue);
  });

  test('legacy rework tasks remain readable and recover into the configured normal workflow', () {
    final p = reviewProject();
    final store = TaskStore(':memory:', project: p, identity: p.people[1]);
    addTearDown(store.dispose);
    final legacy = WorkTask.fromJson({
      ...draft(),
      'id': 'TASK-legacy-return',
      'status': 'rework',
      'version': 3,
      'updatedAt': '2026-10-06T00:00:00Z',
      'completedDate': '',
      'reworkReason': '기존 보완 의견',
    });
    store.put(legacy);
    expect(store.workflowStatuses['rework'], '이전 반려 작업');
    expect(p.workflowStages.any((s) => s.id == 'rework'), isFalse);
    expect(store.canMove(legacy, 'todo'), isFalse);
    store.setMeta('profile', owner.id);
    store.recoverTask(
      legacy.id,
      stageId: 'todo',
      personId: worker.id,
      expectedVersion: legacy.version,
    );
    expect(store.find(legacy.id).reworkReason, '기존 보완 의견');
    expect(store.workflowStatuses.containsKey('rework'), isFalse);
  });

  test('broad administrator permissions do not subscribe unrelated personal work or review notifications', () {
    final p = reviewProject();
    final store = TaskStore(':memory:', project: p, identity: owner);
    addTearDown(store.dispose);
    final submitted = submittedTask(p, 'TASK-review-notification');
    expect(store.canMove(submitted, 'done'), isTrue);
    expect(store.canActOnTask(submitted), isTrue);
    expect(isWorkflowRecipient(store.actor, submitted, p), isFalse);
    store.importSnapshot({
      'schemaVersion': 1,
      'projectId': p.id,
      'revision': 'review-unrelated',
      'tasks': [submitted.data],
    });
    expect(store.notifications, isEmpty);
  });

  test('rejection requires comment and assigns the configured worker without restricting shared content edits', () {
    final p = reviewProject();
    final store = TaskStore(':memory:', project: p, identity: p.people.first);
    addTearDown(store.dispose);
    final task = store.save(draft());
    void move(String status, {String reason = '', String? routeId}) =>
        store.transition(
          task.id,
          status,
          reason: reason,
          routeId: routeId,
          expectedVersion: store.find(task.id).version,
        );
    store.setMeta('profile', worker.id);
    move('doing');
    move('review');
    final submitted = store.find(task.id);
    for (final person in p.people) {
      expect(canEditTask(person, submitted, workflowProject: p), isTrue);
      expect(canEditTaskContent(person, submitted, workflowProject: p), isTrue);
    }
    expect(store.canMove(submitted, 'doing'), isTrue);
    store.setMeta('profile', reviewer.id);
    expect(store.canMove(submitted, 'doing'), isTrue);
    expect(() => move('doing', routeId: 'reject'), throwsStateError);
    expect(
      () => move('doing', reason: '   ', routeId: 'reject'),
      throwsStateError,
    );
    expect(store.find(task.id).status, 'review');
    move('doing', reason: '  기획 근거를 보완하세요.  ', routeId: 'reject');
    final returned = store.find(task.id);
    expect(returned.status, 'doing');
    expect(returned.assigneeId, worker.id);
    expect(returned.workflowTarget, 'part:role-plan');
    expect(returned.workflowPerson, 'gh-4');
    expect(returned.workflowRoute, 'reject');
    expect(returned.reworkReason, '기획 근거를 보완하세요.');
    expect(store.canEditContent(returned), isTrue);
    store.setMeta('profile', worker.id);
    expect(store.canEditContent(returned), isTrue);
    expect(store.isAssignedToMe(returned), isFalse);
    store.setMeta('profile', 'gh-4');
    expect(store.canEditContent(returned), isTrue);
    expect(store.isAssignedToMe(returned), isTrue);
    store.save({
      ...returned.data,
      'description': '반려 사항 보완',
    }, expectedVersion: returned.version);
    move('review');
    store.setMeta('profile', reviewer.id);
    move('done');
    expect(store.find(task.id).completedDate, isNotEmpty);
  });

  test('empty return person opens the receiving part and unavailable personal recipients block only that handoff', () {
    final p = reviewProject(returnAssigneeId: '');
    final store = TaskStore(':memory:', project: p, identity: p.people[2]);
    addTearDown(store.dispose);
    final submitted = submittedTask(p, 'TASK-rejection');
    store.put(submitted);
    store.transition(submitted.id, 'doing', reason: '보완', expectedVersion: 3);
    final returned = store.find(submitted.id);
    expect(returned.assigneeId, worker.id);
    expect(returned.workflowTarget, 'part:role-plan');
    expect(returned.workflowPerson, isEmpty);
    expect(isWorkflowRecipient(p.people[1], returned, p), isTrue);
    expect(isWorkflowRecipient(p.people[3], returned, p), isTrue);
    expect(isWorkflowRecipient(p.people[4], returned, p), isFalse);
    final unavailable = ProjectManifest.fromJson({
      ...reviewProject().json,
      'members': [
        for (final person in reviewProject().people)
          person.id == 'gh-4'
              ? {...person.json, 'enabled': false}
              : person.json,
      ],
    });
    store.updateProject(unavailable);
    store.put(submitted);
    expect(store.project, isNotNull);
    expect(store.canMove(submitted, 'doing'), isTrue);
    expect(
      store
          .availableHandoffs(submitted)
          .any((plan) => plan.routeId == 'reject'),
      isFalse,
    );
    expect(store.canMove(submitted, 'done'), isTrue);
    expect(
      () => store.transition(
        submitted.id,
        'doing',
        reason: '보완',
        routeId: 'reject',
        expectedVersion: 3,
      ),
      throwsStateError,
    );
  });

  test('review mutation cannot forge recipient or comment and separates shared metadata editing from rejection', () {
    final p = reviewProject();
    final submitted = submittedTask(p, 'TASK-rejection');
    final returned = applyWorkflowRoute(
      submitted,
      p.workflowSheet!
          .outgoing('review')
          .firstWhere((r) => r.action == 'reject'),
      p,
      reason: '보완',
    ).copy({'version': 4});
    void validate(
      Person actor,
      Map<String, dynamic> change, {
      bool collapsed = false,
    }) => validateTaskMutation(
      actor: actor,
      current: submitted,
      next: submitted.copy({'version': 4, ...change}),
      allowCollapsedTransitions: collapsed,
      customStages: p.workflowStages.map((s) => s.id).toList(),
      workflowConnections: p.workflowConnections,
      workflowProject: p,
    );
    expect(() => validate(p.people[2], returned.data), returnsNormally);
    for (final change in <Map<String, dynamic>>[
      {...returned.data, 'workflowPerson': 'gh-5'},
      {...returned.data, 'reworkReason': ''},
      {...returned.data, 'title': '검토자 본문 수정'},
      {'workflowPerson': 'gh-4'},
    ]) {
      expect(() => validate(p.people[2], change), throwsStateError);
      expect(() => validate(p.people.first, change), throwsStateError);
    }
    for (final change in <Map<String, dynamic>>[
      {'assigneeId': 'gh-4'},
      {'reviewerId': 'gh-5'},
      {'title': '공유 검토 내용 수정'},
    ]) {
      expect(() => validate(p.people[2], change), returnsNormally);
      expect(() => validate(p.people.first, change), returnsNormally);
    }
    expect(
      () => validate(p.people[2], {
        ...returned.data,
        'title': '검토자 본문 수정',
      }, collapsed: true),
      throwsStateError,
    );
  });

  test('part-wide reviewers receive incoming review notifications and share content editing and rejection', () {
    final p = reviewProject(partWide: true);
    final store = TaskStore(':memory:', project: p, identity: p.people.last);
    addTearDown(store.dispose);
    final submitted = submittedTask(p, 'TASK-rejection');
    expect(store.canActOnTask(submitted), isTrue);
    expect(store.canEditContent(submitted), isTrue);
    store.importSnapshot({
      'schemaVersion': 1,
      'projectId': p.id,
      'revision': 'review-1',
      'tasks': [submitted.data],
    });
    expect(store.notifications, hasLength(1));
    expect(store.notifications.single['eventType'], 'task.review');
    expect(store.notifications.single['recipientId'], 'gh-5');
    store.transition(
      submitted.id,
      'doing',
      reason: '파트 검토 반려',
      expectedVersion: 3,
    );
    expect(store.find(submitted.id).assigneeId, worker.id);
    expect(store.find(submitted.id).workflowPerson, 'gh-4');
  });

  test('repository publication permits configured rejection and rejects forged recipients or missing comments', () async {
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    final api = FakeGitHubApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
    addTearDown(session.signOut);
    final p = reviewProject();
    await session.writeJson(
      config,
      '.ieum/project.json',
      p.json,
      message: 'Test review return handoff',
    );
    final submitted = submittedTask(p, 'TASK-rejection');
    final returned = applyWorkflowRoute(
      submitted,
      p.workflowSheet!
          .outgoing('review')
          .firstWhere((r) => r.action == 'reject'),
      p,
      reason: '보완',
    ).copy({'version': 4});
    api.identityId = 3;
    api.identityLogin = 'reviewer';
    Future<SyncReceipt> publish(Map<String, dynamic> change) =>
        GitHubPublisher(api).publish(config, {
          'taskId': submitted.id,
          'proposal': {
            'schemaVersion': 1,
            'projectId': p.id,
            'authorId': reviewer.id,
            'changes': [
              {
                'base': submitted.data,
                'task': submitted.copy({'version': 4, ...change}).data,
              },
            ],
          },
        });
    await expectLater(
      publish({...returned.data, 'workflowPerson': 'gh-5'}),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      publish({...returned.data, 'reworkReason': ''}),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.prs, isEmpty);
    final receipt = await publish(returned.data);
    expect(receipt.prUrl, isNotEmpty);
    expect(api.prs, hasLength(1));
  });
}
