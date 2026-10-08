import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/project_gate.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi;
import 'github_oauth_test.dart' show MemoryVault, ScriptedOAuth, device, tokens;

const settings = GitHubConfig(
  repository: 'team/data',
  enabled: true,
  autoMerge: false,
);

class ProjectApi extends FakeGitHubApi {
  int userFailure = -1;
  bool loseCreateResponse = false;
  Completer<void>? holdIdentity;
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (path == '/user') {
      await holdIdentity?.future;
      if (userFailure >= 0) throw GitHubFailure('injected', userFailure);
    }
    if (path == '/repos/team/data/pulls' && method == 'GET') {
      final all =
          await super.call(method, path, query: query, body: body) as List;
      final offset = ((int.tryParse(query?['page'] ?? '') ?? 1) - 1) * 100;
      return all.skip(offset).take(100).toList();
    }
    final result = await super.call(method, path, query: query, body: body);
    if (loseCreateResponse &&
        method == 'PUT' &&
        path.endsWith('/.ieum/project.json')) {
      loseCreateResponse = false;
      throw const GitHubFailure('response lost');
    }
    return result;
  }
}

class TwoProjectApi implements GitHubApi {
  final first = ProjectApi(), second = ProjectApi();
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) => path.startsWith('/repos/team/second')
      ? second.call(
          method,
          path.replaceFirst('/repos/team/second', '/repos/team/data'),
          query: query,
          body: body,
        )
      : first.call(method, path, query: query, body: body);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File prefs;
  late ProjectApi api;
  late MemoryVault vault;
  late GitHubSession session;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ieum-v020-projects-');
    prefs = File('${dir.path}/preferences.json');
    api = ProjectApi();
    vault = MemoryVault();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: vault),
    );
  });
  tearDown(() async {
    session.signOut();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> rememberOAuth() async {
    final transport = ScriptedOAuth()
      ..responses.addAll([device(), tokens('saved', seconds: null)]);
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(
        vault: vault,
        transport: transport,
        delay: (_) async {},
      ),
    );
    await session.signInOAuth(remember: true, onCode: (_) {});
  }

  Future<SavedProject> seed({String suffix = 'one'}) async {
    if (session.user == null) await session.signIn(token: 'test-only');
    final project = await session.createProject(settings, '첫 프로젝트', '개설자');
    final path = '${dir.path}/$suffix.sqlite';
    final store = TaskStore(
      path,
      project: project,
      identity: session.named('개설자'),
    );
    store.setMeta('github.config', jsonEncode(settings.toJson()));
    store.dispose();
    return SavedProject(
      path: path,
      name: suffix == 'one' ? '첫 프로젝트' : '두 번째 프로젝트',
      projectId: project.id,
      config: settings,
    );
  }

  testWidgets(
    'project settings selector switches context and home keeps selected project',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = await seed();
      final second = await seed(suffix: 'two');
      ProjectCatalog(prefs)
        ..remember('gh-1', second)
        ..remember('gh-1', first);
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectGate(preferences: prefs, session: session),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('project-picker')), findsOneWidget);
      expect(find.byIcon(Icons.home_outlined), findsOneWidget);
      await tester.tap(find.byKey(const Key('sidebar-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
      expect(find.byKey(const Key('settings-navigation')), findsOneWidget);
      expect(find.byKey(const Key('settings-section-picker')), findsNothing);
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('project-option-${second.path}')));
      await tester.pumpAndSettle();
      final active = tester.widget<Workspace>(find.byType(Workspace)).store;
      expect(active.filename, second.path);
      expect(find.byKey(const Key('settings-navigation')), findsOneWidget);
      await tester.tap(find.byKey(const Key('project-home')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Workspace>(find.byType(Workspace)).store,
        same(active),
      );
      expect(find.byKey(const Key('task-list')), findsOneWidget);
      expect(find.byKey(const Key('settings-shell')), findsNothing);
      expect(find.byKey(const Key('project-picker')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  test(
    'catalog isolates accounts and keeps valid backup after damaged primary',
    () {
      final catalog = ProjectCatalog(prefs);
      SavedProject entry(String name) => SavedProject(
        path: '${dir.path}/$name.sqlite',
        name: name,
        projectId: name,
        config: settings,
      );
      catalog.remember('gh-1', entry('one'));
      catalog.remember('gh-2', entry('two'));
      catalog.remember('gh-1', entry('three'));
      expect(catalog.forAccount('gh-1').map((p) => p.name), ['three', 'one']);
      expect(catalog.forAccount('gh-2').single.name, 'two');
      prefs.writeAsStringSync('{broken');
      final recovered = ProjectCatalog(prefs);
      expect(recovered.lastFor('gh-1')!.name, 'one');
      expect(recovered.forAccount('gh-2').single.name, 'two');
      expect(recovered.warning, contains('백업'));
      recovered.remember('gh-1', entry('four'));
      expect(ProjectCatalog(prefs).lastFor('gh-1')!.name, 'four');
      expect(
        jsonDecode(File('${prefs.path}.bak').readAsStringSync())['schema'],
        2,
      );
    },
  );

  test(
    'lost project creation response recovers only same owner and project name',
    () async {
      await session.signIn(token: 'test-only');
      api.loseCreateResponse = true;
      final first = await session.createProject(settings, '첫 프로젝트', '개설자');
      final again = await session.createProject(settings, '첫 프로젝트', '개설자');
      expect(again.id, first.id);
      expect(api.writes, 1);
      await expectLater(
        session.createProject(settings, '다른 프로젝트', '개설자'),
        throwsA(isA<GitHubFailure>()),
      );
      api.identityId = 2;
      api.identityLogin = 'guest';
      await session.signIn(token: 'test-only');
      await expectLater(
        session.createProject(settings, '첫 프로젝트', '다른 개설자'),
        throwsA(isA<GitHubFailure>()),
      );
    },
  );

  test('offline remembered identity is usable locally and revalidated before writes', () async {
    await rememberOAuth();
    session.signOut();
    api.userFailure = 0;
    expect(await session.restoreOAuth(), isTrue);
    expect(session.offline, isTrue);
    expect(session.user!.id, 'gh-1');
    final before = api.writes;
    await expectLater(
      session.createProject(settings, '첫 프로젝트', '개설자'),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, before);
    api.userFailure = -1;
    await session.access(settings);
    expect(session.offline, isFalse);
    session.signOut();
    api.userFailure = 401;
    await expectLater(session.restoreOAuth(), throwsA(isA<GitHubFailure>()));
    expect(session.user, isNull);
    expect(vault.value, isNull);
  });

  test(
    'cached account mismatch after offline restore blocks repository access',
    () async {
      await rememberOAuth();
      session.signOut();
      api.userFailure = 0;
      await session.restoreOAuth();
      api.userFailure = -1;
      api.identityId = 2;
      await expectLater(
        session.access(settings),
        throwsA(isA<GitHubFailure>()),
      );
      expect(session.user, isNull);
      expect(vault.value, isNull);
      expect(api.writes, 0);
    },
  );

  test('old vault with no cached identity remains valid online and fails closed offline', () async {
    await rememberOAuth();
    final stored = Map<String, dynamic>.from(jsonDecode(vault.value!))
      ..remove('identity');
    vault.value = jsonEncode(stored);
    session.signOut();
    api.userFailure = 0;
    await expectLater(session.restoreOAuth(), throwsA(isA<GitHubFailure>()));
    expect(session.user, isNull);
    expect(vault.value, isNotNull);
    api.userFailure = -1;
    expect(await session.restoreOAuth(), isTrue);
    expect(jsonDecode(vault.value!)['identity']['id'], 'gh-1');
  });

  test(
    'malformed membership request is isolated and page two is included',
    () async {
      await session.signIn(token: 'test-only');
      final project = await session.createProject(settings, '첫 프로젝트', '개설자');
      api.identityId = 2;
      api.identityLogin = 'guest';
      await session.signIn(token: 'test-only');
      await session.register(settings, project, '참여자');
      final valid = Map<String, dynamic>.from(api.prs.single);
      final branch = valid['head']['ref'] as String;
      final brokenBranch = '$branch-broken';
      api.refs[brokenBranch] = 'broken-head';
      api.files[brokenBranch] = {
        '.ieum/requests/gh-3.json': {
          'encoding': 'base64',
          'content': base64Encode(utf8.encode('{broken')),
          'sha': 'broken-blob',
        },
      };
      api.prs.clear();
      for (var n = 1; n <= 100; n++) {
        api.prs.add({
          ...valid,
          'number': n,
          'head': {
            ...valid['head'] as Map,
            'ref': n == 1 ? brokenBranch : 'unrelated/$n',
            'sha': n == 1 ? 'broken-head' : valid['head']['sha'],
          },
        });
      }
      api.prs.add({...valid, 'number': 101});
      final requests = await session.requests(settings);
      expect(requests.single['number'], 101);
      expect(session.requestWarnings.single, contains('#1'));
    },
  );

  testWidgets(
    'startup migrates legacy DB and opens last project without onboarding flash',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final project = await seed();
      prefs.writeAsStringSync(
        jsonEncode({
          'path': project.path,
          'repository': settings.slug,
          'base': 'main',
          'branch': '',
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectGate(preferences: prefs, session: session),
        ),
      );
      expect(find.text('내 작업 공간을 준비하고 있어요'), findsOneWidget);
      expect(find.text('이음에 로그인'), findsNothing);
      expect(find.text('프로젝트 시작하기'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(Workspace), findsOneWidget);
      expect(find.byKey(const Key('project-home')), findsOneWidget);
      expect(ProjectCatalog(prefs).lastFor('gh-1')!.path, project.path);
      expect(jsonDecode(prefs.readAsStringSync())['schema'], 2);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'failed project switch preserves current DB and create can return without logout',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final good = await seed();
      final missing = SavedProject(
        path: '${dir.path}/missing.sqlite',
        name: '없는 프로젝트',
        projectId: 'missing',
        config: settings,
      );
      final catalog = ProjectCatalog(prefs)
        ..remember('gh-1', missing)
        ..remember('gh-1', good);
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectGate(preferences: prefs, session: session),
        ),
      );
      await tester.pumpAndSettle();
      final current = tester.widget<Workspace>(find.byType(Workspace)).store;
      if (find.byKey(const Key('project-view-sidebar')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('titlebar-sidebar-toggle')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('project-option-${missing.path}')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Workspace>(find.byType(Workspace)).store,
        same(current),
      );
      expect(catalog.lastFor('gh-1')!.path, good.path);
      expect(find.textContaining('DB 파일이 없습니다.'), findsOneWidget);
      if (find.byKey(const Key('project-view-sidebar')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('titlebar-sidebar-toggle')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-create-menu')));
      await tester.pumpAndSettle();
      expect(find.text('프로젝트 시작하기'), findsOneWidget);
      expect(session.user!.id, 'gh-1');
      await tester.tap(find.byKey(const Key('reopen-project')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Workspace>(find.byType(Workspace)).store,
        same(current),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'remembered login opens existing project offline and keeps local identity',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await rememberOAuth();
      final project = await seed();
      ProjectCatalog(prefs).remember('gh-1', project);
      session.signOut();
      api.userFailure = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectGate(preferences: prefs, session: session),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Workspace), findsOneWidget);
      expect(session.offline, isTrue);
      expect(find.textContaining('오프라인'), findsWidgets);
      expect(
        tester.widget<Workspace>(find.byType(Workspace)).store.filename,
        project.path,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'two repositories switch independently and catalog failure rolls back safely',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pair = TwoProjectApi();
      session = GitHubSession(
        api: pair,
        oauth: GitHubOAuth(vault: vault),
      );
      await session.signIn(token: 'memory-only');
      final entries = <SavedProject>[];
      for (final slug in ['team/data', 'team/second']) {
        final config = GitHubConfig(
          repository: slug,
          enabled: true,
          autoMerge: false,
        );
        final manifest = await session.createProject(config, slug, '개설자');
        final path = '${dir.path}/${slug.split('/').last}.sqlite';
        final store = TaskStore(
          path,
          project: manifest,
          identity: session.named('개설자'),
        );
        store.setMeta('github.config', jsonEncode(config.toJson()));
        store.setMeta(
          'ui.workspace',
          jsonEncode({'page': slug == 'team/data' ? 0 : 1, 'taskView': 'list'}),
        );
        store.dispose();
        entries.add(
          SavedProject(
            path: path,
            name: manifest.name,
            projectId: manifest.id,
            config: config,
          ),
        );
      }
      ProjectCatalog(prefs)
        ..remember('gh-1', entries.last)
        ..remember('gh-1', entries.first);
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectGate(preferences: prefs, session: session),
        ),
      );
      await tester.pumpAndSettle();
      final initialStore = tester
          .widget<Workspace>(find.byType(Workspace))
          .store;
      Directory('${prefs.path}.tmp').createSync();
      Future<void> select(SavedProject entry) async {
        if (find.byKey(const Key('settings-shell')).evaluate().isNotEmpty) {
          await tester.tap(find.byKey(const Key('project-picker')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(ValueKey('project-option-${entry.path}')),
          );
          await tester.pumpAndSettle();
          return;
        }
        if (find.byKey(const Key('project-view-sidebar')).evaluate().isEmpty) {
          await tester.tap(find.byKey(const Key('titlebar-sidebar-toggle')));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byKey(const Key('project-picker')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('project-option-${entry.path}')));
        await tester.pumpAndSettle();
      }

      await select(entries.last);
      expect(
        tester.widget<Workspace>(find.byType(Workspace)).store,
        same(initialStore),
      );
      expect(ProjectCatalog(prefs).lastFor('gh-1')!.path, entries.first.path);
      expect(initialStore.project!.id, entries.first.projectId);
      Directory('${prefs.path}.tmp').deleteSync();
      await select(entries.last);
      final secondStore = tester
          .widget<Workspace>(find.byType(Workspace))
          .store;
      expect(secondStore.filename, entries.last.path);
      expect(secondStore.project!.id, entries.last.projectId);
      expect(ProjectCatalog(prefs).lastFor('gh-1')!.path, entries.last.path);
      await select(entries.first);
      final returned = tester.widget<Workspace>(find.byType(Workspace)).store;
      expect(returned.filename, entries.first.path);
      expect(returned.project!.id, entries.first.projectId);
      expect(returned, isNot(same(initialStore)));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
