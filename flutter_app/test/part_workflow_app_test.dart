import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

const _owner = Person('gh-1', '관리자', '관', 'owner', 0, login: 'owner');
const _planner = Person(
  'gh-2',
  '기획자',
  '기',
  'unassigned',
  0,
  login: 'planner',
  parts: ['기획'],
);
const _pd = Person(
  'gh-3',
  'PD 작업자',
  '피',
  'unassigned',
  0,
  login: 'pd',
  parts: ['PD'],
);
const _otherPd = Person(
  'gh-4',
  '다른 PD',
  '다',
  'unassigned',
  0,
  login: 'other-pd',
  parts: ['PD'],
);
const _sheet = WorkflowSheet(
  nodes: [
    WorkflowSheetNode('todo', 'todo'),
    WorkflowSheetNode('doing', 'doing'),
    WorkflowSheetNode('review', 'review'),
    WorkflowSheetNode('done', 'done'),
  ],
  routes: [
    WorkflowSheetRoute(id: 'start', from: 'todo', to: 'doing'),
    WorkflowSheetRoute(
      id: 'pd-all',
      from: 'doing',
      to: 'review',
      source: 'part:role-plan',
      destination: 'part:role-pd',
    ),
    WorkflowSheetRoute(
      id: 'pd-person',
      from: 'doing',
      to: 'review',
      source: 'part:role-plan',
      destination: 'part:role-pd',
      person: 'gh-3',
    ),
    WorkflowSheetRoute(
      id: 'approve',
      from: 'review',
      to: 'done',
      action: 'approve',
      source: 'part:role-pd',
    ),
    WorkflowSheetRoute(
      id: 'reject',
      from: 'review',
      to: 'todo',
      action: 'reject',
      source: 'part:role-pd',
      destination: 'part:role-plan',
    ),
  ],
);
const _project = ProjectManifest(
  'project-ui-routing',
  '파트 전달',
  'gh-1',
  [_owner, _planner, _pd, _otherPd],
  roles: [ProjectRole('role-plan', '기획', {}), ProjectRole('role-pd', 'PD', {})],
  parts: ['기획', 'PD'],
  unifiedParts: true,
  workflowStages: [
    WorkflowStage('todo', '확인중'),
    WorkflowStage('doing', '진행중'),
    WorkflowStage('review', '검토'),
    WorkflowStage('done', '완료'),
  ],
  workflowSheet: _sheet,
);

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
    store = TaskStore(':memory:', project: _project, identity: _owner);
    store.setMeta(
      'github.config',
      jsonEncode({'repository': 'team/data', 'enabled': false}),
    );
    task = store.save({
      'title': '경로별 전달 작업',
      'part': '기획',
      'assigneeId': 'gh-2',
      'reviewerId': 'gh-3',
      'priority': 'normal',
      'assignedDate': '2026-10-01',
      'dueDate': '',
      'description': '',
    });
    store.transition(
      task.id,
      'doing',
      expectedVersion: task.version,
      routeId: 'start',
    );
    task = store.find(task.id);
    store.setMeta('profile', _planner.id);
  });
  tearDown(() => store.dispose());

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1480, 940);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(IeumApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
  }

  Finder handoff(String route) =>
      find.byKey(Key('task-handoff-${task.id}-advance-review-$route'));

  testWidgets(
    'same destination exposes distinct route actions and confirms the exact receiver',
    (tester) async {
      await mount(tester);
      expect(handoff('pd-all'), findsOneWidget);
      expect(handoff('pd-person'), findsOneWidget);
      expect(
        find.descendant(
          of: handoff('pd-all'),
          matching: find.textContaining('PD 전체'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: handoff('pd-person'),
          matching: find.textContaining('PD 작업자'),
        ),
        findsOneWidget,
      );
      await tester.tap(handoff('pd-person'));
      await tester.pumpAndSettle();
      expect(store.find(task.id).version, task.version);
      expect(find.byKey(const Key('task-handoff-recipient')), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      final next = store.find(task.id);
      expect(next.workflowRoute, 'pd-person');
      expect(next.workflowTarget, 'part:role-pd');
      expect(next.workflowPerson, 'gh-3');
      expect(next.status, 'review');
      expect(store.canEditContent(next), isTrue);
      expect(store.currentActorLabel(next), 'PD 작업자');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ambiguous Kanban drop requires choosing the receiver before final confirmation',
    (tester) async {
      await mount(tester);
      final card = find.byKey(Key('card-${task.id}'));
      final start = tester.getTopLeft(card) + const Offset(50, 45);
      final destination =
          tester.getTopLeft(find.byKey(const Key('column-doing'))) +
          const Offset(90, 30);
      await tester.dragFrom(start, destination - start);
      await tester.pumpAndSettle();
      expect(find.text('전달 경로 선택'), findsOneWidget);
      expect(find.byKey(const Key('task-handoff-confirm')), findsNothing);
      expect(store.find(task.id).version, task.version);
      await tester.tap(
        find.widgetWithText(SimpleDialogOption, '검토 단계로 전달 · PD 전체'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-handoff-confirm')), findsOneWidget);
      expect(store.find(task.id).version, task.version);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(store.find(task.id).version, task.version);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'layout-only edit keeps confirmation valid while recipient policy change invalidates it',
    (tester) async {
      await mount(tester);
      await tester.tap(handoff('pd-all'));
      await tester.pumpAndSettle();
      final moved = WorkflowSheet(
        nodes: [
          for (final n in _sheet.nodes)
            WorkflowSheetNode(n.id, n.stageId, x: n.x + 30, y: n.y + 50),
        ],
        routes: _sheet.routes,
      );
      store.updateProject(
        ProjectManifest.fromJson({
          ..._project.json,
          'workflowSheet': moved.json,
        }),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('task-handoff-confirm')))
            .onPressed,
        isNotNull,
      );
      final changed = WorkflowSheet(
        nodes: moved.nodes,
        routes: [
          for (final r in moved.routes)
            r.id == 'pd-all'
                ? WorkflowSheetRoute(
                    id: r.id,
                    from: r.from,
                    to: r.to,
                    source: r.source,
                    destination: r.destination,
                    person: 'gh-4',
                  )
                : r,
        ],
      );
      store.updateProject(
        ProjectManifest.fromJson({
          ..._project.json,
          'workflowSheet': changed.json,
        }),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('task-handoff-confirm')))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const Key('task-handoff-stale')), findsOneWidget);
      expect(store.find(task.id).version, task.version);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'administrator recovery remains visible on a completed task and reassigns after confirmation',
    (tester) async {
      store.setMeta('profile', _owner.id);
      store.transition(
        task.id,
        'review',
        expectedVersion: task.version,
        routeId: 'pd-all',
      );
      store.transition(
        task.id,
        'done',
        expectedVersion: store.find(task.id).version,
        routeId: 'approve',
      );
      task = store.find(task.id);
      await mount(tester);
      await tester.tap(find.byKey(Key('card-${task.id}')));
      await tester.pumpAndSettle();
      final recover = find.byKey(Key('task-admin-recover-${task.id}'));
      await tester.ensureVisible(recover);
      await tester.tap(recover);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-confirm')), findsOneWidget);
      expect(store.find(task.id).status, 'done');
      await tester.tap(find.byKey(const Key('recovery-confirm')));
      await tester.pumpAndSettle();
      final next = store.find(task.id);
      expect(next.workflowRoute, 'admin-recovery');
      expect(next.workflowPerson, 'gh-2');
      expect(next.status, 'todo');
      expect(next.version, task.version + 1);
      expect(tester.takeException(), isNull);
    },
  );
}
