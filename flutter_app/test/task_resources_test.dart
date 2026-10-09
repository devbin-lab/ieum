import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_theme.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_resource_storage.dart';
import 'package:ieum_flutter/task_resources_panel.dart';

import 'part_workflow_test_fixtures.dart';
import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'six_channel_workflow_test.dart' show draft;

class ResourceApi implements GitHubApi {
  ResourceApi(this.resource);
  final TaskResource resource;
  final calls = <({String method, String path, Map<String, dynamic>? body})>[];
  bool uploaded = false, raceOnce = false, failUpload = false;
  String head = 'first';
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    calls.add((method: method, path: path, body: body));
    if (method == 'GET' && path.contains('/contents/.ieum/files/')) {
      if (!uploaded) throw const GitHubFailure('missing', 404);
      return {'sha': resource.blobSha, 'size': resource.size};
    }
    if (method == 'POST' && path.endsWith('/git/blobs')) {
      if (failUpload) throw const GitHubFailure('offline', 503);
      return {'sha': resource.blobSha};
    }
    if (method == 'GET' && path.contains('/git/ref/heads/')) {
      return {
        'object': {'sha': head},
      };
    }
    if (method == 'GET' && path.contains('/git/commits/')) {
      return {
        'tree': {'sha': 'tree-$head'},
      };
    }
    if (method == 'POST' && path.endsWith('/git/trees')) {
      return {'sha': 'new-tree'};
    }
    if (method == 'POST' && path.endsWith('/git/commits')) {
      return {'sha': 'new-commit'};
    }
    if (method == 'PATCH' && path.contains('/git/refs/heads/')) {
      if (raceOnce) {
        raceOnce = false;
        head = 'concurrent';
        throw const GitHubFailure('race', 409);
      }
      uploaded = true;
      return {};
    }
    throw StateError('Unexpected API call: $method $path');
  }
}

