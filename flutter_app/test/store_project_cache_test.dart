import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:sqlite3/sqlite3.dart';

const owner = Person(
  'gh-1',
  'Owner',
  'O',
  'owner',
  0xff777777,
  login: 'fixture-owner',
);

ProjectManifest manifest(String name) =>
    ProjectManifest('cache-project', name, owner.id, const [owner]);

void main() {
  late Directory directory;
  late TaskStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('ieum-project-cache-');
    store = TaskStore(
      '${directory.path}/project.sqlite',
      project: manifest('Original'),
      identity: owner,
    );
  });
  tearDown(() {
    store.dispose();
    directory.deleteSync(recursive: true);
  });

  test('unchanged metadata reuses the operational project snapshot', () {
    final first = store.project!;
    expect(identical(store.project, first), isTrue);
    expect(first.workflowStages.map((stage) => stage.id), [
      'todo',
      'doing',
      'review',
      'done',
      'hold',
      'drop',
    ]);
    expect(first.workflowSheet!.routes, isEmpty);
    expect(
      first.json,
      ProjectManifest.fromJson(manifest('Original').json).partWorkflowView.json,
    );
  });

  test('another database connection invalidates cached metadata', () {
    final first = store.project!;
    final external = sqlite3.open(store.filename);
    try {
      external.execute('UPDATE metadata SET value=? WHERE key=?', [
        jsonEncode(manifest('External').json),
        'project',
      ]);
      expect(store.project!.name, 'External');
      expect(identical(store.project, first), isFalse);
      external.execute('DELETE FROM metadata WHERE key=?', ['project']);
      expect(store.project, isNull);
    } finally {
      external.close();
    }
  });

  test('authorized update refreshes the snapshot and listeners', () {
    final first = store.project!;
    var notifications = 0;
    store.addListener(() => notifications++);
    store.updateProject(manifest('Updated'));
    expect(store.project!.name, 'Updated');
    expect(identical(store.project, first), isFalse);
    expect(notifications, 1);
  });

  test(
    'rollback restores metadata after the transaction snapshot was read',
    () {
      expect(store.project!.name, 'Original');
      expect(
        () => store.transaction<void>(() {
          store.setMeta('project', jsonEncode(manifest('Uncommitted').json));
          expect(store.project!.name, 'Uncommitted');
          throw StateError('rollback fixture');
        }),
        throwsStateError,
      );
      expect(store.project!.name, 'Original');
      expect(store.meta('project'), jsonEncode(manifest('Original').json));
    },
  );

  test('empty and missing metadata can transition back to a project', () {
    expect(store.project, isNotNull);
    store.setMeta('project', '');
    expect(store.project, isNull);
    expect(store.project, isNull);
    store.setMeta('project', jsonEncode(manifest('Restored').json));
    expect(store.project!.name, 'Restored');

    final empty = TaskStore(':memory:');
    try {
      expect(empty.project, isNull);
      empty.setMeta('project', jsonEncode(manifest('Created').json));
      expect(empty.project!.name, 'Created');
    } finally {
      empty.dispose();
    }
  });

  test(
    'invalid metadata is rejected instead of returning a stale snapshot',
    () {
      final original = store.project!;
      store.setMeta('project', '{');
      expect(() => store.project, throwsFormatException);
      expect(() => store.project, throwsFormatException);
      store.setMeta(
        'project',
        jsonEncode({...manifest('Bad').json, 'schemaVersion': 99}),
      );
      expect(() => store.project, throwsStateError);
      store.setMeta('project', jsonEncode(manifest('Original').json));
      expect(identical(store.project, original), isTrue);
    },
  );

  test('baseline preserves body IDs and validates each decoded task', () {
    final task = WorkTask.fromJson({
      'id': 'cache-task',
      'title': 'Temporary fixture',
      'part': '기획',
      'status': 'todo',
      'priority': 'normal',
      'assigneeId': owner.id,
      'reviewerId': owner.id,
      'assignedDate': '2026-10-10',
      'dueDate': '',
      'completedDate': '',
      'description': '',
      'reworkReason': '',
      'version': 1,
      'updatedAt': '2026-10-10T00:00:00Z',
    });
    // Body IDs remain authoritative as they were before single-decode loading.
    store.db.execute('INSERT INTO baseline_tasks VALUES (?, ?)', [
      'legacy-row-key',
      jsonEncode(task.data),
    ]);
    expect(store.baseline.keys, ['cache-task']);
    expect(store.baseline['cache-task']!.data, task.data);
    store.db.execute('UPDATE baseline_tasks SET body=?', [
      jsonEncode({...task.data, 'unsupported': true}),
    ]);
    expect(() => store.baseline, throwsStateError);
  });
}
