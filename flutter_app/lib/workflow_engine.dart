part of 'models.dart';

// Shared transition policy for local edits, upload admission and PR integration.
List<WorkTask>? parseWorkflowRevisions(dynamic raw) {
  if (raw == null) return null;
  if (raw is! List ||
      raw.isEmpty ||
      raw.length > maxTaskRevisionAdvance ||
      raw.any((step) => step is! Map)) {
    throw StateError('작업 변경 순서의 형식과 개수를 확인하세요.');
  }
  return List.unmodifiable(
    raw.map((step) => WorkTask.fromJson(Map<String, dynamic>.from(step))),
  );
}

bool workflowGroupContains(
  String group,
  Person person,
  ProjectManifest project,
) {
  if (group.isEmpty) return true;
  if (group == 'role:owner') return person.id == project.ownerId;
  if (!group.startsWith('part:')) return false;
  final part = project.roles
      .where((r) => r.id == group.substring(5))
      .firstOrNull;
  return part != null && person.parts.contains(part.name);
}

/// Processing intent is separate from a board status. Older files derive it
/// from their explicit review stage or saved rejection route without rewriting
/// historical task revisions.
String workflowTaskPurpose(WorkTask task, ProjectManifest? project) {
  if (task.workflowPurpose.isNotEmpty) return task.workflowPurpose;
  if (task.status == 'rework') return 'revision';
  final route = project?.workflowSheet?.routes
      .where((r) => r.id == task.workflowRoute)
      .firstOrNull;
  if (route?.action == 'reject') return 'revision';
  if (task.status == 'review' ||
      project != null &&
          project.isLockedStatus(task.status) &&
          !project.isCompleteStatus(task.status)) {
    return 'review';
  }
  return 'work';
}

String workflowBoardCategory(WorkTask task, ProjectManifest? project) {
  if (task.isPaused || task.isDropped) return task.status;
  final stage = project?.stage(task.status);
  if (stage?.isCompleted == true || stage == null && task.status == 'done') {
    return 'done';
  }
  if (task.status == 'rework' ||
      task.status == 'review' && (stage == null || stage.category.isEmpty)) {
    return 'inProgress';
  }
  return stage?.resolvedCategory ??
      (task.status == 'todo' ? 'todo' : 'inProgress');
}

String workflowCurrentPartLabel(WorkTask task, ProjectManifest? project) {
  if (project == null) return task.part;
  if (task.workflowTarget == 'role:owner') return '관리자';
  if (task.workflowTarget.startsWith('part:')) {
    return project.roles
            .where((r) => 'part:${r.id}' == task.workflowTarget)
            .firstOrNull
            ?.name ??
        '삭제된 파트';
  }
  final personId = task.workflowTarget == 'legacy'
      ? task.currentId
      : task.workflowPerson;
  if (personId.isEmpty) return '모든 파트';
  final person = project.people.where((p) => p.id == personId).firstOrNull;
  if (person == null) return '참여자 없음';
  return person.parts.isEmpty ? '파트 미배정' : person.parts.join(' · ');
}

/// A selectable receiver is still constrained by the saved route. Empty group
/// means an individual selection; empty group and person never means everyone.
bool workflowSelectedReceiverAllowed(
  WorkflowSheetRoute route,
  ProjectManifest project, {
  required String group,
  required String person,
}) {
  if (group.isEmpty && person.isEmpty) return false;
  if (group.isNotEmpty &&
      group != 'role:owner' &&
      !project.roles.any((r) => 'part:${r.id}' == group)) {
    return false;
  }
  if (route.destination.isNotEmpty &&
      group.isNotEmpty &&
      group != route.destination) {
    return false;
  }
  if (route.person.isNotEmpty && person != route.person) return false;
  return project.people.any(
    (p) =>
        p.active &&
        (person.isEmpty || person == p.id) &&
        workflowGroupContains(group, p, project) &&
        workflowGroupContains(route.destination, p, project),
  );
}

String workflowInitialPerson(
  ProjectManifest project,
  String stage,
  String assigneeId,
) =>
    project.workflowSheet!.routes.any((r) => r.assignment == 'select') ||
        project.workflowSheet!
            .outgoing(stage)
            .any(
              (r) =>
                  r.source.isNotEmpty ||
                  r.destination.isNotEmpty ||
                  r.person.isNotEmpty,
            )
    ? assigneeId
    : '';

bool isWorkflowRecipient(
  Person actor,
  WorkTask task,
  ProjectManifest project,
) =>
    actor.active &&
    project.people.any((p) => p.id == actor.id && p.active) &&
    (task.workflowTarget == 'legacy'
        ? actor.id == task.currentId
        : workflowGroupContains(task.workflowTarget, actor, project) &&
              (task.workflowPerson.isEmpty || task.workflowPerson == actor.id));

bool canEditWorkflowTask(
  Person actor,
  WorkTask task,
  ProjectManifest project,
) =>
    actor.active &&
    !task.isDeleted &&
    !task.isArchived &&
    !task.isPaused &&
    !task.isDropped &&
    hasTaskLockAccess(actor, task) &&
    !project.isCompleteStatus(task.status) &&
    project.people.any((p) => p.id == actor.id && p.active);

