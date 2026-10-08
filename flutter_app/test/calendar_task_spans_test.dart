import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/project_schedule_view.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_test_fixtures.dart';
import 'project_schedule_view_test.dart' show date, task;

void main() {
  test(
    'one task is a continuous interval and resumes in the following week',
    () {
      final item = task(
        'draft',
        assigned: '2026-10-08',
        due: '2026-10-12',
        title: '기획서 초안',
      );
      final first = calendarWeekSpans([item], DateTime(2026, 10, 5)).single;
      expect(first.firstDay, 3);
      expect(first.lastDay, 6);
      expect(first.continuesBefore, isFalse);
      expect(first.continuesAfter, isTrue);
      final next = calendarWeekSpans(
        [item],
        DateTime(2026, 10, 12),
        previousLanes: {item.id: first.lane},
      ).single;
      expect(next.firstDay, 0);
      expect(next.lastDay, 0);
      expect(next.continuesBefore, isTrue);
      expect(next.continuesAfter, isFalse);
      expect(next.lane, first.lane);
      expect(calendarWeekSpans([item], DateTime(2026, 10, 19)), isEmpty);
    },
  );

  test(
    'overlapping tasks never share a lane and identical titles remain separate',
    () {
      final items = [
        task('a', assigned: '2026-10-05', due: '2026-10-09', title: '같은 이름'),
        task('b', assigned: '2026-10-08', due: '2026-10-13', title: '같은 이름'),
        task('c', assigned: '2026-10-08', due: '2026-10-10'),
        task('d', assigned: '2026-10-11', due: '2026-10-11'),
      ];
      final spans = calendarWeekSpans(items, DateTime(2026, 10, 5));
      expect(spans, hasLength(4));
      for (final a in spans) {
        for (final b in spans) {
          if (a.task.id != b.task.id &&
              a.firstDay <= b.lastDay &&
              b.firstDay <= a.lastDay) {
            expect(a.lane, isNot(b.lane));
          }
        }
      }
      final lanes = {for (final span in spans) span.task.id: span.lane};
      final next = calendarWeekSpans(
        items,
        DateTime(2026, 10, 12),
        previousLanes: lanes,
      ).single;
      expect(next.task.id, 'b');
      expect(next.lane, lanes['b']);
    },
  );

  test(
    'month-crossing and extremely long intervals are clipped to seven days',
    () {
      final long = task('long', assigned: '2000-01-01', due: '2099-12-31');
      final span = calendarWeekSpans([long], DateTime(2026, 9, 28)).single;
      expect(span.firstDay, 0);
      expect(span.lastDay, 6);
      expect(span.continuesBefore, isTrue);
      expect(span.continuesAfter, isTrue);
      final startOnly = task('point', assigned: '2026-10-01');
      final point = calendarWeekSpans([
        startOnly,
      ], DateTime(2026, 9, 28)).single;
      expect(point.firstDay, 3);
      expect(point.lastDay, 3);
      expect(point.continuesAfter, isFalse);
    },
  );

  testWidgets(
    'a bar crosses day borders, continues next week, and opens the actual task',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, 1);
      final gridStart = DateTime(
        first.year,
        first.month,
        first.day - first.weekday + 1,
      );
      final weekStart = DateTime(
        gridStart.year,
        gridStart.month,
        gridStart.day + 7,
      );
      final assigned = DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day + 2,
      );
      final nextWeek = DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day + 7,
      );
      final due = DateTime(nextWeek.year, nextWeek.month, nextWeek.day + 2);
      final item = task(
        'draft',
        assigned: date(assigned),
        due: date(due),
        title: '기획서 초안',
      );
      final store = TaskStore(
        ':memory:',
        project: personalReviewProject,
        identity: routeOwner,
        seed: [item.data],
      );
      addTearDown(store.dispose);
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectScheduleView(
              store: store,
              onOpenTask: (task) => opened = task.id,
              onEditTask: (_) {},
              onCreateTask: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstBar = find.byKey(
        Key('calendar-span-draft-${date(weekStart)}'),
      );
      final secondBar = find.byKey(
        Key('calendar-span-draft-${date(nextWeek)}'),
      );
      expect(firstBar, findsOneWidget);
      expect(secondBar, findsOneWidget);
      final firstRect = tester.getRect(firstBar);
      final startCell = tester.getRect(
        find.byKey(Key('schedule-day-${date(assigned)}')),
      );
      final sunday = DateTime(
        weekStart.year,
        weekStart.month,
        weekStart.day + 6,
      );
      final sundayCell = tester.getRect(
        find.byKey(Key('schedule-day-${date(sunday)}')),
      );
      expect(firstRect.left, closeTo(startCell.left + 5, .1));
      expect(firstRect.right, closeTo(sundayCell.right, .1));
      expect(firstRect.width, greaterThan(startCell.width * 4));
      final nextRect = tester.getRect(secondBar);
      final mondayCell = tester.getRect(
        find.byKey(Key('schedule-day-${date(nextWeek)}')),
      );
      final endCell = tester.getRect(
        find.byKey(Key('schedule-day-${date(due)}')),
      );
      expect(nextRect.left, closeTo(mondayCell.left, .1));
      expect(nextRect.right, closeTo(endCell.right - 5, .1));
      await tester.tap(firstBar);
      expect(opened, item.id);
      expect(store.changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
