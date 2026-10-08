import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

const planner = Person(
  'gh-2',
  '기획자',
  '기',
  'unassigned',
  0,
  parts: ['기획'],
  login: 'planner',
);
const director = Person(
  'gh-3',
  'PD',
  'P',
  'unassigned',
  0,
  parts: ['PD'],
  login: 'director',
);
const otherDirector = Person(
  'gh-4',
  '다른 PD',
  'P',
  'unassigned',
  0,
  parts: ['PD'],
  login: 'other-director',
);
const artist = Person(
  'gh-5',
  '아트',
  '아',
  'unassigned',
  0,
  parts: ['아트'],
  login: 'artist',
);
const admin = Person('gh-1', '관리자', '관', 'owner', 0, login: 'admin');
const legacyReviewStages = [
  WorkflowStage('todo', '확인중'),
  WorkflowStage('doing', '진행중'),
  WorkflowStage('review', '검토'),
  WorkflowStage('done', '완료'),
];
const nodes = [
  WorkflowSheetNode('todo', 'todo'),
  WorkflowSheetNode('doing', 'doing'),
  WorkflowSheetNode('review', 'review'),
  WorkflowSheetNode('done', 'done'),
];
const routes = [
  WorkflowSheetRoute(
    id: 'start',
    from: 'todo',
    to: 'doing',
    source: 'part:role-plan',
    destination: 'part:role-plan',
    person: 'gh-2',
  ),
  WorkflowSheetRoute(
    id: 'submit',
    from: 'doing',
    to: 'review',
    source: 'part:role-plan',
    destination: 'part:role-pd',
  ),
  WorkflowSheetRoute(
    id: 'approve',
    from: 'review',
    to: 'done',
    source: 'part:role-pd',
    action: 'approve',
  ),
  WorkflowSheetRoute(
    id: 'reject',
    from: 'review',
    to: 'todo',
    source: 'part:role-pd',
    destination: 'part:role-plan',
    person: 'gh-2',
    action: 'reject',
  ),
];

ProjectManifest configured({
  List<WorkflowSheetRoute> links = routes,
  List<Person> people = const [admin, planner, director, otherDirector, artist],
}) => ProjectManifest(
  'part-project',
  '프로젝트',
  admin.id,
  people,
  unifiedParts: true,
  roles: const [
    ProjectRole('role-plan', '기획', {}),
    ProjectRole('role-pd', 'PD', {}),
    ProjectRole('role-art', '아트', {}),
  ],
  parts: const ['기획', 'PD', '아트'],
  workflowStages: legacyReviewStages,
  workflowSheet: WorkflowSheet(nodes: nodes, routes: links),
);

Map<String, dynamic> draft() => {
  'title': '기획 작업',
  'part': '기획',
  'assigneeId': planner.id,
  'reviewerId': director.id,
  'assignedDate': '2026-10-07',
  'dueDate': '',
  'priority': 'normal',
  'description': '기획 내용',
};

