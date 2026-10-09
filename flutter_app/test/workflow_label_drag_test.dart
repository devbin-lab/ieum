import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_policy_test.dart' show configured, draft, planner;

const sheet = WorkflowSheet(
  nodes: [
    WorkflowSheetNode('doing', 'doing', x: -160),
    WorkflowSheetNode('review', 'review', x: 160),
  ],
  routes: [
    WorkflowSheetRoute(id: 'broad', from: 'doing', to: 'review'),
    WorkflowSheetRoute(
      id: 'planning',
      from: 'doing',
      to: 'review',
      source: 'part:role-plan',
      destination: 'part:role-pd',
    ),
  ],
);

void main() {
  test('label offsets roundtrip, default legacy offsets and reject malformed coordinates', () {
    final moved = WorkflowSheet.fromJson({
      ...sheet.json,
      'routes': [
        {...sheet.routes.first.json, 'labelDx': 73.5, 'labelDy': -18},
        sheet.routes.last.json,
      ],
    });
    expect(moved.routes.first.labelDx, 73.5);
    expect(moved.routes.first.labelDy, -18);
    expect(moved.routes.last.labelDx, 0);
    expect(WorkflowSheet.fromJson(moved.json).json, moved.json);
    expect(moved.policyJson, sheet.policyJson);
    for (final field in ['labelDx', 'labelDy']) {
      for (final invalid in [double.nan, double.infinity, '1', 100001]) {
        expect(
          () => WorkflowSheetRoute.fromJson({
            ...sheet.routes.first.json,
            field: invalid,
          }),
          throwsStateError,
        );
      }
    }
  });

  test(
    'archived label positions do not alter a prepared manual status change',
    () {
      final project = configured();
      final store = TaskStore(':memory:', project: project, identity: planner);
      addTearDown(store.dispose);
      var task = store.save(draft());
      store.transition(task.id, 'doing', expectedVersion: task.version);
      task = store.find(task.id);
      final plan = store.planHandoff(task, 'review', routeId: 'manual-review');
      store.updateProject(
        ProjectManifest.fromJson({
          ...project.json,
          'workflowSheet': {
            ...project.workflowSheet!.json,
            'routes': [
              for (final r in project.workflowSheet!.routes)
                {...r.json, 'labelDx': 120, 'labelDy': -60},
            ],
          },
        }),
      );
      expect(store.isHandoffCurrent(plan), isTrue);
      store.confirmHandoff(plan);
      expect(store.find(task.id).status, 'review');
      expect(store.find(task.id).workflowTarget, isEmpty);
      expect(store.find(task.id).assigneeId, task.assigneeId);
    },
  );
}
