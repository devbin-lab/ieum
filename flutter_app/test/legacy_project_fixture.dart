import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';

/// Seeds historical repository metadata through the tests' fake GitHub API.
/// Legacy data remains readable; these writes do not expose retired app APIs.
Future<ProjectManifest> writeLegacyProjectFixture(
  GitHubSession session,
  GitHubConfig config, {
  required Map<String, dynamic> overrides,
}) async {
  final file = (await session.readJson(config, '.ieum/project.json'))!;
  final fixture = ProjectManifest.fromJson({
    ...Map<String, dynamic>.from(file['data']),
    ...overrides,
  });
  await session.writeJson(
    config,
    '.ieum/project.json',
    fixture.json,
    sha: file['sha'],
    message: 'Historical project fixture',
  );
  return fixture.partWorkflowView;
}
