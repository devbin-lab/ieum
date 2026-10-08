import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_definition_editor.dart';
import 'package:ieum_flutter/workflow_sheet_handoff.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

const legacyWorkflowStages = [
  WorkflowStage('todo', '확인중'),
  WorkflowStage('doing', '진행중'),
  WorkflowStage('review', '검토'),
  WorkflowStage('done', '완료'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = GitHubConfig(repository: 'team/data', enabled: true);
  late FakeGitHubApi api;
  late GitHubSession session;
  late TaskStore store;
  late GitHubSync sync;

  setUp(() async {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
    var project = await session.createProject(config, '연속 검토', '관리자');
    project = await session.saveWorkflowDefinition(
      config,
      legacyWorkflowStages,
      WorkflowSheet.defaultFor(
        legacyWorkflowStages.map((stage) => stage.id).toList(),
      ),
      expectedProjectId: project.id,
      expectedStages: project.workflowStages,
      expectedSheet: project.workflowSheet,
    );
    for (final part in const [
      ProjectRole('role-plan', '기획', {}),
      ProjectRole('role-qa', 'QA', {}),
      ProjectRole('role-pd', 'PD', {}),
    ]) {
      project = await session.savePermissionPart(config, part);
    }
    store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    sync = GitHubSync(store, publisher: GitHubPublisher(api));
  });
  tearDown(() {
    sync.dispose();
    store.dispose();
    session.signOut();
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkflowDefinitionEditor(
            store: store,
            sync: sync,
            session: session,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, Finder field, String label) async {
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<String> addReview(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.byKey(const Key('workflow-stage-add')));
    await tester.tap(find.byKey(const Key('workflow-stage-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('workflow-stage-name')), name);
    expect(find.byKey(const Key('workflow-stage-edit-policy')), findsNothing);
    expect(
      find.byKey(const Key('workflow-stage-collaboration')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('workflow-stage-initial')),
          )
          .onChanged,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('workflow-stage-confirm-add')));
    await tester.pumpAndSettle();
    final draft =
        jsonDecode(store.meta('workflow.draft.${store.project!.id}')) as Map;
    return (draft['stages'] as List).cast<Map>().singleWhere(
          (stage) => stage['name'] == name,
        )['id']
        as String;
  }

  testWidgets(
    'QA and PD states remain a persisted local draft until one atomic publish',
    (tester) async {
      await open(tester);
      final writes = api.writes;
      final qa = await addReview(tester, 'QA 검토');
      final pd = await addReview(tester, 'PD 승인');
      expect(qa, isNot(pd));
      expect(store.project!.workflowStages.length, 4);
      expect((await session.loadProject(config)).workflowStages.length, 4);
      expect(api.writes, writes);
      final draft =
          jsonDecode(store.meta('workflow.draft.${store.project!.id}')) as Map;
      final graph = WorkflowSheet.fromJson(
        Map<String, dynamic>.from(draft['sheet']),
      );
      expect(graph.nodes.map((n) => n.stageId), containsAll([qa, pd]));
      expect(find.text('초안 · 이 컴퓨터에 자동 저장됨'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await open(tester);
      expect(find.byKey(Key('workflow-stage-row-$qa')), findsOneWidget);
      expect(find.byKey(Key('workflow-stage-row-$pd')), findsOneWidget);
      expect(api.writes, writes);
      await tester.tap(find.byKey(const Key('workflow-sheet-save')));
      await tester.pumpAndSettle();
      expect(api.writes, writes + 1);
      final saved = await session.loadProject(config);
      expect(
        saved.workflowStages
            .singleWhere((stage) => stage.id == qa)
            .locksContent,
        isFalse,
      );
      expect(
        saved.workflowStages
            .singleWhere((stage) => stage.id == pd)
            .resolvedCategory,
        'inProgress',
      );
      expect(
        saved.workflowSheet!.nodes.map((n) => n.stageId),
        containsAll([qa, pd]),
      );
      expect(store.project!.workflowStages.length, 6);
      expect(store.meta('workflow.draft.${saved.id}'), isEmpty);
      expect(find.text('현재 적용 중'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'state properties set a single editable initial state without publishing early',
    (tester) async {
      await open(tester);
      final writes = api.writes;
      await tester.tap(find.byKey(const Key('workflow-stage-edit-doing')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('workflow-stage-name')),
        '기획 작업',
      );
      await tester.tap(find.byKey(const Key('workflow-stage-initial')));
      await tester.tap(find.byKey(const Key('workflow-stage-confirm-edit')));
      await tester.pumpAndSettle();
      final draft =
          jsonDecode(store.meta('workflow.draft.${store.project!.id}')) as Map;
      expect(
        (draft['stages'] as List)
            .cast<Map>()
            .where((stage) => stage['initial'] == true)
            .single['id'],
        'doing',
      );
      expect(store.project!.initialStatusId, 'todo');
      expect(api.writes, writes);
      await tester.tap(find.byKey(const Key('workflow-sheet-save')));
      await tester.pumpAndSettle();
      expect(store.project!.initialStatusId, 'doing');
      expect(store.project!.stage('doing')!.name, '기획 작업');
      expect(api.writes, writes + 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote changes block stale publication while keeping the local draft',
    (tester) async {
      await open(tester);
      await addReview(tester, 'QA 검토');
      final local = store.meta('workflow.draft.${store.project!.id}');
      final base = store.project!;
      final remote = await session.saveWorkflowStages(
        config,
        [
          for (final stage in base.workflowStages)
            if (stage.id == 'doing')
              const WorkflowStage('doing', '다른 관리자의 진행 상태')
            else
              stage,
        ],
        expectedProjectId: base.id,
        expectedStages: base.workflowStages,
      );
      store.updateProject(remote);
      await tester.pumpAndSettle();
      expect(find.text('원격 변경 있음'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('workflow-sheet-save')))
            .onPressed,
        isNull,
      );
      expect(store.meta('workflow.draft.${base.id}'), local);
      expect(find.text('QA 검토'), findsWidgets);
      await tester.tap(find.byKey(const Key('workflow-sheet-reload')));
      await tester.pumpAndSettle();
      expect(find.text('원격 변경 있음'), findsNothing);
      expect(find.text('QA 검토'), findsNothing);
      expect(store.meta('workflow.draft.${base.id}'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'used states cannot disappear and unused state deletion prunes graph draft only',
    (tester) async {
      store.save({
        for (final field in fields) field: '',
        'title': '진행 전 작업',
        'assigneeId': store.actor.id,
        'part': '기획',
        'priority': 'normal',
        'reviewerId': store.actor.id,
        'assignedDate': '2026-10-08',
      });
      await open(tester);
      final writes = api.writes;
      await tester.tap(find.byKey(const Key('workflow-stage-delete-todo')));
      await tester.pumpAndSettle();
      expect(find.textContaining('현재 1개 작업이 이 상태에 있습니다.'), findsOneWidget);
      expect(
        find.byKey(const Key('workflow-stage-confirm-delete-todo')),
        findsNothing,
      );
      final qa = await addReview(tester, 'QA 검토');
      await tester.tap(find.byKey(Key('workflow-stage-delete-$qa')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('workflow-stage-confirm-delete-$qa')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('workflow-stage-row-$qa')), findsNothing);
      expect(store.project!.stage('todo'), isNotNull);
      expect(api.writes, writes);
      expect(store.meta('workflow.draft.${store.project!.id}'), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'arbitrary QA state can explicitly approve or reject without losing rule metadata',
    (tester) async {
      List<SheetHandoffRule>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await editSheetHandoff(
                    context,
                    from: 'QA 검토',
                    to: 'PD 승인',
                    fromStage: 'stage-qa',
                    toStage: 'stage-pd',
                    routes: const [
                      SheetHandoffRule(
                        id: 'qa-pd',
                        source: 'part:role-qa',
                        destination: 'part:role-pd',
                        name: 'PD에게 전달',
                        operation: 'qa-decision',
                        labelDx: 72,
                        labelDy: 31,
                      ),
                    ],
                    roles: store.project!.roles,
                    people: store.project!.people,
                    parts: store.project!.parts,
                  );
                },
                child: const Text('전환 편집'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('전환 편집'));
      await tester.pumpAndSettle();
      await choose(
        tester,
        find.byKey(const ValueKey('workflow-route-action-0')),
        '승인',
      );
      await tester.ensureVisible(
        find.byKey(const Key('workflow-route-required-comment')),
      );
      await tester.tap(
        find.byKey(const Key('workflow-route-required-comment')),
      );
      await tester.ensureVisible(
        find.byKey(const Key('workflow-route-required-description')),
      );
      await tester.tap(
        find.byKey(const Key('workflow-route-required-description')),
      );
      await tester.ensureVisible(
        find.byKey(const Key('workflow-route-required-dueDate')),
      );
      await tester.tap(
        find.byKey(const Key('workflow-route-required-dueDate')),
      );
      await choose(
        tester,
        find.byKey(const ValueKey('workflow-route-assignment-0')),
        '현재 처리 담당자 유지',
      );
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(saved!.single.action, 'approve');
      expect(saved!.single.assignment, 'keep');
      expect(saved!.single.commentRequired, isTrue);
      expect(
        saved!.single.requiredFields,
        containsAll(['description', 'dueDate']),
      );
      expect(saved!.single.id, 'qa-pd');
      expect(saved!.single.operation, 'qa-decision');
      expect(saved!.single.name, 'PD에게 전달');
      expect(saved!.single.labelDx, 72);
      expect(saved!.single.labelDy, 31);
      expect(
        sheetHandoffLabel(
          saved!.single,
          store.project!.roles,
          store.people,
          store.project!.parts,
        ),
        contains('현재 처리 담당자 유지'),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
