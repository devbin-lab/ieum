import 'dart:convert';
import 'dart:io';

import 'github_sync.dart';

class SavedProject {
  const SavedProject({
    required this.path,
    required this.name,
    required this.projectId,
    required this.config,
  });
  final String path, name, projectId;
  final GitHubConfig config;
  Map<String, dynamic> get json => {
    'path': path,
    'name': name,
    'projectId': projectId,
    ...config.toJson(),
  };
  factory SavedProject.fromJson(Map<String, dynamic> value) {
    final path = value['path'], name = value['name'], id = value['projectId'];
    if (path is! String ||
        path.isEmpty ||
        name is! String ||
        name.isEmpty ||
        id is! String ||
        id.isEmpty ||
        !File(path).isAbsolute) {
      throw const FormatException('프로젝트 목록 형식이 올바르지 않습니다.');
    }
    final config = GitHubConfig.fromJson(value);
    config.validate();
    return SavedProject(path: path, name: name, projectId: id, config: config);
  }
}

/// Credentials never belong here. Projects are scoped to the verified GitHub ID.
class ProjectCatalog {
  ProjectCatalog(this.file) {
    _read();
  }
  final File file;
  final Map<String, List<SavedProject>> _accounts = {};
  final Map<String, String> _last = {};
  final Map<String, String> _names = {};
  final Map<String, List<String>> _pendingNames = {};
  String? nameFor(String id) => _names[id];
  List<String> pendingNames(String id) =>
      List.unmodifiable(_pendingNames[id] ?? []);
  Map<String, dynamic>? legacy;
  String warning = '';
  List<SavedProject> forAccount(String id) =>
      List.unmodifiable(_accounts[id] ?? []);
  SavedProject? lastFor(String id) {
    final entries = forAccount(id);
    if (entries.isEmpty) return null;
    return entries.firstWhere(
      (p) => p.path == _last[id],
      orElse: () => entries.first,
    );
  }

  void _read() {
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!candidate.existsSync()) continue;
      try {
        final raw = Map<String, dynamic>.from(
          jsonDecode(candidate.readAsStringSync()),
        );
        if (raw['schema'] == 2 && raw['accounts'] is Map) {
          for (final entry in (raw['accounts'] as Map).entries) {
            if (!RegExp(r'^gh-[0-9]+$').hasMatch('${entry.key}') ||
                entry.value is! Map) {
              continue;
            }
            final value = entry.value as Map;
            final projects = <SavedProject>[];
            for (final item
                in value['projects'] is List ? value['projects'] as List : []) {
              try {
                projects.add(
                  SavedProject.fromJson(Map<String, dynamic>.from(item)),
                );
              } catch (_) {
                warning = '일부 프로젝트 정보가 손상되어 목록에서 제외했습니다. DB 파일은 보존됩니다.';
              }
            }
            _accounts[entry.key as String] = projects;
            _last[entry.key as String] = value['lastPath'] as String? ?? '';
            if (value['displayName'] is String) {
              _names[entry.key as String] = value['displayName'];
            }
            _pendingNames[entry.key as String] = List<String>.from(
              value['pendingNames'] ?? [],
            );
          }
          if (raw['legacy'] is Map) {
            legacy = Map<String, dynamic>.from(raw['legacy']);
          }
        } else if (raw['path'] is String && raw['repository'] is String) {
          legacy = raw;
        } else {
          throw const FormatException();
        }
        if (candidate.path != file.path) {
          warning = '프로젝트 목록을 백업에서 복구했습니다. 로컬 DB는 그대로 사용할 수 있습니다.';
        }
        return;
      } catch (_) {
        _accounts.clear();
        _last.clear();
        _names.clear();
        _pendingNames.clear();
        warning = '프로젝트 목록을 읽지 못했습니다. 기존 DB 폴더로 다시 참여하면 데이터를 복구할 수 있습니다.';
      }
    }
  }

  void remember(
    String accountId,
    SavedProject project, {
    bool migrateLegacy = false,
  }) {
    if (!RegExp(r'^gh-[0-9]+$').hasMatch(accountId)) {
      throw const FormatException('계정 ID 오류');
    }
    final entries = [
      project,
      ...forAccount(accountId).where((p) => p.path != project.path),
    ];
    _persist(accountId, entries, project.path, migrateLegacy: migrateLegacy);
    _accounts[accountId] = entries;
    _last[accountId] = project.path;
    if (migrateLegacy) legacy = null;
  }

  void setName(String accountId, String name, List<String> pending) {
    if (!RegExp(r'^gh-[0-9]+$').hasMatch(accountId) ||
        name.trim().isEmpty ||
        name.length > 40) {
      throw const FormatException('이름을 확인하세요.');
    }
    final previousName = _names[accountId];
    final previousPending = _pendingNames[accountId];
    _names[accountId] = name.trim();
    _pendingNames[accountId] = List.of(pending);
    try {
      _persist(accountId, forAccount(accountId), _last[accountId] ?? '');
    } catch (_) {
      if (previousName == null) {
        _names.remove(accountId);
      } else {
        _names[accountId] = previousName;
      }
      if (previousPending == null) {
        _pendingNames.remove(accountId);
      } else {
        _pendingNames[accountId] = previousPending;
      }
      rethrow;
    }
  }

  void _persist(
    String accountId,
    List<SavedProject> entries,
    String lastPath, {
    bool migrateLegacy = false,
  }) {
    final data = <String, dynamic>{
      'schema': 2,
      'accounts': {
        for (final id in {..._accounts.keys, accountId})
          id: {
            'lastPath': id == accountId ? lastPath : _last[id],
            'displayName': _names[id],
            'pendingNames': _pendingNames[id] ?? [],
            'projects': (id == accountId ? entries : forAccount(id))
                .map((p) => p.json)
                .toList(),
          },
      },
      if (!migrateLegacy && legacy != null) 'legacy': legacy,
    };
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(jsonEncode(data), flush: true);
    // Keep the last valid catalog even when the main file was already corrupt.
    if (file.existsSync()) {
      try {
        final previous = jsonDecode(file.readAsStringSync());
        if (previous is Map &&
            (previous['schema'] == 2 || previous['path'] is String)) {
          file.copySync('${file.path}.bak');
        }
      } catch (_) {}
    }
    temporary.renameSync(file.path);
  }
}
