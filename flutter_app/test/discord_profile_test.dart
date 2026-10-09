import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = GitHubConfig(repository: 'team/data', enabled: true);
  late FakeGitHubApi api;
  late GitHubSession session;
  late ProjectManifest project;
  setUp(() async {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn(token: 'memory-only');
    project = await session.createProject(config, 'Project', 'Owner');
    final remote = await session.readJson(config, '.ieum/project.json');
    project = ProjectManifest.fromJson({
      ...project.json,
      'members': [
        ...project.people.map((p) => p.json),
        {
          'id': 'gh-2',
          'name': 'Member',
          'login': 'guest',
          'role': 'unassigned',
          'parts': <String>[],
        },
      ],
    });
    await session.writeJson(
      config,
      '.ieum/project.json',
      project.json,
      sha: remote!['sha'],
      message: 'Fixture members',
    );
  });
  tearDown(() => session.signOut());

  test(
    'legacy member data remains compatible and owner can register own ID',
    () async {
      expect(
        project.people.every((p) => !p.json.containsKey('discordUserId')),
        isTrue,
      );
      final updated = await session.setOwnDiscordUserId(
        config,
        '123456789012345678',
        expectedProjectId: project.id,
      );
      expect(updated.people.first.discordUserId, '123456789012345678');
      expect(updated.people.last.discordUserId, isEmpty);
      expect(
        updated.people.first.resolved(updated.roles).discordUserId,
        '123456789012345678',
      );
      final cleared = await session.setOwnDiscordUserId(
        config,
        '',
        expectedProjectId: project.id,
      );
      expect(cleared.people.first.discordUserId, isEmpty);
    },
  );

  test('active participant updates only own mapping without management permissions', () async {
    await session.setOwnDiscordUserId(
      config,
      '123456789012345678',
      expectedProjectId: project.id,
    );
    api.identityId = 2;
    api.identityLogin = 'guest';
    await session.signIn(token: 'memory-only');
    final updated = await session.setOwnDiscordUserId(
      config,
      '234567890123456789',
      expectedProjectId: project.id,
    );
    expect(updated.people.first.discordUserId, '123456789012345678');
    expect(updated.people.last.discordUserId, '234567890123456789');
  });

  test('invalid ID and wrong project cannot overwrite mappings', () async {
    final writes = api.writes;
    expect(
      () => session.setOwnDiscordUserId(
        config,
        'nickname',
        expectedProjectId: project.id,
      ),
      throwsStateError,
    );
    await expectLater(
      session.setOwnDiscordUserId(
        config,
        '123456789012345678',
        expectedProjectId: 'different',
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
  });
}
