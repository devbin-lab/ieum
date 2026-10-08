import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'v020_store_test.dart' show project, owner, worker, reviewer, draft;

const archivedRules = WorkflowAutomation(
  reviewEnabled: true,
  connections: [
    WorkflowConnection('todo', 'doing', actorParts: ['QA'], assignedOnly: true),
    WorkflowConnection(
      'review',
      'todo',
      action: 'reject',
      actor: 'reviewer',
      assignedOnly: true,
      returnAssigneeId: 'gh-3',
    ),
  ],
  disabledConnections: ['doing/advance', 'review/approve'],
);

ProjectManifest configured() => ProjectManifest.fromJson({
  ...project.json,
  'workflowAutomation': archivedRules.json,
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

  test('archived rules are ignored while the new default sheet controls legal stage actions', () {
    final store = TaskStore(':memory:', project: configured(), identity: owner);
    addTearDown(store.dispose);
    final task = store.save(draft());
    store.setMeta('profile', worker.id);
    expect(store.project!.activeWorkflowConnections, isEmpty);
    expect(store.canMove(task, 'review'), isFalse);
    expect(store.canMove(task, 'doing'), isTrue);
    store.transition(task.id, 'doing', expectedVersion: task.version);
    store.transition(
      task.id,
      'review',
      expectedVersion: store.find(task.id).version,
    );
    final review = store.find(task.id);
    expect(store.canEditContent(review), isTrue);
    expect(store.canMove(review, 'todo'), isTrue);
    final plan = store.planHandoff(
      review,
      review.status,
      routeId: 'manual-return',
    );
    expect(plan.isRejection, isTrue);
    expect(plan.maintainsStatus, isTrue);
    expect(plan.editWarning, contains('모든 활성 참여자'));
    expect(() => store.confirmHandoff(plan), throwsStateError);
    store.confirmHandoff(plan, reason: '보완해 주세요.');
    final returned = store.find(task.id);
    expect(returned.status, review.status);
    expect(returned.assigneeId, task.assigneeId);
    expect(returned.reworkReason, '보완해 주세요.');
    expect(
      store.records('notification_outbox').any((n) => n['taskId'] == task.id),
      isTrue,
    );
    store.transition(task.id, 'doing', expectedVersion: returned.version);
    store.transition(
      task.id,
      'review',
      expectedVersion: store.find(task.id).version,
    );
    store.transition(
      task.id,
      'done',
      expectedVersion: store.find(task.id).version,
    );
    final done = store.find(task.id);
    expect(store.canEditContent(done), isFalse);
    expect(store.canMove(done, 'doing'), isFalse);
  });

  test(
    'archive-only changes do not invalidate a manual move; stage changes do',
    () {
      final store = TaskStore(
        ':memory:',
        project: configured(),
        identity: owner,
      );
      addTearDown(store.dispose);
      final task = store.save(draft());
      final plan = store.planHandoff(task, 'doing');
      store.updateProject(
        ProjectManifest.fromJson({
          ...store.project!.json,
          'workflowAutomation': const WorkflowAutomation().json,
        }),
      );
      expect(store.isHandoffCurrent(plan), isTrue);
      expect(store.find(task.id).same(task), isTrue);
      store.updateProject(
        ProjectManifest.fromJson({
          ...store.project!.json,
          'workflowStages': store.project!.workflowStages
              .where((s) => s.id != 'doing')
              .map((s) => s.json)
              .toList(),
        }),
      );
      expect(store.isHandoffCurrent(plan), isFalse);
      expect(() => store.confirmHandoff(plan), throwsStateError);
      expect(store.find(task.id).same(task), isTrue);
    },
  );

  test('manual admission ignores raw archived rules but preserves assignment permissions', () {
    final store = TaskStore(':memory:', project: configured(), identity: owner);
    addTearDown(store.dispose);
    final task = store.save(draft());
    final submitted = task.copy({'status': 'review', 'version': 2});
    final returned = submitted.copy({'status': 'todo', 'version': 3});
    validateTaskMutation(
      actor: worker,
      current: submitted,
      next: returned,
      customStages: ['todo', 'doing', 'review', 'done'],
      workflowConnections: archivedRules.resolve(defaultWorkflowStages),
      manualWorkflow: true,
    );
    expect(
      () => validateTaskMutation(
        actor: worker,
        current: submitted,
        next: returned.copy({'assigneeId': reviewer.id}),
        customStages: ['todo', 'doing', 'review', 'done'],
        workflowConnections: archivedRules.resolve(defaultWorkflowStages),
        manualWorkflow: true,
      ),
      throwsStateError,
    );
    const viewer = Person('gh-8', '열람자', '열', 'viewer', 0);
    expect(
      () => validateTaskMutation(
        actor: viewer,
        current: submitted,
        next: returned,
        customStages: ['todo', 'doing', 'review', 'done'],
        manualWorkflow: true,
      ),
      throwsStateError,
    );
  });

  test(
    'archived review flags and deleted role references cannot rebuild stages',
    () {
      final parsed = ProjectManifest.fromJson({
        ...configured().json,
        'workflowStages': [const WorkflowStage('todo', '확인중').json],
        'workflowAutomation': const WorkflowAutomation(
          reviewEnabled: true,
          connections: [
            WorkflowConnection(
              'review',
              'todo',
              action: 'reject',
              actor: 'reviewer',
              roles: ['role-deleted'],
              returnAssigneeId: 'gh-99',
            ),
          ],
        ).json,
      });
      expect(parsed.workflowStages.map((s) => s.id), ['todo']);
      expect(parsed.activeWorkflowConnections, isEmpty);
      final store = TaskStore(':memory:', project: parsed, identity: owner);
      addTearDown(store.dispose);
      final task = store.save(draft());
      expect(store.canEditContent(task), isTrue);
    },
  );

  test('retired sheet APIs refuse all network activity', () async {
    final api = FakeGitHubApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    await expectLater(
      session.saveWorkflowAutomation(
        config,
        archivedRules,
        expectedProjectId: project.id,
        expectedAutomation: archivedRules,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.applyDefaultWorkflow(
        config,
        expectedProjectId: project.id,
        expectedStages: defaultWorkflowStages,
        expectedAutomation: archivedRules,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.calls, isEmpty);
    expect(api.writes, 0);
  });

  test('stage and part changes ignore archived role dependencies and prune active routes', () async {
    final api = FakeGitHubApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    addTearDown(session.signOut);
    await session.signIn();
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    final created = await session.createProject(config, '테스트', '개설자');
    final saved = {
      ...created.json,
      'roles': [const ProjectRole('role-old', '이전 파트', {}).json],
      'parts': ['이전 파트'],
      'workflowAutomation': const WorkflowAutomation(
        reviewEnabled: true,
        connections: [
          WorkflowConnection(
            'review',
            'todo',
            action: 'reject',
            actor: 'reviewer',
            roles: ['role-old'],
          ),
        ],
      ).json,
    };
    api.files['main']!['.ieum/project.json']!['content'] = base64Encode(
      utf8.encode(jsonEncode(saved)),
    );
    final staged = await session.saveWorkflowStages(config, [
      const WorkflowStage('todo', '확인중'),
      const WorkflowStage('done', '완료'),
    ], expectedProjectId: created.id);
    expect(staged.workflowStages.map((s) => s.id), ['todo', 'done']);
    final deleted = await session.deletePermissionPart(
      config,
      'role-old',
      expectedProjectId: created.id,
    );
    expect(deleted.roles, isEmpty);
    expect(deleted.activeWorkflowConnections, isEmpty);
  });

  testWidgets(
    'settings routes the right-hand workspace into the supplied current sheet editor',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsShell(
              selected: SettingsSection.workflow,
              onSelected: (_) {},
              contentOnly: true,
              contentBuilder: (_) => const Text('작업 단계 목록'),
              workflowAutomationBuilder: () => const Text('현재 자동화 시트'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('작업 단계 목록'), findsOneWidget);
      expect(find.text('현재 자동화 시트'), findsOneWidget);
      expect(
        find.byKey(const Key('workflow-automation-space')),
        findsOneWidget,
      );
      expect(find.text('기본 흐름'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'project cards and detail expose executable approval and rejection actions',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TaskStore(
        ':memory:',
        project: configured(),
        identity: owner,
      );
      addTearDown(store.dispose);
      final task = store.save(draft(title: '기존 작업 유지'));
      store.transition(task.id, 'doing', expectedVersion: task.version);
      store.transition(
        task.id,
        'review',
        expectedVersion: store.find(task.id).version,
      );
      store.setMeta(
        'ui.workspace',
        jsonEncode({'page': 6, 'view': 'kanban', 'projectTabsVersion': 1}),
      );
      await tester.pumpWidget(IeumApp(store: store));
      await tester.pumpAndSettle();
      expect(find.text('최종 완료'), findsWidgets);
      expect(
        find.byKey(Key('task-handoff-${task.id}-approve-done-manual-finish')),
        findsOneWidget,
      );
      await tester.tap(find.text('기존 작업 유지'));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('task-manual-stage-${task.id}')), findsNothing);
      expect(
        find.byKey(
          Key('task-handoff-detail-${task.id}-reject-review-manual-return'),
        ),
        findsOneWidget,
      );
      expect(store.find(task.id).status, 'review');
      expect(tester.takeException(), isNull);
    },
  );
}
