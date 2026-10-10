import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_schedule_view.dart';
import 'package:ieum_flutter/task_detail_toolbar.dart';

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

  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final view in ['list', 'kanban']) {
    testWidgets('calendar preview opens the task in saved $view layout', (
      tester,
    ) async {
      size(tester);
      final seed = WorkTask.fromJson({
        ...task().data,
        'assignedDate': '2026-10-10',
        'dueDate': '2026-10-12',
      });
      final store = storeFor(seed: seed);
      store.setMeta(
        'ui.workspace',
        jsonEncode({
          'page': 0,
          'view': view,
          'lastWorkPage': 0,
          'projectTabsVersion': 1,
        }),
      );
      store.setMeta(
        'ui.schedule',
        jsonEncode({
          'mode': 'calendar',
          'month': '2026-10-01',
          'selected': '2026-10-10',
        }),
      );
      final before = jsonEncode(store.find(seed.id).data);
      final changes = jsonEncode(store.changes);
      await tester.pumpWidget(
        IeumApp(
          store: store,
          home: Workspace(store: store, projectSwitcher: const Text('프로젝트')),
        ),
      );
      await tester.pumpAndSettle();
      final bar = find.byKey(const Key('calendar-span-delete-task-2026-10-05'));
      await tester.ensureVisible(bar);
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailToolbar), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('task-open-in-workspace-delete-task')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProjectScheduleView), findsNothing);
      expect(find.byType(TaskDetailToolbar), findsOneWidget);
      expect(
        find.byKey(const Key('task-open-in-workspace-delete-task')),
        findsNothing,
      );
      final saved = jsonDecode(store.meta('ui.workspace')) as Map;
      expect(saved['page'], 6);
      expect(saved['view'], view);
      expect(jsonEncode(store.find(seed.id).data), before);
      expect(jsonEncode(store.changes), changes);
      await tester.tap(find.byTooltip('작업 상세 닫기'));
      await tester.pumpAndSettle();
      expect(find.byType(TaskDetailToolbar), findsNothing);
      expect(
        find.byKey(Key(view == 'list' ? 'task-list' : 'task-kanban')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('calendar jump finds a task beyond the first list page', (
    tester,
  ) async {
    size(tester);
    final store = storeFor();
    for (var i = 0; i < 70; i++) {
      store.put(
        WorkTask.fromJson({
          ...task().data,
          'id': 'batch-${i.toString().padLeft(2, '0')}',
          'title': '작업 $i',
        }),
      );
    }
    store.setMeta(
      'ui.workspace',
      jsonEncode({
        'page': 0,
        'view': 'list',
        'lastWorkPage': 0,
        'projectTabsVersion': 1,
      }),
    );
    final before = jsonEncode(store.tasks.map((task) => task.data).toList());
    await tester.pumpWidget(
      IeumApp(
        store: store,
        home: Workspace(store: store, projectSwitcher: const Text('프로젝트')),
      ),
    );
    await tester.pumpAndSettle();
    tester
        .widget<ProjectScheduleView>(find.byType(ProjectScheduleView))
        .onOpenTask(store.find('batch-60'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-open-in-workspace-batch-60')));
    await tester.pumpAndSettle();
    expect(find.byType(TaskDetailToolbar), findsOneWidget);
    await tester.tap(find.byTooltip('작업 상세 닫기'));
    await tester.pumpAndSettle();
    expect(find.text('작업 60'), findsOneWidget);
    final target = tester.getRect(find.text('작업 60'));
    expect(target.top, greaterThan(240));
    expect(target.bottom, lessThan(900));
    expect(find.text('작업 0'), findsNothing);
    expect(jsonEncode(store.tasks.map((task) => task.data).toList()), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
