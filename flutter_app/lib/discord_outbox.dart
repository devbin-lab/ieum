import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'discord_models.dart';

/// A separate, durable external-delivery queue. Received changes never enter it.
class DiscordOutbox {
  DiscordOutbox(this.db);
  final Database db;
  static const _tables = {'discord_events', 'discord_deliveries'};
  static const _safeBody = "CASE WHEN json_valid(body) THEN body ELSE '{}' END";
  static String _field(String name) => "json_extract($_safeBody, '\$.$name')";

  static void initialize(Database db) {
    for (final table in ['discord_events', 'discord_deliveries']) {
      db.execute(
        'CREATE TABLE IF NOT EXISTS $table(id TEXT PRIMARY KEY,body TEXT NOT NULL)',
      );
    }
    for (final entry in {
      'discord_events_state_task': ('discord_events', ['state', 'taskId']),
      'discord_events_revision_actor': (
        'discord_events',
        ['revision', 'actorId'],
      ),
      'discord_deliveries_state': ('discord_deliveries', ['state']),
      'discord_deliveries_event': ('discord_deliveries', ['eventId']),
    }.entries) {
      db.execute(
        'CREATE INDEX IF NOT EXISTS ${entry.key} ON ${entry.value.$1}(${entry.value.$2.map(_field).join(',')})',
      );
    }
  }

  List<Map<String, dynamic>> rows(String table) => _rowsWhere(table);

  List<Map<String, dynamic>> _rowsWhere(
    String table, {
    String where = '1',
    List<Object?> parameters = const [],
    String order = 'rowid DESC',
    int? limit,
  }) {
    if (!_tables.contains(table) || limit != null && limit < 1) {
      throw ArgumentError('Invalid Discord queue query');
    }
    return [
      for (final row in db.select(
        'SELECT body FROM $table WHERE $where ORDER BY $order${limit == null ? '' : ' LIMIT ?'}',
        [...parameters, ?limit],
      ))
        ?_decode(row['body']),
    ];
  }

  List<Map<String, dynamic>> history(
    String table, {
    int limit = 200,
    bool includeCancelled = true,
  }) => _rowsWhere(
    table,
    where: includeCancelled
        ? '1'
        : "COALESCE(${_field('state')},'unknown')!='cancelled'",
    order: '${_field('createdAt')} DESC, rowid DESC',
    limit: limit,
  );

  List<Map<String, dynamic>> waitingEvents({
    String? taskId,
    int? limit,
  }) => _rowsWhere(
    'discord_events',
    where:
        "${_field('state')}='waitingIntegration'${taskId == null ? '' : ' AND ${_field('taskId')}=?'}",
    parameters: [?taskId],
    order: limit == null
        ? 'rowid DESC'
        : '${_field('createdAt')} DESC, rowid DESC',
    limit: limit,
  );

  List<Map<String, dynamic>> pendingDeliveries() => _rowsWhere(
    'discord_deliveries',
    where: "${_field('state')} IN ('ready','retry_wait')",
  );

  Map<String, dynamic>? _byId(String table, String id) =>
      _rowsWhere(table, where: 'id=?', parameters: [id], limit: 1).firstOrNull;

  Map<String, dynamic>? delivery(String id) => _byId('discord_deliveries', id);

  static Map<String, dynamic>? _decode(Object? body) {
    try {
      return Map<String, dynamic>.from(jsonDecode(body as String));
    } catch (_) {
      return null;
    }
  }

  void put(String table, Map<String, dynamic> row) => db.execute(
    'INSERT INTO $table VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
    [row['id'], jsonEncode(row)],
  );

