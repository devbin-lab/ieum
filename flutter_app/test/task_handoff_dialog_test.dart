import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_handoff.dart';
import 'package:ieum_flutter/task_handoff_dialog.dart';

import 'v020_store_test.dart' as fixtures;

class _Result {
  bool completed = false;
  String? value;
}

Future<_Result> _openDialog(
  WidgetTester tester,
  TaskStore store,
  TaskHandoffPlan plan,
) async {
  final result = _Result();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const Key('open-handoff'),
            onPressed: () async {
              result.value = await showDialog<String>(
                context: context,
                builder: (_) => TaskHandoffDialog(plan: plan, store: store),
              );
              result.completed = true;
            },
            child: const Text('전달'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open-handoff')));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  late TaskStore store;
  setUp(
    () => store = TaskStore(
      ':memory:',
      project: ProjectManifest(
        fixtures.project.id,
        fixtures.project.name,
        fixtures.project.ownerId,
        fixtures.project.people,
        parts: fixtures.project.parts,
      ),
      identity: fixtures.owner,
    ),
  );
  tearDown(() => store.dispose());

  WorkTask task() => store.save(fixtures.draft());
  WorkTask working() {
    final created = task();
    store.transition(created.id, 'doing', expectedVersion: created.version);
    return store.find(created.id);
  }

  testWidgets(
    'initial Enter does not submit and cancellation leaves work unchanged',
    (tester) async {
      final original = task();
      final plan = store.planHandoff(original, 'doing');
      final activityCount = store.activity.length;
      final result = await _openDialog(tester, store, plan);
      expect(find.text('상태 변경'), findsOneWidget);
      expect(
        find.text('${plan.sourceName} → ${plan.destinationName}'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('task-handoff-recipient')), findsNothing);
      expect(find.byKey(const Key('task-handoff-edit-warning')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(result.completed, isFalse);
      expect(store.find(original.id).data, original.data);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, isNull);
      expect(store.find(original.id).data, original.data);
      expect(store.activity.length, activityCount);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'final confirmation returns an ordinary reason without committing',
    (tester) async {
      final original = task();
      final result = await _openDialog(
        tester,
        store,
        store.planHandoff(original, 'doing'),
      );
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(result.completed, isTrue);
      expect(result.value, '');
      expect(store.find(original.id).data, original.data);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hold requires a nonblank reason in the final confirmation', (
    tester,
  ) async {
    final original = working();
    final result = await _openDialog(
      tester,
      store,
      store.planHandoff(original, 'hold', routeId: 'manual-hold'),
    );
    final confirm = find.byKey(const Key('task-handoff-confirm'));
    final comment = find.byKey(const Key('rework-reason'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.enterText(comment, '   ');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result.completed, isFalse);
    await tester.enterText(comment, '  외부 자료를 기다리고 있습니다.  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result.value, '외부 자료를 기다리고 있습니다.');
    expect(store.find(original.id).data, original.data);
    expect(tester.takeException(), isNull);
  });

  for (final changed in ['task', 'participants']) {
    testWidgets(
      '$changed changes while confirmation is open invalidate the pending plan',
      (tester) async {
        final original = task();
        final result = await _openDialog(
          tester,
          store,
          store.planHandoff(original, 'doing'),
        );
        if (changed == 'task') {
          store.save({
            ...original.data,
            'title': '다른 사용자가 수정',
          }, expectedVersion: original.version);
        } else {
          store.updateProject(
            ProjectManifest.fromJson({
              ...store.project!.json,
              'members': [
                for (final member in store.project!.people)
                  {
                    ...member.json,
                    if (member.id == fixtures.reviewer.id) 'name': '이름이 바뀐 참여자',
                  },
              ],
            }),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('작업 정보가 변경되었습니다. 창을 닫고 다시 시도하세요.'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('task-handoff-confirm')),
              )
              .onPressed,
          isNull,
        );
        expect(result.completed, isFalse);
        expect(store.find(original.id).status, 'todo');
        await tester.tap(find.byKey(const Key('task-handoff-cancel')));
        await tester.pumpAndSettle();
        expect(result.value, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'confirmation revalidates the actor even before the dialog rebuilds',
    (tester) async {
      final original = task();
      final result = await _openDialog(
        tester,
        store,
        store.planHandoff(original, 'doing'),
      );
      // Metadata alone does not notify listeners, exercising the final click guard.
      store.setMeta('profile', fixtures.worker.id);
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(result.completed, isFalse);
      expect(find.byKey(const Key('task-handoff-stale')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('task-handoff-confirm')))
            .onPressed,
        isNull,
      );
      expect(store.find(original.id).data, original.data);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(result.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'handoff explains its optional lock while completion displays its finality warning',
    (tester) async {
      final current = working();
      final plan = store.planHandoff(
        current,
        'todo',
        routeId: 'manual-handoff',
      );
      expect(plan.requiresRecipient, isTrue);
      expect(plan.lockOnHandoff, isFalse);
      await _openDialog(tester, store, plan);
      expect(find.byKey(const Key('task-handoff-lock')), findsOneWidget);
      expect(find.text('잠금 없이 전달하면 모든 참여자가 수정할 수 있습니다.'), findsOneWidget);
      expect(find.byKey(const Key('task-handoff-edit-warning')), findsNothing);
      expect(find.text(plan.editWarning), findsNothing);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(store.find(current.id).status, 'doing');
      final completion = store.planHandoff(
        current,
        'done',
        routeId: 'manual-finish',
      );
      await _openDialog(tester, store, completion);
      expect(
        find.byKey(const Key('task-handoff-completion-help')),
        findsOneWidget,
      );
      expect(find.text(completion.editWarning), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(store.find(current.id).same(current), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('drop confirmation remains usable in a short narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final original = working();
    final result = await _openDialog(
      tester,
      store,
      store.planHandoff(original, 'drop', routeId: 'manual-drop'),
    );
    await tester.ensureVisible(find.byKey(const Key('rework-reason')));
    await tester.enterText(
      find.byKey(const Key('rework-reason')),
      '일정에서 제외합니다.',
    );
    await tester.pumpAndSettle();
    final finalButton = find.byKey(const Key('task-handoff-confirm'));
    expect(tester.getRect(finalButton).bottom, lessThanOrEqualTo(420));
    await tester.tap(finalButton);
    await tester.pumpAndSettle();
    expect(result.value, '일정에서 제외합니다.');
    expect(store.find(original.id).status, 'doing');
    expect(tester.takeException(), isNull);
  });
}
