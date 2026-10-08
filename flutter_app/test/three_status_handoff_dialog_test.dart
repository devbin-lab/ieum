import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_handoff.dart';
import 'package:ieum_flutter/task_handoff_dialog.dart';

class _DialogStore extends TaskStore {
  _DialogStore() : super(':memory:');
  bool current = true;

  @override
  bool isHandoffCurrent(TaskHandoffPlan plan) => current;

  void invalidate() {
    current = false;
    notifyListeners();
  }
}

class _Result {
  TaskHandoffConfirmation? value;
}

const _plan = TaskHandoffPlan(
  taskId: 'task-dialog',
  title: '기획 결과 검토',
  version: 3,
  sourceId: 'doing',
  sourceName: '진행중',
  destinationId: 'todo',
  destinationName: '확인중',
  action: 'move',
  transitionName: '검토 요청',
  routeId: 'request-review',
  recipientLabel: '전달 대상을 선택하세요',
  editWarning: '전달 후에는 다음 담당자가 내용을 처리합니다.',
  workflowSnapshot: 'snapshot',
  actorId: 'planner',
  requiresRecipient: true,
  receiverGroupOptions: {'part:planning': '기획', 'part:pd': 'PD'},
  receiverPersonOptions: {'planner': '기획자', 'pd': '담당 PD'},
  receiverPersonGroups: {
    'planner': ['', 'part:planning'],
    'pd': ['', 'part:pd'],
  },
);

Future<_Result> _open(
  WidgetTester tester,
  _DialogStore store, {
  TaskHandoffPlan plan = _plan,
}) async {
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open-delivery'),
            onPressed: () async => result.value = await showTaskHandoffDialog(
              context,
              plan: plan,
              store: store,
            ),
            child: const Text('전달'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-delivery')));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  late _DialogStore store;
  setUp(() => store = _DialogStore());
  tearDown(() => store.dispose());

  testWidgets(
    'handoff requires a recipient and returns the selected part and person',
    (tester) async {
      final result = await _open(tester, store);
      final confirm = find.byKey(const Key('task-handoff-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

      await tester.tap(find.byKey(const Key('task-handoff-receiver-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-part:pd')));
      await tester.pumpAndSettle();
      expect(find.text('다음 처리: PD 전체'), findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);

      await tester.tap(find.byKey(const Key('task-handoff-receiver-person')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('option-planner')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('option-pd')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('rework-reason')),
        '  검토해 주세요.  ',
      );
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(result.value!.plan.receiverGroup, 'part:pd');
      expect(result.value!.plan.receiverPerson, 'pd');
      expect(result.value!.plan.recipientLabel, 'PD · 담당 PD');
      expect(result.value!.reason, '검토해 주세요.');
      expect(store.tasks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an individual can receive work without a part selection', (
    tester,
  ) async {
    final result = await _open(tester, store);
    await tester.tap(find.byKey(const Key('task-handoff-receiver-person')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-pd')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-handoff-confirm')));
    await tester.pumpAndSettle();
    expect(result.value!.plan.receiverGroup, '');
    expect(result.value!.plan.receiverPerson, 'pd');
    expect(result.value!.plan.recipientLabel, '담당 PD');
    expect(tester.takeException(), isNull);
  });

  testWidgets('part handoff is usable in a narrow window and invalidates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = await _open(tester, store);
    final group = find.byKey(const Key('task-handoff-receiver-group'));
    await tester.ensureVisible(group);
    await tester.tap(group);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('option-part:pd')));
    await tester.pumpAndSettle();
    store.invalidate();
    await tester.pumpAndSettle();
    final confirm = find.byKey(const Key('task-handoff-confirm'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(420));
    await tester.tap(find.byKey(const Key('task-handoff-cancel')));
    await tester.pumpAndSettle();
    expect(result.value, isNull);
    expect(tester.takeException(), isNull);
  });
}
