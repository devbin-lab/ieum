import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

const owner = Person('gh-1', '소유자', '소', 'owner', 0, login: 'owner');
const planner = Person(
  'gh-2',
  '기획자',
  '기',
  'unassigned',
  0,
  parts: ['기획'],
  login: 'planner',
);
const qa = Person(
  'gh-3',
  'QA',
  'Q',
  'unassigned',
  0,
  parts: ['QA'],
  login: 'qa',
);
const director = Person(
  'gh-4',
  'PD',
  'P',
  'unassigned',
  0,
  parts: ['PD'],
  login: 'director',
);
const inactive = Person(
  'gh-5',
  '비활성',
  '비',
  'disabled',
  0,
  parts: ['QA'],
  login: 'inactive',
);

ProjectManifest project({bool emptySheet = false}) => ProjectManifest(
  'collaborative-project',
  '협업 프로젝트',
  owner.id,
  const [owner, planner, qa, director, inactive],
  roles: const [
    ProjectRole('role-plan', '기획', {}),
    ProjectRole('role-qa', 'QA', {}),
    ProjectRole('role-pd', 'PD', {}),
  ],
  parts: const ['기획', 'QA', 'PD'],
  unifiedParts: true,
  workflowSheet: emptySheet
      ? const WorkflowSheet(nodes: [], routes: [])
      : WorkflowSheet.defaultFor(['todo', 'doing', 'done']),
);

WorkTask task({String status = 'doing'}) => WorkTask.fromJson({
  'id': 'TASK-COLLAB',
  'title': '기획 검증',
  'part': '기획',
  'assigneeId': planner.id,
  'reviewerId': director.id,
  'priority': 'normal',
  'assignedDate': '2026-10-08',
  'dueDate': '',
  'description': '기획 초안',
  'status': status,
  'completedDate': status == 'done' ? '2026-10-08' : '',
  'reworkReason': '',
  'workflowTarget': '',
  'workflowPerson': planner.id,
  'workflowRoute': '',
  'workflowPurpose': 'work',
  'version': 1,
  'updatedAt': '2026-10-08T00:00:00Z',
});

