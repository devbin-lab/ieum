import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_sheet_settings.dart';
import 'package:ieum_flutter/workflow_automation_tree.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

const config = GitHubConfig(repository: 'team/data', enabled: true);
const legacyWorkflowStages = [
  WorkflowStage('todo', '확인중'),
  WorkflowStage('doing', '진행중'),
  WorkflowStage('review', '검토'),
  WorkflowStage('done', '완료'),
];

void main() {
  late FakeGitHubApi api;
  late GitHubSession session;
  late ProjectManifest project;
  TaskStore? store;
  GitHubSync? sync;

  setUp(() async {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
    project = await session.createProject(config, '공유 작업', '관리자');
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
  });
  tearDown(() {
    sync?.dispose();
    store?.dispose();
    sync = null;
    store = null;
    session.signOut();
  });

  Future<void> showPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    store!.setMeta('github.config', jsonEncode(config.toJson()));
    sync = GitHubSync(store!, publisher: GitHubPublisher(api));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkflowSheetSettings(
            store: store!,
            sync: sync,
            session: session,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> rightClick(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.down(tester.getCenter(target));
    await mouse.up();
    await tester.pumpAndSettle();
  }

  testWidgets(
    'saved route editor explicitly clears recipient restrictions only after applying the draft',
    (tester) async {
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
                source: r.id == 'default-next-0' ? 'role:owner' : '',
                destination: r.id == 'default-next-0' ? 'role:owner' : '',
                person: r.id == 'default-next-0' ? project.ownerId : '',
              ),
          ],
        ),
        expectedProjectId: project.id,
        expectedSheet: base,
      );
      await showPanel(tester);
      final writes = api.writes;
      await tester.tap(
        find.byKey(const Key('workflow-sheet-route-todo-doing-0')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is DropdownButtonFormField<String> &&
                    widget.key.toString().contains('workflow-route-source-'),
              ),
            )
            .initialValue,
        'role:owner',
      );
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

      await choose(0, '모든 작업자');
      await choose(1, '모든 작업자');
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(api.writes, writes);
      expect(find.text('저장하지 않은 변경사항'), findsOneWidget);
      await tester.tap(find.byKey(const Key('workflow-sheet-save')));
      await tester.pumpAndSettle();
      final saved = (await session.loadProject(config)).workflowSheet!
          .outgoing('todo')
          .single;
      expect(saved.source, isEmpty);
      expect(saved.destination, isEmpty);
      expect(saved.person, isEmpty);
      expect(api.writes, writes + 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'tree copies explicit restrictions and creates unconfigured links for all workers',
    (tester) async {
      WorkflowConnection? connected;
      const stages = [
        ...legacyWorkflowStages,
        WorkflowStage('stage-extra', '추가'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: WorkflowAutomationTree(
                stages: stages,
                connections: const [
                  WorkflowConnection(
                    'todo',
                    'doing',
                    assignedOnly: true,
                    actorParts: ['기획'],
                    taskParts: ['기획'],
                  ),
                ],
                roleName: (id) => id,
                onConnect: (connection) async {
                  connected = connection;
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await rightClick(tester, find.byKey(const Key('automation-node-todo')));
      await tester.tap(find.byKey(const Key('automation-card-connect')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('automation-node-review')));
      await tester.pumpAndSettle();
      expect(connected!.allWorkers, isFalse);
      expect(connected!.assignedOnly, isTrue);
      expect(connected!.actorParts, ['기획']);
      expect(connected!.taskParts, ['기획']);

      await rightClick(
        tester,
        find.byKey(const Key('automation-node-stage-extra')),
      );
      await tester.tap(find.byKey(const Key('automation-card-connect')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('automation-node-doing')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('automation-node-doing')));
      await tester.pumpAndSettle();
      expect(connected!.from, 'stage-extra');
      expect(connected!.allWorkers, isTrue);
      expect(connected!.assignedOnly, isFalse);
      expect(connected!.actorParts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'editing one open route preserves user stages and unrelated saved links',
    (tester) async {
      project = await session.saveWorkflowStages(
        config,
        [
          const WorkflowStage('todo', '접수'),
          const WorkflowStage('stage-extra', '추가 단계'),
          const WorkflowStage('doing', '제작'),
          const WorkflowStage('review', '검토'),
          const WorkflowStage('done', '완료'),
        ],
        expectedProjectId: project.id,
        expectedStages: project.workflowStages,
      );
      final generated = WorkflowSheet.defaultFor(
        project.workflowStages.map((s) => s.id).toList(),
      );
      project = await session.saveWorkflowSheet(
        config,
        WorkflowSheet(
          nodes: generated.nodes,
          routes: [
            for (final r in generated.routes)
              WorkflowSheetRoute(
                id: r.id,
                from: r.from,
                to: r.to,
                action: r.action,
                source: r.id == 'default-next-0' ? 'role:owner' : '',
              ),
          ],
        ),
        expectedProjectId: project.id,
        expectedSheet: project.workflowSheet,
      );
      final untouched = project.workflowSheet!
          .outgoing('stage-extra')
          .single
          .json;
      await showPanel(tester);
      await tester.tap(
        find.byKey(const Key('workflow-sheet-route-todo-stage-extra-0')),
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

      await choose(0, '모든 작업자');
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-sheet-save')));
      await tester.pumpAndSettle();
      final saved = await session.loadProject(config);
      expect(saved.workflowStages.map((s) => s.name), [
        '접수',
        '추가 단계',
        '제작',
        '검토',
        '완료',
      ]);
      expect(saved.workflowSheet!.outgoing('todo').single.source, isEmpty);
      expect(
        saved.workflowSheet!.outgoing('stage-extra').single.json,
        untouched,
      );
      expect(saved.workflowSheet!.outgoing('review').map((r) => r.action), [
        'approve',
        'reject',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
