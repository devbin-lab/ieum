import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_sheet_settings.dart';
import 'package:ieum_flutter/workflow_panel.dart';

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
  late ProjectManifest project;
  setUp(() async {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
    project = await session.createProject(config, '설정 통합', '개설자');
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
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    project = ProjectManifest.fromJson({
      ...project.json,
      'members': [
        ...project.people.map((p) => p.json),
        const Person(
          'gh-2',
          '반려 담당',
          '반',
          'unassigned',
          0,
          login: 'worker',
          parts: ['기획'],
        ).json,
      ],
    }).partWorkflowView;
    await session.writeJson(
      config,
      '.ieum/project.json',
      project.json,
      sha: (await session.readJson(config, '.ieum/project.json'))!['sha'],
      message: 'Test members',
    );
  });
  tearDown(() => session.signOut());

  WorkflowSheet designatedReturn() {
    final base = project.workflowSheet!;
    return WorkflowSheet(
      nodes: base.nodes,
      routes: [
        for (final r in base.routes)
          WorkflowSheetRoute(
            id: r.id,
            from: r.from,
            to: r.to,
            action: r.action,
            source: r.source,
            destination: r.action == 'reject'
                ? 'part:role-plan'
                : r.destination,
            person: r.action == 'reject' ? 'gh-2' : r.person,
          ),
      ],
    );
  }

  test('deleting a review stage prunes saved cards and links without archived resurrection', () async {
    project = await session.saveWorkflowSheet(
      config,
      designatedReturn(),
      expectedProjectId: project.id,
      expectedSheet: project.workflowSheet,
    );
    expect(project.workflowSheet!.outgoing('review').map((r) => r.action), [
      'approve',
      'reject',
    ]);
    final removed = await session.saveWorkflowStages(
      config,
      project.workflowStages.where((s) => s.id != 'review').toList(),
      expectedProjectId: project.id,
      expectedStages: project.workflowStages,
    );
    expect(removed.workflowStages.map((s) => s.id), ['todo', 'doing', 'done']);
    expect(
      removed.workflowSheet!.nodes.any((n) => n.stageId == 'review'),
      isFalse,
    );
    expect(
      removed.workflowSheet!.routes.any(
        (r) =>
            removed.workflowSheet!.stageFor(r.from) == 'review' ||
            removed.workflowSheet!.stageFor(r.to) == 'review',
      ),
      isFalse,
    );
    final loaded = await session.loadProject(config);
    expect(loaded.workflowStages.any((s) => s.id == 'review'), isFalse);
    expect(loaded.workflowSheet!.json, removed.workflowSheet!.json);
  });

  test('a configured recipient must be retargeted before losing their required part', () async {
    project = await session.saveWorkflowSheet(
      config,
      designatedReturn(),
      expectedProjectId: project.id,
      expectedSheet: project.workflowSheet,
    );
    final member = project.people.firstWhere((p) => p.id == 'gh-2');
    final blockers = await GitHubPublisher(api).memberBlockers(
      config,
      project,
      member.id,
      remainingParts: const [],
      removingMember: false,
    );
    expect(blockers.any((b) => b.contains('자동화 전달 담당자')), isTrue);
    final writes = api.writes;
    await expectLater(
      session.assign(
        config,
        Person.fromJson({...member.json, 'parts': <String>[]}),
        expectedProjectId: project.id,
        expectedMember: member,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    expect(
      (await session.loadProject(config)).people
          .firstWhere((p) => p.id == member.id)
          .parts,
      ['기획'],
    );

    final base = project.workflowSheet!;
    project = await session.saveWorkflowSheet(
      config,
      WorkflowSheet(
        nodes: base.nodes,
        routes: [
          for (final r in base.routes)
            WorkflowSheetRoute(
              id: r.id,
              from: r.from,
              to: r.to,
              action: r.action,
              source: r.source,
              destination: r.action == 'reject' ? '' : r.destination,
              person: r.action == 'reject' ? '' : r.person,
            ),
        ],
      ),
      expectedProjectId: project.id,
      expectedSheet: base,
    );
    final updated = await session.assign(
      config,
      Person.fromJson({...member.json, 'parts': <String>[]}),
      expectedProjectId: project.id,
      expectedMember: member,
    );
    expect(updated.people.firstWhere((p) => p.id == member.id).parts, isEmpty);
    expect(
      updated.workflowSheet!
          .outgoing('review')
          .firstWhere((r) => r.action == 'reject')
          .person,
      isEmpty,
    );
  });

  testWidgets(
    'route editor saves the return recipient shared by stage and sheet views',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      addTearDown(() {
        sync.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: WorkflowPanel(
                    store: store,
                    sync: sync,
                    session: session,
                  ),
                ),
                Expanded(
                  child: WorkflowSheetSettings(
                    store: store,
                    sync: sync,
                    session: session,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-stage-row-review')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workflow-sheet-review-card')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('workflow-sheet-route-review-todo-0')),
      );
      await tester.pumpAndSettle();
      Future<void> choose(int index, String label) async {
        final prefix = [
          'workflow-route-source-',
          'workflow-route-destination-',
          'workflow-route-person-',
        ][index];
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButtonFormField<String> &&
              widget.key.toString().contains(prefix),
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await choose(1, '파트 · 기획');
      await choose(2, '반려 담당');
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      final writes = api.writes;
      expect(
        store.project!.workflowSheet!
            .outgoing('review')
            .firstWhere((r) => r.action == 'reject')
            .person,
        isEmpty,
      );
      await tester.tap(find.byKey(const Key('workflow-sheet-save')));
      await tester.pumpAndSettle();
      final saved = await session.loadProject(config);
      final rejection = saved.workflowSheet!
          .outgoing('review')
          .firstWhere((r) => r.action == 'reject');
      expect(saved.workflowSheet!.stageFor(rejection.to), 'todo');
      expect(rejection.destination, 'part:role-plan');
      expect(rejection.person, 'gh-2');
      expect(api.writes, writes + 1);
      expect(store.project!.workflowSheet!.json, saved.workflowSheet!.json);
      expect(
        find.byKey(const Key('workflow-stage-row-review')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workflow-sheet-review-card')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('workflow-sheet-rework-card')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