const directWorkflowRouteIds = {
  'manual-start',
  'manual-finish',
  'manual-handoff',
  'manual-review',
  'manual-hold',
  'manual-resume',
  'manual-drop',
  'manual-restore',
};

/// Built-in presets are hidden only while their executable policy remains the
/// default. Moving their cards or labels does not create duplicate buttons;
/// editing a receiver, condition or trigger makes the preset an explicit action.
bool isDefaultWorkflowPreset(
  WorkflowSheetRoute route,
  ProjectManifest project,
) {
  if (!route.id.startsWith('default-')) return false;
  final sheet = project.workflowSheet;
  if (sheet == null) return false;
  final defaults = WorkflowSheet.defaultFor(
    project.workflowStages.map((s) => s.id).toList(),
  );
  final canonical = defaults.routes.where((r) => r.id == route.id).firstOrNull;
  if (canonical == null) return false;
  Map<String, dynamic> policy(WorkflowSheet source, WorkflowSheetRoute item) {
    final value = Map<String, dynamic>.from(
      (WorkflowSheet(nodes: source.nodes, routes: [item]).policyJson['routes']
                  as List)
              .single
          as Map,
    );
    if (value['requiredFields'] case final List fields) {
      value['requiredFields'] = [...fields]..sort();
    }
    return value;
  }

  return jsonEncode(policy(sheet, route)) ==
      jsonEncode(policy(defaults, canonical));
}

/// Shared project actions do not depend on a saved automation route. A current
/// recipient drives the inbox; it is not an exclusive edit or delivery grant.
const directActionRouteIds = [
  'manual-start',
  'manual-review',
  'manual-finish',
  'manual-hold',
  'manual-resume',
  'manual-drop',
  'manual-restore',
];

WorkflowSheetRoute? directWorkflowRoute(
  WorkTask task,
  ProjectManifest project,
  String id,
) {
  if (!directWorkflowRouteIds.contains(id) ||
      task.isDeleted ||
      task.isArchived ||
      project.isCompleteStatus(task.status)) {
    return null;
  }
  final start = task.workflowPurpose == 'review' ? 'review' : 'doing';
  return switch (id) {
    'manual-start' when task.status == 'todo' || task.status == 'rework' =>
      WorkflowSheetRoute(
        id: id,
        from: task.status,
        to: start,
        name: start == 'review' ? '검토 시작' : '작업 시작',
        operation: 'start',
        assignment: 'keep',
      ),
    'manual-review' when task.status == 'doing' => WorkflowSheetRoute(
      id: id,
      from: task.status,
      to: 'review',
      name: '검토 시작',
      operation: 'start',
      assignment: 'keep',
    ),
    'manual-finish' when const {'doing', 'review'}.contains(task.status) =>
      WorkflowSheetRoute(
        id: id,
        from: task.status,
        to: 'done',
        name: '완료',
        operation: 'finish',
        assignment: 'keep',
        action: 'approve',
      ),
    'manual-handoff' when const {'doing', 'review'}.contains(task.status) =>
      WorkflowSheetRoute(
        id: id,
        from: task.status,
        to: 'todo',
        name: '전달',
        operation: 'handoff',
        assignment: 'select',
      ),
    'manual-hold'
        when const {
          'todo',
          'doing',
          'review',
          'rework',
        }.contains(task.status) =>
      WorkflowSheetRoute(
        id: id,
        from: task.status,
        to: 'hold',
        name: '보류',
        operation: 'move',
        assignment: 'keep',
        commentRequired: true,
      ),
    'manual-resume' when task.status == 'hold' => WorkflowSheetRoute(
      id: id,
      from: task.status,
      to: task.pausedFrom.isEmpty ? 'todo' : task.pausedFrom,
      name: '작업 재개',
      operation: 'move',
      assignment: 'keep',
    ),
    'manual-drop'
        when const {
          'todo',
          'doing',
          'review',
          'rework',
          'hold',
        }.contains(task.status) =>
      WorkflowSheetRoute(
        id: id,
        from: task.status,
        to: 'drop',
        name: '드랍',
        operation: 'move',
        assignment: 'keep',
        commentRequired: true,
      ),
    'manual-restore' when task.status == 'drop' => WorkflowSheetRoute(
      id: id,
      from: task.status,
      to: 'todo',
      name: '복원',
      operation: 'move',
      assignment: 'keep',
    ),
    _ => null,
  };
}

