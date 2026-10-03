import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';

class MergeResult {
  final bool applied;
  final List<Map<String, dynamic>> conflicts;
  const MergeResult(this.applied, this.conflicts);
}

class TaskStore extends ChangeNotifier {
  final Database db;
  final String filename;
  TaskStore(
    this.filename, {
    List<dynamic> seed = const [],
    ProjectManifest? project,
    Person? identity,
  }) : db = sqlite3.open(filename) {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA busy_timeout=3000');
    for (final name in ['tasks', 'baseline_tasks']) {
      db.execute(
        'CREATE TABLE IF NOT EXISTS $name(id TEXT PRIMARY KEY,body TEXT NOT NULL)',
      );
    }
    db.execute(
      'CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)',
    );
    for (final name in [
      'activity',
      'notification_outbox',
      'notification_inbox',
      'github_queue',
      'github_sent',
      'conflict_backups',
      'sync_recovery',
    ]) {
      db.execute(
        'CREATE TABLE IF NOT EXISTS $name(id TEXT PRIMARY KEY,body TEXT NOT NULL)',
      );
    }
    if (meta('initialized').isEmpty) {
      transaction(() {
        setMeta('initialized', '1');
        setMeta('profile', 'planner');
        setMeta('projectId', 'ieum-demo');
        setMeta('baseRevision', 'demo-initial');
        for (final raw in seed) {
          final t = WorkTask.fromJson(Map<String, dynamic>.from(raw));
          put(t);
          put(t, table: 'baseline_tasks');
        }
      });
    }
    if (project != null) {
      if (meta('project').isNotEmpty && meta('projectId') != project.id) {
        db.close();
        throw StateError('다른 프로젝트의 DB입니다. 새 폴더를 선택하세요.');
      }
      transaction(() {
        setMeta('project', jsonEncode(project.json));
        setMeta('projectId', project.id);
        if (identity != null) {
          setMeta('identity', jsonEncode(identity.json));
          setMeta('profile', identity.id);
        }
      });
    }
  }
  bool get isProject => meta('project').isNotEmpty;
  ProjectManifest? get project => isProject
      ? ProjectManifest.fromJson(
          Map<String, dynamic>.from(jsonDecode(meta('project'))),
        )
      : null;
  List<Person> get people {
    if (!isProject) return members;
    final list = [...project!.people];
    if (!list.any((p) => p.id == profileId) && meta('identity').isNotEmpty) {
      final self = Person.fromJson(
        Map<String, dynamic>.from(jsonDecode(meta('identity'))),
      );
      list.add(
        Person(
          self.id,
          self.name,
          self.initials,
          'pending',
          self.color,
          login: self.login,
        ),
      );
    }
    return list;
  }

  Person member(String id) => people.firstWhere(
    (p) => p.id == id,
    orElse: () => Person(id, '미등록 참여자', '?', 'disabled', 0xff9990a5),
  );
  Person get actor => member(profileId);
  bool get manages => actor.manages;
  bool get owns => actor.role == 'owner';
  bool get canCreate => !isProject || actor.has('task.create');
  bool canEdit(WorkTask task) => canEditTask(actor, task);
  bool canEditContent(WorkTask task) => canEditTaskContent(actor, task);
  String editLockReason(WorkTask task) => task.status == 'done'
      ? '완료된 작업은 수정할 수 없습니다. 변경이 필요하면 새 작업을 등록하세요.'
      : task.status == 'review'
      ? '검토 결과를 기다리는 중입니다. 제출 내용은 잠겨 있으며 조회할 수 있습니다.'
      : '본인 담당 작업 또는 전체 작업 수정 권한이 필요합니다.';
  List<PartRule> get partRules => !isProject
      ? rules
      : rules.map((r) {
          final candidates =
              people
                  .where(
                    (p) => p.active && p.canWork && p.parts.contains(r.part),
                  )
                  .toList()
                ..sort(
                  (a, b) => (a.role == 'worker' ? 0 : 1).compareTo(
                    b.role == 'worker' ? 0 : 1,
                  ),
                );
          return PartRule(
            r.part,
            candidates.isEmpty ? project!.ownerId : candidates.first.id,
            project!.ownerId,
            r.nextPart,
          );
        }).toList();
  void updateProject(ProjectManifest value) {
    if (!isProject ||
        value.id != project!.id ||
        value.founderId != project!.founderId) {
      throw StateError('연결된 프로젝트 정보가 다릅니다.');
    }
    setMeta('project', jsonEncode(value.json));
    notifyListeners();
  }

