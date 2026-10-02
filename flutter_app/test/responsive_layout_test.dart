import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/window_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('startup window fits portrait displays and scaled work areas', () {
    for (final workArea in [
      const Size(1080, 1880),
      const Size(720, 1240),
      const Size(540, 940),
    ]) {
      final size = initialWindowSize(workArea);
      expect(size.width, lessThan(workArea.width));
      expect(size.height, lessThan(workArea.height));
    }
    expect(minimumWindowSize.width, lessThanOrEqualTo(540));
    expect(minimumWindowSize.height, lessThanOrEqualTo(480));
  });

  testWidgets(
    'portrait half-screen, scaling and narrow settings keep controls reachable',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('ieum-responsive-');
      final seed =
          jsonDecode(
                File('assets/demo-snapshot.json').readAsStringSync(),
              )['tasks']
              as List;
      final store = TaskStore(
        '${directory.path}/project-with-a-long-local-database-path-for-portrait-screen-testing.sqlite',
        seed: seed,
      );
      final sync = GitHubSync(store);
      addTearDown(() {
        sync.dispose();
        store.dispose();
        directory.deleteSync(recursive: true);
      });
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      await tester.pumpWidget(IeumApp(store: store, sync: sync));

      Future<void> section(String id) async {
        final menu = find.byKey(const Key('settings-category-menu'));
        if (menu.evaluate().isNotEmpty) {
          await tester.tap(menu);
          await tester.pumpAndSettle();
        }
        final target = find.byKey(Key('settings-$id'));
        final list = find.descendant(
          of: find.byKey(const Key('settings-navigation')),
          matching: find.byType(ListView),
        );
        tester.widget<ListView>(list).controller!.jumpTo(0);
        await tester.pumpAndSettle();
        final scrollable = find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        );
        await tester.scrollUntilVisible(target, 80, scrollable: scrollable);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      for (final size in [
        const Size(1080, 940),
        const Size(720, 620),
        const Size(540, 940),
        const Size(480, 420),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await tester.tapAt(
          tester.getTopLeft(find.byKey(const Key('sidebar-account'))) +
              const Offset(18, 18),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('account-settings')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        for (final field in tester.widgetList<SelectableText>(
          find.byType(SelectableText),
        )) {
          if (field.data == store.filename) {
            final bounds = tester.getRect(find.byWidget(field));
            expect(bounds.right, lessThanOrEqualTo(size.width));
            expect(bounds.left, greaterThanOrEqualTo(64));
          }
        }
        for (final id in [
          'assignments',
          'github',
          'notifications',
          'changes',
          'general',
        ]) {
          await section(id);
        }
        final close = tester.getRect(find.byKey(const Key('window-close')));
        expect(close.right, lessThanOrEqualTo(size.width));
        await tester.tap(find.byKey(const Key('nav-0')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('view-kanban')));
        await tester.tap(find.byKey(const Key('view-kanban')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('view-list')));
        await tester.tap(find.byKey(const Key('view-list')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('task-list')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('new-task')));
        await tester.tap(find.byKey(const Key('new-task')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('task-title')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byTooltip('작업 등록 닫기'));
        await tester.tap(find.byTooltip('작업 등록 닫기'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      // Switching layouts must preserve the active category without duplicating controllers.
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const Key('sidebar-account'))) +
            const Offset(18, 18),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-settings')));
      await tester.pumpAndSettle();
      await section('notifications');
      await tester.tap(find.byKey(const Key('settings-category-menu')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1480, 940);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('settings-content-title')))
            .data,
        '알림',
      );
      expect(find.byKey(const Key('settings-category-menu')), findsNothing);
      tester.view.physicalSize = const Size(540, 940);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-category-menu')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-list')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