WorkTask applyDirectWorkflowRoute(
  WorkTask task,
  WorkflowSheetRoute route,
  ProjectManifest project, {
  required String actorId,
  String receiverGroup = '',
  String receiverPerson = '',
  String purpose = '',
  String reason = '',
  String? completionDate,
  bool? lockOnHandoff,
  String? at,
}) {
  if (!hasTaskLockAccess(
        project.people.firstWhere((p) => p.id == actorId),
        task,
      ) ||
      !project.people.any((p) => p.id == actorId && p.active) ||
      directWorkflowRoute(task, project, route.id)?.to != route.to) {
    throw StateError('활성 참여자와 현재 작업 상태를 확인하세요.');
  }
  validateWorkflowRouteInputs(task, route, comment: reason);
  final transfer = route.assignment == 'select';
  if (transfer &&
      !workflowSelectedReceiverAllowed(
        route,
        project,
        group: receiverGroup,
        person: receiverPerson,
      )) {
    throw StateError('전달받을 활성 파트 또는 작업자를 선택하세요.');
  }
  if (!const {'', 'work', 'review', 'revision'}.contains(purpose) ||
      route.id == 'manual-return' &&
          purpose.isNotEmpty &&
          purpose != 'revision' ||
      !transfer &&
          purpose.isNotEmpty &&
          purpose != task.workflowPurpose &&
          !(route.id == 'manual-review' && purpose == 'review')) {
    throw StateError('전달 방식과 요청 유형을 확인하세요.');
  }
  final target = transfer
      ? receiverGroup
      : task.workflowTarget == 'legacy'
      ? ''
      : task.workflowTarget;
  final person = transfer
      ? receiverPerson
      : task.workflowTarget == 'legacy'
      ? task.currentId
      : task.workflowPerson;
  final intent = transfer
      ? (purpose.isEmpty ? 'work' : purpose)
      : route.id == 'manual-review'
      ? 'review'
      : task.workflowPurpose;
  final transferLocked = transfer && (lockOnHandoff ?? task.isLocked);
  if (transferLocked && receiverPerson.isEmpty) {
    throw StateError('잠근 채 전달하려면 특정 담당자 한 명을 선택하세요.');
  }
  final stamp = at ?? task.data['updatedAt'] as String;
  return task.copy({
    'pausedFrom': route.id == 'manual-hold'
        ? task.status
        : route.to == 'hold'
        ? task.pausedFrom
        : '',
    'transitionHistory': appendTaskTransition(
      task,
      route,
      actorId: actorId,
      person: person,
      group: target,
      purpose: intent,
      at: stamp,
      comment: reason,
    ),
    'lockedBy': transfer
        ? (transferLocked ? receiverPerson : '')
        : task.lockedBy,
    'status': route.to,
    'workflowTarget': target,
    'workflowPerson': person,
    'workflowRoute': route.id,
    'workflowPurpose': intent,
    'workflowSender': transfer ? actorId : task.workflowSender,
    'completedDate': project.isCompleteStatus(route.to)
        ? completionDate ?? localDate()
        : '',
    'reworkReason': reason.trim().isEmpty ? task.reworkReason : reason.trim(),
  });
}

bool workflowReceiverAvailable(
  WorkflowSheetRoute route,
  ProjectManifest project, {
  WorkTask? task,
  Person? actor,
}) {
  if (route.assignment == 'select') {
    return project.people.any(
      (p) => workflowSelectedReceiverAllowed(
        route,
        project,
        group: '',
        person: p.id,
      ),
    );
  }
  if (route.assignment == 'keep') {
    return task != null &&
        project.people.any((p) => isWorkflowRecipient(p, task, project));
  }
  if (const {'assignee', 'actor', 'sender'}.contains(route.assignment)) {
    final id = switch (route.assignment) {
      'actor' => actor?.id,
      'sender' => task?.workflowSender,
      _ => task?.assigneeId,
    };
    return project.people.any((p) => p.id == id && p.active);
  }
  return project.people.any(
    (p) =>
        p.active &&
        workflowGroupContains(route.destination, p, project) &&
        (route.person.isEmpty || route.person == p.id),
  );
}

/// Transition validators are evaluated when executing, separately from the
/// conditions that decide which action buttons the current participant sees.
void validateWorkflowRouteInputs(
  WorkTask task,
  WorkflowSheetRoute route, {
  String comment = '',
}) {
  if (route.requiresComment && comment.trim().isEmpty) {
    throw StateError(route.action == 'reject' ? '반려 사유를 입력하세요.' : '댓글을 입력하세요.');
  }
  for (final field in route.requiredFields) {
    if ((task.data[field] as String).trim().isEmpty) {
      throw StateError('${fieldLabels[field]} 입력 후 전환하세요.');
    }
  }
}

List<WorkflowSheetRoute> availableWorkflowRoutes(
  Person actor,
  WorkTask task,
  ProjectManifest project,
) {
  final sheet = project.workflowSheet;
  if (sheet == null ||
      task.isDeleted ||
      task.isArchived ||
      !actor.active ||
      !project.people.any((p) => p.id == actor.id && p.active)) {
    return const [];
  }
  final owner = actor.id == project.ownerId;
  // Specific sender routes replace broad fallbacks for the same operation.
  // Resolve precedence before checking recipients: an unavailable specific
  // recipient must not silently open a less restrictive all-worker route.
  final outgoing = sheet
      .outgoing(task.status)
      .where(
        (r) =>
            r.requiredPurpose.isEmpty ||
            r.requiredPurpose == workflowTaskPurpose(task, project),
      );
  final specificActions = outgoing
      .where(
        (r) =>
            r.source.isNotEmpty &&
            workflowGroupContains(r.source, actor, project),
      )
      .map((r) => r.effectiveOperation)
      .toSet();
  return outgoing
      .where(
        (r) =>
            (owner || workflowGroupContains(r.source, actor, project)) &&
            (!specificActions.contains(r.effectiveOperation) ||
                r.source.isNotEmpty &&
                    workflowGroupContains(r.source, actor, project)) &&
            project.stage(sheet.stageFor(r.to) ?? '') != null &&
            workflowReceiverAvailable(r, project, task: task, actor: actor),
      )
      .toList();
}

