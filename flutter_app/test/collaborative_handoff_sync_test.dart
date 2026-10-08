import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;

const _planner = Person(
  'gh-2',
  '기획자',
  '기',
  'unassigned',
  0,
  login: 'planner',
  parts: ['기획'],
);
const _qa = Person(
  'gh-3',
  'QA',
  'Q',
  'unassigned',
  0,
  login: 'qa',
  parts: ['QA'],
);
const _pd = Person(
  'gh-4',
  'PD',
  'P',
  'unassigned',
  0,
  login: 'director',
  parts: ['PD'],
);
const _config = GitHubConfig(repository: 'team/data', enabled: true);

Map<String, dynamic> _draft() => {
  'title': '협업 전달 작업',
  'part': '기획',
  'priority': 'normal',
  'assigneeId': _planner.id,
  'reviewerId': _pd.id,
  'assignedDate': '2026-10-08',
  'dueDate': '',
  'description': '기획 초안',
};

void _transfer(
  TaskStore store,
  WorkTask task,
  Person receiver, {
  String purpose = 'review',
}) {
  final plan = store.planHandoff(
    task,
    task.status,
    routeId: 'manual-handoff',
    receiverPerson: receiver.id,
    purpose: purpose,
  );
  store.confirmHandoff(plan);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AutoMergeApi api;
  late GitHubSession session;
  late ProjectManifest project;

  void publishManifest(ProjectManifest manifest) {
    final content = {
      'encoding': 'base64',
      'sha': 'manifest${++api.serial}',
      'content': base64Encode(utf8.encode(jsonEncode(manifest.json))),
    };
    api.files['main']!['.ieum/project.json'] = content;
    api.snapshots[api.refs['main']]!['.ieum/project.json'] = content;
  }

  TaskStore storeFor(Person identity, {WorkTask? seed}) {
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: identity,
      seed: seed == null ? const [] : [seed.data],
    );
    store.setMeta('github.config', jsonEncode(_config.toJson()));
    store.setMeta('github.login', identity.login);
    addTearDown(store.dispose);
    return store;
  }

  void useIdentity(Person identity) {
    api.identityId = int.parse(identity.id.substring(3));
    api.identityLogin = identity.login;
  }

  Future<void> flush(TaskStore store, Person identity) async {
    useIdentity(identity);
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    try {
      await sync.cycle();
      await idle(sync);
      expect(sync.autoMergeErrors, isEmpty);
      expect(sync.jobs.every((job) => job['state'] == 'merged'), isTrue);
    } finally {
      sync.dispose();
    }
  }

  Future<void> pull(TaskStore store, Person identity) async {
    useIdentity(identity);
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    try {
      await sync.pullLatest();
    } finally {
      sync.dispose();
    }
  }

  WorkTask baselineTask() => WorkTask.fromJson({
    ..._draft(),
    'id': 'COLLABORATIVE-TASK',
    'status': 'doing',
    'completedDate': '',
    'reworkReason': '',
    'workflowTarget': '',
    'workflowPerson': _planner.id,
    'workflowRoute': '',
    'workflowPurpose': 'work',
    'workflowSender': '',
    'version': 1,
    'updatedAt': '2026-10-08T00:00:00Z',
  });

  Map<String, dynamic> snapshot(WorkTask task, String revision) => {
    'schemaVersion': 1,
    'projectId': project.id,
    'revision': revision,
    'tasks': [task.data],
  };

  setUp(() async {
    api = AutoMergeApi();
    session = GitHubSession(api: api);
    await session.signIn(token: 'test-only');
    final created = await session.createProject(_config, '협업 전달 회귀', '관리자');
    final defaults = WorkflowSheet.defaultFor(['todo', 'doing', 'done']);
    project = ProjectManifest.fromJson({
      ...created.json,
      'roles': [
        const ProjectRole('role-plan', '기획', {}).json,
        const ProjectRole('role-qa', 'QA', {}).json,
        const ProjectRole('role-pd', 'PD', {}).json,
      ],
      'parts': ['기획', 'QA', 'PD'],
      'unifiedParts': true,
      'members': [
        ...created.people.map((person) => person.json),
        _planner.json,
        _qa.json,
        _pd.json,
      ],
      'workflowSheet': WorkflowSheet(
        nodes: defaults.nodes,
        routes: [
          ...defaults.routes,
          const WorkflowSheetRoute(
            id: 'planning-pd-preset',
            from: 'doing',
            to: 'doing',
            source: 'part:role-plan',
            destination: 'part:role-pd',
          ),
        ],
      ).json,
    });
    publishManifest(project);
  });

  tearDown(() => session.signOut());

  test('same-status handoff, sender edit, QA to PD and return integrate under their actual GitHub authors', () async {
    final planner = storeFor(_planner);
    var task = planner.save(_draft());
    planner.confirmHandoff(
      planner.planHandoff(task, 'doing', routeId: 'manual-start'),
    );
    task = planner.find(task.id);
    _transfer(planner, task, _qa);
    task = planner.find(task.id);
    expect(task.status, 'doing');
    expect(task.workflowPerson, _qa.id);
    expect(task.workflowSender, _planner.id);
    expect(planner.isAssignedToMe(task), isFalse);
    expect(planner.canEditContent(task), isTrue);
    planner.save({
      ...task.data,
      'description': '전달 후 기획자 추가 설명',
    }, expectedVersion: task.version);
    final proof = (planner.exportChanges()['changes'] as List).single as Map;
    expect(parseWorkflowRevisions(proof['steps']), hasLength(4));
    await flush(planner, _planner);
    expect(planner.baseline[task.id]!.description, '전달 후 기획자 추가 설명');
    expect(planner.baseline[task.id]!.status, 'doing');
    expect(api.prs.single['user']['id'], 2);
    expect(api.prs.single['merged'], isTrue);

    final qa = storeFor(_qa);
    await pull(qa, _qa);
    task = qa.find(task.id);
    expect(qa.isAssignedToMe(task), isTrue);
    final firstInboxCount = qa.notifications.length;
    await pull(qa, _qa);
    expect(qa.notifications.length, firstInboxCount);
    expect(firstInboxCount, 1);
    _transfer(qa, task, _pd);
    await flush(qa, _qa);
    expect(qa.baseline[task.id]!.workflowSender, _qa.id);
    expect(qa.baseline[task.id]!.workflowPerson, _pd.id);
    expect(qa.baseline[task.id]!.status, 'doing');
    expect(api.prs.last['user']['id'], 3);

    await pull(planner, _planner);
    expect(planner.canEditContent(planner.find(task.id)), isTrue);
    final pd = storeFor(_pd);
    await pull(pd, _pd);
    task = pd.find(task.id);
    final returnPlan = pd.planHandoff(
      task,
      task.status,
      routeId: 'manual-return',
    );
    expect(returnPlan.receiverPerson, _qa.id);
    pd.confirmHandoff(returnPlan, reason: 'QA 확인 사항을 보완해 주세요.');
    await flush(pd, _pd);
    final returned = pd.baseline[task.id]!;
    expect(returned.status, 'doing');
    expect(returned.workflowPerson, _qa.id);
    expect(returned.workflowSender, _pd.id);
    expect(returned.workflowPurpose, 'revision');
    expect(returned.reworkReason, 'QA 확인 사항을 보완해 주세요.');
    expect(api.prs.last['user']['id'], 4);
    expect(api.prs.every((request) => request['merged'] == true), isTrue);
    expect(
      api.refs.keys.where((ref) => ref.startsWith('ieum/integrations/')),
      isEmpty,
    );
  });

  test('an independent local content edit merges with a remote handoff without a recipient lock', () {
    final base = baselineTask();
    final local = storeFor(_planner, seed: base);
    final remote = storeFor(_qa, seed: base);
    local.save({
      ...base.data,
      'description': '기획자가 정리한 추가 내용',
    }, expectedVersion: base.version);
    _transfer(remote, base, _pd);
    final incoming = remote.find(base.id);
    final merged = local.importSnapshot(snapshot(incoming, 'handoff-main'));
    expect(merged.applied, isTrue);
    expect(merged.conflicts, isEmpty);
    final result = local.find(base.id);
    expect(result.description, '기획자가 정리한 추가 내용');
    expect(result.status, 'doing');
    expect(result.workflowPerson, _pd.id);
    expect(result.workflowSender, _qa.id);
    expect(local.canEditContent(result), isTrue);
    expect(local.baseline[base.id]!.same(incoming), isTrue);
  });

  test('different concurrent handoffs preserve the original local recipient and report an atomic conflict', () {
    final base = baselineTask();
    final local = storeFor(_planner, seed: base);
    final remote = storeFor(_qa, seed: base);
    _transfer(local, base, _qa);
    final own = local.find(base.id);
    _transfer(remote, base, _pd);
    final merged = local.importSnapshot(
      snapshot(remote.find(base.id), 'competing-handoff'),
    );
    expect(merged.applied, isFalse);
    expect(merged.conflicts.single['field'], '워크플로 전환');
    expect(local.find(base.id).same(own), isTrue);
    expect(local.find(base.id).workflowSender, _planner.id);
    expect(local.baseline[base.id]!.same(base), isTrue);
  });

  test('unchanged inactive recipient does not block another active member content edit or GitHub integration', () async {
    final planner = storeFor(_planner);
    var task = planner.save(_draft());
    planner.confirmHandoff(
      planner.planHandoff(task, 'doing', routeId: 'manual-start'),
    );
    _transfer(planner, planner.find(task.id), _qa);
    await flush(planner, _planner);
    project = ProjectManifest.fromJson({
      ...project.json,
      'members': [
        for (final person in project.people)
          {...person.json, if (person.id == _qa.id) 'enabled': false},
      ],
    });
    publishManifest(project);
    planner.updateProject(project);
    task = planner.find(task.id);
    expect(planner.canEditContent(task), isTrue);
    planner.save({
      ...task.data,
      'description': '담당자 비활성화 후에도 공유 문서 수정',
    }, expectedVersion: task.version);
    await flush(planner, _planner);
    final integrated = planner.baseline[task.id]!;
    expect(integrated.workflowPerson, _qa.id);
    expect(integrated.description, '담당자 비활성화 후에도 공유 문서 수정');
    expect(api.prs.last['merged'], isTrue);
    expect(
      () => planner.confirmHandoff(
        planner.planHandoff(
          integrated,
          integrated.status,
          routeId: 'manual-handoff',
          receiverPerson: _qa.id,
        ),
      ),
      throwsStateError,
    );
  });

  test('legacy registration edits normalize the same inactive recipient and integrate without allowing forged normalization', () async {
    final base = baselineTask().copy({
      'assigneeId': _qa.id,
      'workflowTarget': 'legacy',
      'workflowPerson': '',
    });
    project = ProjectManifest.fromJson({
      ...project.json,
      'members': [
        for (final person in project.people)
          {...person.json, if (person.id == _qa.id) 'enabled': false},
      ],
    });
    publishManifest(project);
    api.addMainProposal({
      'schemaVersion': 1,
      'projectId': project.id,
      'githubLogin': _qa.login,
      'authorId': _qa.id,
      'changes': [
        {'taskId': base.id, 'task': base.data},
      ],
    }, base.id);
    final planner = storeFor(_planner, seed: base);
    expect(base.currentId, _qa.id);
    expect(planner.canEditContent(base), isTrue);
    final normalized = planner.save({
      ...base.data,
      'assigneeId': _pd.id,
      'description': '등록 담당자를 바꾸고 공유 내용을 정리',
    }, expectedVersion: base.version);
    expect(normalized.workflowTarget, isEmpty);
    expect(normalized.workflowPerson, base.currentId);
    expect(normalized.currentId, base.currentId);
    expect(normalized.assigneeId, _pd.id);
    await flush(planner, _planner);
    final integrated = planner.baseline[base.id]!;
    expect(integrated.workflowPerson, _qa.id);
    expect(integrated.assigneeId, _pd.id);
    expect(api.prs.single['merged'], isTrue);
    expect(
      () => validateTaskMutation(
        actor: planner.actor,
        current: base,
        next: base.copy({
          'workflowTarget': '',
          'workflowPerson': _qa.id,
          'version': 2,
        }),
        workflowProject: project,
      ),
      throwsStateError,
    );
    expect(
      () => planner.confirmHandoff(
        planner.planHandoff(
          integrated,
          integrated.status,
          routeId: 'manual-handoff',
          receiverPerson: _qa.id,
        ),
      ),
      throwsStateError,
    );
  });
}