  /// Called inside the task mutation transaction, after local validation.
  void capture({
    required WorkTask task,
    required ProjectManifest project,
    required String actorId,
    required String deviceId,
    required String scope,
    required List<Map<String, dynamic>> routes,
    required String eventType,
    required String at,
    required String statusName,
    String previousStatusName = '',
  }) {
    if (deviceId.isEmpty ||
        routes.isEmpty ||
        task.isDeleted ||
        task.isArchived) {
      return;
    }
    final isTransition =
        eventType == 'task.moved' ||
        eventType == 'task.${task.status}' ||
        const {'task.approved', 'task.rejected'}.contains(eventType);
    final type =
        project.isCompleteStatus(task.status) &&
            (isTransition || eventType == 'task.created')
        ? 'completed'
        : eventType == 'task.created'
        ? 'assigned'
        : const {'task.assigned', 'task.review'}.contains(eventType)
        ? 'handedOff'
        : isTransition && previousStatusName != statusName
        ? 'statusChanged'
        : null;
    if (type == null) return;
    final recipients = discordTaskRecipients(task, project);
    final parts = discordTaskParts(task, project);
    final candidates = routes
        .where(
          (r) =>
              r['enabled'] == true &&
              DiscordRoute.fromJson(r).effectiveEventTypes
                  .any((e) => e.name == type),
        )
        .toList();
    final specific = candidates
        .where(
          (r) =>
              (r['partIds'] as List).isNotEmpty &&
              (r['partIds'] as List).any(parts.contains),
        )
        .toList();
    final selected = specific.isNotEmpty
        ? specific
        : candidates.where((r) => (r['partIds'] as List).isEmpty).toList();
    final uniqueChannels = <String>{};
    selected.removeWhere((r) => !uniqueChannels.add(r['channelId'] as String));
    if (selected.isEmpty) return;
    final pending =
        db
                .select(
                  "SELECT COUNT(*) AS count FROM discord_events WHERE ${_field('state')} NOT IN ('delivered','cancelled')",
                )
                .single['count']
            as int;
    if (pending >= 1000) {
      db.execute(
        'INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
        [
          'discord.queueNotice',
          '알림 대기가 1,000건에 도달했습니다. 작업은 저장되었지만 Discord 알림은 추가되지 않았습니다.',
        ],
      );
      return;
    }
    final id = const Uuid().v4();
    put('discord_events', {
      'id': id,
      'scope': scope,
      'originDeviceId': deviceId,
      'actorId': actorId,
      'taskId': task.id,
      'taskVersion': task.version,
      'task': task.data,
      'type': type,
      'title': task.title,
      'status': statusName,
      if (previousStatusName.isNotEmpty) 'previousStatus': previousStatusName,
      'recipients': recipients.map((p) => p.id).toList(),
      'recipientNames': recipients.map((p) => p.name).toList(),
      'routes': selected,
      'state': 'waitingIntegration',
      'createdAt': at,
      'revision': '',
    });
  }

  void bind(WorkTask task, String revision, ProjectManifest? project) {
    final waiting = waitingEvents(taskId: task.id);
    final captured = waiting.any((e) => e['taskVersion'] == task.version);
    var carried = false;
    for (final event in waiting) {
      if (event['taskVersion'] == task.version) {
        put('discord_events', {...event, 'revision': revision});
      } else if ((event['taskVersion'] as int) < task.version) {
        final previous = WorkTask.fromJson(
          Map<String, dynamic>.from(event['task']),
        );
        final currentRecipients = project == null
            ? <String>{}
            : discordTaskRecipients(task, project).map((p) => p.id).toSet();
        final savedRecipients = (event['recipients'] as List)
            .cast<String>()
            .toSet();
        if (!captured &&
            !carried &&
            !task.isDeleted &&
            !task.isArchived &&
            task.status == previous.status &&
            task.workflowTarget == previous.workflowTarget &&
            task.workflowPerson == previous.workflowPerson &&
            currentRecipients.length == savedRecipients.length &&
            currentRecipients.containsAll(savedRecipients)) {
          // A plain edit before integration updates the same notification.
          put('discord_events', {
            ...event,
            'task': task.data,
            'taskVersion': task.version,
            'title': task.title,
            'revision': revision,
          });
          carried = true;
          continue;
        }
        put('discord_events', {
          ...event,
          'state': 'cancelled',
          'error': '다음 저장에 포함된 변경입니다.',
        });
      }
    }
  }

  /// Only an exact own proposal accepted on the integration branch is eligible.
  void integrated(Map<String, dynamic> job, String actorId) {
    final proposal = job['proposal'] as Map;
    if (proposal['authorId'] != actorId ||
        job['state'] != 'merged' ||
        (job['commitSha'] as String? ?? '').isEmpty) {
      return;
    }
    final changes = proposal['changes'] as List;
    if (changes.length != 1) return;
    final task = WorkTask.fromJson(
      Map<String, dynamic>.from(changes.single['task']),
    );
    for (final event in _rowsWhere(
      'discord_events',
      where:
          "${_field('actorId')}=? AND ${_field('taskId')}=? AND ${_field('revision')}=? AND ${_field('state')}='waitingIntegration'",
      parameters: [actorId, task.id, job['revision']],
    )) {
      if (!task.same(
        WorkTask.fromJson(Map<String, dynamic>.from(event['task'])),
      )) {
        continue;
      }
      for (final route in event['routes'] as List) {
        final deliveryId = '${event['id']}:${route['channelId']}';
        db.execute('INSERT OR IGNORE INTO discord_deliveries VALUES (?,?)', [
          deliveryId,
          jsonEncode({
            'id': deliveryId,
            'eventId': event['id'],
            'route': route,
            'state': 'ready',
            'attempts': 0,
            'createdAt': event['createdAt'],
            'error': '',
          }),
        ]);
      }
      put('discord_events', {...event, 'state': 'ready'});
    }
  }

