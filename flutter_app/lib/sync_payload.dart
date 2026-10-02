part of 'github_sync.dart';

const _maxTaskJsonBytes = 1024 * 1024;

class _SyncInterrupted implements Exception {
  const _SyncInterrupted();
}

/// Honor GitHub's server-provided retry time, including secondary limits.
Duration? githubRetryDelay(
  int status,
  String? retryAfter,
  String? remaining,
  String? reset, {
  DateTime? now,
  bool rateLimited = false,
}) {
  final clock = now ?? DateTime.now().toUtc();
  if (retryAfter != null) {
    final seconds = int.tryParse(retryAfter);
    if (seconds != null) return Duration(seconds: seconds < 1 ? 1 : seconds);
    try {
      final duration = HttpDate.parse(retryAfter).difference(clock);
      return duration.isNegative ? const Duration(seconds: 1) : duration;
    } catch (_) {}
  }
  if (remaining == '0' && reset != null) {
    final timestamp = int.tryParse(reset);
    if (timestamp != null) {
      final duration =
          DateTime.fromMillisecondsSinceEpoch(
            timestamp * 1000,
            isUtc: true,
          ).difference(clock) +
          const Duration(seconds: 1);
      return duration.isNegative ? const Duration(seconds: 1) : duration;
    }
  }
  return status == 429 || status == 403 && rateLimited
      ? const Duration(minutes: 1)
      : null;
}

Map<String, dynamic> _decodeTaskProposal(dynamic blob, {String? path}) {
  if (blob is! Map ||
      blob['encoding'] != 'base64' ||
      blob['content'] is! String) {
    throw const GitHubFailure('작업 파일 인코딩이 올바르지 않습니다.');
  }
  final encoded = (blob['content'] as String).replaceAll(RegExp(r'\s'), '');
  if (encoded.length > ((_maxTaskJsonBytes + 2) ~/ 3) * 4) {
    throw const GitHubFailure('작업 JSON은 1MB 이하만 지원합니다.');
  }
  final bytes = base64Decode(encoded);
  if (bytes.length > _maxTaskJsonBytes) {
    throw const GitHubFailure('작업 JSON은 1MB 이하만 지원합니다.');
  }
  final raw = jsonDecode(utf8.decode(bytes));
  if (raw is! Map) throw const GitHubFailure('작업 JSON이 올바르지 않습니다.');
  final proposal = Map<String, dynamic>.from(raw);
  _validateTaskProposal(proposal, path: path);
  return proposal;
}

void _validateTaskProposal(Map<String, dynamic> proposal, {String? path}) {
  if (proposal['schemaVersion'] != 1 ||
      proposal['projectId'] is! String ||
      proposal['changes'] is! List ||
      (proposal['changes'] as List).length != 1) {
    throw const GitHubFailure('작업 변경안의 형식이 올바르지 않습니다.');
  }
  final change = (proposal['changes'] as List).single;
  if (change is! Map || change['task'] is! Map) {
    throw const GitHubFailure('작업 변경안의 항목이 올바르지 않습니다.');
  }
  final task = WorkTask.fromJson(Map<String, dynamic>.from(change['task']));
  final expected = path == null ? null : _taskIdAtPath(path);
  if (path != null && (expected == null || expected != task.id) ||
      change['taskId'] != null && change['taskId'] != task.id) {
    throw const GitHubFailure('작업 파일 경로와 작업 ID가 일치하지 않습니다.');
  }
  if (change['base'] != null) {
    if (change['base'] is! Map) throw const GitHubFailure('작업 기준이 올바르지 않습니다.');
    final base = WorkTask.fromJson(Map<String, dynamic>.from(change['base']));
    if (base.id != task.id) throw const GitHubFailure('작업 기준 ID가 다릅니다.');
  }
}

String? _taskIdAtPath(String path) {
  final match = RegExp(
    r'^\.ieum/changes/[A-Za-z0-9_-]+/([A-Za-z0-9_-]{1,80})\.json$',
  ).firstMatch(path);
  return match?.group(1);
}

String? _quarantineTaskId(String path) {
  final name = path.split('/').last;
  final match = RegExp(r'^([A-Za-z0-9_-]{1,80})\.json$').firstMatch(name);
  return match?.group(1);
}

/// Only valid task IDs can affect admission. Non-task filenames remain visible
/// in recovery warnings without preventing unrelated work from progressing.
class _RemoteTasks {
  final tasks = <String, WorkTask>{};
  final blocked = <String>{};
  final warnings = <String>[];
  bool uncertain = false;

  _RemoteTasks(Map<String, dynamic> snapshot, String projectId) {
    for (final raw in snapshot['quarantined'] as List? ?? []) {
      final issue = raw as Map;
      final id = issue['taskId'] as String?;
      if (id != null) {
        blocked.add(id);
      }
      warnings.add('${issue['path']}: ${issue['error']}');
    }
    for (final proposal in snapshot['proposals'] as List) {
      if (proposal['projectId'] != projectId) continue;
      final change = (proposal['changes'] as List).single as Map;
      final task = WorkTask.fromJson(Map<String, dynamic>.from(change['task']));
      final previous = tasks[task.id];
      if (previous != null &&
          previous.version == task.version &&
          !previous.same(task)) {
        blocked.add(task.id);
        warnings.add('${task.id}: 같은 버전에 서로 다른 작업 내용이 있습니다.');
      }
      if (previous == null || task.version > previous.version) {
        tasks[task.id] = task;
      }
    }
    for (final id in blocked) {
      tasks.remove(id);
    }
  }
}
