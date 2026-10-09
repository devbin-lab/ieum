import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

/// Compile this entry point with the Windows Release runner. It tests native
/// AOT registration, not a live project or network. All databases are temporary.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final folder = Directory.systemTemp.createTempSync('ieum-registration-aot-');
  final markerPath = Platform.environment['IEUM_REGISTRATION_PROBE_RESULT'];
  void stage(String value) {
    if (markerPath != null) {
      File(markerPath).writeAsStringSync(value, flush: true);
    }
  }

  const owner = Person('gh-1', '관리자', '관', 'owner', 0, login: 'owner');
  const worker = Person(
    'gh-2',
    '작업자',
    '작',
    'unassigned',
    0,
    login: 'worker',
    parts: ['기획'],
  );
  final project = ProjectManifest(
    'aot-registration-fixture',
    '임시 코드 검사',
    owner.id,
    [owner, worker],
    parts: const ['기획'],
    roles: const [ProjectRole('role-plan', '기획', {})],
    unifiedParts: true,
    workflowSheet: WorkflowSheet.defaultFor(['todo', 'doing', 'done']),
  );
  TaskStore? store;
  var result = 0;
  try {
    for (final actor in [owner, worker]) {
      final path = '${folder.path}${Platform.pathSeparator}${actor.id}.sqlite';
      store = TaskStore(path, project: project, identity: actor);
      for (var i = 0; i < 3; i++) {
        stage('save-${actor.id}-$i');
        var task = store.save({
          'lockedBy': actor.id,
          'title': '새 작업 등록 코드 검사',
          'description': '',
          'part': '기획',
          'assigneeId': worker.id,
          'reviewerId': owner.id,
          'priority': 'normal',
          'assignedDate': '2026-10-08',
          'dueDate': '',
        });
        task = store.setTaskPinned(
          task.id,
          true,
          expectedVersion: task.version,
        );
        task = store.save({
          ...task.data,
          'description': '수정 검사',
        }, expectedVersion: task.version);
        if (!task.isPinned) throw StateError('Pin was lost during edit');
        task = store.setTaskPinned(
          task.id,
          false,
          expectedVersion: task.version,
        );
        task = store.addTaskComment(
          task.id,
          '잠금과 코멘트 Release 검사',
          expectedVersion: task.version,
        );
        task = store.setTaskLocked(
          task.id,
          false,
          expectedVersion: task.version,
        );
        store.transition(
          task.id,
          'doing',
          routeId: 'manual-start',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        final recipient = actor.id == owner.id ? worker : owner;
        final plan = store
            .planHandoff(
              task,
              'todo',
              routeId: 'manual-handoff',
              receiverPerson: recipient.id,
            )
            .withLock(false);
        store.confirmHandoff(plan);
        task = store.find(task.id);
        store.transition(
          task.id,
          'doing',
          routeId: 'manual-start',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        store.transition(
          task.id,
          'review',
          routeId: 'manual-review',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        store.transition(
          task.id,
          'hold',
          routeId: 'manual-hold',
          reason: 'Release hold check',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        store.transition(
          task.id,
          'review',
          routeId: 'manual-resume',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        store.transition(
          task.id,
          'drop',
          routeId: 'manual-drop',
          reason: 'Release drop check',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        store.transition(
          task.id,
          'todo',
          routeId: 'manual-restore',
          expectedVersion: task.version,
        );
        task = store.find(task.id);
        if (task.creatorId != actor.id ||
            task.initialAssigneeId != worker.id ||
            task.transitionHistory.length != 8 ||
            task.pausedFrom.isNotEmpty) {
          throw StateError('Six-channel history check failed');
        }
        store.deleteTask(task.id, expectedVersion: task.version);
      }
      store.dispose();
      store = TaskStore(path);
      if (store.tasks.isNotEmpty ||
          store.storedTasks.length != 3 ||
          store.db.select('PRAGMA quick_check').single.values.single != 'ok') {
        throw StateError('Release registration check failed');
      }
      store.dispose();
      store = null;
    }
    stage('passed');
  } catch (error) {
    stage('failed: ${error.runtimeType}');
    result = 1;
  } finally {
    store?.dispose();
    if (folder.absolute.parent.path != Directory.systemTemp.absolute.path ||
        !folder.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('ieum-registration-aot-')) {
      throw StateError('Unexpected temporary database directory');
    }
    folder.deleteSync(recursive: true);
  }
  exit(result);
}