  void recoverInterrupted() {
    for (final row in _rowsWhere(
      'discord_deliveries',
      where: "${_field('state')}='sending'",
    )) {
      put('discord_deliveries', {
        ...row,
        'state': 'uncertain',
        'error': '전송 중 앱이 종료되어 수신 여부를 확인하지 못했습니다.',
      });
    }
  }

  Map<String, dynamic>? event(String id) => _byId('discord_events', id);

  bool claim(Map<String, dynamic> row) {
    final original = jsonEncode(row);
    final next = {
      ...row,
      'state': 'sending',
      'attempts': (row['attempts'] as int? ?? 0) + 1,
      'error': '',
    };
    db.execute('UPDATE discord_deliveries SET body=? WHERE id=? AND body=?', [
      jsonEncode(next),
      row['id'],
      original,
    ]);
    return db.updatedRows == 1;
  }

  void settle(Map<String, dynamic> row) {
    put('discord_deliveries', row);
    final eventId = row['eventId'] as String;
    final item = event(eventId);
    if (item == null) return;
    final unsettled = db.select(
      "SELECT 1 FROM discord_deliveries WHERE ${_field('eventId')}=? AND COALESCE(${_field('state')},'unknown') NOT IN ('delivered','cancelled') LIMIT 1",
      [eventId],
    );
    if (unsettled.isEmpty) {
      put('discord_events', {
        ...item,
        'state': 'delivered',
        'settledAt': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  void retry(String id, {required bool confirmedUncertain}) {
    final item = delivery(id);
    if (item == null ||
        !const {'failed', 'blocked', 'uncertain'}.contains(item['state'])) {
      return;
    }
    if (item['state'] == 'uncertain' && !confirmedUncertain) {
      throw StateError('중복 전송 가능성을 확인하세요.');
    }
    put('discord_deliveries', {
      ...item,
      'state': 'ready',
      'retryAt': '',
      'error': '',
      'attempts': 0,
    });
  }

  void cancel(String id) {
    if (id.startsWith('event:')) {
      final item = event(id.substring(6));
      if (item != null && item['state'] == 'waitingIntegration') {
        put('discord_events', {...item, 'state': 'cancelled', 'error': ''});
      }
      return;
    }
    final item = delivery(id);
    if (item == null ||
        const {'sending', 'delivered'}.contains(item['state'])) {
      return;
    }
    settle({...item, 'state': 'cancelled', 'error': ''});
  }

  /// Terminal records are bounded; no received PR regenerates older candidates.
  void prune() {
    final now = DateTime.now();
    final compactCutoff = now
        .subtract(const Duration(days: 30))
        .toUtc()
        .toIso8601String();
    final cutoff = now
        .subtract(const Duration(days: 180))
        .toUtc()
        .toIso8601String();
    for (final table in _tables) {
      db.execute(
        "DELETE FROM $table WHERE ${_field('state')} IN ('delivered','cancelled') AND ${_field('createdAt')} < ?",
        [cutoff],
      );
    }
    db.execute(
      "UPDATE discord_events SET body=json_remove(body, '\$.task') WHERE ${_field('state')} IN ('delivered','cancelled') AND ${_field('createdAt')} < ? AND json_type($_safeBody, '\$.task') IS NOT NULL",
      [compactCutoff],
    );
    for (final table in _tables) {
      db.execute(
        "DELETE FROM $table WHERE id IN (SELECT id FROM $table WHERE ${_field('state')} IN ('delivered','cancelled') ORDER BY rowid DESC LIMIT -1 OFFSET 2000)",
      );
    }
  }
}

List<Person> discordTaskRecipients(WorkTask task, ProjectManifest project) {
  final explicit = task.workflowPerson.isNotEmpty
      ? task.workflowPerson
      : task.workflowTarget == 'legacy'
      ? task.currentId
      : '';
  if (explicit.isNotEmpty) {
    return project.people.where((p) => p.active && p.id == explicit).toList();
  }
  if (task.workflowTarget.startsWith('part:')) {
    return project.people
        .where(
          (p) =>
              p.active &&
              workflowGroupContains(task.workflowTarget, p, project),
        )
        .toList();
  }
  if (task.workflowTarget == 'role:owner') {
    return project.people
        .where((p) => p.active && p.id == project.ownerId)
        .toList();
  }
  return const []; // An unrestricted task does not ping the entire server.
}

Set<String> discordTaskParts(WorkTask task, ProjectManifest project) {
  if (task.workflowTarget.startsWith('part:')) {
    return {task.workflowTarget.substring(5)};
  }
  final names = discordTaskRecipients(
    task,
    project,
  ).expand((p) => p.parts).toSet();
  return project.roles
      .where((r) => names.contains(r.name))
      .map((r) => r.id)
      .toSet();
}
