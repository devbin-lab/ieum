import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;
import 'part_workflow_test_fixtures.dart';

WorkTask task({String status = 'doing', bool archived = false}) =>
    WorkTask.fromJson({
      'id': 'delete-task',
      'title': '삭제할 작업',
      'part': '기획',
      'priority': 'normal',
      'assigneeId': routeWorker.id,
      'reviewerId': routeReviewer.id,
      'status': status,
      'assignedDate': '2026-10-08',
      'dueDate': '',
      'completedDate': status == 'done' ? '2026-10-08' : '',
      'description': '본문',
      'reworkReason': '',
      'version': 1,
      'updatedAt': '2026-10-08T00:00:00Z',
      'archivedAt': archived ? '2026-10-08T01:00:00Z' : '',
    });

TaskStore storeFor({WorkTask? seed, Person identity = routeWorker}) {
  final store = TaskStore(
    ':memory:',
    project: personalReviewProject,
    identity: identity,
    seed: seed == null ? const [] : [seed.data],
  );
  if (seed != null) store.put(seed, table: 'baseline_tasks');
  store.setMeta(
    'github.config',
    jsonEncode(const GitHubConfig(repository: 'team/data').toJson()),
  );
  store.setMeta('github.login', identity.login);
  addTearDown(store.dispose);
  return store;
}

