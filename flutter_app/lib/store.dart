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
      'github_queue',
      'github_sent',
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
  bool get canCreate => !isProject || manages;
  bool canEdit(WorkTask task) =>
      manages || actor.role == 'worker' && actor.id == task.assigneeId;
  List<PartRule> get partRules => !isProject
      ? rules
      : rules.map((r) {
          final candidates =
              people
                  .where(
                    (p) =>
                        p.active &&
                        p.role != 'viewer' &&
                        p.parts.contains(r.part),
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
        value.ownerId != project!.ownerId) {
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
  List<Map<String, dynamic>> get notifications =>
      records('notification_outbox');
  WorkTask find(String id) => tasks.firstWhere(
    (t) => t.id == id,
    orElse: () => throw StateError('작업을 찾을 수 없습니다.'),
  );
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
    final old = input['id'] == null ? null : find(input['id']);
    final actor = member(profileId);
    if (isProject && !actor.active || old == null && !canCreate) {
      throw StateError('작업 등록은 개설자 또는 PD / PM에게 허용됩니다.');
    }
    if (old != null && old.version != expectedVersion) {
      throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
    }
    if (old != null && !canEdit(old)) {
      throw StateError('작업자 또는 PD / PM만 내용을 수정할 수 있습니다.');
    }
    final next = WorkTask.fromJson({
      ...input,
      'id': old?.id ?? 'TASK-${const Uuid().v4()}',
      'status': old?.status ?? 'todo',
      'completedDate': old?.completedDate ?? '',
      'reworkReason': old?.reworkReason ?? '',
      'version': (old?.version ?? 0) + 1,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (isProject) {
      for (final id in [next.assigneeId, next.reviewerId]) {
        final assigned = member(id);
        if (!assigned.active || assigned.role == 'viewer') {
          throw StateError('승인된 작업자 또는 관리자를 담당자로 지정하세요.');
        }
      }
      if (old != null &&
          !manages &&
          [
            'part',
            'assigneeId',
            'reviewerId',
            'assignedDate',
            'dueDate',
            'priority',
          ].any((key) => old.data[key] != next.data[key])) {
        throw StateError('배정·일정·우선순위 변경은 PD / PM에게 허용됩니다.');
      }
    }
    if (old != null && old.same(next)) return old;
    transaction(() {
      put(next);
      log(
        next,
        old == null ? '새 작업을 등록했습니다.' : '작업내용을 수정했습니다.',
        eventType: old == null ? 'task.created' : null,
      );
      queueGitHub(next);
    });
    notifyListeners();
    return next;
  }

  bool canMove(WorkTask task, String status) {
    final p = member(profileId);
    if (!p.active || p.role == 'viewer') return false;
    final worker = p.id == task.assigneeId || p.manages;
    final reviewer = p.id == task.reviewerId || p.manages;
    return status == 'doing' &&
            ['todo', 'rework'].contains(task.status) &&
            worker ||
        status == 'review' && task.status == 'doing' && worker ||
        ['done', 'rework'].contains(status) &&
            task.status == 'review' &&
            reviewer;
  }

  void transition(
    String id,
    String status, {
    String reason = '',
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
      'version': task.version + 1,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    transaction(() {
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
    });
    notifyListeners();
  }

  void queueGitHub(WorkTask task) {
    final rawConfig = meta('github.config');
    if (rawConfig.isEmpty) return;
    final config = jsonDecode(rawConfig) as Map;
    if (config['enabled'] != true) return;
    final proposal = exportChanges();
    proposal['changes'] = (proposal['changes'] as List)
        .where((change) => change['taskId'] == task.id)
        .toList();
    // A revert to the baseline still needs to replace an earlier submitted
    // proposal. Otherwise the open PR would keep the discarded change.
    if ((proposal['changes'] as List).isEmpty) {
      final base = baseline[task.id];
      proposal['changes'] = [
        {
          'taskId': task.id,
          'kind': 'update',
          'title': task.title,
          'baseVersion': base?.version,
          'fields': <dynamic>[],
          'base': base?.data,
          'task': task.data,
        },
      ];
    }
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
      final changed = fields
          .where((f) => b == null || b.data[f] != t.data[f])
          .toList();
      if (changed.isEmpty) continue;
      list.add({
        'taskId': t.id,
        'kind': b == null ? 'create' : 'update',
        'title': t.title,
        'baseVersion': b?.version,
        'fields': changed
            .map(
              (f) => {
                'key': f,
                'label': fieldLabels[f],
                'before': b?.data[f],
                'after': t.data[f],
              },
            )
            .toList(),
        'base': b?.data,
        'task': t.data,
      });
    }
    return list;
  }

  Map<String, dynamic> exportChanges() => {
    'schemaVersion': 1,
    'projectId': meta('projectId'),
    'baseRevision': baseRevision,
    'authorId': profileId,
    'changes': changes,
  };
  MergeResult importSnapshot(
    dynamic snapshot, {
    Map<String, WorkTask>? acknowledgedBases,
  }) {
    if (snapshot is! Map ||
        snapshot['schemaVersion'] != 1 ||
        snapshot['projectId'] != meta('projectId') ||
        snapshot['revision'] is! String ||
        (snapshot['revision'] as String).isEmpty ||
        (snapshot['revision'] as String).length > 200 ||
        snapshot['tasks'] is! List ||
        (snapshot['tasks'] as List).length > 10000) {
      throw StateError('이 프로젝트의 통합본 JSON 형식이 아닙니다.');
    }
    final incoming = <String, WorkTask>{};
    for (final raw in snapshot['tasks']) {
      if (raw is! Map) throw StateError('작업 데이터 형식이 올바르지 않습니다.');
      final t = WorkTask.fromJson(Map<String, dynamic>.from(raw));
      if (incoming.containsKey(t.id)) throw StateError('통합본에 중복 작업 ID가 있습니다.');
      incoming[t.id] = t;
    }
    final bases = acknowledgedBases ?? baseline;
    final locals = {for (final t in tasks) t.id: t};
    final merged = <WorkTask>[];
    final conflicts = <Map<String, dynamic>>[];
    for (final id in bases.keys) {
      if (!incoming.containsKey(id)) {
        throw StateError('기존 작업이 빠진 통합본입니다. 삭제 병합은 지원하지 않습니다.');
      }
    }
    for (final remote in incoming.values) {
      final base = bases[remote.id];
      final local = locals[remote.id];
      if (local == null) {
        merged.add(remote);
        continue;
      }
      if (base == null) {
        if (!local.same(remote)) {
          conflicts.add({
            'taskId': local.id,
            'title': local.title,
            'field': '작업 ID',
            'local': '개인 신규 작업',
            'remote': '동일 ID의 통합 작업',
          });
        } else {
          merged.add(
            remote.copy({'version': max(local.version, remote.version) + 1}),
          );
        }
        continue;
      }
      final next = Map<String, dynamic>.from(local.data);
      for (final f in fields) {
        final lc = local.data[f] != base.data[f];
        final rc = remote.data[f] != base.data[f];
        if (lc && rc && local.data[f] != remote.data[f]) {
          conflicts.add({
            'taskId': local.id,
            'title': local.title,
            'field': fieldLabels[f],
            'local': local.data[f],
            'remote': remote.data[f],
          });
        } else if (rc) {
          next[f] = remote.data[f];
        }
      }
      next['version'] = max(local.version, remote.version) + 1;
      next['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      try {
        merged.add(WorkTask.fromJson(next));
      } catch (e) {
        conflicts.add({
          'taskId': local.id,
          'title': local.title,
          'field': '항목 간 관계',
          'local': e.toString(),
          'remote': '통합 전 확인 필요',
        });
      }
    }
    if (conflicts.isNotEmpty) return MergeResult(false, conflicts);
    transaction(() {
      for (final t in merged) {
        put(t);
      }
      for (final t in incoming.values) {
        put(t, table: 'baseline_tasks');
      }
      setMeta('baseRevision', snapshot['revision']);
    });
    notifyListeners();
    return const MergeResult(true, []);
  }

  @override
  void dispose() {
    db.close();
    super.dispose();
  }
}