WorkTask applyWorkflowRoute(
  WorkTask task,
  WorkflowSheetRoute route,
  ProjectManifest project, {
  String reason = '',
  String? completionDate,
  String actorId = '',
  String receiverGroup = '',
  String receiverPerson = '',
  bool preserveLegacyPurpose = true,
  bool recordSender = true,
}) {
  if (route.assignment == 'select' &&
      !workflowSelectedReceiverAllowed(
        route,
        project,
        group: receiverGroup,
        person: receiverPerson,
      )) {
    throw StateError('전달받을 파트 또는 활성 작업자를 선택하세요.');
  }
  final (target, person) = switch (route.assignment) {
    'select' => (receiverGroup, receiverPerson),
    'keep' =>
      task.workflowTarget == 'legacy'
          ? ('', task.currentId)
          : (task.workflowTarget, task.workflowPerson),
    'assignee' => ('', task.assigneeId),
    'sender' => ('', task.workflowSender),
    'actor' => ('', actorId),
    _ => (route.destination, route.person),
  };
  if (route.assignment == 'actor' && actorId.isEmpty) {
    throw StateError('전환 실행자를 확인하세요.');
  }
  var purpose = route.purpose.isEmpty ? task.workflowPurpose : route.purpose;
  if (purpose.isEmpty && preserveLegacyPurpose) {
    final inferred = route.action == 'reject'
        ? 'revision'
        : workflowTaskPurpose(task, project);
    if (inferred != 'work') purpose = inferred;
  }
  return task.copy({
    'status': project.workflowSheet!.stageFor(route.to)!,
    'workflowTarget': target,
    'workflowPerson': person,
    'workflowRoute': route.id,
    'workflowPurpose': purpose,
    'workflowSender': recordSender && route.assignment != 'keep'
        ? actorId
        : task.workflowSender,
    'completedDate':
        project.isCompleteStatus(project.workflowSheet!.stageFor(route.to)!)
        ? project.isCompleteStatus(task.status) && task.completedDate.isNotEmpty
              ? task.completedDate
              : completionDate ?? localDate()
        : '',
    'reworkReason': reason.trim().isNotEmpty
        ? reason.trim()
        : task.reworkReason,
  });
}

String workflowTargetLabel(WorkTask task, ProjectManifest project) {
  if (project.isCompleteStatus(task.status)) return '처리 종료';
  if (task.workflowTarget == 'legacy' || task.workflowPerson.isNotEmpty) {
    final id = task.workflowTarget == 'legacy'
        ? task.currentId
        : task.workflowPerson;
    return project.people
            .where((p) => p.id == id && p.active)
            .firstOrNull
            ?.name ??
        '처리 가능한 담당자 없음';
  }
  if (task.workflowTarget.isEmpty) return '모든 작업자';
  if (task.workflowTarget == 'role:owner') return '관리자';
  final part = project.roles
      .where((r) => 'part:${r.id}' == task.workflowTarget)
      .firstOrNull;
  return part == null ? '삭제된 파트 · 관리자 회수 필요' : '${part.name} 전체';
}

