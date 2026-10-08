import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi;
import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'part_workflow_test_fixtures.dart';

WorkTask _task({String id = 'archive-task', String status = 'review'}) =>
    WorkTask.fromJson({
      'id': id,
      'title': '보관할 작업',
      'part': '기획',
      'priority': 'normal',
      'assigneeId': routeWorker.id,
      'reviewerId': routeReviewer.id,
      'status': status,
      'assignedDate': '2026-10-01',
      'dueDate': '',
      'completedDate': '',
      'description': '원본 내용',
      'reworkReason': '',
      'workflowTarget': 'part:role-pd',
      'workflowPerson': routeReviewer.id,
      'workflowRoute': 'submit',
      'version': 1,
      'updatedAt': '2026-10-08T00:00:00Z',
    });

TaskStore _store(Person actor) {
  final store = TaskStore(
    ':memory:',
    project: personalReviewProject,
    identity: actor,
  );
  final task = _task();
  store.put(task);
  store.put(task, table: 'baseline_tasks');
  store.setMeta(
    'github.config',
    jsonEncode(const GitHubConfig(repository: 'team/data').toJson()),
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  test('completed archive restores after its former recipient is disabled without allowing content edits', () async {
    final api = AutoMergeApi();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    const config = GitHubConfig(repository: 'team/data');
    await session.signIn(token: 'test-only');
    final project = ProjectManifest.fromJson({
      ...personalReviewProject.json,
      'members': [
        routeOwner.json,
        routeWorker.json,
        {...routeReviewer.json, 'enabled': false},
      ],
    });
    await session.writeJson(
      config,
      '.ieum/project.json',
      project.json,
      message: 'Fixture',
    );
    final archived = _task().copy({
      'status': 'done',
      'completedDate': '2026-10-08',
      'archivedAt': '2026-10-08T01:00:00Z',
    });
    Map<String, dynamic> proposal(WorkTask task, WorkTask? base) => {
      'schemaVersion': 1,
      'projectId': project.id,
      'authorId': routeOwner.id,
      'githubLogin': 'tester',
      'changes': [
        {'taskId': task.id, 'task': task.data, 'base': base?.data},
      ],
    };
    api.addMainProposal(proposal(archived, null), archived.id);
    final publisher = GitHubPublisher(api);
    final restored = archived.copy({'archivedAt': '', 'version': 2});
    await expectLater(
      publisher.publish(config, {
        'taskId': restored.id,
        'title': restored.title,
        'proposal': proposal(
          restored.copy({'description': '허용되지 않은 내용 변경'}),
          archived,
        ),
      }),
      throwsA(isA<GitHubFailure>()),
    );
    final receipt = await publisher.publish(config, {
      'taskId': restored.id,
      'title': restored.title,
      'proposal': proposal(restored, archived),
    });
    await publisher.integrateTask(
      config,
      receipt.prUrl,
      projectId: project.id,
      founderId: project.founderId,
    );
    expect(api.prs.single['merged'], isTrue);
  });

  test(
    'older unread notifications remain reachable behind newer read history',
    () {
      final store = _store(routeOwner);
      for (var i = 0; i < 510; i++) {
        store.db.execute('INSERT INTO notification_inbox VALUES (?,?)', [
          '$i',
          jsonEncode({
            'id': '$i',
            'recipientId': routeOwner.id,
            'read': i >= 10,
            'createdAt': i < 10
                ? '2026-10-01T00:00:00Z'
                : '2026-10-08T00:00:00Z',
          }),
        ]);
      }
      expect(store.totalNotificationCount, 510);
      expect(store.notifications, hasLength(500));
      expect(
        store.notifications.where((n) => n['read'] == false),
        hasLength(10),
      );
      expect(store.unreadNotificationCount, 10);
    },
  );

  test('offline content revisions use a proven bounded wire payload', () async {
    final api = AutoMergeApi();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    const config = GitHubConfig(repository: 'team/data');
    await session.signIn(token: 'test-only');
    await session.createProject(config, '보관과 동기화', '개설자');
    final project = await session.savePermissionPart(config, planningPart);
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: session.named('개설자'),
    );
    addTearDown(store.dispose);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'tester');
    var task = store.save({
      'title': '오프라인 편집',
      'part': '기획',
      'priority': 'normal',
      'assigneeId': 'gh-1',
      'reviewerId': 'gh-1',
      'assignedDate': '2026-10-01',
      'dueDate': '',
      'description': '${'가' * 9900} 0',
    });
    for (var i = 1; i < 40; i++) {
      task = store.save({
        ...task.data,
        'description': '${'가' * 9900} $i',
      }, expectedVersion: task.version);
    }
    final job = Map<String, dynamic>.from(
      jsonDecode(
        store.db.select('SELECT body FROM github_queue').single['body']
            as String,
      ),
    );
    expect(
      utf8.encode(jsonEncode(job['proposal'])).length,
      greaterThan(1024 * 1024),
    );
    final receipt = await GitHubPublisher(api).publish(config, job);
    final content = api.files[receipt.branch]!.values.last['content'] as String;
    final published = jsonDecode(utf8.decode(base64Decode(content)));
    expect(published['changes'].single['steps'], isNull);
    expect(published['changes'].single['task']['version'], task.version);
    expect(store.db.select('SELECT * FROM workflow_revisions'), hasLength(40));
  });
  test('archive and restore are versioned transactions and archived content stays protected', () {
    final store = _store(routeReviewer);
    final original = store.find('archive-task');
    expect(original.isArchived, isFalse);
    expect(store.canEdit(original), isTrue);
    final archived = store.setArchived(original.id, true, expectedVersion: 1);
    expect(archived.isArchived, isTrue);
    expect(archived.version, 2);
    expect(store.availableHandoffs(archived), isEmpty);
    expect(store.canEditContent(archived), isFalse);
    expect(
      () =>
          store.save({...archived.data, 'title': '우회 수정'}, expectedVersion: 2),
      throwsStateError,
    );
    expect(
      () => store.setArchived(original.id, false, expectedVersion: 1),
      throwsStateError,
    );
    final restored = store.setArchived(original.id, false, expectedVersion: 2);
    expect(restored.isArchived, isFalse);
    expect(restored.description, original.description);
    expect(restored.version, 3);
    expect(store.activityFor(original.id), hasLength(2));
    final proposal = jsonDecode(
      store.db.select('SELECT body FROM github_queue').single['body'] as String,
    )['proposal'];
    validateTaskMutation(
      actor: routeReviewer,
      next: restored,
      current: original,
      workflowProject: personalReviewProject,
      allowCollapsedTransitions: true,
      revisions: parseWorkflowRevisions(proposal['changes'].single['steps']),
    );
  });

  test('collaborators may archive but cannot combine archiving with hidden content edits', () {
    final store = _store(routeWorker);
    final original = store.find('archive-task');
    expect(store.canArchive(original), isTrue);
    expect(
      () => store.setArchived(original.id, true, expectedVersion: 1),
      returnsNormally,
    );
    final archived = original.copy({
      'archivedAt': '2026-10-08T01:00:00Z',
      'version': 2,
    });
    expect(
      () => validateTaskMutation(
        actor: routeReviewer,
        current: original,
        next: archived.copy({'title': '숨긴 변경'}),
        workflowProject: personalReviewProject,
      ),
      throwsStateError,
    );
    expect(
      () => validateTaskMutation(
        actor: routeReviewer,
        current: archived,
        next: archived.copy({'description': '변경', 'version': 3}),
        workflowProject: personalReviewProject,
      ),
      throwsStateError,
    );
    expect(() => original.copy({'archivedAt': 'not-a-date'}), throwsStateError);
    expect(store.db.select('SELECT * FROM github_queue'), hasLength(1));
    expect(store.find(original.id).title, original.title);
  });

  test('remote archive conflicts with outstanding local content instead of hiding it', () {
    final store = _store(routeOwner);
    final original = store.find('archive-task');
    store.put(original.copy({'description': '아직 보내지 않은 내용', 'version': 2}));
    final remote = original.copy({
      'archivedAt': '2026-10-08T01:00:00Z',
      'version': 2,
    });
    final result = store.importSnapshot({
      'schemaVersion': 1,
      'projectId': personalReviewProject.id,
      'revision': 'new-main',
      'tasks': [remote.data],
    }, allowPartial: true);
    expect(result.conflicts, isNotEmpty);
    expect(store.find(original.id).isArchived, isFalse);
    expect(store.find(original.id).description, '아직 보내지 않은 내용');
  });

  test('task history is filtered before limit and inbox caps preserve unread records', () {
    final store = _store(routeOwner);
    final first = store.find('archive-task');
    final other = _task(id: 'another');
    store.put(other);
    store.put(other, table: 'baseline_tasks');
    store.log(first, '원래 작업 기록');
    for (var i = 0; i < 110; i++) {
      store.log(other, '다른 기록 $i', eventType: 'task.moved');
    }
    expect(store.activityFor(first.id).single['message'], '원래 작업 기록');
    expect(store.activityFor(other.id), hasLength(100));
    expect(
      store.db.select('SELECT * FROM notification_outbox'),
      hasLength(100),
    );
    for (var i = 0; i < 520; i++) {
      store.db.execute('INSERT INTO notification_inbox VALUES (?,?)', [
        '$i',
        jsonEncode({
          'id': '$i',
          'recipientId': routeOwner.id,
          'read': false,
          'createdAt': '2026-10-08T01:00:00Z',
        }),
      ]);
    }
    expect(store.notifications, hasLength(500));
    expect(store.unreadNotificationCount, 520);
    expect(store.db.select('SELECT * FROM notification_inbox'), hasLength(520));
    store.markNotificationsRead();
    expect(store.db.select('SELECT * FROM notification_inbox'), hasLength(500));
    expect(store.unreadNotificationCount, 0);
  });

  test('small blob cache evicts old payloads while unchanged current snapshot is reused', () async {
    final api = FakeGitHubApi();
    final publisher = GitHubPublisher(api, blobCacheByteLimit: 1);
    const config = GitHubConfig(repository: 'team/data');
    Map<String, dynamic> proposal(WorkTask task) => {
      'schemaVersion': 1,
      'projectId': personalReviewProject.id,
      'changes': [
        {'taskId': task.id, 'task': task.data},
      ],
    };
    api.addMainProposal(proposal(_task()), 'archive-task');
    await publisher.pull(config, '');
    final first = api.calls
        .where((call) => call.contains('/git/blobs/'))
        .length;
    await publisher.pull(config, '');
    expect(
      api.calls.where((call) => call.contains('/git/blobs/')).length,
      first,
    );
    api.addMainProposal(proposal(_task(id: 'next')), 'next');
    final result = await publisher.pull(config, '');
    expect(result!['proposals'], hasLength(2));
    expect(
      api.calls.where((call) => call.contains('/git/blobs/')).length,
      first + 2,
    );
  });
}
