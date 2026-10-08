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
      project: fixtures.project,
      identity: fixtures.owner,
    ),
  );
  tearDown(() => store.dispose());

  WorkTask task() => store.save(fixtures.draft());
  WorkTask submitted() {
    final created = task();
    store.transition(created.id, 'doing', expectedVersion: created.version);
    store.transition(
      created.id,
      'review',
      expectedVersion: store.find(created.id).version,
    );
    return store.find(created.id);
  }

  testWidgets(
    'initial Enter does not submit and cancellation leaves work unchanged',
    (tester) async {
      final original = task();
      final plan = store.planHandoff(original, 'doing');
      final activityCount = store.activity.length;
      final result = await _openDialog(tester, store, plan);
      expect(find.text('${plan.buttonLabel} 확인'), findsOneWidget);
      expect(
        find.text('${plan.sourceName} → ${plan.destinationName}'),
        findsOneWidget,
      );
      expect(find.text('다음 처리: ${plan.recipientLabel}'), findsOneWidget);
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

  testWidgets(
    'rejection requires a nonblank comment in the same final confirmation',
    (tester) async {
      final original = submitted();
      final result = await _openDialog(
        tester,
        store,
        store.planHandoff(original, original.status, routeId: 'manual-return'),
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
      await tester.enterText(comment, '  설명을 보완해 주세요.  ');
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(result.value, '설명을 보완해 주세요.');
      expect(store.find(original.id).data, original.data);
      expect(tester.takeException(), isNull);
    },
  );

  for (final changed in ['task', 'automation']) {
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
              'workflowStages': [
                ...fixtures.legacyFourStages.take(3).map((s) => s.json),
                const WorkflowStage('stage-extra', '추가 단계').json,
                fixtures.legacyFourStages.last.json,
              ],
            }),
          );
        }
        await tester.pumpAndSettle();
        expect(find.text('작업 또는 프로젝트 설정이 변경되었습니다. 다시 확인하세요.'), findsOneWidget);
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
    'handoff preserves collaboration while completion displays its finality warning',
    (tester) async {
      store.updateProject(
        ProjectManifest.fromJson({
          ...store.project!.json,
          'workflowAutomation': const WorkflowAutomation(
            reviewEnabled: true,
            connections: [
              WorkflowConnection(
                'review',
                'done',
                action: 'approve',
                actor: 'reviewer',
                assignedOnly: true,
              ),
              WorkflowConnection(
                'review',
                'todo',
                action: 'reject',
                actor: 'reviewer',
                assignedOnly: true,
              ),
            ],
          ).json,
        }),
      );
      final original = task();
      store.transition(original.id, 'doing', expectedVersion: original.version);
      final working = store.find(original.id);
      final plan = store.planHandoff(
        working,
        working.status,
        routeId: 'manual-handoff',
      );
      expect(plan.editWarning, isNotEmpty);
      expect(plan.editWarning, contains('모든 활성 참여자'));
      expect(plan.editWarning, isNot(contains('수정할 수 없습니다')));
      await _openDialog(tester, store, plan);
      expect(
        find.byKey(const Key('task-handoff-edit-warning')),
        findsOneWidget,
      );
      expect(find.text(plan.editWarning), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(store.find(original.id).status, 'doing');
      final completion = store.planHandoff(
        working,
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
      expect(store.find(original.id).same(working), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rejection confirmation remains usable in a short narrow window',
    (tester) async {
      tester.view.physicalSize = const Size(360, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = submitted();
      final result = await _openDialog(
        tester,
        store,
        store.planHandoff(original, original.status, routeId: 'manual-return'),
      );
      await tester.ensureVisible(find.byKey(const Key('rework-reason')));
      await tester.enterText(find.byKey(const Key('rework-reason')), '반려 의견');
      await tester.pumpAndSettle();
      final finalButton = find.byKey(const Key('task-handoff-confirm'));
      expect(tester.getRect(finalButton).bottom, lessThanOrEqualTo(420));
      await tester.tap(finalButton);
      await tester.pumpAndSettle();
      expect(result.value, '반려 의견');
      expect(store.find(original.id).status, 'review');
      expect(tester.takeException(), isNull);
    },
  );
}
