import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  final seed =
      jsonDecode(File('assets/demo-snapshot.json').readAsStringSync())['tasks']
          as List;
  late TaskStore store;
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    store = TaskStore(':memory:', seed: seed);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  tearDown(() => store.dispose());
  Future<void> setup(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(IeumApp(store: store));
    await tester.pumpAndSettle();
  }

  Future<void> settings(WidgetTester tester, {bool changes = false}) async {
    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-settings')));
    await tester.pumpAndSettle();
    if (changes) {
      await tester.tap(find.byKey(const Key('settings-changes')));
      await tester.pumpAndSettle();
    }
  }

  testWidgets(
    'GitHub setup fits both window sizes and keeps destination user-selected',
    (tester) async {
      final sync = GitHubSync(store);
      addTearDown(sync.dispose);
      tester.view.physicalSize = const Size(1480, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(IeumApp(store: store, sync: sync));
      await tester.pumpAndSettle();
      await settings(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-github')));
      await tester.pumpAndSettle();
      expect(find.text('연결 상태'), findsOneWidget);
      for (final size in [const Size(1480, 940), const Size(1160, 740)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('github-configure')));
        await tester.pumpAndSettle();
        final repository = tester.widget<TextField>(
          find.byKey(const Key('github-repository')),
        );
        expect(repository.controller!.text, isEmpty);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('github-token')))
              .obscureText,
          isTrue,
        );
        await tester.tap(find.text('확인 후 자동 동기화 켜기'));
        await tester.pumpAndSettle();
        expect(
          find.text('Bad state: 저장소를 소유자/저장소 또는 GitHub HTTPS 주소로 입력하세요.'),
          findsOneWidget,
        );
        expect(sync.config.enabled, isFalse);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('취소'));
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets('desktop pages fit common window sizes without layout errors', (
    tester,
  ) async {
    await setup(tester, const Size(1480, 940));
    expect(find.byKey(const Key('task-list')), findsOneWidget);
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-IE-101')), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final i in [1, 2, 0]) {
      if (i == 0) {
        await tester.tap(find.byKey(const Key('project-home')));
      } else {
        await settings(tester, changes: i == 1);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    tester.view.physicalSize = const Size(1160, 740);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('view-list')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await settings(tester);
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
    expect(find.byKey(const Key('window-titlebar')), findsOneWidget);
    expect(find.byKey(const Key('window-close')), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
    expect(find.text('Flutter 등록 검증'), findsOneWidget);
    await tester.tap(find.byKey(const Key('view-list')));
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
      await tester.tap(find.byKey(const Key('view-kanban')));
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
  testWidgets('view switches preserve filters, task state and selection', (
    tester,
  ) async {
    await setup(tester, const Size(1480, 940));
    store.setProfile('pm');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('search')), 'IE-101');
    await tester.pumpAndSettle();
    expect(find.text('1개 작업 · 자동 저장'), findsOneWidget);
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-IE-101')), findsOneWidget);
    expect(find.byKey(const Key('card-IE-102')), findsNothing);
    final start = tester.getCenter(find.byKey(const Key('card-IE-101')));
    final target =
        tester.getTopLeft(find.byKey(const Key('column-doing'))) +
        const Offset(80, 60);
    await tester.dragFrom(start, target - start);
    await tester.pumpAndSettle();
    expect(store.find('IE-101').status, 'doing');
    await tester.tap(find.byKey(const Key('view-list')));
    await tester.pumpAndSettle();
    final table = tester.widget<DataTable>(find.byType(DataTable));
    expect(table.rows, hasLength(1));
    expect(
      find.descendant(of: find.byType(DataTable), matching: find.text('진행 중')),
      findsOneWidget,
    );
    expect(find.text('1개 작업 · 자동 저장'), findsOneWidget);
    await settings(tester, changes: true);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-home')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-list')), findsOneWidget);
    expect(tester.widget<DataTable>(find.byType(DataTable)).rows, hasLength(1));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'custom profile and part menus fit small windows and keep behavior',
    (tester) async {
      await setup(tester, const Size(1160, 740));
      await tester.tap(find.byKey(const Key('sidebar-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('profile')));
      await tester.pumpAndSettle();
      final profileOption = find.byKey(const ValueKey('option-dev'));
      final bounds = tester.getRect(profileOption);
      expect(bounds.top, greaterThanOrEqualTo(0));
      expect(bounds.bottom, lessThanOrEqualTo(740));
      await tester.tap(profileOption);
      await tester.pumpAndSettle();
      expect(store.profileId, 'dev');
      await tester.tap(find.byKey(const ValueKey('filter-')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-QA')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('filter-QA')), findsOneWidget);
      final expected = store.tasks.where((t) => t.part == 'QA').length;
      expect(
        tester.widget<DataTable>(find.byType(DataTable)).rows,
        hasLength(expected),
      );

      await tester.tap(find.byTooltip('알림 미리보기'));
      await tester.pumpAndSettle();
      expect(find.text('알림 미리보기'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-task')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('task-priority-normal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-high')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-priority-high')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('task-assignee-planner')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-artist')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('task-assignee-artist')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
