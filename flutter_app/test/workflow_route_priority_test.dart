import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_policy_test.dart'
    show admin, artist, configured, director, draft, planner;

const fallback = WorkflowSheetRoute(id: 'all', from: 'doing', to: 'review');
const planning = WorkflowSheetRoute(
  id: 'planning-pd',
  from: 'doing',
  to: 'review',
  source: 'part:role-plan',
  destination: 'part:role-pd',
);
const art = WorkflowSheetRoute(
  id: 'art-pd',
  from: 'doing',
  to: 'review',
  source: 'part:role-art',
  destination: 'part:role-pd',
  person: 'gh-3',
);

WorkTask openTask(String stage) => WorkTask.fromJson({
  ...draft(),
  'id': 'IE-PRIORITY',
  'version': 1,
  'status': stage,
  'workflowTarget': '',
  'workflowPerson': '',
  'workflowRoute': '',
  'completedDate': '',
  'reworkReason': '',
  'updatedAt': '2026-10-07T00:00:00Z',
});

void main() {
  test(
    'specific sender routes also suppress broad routes to another stage',
    () {
      final project = configured(
        links: const [
          WorkflowSheetRoute(id: 'broad-return', from: 'doing', to: 'todo'),
          fallback,
          planning,
        ],
      );
      expect(
        availableWorkflowRoutes(
          planner,
          openTask('doing'),
          project,
        ).map((r) => r.id),
        ['planning-pd'],
      );
      expect(
        availableWorkflowRoutes(
          artist,
          openTask('doing'),
          project,
        ).map((r) => r.id),
        ['broad-return', 'all'],
      );
    },
  );

  test(
    'owner with a matching part follows its specific routes during handoff',
    () {
      final owner = Person.fromJson({
        ...admin.json,
        'parts': ['기획'],
      });
      final project = configured(
        links: [fallback, planning, art],
        people: [owner, planner, director, artist],
      );
      expect(
        availableWorkflowRoutes(
          owner,
          openTask('doing'),
          project,
        ).map((r) => r.id),
        ['planning-pd'],
      );
    },
  );
  test(
    'matching part overrides all-worker routes; others keep the fallback',
    () {
      final project = configured(links: [fallback, planning]);
      final task = openTask('doing');
      expect(availableWorkflowRoutes(planner, task, project).map((r) => r.id), [
        'planning-pd',
      ]);
      expect(availableWorkflowRoutes(artist, task, project).map((r) => r.id), [
        'all',
      ]);
      expect(
        availableWorkflowRoutes(director, task, project).map((r) => r.id),
        ['all'],
      );
      final restored = ProjectManifest.fromJson(project.json);
      expect(restored.workflowSheet!.outgoing('doing').length, 2);
      expect(
        availableWorkflowRoutes(planner, task, restored).map((r) => r.id),
        ['planning-pd'],
      );
    },
  );

  test('multiple sender parts retain all matching specific routes without fallback', () {
    final both = Person.fromJson({
      ...planner.json,
      'parts': ['기획', '아트'],
    });
    final project = configured(
      links: [fallback, planning, art],
      people: [admin, both, director, artist],
    );
    final task = openTask('doing');
    expect(availableWorkflowRoutes(both, task, project).map((r) => r.id), [
      'planning-pd',
      'art-pd',
    ]);
    expect(availableWorkflowRoutes(artist, task, project).map((r) => r.id), [
      'art-pd',
    ]);
    expect(availableWorkflowRoutes(director, task, project).map((r) => r.id), [
      'all',
    ]);
  });

  test(
    'missing specific recipient never falls back to unrestricted delivery',
    () {
      final project = configured(
        links: [fallback, planning],
        people: [admin, planner, artist],
      );
      expect(
        availableWorkflowRoutes(planner, openTask('doing'), project),
        isEmpty,
      );
      expect(
        availableWorkflowRoutes(
          artist,
          openTask('doing'),
          project,
        ).map((r) => r.id),
        ['all'],
      );
    },
  );

  test('review approve and reject resolve fallback independently', () {
    final project = configured(
      links: const [
        WorkflowSheetRoute(
          id: 'approve-all',
          from: 'review',
          to: 'done',
          action: 'approve',
        ),
        WorkflowSheetRoute(
          id: 'reject-all',
          from: 'review',
          to: 'todo',
          action: 'reject',
        ),
        WorkflowSheetRoute(
          id: 'reject-pd',
          from: 'review',
          to: 'doing',
          source: 'part:role-pd',
          action: 'reject',
        ),
      ],
    );
    expect(
      availableWorkflowRoutes(
        director,
        openTask('review'),
        project,
      ).map((r) => r.id),
      ['approve-all', 'reject-pd'],
    );
  });

  test('manual status changes ignore archived routes while legacy validation rejects a shadowed fallback', () {
    final project = configured(
      links: const [
        WorkflowSheetRoute(id: 'start', from: 'todo', to: 'doing'),
        fallback,
        planning,
      ],
    );
    final store = TaskStore(':memory:', project: project, identity: planner);
    addTearDown(store.dispose);
    var task = store.save(draft());
    store.transition(task.id, 'doing', expectedVersion: task.version);
    task = store.find(task.id);
    expect(store.availableHandoffs(task).map((p) => p.routeId), [
      'manual-review',
      'manual-finish',
      'manual-hold',
      'manual-drop',
    ]);
    expect(
      () => store.planHandoff(task, 'review', routeId: 'all'),
      throwsStateError,
    );
    final forged = applyWorkflowRoute(
      task,
      fallback,
      project,
    ).copy({'version': task.version + 1});
    for (final collapsed in [false, true]) {
      expect(
        () => validatePartWorkflowMutation(
          actor: planner,
          current: task,
          next: forged,
          project: project,
          allowCollapsedTransitions: collapsed,
        ),
        throwsStateError,
      );
    }
    expect(
      () => store.planHandoff(task, 'review', routeId: 'planning-pd'),
      throwsStateError,
    );
    final plan = store.planHandoff(task, 'review', routeId: 'manual-review');
    store.confirmHandoff(plan);
    expect(store.find(task.id).status, 'review');
    expect(store.find(task.id).workflowTarget, isEmpty);
  });
}
