import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/project_schedule_view.dart';
import 'package:ieum_flutter/project_timeline_view.dart';
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

  testWidgets('alert preview opens its task in the last board view', (
    tester,
  ) async {
    size(tester);
    final store = storeFor(seed: task());
    final before = jsonEncode(store.find('delete-task').data);
    store.setMeta(
      'ui.workspace',
      jsonEncode({
        'page': 6,
        'view': 'kanban',
        'lastWorkPage': 6,
        'projectTabsVersion': 1,
      }),
    );
    store.db.execute('INSERT INTO notification_inbox VALUES (?,?)', [
      'navigation',
      jsonEncode({
        'id': 'navigation',
        'taskId': 'delete-task',
        'title': '담당 작업 알림',
        'eventType': 'task.assigned',
        'recipientId': store.profileId,
        'read': false,
        'createdAt': '2026-10-08T00:00:00Z',
      }),
    ]);
    await tester.pumpWidget(
      IeumApp(
        store: store,
        home: Workspace(store: store, projectSwitcher: const Text('프로젝트 선택')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sidebar-notifications')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('담당 작업 알림'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notification-detail')), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(store.notifications.single['read'], isTrue);
    await tester.tap(find.byKey(const Key('notification-open-task')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-kanban')), findsOneWidget);
    expect(find.byType(TaskDetailToolbar), findsOneWidget);
    expect(jsonEncode(store.find('delete-task').data), before);
    await tester.tap(find.byTooltip('작업 상세 닫기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-view-tab-timeline')));
    await tester.pumpAndSettle();
    expect(find.byType(ProjectTimelineView), findsOneWidget);
    expect(find.byKey(const Key('project-view-sidebar')), findsOneWidget);
    expect(jsonDecode(store.meta('ui.workspace'))['page'], 7);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'project task deep link keeps schedule mode and consumes focus once',
    (tester) async {
      size(tester);
      final store = storeFor(seed: task());
      final before = jsonEncode(store.find('delete-task').data);
      store.setMeta(
        'ui.workspace',
        jsonEncode({
          'page': 4,
          'view': 'kanban',
          'lastWorkPage': 0,
          'projectTabsVersion': 1,
        }),
      );
      store.setMeta(
        'ui.schedule',
        jsonEncode({
          'mode': 'timeline',
          'month': '2026-01-01',
          'selected': '2026-01-03',
        }),
      );
      await tester.pumpWidget(
        IeumApp(
          store: store,
          home: Workspace(
            store: store,
            projectSwitcher: const Text('프로젝트 선택'),
            initialTaskId: 'delete-task',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProjectScheduleView), findsOneWidget);
      expect(find.byType(TaskDetailToolbar), findsOneWidget);
      var saved = jsonDecode(store.meta('ui.schedule')) as Map;
      expect(saved['mode'], 'timeline');
      expect(saved['month'], '2026-10-01');
      expect(saved['selected'], '2026-10-08');
      await tester.tap(find.byTooltip('작업 상세 닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule-next-month')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-view-tab-timeline')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-view-tab-schedule')));
      await tester.pumpAndSettle();
      saved = jsonDecode(store.meta('ui.schedule')) as Map;
      expect(saved['mode'], 'timeline');
      expect(saved['month'], '2026-11-01');
      expect(jsonEncode(store.find('delete-task').data), before);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
