import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_handoff.dart';

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
  'PD 담당자',
  'P',
  'unassigned',
  0,
  login: 'pd',
  parts: ['PD'],
);
const _qa = Person(
  'gh-4',
  'QA 담당자',
  'Q',
  'unassigned',
  0,
  login: 'qa',
  parts: ['QA'],
);
const _nodes = [
  WorkflowSheetNode('todo', 'todo', x: -200),
  WorkflowSheetNode('doing', 'doing'),
  WorkflowSheetNode('done', 'done', x: 200),
];

ProjectManifest _project(WorkflowSheet sheet) => ProjectManifest(
  'collaborative-app',
  '공동 작업',
  _owner.id,
  [_owner, _planner, _pd, _qa],
  parts: const ['기획', 'PD', 'QA'],
  roles: const [
    ProjectRole('role-plan', '기획', {}),
    ProjectRole('role-pd', 'PD', {}),
    ProjectRole('role-qa', 'QA', {}),
  ],
  unifiedParts: true,
  workflowSheet: sheet,
);

Map<String, dynamic> _task() => {
  'id': 'planning-work',
  'title': '다음 담당자에게 넘길 기획 작업',
  'status': 'doing',
  'part': '기획',
  'priority': 'normal',
  'assigneeId': _planner.id,
  'reviewerId': _pd.id,
  'assignedDate': '2026-10-08',
  'dueDate': '',
  'completedDate': '',
  'description': '기획 본문',
  'reworkReason': '',
  'workflowTarget': '',
  'workflowPerson': _planner.id,
  'workflowPurpose': 'work',
  'workflowRoute': '',
  'version': 1,
  'updatedAt': '2026-10-08T00:00:00Z',
};

