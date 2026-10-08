import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:flutter/services.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';
import 'package:ieum_flutter/workflow_automation_tree.dart';

import 'v020_store_test.dart' show project;

void main() {
  testWidgets(
    'current canvas card and background right clicks open only one popup',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final observer = _PopupObserver();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [observer],
          home: const Scaffold(body: WorkflowSheetCanvas()),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> rightClick(Offset point) async {
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await mouse.down(point);
        await tester.pump(const Duration(milliseconds: 200));
        await mouse.up();
        await tester.pumpAndSettle();
      }

      await rightClick(
        tester.getCenter(find.byKey(const Key('workflow-sheet-doing-card'))),
      );
      expect(observer.opened, 1);
      expect(find.text('단계 불러오기', skipOffstage: false), findsNothing);
      expect(
        find.byKey(const Key('workflow-sheet-connect-menu')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workflow-sheet-delete-menu')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await rightClick(const Offset(80, 180));
      expect(observer.opened, 2);
      await tester.tap(find.byKey(const Key('workflow-sheet-import-todo')));
      await tester.pumpAndSettle();
      final imported = find.byKey(const Key('workflow-sheet-todo-copy-1-card'));
      expect(imported, findsOneWidget);
      await rightClick(tester.getCenter(imported));
      expect(observer.opened, 3);
      expect(find.text('단계 불러오기', skipOffstage: false), findsNothing);
      await tester.tap(find.byKey(const Key('workflow-sheet-delete-menu')));
      await tester.pumpAndSettle();
      expect(imported, findsNothing);
      await rightClick(const Offset(80, 180));
      expect(observer.opened, 4);
      await rightClick(tester.getCenter(find.text('단계 불러오기')));
      expect(observer.opened, 4);
      expect(find.text('단계 불러오기', skipOffstage: false), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('right click imports separate instances of connected stages', (
    tester,
  ) async {
    const stages = [
      WorkflowStage('todo', '확인'),
      WorkflowStage('doing', '진행'),
      WorkflowStage('done', '완료'),
    ];
    List<String> saved = [];
    Widget sheet({List<String> initial = const []}) => MaterialApp(
      home: Scaffold(
        body: WorkflowAutomationTree(
          stages: stages,
          connections: const WorkflowAutomation().resolve(stages),
          stageCatalog: stages,
          initialImportedStageIds: initial,
          onImportedStagesChanged: (ids) => saved = ids,
          roleName: (id) => id,
        ),
      ),
    );
    await tester.pumpWidget(sheet());
    await tester.pumpAndSettle();
    Future<void> importTodo() async {
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.down(const Offset(400, 180));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(find.text('단계 불러오기'), findsOneWidget);
      expect(find.byKey(const Key('automation-load-review')), findsNothing);
      expect(find.byKey(const Key('automation-load-rework')), findsNothing);
      await tester.tap(find.byKey(const Key('automation-load-todo')));
      await tester.pumpAndSettle();
    }

    await importTodo();
    expect(find.byKey(const Key('automation-node-todo')), findsOneWidget);
    expect(find.byKey(const Key('automation-loaded-0')), findsOneWidget);
    await importTodo();
    expect(find.byKey(const Key('automation-loaded-1')), findsOneWidget);
    expect(saved, ['todo', 'todo']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(sheet(initial: saved));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('automation-loaded-0')), findsOneWidget);
    expect(find.byKey(const Key('automation-loaded-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mouse drag follows pointer and springs home without editing conditions',
    (tester) async {
      const stages = [
        WorkflowStage('todo', '확인'),
        WorkflowStage('doing', '진행'),
        WorkflowStage('done', '완료'),
      ];
      var edits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowAutomationTree(
              stages: stages,
              connections: const WorkflowAutomation().resolve(stages),
              roleName: (id) => id,
              onEdit: (_) => edits++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('automation-node-doing'));
      final origin = tester.getCenter(card);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(origin);
      await mouse.moveBy(const Offset(25, 20));
      await tester.pump();
      await mouse.moveBy(const Offset(50, 65));
      await tester.pump();
      expect(tester.getCenter(card).dy, greaterThan(origin.dy + 40));
      expect(tester.getCenter(card).dx, greaterThan(origin.dx + 30));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 80));
      expect((tester.getCenter(card) - origin).distance, greaterThan(1));
      // Grabbing a returning card must resume at its current position.
      final returning = tester.getCenter(card);
      await mouse.down(returning);
      await mouse.moveBy(const Offset(20, 20));
      await tester.pump();
      await mouse.moveBy(const Offset(0, 25));
      await tester.pump();
      expect(tester.getCenter(card).dy, greaterThan(returning.dy));
      await mouse.up();
      await tester.pumpAndSettle();
      expect((tester.getCenter(card) - origin).distance, lessThan(0.5));
      expect(edits, 0);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(edits, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'horizontal tree branches to approval and rejection return without cycles',
    (tester) async {
      tester.view.physicalSize = const Size(600, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      WorkflowConnection? edited;
      Future<void> show(
        WorkflowAutomation automation, {
        bool withoutReview = false,
      }) async {
        final configured = ProjectManifest.fromJson({
          ...project.json,
          'workflowAutomation': automation.json,
          if (withoutReview)
            'workflowStages': defaultWorkflowStages
                .where((s) => s.id != 'review')
                .map((s) => s.json)
                .toList(),
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: WorkflowAutomationTree(
                  stages: configured.workflowStages,
                  connections: configured.workflowConnections,
                  roleName: (id) => id,
                  onEdit: (connection) => edited = connection,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Offset center(String id) =>
          tester.getCenter(find.byKey(Key('automation-node-$id')));
      await show(const WorkflowAutomation(), withoutReview: true);
      final todo = center('todo'),
          doing = center('doing'),
          done = center('done');
      expect(todo.dx, lessThan(doing.dx));
      expect(doing.dx, lessThan(done.dx));
      expect(todo.dy, doing.dy);
      expect(doing.dy, done.dy);
      await tester.tap(
        find.byKey(const Key('automation-connection-todo-advance')),
      );
      expect(edited?.to, 'doing');

      await show(const WorkflowAutomation(reviewEnabled: true));
      final review = center('review'), approved = center('done');
      expect(center('doing').dx, lessThan(review.dx));
      expect(review.dx, lessThan(approved.dx));
      expect(approved.dy, lessThan(review.dy));
      expect(find.byKey(const Key('automation-node-rework')), findsNothing);
      final reference = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
              'automation-reference-todo-',
            ),
      );
      expect(reference, findsOneWidget);
      expect(tester.getCenter(reference).dy, greaterThan(review.dy));
      await tester.ensureVisible(reference);
      await tester.pumpAndSettle();
      expect(tester.getRect(reference).right, lessThanOrEqualTo(584));
      expect(tester.takeException(), isNull);
    },
  );
}

class _PopupObserver extends NavigatorObserver {
  int opened = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) opened++;
    super.didPush(route, previousRoute);
  }
}
