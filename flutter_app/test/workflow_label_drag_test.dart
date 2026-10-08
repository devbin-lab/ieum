import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';

import 'part_workflow_policy_test.dart'
    show configured, draft, planner, legacyReviewStages;

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

  test('moving only a label preserves prepared task handoff validity', () {
    final project = configured();
    final store = TaskStore(':memory:', project: project, identity: planner);
    addTearDown(store.dispose);
    var task = store.save(draft());
    store.transition(task.id, 'doing', expectedVersion: task.version);
    task = store.find(task.id);
    final plan = store.planHandoff(task, 'review', routeId: 'submit');
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
    expect(store.find(task.id).workflowTarget, 'part:role-pd');
  });

  Future<void> size(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final label = find.byKey(const Key('workflow-sheet-route-doing-review-0'));
  final other = find.byKey(const Key('workflow-sheet-route-doing-review-1'));
  final viewport = find.byKey(const Key('workflow-sheet-viewport'));
  final card = find.byKey(const Key('workflow-sheet-doing-card'));

  Future<void> wheel(WidgetTester tester, double delta) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getRect(viewport).center,
        scrollDelta: Offset(0, delta),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'label drag follows zoom, preserves other elements, persists and still opens editing',
    (tester) async {
      await size(tester);
      WorkflowSheet? saved;
      final project = configured();
      Widget panel(WorkflowSheet value, {String instance = 'canvas'}) =>
          MaterialApp(
            home: Scaffold(
              body: WorkflowSheetCanvas(
                stageCatalog: project.workflowStages,
                key: ValueKey(instance),
                value: value,
                roles: project.roles,
                people: project.people,
                parts: project.parts,
                onChanged: (s) => saved = s,
              ),
            ),
          );
      await tester.pumpWidget(panel(sheet));
      await tester.pumpAndSettle();
      final original = tester.getCenter(label);
      await wheel(tester, -120);
      final start = tester.getCenter(label);
      final cardStart = tester.getCenter(card),
          otherStart = tester.getCenter(other);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      const movement = Offset(120, 55);
      await gesture.moveBy(movement);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        (tester.getCenter(label) - start - movement).distance,
        lessThan(.01),
      );
      expect(tester.getCenter(card), cardStart);
      expect(tester.getCenter(other), otherStart);
      expect(find.byKey(const Key('workflow-route-save')), findsNothing);
      expect(saved!.policyJson, sheet.policyJson);
      expect(saved!.routes.first.id, 'broad');
      expect(saved!.routes.last.labelDx, 0);
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.byKey(const Key('workflow-sheet-link-doing-review')),
                  )
                  .painter
              as WorkflowSheetLinkPainter;
      expect(
        painter.labelCenter,
        tester.getCenter(label) - tester.getTopLeft(viewport),
      );
      await wheel(tester, 120);
      expect(
        (tester.getCenter(label) -
                original -
                Offset(
                  saved!.routes.first.labelDx,
                  saved!.routes.first.labelDy,
                ))
            .distance,
        lessThan(.01),
      );
      final moved = tester.getCenter(label);
      await tester.pumpWidget(
        panel(WorkflowSheet.fromJson(saved!.json), instance: 'reloaded'),
      );
      await tester.pumpAndSettle();
      expect(tester.getCenter(label), moved);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workflow-route-save')), findsOneWidget);
      final destination = find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.key.toString().contains('workflow-route-destination-'),
      );
      await tester.ensureVisible(destination);
      await tester.tap(destination);
      await tester.pumpAndSettle();
      await tester.tap(find.text('파트 · PD').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(tester.getCenter(label), moved);
      expect(saved!.routes.first.destination, 'part:role-pd');
      expect(saved!.routes.first.labelDx, isNonZero);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only label never edits or changes its offset', (
    tester,
  ) async {
    await size(tester);
    var changes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkflowSheetCanvas(
            stageCatalog: legacyReviewStages,
            value: sheet,
            readOnly: true,
            onChanged: (_) => changes++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final relative = tester.getCenter(label) - tester.getCenter(card);
    await tester.drag(label, const Offset(80, 50));
    await tester.pumpAndSettle();
    expect(tester.getCenter(label) - tester.getCenter(card), relative);
    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workflow-route-save')), findsNothing);
    expect(changes, 0);
  });
}
