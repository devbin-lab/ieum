import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/store.dart';

import 'v020_store_test.dart' as workflow_fixtures;
import 'part_workflow_test_fixtures.dart' show personalReviewProject;

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
      expect(find.text('저장소 연결'), findsWidgets);
      for (final size in [const Size(1480, 940), const Size(1160, 740)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('github-configure')));
        await tester.pumpAndSettle();
        final repository = tester.widget<TextField>(
          find.byKey(const Key('github-repository')),
        );
        expect(repository.controller!.text, isEmpty);
        await tester.tap(find.byKey(const Key('github-advanced-settings')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('github-token')))
              .obscureText,
          isTrue,
        );
        await tester.tap(find.text('연결'));
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
    expect(find.byKey(const ValueKey('task-reviewer-pm')), findsNothing);
    await tester.enterText(find.byKey(const Key('task-due')), '2026-10-12');
    await tester.enterText(find.byKey(const Key('task-description')), '동작 검증');
    await tester.tap(find.byKey(const Key('task-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-title')), findsNothing);
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
    expect(find.text('시작일'), findsOneWidget);
    expect(find.text('마감일'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'project Kanban uses manual progress and locked handoff with comments',
    (tester) async {
      const project = personalReviewProject;
      store.dispose();
      store = TaskStore(
        ':memory:',
        project: project,
        identity: workflow_fixtures.worker,
      );
      final task = store.save({
        ...workflow_fixtures.draft(),
        'lockedBy': workflow_fixtures.worker.id,
      });
      await setup(tester, const Size(1480, 940));
      await tester.tap(find.byKey(const Key('view-kanban')));
      await tester.pumpAndSettle();
      final card = find.byKey(Key('card-${task.id}'));
      final start = tester.getCenter(card);
      final target =
          tester.getTopLeft(find.byKey(const Key('column-doing'))) +
          const Offset(80, 60);
      await tester.dragFrom(start, target - start);
      await tester.pumpAndSettle();
      expect(store.find(task.id).status, 'todo');
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(store.find(task.id).status, 'doing');
      expect(find.byKey(const Key('column-review')), findsOneWidget);
      expect(find.byKey(const Key('column-rework')), findsNothing);
      final current = store.find(task.id);
      store.confirmHandoff(
        store.planHandoff(
          current,
          'todo',
          routeId: 'manual-handoff',
          receiverPerson: workflow_fixtures.reviewer.id,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('task-edit-${task.id}')), findsNothing);
      expect(find.text('반려하여 전달'), findsNothing);
      store.setMeta('profile', workflow_fixtures.reviewer.id);
      store.updateProject(project);
      await tester.pumpAndSettle();
      expect(find.byKey(Key('task-edit-${task.id}')), findsOneWidget);
      final received = store.find(task.id);
      store.transition(
        task.id,
        'doing',
        expectedVersion: received.version,
        routeId: 'manual-start',
      );
      store.addTaskComment(
        task.id,
        '검토 의견',
        expectedVersion: store.find(task.id).version,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('task-status-menu-${task.id}')));
      await tester.pumpAndSettle();
      final complete = find.byKey(
        Key('task-status-action-${task.id}-manual-finish'),
      );
      await tester.tap(complete);
      await tester.pumpAndSettle();
      expect(store.find(task.id).status, 'doing');
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(store.find(task.id).status, 'done');
      expect(store.find(task.id).completedDate, isNotEmpty);
      expect(store.find(task.id).comments.single['text'], '검토 의견');
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
    expect(find.text('1개 작업'), findsOneWidget);
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
    expect(store.find('IE-101').status, 'todo');
    await tester.tap(find.byKey(const Key('task-handoff-confirm')));
    await tester.pumpAndSettle();
    expect(store.find('IE-101').status, 'doing');
    await tester.tap(find.byKey(const Key('view-list')));
    await tester.pumpAndSettle();
    final table = tester.widget<DataTable>(find.byType(DataTable));
    expect(table.rows, hasLength(1));
    expect(
      find.descendant(of: find.byType(DataTable), matching: find.text('진행중')),
      findsOneWidget,
    );
    expect(find.text('1개 작업'), findsOneWidget);
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
      if (expected == 0) {
        expect(find.text('표시할 작업이 없습니다'), findsOneWidget);
        expect(find.byType(DataTable), findsNothing);
      } else {
        expect(
          tester.widget<DataTable>(find.byType(DataTable)).rows,
          hasLength(expected),
        );
      }

      await tester.tap(find.byTooltip('알림 미리보기'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notification-filter-bar')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('project-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-task')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-priority-normal')),
      );
      await tester.tap(find.byKey(const ValueKey('task-priority-normal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-high')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('task-priority-high')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('task-assignee-planner')),
      );
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
