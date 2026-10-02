import 'models.dart';
import 'project_catalog.dart';
import 'project_service.dart';

String profileTarget(SavedProject project) =>
    '${project.config.slug}|${project.projectId}';

/// Keep failed targets on disk so restarting the app cannot lose a rename.
Future<String> renameParticipatingProjects(
  ProjectCatalog catalog,
  GitHubSession session,
  String name, {
  void Function(SavedProject, ProjectManifest)? onProject,
}) async {
  final account = session.user!.id;
  final entries = {
    for (final p in catalog.forAccount(account)) profileTarget(p): p,
  };
  catalog.setName(account, name, entries.keys.toList());
  final pending = entries.keys.toSet();
  final failures = <String>[];
  for (final entry in entries.values) {
    try {
      if (session.user?.id != account) throw StateError('로그인 계정이 변경되었습니다.');
      final project = await session.rename(
        entry.config,
        name,
        expectedProjectId: entry.projectId,
      );
      onProject?.call(entry, project);
      pending.remove(profileTarget(entry));
      catalog.setName(account, name, pending.toList());
    } catch (e) {
      failures.add('${entry.name}: $e');
    }
  }
  return failures.isEmpty
      ? '참여 중인 ${entries.length}개 프로젝트에 이름을 반영했습니다.'
      : '일부 프로젝트는 전송 대기 중입니다. 다음에 열 때 다시 전송합니다.\n${failures.join('\n')}';
}
