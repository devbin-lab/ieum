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
  'PD 담당자',
  'P',
  'unassigned',
  0,
  login: 'pd',
  parts: ['PD'],
);
final _project = ProjectManifest(
  'three-board',
  '세 단계 보드',
  'gh-1',
  [_owner, _planner, _pd],
  roles: [ProjectRole('role-plan', '기획', {}), ProjectRole('role-pd', 'PD', {})],
  parts: ['기획', 'PD'],
  unifiedParts: true,
  workflowSheet: WorkflowSheet.defaultFor(['todo', 'doing', 'done']),
);

Map<String, dynamic> _task(
  String id,
  String title,
  String status, {
  String purpose = 'work',
  String person = 'gh-2',
  String target = '',
}) => {
  'id': id,
  'title': title,
  'status': status,
  'part': '기획',
  'assigneeId': 'gh-2',
  'reviewerId': 'gh-3',
  'priority': 'normal',
  'assignedDate': '2026-10-08',
  'dueDate': '',
  'completedDate': '',
  'description': '',
  'reworkReason': '',
  'workflowTarget': target,
  'workflowPerson': person,
  'workflowRoute': purpose == 'review' ? 'default-handoff' : '',
  'workflowPurpose': purpose,
  'version': 1,
  'updatedAt': '2026-10-08T00:00:00Z',
};

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
    tester.view.physicalSize = const Size(1480, 940);
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

  testWidgets(
    'six columns show recipient and purpose while my work follows the receiver',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        project: _project,
        identity: _pd,
        seed: [
          _task(
            'received',
            '검토 전달된 작업',
            'todo',
            purpose: 'review',
            person: 'gh-3',
            target: 'part:role-pd',
          ),
          _task('other', '기획자의 진행 작업', 'doing'),
        ],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      for (final status in [
        'todo',
        'doing',
        'review',
        'done',
        'hold',
        'drop',
      ]) {
        expect(find.byKey(Key('column-$status')), findsOneWidget);
      }
      expect(find.byKey(const Key('column-review')), findsOneWidget);
      expect(find.byKey(const Key('card-received')), findsOneWidget);
      expect(find.byKey(const Key('card-other')), findsOneWidget);
      expect(find.byKey(const Key('task-purpose-received')), findsOneWidget);
      final card = find.byKey(const Key('card-received'));
      expect(
        find.descendant(of: card, matching: find.text('PD')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('담당 · PD 담당자')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('scope-mine')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-received')), findsOneWidget);
      expect(find.byKey(const Key('card-other')), findsNothing);
      tester.view.physicalSize = const Size(600, 740);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(store.find('received').version, 1);
      expect(store.find('other').version, 1);
    },
  );

  testWidgets(
    'legacy review appears in review without rewriting stored status',
    (tester) async {
      final project = ProjectManifest.fromJson({
        ..._project.json,
        'workflowStages': [
          const WorkflowStage('todo', '확인중').json,
          const WorkflowStage('doing', '진행중').json,
          const WorkflowStage('review', '검토').json,
          const WorkflowStage('done', '완료').json,
        ],
        'workflowSheet': WorkflowSheet.defaultFor([
          'todo',
          'doing',
          'review',
          'done',
        ]).json,
      });
      final legacy = _task(
        'legacy',
        '기존 검토 작업',
        'review',
        purpose: '',
        person: 'gh-3',
      );
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: _pd,
        seed: [legacy],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      expect(
        find.descendant(
          of: find.byKey(const Key('column-review')),
          matching: find.byKey(const Key('card-legacy')),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('column-review')), findsOneWidget);
      expect(store.find('legacy').status, 'review');
      expect(store.find('legacy').workflowPurpose, '');
      expect(store.find('legacy').version, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'board delivery chooses a part and commits only after confirmation',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        project: _project,
        identity: _planner,
        seed: [_task('handoff', '기획에서 PD로 전달', 'doing')],
      );
      addTearDown(store.dispose);
      await mount(tester, store);
      await tester.ensureVisible(
        find.byKey(
          const Key('task-handoff-handoff-advance-todo-manual-handoff'),
        ),
      );
      await tester.tap(
        find.byKey(
          const Key('task-handoff-handoff-advance-todo-manual-handoff'),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.find('handoff').status, 'doing');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('task-handoff-confirm')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('task-handoff-receiver-group')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PD').last);
      await tester.pumpAndSettle();
      expect(store.find('handoff').status, 'doing');
      await tester.tap(find.byKey(const Key('task-handoff-confirm')));
      await tester.pumpAndSettle();
      final delivered = store.find('handoff');
      expect(delivered.status, 'todo');
      expect(delivered.workflowTarget, 'part:role-pd');
      expect(delivered.workflowPerson, '');
      expect(delivered.workflowPurpose, 'work');
      expect(delivered.workflowSender, _planner.id);
      expect(store.isAssignedToMe(delivered), isFalse);
      expect(store.canEditContent(delivered), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
