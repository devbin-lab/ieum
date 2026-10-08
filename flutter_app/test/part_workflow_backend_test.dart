import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;
import 'v020_store_test.dart' show legacyFourStages;

class _WorkflowApi extends AutoMergeApi {
  void Function()? afterIdentityRead, beforeTreeRead;

  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (path.contains('/git/trees/')) {
      final callback = beforeTreeRead;
      beforeTreeRead = null;
      callback?.call();
    }
    final result = await super.call(method, path, query: query, body: body);
    if (path == '/user') {
      final callback = afterIdentityRead;
      afterIdentityRead = null;
      callback?.call();
    }
    return result;
  }
}

const _config = GitHubConfig(repository: 'team/data', enabled: true);
const _planning = ProjectRole('role-plan', '기획', {});
const _pd = ProjectRole('role-pd', 'PD', {});

Person _member(int id, List<String> parts) => Person.fromJson({
  'id': 'gh-$id',
  'name': '사용자 $id',
  'role': 'unassigned',
  'login': id == 1 ? 'tester' : 'member$id',
  'parts': parts,
});

WorkflowSheet _sheet({String person = ''}) => WorkflowSheet(
  nodes: const [
    WorkflowSheetNode('todo', 'todo', x: -150),
    WorkflowSheetNode('doing', 'doing'),
    WorkflowSheetNode('review', 'review', x: 150),
    WorkflowSheetNode('done', 'done', x: 300),
  ],
  routes: [
    const WorkflowSheetRoute(id: 'start', from: 'todo', to: 'doing'),
    WorkflowSheetRoute(
      id: 'handoff',
      from: 'doing',
      to: 'review',
      source: 'part:role-plan',
      destination: 'part:role-pd',
      person: person,
    ),
    const WorkflowSheetRoute(
      id: 'approve',
      from: 'review',
      to: 'done',
      action: 'approve',
      source: 'part:role-pd',
    ),
    const WorkflowSheetRoute(
      id: 'reject',
      from: 'review',
      to: 'todo',
      action: 'reject',
      source: 'part:role-pd',
      destination: 'part:role-plan',
    ),
  ],
);

WorkTask _task({
  String status = 'doing',
  String target = 'part:role-plan',
  String route = 'start',
}) => WorkTask.fromJson({
  'id': 'task-routing',
  'title': '파트 전달',
  'part': '기획',
  'status': status,
  'priority': 'normal',
  'assigneeId': 'gh-2',
  'reviewerId': 'gh-1',
  'assignedDate': '2026-10-01',
  'dueDate': '',
  'completedDate': '',
  'description': '',
  'reworkReason': '',
  'version': 1,
  'updatedAt': '2026-10-01T00:00:00Z',
  'workflowTarget': target,
  'workflowPerson': '',
  'workflowRoute': route,
});

