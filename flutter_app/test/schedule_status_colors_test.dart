import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/project_schedule_view.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_test_fixtures.dart';
import 'project_schedule_view_test.dart' show date, task;

void main() {
  testWidgets(
    'calendar, agenda and timeline follow live board states even when overdue',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, 1);
      final last = DateTime(now.year, now.month + 1, 0);
      final item = task('switch', assigned: date(first), due: date(last));
      final late = task(
        'late',
        assigned: date(first),
        due: date(first),
      ).copy({'status': 'doing'});
      final store = TaskStore(
        ':memory:',
        project: personalReviewProject,
        identity: routeOwner,
        seed: [item.data, late.data],
      );
      addTearDown(store.dispose);
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
      await tester.tap(find.byKey(const Key('schedule-completed')));
      await tester.pumpAndSettle();

      Finder bars(String id) => find.byWidgetPredicate(
        (w) =>
            w is Material &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('calendar-span-$id-'),
      );
      Future<void> check(Color background, Color foreground) async {
        await tester.pumpAndSettle();
        expect(bars('switch'), findsWidgets);
        for (final element in bars('switch').evaluate()) {
          expect((element.widget as Material).color, background);
        }
        final title = find
            .descendant(of: bars('switch').first, matching: find.text('switch'))
            .first;
        expect(tester.widget<Text>(title).style!.color, foreground);
        expect(
          tester
              .widget<Material>(find.byKey(const Key('schedule-agenda-switch')))
              .color,
          background,
        );
        expect(tester.takeException(), isNull);
      }

      void move(String status, {String reason = ''}) {
        final current = store.find('switch');
        store.transition(
          current.id,
          status,
          reason: reason,
          expectedVersion: current.version,
        );
      }

      await check(const Color(0xfff1f3f5), const Color(0xff6e687b));
      move('doing');
      await check(const Color(0xffedf4ff), const Color(0xff2f6fda));
      for (final element in bars('late').evaluate()) {
        expect((element.widget as Material).color, const Color(0xffedf4ff));
      }
      move('review');
      await check(const Color(0xfffff1e5), const Color(0xffd47a1f));
      move('hold', reason: '자료 대기');
      await check(const Color(0xfff2edff), const Color(0xff7963d5));
      move('review');
      move('done');
      await check(const Color(0xffedf6ef), const Color(0xff417458));
      await tester.tap(find.text('타임라인'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Material>(find.byKey(const Key('timeline-span-switch')))
            .color,
        const Color(0xffedf6ef),
      );
      expect(
        tester
            .widget<Material>(find.byKey(const Key('timeline-span-late')))
            .color,
        const Color(0xffedf4ff),
      );
      expect(store.tasks, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
}
