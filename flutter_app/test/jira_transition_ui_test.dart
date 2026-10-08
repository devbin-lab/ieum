import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_handoff_dialog.dart';
import 'package:ieum_flutter/task_editor.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';
import 'package:ieum_flutter/workflow_sheet_style.dart';

import 'v020_store_test.dart' as fixtures;

const stages = [
  WorkflowStage('todo', '접수', initial: true),
  WorkflowStage('stage-qa', 'QA 검토', editPolicy: 'locked'),
  WorkflowStage('stage-pd', 'PD 승인', editPolicy: 'locked'),
  WorkflowStage('stage-finished', '처리 종료', category: 'done'),
];
const sheet = WorkflowSheet(
  nodes: [
    WorkflowSheetNode('todo', 'todo', x: -300),
    WorkflowSheetNode('qa', 'stage-qa', x: -100),
    WorkflowSheetNode('pd', 'stage-pd', x: 100),
    WorkflowSheetNode('finished', 'stage-finished', x: 300),
  ],
  routes: [
    WorkflowSheetRoute(id: 'submit', from: 'todo', to: 'qa'),
    WorkflowSheetRoute(
      id: 'qa-approve',
      from: 'qa',
      to: 'pd',
      action: 'approve',
      name: 'PD 승인 요청',
      operation: 'submit-pd',
      assignment: 'keep',
      commentRequired: true,
      requiredFields: ['description'],
      labelDx: 12,
      labelDy: -15,
    ),
    WorkflowSheetRoute(
      id: 'finish',
      from: 'pd',
      to: 'finished',
      action: 'approve',
    ),
  ],
);

void main() {
  Future<void> openCanvas(
    WidgetTester tester,
    ValueChanged<WorkflowSheet> onChanged,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkflowSheetCanvas(
            stageCatalog: stages,
            value: sheet,
            onChanged: onChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> connect(
    WidgetTester tester,
    String source,
    String target,
  ) async {
    await tester.tap(
      find.byKey(Key('workflow-sheet-$source-card')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workflow-sheet-connect-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('workflow-sheet-$target-card')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'completed nodes support explicit self-transitions and reopen connections',
    (tester) async {
      WorkflowSheet? saved;
      await openCanvas(tester, (value) => saved = value);
      await connect(tester, 'finished', 'finished');
      expect(
        find.byKey(const Key('workflow-sheet-link-finished-finished')),
        findsOneWidget,
      );
      expect(saved!.routes.last.from, 'finished');
      expect(saved!.routes.last.to, 'finished');
      // A destination in the completed category defaults to approval.
      expect(saved!.routes.last.action, 'approve');
      expect(WorkflowSheet.fromJson(saved!.json).routes.last.to, 'finished');
      await connect(tester, 'finished', 'qa');
      expect(
        find.byKey(const Key('workflow-sheet-link-finished-qa')),
        findsOneWidget,
      );
      expect(saved!.routes.last.to, 'qa');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'named QA approval to PD keeps its semantics and validation during label dragging',
    (tester) async {
      WorkflowSheet? saved;
      await openCanvas(tester, (value) => saved = value);
      final label = find.byKey(const Key('workflow-sheet-route-qa-pd-0'));
      expect(find.textContaining('PD 승인 요청'), findsOneWidget);
      await tester.drag(label, const Offset(70, 60));
      await tester.pumpAndSettle();
      final moved = saved!.routes.firstWhere(
        (route) => route.id == 'qa-approve',
      );
      expect(moved.name, 'PD 승인 요청');
      expect(moved.action, 'approve');
      expect(moved.operation, 'submit-pd');
      expect(moved.assignment, 'keep');
      expect(moved.commentRequired, isTrue);
      expect(moved.requiredFields, ['description']);
      expect(moved.labelDx, closeTo(82, .01));
      expect(moved.labelDy, closeTo(45, .01));
      final pd = find.byKey(const Key('workflow-sheet-pd-card'));
      await tester.drag(pd, const Offset(25, 10));
      await tester.pumpAndSettle();
      expect(
        saved!.routes.firstWhere((route) => route.id == 'qa-approve').json,
        moved.json,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'status properties control review and completion card visuals for custom IDs',
    (tester) async {
      await openCanvas(tester, (_) {});
      final qa = tester.widget<WorkflowSheetCardFace>(
        find.byWidgetPredicate(
          (widget) => widget is WorkflowSheetCardFace && widget.id == 'qa',
        ),
      );
      final finished = tester.widget<WorkflowSheetCardFace>(
        find.byWidgetPredicate(
          (widget) =>
              widget is WorkflowSheetCardFace && widget.id == 'finished',
        ),
      );
      expect(qa.category, 'inProgress');
      expect(qa.locksContent, isTrue);
      expect(finished.category, 'done');
      expect(
        find.descendant(
          of: find.byKey(const Key('workflow-sheet-finished-card')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('workflow-sheet-qa-card')),
          matching: find.byIcon(Icons.fact_check_outlined),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'named non-rejection transition requires a comment and confirms the exact input',
    (tester) async {
      final project = ProjectManifest.fromJson({
        ...fixtures.project.json,
        'workflowStages': stages.map((stage) => stage.json).toList(),
        'workflowSheet': sheet.json,
      });
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: fixtures.owner,
      );
      addTearDown(store.dispose);
      var task = store.save({...fixtures.draft(), 'description': '테스트 사양'});
      store.transition(
        task.id,
        'stage-qa',
        expectedVersion: task.version,
        routeId: 'submit',
      );
      task = store.find(task.id);
      final plan = store.planHandoff(task, 'stage-pd', routeId: 'qa-approve');
      expect(plan.buttonLabel, 'PD 승인 요청');
      expect(plan.needsComment, isTrue);
      expect(plan.isRejection, isFalse);
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showDialog<String>(
                  context: context,
                  builder: (_) => TaskHandoffDialog(plan: plan, store: store),
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
      expect(find.text('PD 승인 요청 확인'), findsOneWidget);
      final confirm = find.byKey(const Key('task-handoff-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('rework-reason')),
        '  QA 확인 완료  ',
      );
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(result, 'QA 확인 완료');
      expect(store.find(task.id).status, 'stage-qa');
      store.confirmHandoff(plan, reason: result!);
      expect(store.find(task.id).status, 'stage-pd');
      expect(store.find(task.id).reworkReason, result);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom review remains collaborative and refreshes when its category completes',
    (tester) async {
      final project = ProjectManifest.fromJson({
        ...fixtures.project.json,
        'workflowStages': stages.map((stage) => stage.json).toList(),
        'workflowSheet': sheet.json,
      });
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: fixtures.owner,
      );
      addTearDown(store.dispose);
      var task = store.save({...fixtures.draft(), 'description': '테스트 사양'});
      store.transition(
        task.id,
        'stage-qa',
        expectedVersion: task.version,
        routeId: 'submit',
      );
      task = store.find(task.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskEditor(store: store, task: task),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final description = find.byKey(const Key('task-description'));
      final field = find.descendant(
        of: description,
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(field).readOnly, isFalse);
      expect(find.textContaining('QA 검토 상태에서는'), findsNothing);
      store.updateProject(
        ProjectManifest.fromJson({
          ...project.json,
          'workflowStages': [
            for (final stage in stages)
              {...stage.json, if (stage.id == 'stage-qa') 'category': 'done'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).readOnly, isTrue);
      expect(find.textContaining('완료된 작업의 내용은 잠겨'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
