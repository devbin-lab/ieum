import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/task_editor.dart';
import 'package:ieum_flutter/task_comments_panel.dart';
import 'package:ieum_flutter/task_handoff_dialog.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/project_schedule_view.dart';

import 'part_workflow_test_fixtures.dart';
import 'task_lock_test.dart' show draft, storeFor;

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => null,
        );
  });
  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('creation checkbox locks the task to its author', (tester) async {
    size(tester, const Size(1024, 900));
    final store = storeFor(routeWorker);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('등록'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TaskEditor(store: store),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('등록'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task-title')), '잠근 작업 등록');
    await tester.ensureVisible(find.byKey(const Key('task-create-lock')));
    await tester.tap(find.byKey(const Key('task-create-lock')));
    await tester.tap(find.byKey(const Key('task-save')));
    await tester.pumpAndSettle();
    expect(store.tasks.single.lockedBy, routeWorker.id);
    expect(find.byType(TaskEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'locked handoff prevents whole-part confirmation in a narrow dialog',
    (tester) async {
      size(tester, const Size(360, 540));
      final store = storeFor(routeWorker);
      final task = store.save({...draft(), 'lockedBy': routeWorker.id});
      final plan = store.planHandoff(
        task,
        task.status,
        routeId: 'manual-handoff',
        receiverGroup: 'part:role-pd',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TaskHandoffDialog(plan: plan, store: store),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('task-handoff-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(540));
      await tester.ensureVisible(find.byKey(const Key('task-handoff-lock')));
      await tester.tap(find.byKey(const Key('task-handoff-lock')));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a locked viewer can comment without changing the work', (
    tester,
  ) async {
    size(tester, const Size(360, 540));
    final origin = storeFor(routeWorker);
    final task = origin.save({...draft(), 'lockedBy': routeWorker.id});
    final store = storeFor(routeReviewer, task: task);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AnimatedBuilder(
              animation: store,
              builder: (_, _) =>
                  TaskCommentsPanel(store: store, task: store.find(task.id)),
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('task-comment-input')),
      '코멘트로 수정 요청',
    );
    await tester.tap(find.byKey(const Key('task-comment-add')));
    await tester.pumpAndSettle();
    expect(find.text('코멘트로 수정 요청'), findsOneWidget);
    expect(store.find(task.id).lockedBy, routeWorker.id);
    expect(store.find(task.id).description, task.description);
    expect(store.canEdit(store.find(task.id)), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'calendar selection shows tasks on a middle day, not only the deadline',
    (tester) async {
      size(tester, const Size(1280, 840));
      final store = storeFor(routeWorker);
      final now = DateTime.now();
      String day(int value) =>
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${value.toString().padLeft(2, '0')}';
      final task = store.save({
        ...draft(),
        'assignedDate': day(2),
        'dueDate': day(4),
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectScheduleView(
              store: store,
              onOpenTask: (_) {},
              onEditTask: (_) {},
              onCreateTask: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final value in [2, 3, 4]) {
        await tester.tap(find.byKey(Key('schedule-day-${day(value)}')));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('schedule-agenda-${task.id}')), findsOneWidget);
      }
      await tester.tap(find.byKey(Key('schedule-day-${day(5)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('schedule-agenda-${task.id}')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings navigation removes the automation entry', (
    tester,
  ) async {
    size(tester, const Size(1000, 600));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsShell(
            selected: SettingsSection.projectGeneral,
            personal: false,
            onSelected: (_) {},
            contentBuilder: (_) => const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('작업 단계'), findsNothing);
    expect(find.text('파트'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
