import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_service.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new projects contain six statuses without automated routes or preset parts', () async {
    final api = FakeGitHubApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    addTearDown(session.signOut);
    await session.signIn();
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    final created = await session.createProject(config, '기본 프로젝트', '개설자');
    final loaded = await session.loadProject(config);
    expect(loaded.id, created.id);
    expect(loaded.workflowStages.map((stage) => stage.name), [
      '확인중',
      '진행중',
      '검토중',
      '완료',
      '보류',
      '드랍',
    ]);
    expect(loaded.workflowSheet!.routes, isEmpty);
    expect(loaded.parts, isEmpty);
    expect(loaded.roles, isEmpty);
  });
}
