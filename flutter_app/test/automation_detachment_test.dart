import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'legacy_project_fixture.dart';
import 'v020_store_test.dart' show project, owner, worker, draft;

const archivedRules = WorkflowAutomation(
  reviewEnabled: true,
  connections: [
    WorkflowConnection('todo', 'doing', actorParts: ['QA'], assignedOnly: true),
    WorkflowConnection(
      'review',
      'todo',
      action: 'reject',
      actor: 'reviewer',
      roles: ['role-deleted'],
      returnAssigneeId: 'gh-99',
    ),
  ],
  disabledConnections: ['doing/advance', 'review/approve'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'historical rules remain readable without restricting active task edits',
    () {
      final parsed = ProjectManifest.fromJson({
        ...project.json,
        'workflowAutomation': archivedRules.json,
      });
      expect(parsed.workflowAutomation.json, archivedRules.json);
      expect(parsed.activeWorkflowConnections, isEmpty);
      final store = TaskStore(':memory:', project: parsed, identity: owner);
      addTearDown(store.dispose);
      final task = store.save(draft());
      store.setMeta('profile', worker.id);
      expect(store.project!.workflowSheet!.routes, isEmpty);
      expect(store.canEditContent(task), isTrue);
      expect(store.canEditContent(task.copy({'status': 'review'})), isTrue);
      expect(store.canEditContent(task.copy({'status': 'done'})), isFalse);
    },
  );

  test('archived references do not resurrect deleted operational stages', () {
    final parsed = ProjectManifest.fromJson({
      ...project.json,
      'workflowStages': [const WorkflowStage('todo', '확인중').json],
      'workflowAutomation': archivedRules.json,
    });
    expect(parsed.workflowStages.map((stage) => stage.id), ['todo']);
    expect(parsed.activeWorkflowConnections, isEmpty);
    final operational = parsed.partWorkflowView;
    expect(operational.workflowStages.map((stage) => stage.id), [
      'todo',
      'doing',
      'review',
      'done',
      'hold',
      'drop',
    ]);
    expect(operational.workflowSheet!.routes, isEmpty);
  });

  test('part deletion ignores archived role dependencies', () async {
    final api = FakeGitHubApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    addTearDown(session.signOut);
    await session.signIn();
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    final created = await session.createProject(config, '테스트', '개설자');
    await writeLegacyProjectFixture(
      session,
      config,
      overrides: {
        'roles': [const ProjectRole('role-deleted', '이전 파트', {}).json],
        'parts': ['이전 파트'],
        'workflowAutomation': archivedRules.json,
      },
    );
    final deleted = await session.deletePermissionPart(
      config,
      'role-deleted',
      expectedProjectId: created.id,
    );
    expect(deleted.roles, isEmpty);
    expect(deleted.activeWorkflowConnections, isEmpty);
  });
}