  String meta(String key) {
    final rows = db.select('SELECT value FROM metadata WHERE key=?', [key]);
    return rows.isEmpty ? '' : rows.first['value'] as String;
  }

  void setMeta(String key, String value) => db.execute(
    'INSERT INTO metadata VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  String get profileId => meta('profile');
  String get baseRevision => meta('baseRevision');
  List<WorkTask> get tasks => db
      .select('SELECT body FROM tasks ORDER BY id')
      .map(
        (r) => WorkTask.fromJson(
          Map<String, dynamic>.from(jsonDecode(r['body'] as String)),
        ),
      )
      .toList();
  Map<String, WorkTask> get baseline => {
    for (final row in db.select('SELECT body FROM baseline_tasks'))
      (jsonDecode(row['body'] as String)['id'] as String): WorkTask.fromJson(
        Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
      ),
  };
  List<Map<String, dynamic>> records(String table) => db
      .select('SELECT body FROM $table ORDER BY rowid DESC LIMIT 30')
      .map((r) => Map<String, dynamic>.from(jsonDecode(r['body'] as String)))
      .toList();
  List<Map<String, dynamic>> get activity => records('activity');
  List<Map<String, dynamic>> get notifications => !isProject
      ? records('notification_outbox')
      : db
            .select(
              "SELECT body FROM notification_inbox WHERE json_extract(body, '\$.recipientId')=? ORDER BY rowid DESC LIMIT 30",
              [profileId],
            )
            .map(
              (row) =>
                  Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
            )
            .toList();
  int get unreadNotificationCount => !isProject
      ? notifications.length
      : db.select(
              "SELECT COUNT(*) AS total FROM notification_inbox WHERE json_extract(body, '\$.recipientId')=? AND json_extract(body, '\$.read')=0",
              [profileId],
            ).single['total']
            as int;

  void markNotificationsRead() {
    if (!isProject) return;
    db.execute(
      "UPDATE notification_inbox SET body=json_set(body, '\$.read', json('true')) WHERE json_extract(body, '\$.recipientId')=?",
      [profileId],
    );
    notifyListeners();
  }

  void _notifyIncoming(WorkTask remote, WorkTask? previous, WorkTask? local) {
    if (!isProject ||
        remote.currentId != profileId ||
        local != null && local.same(remote)) {
      return;
    }
    final String eventType;
    if (previous == null) {
      if (remote.status == 'done') return;
      eventType = remote.status == 'review' ? 'task.review' : 'task.created';
    } else if (remote.status != previous.status) {
      eventType = 'task.${remote.status}';
    } else if (remote.currentId != previous.currentId) {
      eventType = 'task.assigned';
    } else {
      return;
    }
    final id = '${remote.id}:${remote.version}:$eventType:$profileId';
    db.execute('INSERT OR IGNORE INTO notification_inbox VALUES (?,?)', [
      id,
      jsonEncode({
        'id': id,
        'eventType': eventType,
        'taskId': remote.id,
        'title': remote.title,
        'status': remote.status,
        'recipientId': profileId,
        'reason': remote.reworkReason,
        'state': 'received',
        'read': false,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    ]);
  }

  WorkTask find(String id) {
    final rows = db.select('SELECT body FROM tasks WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('작업을 찾을 수 없습니다.');
    return WorkTask.fromJson(
      Map<String, dynamic>.from(jsonDecode(rows.single['body'] as String)),
    );
  }

  WorkTask? baselineFor(String id) {
    final rows = db.select('SELECT body FROM baseline_tasks WHERE id=?', [id]);
    return rows.isEmpty
        ? null
        : WorkTask.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(rows.single['body'] as String),
            ),
          );
  }

  void put(WorkTask task, {String table = 'tasks'}) => db.execute(
    'INSERT INTO $table VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
    [task.id, jsonEncode(task.data)],
  );
  T transaction<T>(T Function() work) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = work();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void setProfile(String id) {
    if (isProject) throw StateError('다른 사용자로 전환할 수 없습니다. 다시 로그인하세요.');
    person(id);
    setMeta('profile', id);
    notifyListeners();
  }

  void log(WorkTask t, String message, {String? eventType}) {
    final at = DateTime.now().toUtc().toIso8601String();
    final id = const Uuid().v4();
    db.execute('INSERT INTO activity VALUES (?,?)', [
      id,
      jsonEncode({
        'id': id,
        'taskId': t.id,
        'actorId': profileId,
        'message': message,
        'createdAt': at,
      }),
    ]);
    if (eventType != null) {
      final id = const Uuid().v4();
      db.execute('INSERT INTO notification_outbox VALUES (?,?)', [
        id,
        jsonEncode({
          'id': id,
          'eventType': eventType,
          'taskId': t.id,
          'title': t.title,
          'status': t.status,
          'recipientId': t.currentId,
          'actorId': profileId,
          'reason': t.reworkReason,
          'state': 'preview',
          'createdAt': at,
        }),
      ]);
    }
  }

  WorkTask save(Map<String, dynamic> input, {int? expectedVersion}) {
    final next = transaction(
      () => _save(input, expectedVersion: expectedVersion),
    );
    notifyListeners();
    return next;
  }

  WorkTask _save(Map<String, dynamic> input, {int? expectedVersion}) {
    // Read and compare only after BEGIN IMMEDIATE has acquired the write lock.
    // Another process using this same DB must not change the row between the
    // expected-version check and its update.
    final old = input['id'] == null ? null : find(input['id']);
    final actor = member(profileId);
    if (isProject && !actor.active || old == null && !canCreate) {
      throw StateError('작업 등록 권한이 필요합니다.');
    }
    if (old != null && old.version != expectedVersion) {
      throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
    }
    if (old != null && !canEdit(old)) {
      throw StateError(editLockReason(old));
    }
    final next = WorkTask.fromJson({
      ...input,
      'id': old?.id ?? 'TASK-${const Uuid().v4()}',
      'status': old?.status ?? 'todo',
      'completedDate': old?.completedDate ?? '',
      'reworkReason': old?.reworkReason ?? '',
      'version': nextTaskVersion(old?.version ?? 0),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (isProject) {
      for (final (id, reviewer) in [
        (next.assigneeId, false),
        (next.reviewerId, true),
      ]) {
        final assigned = member(id);
        if (!(reviewer ? assigned.canReview : assigned.canWork)) {
          throw StateError('승인된 작업자 또는 관리자를 담당자로 지정하세요.');
        }
      }
      if (old != null &&
          !actor.has('task.assign') &&
          [
            'part',
            'assigneeId',
            'reviewerId',
            'assignedDate',
            'dueDate',
            'priority',
          ].any((key) => old.data[key] != next.data[key])) {
        throw StateError('배정·일정·우선순위 변경 권한이 필요합니다.');
      }
    }
    if (old != null && old.same(next)) return old;
    if (isProject) {
      validateTaskMutation(actor: actor, next: next, current: old);
    } else if (old != null &&
        !canEditContent(old) &&
        [
          'title',
          'description',
        ].any((key) => old.data[key] != next.data[key])) {
      throw StateError(editLockReason(old));
    }
    put(next);
    log(
      next,
      old == null ? '새 작업을 등록했습니다.' : '작업내용을 수정했습니다.',
      eventType: old == null ? 'task.created' : null,
    );
    queueGitHub(next);
    return next;
  }

  bool canMove(WorkTask task, String status) =>
      canTransitionTask(actor, task, status);

  void transition(
    String id,
    String status, {
    String reason = '',
    required int expectedVersion,
  }) {
    transaction(
      () => _transition(
        id,
        status,
        reason: reason,
        expectedVersion: expectedVersion,
      ),
    );
    notifyListeners();
  }

  void _transition(
    String id,
    String status, {
    required String reason,
    required int expectedVersion,
  }) {
    final task = find(id);
    if (expectedVersion != task.version) {
      throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
    }
    if (!canMove(task, status)) {
      throw StateError('현재 역할이나 작업 상태에 허용되지 않은 변경입니다.');
    }
    if (status == 'rework' && reason.trim().isEmpty) {
      throw StateError('재작업 사유를 입력하세요.');
    }
    final next = task.copy({
      'status': status,
      'completedDate': status == 'done' ? localDate() : '',
      'reworkReason': status == 'rework' ? reason : task.reworkReason,
      'version': nextTaskVersion(task.version),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    validateTaskMutation(actor: actor, current: task, next: next);
    put(next);
    log(
      next,
      {
        'doing': '작업을 시작했습니다.',
        'review': '검토를 요청했습니다.',
        'rework': '재작업을 요청했습니다.',
        'done': '완료를 승인했습니다.',
      }[status]!,
      eventType: 'task.$status',
    );
    queueGitHub(next);
  }

  void queueGitHub(WorkTask task) {
    final rawConfig = meta('github.config');
    if (rawConfig.isEmpty) return;
    final config = jsonDecode(rawConfig) as Map;
    // Read only this task's baseline. Saving one item must not serialize the
    // entire project, and a revert must still replace its previous open PR.
    final proposal = {
      'schemaVersion': 1,
      'projectId': meta('projectId'),
      'baseRevision': baseRevision,
      'authorId': profileId,
      'changes': [_change(task, baselineFor(task.id))],
    };
    db.execute(
      'INSERT INTO github_queue VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
      [
        task.id,
        jsonEncode({
          'taskId': task.id,
          'title': task.title,
          'revision': const Uuid().v4(),
          'repository': config['repository'],
          'proposal': proposal,
          'configuration': config,
          'githubLogin': meta('github.login'),
          'state': 'pending',
          'error': '',
          'createdAt': task.data['updatedAt'],
        }),
      ],
    );
  }

  List<Map<String, dynamic>> get changes {
    final bases = baseline;
    final list = <Map<String, dynamic>>[];
    for (final t in tasks) {
      final b = bases[t.id];
      if (b != null && b.same(t)) continue;
      list.add(_change(t, b));
    }
    return list;
  }

  Map<String, dynamic> _change(WorkTask task, WorkTask? base) => {
    'taskId': task.id,
    'kind': base == null ? 'create' : 'update',
    'title': task.title,
    'baseVersion': base?.version,
    'fields': fields
        .where((key) => base == null || base.data[key] != task.data[key])
        .map(
          (key) => {
            'key': key,
            'label': fieldLabels[key],
            'before': base?.data[key],
            'after': task.data[key],
          },
        )
        .toList(),
    'base': base?.data,
    'task': task.data,
  };

  Map<String, dynamic> exportChanges() => {
    'schemaVersion': 1,
    'projectId': meta('projectId'),
    'baseRevision': baseRevision,
    'authorId': profileId,
    'changes': changes,
  };

  /// Explicitly accepts a user-selected remote task after sync has checked the
  /// current main revision and retired the discarded proposal's open PR.
  /// The local alternative remains recoverable; it is never silently discarded.
  void acceptRemoteTask(WorkTask remote, {required int expectedVersion}) {
    transaction(() {
      final local = find(remote.id);
      if (local.version != expectedVersion) {
        throw StateError('작업이 변경되었습니다. 최신 내용을 다시 확인하세요.');
      }
      final queued = db.select('SELECT body FROM github_queue WHERE id=?', [
        local.id,
      ]);
      final backupId = const Uuid().v4();
      db.execute('INSERT INTO conflict_backups VALUES (?,?)', [
        backupId,
        jsonEncode({
          'id': backupId,
          'taskId': local.id,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'task': local.data,
          'base': baselineFor(local.id)?.data,
          'queue': queued.isEmpty
              ? null
              : jsonDecode(queued.single['body'] as String),
          'accepted': remote.data,
        }),
      ]);
      final revision = max(local.version, remote.version);
      put(
        remote.copy({
          'version': revision < maxTaskVersion
              ? nextTaskVersion(revision)
              : revision,
        }),
      );
      put(remote, table: 'baseline_tasks');
      db.execute('DELETE FROM github_queue WHERE id=?', [local.id]);
      final conflicts = meta('github.pullConflicts');
      if (conflicts.isNotEmpty) {
        final remaining = (jsonDecode(conflicts) as List)
            .where((conflict) => conflict['taskId'] != local.id)
            .toList();
        setMeta(
          'github.pullConflicts',
          remaining.isEmpty ? '' : jsonEncode(remaining),
        );
      }
      log(remote, '개인 변경을 보관하고 팀의 최신 내용을 선택했습니다.');
    });
    notifyListeners();
  }

  MergeResult importSnapshot(
    dynamic snapshot, {
    Map<String, WorkTask>? acknowledgedBases,
    bool allowPartial = false,
  }) {
    if (snapshot is! Map ||
        snapshot['schemaVersion'] != 1 ||
        snapshot['projectId'] != meta('projectId') ||
        snapshot['revision'] is! String ||
        (snapshot['revision'] as String).isEmpty ||
        (snapshot['revision'] as String).length > 200 ||
        snapshot['tasks'] is! List) {
      throw StateError('이 프로젝트의 통합본 JSON 형식이 아닙니다.');
    }
    final incoming = <String, WorkTask>{};
    for (final raw in snapshot['tasks']) {
      if (raw is! Map) throw StateError('작업 데이터 형식이 올바르지 않습니다.');
      final t = WorkTask.fromJson(Map<String, dynamic>.from(raw));
      if (incoming.containsKey(t.id)) throw StateError('통합본에 중복 작업 ID가 있습니다.');
      incoming[t.id] = t;
    }
    final result = transaction(() {
      final storedBases = baseline;
      final bases = acknowledgedBases ?? storedBases;
      final locals = {for (final t in tasks) t.id: t};
      final merged = <WorkTask>[];
      final accepted = <WorkTask>[];
      final conflicts = <Map<String, dynamic>>[];
      if (!allowPartial && bases.keys.any((id) => !incoming.containsKey(id))) {
        throw StateError('기존 작업이 빠진 통합본입니다. 삭제 병합은 지원하지 않습니다.');
      }
      void conflict(WorkTask local, String field, dynamic own, dynamic remote) {
        conflicts.add({
          'taskId': local.id,
          'title': local.title,
          'field': field,
          'local': own,
          'remote': remote,
        });
      }

      for (final remote in incoming.values) {
        final base = bases[remote.id];
        final local = locals[remote.id];
        if (local == null) {
          merged.add(remote);
          accepted.add(remote);
          continue;
        }
        final start = conflicts.length;
        if (base == null) {
          if (!local.same(remote)) {
            conflict(local, '작업 ID', '개인 신규 작업', '동일 ID의 통합 작업');
            continue;
          }
        } else {
          if (remote.version < base.version) {
            conflict(local, '작업 버전', base.version, remote.version);
            continue;
          }
          if (base.status == 'done' && !base.same(remote)) {
            conflict(local, '완료 작업 잠금', '변경할 수 없는 완료 작업', '완료 후 변경된 통합본');
            continue;
          }
          // A remote handoff must not combine a worker's outstanding edit with
          // already submitted / completed content. Keep both versions for review.
          if (['review', 'done'].contains(remote.status) &&
              !local.same(remote) &&
              ['title', 'description'].any(
                (key) =>
                    local.data[key] != base.data[key] &&
                    local.data[key] != remote.data[key],
              )) {
            conflict(
              local,
              '검토·완료 잠금',
              '아직 통합되지 않은 내용 수정',
              statuses[remote.status],
            );
            continue;
          }
        }
        if (local.same(remote)) {
          // Repeated pulls do not manufacture new local revisions. Preserve a
          // higher local revision so stale editors are still detected.
          merged.add(
            remote.copy({'version': max(local.version, remote.version)}),
          );
          accepted.add(remote);
          continue;
        }
        if (base != null && local.same(base)) {
          try {
            merged.add(
              remote.version > local.version
                  ? remote
                  : remote.copy({'version': nextTaskVersion(local.version)}),
            );
            accepted.add(remote);
          } catch (e) {
            conflict(local, '작업 버전', e.toString(), '통합 전 확인 필요');
          }
          continue;
        }
        final next = Map<String, dynamic>.from(local.data);
        for (final f in fields) {
          final lc = local.data[f] != base!.data[f];
          final rc = remote.data[f] != base.data[f];
          if (lc && rc && local.data[f] != remote.data[f]) {
            conflict(local, fieldLabels[f]!, local.data[f], remote.data[f]);
          } else if (rc) {
            next[f] = remote.data[f];
          }
        }
        if (conflicts.length != start) continue;
        try {
          // Keep a locally newer proposal only when it remains ahead of main.
          // Increment once for a real rebase, never merely for polling again.
          final candidate = WorkTask.fromJson(next);
          next['version'] =
              candidate.same(local) && local.version > remote.version
              ? local.version
              : nextTaskVersion(max(local.version, remote.version));
          next['updatedAt'] = DateTime.now().toUtc().toIso8601String();
          merged.add(WorkTask.fromJson(next));
          accepted.add(remote);
        } catch (e) {
          conflict(local, '항목 간 관계', e.toString(), '통합 전 확인 필요');
        }
      }
      if (conflicts.isNotEmpty && !allowPartial) {
        return MergeResult(false, conflicts);
      }
      for (final t in incoming.values) {
        _notifyIncoming(t, storedBases[t.id], locals[t.id]);
      }
      for (final t in merged) {
        put(t);
      }
      for (final t in accepted) {
        put(t, table: 'baseline_tasks');
      }
      // This describes the snapshot observed, not every task's merge base.
      // Conflicted task baselines remain untouched and will be retried later.
      setMeta('baseRevision', snapshot['revision']);
      return MergeResult(conflicts.isEmpty || accepted.isNotEmpty, conflicts);
    });
    notifyListeners();
    return result;
  }

  @override
  void dispose() {
    db.close();
    super.dispose();
  }
}
