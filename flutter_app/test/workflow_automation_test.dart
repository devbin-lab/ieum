import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_policy_test.dart'
    show
        configured,
        nodes,
        routes,
        admin,
        planner,
        director,
        otherDirector,
        artist,
        draft;

void main() {
  late TaskStore store;
  setUp(
    () =>
        store = TaskStore(':memory:', project: configured(), identity: planner),
  );
  tearDown(() => store.dispose());
  WorkTask move(WorkTask task, String to) {
    store.confirmHandoff(store.planHandoff(task, to));
    return store.find(task.id);
  }

  test('active project membership permits editing and common start independently of assignment', () {
    final task = store.save(draft());
    expect(task.workflowPerson, planner.id);
    store.setMeta('profile', artist.id);
    expect(store.canEdit(task), isTrue);
    expect(store.canMove(task, 'doing'), isTrue);
    store.setMeta('profile', planner.id);
    expect(store.canMove(task, 'doing'), isTrue);
  });

  test('part IDs and multiple same-destination routes round trip', () {
    final sheet = WorkflowSheet(
      nodes: nodes,
      routes: [
        ...routes,
        const WorkflowSheetRoute(
          id: 'private',
          from: 'doing',
          to: 'review',
          source: 'part:role-plan',
          destination: 'part:role-pd',
          person: 'gh-3',
        ),
      ],
    );
    final parsed = WorkflowSheet.fromJson(jsonDecode(jsonEncode(sheet.json)));
    expect(parsed.outgoing('doing').map((r) => r.id), ['submit', 'private']);
    expect(parsed.json, sheet.json);
    expect(
      () => WorkflowSheet.fromJson({
        ...sheet.json,
        'routes': [...sheet.routes.map((r) => r.json), sheet.routes.first.json],
      }),
      throwsStateError,
    );
  });

  test('source part conditions are independent of the task origin part', () {
    final task = move(store.save({...draft(), 'part': '아트'}), 'doing');
    expect(store.canMove(task, 'review'), isTrue);
    store.setMeta('profile', artist.id);
    expect(store.canMove(task, 'review'), isFalse);
  });

  test('part-wide receivers drive the inbox while all active participants retain collaboration', () {
    final task = move(move(store.save(draft()), 'doing'), 'review');
    for (final p in [director, otherDirector]) {
      store.setMeta('profile', p.id);
      expect(store.canMove(task, 'done'), isTrue);
      expect(store.canEditContent(task), isTrue);
    }
    store.setMeta('profile', artist.id);
    expect(store.canMove(task, 'done'), isTrue);
  });

  test('part rename preserves routing and shows the new recipient name', () {
    final task = move(move(store.save(draft()), 'doing'), 'review');
    store.updateProject(
      ProjectManifest.fromJson({
        ...store.project!.json,
        'roles': [
          for (final r in store.project!.roles)
            if (r.id == 'role-pd') {...r.json, 'name': '디렉터'} else r.json,
        ],
        'parts': ['기획', '디렉터', '아트'],
        'members': [
          for (final p in store.people)
            {
              ...p.json,
              'parts': [
                for (final name in p.parts)
                  if (name == 'PD') '디렉터' else name,
              ],
            },
        ],
      }),
    );
    store.setMeta('profile', director.id);
    expect(store.canMove(task, 'done'), isTrue);
    expect(store.currentActorLabel(task), '디렉터 전체');
  });

  test('missing receiver part never becomes an unrestricted group', () {
    final task = move(store.save(draft()), 'doing');
    store.updateProject(
      ProjectManifest.fromJson({
        ...store.project!.json,
        'roles': [
          for (final r in store.project!.roles)
            if (r.id != 'role-pd') r.json,
        ],
        'parts': ['기획', '아트'],
        'members': [
          for (final p in store.people)
            {
              ...p.json,
              'parts': p.parts.where((name) => name != 'PD').toList(),
            },
        ],
      }),
    );
    expect(store.canMove(task, 'review'), isFalse);
    expect(store.availableHandoffs(task).map((p) => p.routeId), [
      'manual-finish',
    ]);
  });

  test(
    'inactive exact receiver blocks its path even if other members remain',
    () {
      store.updateProject(
        configured(
          links: [
            for (final r in routes)
              if (r.id == 'submit')
                WorkflowSheetRoute(
                  id: r.id,
                  from: r.from,
                  to: r.to,
                  source: r.source,
                  destination: r.destination,
                  person: director.id,
                )
              else
                r,
          ],
        ),
      );
      final task = move(store.save(draft()), 'doing');
      store.updateProject(
        configured(
          links: store.project!.workflowSheet!.routes,
          people: [
            admin,
            planner,
            Person(
              director.id,
              director.name,
              director.initials,
              'unassigned',
              0,
              login: director.login,
              parts: director.parts,
              enabled: false,
            ),
            otherDirector,
            artist,
          ],
        ),
      );
      expect(store.canMove(task, 'review'), isFalse);
    },
  );

  test(
    'archived automation is readable but does not become operational routing',
    () {
      final old = ProjectManifest(
        'old-project',
        '이전 프로젝트',
        admin.id,
        [admin, planner, director],
        parts: const ['기획', 'PD'],
        workflowAutomation: const WorkflowAutomation(
          disabledConnections: ['todo/advance'],
        ),
      );
      final managed = old.partWorkflowView;
      expect(managed.workflowAutomation.disabledConnections, ['todo/advance']);
      expect(managed.workflowSheet!.outgoing('todo'), isNotEmpty);
      expect(managed.activeWorkflowConnections, isEmpty);
      expect(managed.usesManualWorkflow, isFalse);
    },
  );
}