Map<String, dynamic> _proposal(
  ProjectManifest project,
  WorkTask next, {
  WorkTask? base,
  int author = 2,
}) => {
  'schemaVersion': 1,
  'projectId': project.id,
  'authorId': 'gh-$author',
  'githubLogin': 'member$author',
  'changes': [
    {'taskId': next.id, 'task': next.data, if (base != null) 'base': base.data},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _WorkflowApi api;
  late GitHubSession session;
  late ProjectManifest project;
  late GitHubPublisher publisher;

  Future<void> write(Map<String, dynamic> value) async {
    final file = await session.readJson(_config, '.ieum/project.json');
    await session.writeJson(
      _config,
      '.ieum/project.json',
      value,
      sha: file!['sha'],
      message: 'Fixture',
    );
    project = await session.loadProject(_config);
  }

  Future<void> login(int id) async {
    api.identityId = id;
    api.identityLogin = id == 1 ? 'tester' : 'member$id';
    await session.signIn(token: 'test-only');
  }

  setUp(() async {
    api = _WorkflowApi();
    session = GitHubSession(api: api);
    await login(1);
    project = await session.createProject(_config, '파트 흐름', '관리자');
    project = await session.savePermissionPart(_config, _planning);
    project = await session.savePermissionPart(_config, _pd);
    await write({
      ...project.json,
      'workflowStages': legacyFourStages.map((s) => s.json).toList(),
      'members': [
        project.people.first.json,
        _member(2, ['기획']).json,
        _member(3, ['PD']).json,
        _member(4, ['PD']).json,
      ],
    });
    project = await session.saveWorkflowSheet(
      _config,
      _sheet(),
      expectedSheet: project.workflowSheet,
    );
    publisher = GitHubPublisher(api);
  });
  tearDown(() => session.signOut());

  test(
    'only two management grants persist while task capabilities are defaults',
    () async {
      project = await session.savePermissionPart(
        _config,
        const ProjectRole('role-plan', '기획', {
          'member.manage',
          'task.reviewAll',
        }),
      );
      expect(
        project.roles.firstWhere((r) => r.id == _planning.id).permissions,
        {'member.manage'},
      );
      final manager = project.people.firstWhere((p) => p.id == 'gh-2');
      expect(manager.permissions, containsAll(defaultTaskPermissions));
      expect(manager.has('member.manage'), isTrue);
      expect(manager.has('member.status'), isTrue);
      expect(manager.has('role.manage'), isFalse);
      expect(
        project.people.firstWhere((p) => p.id == 'gh-3').has('member.manage'),
        isFalse,
      );
      await login(2);
      final target = project.people.firstWhere((p) => p.id == 'gh-3');
      project = await session.assign(
        _config,
        Person.fromJson({
          ...target.json,
          'parts': ['기획'],
        }),
        expectedMember: target,
      );
      expect(
        project.people
            .firstWhere((p) => p.id == target.id)
            .has('member.manage'),
        isTrue,
      );
      project = await session.setMemberEnabled(_config, 'gh-4', false);
      expect(project.people.firstWhere((p) => p.id == 'gh-4').active, isFalse);
      await expectLater(
        session.setMemberEnabled(_config, project.ownerId, false),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.savePermissionPart(
          _config,
          const ProjectRole('role-new', '새 파트', {}),
        ),
        throwsA(isA<GitHubFailure>()),
      );
      await login(1);
      project = await session.savePermissionPart(_config, _planning);
      await login(2);
      await expectLater(
        session.setMemberEnabled(_config, 'gh-4', true),
        throwsA(isA<GitHubFailure>()),
      );
    },
  );

  test('delegated role management edits parts without granting unowned management rights', () async {
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-plan', '기획', {'role.manage'}),
    );
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-pd', 'PD', {'member.manage'}),
    );
    await login(2);
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-new', '새 파트', {}),
    );
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-new', '새 이름', {}),
      expectedPart: const ProjectRole('role-new', '새 파트', {}),
    );
    expect(project.parts, contains('새 이름'));
    project = await session.deletePermissionPart(_config, 'role-new');
    expect(project.parts, isNot(contains('새 이름')));
    await expectLater(
      session.savePermissionPart(
        _config,
        const ProjectRole('role-privilege', '추가 관리', {'member.manage'}),
      ),
      throwsA(isA<GitHubFailure>()),
    );
    final pd = project.roles.firstWhere((r) => r.id == _pd.id);
    project = await session.savePermissionPart(
      _config,
      ProjectRole(pd.id, 'PD 팀', pd.permissions),
      expectedPart: pd,
    );
    expect(project.roles.firstWhere((r) => r.id == _pd.id).permissions, {
      'member.manage',
    });
    final target = project.people.firstWhere((p) => p.id == 'gh-4');
    await expectLater(
      session.assign(
        _config,
        Person.fromJson({...target.json, 'parts': []}),
        expectedMember: target,
      ),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test('member managers cannot assign an unowned role-management grant to themselves', () async {
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-plan', '기획', {'member.manage'}),
    );
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-pd', 'PD', {'role.manage'}),
    );
    await login(2);
    final current = project.people.firstWhere((p) => p.id == 'gh-2');
    await expectLater(
      session.assign(
        _config,
        Person.fromJson({
          ...current.json,
          'parts': ['기획', 'PD'],
        }),
        expectedMember: current,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(
      (await session.loadProject(_config)).people
          .firstWhere((p) => p.id == 'gh-2')
          .parts,
      ['기획'],
    );
  });

  test(
    'current recipients edit task metadata without a separate assignment grant',
    () {
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.firstWhere((p) => p.id == 'gh-2'),
      );
      addTearDown(store.dispose);
      final task = store.save({
        'title': '기본 작업',
        'part': '기획',
        'assigneeId': 'gh-2',
        'reviewerId': project.ownerId,
        'assignedDate': '2026-10-07',
        'dueDate': '',
        'priority': 'normal',
        'description': '',
      });
      final changed = store.save({
        ...task.data,
        'priority': 'high',
        'dueDate': '2026-10-10',
      }, expectedVersion: task.version);
      expect(changed.priority, 'high');
      expect(changed.dueDate, '2026-10-10');
      expect(store.actor.has('member.manage'), isFalse);
      expect(store.actor.has('role.manage'), isFalse);
    },
  );

  test(
    'owner can add and remove their own parts while retaining ownership',
    () async {
      final original = project.people.first;
      final ownerId = project.ownerId;
      final founderId = project.founderId;
      for (final parts in [
        <String>['기획', 'PD'],
        <String>['PD'],
        <String>[],
      ]) {
        final current = project.people.firstWhere((p) => p.id == ownerId);
        project = await session.assign(
          _config,
          Person.fromJson({...current.json, 'parts': parts}),
          expectedProjectId: project.id,
          expectedMember: current,
        );
        final loaded = await session.loadProject(_config);
        final owner = loaded.people.firstWhere((p) => p.id == ownerId);
        expect(owner.parts, parts);
        expect(owner.role, 'owner');
        expect(owner.active, isTrue);
        expect(owner.permissions, original.permissions);
        expect(owner.login, original.login);
        expect(owner.name, original.name);
        expect(loaded.ownerId, ownerId);
        expect(loaded.founderId, founderId);
      }
      final writes = api.writes;
      await expectLater(
        session.assign(
          _config,
          Person.fromJson({
            ...original.json,
            'parts': ['기획'],
          }),
          expectedMember: Person.fromJson({
            ...original.json,
            'parts': ['PD'],
          }),
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
    },
  );

  test('owner part assignment cannot change administrator identity or be delegated', () async {
    final owner = project.people.first;
    final writes = api.writes;
    for (final changed in [
      {'role': 'unassigned'},
      {'enabled': false},
      {'name': '다른 이름'},
      {'login': 'member2'},
    ]) {
      await expectLater(
        session.assign(
          _config,
          Person.fromJson({
            ...owner.json,
            ...changed,
            'parts': ['기획'],
          }),
          expectedMember: owner,
        ),
        throwsA(isA<GitHubFailure>()),
      );
    }
    await login(2);
    await expectLater(
      session.assign(
        _config,
        Person.fromJson({
          ...owner.json,
          'parts': ['기획'],
        }),
        expectedMember: owner,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    expect((await session.loadProject(_config)).people.first.json, owner.json);
  });

  test(
    'logging out during an awaited management check aborts the manifest commit',
    () async {
      final writes = api.writes;
      api.beforeTreeRead = session.signOut;
      await expectLater(
        session.deletePermissionPart(_config, _pd.id),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'account guard',
            contains('로그인 계정이 변경'),
          ),
        ),
      );
      expect(api.writes, writes);
    },
  );

  test(
    'part definitions ignore task grants; management rights remain explicit',
    () async {
      project = await session.savePermissionPart(
        _config,
        const ProjectRole('role-plan', '기획', {
          'task.editAll',
          'task.integrate',
        }),
        expectedPart: _planning,
      );
      expect(project.roles.every((r) => r.permissions.isEmpty), isTrue);
      final member = project.people.firstWhere((p) => p.id == 'gh-2');
      expect(member.canWork, isTrue);
      expect(member.canReview, isTrue);
      expect(member.has('role.manage'), isFalse);
      expect(member.has('task.integrate'), isTrue);
      final writes = api.writes;
      await login(2);
      await expectLater(
        session.savePermissionPart(
          _config,
          const ProjectRole('role-new', '새 파트', {}),
        ),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.deletePermissionPart(_config, _pd.id),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.saveWorkflowSheet(_config, _sheet()),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.saveWorkflowStages(_config, project.workflowStages),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.assign(_config, _member(3, ['기획'])),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.setMemberEnabled(_config, 'gh-3', false),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, writes);
    },
  );

  test('sheet persists and rejects stale edits, missing parts and invalid receivers', () async {
    final expected = project.workflowSheet!;
    final moved = WorkflowSheet(
      nodes: [
        const WorkflowSheetNode('todo', 'todo', x: -220, y: 90),
        ...expected.nodes.skip(1),
      ],
      routes: expected.routes,
    );
    project = await session.saveWorkflowSheet(
      _config,
      moved,
      expectedSheet: expected,
    );
    expect(
      (await publisher.project(_config)).workflowSheet!.nodes.first.x,
      -220,
    );
    await expectLater(
      session.saveWorkflowSheet(_config, expected, expectedSheet: expected),
      throwsA(isA<GitHubFailure>()),
    );
    final invalidPart = WorkflowSheet(
      nodes: moved.nodes,
      routes: [
        const WorkflowSheetRoute(
          id: 'missing',
          from: 'doing',
          to: 'review',
          destination: 'part:role-missing',
        ),
      ],
    );
    await expectLater(
      session.saveWorkflowSheet(_config, invalidPart),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.saveWorkflowSheet(_config, _sheet(person: 'gh-2')),
      throwsA(isA<GitHubFailure>()),
    );
    final ordinaryTransition = WorkflowSheet(
      nodes: moved.nodes,
      routes: [
        const WorkflowSheetRoute(id: 'finish', from: 'review', to: 'done'),
      ],
    );
    final generic = await session.saveWorkflowSheet(
      _config,
      ordinaryTransition,
    );
    expect(generic.workflowSheet!.routes.single.action, 'advance');
  });

  test('part rename preserves stable routes and member assignment; unused deletion removes routes', () async {
    project = await session.savePermissionPart(
      _config,
      const ProjectRole('role-pd', '디렉터', {}),
      expectedPart: _pd,
    );
    expect(project.people.where((p) => p.parts.contains('디렉터')).length, 2);
    expect(
      project.workflowSheet!.routes
          .firstWhere((r) => r.id == 'handoff')
          .destination,
      'part:role-pd',
    );
    project = await session.deletePermissionPart(
      _config,
      _pd.id,
      expectedPart: const ProjectRole('role-pd', '디렉터', {}),
    );
    expect(project.roles.any((p) => p.id == _pd.id), isFalse);
    expect(project.workflowSheet!.routes.map((r) => r.id), ['start']);
    expect(project.people.every((p) => !p.parts.contains('디렉터')), isTrue);
  });

  test('first sheet save compares canonical defaults while explicit absence remains a CAS precondition', () async {
    final legacy = {...project.json}..remove('workflowSheet');
    await write(legacy);
    final defaultView = project.workflowSheet!;
    final raw = await session.readJson(_config, '.ieum/project.json');
    expect((raw!['data'] as Map).containsKey('workflowSheet'), isFalse);
    project = await session.saveWorkflowSheet(
      _config,
      defaultView,
      expectedSheet: defaultView,
    );
    final saved = await session.readJson(_config, '.ieum/project.json');
    expect((saved!['data'] as Map).containsKey('workflowSheet'), isTrue);
    await expectLater(
      session.saveWorkflowSheet(_config, _sheet(), expectedSheet: null),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test('removing a stage removes its canvas nodes and routes in the same manifest revision', () async {
    project = await session.saveWorkflowStages(
      _config,
      project.workflowStages.where((stage) => stage.id != 'review').toList(),
      expectedStages: project.workflowStages,
    );
    expect(
      project.workflowSheet!.nodes.any((n) => n.stageId == 'review'),
      isFalse,
    );
    expect(project.workflowSheet!.routes.map((r) => r.id), ['start']);
    expect(
      (await publisher.project(_config)).workflowSheet!.routes.map((r) => r.id),
      ['start'],
    );
  });

  test('deletion cannot orphan a persisted receiver; a part-wide task keeps another active receiver', () async {
    final task = _task(
      status: 'review',
      target: 'part:role-pd',
      route: 'handoff',
    );
    api.addMainProposal(_proposal(project, task), task.id);
    await expectLater(
      session.deletePermissionPart(_config, _pd.id),
      throwsA(isA<GitHubFailure>()),
    );
    project = await session.setMemberEnabled(_config, 'gh-3', false);
    expect(project.people.firstWhere((p) => p.id == 'gh-3').active, isFalse);
    await expectLater(
      session.setMemberEnabled(_config, 'gh-4', false),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test('sender content edits integrate while a forged all-worker recipient is rejected', () async {
    final base = _task(
      status: 'review',
      target: 'part:role-pd',
      route: 'handoff',
    );
    api.addMainProposal(_proposal(project, base), base.id);
    await login(2);
    final writes = api.writes;
    final forged = base.copy({'workflowTarget': '', 'version': 2});
    await expectLater(
      publisher.publish(_config, {
        'taskId': forged.id,
        'title': forged.title,
        'proposal': _proposal(project, forged, base: base),
      }),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    final edited = base.copy({'title': '검토 중 기획자가 수정', 'version': 2});
    final receipt = await publisher.publish(_config, {
      'taskId': edited.id,
      'title': edited.title,
      'proposal': _proposal(project, edited, base: base),
    });
    await publisher.integrateTask(
      _config,
      receipt.prUrl,
      projectId: project.id,
      founderId: project.founderId,
    );
    expect(api.prs.single['merged'], isTrue);
    final snapshot = (await publisher.pull(_config, ''))!;
    final accepted = (snapshot['proposals'] as List)
        .map(
          (p) => WorkTask.fromJson(
            Map<String, dynamic>.from(p['changes'].single['task']),
          ),
        )
        .reduce((a, b) => a.version > b.version ? a : b);
    expect(accepted.title, edited.title);
    expect(accepted.workflowTarget, 'part:role-pd');
  });

  test(
    'upload and integration apply the same source and current receiver policy',
    () async {
      final base = _task();
      api.addMainProposal(_proposal(project, base), base.id);
      final route = project.workflowSheet!.routes.firstWhere(
        (r) => r.id == 'handoff',
      );
      final next = applyWorkflowRoute(
        base,
        route,
        project,
      ).copy({'version': 2});
      await login(2);
      final receipt = await publisher.publish(_config, {
        'taskId': next.id,
        'title': next.title,
        'proposal': _proposal(project, next, base: base),
      });
      await publisher.integrateTask(
        _config,
        receipt.prUrl,
        projectId: project.id,
        founderId: project.founderId,
      );
      expect(api.prs.single['merged'], isTrue);
      final remote = (await publisher.pull(_config, ''))!;
      final accepted = (remote['proposals'] as List)
          .map(
            (p) => WorkTask.fromJson(
              Map<String, dynamic>.from(p['changes'].single['task']),
            ),
          )
          .reduce((a, b) => a.version > b.version ? a : b);
      expect(accepted.status, 'review');
      expect(accepted.workflowTarget, 'part:role-pd');
    },
  );

  test(
    'integration rechecks the latest author membership after upload',
    () async {
      final base = _task();
      api.addMainProposal(_proposal(project, base), base.id);
      final route = project.workflowSheet!.routes.firstWhere(
        (r) => r.id == 'handoff',
      );
      final next = applyWorkflowRoute(
        base,
        route,
        project,
      ).copy({'version': 2});
      await login(2);
      final receipt = await publisher.publish(_config, {
        'taskId': next.id,
        'title': next.title,
        'proposal': _proposal(project, next, base: base),
      });
      await login(1);
      await write({
        ...project.json,
        'members': [
          for (final person in project.people)
            {...person.json, if (person.id == 'gh-2') 'parts': <String>[]},
        ],
      });
      final main = api.refs['main'];
      await expectLater(
        publisher.integrateTask(
          _config,
          receipt.prUrl,
          projectId: project.id,
          founderId: project.founderId,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.refs['main'], main);
      expect(api.prs.single['state'], 'open');
    },
  );

  test(
    'a changed executor account is rejected again before the main ref update',
    () async {
      final base = _task();
      api.addMainProposal(_proposal(project, base), base.id);
      final route = project.workflowSheet!.routes.firstWhere(
        (r) => r.id == 'handoff',
      );
      final next = applyWorkflowRoute(
        base,
        route,
        project,
      ).copy({'version': 2});
      await login(2);
      final receipt = await publisher.publish(_config, {
        'taskId': next.id,
        'title': next.title,
        'proposal': _proposal(project, next, base: base),
      });
      final main = api.refs['main'];
      api.afterIdentityRead = () {
        api.identityId = 4;
        api.identityLogin = 'member4';
      };
      await expectLater(
        publisher.integrateTask(
          _config,
          receipt.prUrl,
          projectId: project.id,
          founderId: project.founderId,
        ),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'account guard',
            contains('로그인 계정이 변경'),
          ),
        ),
      );
      expect(api.refs['main'], main);
      expect(api.prs.single['state'], 'open');
    },
  );

  test('active participants integrate validated peer PRs without a management grant', () async {
    final base = _task();
    api.addMainProposal(_proposal(project, base), base.id);
    final route = project.workflowSheet!.routes.firstWhere(
      (r) => r.id == 'handoff',
    );
    final next = applyWorkflowRoute(base, route, project).copy({'version': 2});
    await login(2);
    final receipt = await publisher.publish(_config, {
      'taskId': next.id,
      'title': next.title,
      'proposal': _proposal(project, next, base: base),
    });
    await login(4);
    final main = api.refs['main'];
    final executor = (await session.loadProject(_config)).people
        .firstWhere((p) => p.id == 'gh-4');
    expect(executor.has('member.manage'), isFalse);
    expect(executor.has('role.manage'), isFalse);
    await publisher.integrateTask(
      _config,
      receipt.prUrl,
      projectId: project.id,
      founderId: project.founderId,
    );
    expect(api.refs['main'], isNot(main));
    expect(api.prs.single['merged'], isTrue);
  });

  test('a collapsed queue proposal retains its receiving part and integrates a subsequent sender edit', () async {
    await login(2);
    final sender = project.people.firstWhere((p) => p.id == 'gh-2');
    final store = TaskStore(':memory:', project: project, identity: sender);
    store.setMeta('github.config', jsonEncode(_config.toJson()));
    store.setMeta('github.login', 'member2');
    GitHubSync? sync;
    try {
      final task = store.save({
        'title': '오프라인 단계 전달',
        'part': '기획',
        'priority': 'normal',
        'assigneeId': 'gh-2',
        'reviewerId': 'gh-1',
        'assignedDate': '2026-10-01',
        'dueDate': '',
        'description': '',
      });
      store.transition(task.id, 'doing', expectedVersion: 1);
      store.transition(task.id, 'review', expectedVersion: 2);
      final sent = store.find(task.id);
      expect(sent.version, 3);
      expect(sent.workflowTarget, 'part:role-pd');
      expect(store.canEditContent(sent), isTrue);
      final edited = store.save({
        ...sent.data,
        'description': '전달 이후 기획자의 보충 설명',
      }, expectedVersion: sent.version);
      expect(edited.workflowTarget, sent.workflowTarget);
      expect(
        store
            .availableHandoffs(edited)
            .any((plan) => plan.routeId == 'manual-finish'),
        isTrue,
      );
      sync = GitHubSync(store, publisher: publisher);
      await sync.cycle();
      await idle(sync);
      expect(api.prs.single['merged'], isTrue);
      expect(store.baseline[task.id]!.workflowTarget, 'part:role-pd');
      expect(store.baseline[task.id]!.status, 'review');
      expect(store.baseline[task.id]!.description, edited.description);
      expect(sync.jobs.single['state'], 'merged');
    } finally {
      sync?.dispose();
      store.dispose();
    }
  });

  test(
    'integration rechecks the latest destination policy after upload',
    () async {
      final base = _task();
      api.addMainProposal(_proposal(project, base), base.id);
      final route = project.workflowSheet!.routes.firstWhere(
        (r) => r.id == 'handoff',
      );
      final next = applyWorkflowRoute(
        base,
        route,
        project,
      ).copy({'version': 2});
      await login(2);
      final receipt = await publisher.publish(_config, {
        'taskId': next.id,
        'title': next.title,
        'proposal': _proposal(project, next, base: base),
      });
      await login(1);
      project = await session.saveWorkflowSheet(
        _config,
        _sheet(person: 'gh-3'),
        expectedSheet: project.workflowSheet,
      );
      final main = api.refs['main'];
      await expectLater(
        publisher.integrateTask(
          _config,
          receipt.prUrl,
          projectId: project.id,
          founderId: project.founderId,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.refs['main'], main);
      expect(api.prs.single['state'], 'open');
    },
  );
}