TaskStore storeFor(
  WorkTask base, {
  ProjectManifest? manifest,
  Person actor = planner,
}) {
  final store = TaskStore(
    ':memory:',
    project: manifest ?? project(),
    identity: actor,
    seed: [base.data],
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('editing legacy registration identities cannot silently transfer the current recipient', () {
    final base = task(status: 'review')
        .copy({'workflowTarget': 'legacy', 'workflowPerson': ''});
    final store = storeFor(base, actor: qa);
    final edited = store.save({
      ...base.data,
      'assigneeId': qa.id,
      'reviewerId': planner.id,
    }, expectedVersion: base.version);
    expect(edited.assigneeId, qa.id);
    expect(edited.reviewerId, planner.id);
    expect(edited.workflowPerson, director.id);
    expect(edited.workflowTarget, isEmpty);
    expect(edited.workflowSender, isEmpty);
    for (final collapsed in [false, true]) {
      expect(
        () => validateTaskMutation(
          actor: store.actor,
          current: base,
          next: base.copy({
            'reviewerId': planner.id,
            'version': collapsed ? 3 : 2,
          }),
          workflowProject: store.project,
          allowCollapsedTransitions: collapsed,
        ),
        throwsStateError,
      );
    }
  });

  test('edited default preset remains visible beside the unrestricted direct action', () {
    final original = project();
    final sheet = original.workflowSheet!;
    final modified = ProjectManifest.fromJson({
      ...original.json,
      'workflowSheet': WorkflowSheet(
        nodes: sheet.nodes,
        routes: [
          for (final route in sheet.routes)
            route.id == 'default-handoff'
                ? WorkflowSheetRoute.fromJson({
                    ...route.json,
                    'destination': 'part:role-pd',
                    'person': director.id,
                  })
                : route,
        ],
      ).json,
    });
    final base = task();
    final store = storeFor(base, manifest: modified);
    final plans = store.availableTransfers(base);
    final preset = plans.singleWhere((p) => p.routeId == 'default-handoff');
    final direct = plans.singleWhere((p) => p.routeId == 'manual-handoff');
    expect(preset.receiverPersonOptions.keys, [director.id]);
    expect(direct.receiverPersonOptions, contains(qa.id));
    expect(isDefaultWorkflowPreset(sheet.routes.first, original), isTrue);
    final layoutOnly = WorkflowSheetRoute.fromJson({
      ...sheet.routes.first.json,
      'labelDx': 50,
      'labelDy': -20,
    });
    expect(isDefaultWorkflowPreset(layoutOnly, original), isTrue);
    store.confirmHandoff(preset.withReceiver('', director.id));
    expect(store.find(base.id).status, 'doing');
    expect(store.find(base.id).workflowPerson, director.id);
    expect(store.find(base.id).workflowSender, planner.id);
  });

  test('planner to QA to PD and rejection preserve progress and return to the actual sender', () {
    final base = task();
    final store = storeFor(base);
    store.confirmHandoff(
      store.planHandoff(
        base,
        'doing',
        routeId: 'manual-handoff',
        receiverPerson: qa.id,
        purpose: 'review',
      ),
    );
    var current = store.find(base.id);
    expect(current.status, 'doing');
    expect(current.workflowPerson, qa.id);
    expect(current.workflowSender, planner.id);
    expect(store.isAssignedToMe(current), isFalse);
    expect(store.canEditContent(current), isTrue);
    current = store.save({
      ...current.data,
      'description': '기획자 후속 수정',
    }, expectedVersion: current.version);
    expect(current.workflowSender, planner.id);

    store.setMeta('profile', qa.id);
    expect(store.isAssignedToMe(current), isTrue);
    store.confirmHandoff(
      store.planHandoff(
        current,
        'doing',
        routeId: 'manual-handoff',
        receiverPerson: director.id,
        purpose: 'review',
      ),
    );
    current = store.find(base.id);
    expect(current.workflowSender, qa.id);
    expect(current.assigneeId, planner.id);
    expect(current.status, 'doing');

    store.setMeta('profile', director.id);
    final back = store
        .availableTransfers(current)
        .singleWhere((p) => p.routeId == 'manual-return');
    expect(back.receiverPerson, qa.id);
    expect(back.purpose, 'revision');
    expect(() => store.confirmHandoff(back), throwsStateError);
    store.confirmHandoff(back, reason: 'QA에서 범위를 보완해 주세요.');
    current = store.find(base.id);
    expect(current.status, 'doing');
    expect(current.workflowPerson, qa.id);
    expect(current.workflowSender, director.id);
    expect(current.workflowPurpose, 'revision');
    expect(current.reworkReason, contains('QA'));
    expect(store.canEditContent(current), isTrue);
    store.setMeta('profile', planner.id);
    expect(store.canEditContent(current), isTrue);
    expect(store.isAssignedToMe(current), isFalse);
  });

  test(
    'shared start, transfer and finish operate with an empty automation sheet',
    () {
      final base = task(status: 'todo');
      final store = storeFor(base, manifest: project(emptySheet: true));
      final start = store.availableHandoffs(base).single;
      expect(start.routeId, 'manual-start');
      expect(store.canMove(base, 'doing'), isTrue);
      store.transition(
        base.id,
        start.destinationId,
        expectedVersion: base.version,
      );
      var current = store.find(base.id);
      final transfer = store
          .availableTransfers(current)
          .singleWhere((p) => p.routeId == 'manual-handoff');
      expect(transfer.purpose, 'work');
      expect(transfer.canSelectPurpose, isTrue);
      store.confirmHandoff(
        transfer.withReceiver('', qa.id).withPurpose('review'),
      );
      current = store.find(base.id);
      expect(current.status, 'doing');
      expect(current.workflowPurpose, 'review');
      final finish = store.availableHandoffs(current).single;
      expect(finish.routeId, 'manual-finish');
      store.confirmHandoff(finish);
      current = store.find(base.id);
      expect(current.status, 'done');
      expect(current.completedDate, isNotEmpty);
      expect(store.canEditContent(current), isFalse);
      expect(store.availableTransfers(current), isEmpty);
    },
  );

  test(
    'same-stage transfer and later sender edit retain exact upload proof',
    () {
      final manifest = project();
      final base = task();
      final store = storeFor(base, manifest: manifest);
      store.confirmHandoff(
        store.planHandoff(
          base,
          'doing',
          routeId: 'manual-handoff',
          receiverPerson: qa.id,
          purpose: 'review',
        ),
      );
      final handed = store.find(base.id);
      final edited = store.save({
        ...handed.data,
        'description': '전달 후 추가 설명',
      }, expectedVersion: handed.version);
      final change = (store.exportChanges()['changes'] as List).single as Map;
      final revisions = parseWorkflowRevisions(change['steps'])!;
      expect(revisions, hasLength(2));
      expect(revisions.every((r) => r.workflowSender == planner.id), isTrue);
      validateTaskMutation(
        actor: store.actor,
        current: base,
        next: edited,
        workflowProject: manifest,
        allowCollapsedTransitions: true,
        revisions: revisions,
      );
      validateTaskMutation(
        actor: store.actor,
        current: base,
        next: edited,
        workflowProject: manifest,
        allowCollapsedTransitions: true,
      );
      expect(
        () => validateTaskMutation(
          actor: store.actor,
          current: base,
          next: handed.copy({'workflowSender': director.id}),
          workflowProject: manifest,
        ),
        throwsStateError,
      );
      expect(
        () => validateTaskMutation(
          actor: store.actor,
          current: base,
          next: handed.copy({'title': '한 번에 전달과 내용 변조'}),
          workflowProject: manifest,
        ),
        throwsStateError,
      );
    },
  );

  test('stale confirmation, inactive receiver and inactive sender never mutate the task', () {
    final base = task();
    final store = storeFor(base);
    final original = store
        .availableTransfers(base)
        .singleWhere((p) => p.routeId == 'manual-handoff');
    expect(original.receiverPersonOptions, isNot(contains(inactive.id)));
    expect(
      store.isHandoffCurrent(original.withReceiver('', inactive.id)),
      isFalse,
    );
    expect(
      () => store.transition(
        base.id,
        base.status,
        expectedVersion: base.version,
        routeId: 'manual-handoff',
        receiverPerson: inactive.id,
      ),
      throwsStateError,
    );
    expect(store.find(base.id).same(base), isTrue);
    store.save({...base.data, 'title': '최신 내용'}, expectedVersion: base.version);
    expect(
      () => store.confirmHandoff(original.withReceiver('', qa.id)),
      throwsStateError,
    );
    final fresh = store.find(base.id);
    store.setMeta('profile', inactive.id);
    expect(store.availableTransfers(fresh), isEmpty);
    expect(store.canEditContent(fresh), isFalse);
    expect(
      () => store.transition(
        fresh.id,
        fresh.status,
        expectedVersion: fresh.version,
        routeId: 'manual-handoff',
        receiverPerson: qa.id,
      ),
      throwsStateError,
    );
    expect(store.find(base.id).same(fresh), isTrue);
  });

  test('whole-part delivery changes personal inbox without granting exclusive edit ownership', () {
    final base = task();
    final store = storeFor(base);
    store.confirmHandoff(
      store.planHandoff(
        base,
        'doing',
        routeId: 'manual-handoff',
        receiverGroup: 'part:role-qa',
      ),
    );
    final current = store.find(base.id);
    expect(current.workflowPerson, isEmpty);
    expect(store.isAssignedToMe(current), isFalse);
    expect(store.canEditContent(current), isTrue);
    store.setMeta('profile', qa.id);
    expect(store.isAssignedToMe(current), isTrue);
    store.setMeta('profile', director.id);
    expect(store.isAssignedToMe(current), isFalse);
    expect(store.canEditContent(current), isTrue);
  });

  test('legacy sender defaults and states remain readable and unfinished tasks stay editable', () {
    final base = task(status: 'review');
    final store = storeFor(base, actor: qa);
    expect(base.workflowSender, isEmpty);
    expect(workflowBoardCategory(base, store.project), 'inProgress');
    expect(
      workflowBoardCategory(task(status: 'rework'), store.project),
      'inProgress',
    );
    expect(store.canEditContent(base), isTrue);
    final back = store
        .availableTransfers(base)
        .singleWhere((p) => p.routeId == 'manual-return');
    expect(back.receiverPerson, isEmpty);
    expect(back.hasRecipientSelection, isFalse);
    expect(() => store.confirmHandoff(back, reason: '대상 필요'), throwsStateError);
    store.confirmHandoff(
      back.withReceiver('', planner.id),
      reason: '명시 대상에게 반려',
    );
    expect(store.find(base.id).status, 'review');
    expect(store.find(base.id).workflowSender, qa.id);
  });
}
