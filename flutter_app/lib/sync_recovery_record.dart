import 'dart:convert';

/// A display view of an archived transmission record. Its raw source remains
/// untouched in SQLite, including when the user acknowledges its notice.
class SyncRecoveryRecord {
  const SyncRecoveryRecord({
    required this.index,
    required this.id,
    required this.source,
    required this.recordId,
    required this.createdAt,
    required this.error,
    required this.taskTitle,
  });
  final int index;
  final String id, source, recordId, createdAt, error, taskTitle;

  factory SyncRecoveryRecord.read(int index, String id, String body) {
    try {
      final data = jsonDecode(body) as Map;
      var title = '';
      try {
        final job = jsonDecode(data['raw'] as String) as Map;
        if (job['title'] is String) title = job['title'];
      } catch (_) {
        // An invalid original payload is the reason it was archived.
      }
      String text(String key) => data[key] is String ? data[key] : '';
      return SyncRecoveryRecord(
        index: index,
        id: id,
        source: text('table'),
        recordId: text('recordId'),
        createdAt: text('createdAt'),
        error: text('error'),
        taskTitle: title,
      );
    } catch (_) {
      return SyncRecoveryRecord(
        index: index,
        id: id,
        source: '',
        recordId: '',
        createdAt: '',
        error: '복구 기록의 정보를 읽을 수 없습니다.',
        taskTitle: '',
      );
    }
  }

  String get reason {
    if (error.contains('지원하지 않는 항목') || error.contains('읽을 수 없는 작업 항목')) {
      return '당시 앱에서 지원하지 않는 작업 항목이 포함되어 있었습니다.';
    }
    if (error.contains('FormatException') ||
        error.contains('형식') ||
        error.contains('JSON')) {
      return '전송 기록의 형식이 올바르지 않아 읽을 수 없었습니다.';
    }
    return '전송 기록을 확인하는 과정에서 문제가 발견되었습니다.';
  }
}
