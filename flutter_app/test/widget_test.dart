import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  final seed =
      jsonDecode(File('assets/demo-snapshot.json').readAsStringSync())['tasks']
          as List;
  late TaskStore store;
  setUp(() => store = TaskStore(':memory:', seed: seed));
  tearDown(() => store.dispose());
  Future<void> setup(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(IeumApp(store: store));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop pages fit common window sizes without layout errors', (
    tester,
  ) async {
    await setup(tester, const Size(1480, 940));
    expect(find.byKey(const Key('card-IE-101')), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final i in [1, 2, 3, 0]) {
      await tester.tap(find.byKey(Key('nav-$i')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(1160, 740);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('nav-3')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('create task assigns part defaults and schedule fields', (
    tester,
  ) async {
    await setup(tester, const Size(1480, 940));
    store.setProfile('pm');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-task')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('task-title')),
      'Flutter 등록 검증',
    );
    await tester.tap(find.byKey(const ValueKey('task-part-기획')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('프로그래밍').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('task-assignee-dev')), findsOneWidget);
    expect(find.byKey(const ValueKey('task-reviewer-pm')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('task-due')), '2026-10-12');
    await tester.enterText(find.byKey(const Key('task-description')), '동작 검증');
    await tester.tap(find.byKey(const Key('task-save')));
    await tester.pumpAndSettle();
    expect(find.text('새 작업 등록'), findsNothing);
    expect(store.tasks.length, 9);
    expect(
      store.tasks.firstWhere((t) => t.title == 'Flutter 등록 검증').assigneeId,
      'dev',
    );
    await tester.tap(find.byKey(const Key('nav-1')));
    await tester.pumpAndSettle();
    expect(find.text('작업 지정일'), findsOneWidget);
    expect(find.text('완료일'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'kanban drag, review, rework and approval work without native desktop input',
    (tester) async {
      await setup(tester, const Size(1480, 940));
      store.setProfile('pm');
      await tester.pumpAndSettle();
      final start = tester.getCenter(find.byKey(const Key('card-IE-101')));
      final target =
          tester.getTopLeft(find.byKey(const Key('column-doing'))) +
          const Offset(80, 60);
      await tester.dragFrom(start, target - start);
      await tester.pumpAndSettle();
      expect(store.find('IE-101').status, 'doing');
      await tester.tap(find.byKey(const Key('card-IE-101')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('검토 요청').last);
      await tester.pumpAndSettle();
      expect(store.find('IE-101').currentId, 'pm');
      await tester.tap(find.text('재작업 요청').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rework-reason')), '검토 의견');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '재작업 요청'));
      await tester.pumpAndSettle();
      expect(store.find('IE-101').status, 'rework');
      await tester.tap(find.text('작업 시작').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('검토 요청').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('완료 승인').last);
      await tester.pumpAndSettle();
      expect(store.find('IE-101').status, 'done');
      expect(store.find('IE-101').completedDate, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
