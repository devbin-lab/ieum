import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_schedule_view.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_definition_editor.dart';

import 'part_workflow_test_fixtures.dart';

String date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

WorkTask task(String id, {String? due, String? assigned, String? title}) =>
    WorkTask.fromJson({
      'id': id,
      'title': title ?? id,
      'part': '기획',
      'status': 'todo',
      'priority': 'normal',
      'assigneeId': routeWorker.id,
      'reviewerId': routeReviewer.id,
      'assignedDate': assigned ?? date(DateTime.now()),
      'dueDate': due ?? '',
      'completedDate': '',
      'description': '',
      'reworkReason': '',
      'version': 1,
      'updatedAt': '2026-10-08T00:00:00Z',
    });

void main() {
  late TaskStore store;
  setUp(() {
    store = TaskStore(
      ':memory:',
      project: personalReviewProject,
      identity: routeOwner,
    );
  });
  tearDown(() => store.dispose());

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('calendar opens real tasks and filtering never creates data', (
    tester,
  ) async {
    await size(tester, const Size(1280, 840));
    final today = date(DateTime.now());
    store.put(task('TASK-dated', due: today, title: '출시 작업'));
    store.put(task('TASK-undated', title: '일정 미정'));
    final originalCount = store.tasks.length;
    final originalChanges = store.changes;
    WorkTask? opened;
    DateTime? created;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectScheduleView(
            store: store,
            onOpenTask: (task) => opened = task,
            onEditTask: (_) {},
            onCreateTask: (day) => created = day,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('schedule-agenda-TASK-dated')));
    expect(opened?.id, 'TASK-dated');
    await tester.tap(find.byKey(const Key('schedule-create')));
    expect(date(created!), today);
    await tester.enterText(find.byKey(const Key('schedule-search')), '없음');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-agenda-TASK-dated')), findsNothing);
    expect(find.text('이 날짜에 예정된 작업이 없습니다.'), findsOneWidget);
    expect(store.tasks.length, originalCount);
    expect(store.changes, originalChanges);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar and bounded month timeline fit a narrow window', (
    tester,
  ) async {
    await size(tester, const Size(360, 520));
    store.put(
      task(
        'TASK-long',
        due: '2099-12-31',
        assigned: '2000-01-01',
        title: '아주 긴 작업 제목이 들어가도 일정 칸을 넘어서지 않도록 표시하는 작업',
      ),
    );
    store.put(task('TASK-undated'));
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
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('타임라인'));
    await tester.tap(find.text('타임라인'));
    await tester.pumpAndSettle();
    final days = DateTime(DateTime.now().year, DateTime.now().month + 1, 0).day;
    for (var day = 1; day <= days; day++) {
      expect(find.byKey(Key('timeline-day-$day')), findsOneWidget);
    }
    expect(find.byKey(Key('timeline-day-${days + 1}')), findsNothing);
    expect(
      find.byKey(const Key('schedule-timeline-TASK-long')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1280, 840);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.tasks.length, 2);
  });

  testWidgets('compact workflow switches state and canvas without overflow', (
    tester,
  ) async {
    await size(tester, const Size(440, 680));
    final before = store.meta('project');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkflowDefinitionEditor(store: store)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workflow-compact-view')), findsOneWidget);
    expect(find.byKey(const Key('workflow-stage-list')), findsOneWidget);
    await tester.tap(find.text('흐름'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workflow-sheet-viewport')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('상태'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workflow-stage-list')), findsOneWidget);
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workflow-compact-view')), findsNothing);
    expect(find.byKey(const Key('workflow-stage-list')), findsOneWidget);
    expect(find.byKey(const Key('workflow-sheet-viewport')), findsOneWidget);
    expect(store.meta('project'), before);
    expect(tester.takeException(), isNull);
  });
}
