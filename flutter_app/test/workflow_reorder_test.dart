import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_panel.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mouse drag saves status catalogue order independently of fixed board columns',
    (tester) async {
      const config = GitHubConfig(repository: 'team/data', enabled: true);
      final api = FakeGitHubApi();
      final session = GitHubSession(
        api: api,
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      await session.signIn();
      final project = await session.createProject(config, '테스트', '개설자');
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
        session.signOut();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsShell(
              selected: SettingsSection.workflow,
              personal: false,
              onSelected: (_) {},
              contentBuilder: (_) =>
                  WorkflowPanel(store: store, sync: sync, session: session),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final grip = find.byKey(const Key('workflow-stage-drag-todo'));
      expect(grip, findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getTopLeft(grip) + const Offset(4, 4),
        kind: PointerDeviceKind.mouse,
      );
      final down =
          tester
              .getCenter(find.byKey(const Key('workflow-stage-row-doing')))
              .dy -
          tester.getCenter(grip).dy;
      await gesture.moveBy(Offset(0, down));
      await tester.pump(const Duration(milliseconds: 250));
      // The rows move before release, but the project is saved only on release.
      expect(
        tester.getTopLeft(find.byKey(const Key('workflow-stage-row-doing'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('workflow-stage-row-todo')))
              .dy,
        ),
      );
      expect(store.workflowStatuses.keys, ['todo', 'doing', 'done']);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(store.project!.workflowStages.map((stage) => stage.id), [
        'doing',
        'todo',
        'done',
      ]);
      expect(store.workflowStatuses.keys, ['doing', 'todo', 'done']);
      expect(
        (await session.loadProject(config)).workflowStages
            .map((stage) => stage.id),
        ['doing', 'todo', 'done'],
      );

      final returnGrip = find.byKey(const Key('workflow-stage-drag-todo'));
      final returnGesture = await tester.startGesture(
        tester.getCenter(returnGrip),
        kind: PointerDeviceKind.mouse,
      );
      final up =
          tester
              .getCenter(find.byKey(const Key('workflow-stage-row-doing')))
              .dy -
          tester.getCenter(returnGrip).dy;
      await returnGesture.moveBy(Offset(0, up));
      await tester.pump(const Duration(milliseconds: 250));
      await returnGesture.up();
      await tester.pumpAndSettle();

      expect(store.workflowStatuses.keys, ['todo', 'doing', 'done']);
      expect(
        (await session.loadProject(config)).workflowStages
            .map((stage) => stage.id),
        ['todo', 'doing', 'done'],
      );

      // Completion is movable too. A cancelled drag must never be saved.
      Future<TestGesture> dragDoneToTop() async {
        final handle = find.byKey(const Key('workflow-stage-drag-done'));
        final pointer = await tester.startGesture(
          tester.getTopLeft(handle) + const Offset(2, 2),
          kind: PointerDeviceKind.mouse,
        );
        await pointer.moveTo(
          Offset(
            tester.getCenter(handle).dx,
            tester
                .getCenter(find.byKey(const Key('workflow-stage-row-todo')))
                .dy,
          ),
        );
        await tester.pump();
        return pointer;
      }

      final writesBeforeCancel = api.writes;
      await (await dragDoneToTop()).cancel();
      await tester.pumpAndSettle();
      expect(api.writes, writesBeforeCancel);
      expect(store.workflowStatuses.keys, ['todo', 'doing', 'done']);

      api.failWrite = true;
      await (await dragDoneToTop()).up();
      await tester.pumpAndSettle();
      expect(store.workflowStatuses.keys, ['todo', 'doing', 'done']);
      expect(find.textContaining('offline'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('workflow-stage-row-todo'))).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('workflow-stage-row-done')))
              .dy,
        ),
      );

      api.failWrite = false;
      // A stale local order must not permanently block another valid permutation.
      await session.saveWorkflowStages(config, [
        project.workflowStages[1],
        project.workflowStages[0],
        ...project.workflowStages.skip(2),
      ], expectedProjectId: project.id);
      await (await dragDoneToTop()).up();
      await tester.pumpAndSettle();
      expect(store.workflowStatuses.keys, ['done', 'todo', 'doing']);
      expect(
        (await session.loadProject(config)).workflowStages.map((s) => s.id),
        ['done', 'todo', 'doing'],
      );
      final savedStages = store.project!.workflowStages;
      await session.saveWorkflowStages(config, [
        ...savedStages,
        const WorkflowStage('stage-new', '추가된 단계'),
      ], expectedProjectId: project.id);
      await expectLater(
        session.saveWorkflowStages(
          config,
          savedStages.reversed.toList(),
          expectedProjectId: project.id,
          expectedStages: savedStages,
          reorderOnly: true,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(
        (await session.loadProject(config)).workflowStages.last.id,
        'stage-new',
      );
    },
  );
}
