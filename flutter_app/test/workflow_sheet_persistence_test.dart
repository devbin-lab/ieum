import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';
import 'package:ieum_flutter/workflow_sheet_handoff.dart';
import 'package:ieum_flutter/workflow_sheet_settings.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

const _planning = ProjectRole('role-plan', '기획', {});
const _pd = ProjectRole('role-pd', 'PD', {});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sheet roundtrip keeps card aliases and stable route recipients', () {
    const sheet = WorkflowSheet(
      nodes: [
        WorkflowSheetNode('doing-a', 'doing', x: -180, y: 20),
        WorkflowSheetNode('review-a', 'review', x: 140, y: -50),
        WorkflowSheetNode('review-copy', 'review', x: 140, y: 90),
      ],
      routes: [
        WorkflowSheetRoute(
          id: 'pd-review',
          from: 'doing-a',
          to: 'review-a',
          source: 'part:role-plan',
          destination: 'part:role-pd',
          person: 'gh-2',
        ),
      ],
    );
    final loaded = WorkflowSheet.fromJson(jsonDecode(jsonEncode(sheet.json)));
    expect(loaded.json, sheet.json);
    expect(loaded.stageFor('review-copy'), 'review');
    expect(loaded.outgoing('doing').single.id, 'pd-review');
    const moved = WorkflowSheet(
      nodes: [
        WorkflowSheetNode('new-alias', 'doing', x: 150, y: 320),
        WorkflowSheetNode('review-a', 'review', x: 80, y: 200),
      ],
      routes: [
        WorkflowSheetRoute(
          id: 'pd-review',
          from: 'new-alias',
          to: 'review-a',
          source: 'part:role-plan',
          destination: 'part:role-pd',
          person: 'gh-2',
        ),
      ],
    );
    expect(moved.policyJson, loaded.policyJson);
  });

  test('same-stage aliases roundtrip while invalid endpoints and nonfinite coordinates fail closed', () {
    const sameStage = WorkflowSheet(
      nodes: [WorkflowSheetNode('a', 'doing'), WorkflowSheetNode('b', 'doing')],
      routes: [WorkflowSheetRoute(id: 'self', from: 'a', to: 'b')],
    );
    expect(WorkflowSheet.fromJson(sameStage.json).json, sameStage.json);
    expect(
      () => WorkflowSheet.fromJson({
        ...sameStage.json,
        'routes': [
          const WorkflowSheetRoute(id: 'missing', from: 'a', to: 'none').json,
        ],
      }),
      throwsStateError,
    );
    expect(
      () => WorkflowSheetNode.fromJson({
        'id': 'a',
        'stageId': 'doing',
        'x': double.infinity,
        'y': 0,
      }),
      throwsStateError,
    );
  });

  test('default review approves completion and rejects to initial regardless of list order', () {
    final sheet = WorkflowSheet.defaultFor(['todo', 'review', 'doing', 'done']);
    expect(sheet.outgoing('review').map((r) => r.action), [
      'approve',
      'reject',
    ]);
    expect(sheet.outgoing('review').map((r) => sheet.stageFor(r.to)), [
      'done',
      'todo',
    ]);
    expect(sheet.outgoing('done'), isEmpty);
    expect(sheet.stageFor(sheet.outgoing('doing').single.to), 'review');
    expect(sheet.stageFor(sheet.outgoing('todo').single.to), 'doing');
    expect(WorkflowSheet.fromJson(sheet.json).json, sheet.json);
  });

  Future<void> size(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('controlled canvas persists a completed drag across remounts', (
    tester,
  ) async {
    await size(tester);
    var sheet = WorkflowSheet.defaultFor(['todo', 'doing', 'review', 'done']);
    Widget canvas() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, update) => WorkflowSheetCanvas(
            value: sheet,
            onChanged: (next) => update(() => sheet = next),
          ),
        ),
      ),
    );
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    final todo = find.byKey(const Key('workflow-sheet-todo-card'));
    final before = tester.getCenter(todo);
    final policy = sheet.policyJson;
    await tester.drag(todo, const Offset(68, 44));
    await tester.pumpAndSettle();
    final after = tester.getCenter(todo);
    expect(after.dx, greaterThan(before.dx + 40));
    expect(sheet.policyJson, policy);
    expect(sheet.nodes.first.x, greaterThan(-225));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(canvas());
    await tester.pumpAndSettle();
    expect(tester.getCenter(todo), after);
    expect(
      find.byKey(const Key('workflow-sheet-link-doing-review')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'read-only canvas cannot import, delete or change route conditions',
    (tester) async {
      await size(tester);
      var changes = 0;
      final sheet = WorkflowSheet.defaultFor(['todo', 'doing']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkflowSheetCanvas(
              value: sheet,
              readOnly: true,
              onChanged: (_) => changes++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('workflow-sheet-todo-card')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      expect(find.text('카드 작업'), findsNothing);
      await tester.tapAt(const Offset(50, 150), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('단계 불러오기'), findsNothing);
      await tester.tap(
        find.byKey(const Key('workflow-sheet-route-todo-doing-0')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('workflow-route-save')), findsNothing);
      expect(changes, 0);
    },
  );

  testWidgets(
    'deleted part remains invalid instead of expanding to all workers',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editSheetHandoff(
                  context,
                  from: '진행중',
                  to: '검토',
                  fromStage: 'doing',
                  toStage: 'review',
                  routes: const [
                    SheetHandoffRule(
                      source: 'part:removed',
                      destination: 'part:role-pd',
                    ),
                  ],
                  roles: const [_pd],
                  people: const [],
                  parts: const ['PD'],
                ),
                child: const Text('경로'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('경로'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('workflow-route-save')))
            .onPressed,
        isNull,
      );
      expect(find.text('삭제된 파트 · 다시 선택하세요.'), findsOneWidget);
      expect(sheetHandoffGroups([_pd], ['PD']).keys, contains('part:role-pd'));
      expect(
        sheetHandoffGroups([_pd], ['PD']).keys,
        isNot(contains('part:PD')),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'active part member is eligible without fine-grained permissions',
    (tester) async {
      final worker = Person.fromJson({
        'id': 'gh-2',
        'name': '검토자',
        'login': 'reviewer',
        'role': 'unassigned',
        'parts': ['PD'],
      });
      expect(worker.canWork, isFalse);
      expect(worker.canReview, isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => editSheetHandoff(
                  context,
                  from: '진행중',
                  to: '검토',
                  fromStage: 'doing',
                  toStage: 'review',
                  routes: const [SheetHandoffRule(destination: 'part:role-pd')],
                  roles: const [_planning, _pd],
                  people: [worker],
                  parts: const ['기획', 'PD'],
                ),
                child: const Text('경로'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('경로'));
      await tester.pumpAndSettle();
      final personField = find.byKey(
        const ValueKey('workflow-route-person-0-part:role-pd-'),
      );
      await tester.ensureVisible(personField);
      await tester.tap(personField);
      await tester.pumpAndSettle();
      expect(find.text('검토자'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saved editor reloads graph and non-admin receives read-only view',
    (tester) async {
      await size(tester);
      final api = FakeGitHubApi();
      final session = GitHubSession(
        api: api,
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      await session.signIn();
      const config = GitHubConfig(repository: 'team/data', enabled: true);
      var project = await session.createProject(config, '시트 저장', '관리자');
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      try {
        Widget panel() => MaterialApp(
          home: Scaffold(
            body: WorkflowSheetSettings(
              store: store,
              sync: sync,
              session: session,
            ),
          ),
        );
        await tester.pumpWidget(panel());
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('workflow-sheet-todo-card')),
          const Offset(60, 30),
        );
        await tester.pumpAndSettle();
        expect(find.text('저장하지 않은 변경사항'), findsOneWidget);
        await tester.tap(find.byKey(const Key('workflow-sheet-save')));
        await tester.pumpAndSettle();
        expect(find.text('자동화 시트를 저장하고 작업에 적용했습니다.'), findsOneWidget);
        project = await session.loadProject(config);
        final saved = project.workflowSheet!;
        expect(saved.nodes.first.x, greaterThan(-225));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(panel());
        await tester.pumpAndSettle();
        expect(find.text('저장된 흐름 적용 중'), findsOneWidget);
        expect(store.project!.workflowSheet!.json, saved.json);
        final nonAdmin = Person.fromJson({
          'id': 'gh-2',
          'name': '작업자',
          'login': 'worker',
          'role': 'unassigned',
          'parts': [],
        });
        store.setMeta('profile', nonAdmin.id);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(panel());
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('workflow-sheet-save')), findsNothing);
        expect(
          tester
              .widget<WorkflowSheetCanvas>(find.byType(WorkflowSheetCanvas))
              .readOnly,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
        session.signOut();
      }
    },
  );

  testWidgets('settings uses persisted editor builder with one parts section', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsShell(
            selected: SettingsSection.workflow,
            onSelected: (_) {},
            contentBuilder: (_) => const Text('작업 단계 목록'),
            workflowAutomationBuilder: () => const Text('저장된 시트 편집기'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('저장된 시트 편집기'), findsOneWidget);
    expect(find.byKey(const Key('settings-roles')), findsOneWidget);
    expect(find.byKey(const Key('settings-assignments')), findsNothing);
  });
}