void main() {
  late TaskStore store;
  setUp(
    () =>
        store = TaskStore(':memory:', project: configured(), identity: planner),
  );
  tearDown(() => store.dispose());
  WorkTask move(
    WorkTask task,
    String stage, {
    String reason = '',
    String? routeId,
  }) {
    final plan = store.planHandoff(task, stage, routeId: routeId);
    store.confirmHandoff(plan, reason: reason);
    return store.find(task.id);
  }

  WorkTask submitted() => move(move(store.save(draft()), 'doing'), 'review');

  test('approved participants have work abilities while only administrator can manage', () {
    final worker = store.actor;
    expect(worker.canWork, isTrue);
    expect(worker.canReview, isTrue);
    expect(worker.has('role.manage'), isFalse);
    expect(worker.has('member.manage'), isFalse);
    expect(store.member(admin.id).has('role.manage'), isTrue);
  });

  test(
    'part-wide handoff changes assignment and preserves collaborative editing',
    () {
      var task = submitted();
      expect(task.workflowTarget, 'part:role-pd');
      expect(task.workflowPerson, isEmpty);
      expect(store.currentActorLabel(task), 'PD 전체');
      expect(store.canEdit(task), isTrue);
      expect(store.availableHandoffs(task), isNotEmpty);
      for (final person in [director, otherDirector]) {
        store.setMeta('profile', person.id);
        expect(
          store
              .availableHandoffs(task)
              .where((p) => !directWorkflowRouteIds.contains(p.routeId))
              .map((p) => p.action),
          ['approve', 'reject'],
        );
        expect(store.canEditContent(task), isTrue);
        task = store.save({
          ...task.data,
          'description': '검토자 수정',
        }, expectedVersion: task.version);
      }
      store.setMeta('profile', artist.id);
      expect(store.availableHandoffs(task), isNotEmpty);
    },
  );

  test('review rejection needs comment and records exact return recipient', () {
    var task = submitted();
    store.setMeta('profile', director.id);
    final plan = store.planHandoff(task, 'todo');
    expect(() => store.confirmHandoff(plan), throwsStateError);
    task = move(task, 'todo', reason: '기획 보완 필요');
    expect(task.reworkReason, '기획 보완 필요');
    expect(task.workflowPerson, planner.id);
    expect(store.canEdit(task), isTrue);
    store.setMeta('profile', planner.id);
    expect(store.canEdit(task), isTrue);
    store.save({
      ...task.data,
      'description': '보완 완료',
    }, expectedVersion: task.version);
  });

  test('administrator can recover completed work and recovered task remains editable', () {
    var task = submitted();
    store.setMeta('profile', director.id);
    task = move(task, 'done');
    expect(store.canEdit(task), isFalse);
    expect(
      () => store.recoverTask(
        task.id,
        stageId: 'doing',
        personId: planner.id,
        expectedVersion: task.version,
      ),
      throwsStateError,
    );
    store.setMeta('profile', admin.id);
    store.recoverTask(
      task.id,
      stageId: 'doing',
      personId: planner.id,
      expectedVersion: task.version,
    );
    task = store.find(task.id);
    expect(task.completedDate, isEmpty);
    expect(task.workflowRoute, 'admin-recovery');
    store.save({
      ...task.data,
      'title': '회수 후 수정',
    }, expectedVersion: task.version);
    store.setMeta('profile', planner.id);
    expect(store.canEdit(store.find(task.id)), isTrue);
  });

  test('same-stage target forgery and skipping recipient-controlled review are rejected', () {
    final task = move(store.save(draft()), 'doing');
    final forged = task.copy({
      'workflowTarget': '',
      'workflowPerson': '',
      'version': task.version + 1,
    });
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: task,
        next: forged,
        workflowProject: store.project,
      ),
      throwsStateError,
    );
    final done = task.copy({
      'status': 'done',
      'workflowRoute': 'approve',
      'workflowTarget': '',
      'workflowPerson': '',
      'completedDate': localDate(),
      'version': task.version + 2,
    });
    expect(
      () => validateTaskMutation(
        actor: store.actor,
        current: task,
        next: done,
        workflowProject: store.project,
        allowCollapsedTransitions: true,
      ),
      throwsStateError,
    );
  });

  test(
    'different recipients on same destination require an exact route selection',
    () {
      store.updateProject(
        configured(
          links: [
            ...routes,
            const WorkflowSheetRoute(
              id: 'private-submit',
              from: 'doing',
              to: 'review',
              source: 'part:role-plan',
              destination: 'part:role-pd',
              person: 'gh-3',
            ),
          ],
        ),
      );
      var task = move(store.save(draft()), 'doing');
      final plans = store
          .availableHandoffs(task)
          .where((p) => p.destinationId == 'review');
      expect(plans.map((p) => p.routeId), ['submit', 'private-submit']);
      expect(() => store.planHandoff(task, 'review'), throwsStateError);
      task = move(task, 'review', routeId: 'private-submit');
      expect(task.workflowPerson, director.id);
      store.setMeta('profile', otherDirector.id);
      expect(store.availableHandoffs(task), isNotEmpty);
      expect(store.isAssignedToMe(task), isFalse);
    },
  );

  test(
    'policy changes invalidate confirmation but layout-only moves do not',
    () {
      final task = move(store.save(draft()), 'doing');
      final plan = store.planHandoff(task, 'review');
      final layout = {
        ...store.project!.json,
        'workflowSheet': WorkflowSheet(
          nodes: [
            for (final node in nodes)
              WorkflowSheetNode(node.id, node.stageId, x: 123),
          ],
          routes: routes,
        ).json,
      };
      store.updateProject(ProjectManifest.fromJson(layout));
      expect(store.isHandoffCurrent(plan), isTrue);
      store.updateProject(
        configured(
          links: [
            for (final r in routes)
              if (r.id == 'submit')
                WorkflowSheetRoute(
                  id: r.id,
                  from: r.from,
                  to: r.to,
                  source: r.source,
                  destination: r.destination,
                  person: director.id,
                )
              else
                r,
          ],
        ),
      );
      expect(store.isHandoffCurrent(plan), isFalse);
      expect(() => store.confirmHandoff(plan), throwsStateError);
    },
  );

  test(
    'historical inactive assignee does not block active current recipient',
    () {
      final task = submitted();
      store.updateProject(
        configured(
          people: [
            admin,
            Person(
              planner.id,
              planner.name,
              planner.initials,
              'unassigned',
              0,
              parts: planner.parts,
              login: planner.login,
              enabled: false,
            ),
            director,
            otherDirector,
            artist,
          ],
        ),
      );
      store.setMeta('profile', director.id);
      final completed = move(task, 'done');
      expect(completed.status, 'done');
    },
  );

  test('legacy work keeps its personal recipient and JSON round trip preserves routing', () {
    final task = store.save(draft());
    final legacy = Map<String, dynamic>.from(task.data)
      ..remove('workflowTarget')
      ..remove('workflowPerson')
      ..remove('workflowRoute');
    final parsed = WorkTask.fromJson(legacy);
    expect(parsed.workflowTarget, 'legacy');
    expect(
      isWorkflowRecipient(store.member(planner.id), parsed, store.project!),
      isTrue,
    );
    expect(
      isWorkflowRecipient(store.member(artist.id), parsed, store.project!),
      isFalse,
    );
    final loaded = ProjectManifest.fromJson(
      jsonDecode(jsonEncode(store.project!.json)),
    );
    expect(loaded.workflowSheet!.json, store.project!.workflowSheet!.json);
  });
}