String _persistedState(TaskStore store) => jsonEncode({
  for (final table in [
    'tasks',
    'activity',
    'notification_outbox',
    'github_queue',
  ])
    table: store.db
        .select('SELECT id, body FROM $table ORDER BY id')
        .map((row) => {'id': row['id'], 'body': row['body']})
        .toList(),
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });

  Future<void> mount(WidgetTester tester, TaskStore store) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.setMeta(
      'github.config',
      jsonEncode({'repository': 'team/data', 'enabled': false}),
    );
    await tester.pumpWidget(IeumApp(store: store));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('view-kanban')));
    await tester.pumpAndSettle();
  }

  Finder transfer({bool detail = false}) => find.byKey(
    Key(
      'task-handoff-${detail ? 'detail-' : ''}planning-work-advance-doing-manual-handoff',
    ),
  );

  testWidgets(
    'direct transfer bypasses optional preset scope and keeps collaborative editing',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        identity: _planner,
        project: _project(
          const WorkflowSheet(
            nodes: _nodes,
            routes: [
              WorkflowSheetRoute(
                id: 'planning-to-pd',
                from: 'doing',
                to: 'todo',
                source: 'part:role-plan',
                destination: 'part:role-pd',
                purpose: 'review',
              ),
            ],
          ),
        ),
        seed: [_task()],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      for (final status in ['todo', 'doing', 'done']) {
        expect(find.byKey(Key('column-$status')), findsOneWidget);
      }
      final before = _persistedState(store);
      expect(transfer(), findsOneWidget);
      await tester.ensureVisible(transfer());
      await tester.tap(transfer());
      await tester.pumpAndSettle();
      expect(find.text('진행중 유지'), findsOneWidget);

      await tester.tap(find.byKey(const Key('task-handoff-purpose')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-handoff-receiver-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-part:role-qa')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-handoff-receiver-person')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-gh-4')));
      await tester.pumpAndSettle();
      expect(_persistedState(store), before);
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();

      final delivered = store.find('planning-work');
      expect(delivered.status, 'doing');
      expect(delivered.workflowTarget, 'part:role-qa');
      expect(delivered.workflowPerson, _qa.id);
      expect(delivered.workflowSender, _planner.id);
      expect(delivered.workflowPurpose, 'review');
      expect(store.canEditContent(delivered), isTrue);
      expect(store.isAssignedToMe(delivered), isFalse);
      expect(
        find.descendant(
          of: find.byKey(const Key('column-doing')),
          matching: find.byKey(const Key('card-planning-work')),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('card-planning-work')));
      await tester.pumpAndSettle();
      expect(transfer(detail: true), findsOneWidget);
      final edit = find.widgetWithText(OutlinedButton, '작업 수정');
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final description = find.byKey(const Key('task-description'));
      await tester.ensureVisible(description);
      await tester.enterText(description, '기획자가 전달 후 본문을 보완했습니다.');
      await tester.tap(find.byKey(const Key('task-save')));
      await tester.pumpAndSettle();
      expect(store.find('planning-work').description, contains('본문을 보완'));
      expect(store.find('planning-work').workflowPerson, _qa.id);
      await tester.scrollUntilVisible(
        find.byTooltip('작업 상세 닫기'),
        -400,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('작업 상세 닫기'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('scope-mine')));
      await tester.tap(find.byKey(const Key('scope-mine')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-planning-work')), findsNothing);
      // Re-read the same in-memory snapshot as the receiving account.
      store.setMeta('profile', _qa.id);
      store.updateProject(store.project!);
      await tester.pumpAndSettle();
      expect(store.isAssignedToMe(store.find('planning-work')), isTrue);
      expect(find.byKey(const Key('card-planning-work')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty sheet still has card and detail transfer and narrow cancellation writes nothing',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        identity: _planner,
        project: _project(const WorkflowSheet(nodes: _nodes)),
        seed: [_task()],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      expect(transfer(), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-planning-work')));
      await tester.pumpAndSettle();
      final before = _persistedState(store);
      expect(transfer(detail: true), findsOneWidget);
      await tester.ensureVisible(transfer(detail: true));
      await tester.tap(transfer(detail: true));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(360, 540);
      await tester.pumpAndSettle();
      final person = find.byKey(const Key('task-handoff-receiver-person'));
      await tester.ensureVisible(person);
      await tester.tap(person);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-gh-3')));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('task-handoff-confirm'));
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(540));
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(_persistedState(store), before);
      expect(store.find('planning-work').status, 'doing');
      expect(store.find('planning-work').workflowPerson, _planner.id);
      await tester.scrollUntilVisible(
        transfer(detail: true),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(transfer(detail: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'received scope excludes own start and includes actual delivery',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        identity: _planner,
        project: _project(const WorkflowSheet(nodes: _nodes)),
        seed: [
          {..._task(), 'id': 'own-start', 'status': 'todo'},
          {
            ..._task(),
            'id': 'received-work',
            'workflowRoute': 'manual-handoff',
            'workflowSender': _pd.id,
            'workflowPurpose': 'review',
          },
        ],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      final start = find.byKey(
        const Key('task-handoff-own-start-advance-doing-manual-start'),
      );
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      expect(store.find('own-start').status, 'doing');
      expect(store.find('own-start').workflowRoute, 'manual-start');
      expect(store.find('own-start').workflowSender, '');
      await tester.ensureVisible(find.byKey(const Key('scope-review')));
      await tester.tap(find.byKey(const Key('scope-review')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-own-start')), findsNothing);
      expect(find.byKey(const Key('card-received-work')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long presets stay within one list row and direct transfer uses more',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        identity: _planner,
        project: _project(
          const WorkflowSheet(
            nodes: _nodes,
            routes: [
              WorkflowSheetRoute(
                id: 'long-pd',
                from: 'doing',
                to: 'doing',
                name: '기획 작업을 PD에게 전달하여 최종 검토를 요청하는 사전 설정',
                source: 'part:role-plan',
                destination: 'part:role-pd',
                purpose: 'review',
              ),
              WorkflowSheetRoute(
                id: 'long-qa',
                from: 'doing',
                to: 'doing',
                name: '기획 작업을 QA에게 전달하여 세부 내용을 검증하는 사전 설정',
                source: 'part:role-plan',
                destination: 'part:role-qa',
                purpose: 'review',
              ),
              WorkflowSheetRoute(
                id: 'long-owner',
                from: 'doing',
                to: 'doing',
                name: '기획 작업을 관리자에게 전달하여 추가 수정을 요청하는 사전 설정',
                source: 'part:role-plan',
                destination: 'role:owner',
                purpose: 'revision',
              ),
            ],
          ),
        ),
        seed: [_task()],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      expect(
        store
            .availableTransfers(store.find('planning-work'))
            .where((plan) => plan.routeId.startsWith('long-')),
        hasLength(3),
      );
      await tester.ensureVisible(find.byKey(const Key('view-list')));
      await tester.tap(find.byKey(const Key('view-list')));
      await tester.pumpAndSettle();
      final table = find.byType(DataTable);
      expect(table, findsOneWidget);
      expect(tester.getSize(table).height, lessThanOrEqualTo(160));
      expect(tester.takeException(), isNull);
      final before = _persistedState(store);
      final more = find.byKey(const Key('task-actions-more-planning-work'));
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      final direct = find.byWidgetPredicate(
        (widget) =>
            widget is PopupMenuItem<TaskHandoffPlan> &&
            widget.value?.routeId == 'manual-handoff',
      );
      expect(direct, findsOneWidget);
      await tester.tap(direct);
      await tester.pumpAndSettle();
      expect(find.text('진행중 유지'), findsOneWidget);
      expect(find.byKey(const Key('task-handoff-confirm')), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-handoff-cancel')));
      await tester.pumpAndSettle();
      expect(_persistedState(store), before);
      expect(tester.takeException(), isNull);
    },
  );
}