/// Shared by SQLite edits, upload admission and PR integration. Target metadata
/// is generated only by an exact route; task status alone never grants access.
void validatePartWorkflowMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  required ProjectManifest project,
  bool allowCollapsedTransitions = false,
}) {
  validateTaskProvenance(actor, next, current);
  validateResourceMutation(actor, next, current, project);
  if (validatePinMutation(
    actor: actor,
    next: next,
    current: current,
    project: project,
    allowCollapsedTransitions: allowCollapsedTransitions,
  )) {
    return;
  }
  if (validateLockOrCommentMutation(
    actor: actor,
    next: next,
    current: current,
    project: project,
    allowCollapsedTransitions: allowCollapsedTransitions,
  )) {
    return;
  }
  if (validateDeleteMutation(
    actor: actor,
    next: next,
    current: current,
    project: project,
  )) {
    return;
  }
  if (validateArchiveMutation(
    actor: actor,
    next: next,
    current: current,
    project: project,
  )) {
    return;
  }
  if (!actor.active ||
      !project.people.any((p) => p.id == actor.id && p.active)) {
    throw StateError('승인된 참여자만 작업을 변경할 수 있습니다.');
  }
  if (current != null && !hasTaskLockAccess(actor, current)) {
    throw StateError('잠금 담당자만 작업을 변경할 수 있습니다.');
  }
  final stages = project.workflowStages.map((s) => s.id).toList();
  if (!project.parts.contains(next.part) &&
      (current == null || next.part != current.part)) {
    throw StateError('등록된 파트를 선택하세요.');
  }
  if (!project.isCompleteStatus(next.status) && next.completedDate.isNotEmpty ||
      project.isCompleteStatus(next.status) && next.completedDate.isEmpty) {
    throw StateError('완료 상태와 완료일이 일치하지 않습니다.');
  }
  for (final (field, id) in [
    ('assigneeId', next.assigneeId),
    ('reviewerId', next.reviewerId),
  ]) {
    if ((current == null || current.data[field] != next.data[field]) &&
        !project.people.any((p) => p.id == id && p.active)) {
      throw StateError('활성 참여자를 담당자로 지정하세요.');
    }
  }
  if (current == null) {
    if (next.comments.isNotEmpty ||
        next.transitionHistory.isNotEmpty ||
        next.pausedFrom.isNotEmpty ||
        next.isLocked &&
            next.lockedBy != actor.id &&
            next.lockedBy != next.assigneeId) {
      throw StateError('새 작업은 작성자나 지정 작업자로 잠그세요. 기록은 등록 후 추가합니다.');
    }
    final initial = project.initialStatusId;
    if (initial == null ||
        next.version >
            (allowCollapsedTransitions ? maxTaskRevisionAdvance : 1)) {
      throw StateError('작업을 등록할 단계 또는 버전을 확인하세요.');
    }
    final base = next.copy({
      'status': initial,
      'completedDate': '',
      'reworkReason': '',
      'workflowTarget': '',
      'workflowPerson': next.creatorId.isNotEmpty
          ? next.assigneeId
          : workflowInitialPerson(project, initial, next.assigneeId),
      'workflowRoute': '',
      'workflowPurpose': '',
      'workflowSender': '',
      'version': 1,
    });
    if (next.version == 1) {
      if (next.status != initial ||
          next.reworkReason.isNotEmpty ||
          !const {'', 'legacy'}.contains(next.workflowTarget) ||
          (next.workflowTarget == 'legacy'
              ? next.workflowPerson.isNotEmpty
              : next.workflowPerson != base.workflowPerson) ||
          next.workflowRoute.isNotEmpty ||
          next.workflowPurpose.isNotEmpty ||
          next.workflowSender.isNotEmpty) {
        throw StateError('신규 작업은 첫 단계와 기본 처리 대상으로 등록하세요.');
      }
      return;
    }
    validatePartWorkflowMutation(
      actor: actor,
      next: next,
      current: base,
      project: project,
      allowCollapsedTransitions: allowCollapsedTransitions,
    );
    return;
  }
  if (current.id != next.id ||
      next.version <= current.version ||
      next.version - current.version >
          (allowCollapsedTransitions ? maxTaskRevisionAdvance : 1)) {
    throw StateError('작업 ID 또는 변경 버전이 올바르지 않습니다.');
  }
  final owner = actor.id == project.ownerId;
  final assignmentChanged = assignmentFields.any(
    (f) => current.data[f] != next.data[f],
  );
  final collapsedManagement =
      owner && allowCollapsedTransitions && next.version - current.version >= 2;
  final contentChanged = [
    'title',
    'description',
    'resources',
  ].any((f) => current.data[f] != next.data[f]);
  final legacyRegistrationChanged =
      current.assigneeId != next.assigneeId ||
      current.status == 'review' && current.reviewerId != next.reviewerId;
  final preservesLegacyRecipient =
      current.workflowTarget == 'legacy' &&
      legacyRegistrationChanged &&
      next.workflowTarget.isEmpty &&
      next.workflowPerson == current.currentId;
  final targetSame =
      (current.workflowTarget == next.workflowTarget &&
              current.workflowPerson == next.workflowPerson ||
          preservesLegacyRecipient) &&
      current.workflowRoute == next.workflowRoute &&
      current.workflowPurpose == next.workflowPurpose &&
      current.workflowSender == next.workflowSender;
  final directChange =
      directWorkflowRouteIds.contains(next.workflowRoute) &&
      (current.status != next.status ||
          !targetSame ||
          current.reworkReason != next.reworkReason ||
          current.lockedBy != next.lockedBy);
  if (directChange && next.version == current.version + 1) {
    final route = directWorkflowRoute(current, project, next.workflowRoute);
    if (route == null) throw StateError('현재 상태에서는 이 동작을 실행할 수 없습니다.');
    final expected = applyDirectWorkflowRoute(
      current,
      route,
      project,
      actorId: actor.id,
      receiverGroup: next.workflowTarget,
      receiverPerson: next.workflowPerson,
      purpose: route.assignment == 'select' ? next.workflowPurpose : '',
      reason: next.transitionHistory.isEmpty
          ? next.reworkReason
          : next.transitionHistory.last['comment'] as String,
      completionDate: next.completedDate,
      lockOnHandoff: next.isLocked,
      at: next.data['updatedAt'],
    );
    if (!fields.every((f) => expected.data[f] == next.data[f])) {
      throw StateError('담당자 전달과 내용 수정은 각각 저장하고 전달자를 확인하세요.');
    }
    return;
  }
  if (current.data['transitionHistory'] != next.data['transitionHistory'] ||
      current.pausedFrom != next.pausedFrom) {
    throw StateError('전달 기록과 보류 상태는 확인된 채널 이동으로만 변경할 수 있습니다.');
  }
  if (current.lockedBy != next.lockedBy ||
      current.data['comments'] != next.data['comments']) {
    throw StateError('잠금 변경과 댓글 등록은 각각 저장하세요.');
  }
  if (owner &&
      next.workflowRoute == 'admin-recovery' &&
      (current.status != next.status || !targetSame || assignmentChanged)) {
    if (!stages.contains(next.status) ||
        project.isLockedStatus(next.status) ||
        next.workflowPerson.isEmpty ||
        !project.people.any(
          (p) =>
              p.id == next.workflowPerson &&
              p.active &&
              workflowGroupContains(next.workflowTarget, p, project),
        ) ||
        contentChanged && !collapsedManagement ||
        next.reworkReason != current.reworkReason && !collapsedManagement) {
      throw StateError('관리자 회수는 활성 담당자와 일반 작업 단계로 지정하세요.');
    }
    if (next.workflowPurpose != current.workflowPurpose &&
        !collapsedManagement) {
      throw StateError('관리자 회수 시에는 요청 유형을 변경할 수 없습니다.');
    }
    if (next.workflowSender != current.workflowSender && !collapsedManagement) {
      throw StateError('관리자 회수는 직전 전달자를 변경할 수 없습니다.');
    }
    if (next.reworkReason == current.reworkReason &&
        next.workflowPurpose == current.workflowPurpose) {
      return;
    }
    // A queued rejection followed by recovery must prove the rejection path.
    // Recovery itself never permits changing the review comment.
  }
  final editable = canEditWorkflowTask(actor, current, project);
  if (assignmentChanged && !editable && !allowCollapsedTransitions) {
    throw StateError('현재 처리 대상과 작업 단계에서는 배정을 변경할 수 없습니다.');
  }
  if (current.workflowTarget == 'legacy' &&
      legacyRegistrationChanged &&
      !preservesLegacyRecipient &&
      (!allowCollapsedTransitions ||
          next.workflowRoute == current.workflowRoute &&
              next.status == current.status)) {
    throw StateError('등록 담당자 수정은 현재 수신자를 변경할 수 없습니다.');
  }
  if (current.status == next.status &&
      targetSame &&
      !contentChanged &&
      !assignmentChanged &&
      current.completedDate == next.completedDate &&
      current.reworkReason == next.reworkReason) {
    final selfRoute = availableWorkflowRoutes(actor, current, project)
        .where(
          (r) =>
              r.id == next.workflowRoute &&
              project.workflowSheet!.stageFor(r.to) == current.status,
        )
        .firstOrNull;
    if (selfRoute != null) {
      validateWorkflowRouteInputs(
        current,
        selfRoute,
        comment: next.reworkReason,
      );
      final expected = applyWorkflowRoute(
        current,
        selfRoute,
        project,
        reason: next.reworkReason,
        actorId: actor.id,
        receiverGroup: next.workflowTarget,
        receiverPerson: next.workflowPerson,
        preserveLegacyPurpose:
            current.workflowPurpose.isNotEmpty ||
            next.workflowPurpose.isNotEmpty,
        recordSender: next.workflowSender.isNotEmpty,
      );
      if (expected.workflowTarget == next.workflowTarget &&
          expected.workflowPerson == next.workflowPerson &&
          expected.workflowPurpose == next.workflowPurpose &&
          expected.workflowSender == next.workflowSender &&
          expected.completedDate == next.completedDate &&
          expected.reworkReason == next.reworkReason) {
        return;
      }
      throw StateError('요청 유형과 전달 대상을 확인하세요.');
    }
  }
  if (current.status == next.status &&
      targetSame &&
      current.reworkReason == next.reworkReason &&
      (editable || !collapsedManagement)) {
    if (!editable || current.completedDate != next.completedDate) {
      throw StateError('현재 처리 대상과 작업 단계에서는 수정할 수 없습니다.');
    }
    return;
  }
  if (!allowCollapsedTransitions && contentChanged) {
    throw StateError('내용 저장과 단계 전달은 별도로 처리하세요.');
  }
  final maxSteps = allowCollapsedTransitions
      ? (next.version - current.version).clamp(1, maxWorkflowStages + 2)
      : 1;
  final queue = Queue<(WorkTask, int, bool, bool, bool)>()
    ..add((current, 0, editable, false, editable));
  final canRecover =
      collapsedManagement &&
      project.people.any((p) => p.id == next.assigneeId && p.active);
  const mutableFields = [
    'title',
    'description',
    'resources',
    ...assignmentFields,
  ];
  final visited = <String>{};
  while (queue.isNotEmpty) {
    final (state, count, couldEdit, rejected, couldReassign) = queue
        .removeFirst();
    final signature =
        '${jsonEncode({for (final f in fields) f: state.data[f]})}|$couldEdit|$rejected|$couldReassign';
    if (!visited.add(signature)) continue;
    if (count > 0 &&
        state.status == next.status &&
        state.workflowTarget == next.workflowTarget &&
        state.workflowPerson == next.workflowPerson &&
        state.workflowRoute == next.workflowRoute &&
        state.workflowPurpose == next.workflowPurpose &&
        state.workflowSender == next.workflowSender &&
        state.completedDate == next.completedDate &&
        mutableFields.every((f) => state.data[f] == next.data[f]) &&
        (!contentChanged || couldEdit) &&
        (!assignmentChanged || couldEdit) &&
        (next.reworkReason == current.reworkReason || rejected) &&
        (!rejected || next.reworkReason.trim().isNotEmpty)) {
      return;
    }
    if (count >= maxSteps) continue;
    // Replay one real save at an editable point. Validators read the fields
    // present at each transition, rather than the proposal's eventual values.
    // This permits clearing an optional field after reaching an editable state
    // while preventing the same change after a transfer locks that content.
    if (allowCollapsedTransitions &&
        canEditWorkflowTask(actor, state, project) &&
        mutableFields.any((f) => state.data[f] != next.data[f])) {
      final edited = state.copy({
        for (final f in mutableFields) f: next.data[f],
        if (state.workflowTarget == 'legacy' &&
            (state.assigneeId != next.assigneeId ||
                state.status == 'review' &&
                    state.reviewerId != next.reviewerId)) ...{
          'workflowTarget': '',
          'workflowPerson': state.currentId,
        },
      });
      queue.add((
        edited,
        count + 1,
        true,
        rejected,
        couldReassign || state.workflowTarget != 'legacy',
      ));
    }
    if (canRecover) {
      // A recovery may follow a rejection as well as precede an edit/forward.
      // Preserve its state's comment and require a real rejection for changes.
      for (final stage in stages.where((s) => !project.isLockedStatus(s))) {
        final recovered = state.copy({
          'status': stage,
          'assigneeId': next.assigneeId,
          'completedDate': '',
          'workflowTarget': '',
          'workflowPerson': next.assigneeId,
          'workflowRoute': 'admin-recovery',
        });
        queue.add((recovered, count + 1, true, rejected, true));
      }
    }
    for (final id in directWorkflowRouteIds) {
      final route = directWorkflowRoute(state, project, id);
      if (route == null) continue;
      try {
        final moved = applyDirectWorkflowRoute(
          state,
          route,
          project,
          actorId: actor.id,
          receiverGroup: next.workflowTarget,
          receiverPerson: next.workflowPerson,
          purpose: route.assignment == 'select' ? next.workflowPurpose : '',
          reason: next.reworkReason,
          completionDate: next.completedDate.isEmpty
              ? localDate()
              : next.completedDate,
        );
        queue.add((
          moved,
          count + 1,
          couldEdit || canEditWorkflowTask(actor, moved, project),
          rejected ||
              next.reworkReason.trim().isNotEmpty &&
                  next.reworkReason != current.reworkReason,
          couldReassign,
        ));
      } on StateError {
        // This direct action cannot produce the submitted recipient or intent.
      }
    }
    for (final route in availableWorkflowRoutes(actor, state, project)) {
      if (route.assignment == 'select' &&
          !workflowSelectedReceiverAllowed(
            route,
            project,
            group: next.workflowTarget,
            person: next.workflowPerson,
          )) {
        continue;
      }
      try {
        validateWorkflowRouteInputs(state, route, comment: next.reworkReason);
      } catch (_) {
        continue;
      }
      final moved = applyWorkflowRoute(
        state,
        route,
        project,
        reason: next.reworkReason,
        completionDate: next.completedDate.isEmpty
            ? localDate()
            : next.completedDate,
        actorId: actor.id,
        receiverGroup: next.workflowTarget,
        receiverPerson: next.workflowPerson,
        // Earlier clients did not persist intent. Replaying those revisions may
        // retain an empty legacy value, but an explicit task or route purpose
        // can never be removed by this compatibility path.
        preserveLegacyPurpose:
            current.workflowPurpose.isNotEmpty ||
            next.workflowPurpose.isNotEmpty,
        recordSender: next.workflowSender.isNotEmpty,
      );
      queue.add((
        moved,
        count + 1,
        couldEdit || canEditWorkflowTask(actor, moved, project),
        rejected ||
            next.reworkReason.trim().isNotEmpty &&
                next.reworkReason != current.reworkReason,
        couldReassign ||
            moved.workflowTarget != 'legacy' &&
                canEditWorkflowTask(actor, moved, project),
      ));
    }
  }
  throw StateError('현재 담당자와 작업 상태에서는 이 변경을 저장할 수 없습니다.');
}

