import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/models.dart';

void main() {
  final seed =
      jsonDecode(File('assets/demo-snapshot.json').readAsStringSync())['tasks']
          as List;
  late TaskStore store;
  setUp(() => store = TaskStore(':memory:', seed: seed));
  tearDown(() => store.dispose());
  Map<String, dynamic> snapshot() => {
    'schemaVersion': 1,
    'projectId': 'ieum-demo',
    'revision': 'test-main',
    'tasks': jsonDecode(jsonEncode(seed)),
  };
  test('review and rework return ownership; only reviewer can approve', () {
    void move(String status, {String reason = ''}) => store.transition(
      'IE-101',
      status,
      reason: reason,
      expectedVersion: store.find('IE-101').version,
    );
    expect(() => move('done'), throwsStateError);
    move('doing');
    move('review');
    expect(store.find('IE-101').currentId, 'pm');
    expect(store.notifications.first['recipientId'], 'pm');
    expect(() => move('done'), throwsStateError);
    store.setProfile('pm');
    expect(() => move('rework'), throwsStateError);
    move('rework', reason: '완료 조건 보완');
    expect(store.find('IE-101').currentId, 'planner');
    move('doing');
    move('review');
    move('done');
    expect(store.find('IE-101').completedDate, localDate());
    expect(store.notifications.length, 6);
  });
  test('validation, permissions, stale versions and bypass attempts', () {
    final t = store.find('IE-101');
    expect(
      () => store.save({
        ...t.data,
        'dueDate': '2026-02-30',
      }, expectedVersion: t.version),
      throwsStateError,
    );
    expect(
      () => store.save({
        ...t.data,
        'dueDate': '2026-09-01',
      }, expectedVersion: t.version),
      throwsStateError,
    );
    store.setProfile('artist');
    expect(
      () =>
          store.save({...t.data, 'title': '권한 오류'}, expectedVersion: t.version),
      throwsStateError,
    );
    store.setProfile('planner');
    store.save({
      ...t.data,
      'title': '수정',
      'status': 'done',
      'completedDate': '2026-10-01',
    }, expectedVersion: t.version);
    expect(store.find(t.id).status, 'todo');
    expect(store.find(t.id).completedDate, '');
    expect(
      () =>
          store.save({...t.data, 'title': '이전 변경'}, expectedVersion: t.version),
      throwsStateError,
    );
  });
  test('three-way import preserves local fields and updates remote fields', () {
    final t = store.find('IE-101');
    store.save({...t.data, 'title': '개인 제목'}, expectedVersion: t.version);
    final remote = snapshot();
    remote['tasks'][0]['dueDate'] = '2026-10-11';
    expect(store.importSnapshot(remote).applied, true);
    expect(store.find(t.id).title, '개인 제목');
    expect(store.find(t.id).dueDate, '2026-10-11');
    expect((store.changes.single['fields'] as List).single['key'], 'title');
  });
  test('conflicts are atomic; incompatible relationships and missing IDs stop import', () {
    final t = store.find('IE-101');
    store.save({...t.data, 'title': '개인 제목'}, expectedVersion: t.version);
    final before = jsonEncode(store.tasks.map((t) => t.data).toList());
    final remote = snapshot();
    remote['tasks'][0]['title'] = '통합 제목';
    remote['tasks'][1]['title'] = '다른 제목';
    expect(store.importSnapshot(remote).applied, false);
    expect(jsonEncode(store.tasks.map((t) => t.data).toList()), before);
    expect(store.baseRevision, 'demo-initial');
    remote['tasks'].removeLast();
    expect(() => store.importSnapshot(remote), throwsStateError);
  });
  test('different date fields that combine invalidly are a merge conflict', () {
    final t = store.find('IE-101');
    store.save({
      ...t.data,
      'assignedDate': '2026-10-04',
    }, expectedVersion: t.version);
    final remote = snapshot();
    remote['tasks'][0]['dueDate'] = '2026-10-02';
    expect(store.importSnapshot(remote).applied, false);
    expect(store.find(t.id).dueDate, '2026-10-05');
  });
  test('SQLite persists data and common JSON export after reopening', () {
    final dir = Directory.systemTemp.createTempSync('ieum-flutter-test-');
    final filename = '${dir.path}${Platform.pathSeparator}ieum.sqlite';
    final db = TaskStore(filename, seed: seed);
    final t = db.find('IE-101');
    db.save({...t.data, 'title': '영구 저장'}, expectedVersion: t.version);
    db.setProfile('pm');
    db.dispose();
    final reopened = TaskStore(filename);
    try {
      expect(reopened.find(t.id).title, '영구 저장');
      expect(reopened.profileId, 'pm');
      final exported = reopened.exportChanges();
      expect(exported['schemaVersion'], 1);
      expect(exported['projectId'], 'ieum-demo');
      expect((exported['changes'] as List).single['base']['title'], t.title);
    } finally {
      reopened.dispose();
      if (dir.parent.absolute.path != Directory.systemTemp.absolute.path ||
          !dir.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('ieum-flutter-test-')) {
        throw StateError('Unexpected test data path');
      }
      dir.deleteSync(recursive: true);
    }
  });
}
