import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/popup_ui.dart';
import 'package:ieum_flutter/store.dart';

import 'v020_store_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TaskStore store;
  late WorkTask task;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  tearDown(() => store.dispose());

  Future<void> mount(WidgetTester tester, {ProjectManifest? project}) async {
    tester.view.physicalSize = const Size(1480, 940);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store = TaskStore(
      ':memory:',
      project: project ?? fixtures.project,
      identity: fixtures.owner,
    );
    store.setMeta(
      'github.config',
      jsonEncode({'repository': 'team/data', 'enabled': false}),
    );
    task = store.save(fixtures.draft(title: '확인하고 전달할 작업'));
    store.setMeta('profile', fixtures.worker.id);
    await tester.pumpWidget(IeumApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
  }

  // Includes persistence effects, rather than only the displayed status.
  String persistedState() => jsonEncode({
    for (final table in [
      'tasks',
      'activity',
      'notification_outbox',
      'github_queue',
    ])
      table: store.db
          .select('SELECT id,body FROM $table ORDER BY id')
          .map((row) => {'id': row['id'], 'body': row['body']})
          .toList(),
  });

  Finder handoff(String action, String destination) {
    final route =
        store
            .availableHandoffs(store.find(task.id))
            .where(
              (plan) =>
                  plan.action == action && plan.destinationId == destination,
            )
            .firstOrNull
            ?.routeId ??
        '';
    return find.byKey(
      Key(
        'task-handoff-${task.id}-$action-$destination${route.isEmpty ? '' : '-$route'}',
      ),
    );
  }

  Future<void> dragTo(WidgetTester tester, String destination) async {
    final card = find.byKey(Key('card-${task.id}'));
    final start = tester.getTopLeft(card) + const Offset(50, 45);
    final target =
        tester.getTopLeft(find.byKey(Key('column-$destination'))) +
        const Offset(90, 85);
    await tester.dragFrom(start, target - start);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'legacy automation cannot replace manual start and cancellation preserves work',
    (tester) async {
      final project = ProjectManifest.fromJson({
        ...fixtures.project.json,
        'workflowStages': [
          const WorkflowStage('todo', '접수').json,
          const WorkflowStage('stage-preflight', '자료 보완').json,
          const WorkflowStage('doing', '제작').json,
          const WorkflowStage('review', '품질 점검').json,
          const WorkflowStage('done', '납품').json,
        ],
        'workflowSheet': const WorkflowSheet(
          nodes: [
            WorkflowSheetNode('todo', 'todo'),
            WorkflowSheetNode('preflight', 'stage-preflight'),
            WorkflowSheetNode('doing', 'doing'),
            WorkflowSheetNode('review', 'review'),
            WorkflowSheetNode('done', 'done'),
          ],
          routes: [
            WorkflowSheetRoute(
              id: 'preflight-preset',
              from: 'todo',
              to: 'preflight',
              name: '자료 보완 요청',
              assignment: 'keep',
            ),
          ],
        ).json,
        'workflowAutomation': const WorkflowAutomation(
          reviewEnabled: true,
          connections: [
            WorkflowConnection('todo', 'stage-preflight', assignedOnly: true),
          ],
        ).json,
      });
      await mount(tester, project: project);
      expect(handoff('advance', 'stage-preflight'), findsNothing);
      final action = handoff('advance', 'doing');
      expect(action, findsOneWidget);
      expect(
        find.descendant(of: action, matching: find.text('시작')),
        findsOneWidget,
      );
      final before = persistedState();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-handoff-confirm')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(IeumDialog),
          matching: find.textContaining('진행중'),
        ),
        findsWidgets,
      );
      expect(persistedState(), before);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(persistedState(), before);
      expect(store.find(task.id).version, task.version);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Kanban drag waits for confirmation, cancellation preserves work and acceptance writes once',
    (tester) async {
      await mount(tester);
      final before = persistedState();
      final activityCount = store.activity.length;
      final notificationCount = store.records('notification_outbox').length;
      await dragTo(tester, 'doing');
      expect(find.byKey(const Key('task-handoff-confirm')), findsOneWidget);
      expect(persistedState(), before);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(persistedState(), before);
      await dragTo(tester, 'doing');
      expect(store.find(task.id).status, 'todo');
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(store.find(task.id).status, 'doing');
      expect(store.find(task.id).version, task.version + 1);
      expect(store.activity.length, activityCount + 1);
      expect(
        store.records('notification_outbox').length,
        notificationCount + 1,
      );
      expect(store.db.select('SELECT id FROM github_queue'), hasLength(1));
      final queued = jsonDecode(
        store.db.select('SELECT body FROM github_queue').single['body']
            as String,
      );
      expect(queued['proposal']['changes'].single['task']['status'], 'doing');
      expect(
        queued['proposal']['changes'].single['task']['version'],
        task.version + 1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repeated handoff clicks open one final confirmation and write nothing until accepted',
    (tester) async {
      await mount(tester);
      final before = persistedState();
      final button = tester.widget<ButtonStyleButton>(
        handoff('advance', 'doing'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(find.byType(IeumDialog), findsOneWidget);
      expect(find.byKey(const Key('task-handoff-confirm')), findsOneWidget);
      expect(persistedState(), before);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(persistedState(), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'list view uses the same flow destination and confirmation before transmitting',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byKey(const Key('view-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('task-actions-more-${task.id}')));
      await tester.pumpAndSettle();
      final action = find.byKey(
        Key(
          'task-handoff-list-${task.id}-advance-doing-${store.planHandoff(task, 'doing').routeId}',
        ),
      );
      expect(action, findsOneWidget);
      expect(
        find.descendant(of: action, matching: find.textContaining('작업 시작')),
        findsOneWidget,
      );
      await tester.ensureVisible(action);
      final before = persistedState();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-handoff-confirm')), findsOneWidget);
      expect(persistedState(), before);
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(store.find(task.id).status, 'doing');
      expect(store.find(task.id).version, task.version + 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a changed task revision invalidates an open final confirmation',
    (tester) async {
      await mount(tester);
      await tester.tap(handoff('advance', 'doing'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const Key('task-handoff-confirm')),
            )
            .onPressed,
        isNotNull,
      );
      store.setTaskPinned(task.id, true, expectedVersion: task.version);
      final before = persistedState();
      await tester.pumpAndSettle();
      expect(find.text('작업 정보가 변경되었습니다. 창을 닫고 다시 시도하세요.'), findsOneWidget);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const Key('task-handoff-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(persistedState(), before);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(handoff('advance', 'doing'), findsOneWidget);
      expect(persistedState(), before);
      expect(tester.takeException(), isNull);
    },
  );
}
