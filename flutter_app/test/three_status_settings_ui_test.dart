import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_definition_editor.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';
import 'package:ieum_flutter/workflow_sheet_handoff.dart';

void main() {
  const owner = Person('gh-1', '관리자', '관', 'owner', 0, login: 'admin');
  const roles = [ProjectRole('role-pd', 'PD', {})];

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'delivery editor preserves dynamic recipient scope and purpose conditions',
    (tester) async {
      size(tester);
      List<SheetHandoffRule>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await editSheetHandoff(
                    context,
                    from: '진행중',
                    to: '확인중',
                    fromStage: 'doing',
                    toStage: 'todo',
                    routes: const [
                      SheetHandoffRule(
                        id: 'send',
                        assignment: 'select',
                        destination: 'part:role-pd',
                        purpose: 'review',
                        requiredPurpose: 'work',
                      ),
                    ],
                    roles: roles,
                    people: const [owner],
                    parts: const ['PD'],
                  );
                },
                child: const Text('편집'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('편집'));
      await tester.pumpAndSettle();
      expect(find.text('선택 가능한 파트'), findsOneWidget);
      expect(find.text('받는 작업자'), findsNothing);
      final purpose = find.byKey(const ValueKey('workflow-route-purpose-0'));
      await tester.ensureVisible(purpose);
      await tester.tap(purpose);
      await tester.pumpAndSettle();
      await tester.tap(find.text('수정').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(saved!.single.assignment, 'select');
      expect(saved!.single.destination, 'part:role-pd');
      expect(saved!.single.person, isEmpty);
      expect(saved!.single.purpose, 'revision');
      expect(saved!.single.requiredPurpose, 'work');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dragging a delivery label preserves purpose and recipient policy',
    (tester) async {
      size(tester);
      const sheet = WorkflowSheet(
        nodes: [
          WorkflowSheetNode('doing', 'doing', x: -170),
          WorkflowSheetNode('todo', 'todo', x: 170),
        ],
        routes: [
          WorkflowSheetRoute(
            id: 'send',
            from: 'doing',
            to: 'todo',
            assignment: 'select',
            destination: 'part:role-pd',
            purpose: 'review',
            requiredPurpose: 'work',
          ),
        ],
      );
      WorkflowSheet? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowSheetCanvas(
              value: sheet,
              roles: roles,
              parts: const ['PD'],
              onChanged: (value) => saved = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.byKey(const Key('workflow-sheet-route-doing-todo-0'));
      final gesture = await tester.startGesture(
        tester.getCenter(label),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(55, 28));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(saved!.policyJson, sheet.policyJson);
      expect(saved!.routes.single.labelDx, isNot(0));
      expect(
        WorkflowSheet.fromJson(saved!.json).routes.single.purpose,
        'review',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'three-stage reset stays local and blocks dropping a used legacy state',
    (tester) async {
      size(tester);
      const stages = [
        WorkflowStage('todo', '확인중'),
        WorkflowStage('doing', '진행중'),
        WorkflowStage('review', '검토'),
        WorkflowStage('done', '완료'),
      ];
      final project = ProjectManifest(
        'legacy-project',
        '기존 프로젝트',
        owner.id,
        const [owner],
        unifiedParts: true,
        parts: const ['기획'],
        roles: const [ProjectRole('role-plan', '기획', {})],
        workflowStages: stages,
        workflowSheet: WorkflowSheet.defaultFor(
          stages.map((s) => s.id).toList(),
        ),
      );
      final store = TaskStore(':memory:', project: project, identity: owner);
      addTearDown(store.dispose);
      final task = store.save({
        'title': '기존 검토 작업',
        'part': '기획',
        'assigneeId': owner.id,
        'reviewerId': owner.id,
        'priority': 'normal',
        'assignedDate': '2026-10-08',
        'dueDate': '',
        'description': '',
      });
      store.put(task.copy({'status': 'review'}));
      final originalProject = store.meta('project');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: WorkflowDefinitionEditor(store: store)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-three-stage-default')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-three-stage-confirm')));
      await tester.pumpAndSettle();
      expect(store.meta('project'), originalProject);
      expect(store.find(task.id).status, 'review');
      final draft =
          jsonDecode(store.meta('workflow.draft.${project.id}')) as Map;
      expect((draft['stages'] as List).map((s) => s['id']), [
        'todo',
        'doing',
        'done',
      ]);
      expect(find.text('작업이 남아 있는 상태는 삭제할 수 없습니다.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('workflow-sheet-save')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
