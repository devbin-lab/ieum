import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sheet roundtrip keeps card aliases and stable route recipients', () {
    const sheet = WorkflowSheet(
      nodes: [
        WorkflowSheetNode('doing-a', 'doing', x: -180, y: 20),
        WorkflowSheetNode('review-a', 'review', x: 140, y: -50),
        WorkflowSheetNode('review-copy', 'review', x: 140, y: 90),
      ],
      routes: [
        WorkflowSheetRoute(
          id: 'pd-review',
          from: 'doing-a',
          to: 'review-a',
          source: 'part:role-plan',
          destination: 'part:role-pd',
          person: 'gh-2',
        ),
      ],
    );
    final loaded = WorkflowSheet.fromJson(jsonDecode(jsonEncode(sheet.json)));
    expect(loaded.json, sheet.json);
    expect(loaded.stageFor('review-copy'), 'review');
    expect(loaded.outgoing('doing').single.id, 'pd-review');
    const moved = WorkflowSheet(
      nodes: [
        WorkflowSheetNode('new-alias', 'doing', x: 150, y: 320),
        WorkflowSheetNode('review-a', 'review', x: 80, y: 200),
      ],
      routes: [
        WorkflowSheetRoute(
          id: 'pd-review',
          from: 'new-alias',
          to: 'review-a',
          source: 'part:role-plan',
          destination: 'part:role-pd',
          person: 'gh-2',
        ),
      ],
    );
    expect(moved.policyJson, loaded.policyJson);
  });

  test('same-stage aliases roundtrip while invalid endpoints and nonfinite coordinates fail closed', () {
    const sameStage = WorkflowSheet(
      nodes: [WorkflowSheetNode('a', 'doing'), WorkflowSheetNode('b', 'doing')],
      routes: [WorkflowSheetRoute(id: 'self', from: 'a', to: 'b')],
    );
    expect(WorkflowSheet.fromJson(sameStage.json).json, sameStage.json);
    expect(
      () => WorkflowSheet.fromJson({
        ...sameStage.json,
        'routes': [
          const WorkflowSheetRoute(id: 'missing', from: 'a', to: 'none').json,
        ],
      }),
      throwsStateError,
    );
    expect(
      () => WorkflowSheetNode.fromJson({
        'id': 'a',
        'stageId': 'doing',
        'x': double.infinity,
        'y': 0,
      }),
      throwsStateError,
    );
  });

  test('default review approves completion and rejects to initial regardless of list order', () {
    final sheet = WorkflowSheet.defaultFor(['todo', 'review', 'doing', 'done']);
    expect(sheet.outgoing('review').map((r) => r.action), [
      'approve',
      'reject',
    ]);
    expect(sheet.outgoing('review').map((r) => sheet.stageFor(r.to)), [
      'done',
      'todo',
    ]);
    expect(sheet.outgoing('done'), isEmpty);
    expect(sheet.stageFor(sheet.outgoing('doing').single.to), 'review');
    expect(sheet.stageFor(sheet.outgoing('todo').single.to), 'doing');
    expect(WorkflowSheet.fromJson(sheet.json).json, sheet.json);
  });
}