Map<String, dynamic> snapshot(WorkTask task) => {
  'schemaVersion': 1,
  'projectId': personalReviewProject.id,
  'revision': 'main-2',
  'tasks': [task.data],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final status in ['todo', 'doing', 'done']) {
    test(
      '$status and archived tasks can be deleted by an active participant',
      () {
        for (final archived in [false, true]) {
          final store = storeFor(
            seed: task(status: status, archived: archived),
          );
          final deleted = store.deleteTask('delete-task', expectedVersion: 1);
          expect(deleted.isDeleted, isTrue);
          expect(deleted.version, 2);
          expect(store.tasks, isEmpty);
          expect(store.storedTasks, hasLength(1));
          expect(store.changes, hasLength(1));
          expect(
            (store.changes.single['task'] as Map)['deletedAt'],
            isNotEmpty,
          );
          expect(store.canEdit(deleted), isFalse);
          expect(store.canArchive(deleted), isFalse);
          expect(store.availableTransfers(deleted), isEmpty);
          expect(
            () => store.deleteTask(deleted.id, expectedVersion: 2),
            throwsStateError,
          );
          expect(
            () => store.setArchived(deleted.id, false, expectedVersion: 2),
            throwsStateError,
          );
        }
      },
    );
  }

  test('deletion is atomic, stale or inactive attempts and hidden edits are rejected', () {
    final original = task();
    final store = storeFor(seed: original);
    expect(
      () => store.deleteTask(original.id, expectedVersion: 0),
      throwsStateError,
    );
    expect(store.find(original.id).isDeleted, isFalse);
    final disabled = Person.fromJson({...routeWorker.json, 'enabled': false});
    final inactiveStore = storeFor(seed: original, identity: disabled);
    inactiveStore.updateProject(
      ProjectManifest.fromJson({
        ...personalReviewProject.json,
        'members': [routeOwner.json, disabled.json, routeReviewer.json],
      }),
    );
    expect(
      () => inactiveStore.deleteTask(original.id, expectedVersion: 1),
      throwsStateError,
    );
    final deleted = original.copy({
      'deletedAt': '2026-10-08T02:00:00Z',
      'version': 2,
    });
    expect(
      () => validateTaskMutation(
        actor: routeWorker,
        next: deleted.copy({'description': '숨겨진 수정'}),
        current: original,
        workflowProject: personalReviewProject,
      ),
      throwsStateError,
    );
    expect(
      () => validateTaskMutation(
        actor: routeWorker,
        next: original.copy({'version': 3}),
        current: deleted,
        workflowProject: personalReviewProject,
      ),
      throwsStateError,
    );
  });

  test('remote deletion clears task notifications and repeated pulls cannot resurrect it', () {
    final original = task();
    final store = storeFor(seed: original);
    store.db.execute('INSERT INTO notification_inbox VALUES (?, ?)', [
      'n',
      jsonEncode({
        'id': 'n',
        'taskId': original.id,
        'recipientId': routeWorker.id,
        'read': false,
        'createdAt': '2026-10-08T00:00:00Z',
      }),
    ]);
    final deleted = original.copy({
      'deletedAt': '2026-10-08T02:00:00Z',
      'version': 2,
    });
    expect(store.importSnapshot(snapshot(deleted)).applied, isTrue);
    expect(store.tasks, isEmpty);
    expect(store.notifications, isEmpty);
    expect(store.unreadNotificationCount, 0);
    store.importSnapshot(snapshot(deleted));
    expect(store.find(original.id).version, 2);
    expect(
      store.importSnapshot(snapshot(original.copy({'version': 3}))).conflicts,
      isNotEmpty,
    );
    expect(store.tasks, isEmpty);
  });

  test('deletion versus an outstanding edit remains an explicit conflict', () {
    final original = task();
    final store = storeFor(seed: original);
    store.save({...original.data, 'description': '개인 수정'}, expectedVersion: 1);
    final deleted = original.copy({
      'deletedAt': '2026-10-08T02:00:00Z',
      'version': 2,
    });
    final result = store.importSnapshot(snapshot(deleted), allowPartial: true);
    expect(result.conflicts.single['field'], '작업 삭제');
    expect(store.tasks.single.description, '개인 수정');
    expect(store.baseline[original.id]!.isDeleted, isFalse);
  });

  test('offline creation, editing and deletion publish and merge with revision proof', () async {
    final api = AutoMergeApi();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    await session.signIn(token: 'test-only');
    await session.writeJson(
      config,
      '.ieum/project.json',
      personalReviewProject.json,
      message: 'Fixture',
    );
    api.identityId = 2;
    api.identityLogin = routeWorker.login;
    final store = storeFor();
    store.setMeta('github.config', jsonEncode(config.toJson()));
    final created = store.save({
      'title': '오프라인 작업',
      'part': '기획',
      'priority': 'normal',
      'assigneeId': routeWorker.id,
      'reviewerId': routeReviewer.id,
      'assignedDate': '2026-10-08',
      'dueDate': '',
      'description': '초안',
    });
    final edited = store.save({
      ...created.data,
      'description': '최종 초안',
    }, expectedVersion: 1);
    store.deleteTask(edited.id, expectedVersion: 2);
    expect(parseWorkflowRevisions(store.changes.single['steps']), hasLength(3));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(sync.dispose);
    await sync.cycle();
    await idle(sync);
    expect(sync.autoMergeErrors, isEmpty);
    expect(sync.jobs.single['state'], 'merged');
    expect(store.baseline[edited.id]!.isDeleted, isTrue);
    expect(store.tasks, isEmpty);
    final other = storeFor(identity: routeReviewer);
    other.setMeta('github.config', jsonEncode(config.toJson()));
    final pull = GitHubSync(other, publisher: GitHubPublisher(api));
    addTearDown(pull.dispose);
    api.identityId = 3;
    api.identityLogin = routeReviewer.login;
    await pull.pullLatest();
    expect(other.meta('github.lastPullError'), isEmpty);
    expect(other.tasks, isEmpty);
    expect(other.find(edited.id).isDeleted, isTrue);
  });

  test('an existing completed archived task deletes through GitHub even with a disabled former recipient', () async {
    final api = AutoMergeApi();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    const config = GitHubConfig(repository: 'team/data', enabled: true);
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
    final original = task(status: 'done', archived: true);
    api.addMainProposal({
      'schemaVersion': 1,
      'projectId': project.id,
      'authorId': routeOwner.id,
      'githubLogin': 'tester',
      'changes': [
        {'taskId': original.id, 'task': original.data, 'base': null},
      ],
    }, original.id);
    final store = storeFor(seed: original, identity: routeOwner);
    store.updateProject(project);
    store.setMeta('github.login', 'tester');
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.deleteTask(original.id, expectedVersion: 1);
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(sync.dispose);
    await sync.cycle();
    await idle(sync);
    expect(sync.autoMergeErrors, isEmpty);
    expect(sync.jobs.single['state'], 'merged');
    expect(store.baseline[original.id]!.isDeleted, isTrue);
    expect(store.tasks, isEmpty);
    expect(
      await GitHubPublisher(api)
          .workflowStageBlockers(config, project, {'done'}),
      isEmpty,
    );
  });
}
