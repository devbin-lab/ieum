import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/task_detail_toolbar.dart';

import 'part_workflow_test_fixtures.dart';
import 'task_deletion_test.dart' show storeFor, task;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });

  Future<void> open(
    WidgetTester tester, {
    WorkTask? seed,
    bool lockedViewer = false,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = storeFor(
      seed: seed ?? task(),
      identity: lockedViewer ? routeReviewer : routeWorker,
    );
    await tester.pumpWidget(IeumApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('card-delete-task')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'transfer belongs to assignee, with grouped status and sticky tools',
    (tester) async {
      await open(tester);
      final toolbar = find.byType(TaskDetailToolbar);
      expect(
        find.descendant(of: toolbar, matching: find.byType(FilledButton)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('task-detail-assignment-delete-task')),
          matching: find.widgetWithText(OutlinedButton, '전달'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('task-edit-delete-task')), findsOneWidget);
      expect(find.byKey(const Key('task-delete-delete-task')), findsNothing);
      final before = tester.getRect(toolbar);
      final content = find.byKey(const Key('task-detail-content-delete-task'));
      await tester.drag(content, const Offset(0, -650));
      await tester.pumpAndSettle();
      expect(tester.getRect(toolbar), before);
      await tester.tap(find.byKey(const Key('task-status-menu-delete-task')));
      await tester.pumpAndSettle();
      for (final key in [
        'task-status-action-delete-task-manual-review',
        'task-status-action-delete-task-manual-finish',
        'task-status-action-delete-task-manual-hold',
        'task-status-action-delete-task-manual-drop',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget);
      }
      await tester.tap(
        find.byKey(const Key('task-status-action-delete-task-manual-hold')),
      );
      await tester.pumpAndSettle();
      final store = tester.widget<IeumApp>(find.byType(IeumApp)).store;
      expect(store.find('delete-task').status, 'doing');
      await tester.enterText(
        find.byKey(const Key('rework-reason')),
        '외부 자료 대기',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(store.find('delete-task').status, 'hold');
      expect(
        find.descendant(of: toolbar, matching: find.text('작업 재개')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'management actions use latest revision and fit a narrow window',
    (tester) async {
      final seed = WorkTask.fromJson({
        ...task().data,
        'title': List.filled(16, '아주 긴 작업 제목').join(' '),
      });
      await open(tester, seed: seed);
      tester.view.physicalSize = const Size(360, 540);
      await tester.pumpAndSettle();
      final toolbar = find.byType(TaskDetailToolbar);
      expect(tester.getRect(toolbar).right, lessThanOrEqualTo(360));
      expect(
        tester
            .getRect(
              find.byKey(const Key('task-detail-assignment-delete-task')),
            )
            .right,
        lessThanOrEqualTo(360),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('task-more-delete-task')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('task-delete-delete-task'))).right,
        lessThanOrEqualTo(360),
      );
      await tester.tap(find.byKey(const Key('task-pin-detail-delete-task')));
      await tester.pumpAndSettle();
      final store = tester.widget<IeumApp>(find.byType(IeumApp)).store;
      expect(store.find('delete-task').isPinned, isTrue);
      await tester.tap(find.byKey(const Key('task-more-delete-task')));
      await tester.pumpAndSettle();
      expect(find.text('상단 고정 해제'), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-lock-delete-task')));
      await tester.pumpAndSettle();
      expect(store.find('delete-task').lockedBy, routeWorker.id);
      expect(store.find('delete-task').version, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('locked viewer has no mutation tools or primary action', (
    tester,
  ) async {
    await open(
      tester,
      lockedViewer: true,
      seed: WorkTask.fromJson({...task().data, 'lockedBy': routeWorker.id}),
    );
    final toolbar = find.byType(TaskDetailToolbar);
    expect(
      find.descendant(of: toolbar, matching: find.byType(FilledButton)),
      findsNothing,
    );
    expect(find.byKey(const Key('task-edit-delete-task')), findsNothing);
    expect(find.byKey(const Key('task-more-delete-task')), findsNothing);
    final status = tester.widget<OutlinedButton>(
      find.byKey(const Key('task-status-menu-delete-task')),
    );
    expect(status.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
