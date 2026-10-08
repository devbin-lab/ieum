import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'store.dart';

/// Runs on-enter transitions only after this session's local status changes.
/// Remote imports, opening a project and editing content never start a run.
class WorkflowAutomationRunner extends ChangeNotifier {
  WorkflowAutomationRunner(this.store) {
    _remember();
    store.addListener(_changed);
  }

  final TaskStore store;
  final _pending =
      <String, ({int version, String status, String activityId})>{};
  Map<String, ({int version, String status})> _observed = {};
  String _projectId = '', _actorId = '';
  int _activityCursor = 0;
  bool _scheduled = false, _running = false, _disposed = false;
  String lastMessage = '';

  int get enabledRouteCount =>
      store.project?.workflowSheet?.routes
          .where((route) => route.trigger == 'onEnter')
          .length ??
      0;

  void _remember() {
    _projectId = store.meta('projectId');
    _actorId = store.profileId;
    _observed = {
      for (final task in store.tasks)
        task.id: (version: task.version, status: task.status),
    };
    _activityCursor = _latestActivityRow;
  }

  int get _latestActivityRow =>
      store.db
              .select('SELECT COALESCE(MAX(rowid), 0) AS latest FROM activity')
              .single['latest']
          as int;

  String? _localEvent(WorkTask task, {int? afterRow}) {
    final latest = store.activityFor(task.id, limit: 1).firstOrNull;
    if (latest == null ||
        latest['actorId'] != store.profileId ||
        latest['taskVersion'] != task.version ||
        latest['status'] != task.status) {
      return null;
    }
    final id = latest['id'] as String;
    if (afterRow != null) {
      final rows = store.db.select('SELECT rowid FROM activity WHERE id=?', [
        id,
      ]);
      if (rows.isEmpty || (rows.single['rowid'] as int) <= afterRow) {
        return null;
      }
    }
    return id;
  }

  void _changed() {
    if (_disposed) return;
    if (_running ||
        store.meta('projectId') != _projectId ||
        store.profileId != _actorId) {
      _pending.clear();
      _remember();
      return;
    }
    final tasks = store.tasks;
    final previousActivity = _activityCursor;
    _activityCursor = _latestActivityRow;
    final next = <String, ({int version, String status})>{};
    for (final task in tasks) {
      final previous = _observed[task.id];
      next[task.id] = (version: task.version, status: task.status);
      if (previous?.version != task.version) _pending.remove(task.id);
      if ((previous == null || previous.status != task.status) &&
          !task.isArchived) {
        final activityId = _localEvent(task, afterRow: previousActivity);
        if (activityId != null) {
          _pending[task.id] = (
            version: task.version,
            status: task.status,
            activityId: activityId,
          );
        }
      }
    }
    _observed = next;
    _pending.removeWhere((id, _) => !next.containsKey(id));
    if (_pending.isNotEmpty && !_scheduled) {
      _scheduled = true;
      scheduleMicrotask(_drain);
    }
  }

  void _message(String value) {
    if (_disposed || lastMessage == value) return;
    lastMessage = value;
    notifyListeners();
  }

  void _drain() {
    _scheduled = false;
    if (_disposed || _running || _pending.isEmpty) return;
    final batch = Map.of(_pending);
    _pending.clear();
    _running = true;
    try {
      for (final entry in batch.entries) {
        final task = store.tasks
            .where((task) => task.id == entry.key)
            .firstOrNull;
        if (task == null ||
            task.isArchived ||
            task.version != entry.value.version ||
            task.status != entry.value.status ||
            _localEvent(task) != entry.value.activityId) {
          continue;
        }
        _run(task);
      }
    } finally {
      _running = false;
      if (!_disposed) _remember();
    }
  }

  void _run(WorkTask initial) {
    var task = initial;
    final visited = <String>{task.status};
    final executedRoutes = <String>{};
    var steps = 0;
    while (!_disposed) {
      final project = store.project;
      final sheet = project?.workflowSheet;
      if (project == null || sheet == null || task.isArchived) return;
      if (steps > 0 && !isWorkflowRecipient(store.actor, task, project)) {
        _message(
          '${task.title} · 다음 담당자에게 전달했습니다. 이후 자동 처리는 해당 담당자의 입력을 기다립니다.',
        );
        return;
      }
      final automatic = {
        for (final route in sheet.outgoing(task.status))
          if (route.trigger == 'onEnter') route.id: route,
      };
      if (automatic.isEmpty) {
        if (steps > 0) {
          _message(
            '${task.title} · ${store.workflowStatusName(task.status)} 자동 전달 완료',
          );
        }
        return;
      }
      if (steps >= 8) {
        _message('${task.title} · 자동 전달 8단계에 도달했습니다. 다음 단계는 직접 확인하세요.');
        return;
      }
      final permitted = [
        ...store.availableHandoffs(task),
        ...store.availableTransfers(task),
      ].where((plan) => automatic.containsKey(plan.routeId)).toList();
      if (permitted.isEmpty) {
        _message('${task.title} · 자동 전달 대기: 설정한 파트 조건과 다음 처리 대상을 확인하세요.');
        return;
      }
      if (permitted.length != 1) {
        _message('${task.title} · 자동 전달 경로가 여러 개입니다. 전달할 경로를 직접 선택하세요.');
        return;
      }
      final plan = permitted.single;
      final route = automatic[plan.routeId]!;
      if (executedRoutes.contains(plan.routeId) ||
          !plan.maintainsStatus && visited.contains(plan.destinationId)) {
        _message('${task.title} · 순환 경로의 자동 전달을 멈췄습니다. 다음 단계를 직접 확인하세요.');
        return;
      }
      try {
        validateWorkflowRouteInputs(task, route);
        store.transition(
          task.id,
          plan.destinationId,
          expectedVersion: task.version,
          routeId: plan.routeId,
        );
        executedRoutes.add(plan.routeId);
        steps++;
        task = store.find(task.id);
        visited.add(task.status);
      } catch (error) {
        _message(
          '${task.title} · 자동 전달 대기: '
          '${error.toString().replaceFirst('Bad state: ', '')}',
        );
        return;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_changed);
    _pending.clear();
    super.dispose();
  }
}
