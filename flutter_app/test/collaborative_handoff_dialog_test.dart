import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_editor.dart';
import 'package:ieum_flutter/task_handoff.dart';
import 'package:ieum_flutter/task_handoff_dialog.dart';

class _ReviewStore extends TaskStore {
  _ReviewStore() : super(':memory:');
  bool current = true;

  @override
  bool isHandoffCurrent(TaskHandoffPlan plan) => current;

  void invalidate() {
    current = false;
    notifyListeners();
  }
}

class _Result {
  TaskHandoffConfirmation? confirmation;
}

const _transfer = TaskHandoffPlan(
  taskId: 'planning-result',
  title: '기획 결과 전달',
  version: 4,
  sourceId: 'doing',
  sourceName: '진행중',
  destinationId: 'doing',
  destinationName: '진행중',
  action: 'advance',
  transitionName: '담당자에게 전달',
  routeId: 'manual-handoff',
  recipientLabel: '전달 대상을 선택하세요',
  editWarning: '',
  workflowSnapshot: 'snapshot',
  actorId: 'planner',
  requiresRecipient: true,
  purpose: 'work',
  canSelectPurpose: true,
  receiverGroupOptions: {'part:planning': '기획', 'part:pd': 'PD'},
  receiverPersonOptions: {'planner': '기획자', 'pd': '담당 PD'},
  receiverPersonGroups: {
    'planner': ['', 'part:planning'],
    'pd': ['', 'part:pd'],
  },
);

const _return = TaskHandoffPlan(
  taskId: 'planning-result',
  title: '기획 결과 전달',
  version: 5,
  sourceId: 'doing',
  sourceName: '진행중',
  destinationId: 'doing',
  destinationName: '진행중',
  action: 'reject',
  transitionName: '이전 담당자에게 반려',
  routeId: 'manual-return',
  recipientLabel: 'QA 담당자',
  editWarning: '',
  workflowSnapshot: 'snapshot',
  actorId: 'pd',
  receiverPerson: 'qa',
  purpose: 'revision',
);

Future<_Result> _open(
  WidgetTester tester,
  _ReviewStore store, {
  TaskHandoffPlan plan = _transfer,
}) async {
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open-transfer'),
            onPressed: () async {
              result.confirmation = await showTaskHandoffDialog(
                context,
                plan: plan,
                store: store,
              );
            },
            child: const Text('전달'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-transfer')));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  late _ReviewStore store;
  setUp(() => store = _ReviewStore());
  tearDown(() => store.dispose());

  testWidgets('same-status transfer preserves selected purpose and recipient', (
    tester,
  ) async {
    final result = await _open(tester, store);
    expect(find.text('진행중 유지'), findsOneWidget);
    expect(find.textContaining('다른 활성 참여자도'), findsOneWidget);
    final confirm = find.byKey(const Key('task-handoff-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(find.byKey(const Key('task-handoff-purpose')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-review')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-handoff-receiver-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-part:pd')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-handoff-receiver-person')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-pd')));
    await tester.pumpAndSettle();
    expect(result.confirmation, isNull);
    expect(store.tasks, isEmpty);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    final selected = result.confirmation!.plan;
    expect(selected.sourceId, 'doing');
    expect(selected.destinationId, 'doing');
    expect(selected.purpose, 'review');
    expect(selected.receiverGroup, 'part:pd');
    expect(selected.receiverPerson, 'pd');
    expect(tester.takeException(), isNull);
  });

  testWidgets('return keeps status and needs a comment before confirmation', (
    tester,
  ) async {
    final result = await _open(tester, store, plan: _return);
    final confirm = find.byKey(const Key('task-handoff-confirm'));
    expect(find.text('진행중 유지'), findsOneWidget);
    expect(find.text('처리 목적: 수정'), findsOneWidget);
    expect(find.byKey(const Key('task-handoff-purpose')), findsNothing);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.confirmation, isNull);
    await tester.enterText(
      find.byKey(const Key('rework-reason')),
      '  QA 보완이 필요합니다.  ',
    );
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result.confirmation!.reason, 'QA 보완이 필요합니다.');
    expect(result.confirmation!.plan.receiverPerson, 'qa');
    expect(result.confirmation!.plan.destinationId, 'doing');
    expect(result.confirmation!.plan.purpose, 'revision');
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow transfer remains cancellable after invalidation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = await _open(tester, store);
    final person = find.byKey(const Key('task-handoff-receiver-person'));
    await tester.ensureVisible(person);
    await tester.tap(person);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-pd')));
    await tester.pumpAndSettle();
    store.invalidate();
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('task-handoff-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(420));
    await tester.tap(find.byKey(const Key('task-handoff-cancel')));
    await tester.pumpAndSettle();
    expect(result.confirmation, isNull);
    expect(store.tasks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor keeps registration distinct from the current recipient', (
    tester,
  ) async {
    const planner = Person(
      'gh-2',
      '기획자',
      '기',
      'unassigned',
      0,
      login: 'planner',
      parts: ['기획'],
    );
    const pd = Person(
      'gh-3',
      '담당 PD',
      'P',
      'unassigned',
      0,
      login: 'pd',
      parts: ['PD'],
    );
    final project = ProjectManifest(
      'collaborative-editor',
      '공동 작업',
      'gh-1',
      [
        const Person('gh-1', '관리자', '관', 'owner', 0, login: 'owner'),
        planner,
        pd,
      ],
      parts: const ['기획', 'PD'],
      roles: const [
        ProjectRole('role-plan', '기획', {}),
        ProjectRole('role-pd', 'PD', {}),
      ],
      unifiedParts: true,
      workflowSheet: WorkflowSheet.defaultFor(['todo', 'doing', 'done']),
    );
    final collaborativeStore = TaskStore(
      ':memory:',
      project: project,
      identity: planner,
      seed: [
        {
          'id': 'editor-task',
          'title': 'PD에게 전달한 작업',
          'status': 'doing',
          'part': '기획',
          'priority': 'normal',
          'assigneeId': 'gh-2',
          'reviewerId': 'gh-3',
          'assignedDate': '2026-10-08',
          'dueDate': '',
          'completedDate': '',
          'description': '',
          'reworkReason': '',
          'workflowTarget': '',
          'workflowPerson': 'gh-3',
          'workflowRoute': 'manual-handoff',
          'workflowPurpose': 'review',
          'version': 2,
          'updatedAt': '2026-10-08T00:00:00Z',
        },
      ],
    );
    addTearDown(collaborativeStore.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskEditor(
            store: collaborativeStore,
            task: collaborativeStore.find('editor-task'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('등록 담당자'), findsOneWidget);
    expect(find.text('현재 담당자 · 담당 PD'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-reviewer-gh-3')), findsNothing);
    TextField input(String key) => tester.widget<TextField>(
      find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
      ),
    );
    expect(input('task-title').readOnly, isFalse);
    expect(input('task-description').readOnly, isFalse);
    expect(tester.takeException(), isNull);
  });
}
