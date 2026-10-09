import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'part_workflow_test_fixtures.dart';

const _config = GitHubConfig(
  repository: 'team/data',
  enabled: true,
  autoMerge: false,
);
const _wiki = ProjectShortcut(
  id: 'team-wiki',
  name: '팀 위키',
  url: 'https://team.notion.site/wiki',
  service: 'notion',
  description: '작성한 문서',
  iconUrl: 'https://images.example.com/team-wiki.png',
);

class _ShortcutRaceApi extends FakeGitHubApi {
  bool race = false, replaceLinks = false;
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (race &&
        method == 'PUT' &&
        body?['message'] == 'Update IEUM project shortcuts') {
      race = false;
      final row = files['main']!['.ieum/project.json']!;
      final data = jsonDecode(
        utf8.decode(base64Decode(row['content'])),
      ) as Map<String, dynamic>;
      final next = {
        ...data,
        if (replaceLinks) 'shortcuts': [] else 'name': '다른 팀원이 수정한 이름',
      };
      await super.call(
        method,
        path,
        body: {
          ...body!,
          'sha': row['sha'],
          'message': 'Peer edit',
          'content': base64Encode(utf8.encode(jsonEncode(next))),
        },
      );
      throw const GitHubFailure('sha changed', 409);
    }
    return super.call(method, path, query: query, body: body);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old manifests keep links empty and catalog does not seed data', () {
    final project = ProjectManifest.fromJson(personalReviewProject.json);
    final store = TaskStore(':memory:', project: project, identity: routeOwner);
    addTearDown(store.dispose);
    expect(project.shortcuts, isNull);
    final entries = effectiveProjectShortcuts(
      project.shortcuts,
      repository: 'team/data',
    );
    expect(entries, isEmpty);
    expect(defaultProjectShortcuts, hasLength(8));
    expect(
      defaultProjectShortcuts.map((entry) => entry.service),
      containsAll([
        'drive',
        'notion',
        'jira',
        'discord',
        'kakao',
        'github',
        'figma',
        'slack',
      ]),
    );
    for (final entry in defaultProjectShortcuts) {
      expect(ProjectShortcut.fromJson(entry.json).url, entry.url);
    }
    expect(store.project!.shortcuts, isNull);
    expect(store.tasks, isEmpty);
    expect(store.changes, isEmpty);
    expect(store.db.select('SELECT * FROM github_queue'), isEmpty);
  });

  test('optional icon URLs preserve old links and reject unsafe images', () {
    final legacy = {..._wiki.json}..remove('iconUrl');
    final oldEntry = ProjectShortcut.fromJson(legacy);
    expect(oldEntry.iconUrl, isNull);
    expect(oldEntry.json, isNot(contains('iconUrl')));
    expect(
      ProjectShortcut.fromJson({...legacy, 'iconUrl': null}).json,
      oldEntry.json,
    );
    final image = ProjectShortcut.fromJson({
      ...legacy,
      'iconUrl': ' images.example.com/team-wiki.png ',
    });
    expect(image.iconUrl, 'https://images.example.com/team-wiki.png');
    expect(ProjectShortcut.fromJson(image.json).json, image.json);
    for (final value in [
      'http://images.example.com/icon.png',
      'https://user:password@images.example.com/icon.png',
      'file:///c:/icon.png',
      'javascript:alert(1)',
      'https://images.example.com/icon\n.png',
      'https://images.example.com/${'x' * 2048}',
      '',
      42,
    ]) {
      expect(
        () => ProjectShortcut.fromJson({...legacy, 'iconUrl': value}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '올바른 HTTPS 아이콘 주소를 입력해 주세요.',
          ),
        ),
        reason: '$value',
      );
    }
  });

  test(
    'saved links survive view migrations and reopening; empty stays empty',
    () {
      final dir = Directory.systemTemp.createTempSync('ieum-shortcuts-test-');
      final path = '${dir.path}/project.sqlite';
      addTearDown(() {
        expect(dir.parent.absolute.path, Directory.systemTemp.absolute.path);
        dir.deleteSync(recursive: true);
      });
      final project = ProjectManifest.fromJson({
        ...personalReviewProject.json,
        'shortcuts': [_wiki.json],
      });
      expect(project.partWorkflowView.shortcuts!.single.json, _wiki.json);
      final legacy = ProjectManifest.fromJson({
        ...project.json,
        'partsUnified': false,
      });
      expect(legacy.unifiedView.shortcuts!.single.json, _wiki.json);
      final first = TaskStore(path, project: project, identity: routeOwner);
      first.dispose();
      final reopened = TaskStore(path);
      expect(reopened.project!.shortcuts!.single.json, _wiki.json);
      reopened.updateProject(
        ProjectManifest.fromJson({...project.json, 'shortcuts': []}),
      );
      reopened.dispose();
      final empty = TaskStore(path);
      try {
        expect(effectiveProjectShortcuts(empty.project!.shortcuts), isEmpty);
        expect(empty.tasks, isEmpty);
        expect(empty.changes, isEmpty);
      } finally {
        empty.dispose();
      }
    },
  );

  test('URL and collection validation rejects unsafe or malformed links', () {
    expect(
      normalizeShortcutUrl(' team.notion.site/wiki?q=hello%20world#intro '),
      'https://team.notion.site/wiki?q=hello%20world#intro',
    );
    for (final url in [
      'javascript:alert(1)',
      'file:///c:/secret',
      'http://example.com',
      'https://user:password@example.com/',
      'https://',
      'https://host:99999/',
      'https://example.com/\nscript',
      '',
    ]) {
      expect(() => normalizeShortcutUrl(url), throwsStateError, reason: url);
    }
    expect(
      () => readProjectShortcuts([_wiki.json, _wiki.json]),
      throwsStateError,
    );
    expect(
      () => readProjectShortcuts([
        {'id': 'missing-fields'},
      ]),
      throwsStateError,
    );
    expect(
      () => readProjectShortcuts(List.filled(61, _wiki.json)),
      throwsStateError,
    );
  });

  test(
    'service inference respects domain boundaries and valid HTTPS links',
    () {
      const supported = {
        'https://drive.google.com/drive/folders/team': 'drive',
        'https://docs.google.com/document/d/team/edit': 'drive',
        'https://team.notion.site/wiki': 'notion',
        'https://www.notion.so/team/page': 'notion',
        'https://www.notion.com/login': 'notion',
        'https://team.atlassian.net/jira/software/projects/TEAM': 'jira',
        'https://home.atlassian.com/': 'jira',
        'https://discord.com/channels/team/channel': 'discord',
        'https://discord.gg/team': 'discord',
        'https://open.kakao.com/o/team': 'kakao',
        'https://www.kakaocorp.com/page/service/service/KakaoTalk': 'kakao',
        'https://github.com/team/repository': 'github',
        'https://www.figma.com/design/team': 'figma',
        'https://team.slack.com/archives/channel': 'slack',
      };
      for (final entry in supported.entries) {
        expect(inferShortcutService(entry.key), entry.value, reason: entry.key);
      }
      for (final url in [
        'https://github.com.evil.test/team',
        'https://evilgithub.com/team',
        'https://notion.site.evil.test/wiki',
        'https://drive.google.com.evil.test/folder',
        'https://example.com/path/github.com',
        'http://github.com/team',
        'https://user:password@github.com/team',
        'javascript:alert(1)',
        '',
      ]) {
        expect(inferShortcutService(url), 'custom', reason: url);
      }
      const inferred = ProjectShortcut(
        id: 'inferred',
        name: '저장소',
        url: 'https://github.com/team/repository',
      );
      expect(inferred.resolvedService, 'github');
      expect(inferred.json['service'], 'custom');
      const explicit = ProjectShortcut(
        id: 'explicit',
        name: '팀 링크',
        url: 'https://github.com/team/repository',
        service: 'notion',
      );
      expect(explicit.resolvedService, 'notion');
    },
  );

  test(
    'service home detection never labels configured team links as starters',
    () {
      for (final starter in defaultProjectShortcuts) {
        expect(isShortcutServiceHome(starter), isTrue, reason: starter.name);
        final trailing = ProjectShortcut(
          id: starter.id,
          name: starter.name,
          url: '${starter.url.replaceFirst(RegExp(r'/+$'), '')}/',
        );
        expect(isShortcutServiceHome(trailing), isTrue, reason: starter.name);
      }
      for (final url in [
        'https://github.com/team/repository',
        'https://drive.google.com/drive/folders/team',
        'https://team.notion.site/wiki',
        'https://www.notion.com/team-page',
        'https://discord.com/channels/team/channel',
        'https://team.atlassian.net/jira/software/projects/TEAM',
        'https://app.slack.com/client/team/channel',
        'https://www.figma.com/design/team',
        'https://open.kakao.com/o/team',
        'https://github.com/?team=repository',
      ]) {
        final entry = ProjectShortcut(id: 'team', name: '팀 링크', url: url);
        expect(isShortcutServiceHome(entry), isFalse, reason: url);
      }
      expect(effectiveProjectShortcuts(null, repository: 'team/data'), isEmpty);
      const github = ProjectShortcut(
        id: 'starter-github',
        name: '팀 저장소',
        service: 'github',
        url: 'https://github.com/team/data',
      );
      final configured = [github];
      expect(
        effectiveProjectShortcuts(configured, repository: 'other/repository'),
        same(configured),
      );
      expect(isShortcutServiceHome(github), isFalse);
    },
  );

  test(
    'shared saves preserve unrelated metadata and reject stale link lists',
    () async {
      final api = _ShortcutRaceApi();
      final session = GitHubSession(
        api: api,
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      addTearDown(session.signOut);
      await session.signIn(token: 'test-only');
      final initial = await session.createProject(_config, '프로젝트', '개설자');
      api.race = true;
      final saved = await session.saveShortcuts(
        _config,
        [_wiki],
        expectedProjectId: initial.id,
        expectedShortcuts: null,
      );
      expect(saved.name, '다른 팀원이 수정한 이름');
      expect(saved.shortcuts!.single.json, _wiki.json);
      expect(
        (await session.loadProject(_config)).shortcuts!.single.json,
        _wiki.json,
      );
      final before = api.writes;
      await expectLater(
        session.saveShortcuts(
          _config,
          [],
          expectedProjectId: initial.id,
          expectedShortcuts: null,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, before);
      api.race = true;
      api.replaceLinks = true;
      await expectLater(
        session.saveShortcuts(
          _config,
          [_wiki],
          expectedProjectId: initial.id,
          expectedShortcuts: saved.shortcuts,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect((await session.loadProject(_config)).shortcuts, isEmpty);
    },
  );

  test(
    'active participants can maintain links; revoked participants cannot',
    () async {
      final api = FakeGitHubApi();
      final session = GitHubSession(
        api: api,
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      addTearDown(session.signOut);
      await session.signIn(token: 'test-only');
      final initial = await session.createProject(_config, '프로젝트', '개설자');
      final shared = await session.changeManifest(
        _config,
        'Test participant',
        (project, actor) async => ProjectManifest.fromJson({
          ...project.json,
          'members': [
            ...project.people.map((person) => person.json),
            const Person(
              'gh-2',
              '팀원',
              '팀',
              'unassigned',
              0,
              login: 'guest',
            ).json,
          ],
        }),
      );
      session.signOut();
      api.identityId = 2;
      api.identityLogin = 'guest';
      await session.signIn(token: 'participant-test-only');
      final saved = await session.saveShortcuts(
        _config,
        [_wiki],
        expectedProjectId: initial.id,
        expectedShortcuts: shared.shortcuts,
      );
      expect(saved.shortcuts!.single.id, _wiki.id);
      final disabled = ProjectManifest.fromJson({
        ...saved.json,
        'members': [
          for (final person in saved.people)
            {...person.json, if (person.id == 'gh-2') 'enabled': false},
        ],
      });
      final row = await session.readJson(_config, '.ieum/project.json');
      await session.writeJson(
        _config,
        '.ieum/project.json',
        disabled.json,
        sha: row!['sha'],
        message: 'Test revocation',
      );
      final before = api.writes;
      await expectLater(
        session.saveShortcuts(
          _config,
          [],
          expectedProjectId: initial.id,
          expectedShortcuts: saved.shortcuts,
        ),
        throwsA(isA<GitHubFailure>()),
      );
      expect(api.writes, before);
    },
  );
}
