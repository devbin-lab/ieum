import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'legacy_project_fixture.dart';

const config = GitHubConfig(repository: 'team/data', enabled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AutoMergeApi api;
  late GitHubSession session;
  late GitHubPublisher publisher;
  late ProjectManifest project;

  Future<void> login(int id) async {
    api.identityId = id;
    api.identityLogin = id == 1 ? 'tester' : 'member$id';
    await session.signIn(token: 'test-only');
  }

  setUp(() async {
    api = AutoMergeApi();
    session = GitHubSession(api: api);
    publisher = GitHubPublisher(api);
    await login(1);
    project = await session.createProject(config, '변경 순서 검증', '관리자');
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    project = await writeLegacyProjectFixture(
      session,
      config,
      overrides: {
        'members': [
          ...project.people.map((person) => person.json),
          for (final id in [2, 3])
            Person(
              'gh-$id',
              '사용자 $id',
              '$id',
              'unassigned',
              0,
              login: 'member$id',
              parts: const ['기획'],
            ).json,
        ],
        // Archived custom stages and rules are still accepted as saved data.
        'workflowStages': [
          ...defaultWorkflowStages.map((stage) => stage.json),
          const WorkflowStage(
            'stage-qa',
            '이전 QA',
            category: 'inProgress',
            editPolicy: 'locked',
          ).json,
        ],
        'workflowSheet': const WorkflowSheet(
          nodes: [
            WorkflowSheetNode('todo', 'todo'),
            WorkflowSheetNode('doing', 'doing'),
            WorkflowSheetNode('qa', 'stage-qa'),
          ],
          routes: [
            WorkflowSheetRoute(
              id: 'archived-submit',
              from: 'doing',
              to: 'qa',
              requiredFields: ['description'],
            ),
          ],
        ).json,
      },
    );
  });
  tearDown(() => session.signOut());

  List<WorkTask> proof() {
    final created = WorkTask.fromJson({
      'id': 'task-revision-proof',
      'title': '오프라인 작업 변경',
      'part': '기획',
      'assigneeId': 'gh-2',
      'reviewerId': 'gh-1',
      'status': 'todo',
      'priority': 'normal',
      'assignedDate': '2026-10-01',
      'dueDate': '',
      'completedDate': '',
      'description': '',
      'reworkReason': '',
      'workflowTarget': '',
      'workflowPerson': 'gh-2',
      'creatorId': 'gh-2',
      'initialAssigneeId': 'gh-2',
      'createdAt': '2026-10-01T00:00:00Z',
      'version': 1,
      'updatedAt': '2026-10-01T00:00:00Z',
    });
    final filled = created.copy({'description': '작업 설명', 'version': 2});
    final started = applyDirectWorkflowRoute(
      filled,
      directWorkflowRoute(filled, project, 'manual-start')!,
      project,
      actorId: 'gh-2',
    ).copy({'version': 3});
    return [
      created,
      filled,
      started,
      started.copy({'description': '', 'version': 4}),
    ];
  }

  Map<String, dynamic> proposal(List<WorkTask> steps, {int author = 2}) => {
    'schemaVersion': 1,
    'projectId': project.id,
    'authorId': 'gh-$author',
    'githubLogin': 'member$author',
    'changes': [
      {
        'taskId': steps.last.id,
        'task': steps.last.data,
        'steps': steps.map((step) => step.data).toList(),
      },
    ],
  };

  Map<String, dynamic> job(List<WorkTask> steps, {int author = 2}) => {
    'taskId': steps.last.id,
    'title': steps.last.title,
    'proposal': proposal(steps, author: author),
  };

  test('upload and integration preserve validated offline revisions', () async {
    final steps = proof();
    await login(2);
    final receipt = await publisher.publish(config, job(steps));
    await publisher.integrateTask(
      config,
      receipt.prUrl,
      projectId: project.id,
      founderId: project.founderId,
    );
    expect(api.prs.single['merged'], isTrue);
    final snapshot = (await publisher.pull(config, ''))!;
    final change =
        (snapshot['proposals'] as List).single['changes'].single as Map;
    expect(
      parseWorkflowRevisions(change['steps'])!.map((step) => step.version),
      [1, 2, 3, 4],
    );
    final stored = WorkTask.fromJson(Map<String, dynamic>.from(change['task']));
    expect(stored.status, 'doing');
    expect(stored.description, isEmpty);
  });

  for (final kind in ['version-gap', 'other-task', 'other-author']) {
    test('upload rejects an invalid intermediate revision: $kind', () async {
      var steps = proof();
      if (kind == 'version-gap') {
        steps = [steps.first, ...steps.skip(2)];
      } else if (kind == 'other-task') {
        steps = [
          steps.first,
          steps[1].copy({'id': 'another-task'}),
          ...steps.skip(2),
        ];
      }
      final author = kind == 'other-author' ? 3 : 2;
      await login(author);
      final writes = api.writes;
      final revision = api.refs['main'];
      await expectLater(
        publisher.publish(config, job(steps, author: author)),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
      expect(api.refs['main'], revision);
      expect(api.prs, isEmpty);
    });
  }

  test('integration rejects a revision proof altered after upload', () async {
    final steps = proof();
    await login(2);
    final receipt = await publisher.publish(config, job(steps));
    final branch = api.prs.single['head']['ref'] as String;
    final path = api.files[branch]!.keys.singleWhere(
      (path) => path.startsWith('.ieum/changes/'),
    );
    await session.writeJson(
      config,
      path,
      proposal([
        steps.first,
        steps[1].copy({'id': 'another-task'}),
        ...steps.skip(2),
      ]),
      sha: api.files[branch]![path]!['sha'],
      branch: branch,
      message: 'Tampered fixture proof',
    );
    final revision = api.refs['main'];
    await expectLater(
      publisher.integrateTask(
        config,
        receipt.prUrl,
        projectId: project.id,
        founderId: project.founderId,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.refs['main'], revision);
    expect(api.prs.single['state'], 'open');
  });
}