bool canArchiveTask(Person actor, WorkTask task, {ProjectManifest? project}) {
  if (!actor.active || task.isDeleted || !hasTaskLockAccess(actor, task)) {
    return false;
  }
  final visible = task.isArchived ? task.copy({'archivedAt': ''}) : task;
  if (project != null) {
    if (!project.people.any((p) => p.id == actor.id && p.active)) return false;
    return actor.id == project.ownerId ||
        isWorkflowRecipient(actor, task, project) ||
        canEditTaskContent(actor, visible, workflowProject: project);
  }
  return actor.manages ||
      actor.id == task.currentId ||
      canEditTaskContent(actor, visible);
}

/// Archiving is a separate lifecycle mutation; it never grants a content edit
/// or a transition while bypassing the configured workflow.
bool validateArchiveMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  ProjectManifest? project,
}) {
  if (current == null) {
    if (next.isArchived) throw StateError('새 작업은 보관 상태로 등록할 수 없습니다.');
    return false;
  }
  if (next.archivedAt != current.archivedAt) {
    if (next.id != current.id ||
        next.version != current.version + 1 ||
        next.isArchived == current.isArchived ||
        !canArchiveTask(actor, current, project: project) ||
        fields
            .where((f) => f != 'archivedAt')
            .any((f) => next.data[f] != current.data[f])) {
      throw StateError('작업 보관·복원 권한과 최신 버전을 확인하세요. 다른 변경은 함께 저장할 수 없습니다.');
    }
    return true;
  }
  if (current.isArchived) throw StateError('보관된 작업은 먼저 복원한 뒤 변경하세요.');
  return false;
}

