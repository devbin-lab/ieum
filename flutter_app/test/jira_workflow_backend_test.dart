import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;

const _config = GitHubConfig(repository: 'team/data', enabled: true);
const _stages = [
  WorkflowStage('todo', '등록', category: 'todo', initial: true),
  WorkflowStage('doing', '작업 중', category: 'inProgress'),
  WorkflowStage(
    'stage-qa',
    'QA 검토',
    category: 'inProgress',
    editPolicy: 'locked',
  ),
  WorkflowStage(
    'stage-pd',
    'PD 승인',
    category: 'inProgress',
    editPolicy: 'locked',
  ),
  WorkflowStage('stage-closed', '처리 완료', category: 'done'),
];
const _sheet = WorkflowSheet(
  nodes: [
    WorkflowSheetNode('todo-card', 'todo', x: -300, y: 25),
    WorkflowSheetNode('doing-card', 'doing', x: -100, y: 25),
    WorkflowSheetNode('qa-card', 'stage-qa', x: 100, y: 25),
    WorkflowSheetNode('pd-card', 'stage-pd', x: 300, y: 25),
    WorkflowSheetNode('closed-card', 'stage-closed', x: 500, y: 25),
  ],
  routes: [
    WorkflowSheetRoute(
      id: 'start',
      from: 'todo-card',
      to: 'doing-card',
      name: '작업 시작',
      assignment: 'assignee',
    ),
    WorkflowSheetRoute(
      id: 'qa-submit',
      from: 'doing-card',
      to: 'qa-card',
      name: 'QA 검토 요청',
      source: 'part:role-plan',
      destination: 'part:role-qa',
      operation: 'submit-review',
      requiredFields: ['description'],
      labelDx: 23,
      labelDy: -14,
    ),
    WorkflowSheetRoute(
      id: 'qa-accept',
      from: 'qa-card',
      to: 'pd-card',
      name: 'PD 승인 요청',
      action: 'approve',
      source: 'part:role-qa',
      destination: 'part:role-pd',
      operation: 'accept-review',
    ),
    WorkflowSheetRoute(
      id: 'qa-return',
      from: 'qa-card',
      to: 'doing-card',
      name: '기획에 반려',
      action: 'reject',
      source: 'part:role-qa',
      destination: 'part:role-plan',
    ),
    WorkflowSheetRoute(
      id: 'pd-accept',
      from: 'pd-card',
      to: 'closed-card',
      name: '최종 승인',
      action: 'approve',
      source: 'part:role-pd',
      assignment: 'keep',
    ),
    WorkflowSheetRoute(
      id: 'reopen',
      from: 'closed-card',
      to: 'doing-card',
      name: '작업 재개',
      assignment: 'assignee',
      operation: 'reopen',
      commentRequired: true,
    ),
  ],
);

