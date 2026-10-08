import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';
import 'package:ieum_flutter/workflow_sheet_handoff.dart';

import 'part_workflow_policy_test.dart'
    show admin, artist, configured, director, draft, nodes, planner;

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

  test(
    'local confirmation and collapsed mutation reject a shadowed fallback',
    () {
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
        'manual-finish',
        'planning-pd',
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
      final plan = store.planHandoff(task, 'review', routeId: 'planning-pd');
      store.confirmHandoff(plan);
      expect(store.find(task.id).workflowTarget, 'part:role-pd');
    },
  );

  Future<void> choose(WidgetTester tester, int field, String label) async {
    final prefix = [
      'workflow-route-source-',
      'workflow-route-destination-',
    ][field];
    final dropdown = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.key.toString().contains(prefix),
    );
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'batch route editor retains edits across add and selection, and cancellation is isolated',
    (tester) async {
      List<SheetHandoffRule>? saved;
      final source = [const SheetHandoffRule(id: 'all')];
      final project = configured();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => saved = await editSheetHandoff(
                  context,
                  from: '진행중',
                  to: '검토',
                  fromStage: 'doing',
                  toStage: 'review',
                  routes: source,
                  roles: project.roles,
                  parts: project.parts,
                  people: project.people,
                ),
                child: const Text('편집'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('편집'));
      await tester.pumpAndSettle();
      await choose(tester, 0, '파트 · 기획');
      await choose(tester, 1, '파트 · PD');
      await tester.ensureVisible(find.byKey(const Key('workflow-route-add')));
      await tester.tap(find.byKey(const Key('workflow-route-add')));
      await tester.pumpAndSettle();
      await choose(tester, 0, '파트 · 아트');
      await choose(tester, 1, '파트 · PD');
      await tester.ensureVisible(
        find.byKey(const Key('workflow-route-option-0')),
      );
      await tester.tap(find.byKey(const Key('workflow-route-option-0')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is DropdownButtonFormField<String> &&
                    widget.key.toString().contains('workflow-route-source-'),
              ),
            )
            .initialValue,
        'part:role-plan',
      );
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(saved!.map((r) => r.source), ['part:role-plan', 'part:role-art']);
      expect(saved!.map((r) => r.destination), [
        'part:role-pd',
        'part:role-pd',
      ]);
      expect(saved!.first.id, 'all');
      expect(source.single.source, isEmpty);
      await tester.tap(find.text('편집'));
      await tester.pumpAndSettle();
      await choose(tester, 0, '파트 · 기획');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(source.single.source, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reconnecting existing cards creates an additional route with distinct persisted IDs',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final project = configured();
      WorkflowSheet? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowSheetCanvas(
              stageCatalog: project.workflowStages,
              value: const WorkflowSheet(nodes: nodes, routes: [planning]),
              roles: project.roles,
              parts: project.parts,
              people: project.people,
              onChanged: (s) => saved = s,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Separate overlapping fixture positions through actual dragging.
      final doing = find.byKey(const Key('workflow-sheet-doing-card'));
      final review = find.byKey(const Key('workflow-sheet-review-card'));
      // Reload with positioned cards so hit targets remain unambiguous.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowSheetCanvas(
              stageCatalog: project.workflowStages,
              value: const WorkflowSheet(
                nodes: [
                  WorkflowSheetNode('doing', 'doing', x: -150),
                  WorkflowSheetNode('review', 'review', x: 150),
                ],
                routes: [planning],
              ),
              roles: project.roles,
              parts: project.parts,
              people: project.people,
              onChanged: (s) => saved = s,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(doing, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-sheet-connect-menu')));
      await tester.pumpAndSettle();
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workflow-route-option-1')), findsOneWidget);
      await choose(tester, 0, '파트 · 아트');
      await choose(tester, 1, '파트 · PD');
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(saved!.routes.map((r) => r.source), [
        'part:role-plan',
        'part:role-art',
      ]);
      expect(saved!.routes.map((r) => r.id).toSet().length, 2);
      expect(saved!.routes.first.id, 'planning-pd');
      expect(WorkflowSheet.fromJson(saved!.json).routes.length, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
