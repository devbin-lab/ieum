import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'sync_recovery_record.dart';
import 'task_handoff.dart';

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
      'workflow_revisions',
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
    db.execute(
      "CREATE INDEX IF NOT EXISTS activity_task_idx ON activity(json_extract(body, '\$.taskId')) WHERE json_valid(body)",
    );
    db.execute(
      "CREATE INDEX IF NOT EXISTS notification_recipient_idx ON notification_inbox(json_extract(body, '\$.recipientId'), json_extract(body, '\$.read'), json_extract(body, '\$.createdAt')) WHERE json_valid(body)",
    );
    _maintainHistory();
  }
  bool get isProject => meta('project').isNotEmpty;
  bool referencesResource(String sha256) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256');
    }
    for (final table in const [
      'tasks',
      'baseline_tasks',
      'activity',
      'notification_outbox',
      'notification_inbox',
      'github_queue',
      'github_sent',
      'conflict_backups',
      'sync_recovery',
      'workflow_revisions',
    ]) {
      if (db.select('SELECT 1 FROM $table WHERE instr(body, ?) > 0 LIMIT 1', [
        sha256,
      ]).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  ProjectManifest? get project => isProject
      ? ProjectManifest.fromJson(
          Map<String, dynamic>.from(jsonDecode(meta('project'))),
        ).partWorkflowView
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
  bool get canCreate =>
      (!isProject || actor.has('task.create')) &&
      (!isProject ||
          (project?.workflowSheet != null
                  ? project?.initialStatusId
                  : workflowInitialStatus(customWorkflowStageIds)) !=
              null);
  Map<String, String> get workflowStatuses {
    if (!isProject) return statuses;
    final configured = customWorkflowStageIds.toSet();
    final displayStages = List.of(project!.workflowStages);
    return {
      for (final stage in displayStages) stage.id: stage.name,
      for (final task in tasks)
        if (!configured.contains(task.status) &&
            (const {
                  'todo',
                  'doing',
                  'done',
                  'review',
                  'rework',
                }.contains(task.status) ||
                task.status.startsWith('stage-')))
          task.status: const {'todo', 'doing', 'done'}.contains(task.status)
              ? '삭제된 단계'
              : task.status.startsWith('stage-')
              ? '삭제된 단계'
              : task.status == 'rework'
              ? '이전 반려 작업'
              : statuses[task.status]!,
    };
  }

  String workflowStatusName(String id) =>
      workflowStatuses[id] ??
      (isProject && const {'todo', 'doing', 'done'}.contains(id)
          ? '삭제된 단계'
          : statuses[id] ?? id);
  List<String> get customWorkflowStageIds =>
      project?.workflowStages.map((stage) => stage.id).toList() ?? const [];
  String get workflowFlowLabel {
    if (!isProject || customWorkflowStageIds.isEmpty) return '작업 단계를 설정하세요.';
    if (manualWorkflow) {
      return customWorkflowStageIds.map(workflowStatusName).join(' · ');
    }
    final path = <String>[];
    final visited = <String>{};
    final sheet = project!.workflowSheet;
    final initial = sheet == null
        ? workflowInitialStatus(customWorkflowStageIds)
        : project!.initialStatusId;
    if (initial == null) return '작업을 등록할 일반 단계를 설정하세요.';
    var current = initial;
    while (visited.add(current)) {
      path.add(workflowStatusName(current));
      final String? next;
      if (sheet != null) {
        final route = sheet
            .outgoing(current)
            .where((r) => r.action != 'reject')
            .firstOrNull;
        next = route == null ? null : sheet.stageFor(route.to);
      } else {
        next = project!.activeWorkflowConnections
            .where((c) => c.from == current && c.action != 'reject')
            .firstOrNull
            ?.to;
      }
      if (next == null) break;
      current = next;
    }
    return path.join(' → ');
  }

  String? get workflowCompletionStatus => !isProject
      ? 'done'
      : project!.workflowStages.where((s) => s.isCompleted).firstOrNull?.id;
  bool get manualWorkflow => project?.usesManualWorkflow ?? false;
  bool isOpenTaskStage(WorkTask task) =>
      !task.isLocked &&
      (project?.workflowSheet != null
          ? task.workflowTarget.isEmpty &&
                task.workflowPerson.isEmpty &&
                !isCompleted(task)
          : manualWorkflow && !isCompleted(task) ||
                isOpenWorkflowStage(task, project?.activeWorkflowConnections));
  String currentActorId(WorkTask task) => task.isLocked
      ? task.lockedBy
      : manualWorkflow
      ? task.assigneeId
      : task.currentId;
  bool isAssignedToMe(WorkTask task) {
    if (task.isDeleted || task.isArchived || !actor.active) return false;
    if (task.isLocked) return task.lockedBy == profileId;
    final configured = project;
    if (configured?.workflowSheet == null) {
      return currentActorId(task) == profileId;
    }
    if (task.workflowTarget == 'legacy') return task.currentId == profileId;
    if (task.workflowTarget.isEmpty && task.workflowPerson.isEmpty) {
      return task.assigneeId == profileId;
    }
    return isWorkflowRecipient(actor, task, configured!);
  }

  String currentActorLabel(WorkTask task) => task.isLocked
      ? member(task.lockedBy).name
      : project?.workflowSheet != null
      ? workflowTargetLabel(task, project!)
      : isOpenTaskStage(task)
      ? '모든 작업자'
      : member(currentActorId(task)).name;
  bool canActOnTask(WorkTask task) =>
      !task.isDeleted &&
      !task.isArchived &&
      hasTaskLockAccess(actor, task) &&
      (project?.workflowSheet != null
          ? actor.active &&
                project!.people.any((p) => p.id == actor.id && p.active) &&
                (availableWorkflowRoutes(actor, task, project!).isNotEmpty ||
                    directWorkflowRouteIds.any(
                      (id) => directWorkflowRoute(task, project!, id) != null,
                    ))
          : manualWorkflow && actor.canWork && !isCompleted(task) ||
                currentActorId(task) == profileId ||
                (project?.activeWorkflowConnections ??
                        const <WorkflowConnection>[])
                    .any(
                      (c) =>
                          c.from == task.status &&
                          !c.assignedOnly &&
                          (c.allWorkers || c.actorParts.isNotEmpty) &&
                          canTransitionTask(
                            actor,
                            task,
                            c.to,
                            customWorkflowStageIds,
                            [c],
                          ) &&
                          canMove(task, c.to),
                    ));
  bool isCompleted(WorkTask task) => isProject
      ? project!.isCompleteStatus(task.status)
      : task.status == 'done';
  bool isWaitingForReview(WorkTask task) => project?.workflowSheet != null
      ? workflowTaskPurpose(task, project) == 'review' &&
            const {'todo', 'review'}.contains(task.status)
      : !manualWorkflow && task.status == 'review';
  bool canEdit(WorkTask task) => canEditTask(
    actor,
    task,
    completionStatus: workflowCompletionStatus,
    workflowConnections: project?.activeWorkflowConnections,
    manualWorkflow: manualWorkflow,
    workflowProject: project,
  );
  bool canEditContent(WorkTask task) => canEditTaskContent(
    actor,
    task,
    completionStatus: workflowCompletionStatus,
    workflowConnections: project?.activeWorkflowConnections,
    manualWorkflow: manualWorkflow,
    workflowProject: project,
  );
  String editLockReason(WorkTask task) => !hasTaskLockAccess(actor, task)
      ? '${member(task.lockedBy).name}님만 수정할 수 있습니다. 댓글로 의견을 남겨 주세요.'
      : task.isArchived
      ? '보관된 작업은 먼저 복원한 뒤 변경하세요.'
      : isCompleted(task)
      ? project?.workflowSheet != null
            ? '완료된 작업은 수정할 수 없습니다.'
            : '완료된 작업은 수정할 수 없습니다. 변경이 필요하면 새 작업을 등록하세요.'
      : task.isPaused
      ? '보류된 작업은 재개한 뒤 수정할 수 있습니다.'
      : task.isDropped
      ? '드랍된 작업은 복원한 뒤 수정할 수 있습니다.'
      : '프로젝트에 승인된 활성 참여자만 수정할 수 있습니다.';
  List<PartRule> get partRules => !isProject
      ? rules
      : project!.unifiedView.parts.map((part) {
          final candidates =
              people
                  .where((p) => p.active && p.canWork && p.parts.contains(part))
                  .toList()
                ..sort(
                  (a, b) => (a.role == 'worker' ? 0 : 1).compareTo(
                    b.role == 'worker' ? 0 : 1,
                  ),
                );
          return PartRule(
            part,
            candidates.isEmpty ? project!.ownerId : candidates.first.id,
            project!.ownerId,
            '',
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

  int get latestSyncRecoveryIndex =>
      db
              .select(
                'SELECT coalesce(max(rowid),0) AS value FROM sync_recovery',
              )
              .single['value']
          as int;
  bool get hasSyncRecoveryNotice => meta('github.recoveryNotice').isNotEmpty;
  int syncRecoveryCount({int? through}) =>
      db.select('SELECT count(*) AS value FROM sync_recovery WHERE rowid<=?', [
            through ?? latestSyncRecoveryIndex,
          ]).single['value']
          as int;

  List<SyncRecoveryRecord> syncRecoveryRecords({
    int? through,
    int offset = 0,
    int limit = 10,
  }) => db
      .select(
        'SELECT rowid AS recordIndex,id,body FROM sync_recovery WHERE rowid<=? ORDER BY rowid DESC LIMIT ? OFFSET ?',
        [
          through ?? latestSyncRecoveryIndex,
          limit.clamp(1, 50),
          max(0, offset),
        ],
      )
      .map(
        (row) => SyncRecoveryRecord.read(
          row['recordIndex'] as int,
          row['id'] as String,
          row['body'] as String,
        ),
      )
      .toList();

  void acknowledgeSyncRecoveryNotice({required int through}) {
    transaction(() {
      final latest = latestSyncRecoveryIndex;
      if (through < 0 || through > latest) {
        throw StateError('복구 기록이 변경되었습니다. 다시 확인해 주세요.');
      }
      final previous = int.tryParse(meta('github.recoveryAcknowledged')) ?? 0;
      setMeta('github.recoveryAcknowledged', '${max(previous, through)}');
      if (latest <= through) setMeta('github.recoveryNotice', '');
    });
    notifyListeners();
  }

  String get profileId => meta('profile');
  String get baseRevision => meta('baseRevision');
  List<WorkTask> get tasks => storedTasks.where((t) => !t.isDeleted).toList();

  List<WorkTask> get storedTasks => db
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
  List<Map<String, dynamic>> activityFor(String taskId, {int limit = 100}) => db
      .select(
        "SELECT body FROM activity WHERE json_valid(body) AND json_extract(body, '\$.taskId')=? ORDER BY rowid DESC LIMIT ?",
        [taskId, limit.clamp(1, 100)],
      )
      .map(
        (row) => Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
      )
      .toList();
  List<Map<String, dynamic>> get notifications => !isProject
      ? records('notification_outbox')
      : db
            .select(
              "SELECT body FROM notification_inbox WHERE json_valid(body) AND json_extract(body, '\$.recipientId')=? ORDER BY json_extract(body, '\$.read') ASC, json_extract(body, '\$.createdAt') DESC, rowid DESC LIMIT 500",
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
              "SELECT COUNT(*) AS total FROM notification_inbox WHERE json_valid(body) AND json_extract(body, '\$.recipientId')=? AND json_extract(body, '\$.read')=0",
              [profileId],
            ).single['total']
            as int;

  int get totalNotificationCount => !isProject
      ? notifications.length
      : db.select(
              "SELECT COUNT(*) AS total FROM notification_inbox WHERE json_valid(body) AND json_extract(body, '\$.recipientId')=?",
              [profileId],
            ).single['total']
            as int;

  void markNotificationsRead() {
    if (!isProject) return;
    db.execute(
      "UPDATE notification_inbox SET body=json_set(body, '\$.read', json('true')) WHERE json_valid(body) AND json_extract(body, '\$.recipientId')=?",
      [profileId],
    );
    _pruneNotifications();
    notifyListeners();
  }

  void markNotificationRead(String id) {
    if (!isProject) return;
    db.execute(
      "UPDATE notification_inbox SET body=json_set(body, '\$.read', json('true')) WHERE json_valid(body) AND id=? AND json_extract(body, '\$.recipientId')=?",
      [id, profileId],
    );
    _pruneNotifications();
    notifyListeners();
  }

  void _notifyIncoming(WorkTask remote, WorkTask? previous, WorkTask? local) {
    if (remote.isDeleted || remote.isArchived) return;
    final receives = project?.workflowSheet != null
        ? !isCompleted(remote) && isWorkflowRecipient(actor, remote, project!)
        : currentActorId(remote) == profileId || canActOnTask(remote);
    if (!isProject || !receives || local != null && local.same(remote)) {
      return;
    }
    final String eventType;
    if (previous == null) {
      if (isCompleted(remote)) return;
      eventType = isWaitingForReview(remote) ? 'task.review' : 'task.created';
    } else if (project?.workflowSheet != null) {
      final recipientChanged =
          currentActorId(remote) != currentActorId(previous) ||
          remote.workflowTarget != previous.workflowTarget ||
          remote.workflowPerson != previous.workflowPerson;
      final statusChanged = remote.status != previous.status;
      final purposeChanged =
          workflowTaskPurpose(remote, project) !=
          workflowTaskPurpose(previous, project);
      if (!statusChanged && !recipientChanged && !purposeChanged) return;
      final route = project?.workflowSheet?.routes
          .where((r) => r.id == remote.workflowRoute)
          .firstOrNull;
      final reviewRequest =
          isWaitingForReview(remote) &&
          (recipientChanged ||
              !isWaitingForReview(previous) ||
              statusChanged &&
                  workflowBoardCategory(remote, project) == 'todo');
      eventType =
          route?.action == 'reject' ||
              purposeChanged &&
                  workflowTaskPurpose(remote, project) == 'revision'
          ? 'task.rejected'
          : reviewRequest
          ? 'task.review'
          : statusChanged
          ? 'task.moved'
          : 'task.assigned';
    } else if (remote.status != previous.status) {
      eventType = manualWorkflow
          ? 'task.moved'
          : previous.status == 'review' &&
                remote.status != 'done' &&
                remote.reworkReason.isNotEmpty
          ? 'task.rejected'
          : 'task.${remote.status}';
    } else if (currentActorId(remote) != currentActorId(previous) ||
        remote.workflowTarget != previous.workflowTarget ||
        remote.workflowPerson != previous.workflowPerson) {
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
        'taskVersion': t.version,
        'status': t.status,
        'message': message,
        'createdAt': at,
      }),
    ]);
    if (isProject) {
      db.execute(
        'INSERT INTO workflow_revisions VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
        [
          '${t.id}:$profileId:${t.version}',
          jsonEncode({
            'taskId': t.id,
            'actorId': profileId,
            'version': t.version,
            'task': t.data,
          }),
        ],
      );
      db.execute(
        "DELETE FROM workflow_revisions WHERE json_extract(body, '\$.taskId')=? AND json_extract(body, '\$.actorId')=? AND json_extract(body, '\$.version')<=?",
        [
          t.id,
          profileId,
          max(
            baselineFor(t.id)?.version ?? 0,
            t.version - maxTaskRevisionAdvance,
          ),
        ],
      );
    }
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
          'recipientId': currentActorId(t),
          'actorId': profileId,
          'reason': t.reworkReason,
          'state': 'preview',
          'createdAt': at,
        }),
      ]);
    }
    _pruneActivity(t.id);
    _prunePreviewNotifications();
  }

  void _pruneActivity(String taskId) {
    final count =
        db.select(
              "SELECT COUNT(*) AS total FROM activity WHERE json_valid(body) AND json_extract(body, '\$.taskId')=?",
              [taskId],
            ).single['total']
            as int;
    if (count <= 100) return;
    // The exact workflow journal, pending edits and recovery copies are never
    // removed by display-history maintenance.
    if (isProject) {
      final base = baselineFor(taskId);
      if (base == null || !base.same(find(taskId))) return;
    }
    db.execute(
      "DELETE FROM activity WHERE json_valid(body) AND json_extract(body, '\$.taskId')=? AND rowid NOT IN (SELECT rowid FROM activity WHERE json_valid(body) AND json_extract(body, '\$.taskId')=? ORDER BY rowid DESC LIMIT 100)",
      [taskId, taskId],
    );
  }

  void _prunePreviewNotifications() => db.execute(
    "DELETE FROM notification_outbox WHERE json_valid(body) AND json_extract(body, '\$.state')='preview' AND rowid NOT IN (SELECT rowid FROM notification_outbox WHERE json_valid(body) AND json_extract(body, '\$.state')='preview' ORDER BY rowid DESC LIMIT 100)",
  );

  void _pruneNotifications() => db.execute(
    "DELETE FROM notification_inbox WHERE json_valid(body) AND json_extract(body, '\$.recipientId')=? AND json_extract(body, '\$.read')=1 AND rowid NOT IN (SELECT rowid FROM notification_inbox WHERE json_valid(body) AND json_extract(body, '\$.recipientId')=? AND json_extract(body, '\$.read')=1 ORDER BY json_extract(body, '\$.createdAt') DESC, rowid DESC LIMIT 500)",
    [profileId, profileId],
  );

  void _maintainHistory() {
    final last = DateTime.tryParse(meta('history.maintainedAt'));
    if (last != null &&
        DateTime.now().toUtc().difference(last) < const Duration(days: 1)) {
      return;
    }
    for (final row in db.select(
      "SELECT DISTINCT json_extract(body, '\$.taskId') AS taskId FROM activity WHERE json_valid(body)",
    )) {
      final id = row['taskId'];
      if (id is String &&
          db.select('SELECT id FROM tasks WHERE id=?', [id]).isNotEmpty) {
        _pruneActivity(id);
      }
    }
    _prunePreviewNotifications();
    _pruneNotifications();
    setMeta('history.maintainedAt', DateTime.now().toUtc().toIso8601String());
  }

  bool canPin(WorkTask task) => canPinTask(actor, task, project: project);

  WorkTask setTaskPinned(
    String id,
    bool pinned, {
    required int expectedVersion,
  }) {
    late WorkTask result;
    transaction(() {
      final current = find(id);
      if (current.version != expectedVersion || !canPin(current)) {
        throw StateError('최신 작업과 잠금 담당자를 확인하세요.');
      }
      if (current.isPinned == pinned) {
        result = current;
        return;
      }
      result = current.copy({
        'pinned': pinned ? 'true' : '',
        'version': nextTaskVersion(current.version),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      validateTaskMutation(
        actor: actor,
        current: current,
        next: result,
        workflowProject: project,
      );
      put(result);
      log(result, pinned ? '작업을 상단에 고정했습니다.' : '상단 고정을 해제했습니다.');
      queueGitHub(result);
    });
    notifyListeners();
    return result;
  }

  bool canSetTaskLock(WorkTask task) =>
      isProject &&
      actor.active &&
      !task.isDeleted &&
      !task.isArchived &&
      hasTaskLockAccess(actor, task) &&
      (task.isLocked || !isCompleted(task)) &&
      project!.people.any((p) => p.id == actor.id && p.active);

  bool canComment(WorkTask task) =>
      isProject &&
      actor.active &&
      !task.isDeleted &&
      !task.isArchived &&
      project!.people.any((p) => p.id == actor.id && p.active);

  WorkTask setTaskLocked(
    String id,
    bool locked, {
    required int expectedVersion,
  }) {
    late WorkTask result;
    transaction(() {
      final current = find(id);
      if (current.version != expectedVersion || !canSetTaskLock(current)) {
        throw StateError('잠금 담당자와 최신 작업 버전을 확인하세요.');
      }
      result = current.copy({
        'lockedBy': locked ? actor.id : '',
        'version': nextTaskVersion(current.version),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      if (current.same(result)) {
        result = current;
        return;
      }
      validateTaskMutation(
        actor: actor,
        next: result,
        current: current,
        workflowProject: project,
      );
      put(result);
      log(result, locked ? '작업을 잠갔습니다.' : '작업 잠금을 해제했습니다.');
      queueGitHub(result);
    });
    notifyListeners();
    return result;
  }

  WorkTask addTaskComment(
    String id,
    String text, {
    required int expectedVersion,
  }) {
    late WorkTask result;
    transaction(() {
      final current = find(id);
      if (current.version != expectedVersion || !canComment(current)) {
        throw StateError('작업이 변경되었습니다. 내용을 다시 확인하세요.');
      }
      result = current.copy({
        'comments': jsonEncode([
          ...current.comments,
          {
            'id': 'comment-${const Uuid().v4()}',
            'authorId': actor.id,
            'text': text.trim(),
            'context': current.status == 'review' ? 'review' : '',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
          },
        ]),
        'version': nextTaskVersion(current.version),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      validateTaskMutation(
        actor: actor,
        next: result,
        current: current,
        workflowProject: project,
      );
      put(result);
      log(result, '코멘트를 추가했습니다.');
      queueGitHub(result);
    });
    notifyListeners();
    return result;
  }

  bool canDelete(WorkTask task) => canDeleteTask(actor, task, project: project);

  WorkTask setTaskResources(
    String id,
    List<TaskResource> resources, {
    required int expectedVersion,
  }) {
    late WorkTask result;
    transaction(() {
      final current = find(id);
      if (current.version != expectedVersion || !canEditContent(current)) {
        throw StateError('작업이 변경되었거나 자료를 수정할 수 없습니다.');
      }
      result = current.copy({
        'resources': jsonEncode(
          resources.map((resource) => resource.json).toList(),
        ),
        'version': nextTaskVersion(current.version),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      validateTaskMutation(
        actor: actor,
        next: result,
        current: current,
        workflowProject: project,
      );
      put(result);
      log(result, '첨부 자료를 변경했습니다.');
      queueGitHub(result);
    });
    notifyListeners();
    return result;
  }

  void _removeTaskNotifications(String id) {
    for (final table in ['notification_inbox', 'notification_outbox']) {
      db.execute("DELETE FROM $table WHERE json_extract(body, '\$.taskId')=?", [
        id,
      ]);
    }
  }

  WorkTask deleteTask(String id, {required int expectedVersion}) {
    final next = transaction(() {
      final current = find(id);
      if (current.version != expectedVersion) {
        throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final next = current.copy({
        'deletedAt': now,
        'version': nextTaskVersion(current.version),
        'updatedAt': now,
      });
      validateDeleteMutation(
        actor: actor,
        next: next,
        current: current,
        project: project,
      );
      put(next);
      log(next, '작업을 삭제했습니다.');
      queueGitHub(next);
      _removeTaskNotifications(id);
      return next;
    });
    notifyListeners();
    return next;
  }

  bool canArchive(WorkTask task) =>
      canArchiveTask(actor, task, project: project);

  WorkTask setArchived(
    String id,
    bool archived, {
    required int expectedVersion,
  }) {
    final next = transaction(() {
      final task = find(id);
      if (task.version != expectedVersion) {
        throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
      }
      if (!canArchive(task)) throw StateError('이 작업을 보관·복원할 권한이 없습니다.');
      if (task.isArchived == archived) return task;
      final next = task.copy({
        'archivedAt': archived ? DateTime.now().toUtc().toIso8601String() : '',
        'version': nextTaskVersion(task.version),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      validateArchiveMutation(
        actor: actor,
        next: next,
        current: task,
        project: project,
      );
      put(next);
      log(next, archived ? '작업을 보관했습니다.' : '작업을 복원했습니다.');
      queueGitHub(next);
      return next;
    });
    notifyListeners();
    return next;
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
    final initialStatus = isProject
        ? project?.workflowSheet != null
              ? project?.initialStatusId
              : workflowInitialStatus(customWorkflowStageIds)
        : 'todo';
    if (old == null && initialStatus == null) {
      throw StateError('프로젝트 설정에서 작업을 등록할 일반 단계를 먼저 추가하세요.');
    }
    if (isProject && !actor.active || old == null && !canCreate) {
      throw StateError('작업 등록 권한이 필요합니다.');
    }
    if (old != null && old.version != expectedVersion) {
      throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
    }
    if (old != null && !canEdit(old)) {
      throw StateError(editLockReason(old));
    }
    final preservesLegacyRecipient =
        isProject &&
        old?.workflowTarget == 'legacy' &&
        (old?.assigneeId != input['assigneeId'] ||
            old?.status == 'review' && old?.reviewerId != input['reviewerId']);
    final stamp = DateTime.now().toUtc().toIso8601String();
    final next = WorkTask.fromJson({
      ...input,
      'id': old?.id ?? 'TASK-${const Uuid().v4()}',
      'status': old?.status ?? initialStatus!,
      'completedDate':
          old?.completedDate ??
          (old == null && isProject && initialStatus == workflowCompletionStatus
              ? localDate()
              : ''),
      'reworkReason': old?.reworkReason ?? '',
      'workflowTarget': preservesLegacyRecipient
          ? ''
          : old?.workflowTarget ?? '',
      'workflowPerson': preservesLegacyRecipient
          ? old!.currentId
          : old?.workflowPerson ?? (isProject ? input['assigneeId'] : ''),
      'workflowRoute': old?.workflowRoute ?? '',
      'workflowPurpose': old?.workflowPurpose ?? '',
      'workflowSender': old?.workflowSender ?? '',
      'archivedAt': old?.archivedAt ?? '',
      'deletedAt': old?.deletedAt ?? '',
      'lockedBy':
          old?.lockedBy ??
          (input['lockedBy'] == profileId ||
                  input['lockedBy'] == input['assigneeId']
              ? input['lockedBy'] ?? ''
              : ''),
      'creatorId': old?.creatorId ?? profileId,
      'initialAssigneeId': old?.initialAssigneeId ?? input['assigneeId'],
      'createdAt': old?.createdAt ?? stamp,
      'pausedFrom': old?.pausedFrom ?? '',
      'transitionHistory': old?.data['transitionHistory'] ?? '[]',
      'comments': old?.data['comments'] ?? '[]',
      'resources': old?.data['resources'] ?? '[]',
      'pinned': old?.data['pinned'] ?? '',
      'version': nextTaskVersion(old?.version ?? 0),
      'updatedAt': stamp,
    });
    if (isProject) {
      if (!project!.unifiedView.parts.contains(next.part) &&
          (old == null || old.part != next.part)) {
        throw StateError('프로젝트 설정에서 등록된 파트를 선택하세요.');
      }
      _validateAssignedMember(
        next.assigneeId,
        false,
        previousId: old?.assigneeId,
      );
      _validateAssignedMember(
        next.reviewerId,
        true,
        previousId: old?.reviewerId,
      );
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
      validateTaskMutation(
        actor: actor,
        next: next,
        current: old,
        customStages: isProject ? customWorkflowStageIds : null,
        workflowConnections: project?.activeWorkflowConnections,
        manualWorkflow: manualWorkflow,
        workflowProject: project,
      );
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

  // Keep this check outside _save's nullable edit/create branch. The previous
  // record-destructuring loop crashed Windows AOT while creating a task.
  @pragma('vm:never-inline')
  void _validateAssignedMember(String id, bool reviewer, {String? previousId}) {
    if (previousId == id) return;
    final assigned = member(id);
    final allowed = reviewer ? assigned.canReview : assigned.canWork;
    if (!allowed) {
      throw StateError('승인된 작업자 또는 관리자를 담당자로 지정하세요.');
    }
  }

  WorkflowConnection? rejectionConnection(WorkTask task, String status) =>
      _rejectionConnectionFor(actor, task, status);

  WorkflowConnection? _rejectionConnectionFor(
    Person executor,
    WorkTask task,
    String status,
  ) => project?.activeWorkflowConnections
      .where(
        (c) =>
            c.from == task.status &&
            c.to == status &&
            c.action == 'reject' &&
            canTransitionTask(executor, task, status, customWorkflowStageIds, [
              c,
            ]),
      )
      .firstOrNull;

  bool canMove(WorkTask task, String status) =>
      _canMoveFor(actor, task, status);

  bool _canMoveFor(Person executor, WorkTask task, String status) {
    if (project?.workflowSheet != null) {
      return canTransitionTask(
        executor,
        task,
        status,
        customWorkflowStageIds,
        null,
        false,
        project!,
      );
    }
    if (manualWorkflow) {
      return canTransitionTask(
        executor,
        task,
        status,
        customWorkflowStageIds,
        null,
        true,
      );
    }
    final rejection = _rejectionConnectionFor(executor, task, status);
    final recipientId = rejection?.returnAssigneeId.isNotEmpty == true
        ? rejection!.returnAssigneeId
        : task.assigneeId;
    if (isProject &&
        rejection != null &&
        (rejection.returnAssigneeId.isNotEmpty ||
            !isOpenWorkflowStage(task, project?.activeWorkflowConnections)) &&
        !member(recipientId).canWork) {
      return false;
    }
    return canTransitionTask(
      executor,
      task,
      status,
      isProject ? customWorkflowStageIds : null,
      project?.activeWorkflowConnections,
    );
  }

  String get _handoffSnapshot {
    final configured = project;
    return jsonEncode({
      'projectId': configured?.id ?? meta('projectId'),
      'actorId': profileId,
      'stages':
          configured?.workflowStages.map((s) => s.json).toList() ?? statuses,
      'manualWorkflow': manualWorkflow,
      'deliveryPolicy': 'collaborative-v1',
      'policy': configured?.workflowSheet?.policyJson,
      'roles': configured?.roles.map((r) => r.json).toList() ?? const [],
      'people': [
        for (final p in people)
          {
            'id': p.id,
            'name': p.name,
            'role': p.role,
            'active': p.active,
            'parts': p.parts,
            'permissions': p.permissions.toList()..sort(),
          },
      ],
    });
  }

  WorkTask _handoffTask(WorkTask task, WorkflowConnection connection) =>
      task.copy({
        'status': connection.to,
        if (connection.action == 'reject' &&
            connection.returnAssigneeId.isNotEmpty)
          'assigneeId': connection.returnAssigneeId,
        'completedDate':
            connection.to == workflowCompletionStatus &&
                workflowCompletionStatus != null
            ? localDate()
            : '',
      });

  String _handoffRecipient(WorkTask next, WorkflowConnection handoff) {
    if (next.status == workflowCompletionStatus &&
        workflowCompletionStatus != null) {
      return '처리 종료';
    }
    if (manualWorkflow) return '모든 작업자 · 담당자 변경 없음';
    if (isOpenWorkflowStage(next, project?.activeWorkflowConnections)) {
      return handoff.returnAssigneeId.isNotEmpty
          ? '모든 작업자 · 작업 담당자: ${member(next.assigneeId).name}'
          : '모든 작업자';
    }
    final outgoing =
        project?.activeWorkflowConnections
            .where(
              (c) =>
                  c.from == next.status &&
                  (c.taskParts.isEmpty || c.taskParts.contains(next.part)),
            )
            .toList() ??
        const <WorkflowConnection>[];
    final labels = <String>[];
    final actionLabels = <String>[];
    for (final connection in outgoing) {
      final eligible = people
          .where(
            (p) =>
                canTransitionTask(
                  p,
                  next,
                  connection.to,
                  customWorkflowStageIds,
                  [connection],
                ) &&
                _canMoveFor(p, next, connection.to),
          )
          .toList();
      final String label;
      if (eligible.isEmpty) {
        label = '처리 가능한 담당자 없음';
      } else if (connection.allWorkers &&
          connection.actorParts.isEmpty &&
          connection.roles.isEmpty) {
        label = '모든 작업자';
      } else if (!connection.assignedOnly && connection.actorParts.isNotEmpty) {
        final roleNames = connection.roles
            .map(
              (id) =>
                  roleLabels[id] ??
                  project?.roles.where((r) => r.id == id).firstOrNull?.name ??
                  id,
            )
            .join(', ');
        label =
            '${connection.actorParts.join(', ')} 전체'
            '${roleNames.isEmpty ? '' : ' · 역할: $roleNames'}';
      } else {
        final names = eligible.map((p) => p.name).toSet().toList();
        label = names.length <= 3
            ? names.join(', ')
            : '${names.take(3).join(', ')} 외 ${names.length - 3}명';
      }
      labels.add(label);
      actionLabels.add(
        '${switch (connection.action) {
          'approve' => '승인',
          'reject' => '반려',
          _ => '다음 전환',
        }}: $label',
      );
    }
    if (labels.toSet().length == 1) return labels.first;
    if (labels.isNotEmpty) return actionLabels.join(' / ');
    return '다음 단계 연결 없음';
  }

  List<TaskHandoffPlan> _availableHandoffsFor(WorkTask task) {
    if (project?.workflowSheet != null) {
      return [
        for (final id in directActionRouteIds)
          if (actor.active &&
              project!.people.any((p) => p.id == actor.id && p.active))
            if (directWorkflowRoute(task, project!, id) case final route?)
              _partHandoffPlan(task, route),
        for (final route in availableWorkflowRoutes(actor, task, project!))
          if (!isDefaultWorkflowPreset(route, project!) &&
              !directWorkflowRouteIds.contains(route.id) &&
              project!.workflowSheet!.stageFor(route.to) != task.status)
            _partHandoffPlan(task, route),
      ];
    }
    if (manualWorkflow) {
      final snapshot = _handoffSnapshot;
      return List.unmodifiable([
        for (final target in customWorkflowStageIds)
          if (canMove(task, target))
            _handoffPlan(
              task,
              WorkflowConnection(task.status, target, allWorkers: true),
              snapshot,
            ),
      ]);
    }
    final connections = project?.activeWorkflowConnections;
    final allowed = <WorkflowConnection>[];
    if (connections != null) {
      allowed.addAll(
        connections.where(
          (c) =>
              c.from == task.status &&
              c.to != task.status &&
              canTransitionTask(actor, task, c.to, customWorkflowStageIds, [
                c,
              ]) &&
              canMove(task, c.to),
        ),
      );
    }
    final orphaned =
        connections != null &&
        !customWorkflowStageIds.contains(task.status) &&
        !connections.any((c) => c.from == task.status);
    if (connections == null || orphaned) {
      for (final target
          in connections == null ? statuses.keys : customWorkflowStageIds) {
        if (target == task.status || !canMove(task, target)) continue;
        allowed.add(
          WorkflowConnection(
            task.status,
            target,
            action: task.status == 'review'
                ? (target == 'rework' ? 'reject' : 'approve')
                : 'advance',
            actor: task.status == 'review' ? 'reviewer' : 'assignee',
          ),
        );
      }
    }
    final snapshot = _handoffSnapshot;
    final seen = <String>{};
    return List.unmodifiable([
      for (final connection in allowed)
        if (seen.add('${connection.action}/${connection.to}'))
          _handoffPlan(task, connection, snapshot),
    ]);
  }

  TaskHandoffPlan _handoffPlan(
    WorkTask task,
    WorkflowConnection connection,
    String snapshot,
  ) {
    final next = _handoffTask(task, connection);
    final completed =
        next.status == workflowCompletionStatus &&
        workflowCompletionStatus != null;
    return TaskHandoffPlan(
      taskId: task.id,
      title: task.title,
      version: task.version,
      sourceId: task.status,
      sourceName: workflowStatusName(task.status),
      destinationId: connection.to,
      destinationName: workflowStatusName(connection.to),
      action: connection.action,
      actorId: profileId,
      workflowSnapshot: snapshot,
      recipientLabel: _handoffRecipient(next, connection),
      editWarning: completed
          ? '완료하면 이 작업을 수정하거나 다른 단계로 되돌릴 수 없습니다.'
          : canEditContent(next)
          ? ''
          : '이동 후에는 작업 내용을 수정할 수 없습니다. 다음 담당자의 처리를 기다려 주세요.',
    );
  }

  List<TaskHandoffPlan> availableHandoffs(WorkTask task) =>
      hasTaskLockAccess(actor, task)
      ? _availableHandoffsFor(find(task.id))
      : const [];

  List<TaskHandoffPlan> availableTransfers(WorkTask task) {
    if (!isProject ||
        !actor.active ||
        !project!.people.any((p) => p.id == actor.id && p.active)) {
      return const [];
    }
    final current = find(task.id);
    if (!canEdit(current)) return const [];
    final configured = project!;
    return [
      for (final id in const ['manual-handoff'])
        if (directWorkflowRoute(current, configured, id) case final route?)
          _partHandoffPlan(
            current,
            route,
            receiverPerson:
                id == 'manual-return' &&
                    configured.people.any(
                      (p) => p.id == current.workflowSender && p.active,
                    )
                ? current.workflowSender
                : '',
          ),
      for (final route in availableWorkflowRoutes(actor, current, configured))
        if (!isDefaultWorkflowPreset(route, configured) &&
            !directWorkflowRouteIds.contains(route.id) &&
            configured.workflowSheet!.stageFor(route.to) == current.status)
          _partHandoffPlan(current, route),
    ];
  }

  TaskHandoffPlan _partHandoffPlan(
    WorkTask task,
    WorkflowSheetRoute route, {
    String receiverGroup = '',
    String receiverPerson = '',
    String purpose = '',
  }) {
    final configured = project!;
    final direct = directWorkflowRouteIds.contains(route.id);
    final select = route.assignment == 'select';
    final intent = route.id == 'manual-return'
        ? 'revision'
        : route.id == 'manual-handoff'
        ? (purpose.isEmpty ? 'work' : purpose)
        : route.id == 'manual-review'
        ? 'review'
        : route.purpose;
    final unresolved =
        select && receiverGroup.isEmpty && receiverPerson.isEmpty;
    if (direct &&
        select &&
        !unresolved &&
        !workflowSelectedReceiverAllowed(
          route,
          configured,
          group: receiverGroup,
          person: receiverPerson,
        )) {
      throw StateError('전달받을 활성 파트 또는 작업자를 선택하세요.');
    }
    final next = unresolved
        ? task.copy({
            'pausedFrom': route.to == 'hold'
                ? (task.isPaused ? task.pausedFrom : task.status)
                : '',
            'status': direct
                ? route.to
                : configured.workflowSheet!.stageFor(route.to)!,
            'workflowPurpose': intent.isEmpty ? task.workflowPurpose : intent,
          })
        : direct
        ? task.copy({
            'status': route.to,
            'pausedFrom': route.to == 'hold'
                ? (task.isPaused ? task.pausedFrom : task.status)
                : '',
            'workflowTarget': select
                ? receiverGroup
                : task.workflowTarget == 'legacy'
                ? ''
                : task.workflowTarget,
            'workflowPerson': select
                ? receiverPerson
                : task.workflowTarget == 'legacy'
                ? task.currentId
                : task.workflowPerson,
            'workflowPurpose': intent.isEmpty ? task.workflowPurpose : intent,
          })
        : applyWorkflowRoute(
            task,
            route,
            configured,
            actorId: actor.id,
            receiverGroup: receiverGroup,
            receiverPerson: receiverPerson,
          );
    final people = select
        ? configured.people
              .where(
                (p) => workflowSelectedReceiverAllowed(
                  route,
                  configured,
                  group: '',
                  person: p.id,
                ),
              )
              .toList()
        : const <Person>[];
    final groups = <String, String>{
      if (select) '': '개별 작업자',
      for (final role in configured.roles)
        if (select &&
            workflowSelectedReceiverAllowed(
              route,
              configured,
              group: 'part:${role.id}',
              person: '',
            ))
          'part:${role.id}': role.name,
      if (select &&
          workflowSelectedReceiverAllowed(
            route,
            configured,
            group: 'role:owner',
            person: '',
          ))
        'role:owner': '관리자',
    };
    return TaskHandoffPlan(
      taskId: task.id,
      title: task.title,
      version: task.version,
      sourceId: task.status,
      sourceName: workflowStatusName(task.status),
      destinationId: next.status,
      destinationName: workflowStatusName(next.status),
      action: route.action,
      transitionName: route.name,
      commentRequired: route.requiresComment,
      requiredFields: route.requiredFields,
      completesTask: isCompleted(next),
      routeId: route.id,
      purpose: intent,
      canSelectPurpose: route.id == 'manual-handoff',
      lockOnHandoff: select && task.isLocked,
      actorId: profileId,
      workflowSnapshot: _handoffSnapshot,
      requiresRecipient: select,
      receiverGroup: receiverGroup,
      receiverPerson: receiverPerson,
      receiverGroupOptions: Map.unmodifiable(groups),
      receiverPersonOptions: Map.unmodifiable({
        for (final p in people) p.id: p.name,
      }),
      receiverPersonGroups: Map<String, List<String>>.unmodifiable({
        for (final p in people)
          p.id: List<String>.unmodifiable([
            '',
            for (final group in groups.keys.where((g) => g.isNotEmpty))
              if (workflowGroupContains(group, p, configured)) group,
          ]),
      }),
      recipientLabel: unresolved
          ? '전달 대상을 선택하세요'
          : workflowTargetLabel(next, configured),
      editWarning: isCompleted(next)
          ? '완료하면 작업 내용이 잠깁니다.'
          : select
          ? '상태는 유지됩니다. 잠근 채 전달하면 받는 담당자만 수정할 수 있습니다.'
          : canEditContent(next)
          ? ''
          : '전달 후에는 내용을 수정할 수 없습니다.',
    );
  }

  TaskHandoffPlan planHandoff(
    WorkTask task,
    String target, {
    String? action,
    String? routeId,
    String receiverGroup = '',
    String receiverPerson = '',
    String purpose = '',
  }) {
    var plans = [...availableHandoffs(task), ...availableTransfers(task)]
        .where(
          (p) =>
              p.destinationId == target &&
              (action == null || p.action == action) &&
              (routeId == null || p.routeId == routeId),
        )
        .toList();
    if (routeId == null && plans.length > 1) {
      final presets = plans
          .where((p) => !directWorkflowRouteIds.contains(p.routeId))
          .toList();
      if (presets.length == 1) plans = presets;
    }
    if (plans.length > 1) throw StateError('여러 전달 경로가 있습니다. 받을 대상을 선택하세요.');
    final plan = plans.firstOrNull;
    if (plan == null) throw StateError('현재 권한이나 작업 단계에서는 이동할 수 없습니다.');
    if (plan.requiresRecipient &&
        (receiverGroup.isNotEmpty ||
            receiverPerson.isNotEmpty ||
            purpose.isNotEmpty)) {
      final route = directWorkflowRouteIds.contains(plan.routeId)
          ? directWorkflowRoute(find(task.id), project!, plan.routeId)!
          : project!.workflowSheet!.routes.singleWhere(
              (r) => r.id == plan.routeId,
            );
      return _partHandoffPlan(
        find(task.id),
        route,
        receiverGroup: receiverGroup.isEmpty && receiverPerson.isEmpty
            ? plan.receiverGroup
            : receiverGroup,
        receiverPerson: receiverGroup.isEmpty && receiverPerson.isEmpty
            ? plan.receiverPerson
            : receiverPerson,
        purpose: purpose,
      );
    }
    return plan;
  }

  bool isHandoffCurrent(TaskHandoffPlan plan) {
    try {
      if (profileId != plan.actorId ||
          _handoffSnapshot != plan.workflowSnapshot) {
        return false;
      }
      final task = find(plan.taskId);
      if (!plan.describes(task)) return false;
      final current = planHandoff(
        task,
        plan.destinationId,
        action: plan.action,
        routeId: plan.routeId,
        receiverGroup: plan.receiverGroup,
        receiverPerson: plan.receiverPerson,
        purpose: plan.purpose,
      );
      return current.action == plan.action &&
          current.routeId == plan.routeId &&
          current.destinationId == plan.destinationId &&
          current.requiresRecipient == plan.requiresRecipient &&
          current.receiverGroup == plan.receiverGroup &&
          current.receiverPerson == plan.receiverPerson &&
          current.purpose == plan.purpose &&
          current.editWarning == plan.editWarning;
    } catch (_) {
      return false;
    }
  }

  void confirmHandoff(TaskHandoffPlan plan, {String reason = ''}) {
    transaction(() {
      if (!isHandoffCurrent(plan)) {
        throw StateError('작업이나 전환 조건이 변경되었습니다. 최신 내용을 확인하고 다시 진행하세요.');
      }
      if (plan.requiresRecipient &&
          plan.receiverGroup.isEmpty &&
          plan.receiverPerson.isEmpty) {
        throw StateError('전달받을 파트 또는 작업자를 선택하세요.');
      }
      _transition(
        plan.taskId,
        plan.destinationId,
        reason: reason,
        expectedVersion: plan.version,
        routeId: plan.routeId,
        receiverGroup: plan.receiverGroup,
        receiverPerson: plan.receiverPerson,
        purpose: plan.purpose,
        lockOnHandoff: plan.lockOnHandoff,
      );
    });
    notifyListeners();
  }

  void transition(
    String id,
    String status, {
    String reason = '',
    required int expectedVersion,
    String? routeId,
    String receiverGroup = '',
    String receiverPerson = '',
    String purpose = '',
  }) {
    transaction(
      () => _transition(
        id,
        status,
        reason: reason,
        expectedVersion: expectedVersion,
        routeId: routeId,
        receiverGroup: receiverGroup,
        receiverPerson: receiverPerson,
        purpose: purpose,
      ),
    );
    notifyListeners();
  }

  void recoverTask(
    String id, {
    required String stageId,
    required String personId,
    required int expectedVersion,
  }) {
    transaction(() {
      final task = find(id);
      if (!owns ||
          project?.workflowSheet == null ||
          !hasTaskLockAccess(actor, task)) {
        throw StateError('관리자만 작업을 회수할 수 있습니다.');
      }
      if (task.version != expectedVersion) {
        throw StateError('작업이 변경되었습니다. 다시 확인하세요.');
      }
      if (!customWorkflowStageIds.contains(stageId) ||
          project!.isLockedStatus(stageId) ||
          !member(personId).active) {
        throw StateError('일반 작업 단계와 활성 참여자를 선택하세요.');
      }
      final next = task.copy({
        'status': stageId,
        'workflowTarget': '',
        'workflowPerson': personId,
        'workflowRoute': 'admin-recovery',
        'assigneeId': personId,
        'completedDate': '',
        'version': nextTaskVersion(task.version),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      validateTaskMutation(
        actor: actor,
        current: task,
        next: next,
        workflowProject: project,
      );
      put(next);
      log(
        next,
        '관리자가 ${workflowStatusName(stageId)} 단계로 회수했습니다. · ${member(personId).name}',
        eventType: 'task.assigned',
      );
      queueGitHub(next);
    });
    notifyListeners();
  }

  void _transition(
    String id,
    String status, {
    required String reason,
    required int expectedVersion,
    String? routeId,
    String receiverGroup = '',
    String receiverPerson = '',
    String purpose = '',
    bool? lockOnHandoff,
  }) {
    final task = find(id);
    if (expectedVersion != task.version) {
      throw StateError('작업이 변경되었습니다. 다시 열어 확인하세요.');
    }
    if (isProject &&
        routeId == null &&
        !availableWorkflowRoutes(
          actor,
          task,
          project!,
        ).any((r) => project!.workflowSheet!.stageFor(r.to) == status)) {
      final direct = directActionRouteIds
          .map((id) => directWorkflowRoute(task, project!, id))
          .where((r) => r != null && r.to == status)
          .toList();
      if (direct.length == 1) routeId = direct.single!.id;
    }
    if (isProject && directWorkflowRouteIds.contains(routeId)) {
      final route = directWorkflowRoute(task, project!, routeId!);
      if (route == null || route.to != status) {
        throw StateError('현재 상태에서는 이 동작을 실행할 수 없습니다.');
      }
      final stamp = DateTime.now().toUtc().toIso8601String();
      final next = applyDirectWorkflowRoute(
        task,
        route,
        project!,
        actorId: actor.id,
        receiverGroup: receiverGroup,
        receiverPerson: receiverPerson,
        purpose: purpose,
        reason: reason,
        lockOnHandoff: lockOnHandoff,
        at: stamp,
      ).copy({'version': nextTaskVersion(task.version), 'updatedAt': stamp});
      validateTaskMutation(
        actor: actor,
        current: task,
        next: next,
        workflowProject: project,
      );
      put(next);
      log(
        next,
        '${route.buttonName} · ${workflowStatusName(task.status)}'
        '${task.status == next.status ? ' 유지' : ' → ${workflowStatusName(next.status)}'}'
        ' · ${currentActorLabel(next)}'
        '${reason.trim().isEmpty ? '' : ' · ${reason.trim()}'}',
        eventType: route.action == 'reject'
            ? 'task.rejected'
            : route.assignment == 'select'
            ? workflowTaskPurpose(next, project) == 'review'
                  ? 'task.review'
                  : 'task.assigned'
            : 'task.moved',
      );
      queueGitHub(next);
      return;
    }
    if (project?.workflowSheet != null) {
      final routes = availableWorkflowRoutes(actor, task, project!)
          .where(
            (r) =>
                project!.workflowSheet!.stageFor(r.to) == status &&
                (routeId == null || routeId == r.id),
          )
          .toList();
      if (routes.length != 1) throw StateError('전달 가능한 경로와 수신 대상을 선택하세요.');
      final route = routes.single;
      validateWorkflowRouteInputs(task, route, comment: reason);
      final next =
          applyWorkflowRoute(
            task,
            route,
            project!,
            reason: reason,
            actorId: actor.id,
            receiverGroup: receiverGroup,
            receiverPerson: receiverPerson,
          ).copy({
            'version': nextTaskVersion(task.version),
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          });
      validateTaskMutation(
        actor: actor,
        current: task,
        next: next,
        workflowProject: project,
      );
      put(next);
      log(
        next,
        '${route.buttonName} · ${workflowStatusName(task.status)} → ${workflowStatusName(status)} · ${currentActorLabel(next)}'
        '${reason.trim().isEmpty ? '' : ' · ${reason.trim()}'}',
        eventType: route.action == 'reject'
            ? 'task.rejected'
            : isWaitingForReview(next) &&
                  (route.purpose == 'review' ||
                      project!.isLockedStatus(next.status) ||
                      workflowBoardCategory(next, project) == 'todo')
            ? 'task.review'
            : 'task.$status',
      );
      queueGitHub(next);
      return;
    }
    if (!canMove(task, status)) {
      throw StateError('현재 역할이나 작업 상태에 허용되지 않은 변경입니다.');
    }
    final rejection = rejectionConnection(task, status);
    final isRejection =
        rejection != null ||
        !isProject && task.status == 'review' && status == 'rework';
    if (isRejection && reason.trim().isEmpty) {
      throw StateError('반려 코멘트를 입력하세요.');
    }
    final next = task.copy({
      'status': status,
      if (rejection?.returnAssigneeId.isNotEmpty == true)
        'assigneeId': rejection!.returnAssigneeId,
      'completedDate':
          status == workflowCompletionStatus && workflowCompletionStatus != null
          ? localDate()
          : '',
      'reworkReason': isRejection ? reason.trim() : task.reworkReason,
      'version': nextTaskVersion(task.version),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    validateTaskMutation(
      actor: actor,
      current: task,
      next: next,
      customStages: isProject ? customWorkflowStageIds : null,
      workflowConnections: project?.activeWorkflowConnections,
      manualWorkflow: manualWorkflow,
    );
    put(next);
    log(
      next,
      isRejection
          ? '${workflowStatusName(status)} 단계로 반려했습니다.'
          : manualWorkflow
          ? '${workflowStatusName(status)} 단계로 옮겼습니다.'
          : {
                  'doing': '작업을 시작했습니다.',
                  'review': '검토를 요청했습니다.',
                  'rework': '재작업을 요청했습니다.',
                  'done': '완료를 승인했습니다.',
                }[status] ??
                '${workflowStatusName(status)} 단계로 옮겼습니다.',
      eventType: isRejection
          ? 'task.rejected'
          : manualWorkflow
          ? 'task.moved'
          : 'task.$status',
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
    for (final t in storedTasks) {
      final b = bases[t.id];
      if (b != null && b.same(t)) continue;
      list.add(_change(t, b));
    }
    return list;
  }

  List<WorkTask>? workflowRevisionsFor(WorkTask task, WorkTask? base) {
    if (!isProject) return null;
    final delta = task.version - (base?.version ?? 0);
    if (delta < 1 || delta > maxTaskRevisionAdvance) return null;
    final rows = db.select(
      "SELECT body FROM workflow_revisions WHERE json_extract(body, '\$.taskId')=? AND json_extract(body, '\$.actorId')=? AND json_extract(body, '\$.version')>? AND json_extract(body, '\$.version')<=? ORDER BY json_extract(body, '\$.version')",
      [task.id, profileId, base?.version ?? 0, task.version],
    );
    if (rows.length != delta) return null;
    final revisions = rows
        .map(
          (row) => WorkTask.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(row['body'] as String)['task'],
            ),
          ),
        )
        .toList();
    for (var i = 0; i < revisions.length; i++) {
      if (revisions[i].version != (base?.version ?? 0) + i + 1) return null;
    }
    if (!revisions.last.same(task)) return null;
    return List.unmodifiable(revisions);
  }

  Map<String, dynamic> _change(WorkTask task, WorkTask? base) {
    final revisions = workflowRevisionsFor(task, base);
    return {
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
      if (revisions != null)
        'steps': revisions.map((step) => step.data).toList(),
    };
  }

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
      if (remote.isDeleted) _removeTaskNotifications(remote.id);
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

  bool get canImportManually => actor.canMutate;
  MergeResult importManualSnapshot(dynamic source, {required bool trusted}) {
    if (!canImportManually) throw StateError('읽기 전용 참여자는 통합본을 가져올 수 없습니다.');
    if (!trusted) throw StateError('통합본 출처 확인이 필요합니다.');
    return importSnapshot(source);
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
      if ((isProject
              ? project!.isCompleteStatus(t.status)
              : t.status == 'done') &&
          t.completedDate.isEmpty) {
        throw StateError('완료 상태에는 완료일이 필요합니다.');
      }
      if (incoming.containsKey(t.id)) throw StateError('통합본에 중복 작업 ID가 있습니다.');
      incoming[t.id] = t;
    }
    final result = transaction(() {
      final storedBases = baseline;
      final bases = acknowledgedBases ?? storedBases;
      final locals = {for (final t in storedTasks) t.id: t};
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
        if ((local.isDeleted || remote.isDeleted) &&
            !local.same(remote) &&
            (base == null ||
                (!local.same(base) && !remote.same(base)) ||
                (base.isDeleted && !remote.isDeleted))) {
          conflict(
            local,
            '작업 삭제',
            local.isDeleted ? '삭제됨' : '수정됨',
            remote.isDeleted ? '삭제됨' : '수정됨',
          );
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
          if (!isProject &&
              base.status == 'done' &&
              !remote.isDeleted &&
              !base.same(remote)) {
            conflict(local, '완료 작업 잠금', '변경할 수 없는 완료 작업', '완료 후 변경된 통합본');
            continue;
          }
          if (local.lockedBy != base.lockedBy &&
              !local.same(remote) &&
              ['title', 'description', ...assignmentFields].any(
                (key) =>
                    remote.data[key] != base.data[key] &&
                    remote.data[key] != local.data[key],
              )) {
            conflict(local, '잠금과 내용 수정', '아직 통합되지 않은 잠금 변경', '통합본의 내용 수정');
            continue;
          }
          if (local.isPinned != base.isPinned &&
              local.isPinned != remote.isPinned &&
              !canPinTask(actor, remote, project: project)) {
            conflict(local, '상단 고정 권한', '아직 통합되지 않은 고정 변경', '통합본의 잠금·보관·삭제 상태');
            continue;
          }
          // A remote handoff must not combine a worker's outstanding edit with
          // already submitted / completed content. Keep both versions for review.
          if ((isProject
                  ? !canEditWorkflowTask(actor, remote, project!)
                  : ['review', 'done'].contains(remote.status)) &&
              !local.same(remote) &&
              ['title', 'description', if (isProject) ...assignmentFields].any(
                (key) =>
                    local.data[key] != base.data[key] &&
                    local.data[key] != remote.data[key],
              )) {
            conflict(
              local,
              '전달 후 편집 제한',
              '아직 통합되지 않은 내용 수정',
              workflowStatusName(remote.status),
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
        // A handoff is one mutation. Never combine one client's status with
        // another client's recipient, route, completion date or comment.
        const transitionFields = {
          'status',
          'workflowTarget',
          'workflowPerson',
          'workflowRoute',
          'workflowPurpose',
          'workflowSender',
          'completedDate',
          'reworkReason',
          'archivedAt',
          'deletedAt',
          'lockedBy',
          'pausedFrom',
          'transitionHistory',
        };
        final atomicTransition = project?.workflowSheet != null;
        if (atomicTransition) {
          final localChanged = transitionFields.any(
            (f) => local.data[f] != base!.data[f],
          );
          final remoteChanged = transitionFields.any(
            (f) => remote.data[f] != base!.data[f],
          );
          if (localChanged &&
              remoteChanged &&
              transitionFields.any((f) => local.data[f] != remote.data[f])) {
            conflict(
              local,
              '워크플로 전환',
              {for (final f in transitionFields) f: local.data[f]},
              {for (final f in transitionFields) f: remote.data[f]},
            );
          } else if (remoteChanged) {
            for (final f in transitionFields) {
              next[f] = remote.data[f];
            }
          }
        }
        for (final f in fields) {
          if (f == 'comments') {
            final all = <String, Map<String, dynamic>>{};
            var invalid = false;
            for (final item in [...local.comments, ...remote.comments]) {
              final prior = all[item['id']];
              if (prior != null &&
                  (prior.length != item.length ||
                      prior.keys.any((k) => prior[k] != item[k]))) {
                invalid = true;
              }
              all[item['id'] as String] = item;
            }
            if (invalid || all.length > 100) {
              conflict(local, '코멘트', '코멘트의 내용 또는 개수 충돌', '통합 전 확인 필요');
            } else {
              final values = all.values.toList()
                ..sort((a, b) {
                  final order = (a['createdAt'] as String).compareTo(
                    b['createdAt'] as String,
                  );
                  return order == 0
                      ? (a['id'] as String).compareTo(b['id'] as String)
                      : order;
                });
              next[f] = jsonEncode(values);
            }
            continue;
          }
          if (atomicTransition && transitionFields.contains(f)) continue;
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
        if (t.isDeleted) _removeTaskNotifications(t.id);
      }
      for (final t in accepted) {
        put(t, table: 'baseline_tasks');
        if (storedBases[t.id]?.same(t) != true) _pruneActivity(t.id);
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