WorkTask _task({String status = 'doing', String target = 'part:role-plan'}) =>
    WorkTask.fromJson({
      'id': 'task-jira-workflow',
      'title': '검토와 승인 분리',
      'part': '기획',
      'assigneeId': 'gh-2',
      'reviewerId': 'gh-4',
      'status': status,
      'priority': 'normal',
      'assignedDate': '2026-10-01',
      'dueDate': '',
      'completedDate': status == 'stage-closed' ? '2026-10-02' : '',
      'description': 'QA 확인 대상과 승인 기준',
      'reworkReason': '',
      'workflowTarget': target,
      'workflowPerson': '',
      'workflowRoute': 'start',
      'version': 1,
      'updatedAt': '2026-10-01T00:00:00Z',
    });

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

  Map<String, dynamic> proposal(
    WorkTask next, {
    WorkTask? base,
    int author = 2,
    List<WorkTask>? revisions,
  }) => {
    'schemaVersion': 1,
    'projectId': project.id,
    'authorId': 'gh-$author',
    'githubLogin': author == 1 ? 'tester' : 'member$author',
    'changes': [
      {
        'taskId': next.id,
        'task': next.data,
        if (base != null) 'base': base.data,
        if (revisions != null)
          'steps': revisions.map((step) => step.data).toList(),
      },
    ],
  };

  Future<ProjectManifest> publishDefinition({
    List<WorkflowStage> stages = _stages,
    WorkflowSheet sheet = _sheet,
  }) => session.saveWorkflowDefinition(
    _config,
    stages,
    sheet,
    expectedProjectId: project.id,
    expectedStages: project.workflowStages,
    expectedSheet: project.workflowSheet,
  );

  setUp(() async {
    api = AutoMergeApi();
    session = GitHubSession(api: api);
    publisher = GitHubPublisher(api);
    await login(1);
    project = await session.createProject(_config, '워크플로 재설계', '관리자');
    for (final part in const [
      ProjectRole('role-plan', '기획', {}),
      ProjectRole('role-qa', 'QA', {}),
      ProjectRole('role-pd', 'PD', {}),
    ]) {
      project = await session.savePermissionPart(_config, part);
    }
    final file = (await session.readJson(_config, '.ieum/project.json'))!;
    await session.writeJson(
      _config,
      '.ieum/project.json',
      {
        ...project.json,
        'members': [
          ...project.people.map((p) => p.json),
          for (final (id, part) in [(2, '기획'), (3, 'QA'), (4, 'PD')])
            Person(
              'gh-$id',
              '사용자 $id',
              '$id',
              'unassigned',
              0,
              login: 'member$id',
              parts: [part],
            ).json,
        ],
      },
      sha: file['sha'],
      message: 'Fixture members',
    );
    project = await session.loadProject(_config);
  });
  tearDown(() => session.signOut());

  Future<List<WorkTask>> requiredInputProof({
    bool lockedDestination = false,
    bool otherRecipient = false,
  }) async {
    final required = WorkflowSheetRoute.fromJson({
      ..._sheet.routes.first.json,
      'requiredFields': ['description'],
      if (otherRecipient) 'assignment': 'target',
      if (otherRecipient) 'destination': 'part:role-pd',
    });
    project = await publishDefinition(
      stages: [
        for (final stage in _stages)
          if (stage.id == 'doing' && lockedDestination)
            WorkflowStage(
              stage.id,
              stage.name,
              category: stage.category,
              editPolicy: 'locked',
            )
          else
            stage,
      ],
      sheet: WorkflowSheet(nodes: _sheet.nodes, routes: [required]),
    );
    final created = _task(status: 'todo', target: '').copy({
      'workflowPerson': workflowInitialPerson(project, 'todo', 'gh-2'),
      'workflowRoute': '',
      'description': '',
    });
    final filled = created.copy({'description': '전환 조건 충족', 'version': 2});
    final moved = applyWorkflowRoute(
      filled,
      required,
      project,
      actorId: 'gh-2',
    ).copy({'version': 3});
    final cleared = moved.copy({'description': '', 'version': 4});
    return [created, filled, moved, cleared];
  }

  for (final kind in [
    'shared-stage',
    'legacy-locked-stage',
    'other-recipient',
  ]) {
    test(
      'upload and integration replay input conditions and shared editing after $kind',
      () async {
        final steps = await requiredInputProof(
          lockedDestination: kind == 'legacy-locked-stage',
          otherRecipient: kind == 'other-recipient',
        );
        await login(2);
        final finalTask = steps.last;
        final receipt = await publisher.publish(_config, {
          'taskId': finalTask.id,
          'title': finalTask.title,
          'proposal': proposal(finalTask, revisions: steps),
        });
        await publisher.integrateTask(
          _config,
          receipt.prUrl,
          projectId: project.id,
          founderId: project.founderId,
        );
        expect(api.prs.single['merged'], isTrue);
        final snapshot = (await publisher.pull(_config, ''))!;
        final change =
            (snapshot['proposals'] as List).single['changes'].single as Map;
        final stored = WorkTask.fromJson(
          Map<String, dynamic>.from(change['task']),
        );
        expect(stored.version, 4);
        expect(stored.status, 'doing');
        expect(stored.description, isEmpty);
        expect(
          parseWorkflowRevisions(change['steps'])!.map((step) => step.version),
          [1, 2, 3, 4],
        );
      },
    );
  }

  for (final kind in [
    'missing-input',
    'version-gap',
    'other-task',
    'other-author',
  ]) {
    test('upload rejects an invalid intermediate revision: $kind', () async {
      var steps = await requiredInputProof();
      if (kind == 'missing-input') {
        steps = [
          for (final step in steps) step.copy({'description': ''}),
        ];
      } else if (kind == 'version-gap') {
        steps = [steps.first, ...steps.skip(2)];
      } else if (kind == 'other-task') {
        steps = [
          steps.first,
          steps[1].copy({'id': 'another-issue'}),
          ...steps.skip(2),
        ];
      }
      final author = kind == 'other-author' ? 3 : 2;
      await login(author);
      final writes = api.writes;
      final revision = api.refs['main'];
      await expectLater(
        publisher.publish(_config, {
          'taskId': steps.last.id,
          'title': steps.last.title,
          'proposal': proposal(steps.last, revisions: steps, author: author),
        }),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
      expect(api.refs['main'], revision);
      expect(api.prs, isEmpty);
    });
  }

  test('integration rejects a revision proof changed after upload without updating main', () async {
    final steps = await requiredInputProof();
    await login(2);
    final next = steps.last;
    final receipt = await publisher.publish(_config, {
      'taskId': next.id,
      'title': next.title,
      'proposal': proposal(next, revisions: steps),
    });
    final branch = api.prs.single['head']['ref'] as String;
    final path = api.files[branch]!.keys.singleWhere(
      (path) => path.startsWith('.ieum/changes/'),
    );
    final file = api.files[branch]![path]!;
    await session.writeJson(
      _config,
      path,
      proposal(
        next,
        revisions: [
          for (final step in steps) step.copy({'description': ''}),
        ],
      ),
      sha: file['sha'],
      branch: branch,
      message: 'Tampered fixture proof',
    );
    final revision = api.refs['main'];
    await expectLater(
      publisher.integrateTask(
        _config,
        receipt.prUrl,
        projectId: project.id,
        founderId: project.founderId,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.refs['main'], revision);
    expect(api.prs.single['state'], 'open');
    expect(
      api.refs.keys.where((ref) => ref.startsWith('ieum/integrations/')),
      isEmpty,
    );
  });

  test(
    'pending intermediate revision statuses prevent their removal',
    () async {
      const first = WorkflowSheetRoute(
        id: 'temporary-review',
        from: 'todo-card',
        to: 'qa-card',
        assignment: 'assignee',
      );
      const second = WorkflowSheetRoute(
        id: 'return-to-work',
        from: 'qa-card',
        to: 'doing-card',
        assignment: 'keep',
      );
      project = await publishDefinition(
        sheet: WorkflowSheet(nodes: _sheet.nodes, routes: [first, second]),
      );
      final created = _task(
        status: 'todo',
        target: '',
      ).copy({'workflowPerson': '', 'workflowRoute': ''});
      final submitted = applyWorkflowRoute(
        created,
        first,
        project,
      ).copy({'version': 2});
      final returned = applyWorkflowRoute(
        submitted,
        second,
        project,
      ).copy({'version': 3});
      await login(2);
      await publisher.publish(_config, {
        'taskId': returned.id,
        'title': returned.title,
        'proposal': proposal(
          returned,
          revisions: [created, submitted, returned],
        ),
      });
      await login(1);
      final writes = api.writes;
      await expectLater(
        session.saveWorkflowStages(
          _config,
          _stages.where((stage) => stage.id != 'stage-qa').toList(),
          expectedStages: project.workflowStages,
          expectedProjectId: project.id,
        ),
        throwsA(
          isA<GitHubFailure>().having(
            (error) => error.message,
            'proof status',
            contains('대기 PR'),
          ),
        ),
      );
      expect(api.writes, writes);
    },
  );

  test('publishing statuses and transitions is one manifest write and preserves layout and parts', () async {
    final writes = api.writes;
    final people = project.people.map((p) => p.json).toList();
    project = await publishDefinition();
    expect(api.writes, writes + 1);
    expect(
      project.workflowStages.map((s) => s.json),
      _stages.map((s) => s.json),
    );
    expect(project.workflowSheet!.json, _sheet.json);
    expect(project.people.map((p) => p.json), people);
    final loaded = await session.loadProject(_config);
    expect(loaded.initialStatusId, 'todo');
    expect(loaded.isLockedStatus('stage-qa'), isTrue);
    expect(loaded.isCompleteStatus('stage-closed'), isTrue);
    expect(
      loaded.workflowSheet!.routes
          .firstWhere((r) => r.id == 'qa-submit')
          .labelDx,
      23,
    );
    expect(
      loaded.workflowSheet!.routes
          .firstWhere((r) => r.id == 'qa-submit')
          .requiredFields,
      ['description'],
    );
  });

  test(
    'status attributes participate in stale draft and reorder checks',
    () async {
      project = await publishDefinition();
      final before = project.workflowStages;
      project = await session.saveWorkflowStages(
        _config,
        [
          for (final s in before)
            if (s.id == 'doing')
              WorkflowStage(
                s.id,
                s.name,
                category: s.category,
                editPolicy: 'everyone',
              )
            else
              s,
        ],
        expectedProjectId: project.id,
        expectedStages: before,
      );
      final writes = api.writes;
      await expectLater(
        session.saveWorkflowDefinition(
          _config,
          before,
          _sheet,
          expectedProjectId: project.id,
          expectedStages: before,
          expectedSheet: project.workflowSheet,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.saveWorkflowStages(
          _config,
          before.reversed.toList(),
          expectedProjectId: project.id,
          expectedStages: project.workflowStages,
          reorderOnly: true,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
    },
  );

  test(
    'an inactive or non-owner participant cannot publish workflow',
    () async {
      await login(2);
      final writes = api.writes;
      await expectLater(publishDefinition(), throwsA(isA<GitHubFailure>()));
      expect(api.writes, writes);
    },
  );

  test(
    'an invalid transition rejects the whole status and transition draft',
    () async {
      final writes = api.writes;
      final original = project.json;
      final invalid = WorkflowSheet(
        nodes: _sheet.nodes,
        routes: [
          const WorkflowSheetRoute(
            id: 'bad-part',
            from: 'doing-card',
            to: 'qa-card',
            destination: 'part:role-removed',
          ),
        ],
      );
      await expectLater(
        publishDefinition(sheet: invalid),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
      expect((await session.loadProject(_config)).json, original);
    },
  );

  test('same-state transitions and explicit reopen transitions are valid definitions', () async {
    project = await publishDefinition(
      sheet: WorkflowSheet(
        nodes: _sheet.nodes,
        routes: [
          ..._sheet.routes,
          const WorkflowSheetRoute(
            id: 'qa-reassign',
            from: 'qa-card',
            to: 'qa-card',
            name: '검토 인계',
            assignment: 'actor',
            operation: 'take-review',
          ),
        ],
      ),
    );
    expect(
      project.workflowSheet!.routes.any((r) => r.id == 'qa-reassign'),
      isTrue,
    );
    expect(
      project.workflowSheet!.outgoing('stage-closed').single.name,
      '작업 재개',
    );
  });

  test('a used completion status cannot be deleted', () async {
    project = await publishDefinition();
    final closed = _task(status: 'stage-closed', target: 'part:role-pd');
    api.addMainProposal(proposal(closed), closed.id);
    final writes = api.writes;
    await expectLater(
      session.saveWorkflowStages(
        _config,
        _stages.where((s) => s.id != 'stage-closed').toList(),
        expectedProjectId: project.id,
        expectedStages: project.workflowStages,
      ),
      throwsA(
        isA<GitHubFailure>().having(
          (e) => e.message,
          'usage',
          contains(closed.title),
        ),
      ),
    );
    expect(api.writes, writes);
    expect(
      (await session.loadProject(_config)).isCompleteStatus('stage-closed'),
      isTrue,
    );
  });

  test(
    'a pending transition guards both its source and destination status',
    () async {
      project = await publishDefinition();
      final base = _task();
      api.addMainProposal(proposal(base), base.id);
      final next = applyWorkflowRoute(
        base,
        _sheet.routes.firstWhere((r) => r.id == 'qa-submit'),
        project,
      ).copy({'version': 2});
      await login(2);
      await publisher.publish(_config, {
        'taskId': next.id,
        'title': next.title,
        'proposal': proposal(next, base: base),
      });
      await login(1);
      final writes = api.writes;
      await expectLater(
        session.saveWorkflowStages(
          _config,
          _stages.where((s) => s.id != 'stage-qa').toList(),
          expectedProjectId: project.id,
          expectedStages: project.workflowStages,
        ),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'pending',
            contains('대기 PR'),
          ),
        ),
      );
      expect(api.writes, writes);
    },
  );

  test(
    'a completion classification cannot silently reinterpret existing issues',
    () async {
      project = await publishDefinition();
      final task = _task();
      api.addMainProposal(proposal(task), task.id);
      final writes = api.writes;
      await expectLater(
        session.saveWorkflowStages(
          _config,
          [
            for (final s in project.workflowStages)
              if (s.id == 'doing')
                WorkflowStage(s.id, s.name, category: 'done')
              else
                s,
          ],
          expectedProjectId: project.id,
          expectedStages: project.workflowStages,
        ),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'usage',
            contains(task.title),
          ),
        ),
      );
      expect(api.writes, writes);
      expect(
        (await session.loadProject(_config)).isCompleteStatus('doing'),
        isFalse,
      );
    },
  );

  test('upload and PR integration execute planning to QA to PD to custom completion and reopen', () async {
    project = await publishDefinition();
    var task = _task();
    api.addMainProposal(proposal(task), task.id);
    for (final (author, routeId, reason) in [
      (2, 'qa-submit', ''),
      (3, 'qa-accept', ''),
      (4, 'pd-accept', ''),
      (4, 'reopen', '승인 후 변경 요청'),
    ]) {
      await login(author);
      final route = project.workflowSheet!.routes.firstWhere(
        (r) => r.id == routeId,
      );
      final next = applyWorkflowRoute(
        task,
        route,
        project,
        reason: reason,
        actorId: 'gh-$author',
      ).copy({'version': task.version + 1});
      final receipt = await publisher.publish(_config, {
        'taskId': next.id,
        'title': next.title,
        'proposal': proposal(next, base: task, author: author),
      });
      await publisher.integrateTask(
        _config,
        receipt.prUrl,
        projectId: project.id,
        founderId: project.founderId,
      );
      expect(api.prs.last['merged'], isTrue);
      task = next;
    }
    final remote = (await publisher.pull(_config, ''))!;
    final latest = (remote['proposals'] as List)
        .map(
          (p) => WorkTask.fromJson(
            Map<String, dynamic>.from(p['changes'].single['task']),
          ),
        )
        .reduce((a, b) => a.version > b.version ? a : b);
    expect(latest.status, 'doing');
    expect(latest.completedDate, isEmpty);
    expect(latest.workflowPerson, 'gh-2');
    expect(latest.reworkReason, '승인 후 변경 요청');
  });

  test(
    'custom completed issues release participant and part blockers',
    () async {
      project = await publishDefinition();
      final task = _task(
        status: 'stage-closed',
        target: 'part:role-pd',
      ).copy({'workflowPerson': 'gh-4'});
      api.addMainProposal(proposal(task), task.id);
      expect(
        await publisher.memberBlockers(
          _config,
          project,
          'gh-4',
          remainingParts: [],
          removingMember: true,
        ),
        isEmpty,
      );
      expect(
        await publisher.partBlockers(_config, project, 'role-pd'),
        isEmpty,
      );
    },
  );
}