void main() {
  late Directory temporary;
  late TaskResourceStorage storage;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('ieum-resource-test-');
    storage = TaskResourceStorage(Directory('${temporary.path}/resources'));
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  TaskStore storeFor([Person actor = routeWorker, int limit = 50]) {
    final store = TaskStore(
      ':memory:',
      identity: actor,
      project: ProjectManifest.fromJson({
        ...personalReviewProject.json,
        'attachmentLimitMb': limit,
      }),
    );
    addTearDown(store.dispose);
    return store;
  }

  TaskResource link({String author = 'gh-2'}) => TaskResource(
    id: 'resource-test',
    name: '기획서 / 원본',
    authorId: author,
    createdAt: '2026-10-08T01:00:00Z',
    url: 'https://github.com/team/data',
  );

  Future<TaskResource> stage([String text = 'hello\n']) async {
    final source = File('${temporary.path}${Platform.pathSeparator}result.md');
    await source.writeAsString(text);
    return storage.stage(
      XFile(source.path),
      authorId: routeWorker.id,
      limitMb: 50,
    );
  }

  test(
    'old tasks remain readable and project views retain custom size limits',
    () {
      final store = storeFor();
      final task = store.save(draft());
      final old = Map<String, dynamic>.from(task.data)..remove('resources');
      expect(WorkTask.fromJson(old).resources, isEmpty);
      expect(personalReviewProject.attachmentLimitMb, 50);
      final custom = ProjectManifest.fromJson({
        ...personalReviewProject.json,
        'attachmentLimitMb': 7,
      });
      expect(custom.partWorkflowView.attachmentLimitMb, 7);
      expect(custom.unifiedView.attachmentLimitMb, 7);
      expect(
        ProjectManifest.fromJson(custom.partWorkflowView.json)
            .attachmentLimitMb,
        7,
      );
      for (final bad in [0, 51, '50', 1.5]) {
        expect(
          () => ProjectManifest.fromJson({
            ...personalReviewProject.json,
            'attachmentLimitMb': bad,
          }),
          throwsStateError,
        );
      }
    },
  );

  test(
    'only project administrators can change the current attachment limit',
    () async {
      final api = FakeGitHubApi();
      final session = GitHubSession(
        api: api,
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      addTearDown(session.signOut);
      await session.signIn(token: 'memory-only');
      const config = GitHubConfig(repository: 'team/data');
      final project = await session.createProject(config, '자료 프로젝트', '관리자');
      final saved = await session.setAttachmentLimit(
        config,
        12,
        expectedProjectId: project.id,
        expectedLimitMb: 50,
      );
      expect(saved.attachmentLimitMb, 12);
      expect(
        (await GitHubPublisher(api).project(config)).attachmentLimitMb,
        12,
      );
      await expectLater(
        session.setAttachmentLimit(
          config,
          20,
          expectedProjectId: project.id,
          expectedLimitMb: 50,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      await expectLater(
        session.setAttachmentLimit(
          config,
          51,
          expectedProjectId: project.id,
          expectedLimitMb: 12,
        ),
        throwsStateError,
      );
      await session.changeManifest(
        config,
        'Add test member',
        (current, actor) async => ProjectManifest.fromJson({
          ...current.json,
          'members': [
            ...current.people.map((person) => person.json),
            Person(
              'gh-2',
              '참여자',
              'P',
              'unassigned',
              0xff888888,
              login: 'guest',
            ).json,
          ],
        }),
      );
      api.identityId = 2;
      api.identityLogin = 'guest';
      final guest = GitHubSession(
        api: api,
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      addTearDown(guest.signOut);
      await guest.signIn(token: 'memory-only');
      await expectLater(
        guest.setAttachmentLimit(
          config,
          20,
          expectedProjectId: project.id,
          expectedLimitMb: 12,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(
        (await GitHubPublisher(api).project(config)).attachmentLimitMb,
        12,
      );
    },
  );

  test(
    'resources persist through content edits and enforce versions and locks',
    () {
      final store = storeFor();
      var task = store.save(draft());
      final added = store.setTaskResources(task.id, [
        link(),
      ], expectedVersion: task.version);
      expect(added.resources.single.name, '기획서 / 원본');
      expect(
        () =>
            store.setTaskResources(task.id, [], expectedVersion: task.version),
        throwsStateError,
      );
      task = store.save({
        ...draft(),
        'id': added.id,
        'title': '수정 내용',
      }, expectedVersion: added.version);
      expect(task.resources.single.url, link().url);
      task = store.setTaskLocked(task.id, true, expectedVersion: task.version);
      final other = storeFor(routeOwner);
      other.put(task);
      expect(
        () =>
            other.setTaskResources(task.id, [], expectedVersion: task.version),
        throwsStateError,
      );
      expect(
        () => validateTaskMutation(
          actor: other.actor,
          next: task.copy({'resources': '[]', 'version': task.version + 1}),
          current: task,
          workflowProject: store.project,
        ),
        throwsStateError,
      );
      task = store.setTaskResources(task.id, [], expectedVersion: task.version);
      expect(task.resources, isEmpty);
      expect(task.description, draft()['description']);
    },
  );

  test(
    'forged authors and replacing submitted resource versions are rejected',
    () {
      final store = storeFor();
      var task = store.save(draft());
      expect(
        () => store.setTaskResources(task.id, [
          link(author: routeOwner.id),
        ], expectedVersion: task.version),
        throwsStateError,
      );
      task = store.setTaskResources(task.id, [
        link(),
      ], expectedVersion: task.version);
      final replacement = TaskResource.fromJson({
        ...link().json,
        'url': 'https://example.com/new',
      });
      expect(
        () => store.setTaskResources(task.id, [
          replacement,
        ], expectedVersion: task.version),
        throwsStateError,
      );
      expect(
        () => parseTaskResources(jsonEncode([link().json, link().json])),
        throwsStateError,
      );
      expect(
        () =>
            TaskResource.fromJson({...link().json, 'url': 'file:///C:/secret'}),
        throwsStateError,
      );
    },
  );

  test('size limit rejects oversized files before staging and bounds streaming reads', () async {
    await expectLater(
      storage.stage(
        XFile.fromData(Uint8List(attachmentMegabyte + 1), name: 'large.pdf'),
        authorId: routeWorker.id,
        limitMb: 1,
      ),
      throwsStateError,
    );
    expect(await storage.root.exists(), isFalse);
    await expectLater(
      TaskResourceStorage.readBounded(
        Stream.fromIterable([
          [1, 2],
          [3, 4],
        ]),
        3,
      ),
      throwsStateError,
    );
    final resource = await stage();
    final store = storeFor(routeWorker, 1);
    final task = store.save(draft());
    final oversized = TaskResource.fromJson({
      ...resource.json,
      'size': 2 * attachmentMegabyte,
    });
    expect(
      () => store.setTaskResources(task.id, [
        oversized,
      ], expectedVersion: task.version),
      throwsStateError,
    );
    expect(
      () => TaskResource.fromJson({
        ...resource.json,
        'size': 50 * attachmentMegabyte + 1,
      }),
      throwsStateError,
    );
  });

  test(
    'staged files survive restart and use the canonical Git blob hash',
    () async {
      final resource = await stage();
      expect(resource.blobSha, 'ce013625030ba8dba906f756967f9e9ca394464a');
      final reopened = TaskResourceStorage(storage.root);
      expect(utf8.decode((await reopened.local(resource))!), 'hello\n');
      expect((await stage()).sha256, resource.sha256);
      expect(
        (await Directory(
          '${storage.root.path}/pending',
        ).list().toList()).length,
        1,
      );
    },
  );

  test('file publishing preserves concurrent updates without forcing refs or duplicating bytes', () async {
    final resource = await stage();
    final api = ResourceApi(resource)..raceOnce = true;
    final publisher = GitHubPublisher(api);
    const config = GitHubConfig(repository: 'team/data');
    await publisher.uploadResource(config, resource, storage);
    expect(api.uploaded, isTrue);
    final updates = api.calls.where((call) => call.method == 'PATCH').toList();
    expect(updates.length, 2);
    expect(updates.every((call) => call.body!['force'] == false), isTrue);
    final trees = api.calls
        .where((call) => call.path.endsWith('/git/trees'))
        .toList();
    expect(trees.last.body!['base_tree'], 'tree-concurrent');
    expect(
      api.calls.where((call) => call.path.endsWith('/git/blobs')).length,
      1,
    );
    expect(
      await Directory('${storage.root.path}/pending').list().isEmpty,
      isTrue,
    );
    expect(
      utf8.decode(await publisher.downloadResource(config, resource, storage)),
      'hello\n',
    );
    await publisher.uploadResource(config, resource, storage);
    expect(
      api.calls.where((call) => call.path.endsWith('/git/blobs')).length,
      1,
    );
  });

  test('failed upload retains original file and missing files block task integration', () async {
    final resource = await stage();
    final api = ResourceApi(resource)..failUpload = true;
    final publisher = GitHubPublisher(api);
    const config = GitHubConfig(repository: 'team/data');
    await expectLater(
      publisher.uploadResource(config, resource, storage),
      throwsA(isA<GitHubFailure>()),
    );
    expect(await storage.local(resource), isNotNull);
    final store = storeFor();
    final task = store.save(draft());
    final withFile = store.setTaskResources(task.id, [
      resource,
    ], expectedVersion: task.version);
    await expectLater(
      publisher.validateResourceFiles(config, withFile, task),
      throwsA(isA<GitHubFailure>()),
    );
  });

  testWidgets('file attachment renders Markdown inline and can be removed', (
    tester,
  ) async {
    final store = storeFor();
    final task = store.save(draft());
    final sourceFile = File(
      '${temporary.path}${Platform.pathSeparator}report.md',
    );
    await tester.runAsync(
      () => sourceFile.writeAsString('# 완료 보고\n\n**기획서 작성 완료**\n\n- 결과 확인'),
    );
    final source = XFile(sourceFile.path);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Colors.black, Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 380,
              child: TaskResourcesPanel(
                store: store,
                taskId: task.id,
                storage: storage,
                selectFile: () async => source,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('task-resource-add-file')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    final resource = store.find(task.id).resources.single;
    expect(find.text('report.md'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(Key('resource-preview-${resource.id}')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(find.text('완료 보고', findRichText: true), findsOneWidget);
    expect(find.text('기획서 작성 완료', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(Key('resource-remove-${resource.id}')));
    await tester.pumpAndSettle();
    expect(store.find(task.id).resources, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('link dialog attaches and removes external document references', (
    tester,
  ) async {
    final store = storeFor();
    final task = store.save(draft());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskResourcesPanel(store: store, taskId: task.id),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('task-resource-add-link')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('resource-link-name')),
      '기획 문서',
    );
    await tester.enterText(
      find.byKey(const Key('resource-link-url')),
      'https://example.com/doc',
    );
    await tester.tap(find.byKey(const Key('resource-link-save')));
    await tester.pumpAndSettle();
    final resource = store.find(task.id).resources.single;
    expect(resource.isLink, isTrue);
    expect(find.text('기획 문서'), findsOneWidget);
    expect(find.text('링크 열기'), findsOneWidget);
    expect(find.text('다운로드'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a concurrent edit discards the unattached staged file', (
    tester,
  ) async {
    final store = storeFor();
    final task = store.save(draft());
    final source = File(
      '${temporary.path}${Platform.pathSeparator}unregistered.md',
    );
    await tester.runAsync(() => source.writeAsString('not registered'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TaskResourcesPanel(
            store: store,
            taskId: task.id,
            storage: storage,
            selectFile: () async {
              store.save({
                ...draft(),
                'id': task.id,
                'title': '다른 변경',
              }, expectedVersion: task.version);
              return XFile(source.path);
            },
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('task-resource-add-file')));
      await Future<void>.delayed(const Duration(milliseconds: 250));
    });
    await tester.pumpAndSettle();
    expect(store.find(task.id).resources, isEmpty);
    expect(find.text('작업이 변경되었거나 자료를 수정할 수 없습니다.'), findsOneWidget);
    final pending = await tester.runAsync(
      () => Directory('${storage.root.path}/pending').list().toList(),
    );
    expect(pending, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
