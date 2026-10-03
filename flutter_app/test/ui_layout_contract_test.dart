import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TaskStore store;
  setUp(() {
    store = TaskStore(
      ':memory:',
      seed:
          jsonDecode(
                File('assets/demo-snapshot.json').readAsStringSync(),
              )['tasks']
              as List,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  tearDown(() => store.dispose());

  testWidgets(
    'one home destination, full width table and compact list preserve task access',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1440, 940);
      await tester.pumpWidget(IeumApp(store: store));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-0')), findsNothing);
      expect(find.byKey(const Key('project-home')), findsOneWidget);
      final outer = tester.getRect(find.byKey(const Key('task-list')));
      final table = tester.getRect(find.byType(DataTable));
      expect(table.width, closeTo(outer.width - 2, 1));
      tester.view.physicalSize = const Size(540, 940);
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsNothing);
      final task = store.tasks.first;
      final row = find.byKey(Key('compact-task-${task.id}'));
      await tester.ensureVisible(row);
      expect(tester.getRect(row).right, lessThanOrEqualTo(540));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byTooltip('작업 상세 닫기'), findsOneWidget);
      expect(find.text(task.title), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'task form keeps save and close accessible in short scaled windows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(540, 470), const Size(1080, 540)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          IeumApp(
            store: store,
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(1.3),
              ),
              child: Workspace(store: store),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-task')));
        await tester.pumpAndSettle();
        final save = find.byKey(const Key('task-save'));
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getRect(save).bottom, lessThan(size.height));
        expect(find.byTooltip('작업 등록 닫기').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('작업 등록 닫기'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