bool canDeleteTask(Person actor, WorkTask task, {ProjectManifest? project}) =>
    !task.isDeleted &&
    hasTaskLockAccess(actor, task) &&
    actor.active &&
    (project == null
        ? actor.canMutate
        : project.people.any((p) => p.id == actor.id && p.active));

/// Deletion remains a separate revision so snapshots cannot resurrect removed work.
bool validateDeleteMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  ProjectManifest? project,
}) {
  if (current?.isDeleted == true) throw StateError('삭제된 작업은 변경하거나 복원할 수 없습니다.');
  if (!next.isDeleted) return false;
  if (current == null ||
      next.id != current.id ||
      next.version != current.version + 1 ||
      !canDeleteTask(actor, current, project: project) ||
      fields
          .where((f) => f != 'deletedAt')
          .any((f) => next.data[f] != current.data[f])) {
    throw StateError('작업 삭제 권한과 최신 버전을 확인하세요. 삭제는 별도 변경으로 저장해야 합니다.');
  }
  return true;
}

/// Lock changes and append-only comments are standalone, signed task revisions.
/// Comments are collaboration metadata, so a viewer may comment on locked work.
bool validateLockOrCommentMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  required ProjectManifest project,
  bool allowCollapsedTransitions = false,
}) {
  if (current == null) return false;
  final lockChanged = next.lockedBy != current.lockedBy;
  final commentChanged = next.data['comments'] != current.data['comments'];
  if (!lockChanged && !commentChanged) return false;
  // Lock transfer is validated as part of the exact, atomic handoff instead.
  if (lockChanged &&
      !commentChanged &&
      next.workflowRoute == 'manual-handoff' &&
      (next.isLocked && next.lockedBy == next.workflowPerson ||
          next.workflowPerson != current.workflowPerson ||
          next.workflowTarget != current.workflowTarget ||
          next.workflowSender != current.workflowSender ||
          next.workflowRoute != current.workflowRoute)) {
    return false;
  }
  if (!actor.active ||
      !project.people.any((p) => p.id == actor.id && p.active) ||
      current.isDeleted ||
      current.isArchived ||
      current.id != next.id ||
      next.version <= current.version ||
      next.version - current.version >
          (commentChanged && allowCollapsedTransitions
              ? maxTaskRevisionAdvance
              : 1) ||
      lockChanged && commentChanged ||
      fields
          .where((f) => f != (lockChanged ? 'lockedBy' : 'comments'))
          .any((f) => current.data[f] != next.data[f])) {
    throw StateError('잠금 변경과 댓글 등록은 최신 작업에서 각각 저장하세요.');
  }
  if (lockChanged) {
    if (!hasTaskLockAccess(actor, current) ||
        project.isCompleteStatus(current.status) && next.isLocked ||
        next.isLocked && next.lockedBy != actor.id) {
      throw StateError('본인만 잠글 수 있으며 현재 잠금 담당자만 해제할 수 있습니다.');
    }
  } else {
    final previous = {for (final c in current.comments) c['id']: c};
    final added = next.comments
        .where((c) => !previous.containsKey(c['id']))
        .toList();
    if (added.isEmpty ||
        added.length >
            (allowCollapsedTransitions ? next.version - current.version : 1) ||
        added.any(
          (c) =>
              c['authorId'] != actor.id ||
              c.containsKey('context') &&
                  c['context'] != (current.status == 'review' ? 'review' : ''),
        ) ||
        next.comments.length != previous.length + added.length ||
        next.comments.any(
          (c) =>
              previous.containsKey(c['id']) &&
              c.keys.any((k) => previous[c['id']]![k] != c[k]),
        )) {
      throw StateError('댓글은 본인 이름으로 등록해야 합니다. 기존 댓글은 변경할 수 없습니다.');
    }
  }
  return true;
}

/// Pinning changes presentation metadata, including on completed work. It does
/// not grant an edit, bypass a lock, or combine with unrelated mutations.
bool canPinTask(Person actor, WorkTask task, {ProjectManifest? project}) =>
    actor.active &&
    !task.isDeleted &&
    !task.isArchived &&
    hasTaskLockAccess(actor, task) &&
    (project == null
        ? actor.canMutate
        : project.people.any((p) => p.id == actor.id && p.active));

bool validatePinMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  ProjectManifest? project,
  bool allowCollapsedTransitions = false,
}) {
  if (current == null || current.isPinned == next.isPinned) return false;
  if (current.id != next.id ||
      next.version <= current.version ||
      next.version - current.version >
          (allowCollapsedTransitions ? maxTaskRevisionAdvance : 1) ||
      !canPinTask(actor, current, project: project) ||
      fields
          .where((f) => f != 'pinned')
          .any((f) => current.data[f] != next.data[f])) {
    throw StateError('최신 작업과 잠금 담당자를 확인하세요. 상단 고정은 별도 변경으로 저장합니다.');
  }
  return true;
}
