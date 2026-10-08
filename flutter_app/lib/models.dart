import 'dart:collection';
import 'dart:convert';

import 'workflow_sheet_model.dart';
export 'workflow_sheet_model.dart';

part 'workflow_engine.dart';

const fields = [
  'title',
  'part',
  'assigneeId',
  'reviewerId',
  'status',
  'priority',
  'assignedDate',
  'dueDate',
  'completedDate',
  'description',
  'reworkReason',
  'workflowTarget',
  'workflowPerson',
  'workflowRoute',
  'workflowPurpose',
  'workflowSender',
  'archivedAt',
  'deletedAt',
  'lockedBy',
  'comments',
  'pinned',
];
const fieldLabels = {
  'title': '작업내용',
  'part': '담당 파트',
  'assigneeId': '담당자',
  'reviewerId': '검토자',
  'status': '작업 상태',
  'priority': '우선순위',
  'assignedDate': '작업 지정일',
  'dueDate': '마감일',
  'completedDate': '완료일',
  'description': '설명',
  'reworkReason': '최근 전환 코멘트',
  'workflowTarget': '현재 처리 파트',
  'workflowPerson': '현재 처리 작업자',
  'workflowRoute': '전달 경로',
  'workflowPurpose': '처리 목적',
  'workflowSender': '직전 전달자',
  'archivedAt': '보관 시각',
  'deletedAt': '삭제 시각',
  'lockedBy': '잠금 담당자',
  'comments': '코멘트',
  'pinned': '상단 고정',
};
const statuses = {
  'todo': '할 일',
  'doing': '진행 중',
  'review': '검토',
  'rework': '재작업',
  'done': '완료',
};
const defaultWorkflowStages = [
  WorkflowStage('todo', '확인중'),
  WorkflowStage('doing', '진행중'),
  WorkflowStage('done', '완료'),
];
const workflowPurposeLabels = {'work': '작성', 'review': '검토', 'revision': '수정'};
const maxWorkflowStages = 34;

String? workflowInitialStatus(Iterable<String> stages) =>
    stages.where((id) => !const {'review', 'rework'}.contains(id)).firstOrNull;

String? partWorkflowInitialStatus(Iterable<String> stages) => stages
    .where((id) => !const {'review', 'rework', 'done'}.contains(id))
    .firstOrNull;

class WorkflowStage {
  const WorkflowStage(
    this.id,
    this.name, {
    this.category = '',
    this.editPolicy = '',
    this.initial = false,
  });
  final String id, name;
  final String category, editPolicy;
  final bool initial;
  String get resolvedCategory => category.isNotEmpty
      ? category
      : id == 'todo'
      ? 'todo'
      : id == 'done'
      ? 'done'
      : 'inProgress';
  String get resolvedEditPolicy => editPolicy.isNotEmpty
      ? editPolicy
      : const {'review', 'done'}.contains(id)
      ? 'locked'
      : 'recipients';
  bool get isCompleted => resolvedCategory == 'done';
  bool get locksContent => isCompleted || resolvedEditPolicy == 'locked';

  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    if (category.isNotEmpty) 'category': category,
    if (editPolicy.isNotEmpty) 'editPolicy': editPolicy,
    if (initial) 'initial': initial,
  };

  factory WorkflowStage.fromJson(Map<String, dynamic> raw) {
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String ||
        !(const {'todo', 'doing', 'review', 'done'}.contains(id) ||
            RegExp(r'^stage-[a-zA-Z0-9_-]{1,70}$').hasMatch(id)) ||
        name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 30 ||
        raw['category'] != null &&
            !const {
              '',
              'todo',
              'inProgress',
              'done',
            }.contains(raw['category']) ||
        raw['editPolicy'] != null &&
            !const {
              '',
              'recipients',
              'everyone',
              'locked',
            }.contains(raw['editPolicy']) ||
        raw['initial'] != null && raw['initial'] is! bool) {
      throw StateError('작업 단계 이름은 1~30자로 입력하세요.');
    }
    final stage = WorkflowStage(
      id,
      name.trim(),
      category: raw['category'] ?? '',
      editPolicy: raw['editPolicy'] ?? '',
      initial: raw['initial'] == true,
    );
    if (stage.initial && stage.locksContent) {
      throw StateError('시작 상태는 편집 가능한 미완료 상태여야 합니다.');
    }
    return stage;
  }
}

const workflowActorLabels = {
  'assignee': '작업자',
  'reviewer': '검토자',
  'authorized': '작업 권한이 있는 참여자',
};

class WorkflowConnection {
  const WorkflowConnection(
    this.from,
    this.to, {
    this.action = 'advance',
    this.actor = 'assignee',
    this.roles = const [],
    this.taskParts = const [],
    this.actorParts = const [],
    this.assignedOnly = false,
    this.allWorkers = false,
    this.returnAssigneeId = '',
  });
  final String from, to, action, actor;
  final List<String> roles;
  final List<String> taskParts, actorParts;
  final bool assignedOnly;
  final bool allWorkers;

  /// Empty keeps the submitted task's assignee when a review is rejected.
  final String returnAssigneeId;
  String get key => '$from/$action';
  Map<String, dynamic> get json => {
    'from': from,
    'to': to,
    'action': action,
    'actor': actor,
    'roles': roles,
    if (taskParts.isNotEmpty) 'taskParts': taskParts,
    if (actorParts.isNotEmpty) 'actorParts': actorParts,
    if (assignedOnly) 'assignedOnly': true,
    if (allWorkers) 'allWorkers': true,
    if (returnAssigneeId.isNotEmpty) 'returnAssigneeId': returnAssigneeId,
  };
  factory WorkflowConnection.fromJson(
    Map<String, dynamic> value, {
    bool allowLegacyApproval = false,
  }) {
    final taskParts = value['taskParts'] ?? const [];
    final actorParts = value['actorParts'] ?? const [];
    final returnAssigneeId = value['returnAssigneeId'] ?? '';
    bool validParts(dynamic values) =>
        values is List &&
        values.length <= rules.length &&
        values.every(
          (part) => part is String && rules.any((r) => r.part == part),
        ) &&
        values.toSet().length == values.length;
    if (value['from'] is! String ||
        value['to'] is! String ||
        !const {'advance', 'approve', 'reject'}.contains(value['action']) ||
        !workflowActorLabels.containsKey(value['actor']) ||
        value['roles'] is! List ||
        (value['roles'] as List).any((r) => r is! String) ||
        (value['roles'] as List).toSet().length !=
            (value['roles'] as List).length ||
        !validParts(taskParts) ||
        !validParts(actorParts) ||
        value['assignedOnly'] != null && value['assignedOnly'] is! bool ||
        value['allWorkers'] != null && value['allWorkers'] is! bool ||
        value['allWorkers'] == true && value['assignedOnly'] == true ||
        returnAssigneeId is! String ||
        returnAssigneeId.isNotEmpty &&
            !RegExp(r'^gh-[0-9]+$').hasMatch(returnAssigneeId)) {
      throw StateError('자동화 연결과 파트·담당자 조건을 확인하세요.');
    }
    final connection = WorkflowConnection(
      value['from'],
      value['to'],
      action: value['action'],
      actor: value['actor'],
      roles: List.unmodifiable((value['roles'] as List).cast<String>()),
      taskParts: List.unmodifiable((taskParts as List).cast<String>()),
      actorParts: List.unmodifiable((actorParts as List).cast<String>()),
      assignedOnly: value['assignedOnly'] == true,
      allWorkers: value['allWorkers'] == true,
      returnAssigneeId: returnAssigneeId,
    );
    if (connection.from == connection.to ||
        connection.from == 'done' ||
        (connection.from == 'review') != (connection.action != 'advance') ||
        connection.from == 'review' && connection.actor != 'reviewer' ||
        connection.action == 'reject' &&
            const {'review', 'done'}.contains(connection.to) ||
        connection.action == 'approve' &&
            (connection.to == 'rework' ||
                !allowLegacyApproval && connection.to != 'done') ||
        connection.returnAssigneeId.isNotEmpty &&
            connection.action != 'reject') {
      throw StateError('검토 승인·반려 연결과 반려 담당자를 확인하세요.');
    }
    return connection;
  }
}

class WorkflowAutomation {
  const WorkflowAutomation({
    this.reviewEnabled = false,
    this.reworkEnabled = false,
    this.connections = const [],
    this.disabledConnections = const [],
  });
  final bool reviewEnabled, reworkEnabled;
  final List<WorkflowConnection> connections;
  final List<String> disabledConnections;
  Map<String, dynamic> get json => {
    'reviewEnabled': reviewEnabled,
    'reworkEnabled': reworkEnabled,
    'connections': connections.map((c) => c.json).toList(),
    if (disabledConnections.isNotEmpty)
      'disabledConnections': disabledConnections,
  };
  factory WorkflowAutomation.fromJson(Map<String, dynamic> value) {
    final disabled = value['disabledConnections'] ?? const [];
    if (value['reviewEnabled'] is! bool ||
        value['reworkEnabled'] is! bool ||
        value['connections'] is! List ||
        (value['connections'] as List).length > 36 ||
        value['reworkEnabled'] == true && value['reviewEnabled'] != true ||
        disabled is! List ||
        disabled.length > 36 ||
        disabled.any(
          (key) =>
              key is! String ||
              !RegExp(r'^[^/]+/(advance|approve|reject)$').hasMatch(key),
        ) ||
        disabled.toSet().length != disabled.length) {
      throw StateError('검토·재작업 시트 설정을 확인하세요.');
    }
    final connections = (value['connections'] as List)
        .map(
          (c) => WorkflowConnection.fromJson(
            Map<String, dynamic>.from(c),
            allowLegacyApproval: true,
          ),
        )
        .toList();
    if (connections.map((c) => c.key).toSet().length != connections.length) {
      throw StateError('한 단계의 연결 조건은 중복될 수 없습니다.');
    }
    return WorkflowAutomation(
      reviewEnabled: value['reviewEnabled'],
      reworkEnabled: value['reworkEnabled'],
      connections: List.unmodifiable(connections),
      disabledConnections: List.unmodifiable(disabled.cast<String>()),
    );
  }

  WorkflowAutomation withoutStages(Set<String> removed) => WorkflowAutomation(
    reviewEnabled: reviewEnabled && !removed.contains('review'),
    reworkEnabled: false,
    connections: connections
        .where((c) => !removed.contains(c.from) && !removed.contains(c.to))
        .toList(),
    disabledConnections: disabledConnections
        .where((key) => !removed.contains(key.split('/').first))
        .toList(),
  );

  /// Migrates the former separate rework sheet into a normal return handoff.
  /// Existing tasks in that status remain readable and have a recovery path.
  WorkflowAutomation normalized(List<WorkflowStage> stages) {
    final working = stages.where(
      (s) => !const {'review', 'done'}.contains(s.id),
    );
    final returnStage = working.any((s) => s.id == 'doing')
        ? 'doing'
        : working.firstOrNull?.id;
    return WorkflowAutomation(
      reviewEnabled: stages.any((s) => s.id == 'review') || reviewEnabled,
      connections: [
        for (final c in connections)
          if (c.from != 'rework' &&
              (c.to != 'rework' || returnStage != null) &&
              (c.action != 'approve' || stages.any((s) => s.id == 'done')))
            if (c.to == 'rework' || c.action == 'approve' && c.to != 'done')
              WorkflowConnection(
                c.from,
                c.action == 'approve' ? 'done' : returnStage!,
                action: c.action,
                actor: c.actor,
                roles: c.roles,
                taskParts: c.taskParts,
                actorParts: c.actorParts,
                assignedOnly: c.assignedOnly,
                allWorkers: c.allWorkers,
                returnAssigneeId: c.returnAssigneeId,
              )
            else
              c,
      ],
      disabledConnections: disabledConnections
          .where((key) => !key.startsWith('rework/'))
          .toList(),
    );
  }

  List<WorkflowConnection> resolve(List<WorkflowStage> stages) {
    final config = normalized(stages);
    final ids = stages.map((s) => s.id).toList();
    if (config.reviewEnabled && !ids.contains('review')) {
      final doneIndex = ids.indexOf('done');
      ids.insert(doneIndex < 0 ? ids.length : doneIndex, 'review');
    }
    final active = {...ids};
    final defaults = <WorkflowConnection>[
      for (var i = 0; i + 1 < ids.length; i++)
        if (!const {'done', 'review'}.contains(ids[i]))
          WorkflowConnection(
            ids[i],
            config.reviewEnabled && ids[i + 1] == 'done'
                ? 'review'
                : ids[i + 1],
            actor: ids[i + 1] == 'done' && !config.reviewEnabled
                ? 'reviewer'
                : 'assignee',
            allWorkers: true,
          ),
      if (ids.contains('review') && ids.contains('done'))
        const WorkflowConnection(
          'review',
          'done',
          action: 'approve',
          actor: 'reviewer',
          allWorkers: true,
        ),
    ];
    final working = ids
        .where((id) => !const {'review', 'done'}.contains(id))
        .toList();
    if (ids.contains('review') && working.isNotEmpty) {
      defaults.add(
        WorkflowConnection(
          'review',
          ids.contains('todo') ? 'todo' : working.first,
          action: 'reject',
          actor: 'reviewer',
          allWorkers: true,
        ),
      );
    }
    for (final override in config.connections) {
      if (!active.contains(override.from) || !active.contains(override.to)) {
        continue;
      }
      defaults.removeWhere((c) => c.key == override.key);
      defaults.add(
        config.reviewEnabled &&
                override.to == 'done' &&
                override.from != 'review'
            ? WorkflowConnection(
                override.from,
                'review',
                actor: override.actor,
                roles: override.roles,
                taskParts: override.taskParts,
                actorParts: override.actorParts,
                assignedOnly: override.assignedOnly,
                allWorkers: override.allWorkers,
                returnAssigneeId: override.returnAssigneeId,
              )
            : override,
      );
    }
    return defaults
        .where((c) => !config.disabledConnections.contains(c.key))
        .toList();
  }
}

const priorities = {'high': '높음', 'normal': '보통', 'low': '낮음'};

// Keep revisions well below SQLite/Dart integer limits. A sync proposal may
// contain several locally completed steps, but cannot jump to an arbitrary
// revision and permanently eclipse everyone else's changes.
const maxTaskVersion = 1000000000;
const maxTaskRevisionAdvance = 10000;
const assignmentFields = [
  'part',
  'assigneeId',
  'reviewerId',
  'assignedDate',
  'dueDate',
  'priority',
];

int nextTaskVersion(int current) {
  if (current < 0 || current >= maxTaskVersion) {
    throw StateError('작업 버전 한도에 도달했습니다. 별도 작업으로 이어서 등록하세요.');
  }
  return current + 1;
}

/// Stable permission IDs are shared by local editing and GitHub validation.
const permissionLabels = {
  'task.create': '작업 등록',
  'task.assign': '담당자·일정·우선순위 배정',
  'task.work': '본인 담당 작업 수정·진행·제출',
  'task.editAll': '전체 작업 수정·진행·제출',
  'task.review': '검토 승인·반려',
  'task.reviewAll': '전체 작업 검토',
  'task.integrate': '다른 참여자의 작업 PR 통합',
  'member.manage': '가입 승인·참여자 역할 배정',
  'member.status': '관리자: 참여자 활성화·비활성화',
  'role.manage': '역할 생성·수정·삭제',
};
const managementPermissionLabels = {
  'member.manage': '참여자 관리',
  'role.manage': '역할 관리',
};
const defaultTaskPermissions = {
  'task.create',
  'task.assign',
  'task.work',
  'task.editAll',
  'task.review',
  'task.reviewAll',
  'task.integrate',
};
const workerPermissions = {'task.work', 'task.review'};
const managerPermissions = {
  'task.create',
  'task.assign',
  'task.work',
  'task.editAll',
  'task.review',
  'task.reviewAll',
  'task.integrate',
  'member.manage',
  'member.status',
};

class ProjectRole {
  const ProjectRole(this.id, this.name, this.permissions);
  final String id, name;
  final Set<String> permissions;
  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    'permissions': permissions.toList()..sort(),
  };
  factory ProjectRole.fromJson(Map<String, dynamic> value) {
    final id = value['id'], name = value['name'], raw = value['permissions'];
    if (id is! String ||
        !RegExp(r'^role-[a-zA-Z0-9-]{1,60}$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 40 ||
        raw is! List ||
        raw.any((p) => !permissionLabels.containsKey(p)) ||
        raw.toSet().length != raw.length) {
      throw StateError('역할 이름과 권한을 확인하세요.');
    }
    return ProjectRole(id, name.trim(), Set.unmodifiable(raw.cast<String>()));
  }
}

class Person {
  final String id, name, initials, role;
  final int color;
  final String login;
  final List<String> parts;
  const Person(
    this.id,
    this.name,
    this.initials,
    this.role,
    this.color, {
    this.login = '',
    this.parts = const [],
    this.customRole,
    this.enabled = true,
    this.partPermissions,
    this.workflowParticipant = false,
  });
  final bool enabled;
  final ProjectRole? customRole;
  final List<ProjectRole>? partPermissions;
  final bool workflowParticipant;
  Set<String> get permissions => role != 'owner' && workflowParticipant
      ? {
          ...defaultTaskPermissions,
          for (final part in partPermissions ?? const <ProjectRole>[])
            ...part.permissions.where(managementPermissionLabels.containsKey),
          if ((partPermissions ?? const <ProjectRole>[]).any(
            (part) => part.permissions.contains('member.manage'),
          ))
            'member.status',
        }
      : role != 'owner' && partPermissions != null
      ? {for (final part in partPermissions!) ...part.permissions}
      : switch (role) {
          'owner' => permissionLabels.keys.toSet(),
          'manager' => managerPermissions,
          'worker' => workerPermissions,
          _ => customRole?.permissions ?? const <String>{},
        };
  bool has(String permission) => active && permissions.contains(permission);
  String get roleLabel => role == 'owner'
      ? roleLabels['owner']!
      : partPermissions != null
      ? partPermissions!.isEmpty
            ? '권한 미지정'
            : partPermissions!.map((p) => p.name).join(', ')
      : roleLabels[role] ?? customRole?.name ?? '알 수 없는 역할';
  bool get manages => workflowParticipant
      ? has('member.manage') || has('role.manage')
      : has('task.editAll');
  bool get active =>
      enabled &&
      (['owner', 'unassigned', 'manager', 'worker', 'viewer'].contains(role) ||
          customRole != null);
  bool get canWork => has('task.work') || has('task.editAll');
  bool get canReview => has('task.review') || has('task.reviewAll');
  bool get canMutate => active && permissions.any((p) => p.startsWith('task.'));
  Person resolved(
    List<ProjectRole> roles, {
    bool unifiedParts = false,
    bool workflowParticipant = false,
  }) => Person(
    id,
    name,
    initials,
    role,
    color,
    login: login,
    parts: parts,
    enabled: enabled,
    workflowParticipant: workflowParticipant,
    customRole: roles.where((r) => r.id == role).firstOrNull,
    partPermissions: unifiedParts || workflowParticipant
        ? roles.where((r) => parts.contains(r.name)).toList()
        : null,
  );

  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    // Older clients already reject disabled roles; retain the real role separately.
    'role': enabled ? role : 'disabled',
    if (!enabled && role != 'disabled') 'assignedRole': role,
    'enabled': enabled,
    'login': login,
    'parts': parts,
  };
  factory Person.fromJson(Map<String, dynamic> data) {
    final id = data['id'],
        name = data['name'],
        role = data['role'] == 'disabled' && data['assignedRole'] is String
            ? data['assignedRole']
            : data['role'],
        login = data['login'];
    if (id is! String ||
        !RegExp(r'^gh-[0-9]+$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 40 ||
        login is! String ||
        !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(login) ||
        (role is! String ||
            !roleLabels.containsKey(role) &&
                !RegExp(r'^role-[a-zA-Z0-9-]{1,60}$').hasMatch(role)) ||
        data['parts'] is! List ||
        data.containsKey('enabled') && data['enabled'] is! bool) {
      throw StateError('참여자 정보가 올바르지 않습니다.');
    }
    final parts = List<String>.from(data['parts']);
    if (!validProjectParts(parts)) {
      throw StateError('담당 파트가 올바르지 않습니다.');
    }
    return Person(
      id,
      name.trim(),
      name.trim().substring(0, 1),
      role,
      0xff7963d5,
      login: login,
      parts: List.unmodifiable(parts),
      enabled: data['enabled'] as bool? ?? data['role'] != 'disabled',
    );
  }
}

bool canManageMemberStatus(Person actor, Person target, String ownerId) =>
    actor.has('member.status') &&
    target.id != ownerId &&
    target.role != 'pending' &&
    (!target.permissions.contains('role.manage') || actor.has('role.manage'));

const roleLabels = {
  'owner': '관리자',
  'unassigned': '권한 미지정',
  'manager': '운영자',
  'worker': '작업자',
  'viewer': '열람자',
  'pending': '가입 승인 대기',
  'disabled': '참여 중지',
};

class ProjectManifest {
  final String id, name, ownerId, founderId;
  final List<Person> _people;
  final List<ProjectRole> roles;
  final List<String> parts;
  final bool unifiedParts;
  final WorkflowSheet? workflowSheet;
  final List<WorkflowStage> workflowStages;
  final WorkflowAutomation workflowAutomation;
  WorkflowStage? stage(String id) =>
      workflowStages.where((s) => s.id == id).firstOrNull;
  String? get initialStatusId =>
      workflowStages.where((s) => s.initial).firstOrNull?.id ??
      workflowStages.where((s) => !s.locksContent).firstOrNull?.id;
  bool isCompleteStatus(String id) => stage(id)?.isCompleted ?? id == 'done';
  bool isLockedStatus(String id) => stage(id)?.locksContent ?? true;
  // Stored sheet data is retained only for compatibility. Project tasks no
  // longer execute its connections, assignment rules or rejection rules.
  bool get usesManualWorkflow => workflowSheet == null;
  List<WorkflowConnection> get activeWorkflowConnections => const [];
  List<WorkflowConnection> get workflowConnections =>
      workflowAutomation.resolve(workflowStages);

  /// Operational migration: job parts and recipients organize delivery; active
  /// participants collaborate on unfinished tasks. Historical fine grants are
  /// inactive.
  /// Reading never writes the repository; the next authorized save persists it.
  ProjectManifest get partWorkflowView {
    if (workflowSheet != null) {
      return ProjectManifest(
        id,
        name,
        ownerId,
        people,
        roles: roles,
        parts: parts,
        unifiedParts: unifiedParts,
        founderId: founderId,
        workflowStages: defaultWorkflowStages,
        workflowSheet: WorkflowSheet(
          nodes: WorkflowSheet.defaultFor(const ['todo', 'doing', 'done'])
              .nodes,
          routes: const [],
        ),
      );
    }
    final definitions = <ProjectRole>[
      for (final role in roles) ProjectRole(role.id, role.name, const {}),
    ];
    final partNames = <String, String>{};
    for (final name in parts) {
      var definition = definitions
          .where((r) => r.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (definition == null) {
        var hash = 2166136261;
        for (final unit in name.codeUnits) {
          hash = ((hash ^ unit) * 16777619) & 0xffffffff;
        }
        var id = 'role-part-${hash.toRadixString(16)}';
        while (definitions.any((r) => r.id == id)) {
          id = '$id-x';
        }
        definition = ProjectRole(id, name, const {});
        definitions.add(definition);
      }
      partNames[name] = definition.name;
    }
    return ProjectManifest(
      id,
      name,
      ownerId,
      [
        for (final p in people)
          Person(
            p.id,
            p.name,
            p.initials,
            const {'owner', 'pending', 'disabled'}.contains(p.role)
                ? p.role
                : 'unassigned',
            p.color,
            login: p.login,
            enabled: p.enabled,
            parts: {
              for (final part in p.parts)
                if (partNames[part] != null) partNames[part]!,
              if (p.customRole != null) p.customRole!.name,
            }.toList(),
          ),
      ],
      roles: definitions,
      parts: definitions.map((r) => r.name).toList(),
      unifiedParts: true,
      founderId: founderId,
      workflowStages: defaultWorkflowStages,
      workflowSheet: WorkflowSheet(
        nodes: WorkflowSheet.defaultFor(const ['todo', 'doing', 'done']).nodes,
        routes: const [],
      ),
    );
  }

  /// A deterministic view of older separate catalogues, without writing data.
  ProjectManifest get unifiedView {
    if (unifiedParts) return this;
    final combined = [...roles];
    String add(String name, Set<String> permissions) {
      final existing = combined
          .where((r) => r.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      if (existing != null) return existing.name;
      var hash = 2166136261;
      for (final unit in name.codeUnits) {
        hash = ((hash ^ unit) * 16777619) & 0xffffffff;
      }
      var id = 'role-part-${hash.toRadixString(16)}';
      while (combined.any((r) => r.id == id)) {
        id = '$id-x';
      }
      combined.add(ProjectRole(id, name, permissions));
      return name;
    }

    final partNames = {for (final part in parts) part: add(part, const {})};
    final roleParts = {for (final role in roles) role.id: role.name};
    for (final p in people) {
      if (const {'manager', 'worker', 'viewer'}.contains(p.role) &&
          !roleParts.containsKey(p.role)) {
        var name = p.roleLabel;
        final existing = combined
            .where((r) => r.name.toLowerCase() == name.toLowerCase())
            .firstOrNull;
        if (existing != null &&
            !existing.permissions.containsAll(p.permissions)) {
          // Keep legacy system rights separate when the same part name already
          // has different permissions. Consolidation must not erase those rights
          // or grant them to everybody who was assigned that existing part.
          name = '${p.roleLabel} (기존 권한)';
          var suffix = 2;
          while (combined.any(
            (r) => r.name.toLowerCase() == name.toLowerCase(),
          )) {
            name = '${p.roleLabel} (기존 권한 ${suffix++})';
          }
        }
        roleParts[p.role] = add(name, p.permissions);
      }
    }
    final names = combined.map((r) => r.name).toList();
    return ProjectManifest(
      id,
      name,
      ownerId,
      [
        for (final p in people)
          Person(
            p.id,
            p.name,
            p.initials,
            const {'owner', 'pending', 'disabled'}.contains(p.role)
                ? p.role
                : 'unassigned',
            p.color,
            login: p.login,
            enabled: p.enabled,
            parts: {
              for (final part in p.parts)
                if (partNames[part] != null) partNames[part]!,
              if (p.role != 'owner' && roleParts[p.role] != null)
                roleParts[p.role]!,
            }.toList(),
          ),
      ],
      roles: combined,
      parts: names,
      unifiedParts: true,
      founderId: founderId,
      workflowStages: workflowStages,
      workflowAutomation: workflowAutomation,
    );
  }

  List<Person> get people => _people
      .map(
        (p) =>
            Person(
              p.id,
              p.name,
              p.initials,
              p.role,
              p.color,
              login: p.login,
              parts: p.parts.where(parts.contains).toList(),
              enabled: p.enabled,
            ).resolved(
              roles,
              unifiedParts: unifiedParts,
              workflowParticipant: workflowSheet != null,
            ),
      )
      .toList();
  const ProjectManifest(
    this.id,
    this.name,
    this.ownerId,
    this._people, {
    this.roles = const [],
    this.parts = const [],
    this.unifiedParts = false,
    this.workflowSheet,
    this.workflowStages = defaultWorkflowStages,
    this.workflowAutomation = const WorkflowAutomation(),
    String? founderId,
  }) : founderId = founderId ?? ownerId;
  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'projectId': id,
    'name': name,
    'ownerId': ownerId,
    'founderId': founderId,
    'members': people.map((p) => p.json).toList(),
    'parts': parts,
    if (unifiedParts) 'partsUnified': true,
    if (workflowSheet != null) 'workflowSheet': workflowSheet!.json,
    if (roles.isNotEmpty) 'roles': roles.map((r) => r.json).toList(),
    'workflowStages': workflowStages.map((s) => s.json).toList(),
    'workflowStagesConfigured': true,
    'workflowDefaultsVersion': 2,
    'workflowAutomationDetached': true,
    'workflowAutomation': workflowAutomation.json,
  };
  factory ProjectManifest.fromJson(Map<String, dynamic> raw) {
    if (raw['schemaVersion'] != 1 ||
        raw['projectId'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(raw['projectId']) ||
        raw['name'] is! String ||
        (raw['name'] as String).trim().isEmpty ||
        (raw['name'] as String).length > 80 ||
        raw['members'] is! List ||
        (raw['members'] as List).length > 200) {
      throw StateError('프로젝트 설정 형식이 올바르지 않습니다.');
    }
    final roleValues = raw['roles'] ?? [];
    final partValues = raw['parts'] ?? const <String>[];
    if (partValues is! List || !validProjectParts(partValues)) {
      throw StateError('파트 이름은 중복 없이 1~40자로 입력하세요. 최대 50개까지 등록할 수 있습니다.');
    }
    if (roleValues is! List || roleValues.length > 50) {
      throw StateError('프로젝트 역할 목록을 확인하세요.');
    }
    final stageValues = raw['workflowStages'] ?? [];
    final workflowDefaultsVersion = raw['workflowDefaultsVersion'] ?? 0;
    if (workflowDefaultsVersion is! int || workflowDefaultsVersion < 0) {
      throw StateError('작업 단계 기본값 버전을 확인하세요.');
    }
    if (stageValues is! List || stageValues.length > maxWorkflowStages) {
      throw StateError('작업 단계 목록을 확인하세요.');
    }
    final parsedStages = stageValues
        .map(
          (value) => WorkflowStage.fromJson(Map<String, dynamic>.from(value)),
        )
        .toList();
    final workflowStages = raw['workflowStagesConfigured'] == true
        ? parsedStages
        : parsedStages.isEmpty
        ? List.of(defaultWorkflowStages)
        : [
            for (final id in ['todo', 'doing'])
              parsedStages.firstWhere(
                (stage) => stage.id == id,
                orElse: () =>
                    defaultWorkflowStages.firstWhere((stage) => stage.id == id),
              ),
            ...parsedStages.where(
              (stage) => !const {'todo', 'doing', 'done'}.contains(stage.id),
            ),
            parsedStages.firstWhere(
              (stage) => stage.id == 'done',
              orElse: () => defaultWorkflowStages.last,
            ),
          ];
    final parsedAutomation = raw['workflowAutomation'] == null
        ? const WorkflowAutomation()
        : WorkflowAutomation.fromJson(
            Map<String, dynamic>.from(raw['workflowAutomation']),
          );
    const oldDefaults = [
      WorkflowStage('todo', '확인'),
      WorkflowStage('doing', '진행'),
      WorkflowStage('done', '완료'),
    ];
    final untouchedOldDefaults =
        parsedStages.length == oldDefaults.length &&
        List.generate(oldDefaults.length, (i) => i).every(
          (i) =>
              parsedStages[i].id == oldDefaults[i].id &&
              parsedStages[i].name == oldDefaults[i].name &&
              parsedStages[i].category.isEmpty &&
              parsedStages[i].editPolicy.isEmpty &&
              !parsedStages[i].initial,
        );
    if (workflowDefaultsVersion < 2 &&
        untouchedOldDefaults &&
        !parsedAutomation.reviewEnabled &&
        !parsedAutomation.reworkEnabled &&
        parsedAutomation.connections.isEmpty &&
        parsedAutomation.disabledConnections.isEmpty) {
      workflowStages
        ..clear()
        ..addAll(defaultWorkflowStages);
    }
    final stageIds = workflowStages.map((stage) => stage.id).toSet();
    final stageNames = workflowStages
        .map((stage) => stage.name.toLowerCase())
        .toSet();
    if (stageIds.length != workflowStages.length ||
        stageNames.length != workflowStages.length ||
        workflowStages.length > maxWorkflowStages ||
        workflowStages.where((s) => s.initial).length > 1) {
      throw StateError('작업 단계 ID와 이름은 중복될 수 없습니다.');
    }
    final roles = roleValues
        .map((r) => ProjectRole.fromJson(Map<String, dynamic>.from(r)))
        .toList();
    final automation = parsedAutomation.normalized(workflowStages);
    if (roles.map((r) => r.id).toSet().length != roles.length ||
        roles.map((r) => r.name.toLowerCase()).toSet().length != roles.length) {
      throw StateError('역할 이름과 ID는 중복될 수 없습니다.');
    }
    final people = (raw['members'] as List)
        .map((p) => Person.fromJson(Map<String, dynamic>.from(p)))
        .toList();
    if (raw['partsUnified'] == true &&
        (roles.length != partValues.length ||
            !roles.every((r) => partValues.contains(r.name)) ||
            people.any(
              (p) =>
                  !const {
                    'owner',
                    'unassigned',
                    'pending',
                    'disabled',
                  }.contains(p.role) ||
                  p.parts.any((part) => !partValues.contains(part)),
            ))) {
      throw StateError('파트와 권한, 참여자 배정이 일치하지 않습니다.');
    }
    if (people.any(
          (p) =>
              !roleLabels.containsKey(p.role) &&
              !roles.any((r) => r.id == p.role),
        ) ||
        people.map((p) => p.id).toSet().length != people.length ||
        !RegExp(r'^gh-[0-9]+$')
            .hasMatch('${raw['founderId'] ?? raw['ownerId']}') ||
        people.where((p) => p.role == 'owner').length != 1 ||
        !people.any(
          (p) => p.id == raw['ownerId'] && p.role == 'owner' && p.enabled,
        )) {
      throw StateError('프로젝트 관리자와 참여자 정보를 확인하세요.');
    }
    return ProjectManifest(
      raw['projectId'],
      (raw['name'] as String).trim(),
      raw['ownerId'],
      List.unmodifiable(people),
      founderId: raw['founderId'] ?? raw['ownerId'],
      roles: List.unmodifiable(roles),
      parts: List.unmodifiable(partValues.cast<String>()),
      unifiedParts: raw['partsUnified'] == true,
      workflowSheet: raw['workflowSheet'] == null
          ? null
          : WorkflowSheet.fromJson(
              Map<String, dynamic>.from(raw['workflowSheet']),
            ),
      workflowStages: List.unmodifiable(workflowStages),
      workflowAutomation: automation,
    );
  }
}

const members = [
  Person('planner', '기획 담당자', '기', 'worker', 0xff8263eb),
  Person('dev', '개발 담당자', '개', 'worker', 0xff4486c6),
  Person('artist', '아트 담당자', '아', 'worker', 0xffc56b86),
  Person('pm', '운영자', 'P', 'manager', 0xff557d6d),
];
Person person(String id) => members.firstWhere(
  (p) => p.id == id,
  orElse: () => throw StateError('등록된 테스트 사용자를 선택하세요.'),
);

class PartRule {
  final String part, assigneeId, reviewerId, nextPart;
  const PartRule(this.part, this.assigneeId, this.reviewerId, this.nextPart);
}

bool validProjectParts(List<dynamic> parts) =>
    parts.length <= 50 &&
    parts.every(
      (p) =>
          p is String && p.trim().isNotEmpty && p == p.trim() && p.length <= 40,
    ) &&
    parts.whereType<String>().map((p) => p.toLowerCase()).toSet().length ==
        parts.length;

const rules = [
  PartRule('기획', 'planner', 'pm', '프로그래밍'),
  PartRule('프로그래밍', 'dev', 'pm', 'QA'),
  PartRule('아트', 'artist', 'pm', '프로그래밍'),
  PartRule('사운드', 'planner', 'pm', 'QA'),
  PartRule('QA', 'dev', 'pm', ''),
];
String localDate([DateTime? at]) {
  final d = (at ?? DateTime.now()).toUtc().add(const Duration(hours: 9));
  return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

String validDate(dynamic value, String label, {bool required = false}) {
  if (!required && (value == null || value == '')) return '';
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw StateError('$label을 올바르게 입력하세요.');
  }
  final d = DateTime.tryParse('${value}T00:00:00Z');
  if (d == null || d.toIso8601String().substring(0, 10) != value) {
    throw StateError('$label을 올바르게 입력하세요.');
  }
  return value;
}

class WorkTask {
  final Map<String, dynamic> data;
  WorkTask._(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  factory WorkTask.fromJson(Map<String, dynamic> raw) {
    const allowed = {'id', ...fields, 'version', 'updatedAt'};
    if (raw.keys.any((key) => !allowed.contains(key))) {
      throw StateError(
        '현재 앱에서 읽을 수 없는 작업 항목이 있습니다. 데이터는 보존됩니다. 최신 실행 파일로 프로젝트를 다시 열어주세요.',
      );
    }
    final t = <String, dynamic>{
      'workflowTarget': 'legacy',
      'workflowPerson': '',
      'workflowRoute': '',
      'workflowPurpose': '',
      'workflowSender': '',
      'archivedAt': '',
      'deletedAt': '',
      'lockedBy': '',
      'comments': '[]',
      'pinned': '',
      ...raw,
    };
    for (final f in ['id', ...fields]) {
      if (t[f] is! String) throw StateError('작업 항목 $f 형식이 올바르지 않습니다.');
    }
    t['title'] = (t['title'] as String).trim();
    t['description'] = (t['description'] as String).trim();
    t['reworkReason'] = (t['reworkReason'] as String).trim();
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(t['id'])) {
      throw StateError('작업 ID가 올바르지 않습니다.');
    }
    if (t['title'].isEmpty || t['title'].length > 200) {
      throw StateError('작업내용은 1~200자로 입력하세요.');
    }
    if ((t['part'] as String).length > 40 ||
        (t['part'] as String).trim().isEmpty ||
        !(statuses.containsKey(t['status']) ||
            RegExp(r'^stage-[a-zA-Z0-9_-]{1,70}$').hasMatch(t['status'])) ||
        !priorities.containsKey(t['priority'])) {
      throw StateError('담당 파트, 상태, 우선순위를 확인하세요.');
    }
    for (final key in ['assigneeId', 'reviewerId']) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(t[key])) {
        throw StateError('담당자 ID가 올바르지 않습니다.');
      }
    }
    if (!(const {'', 'legacy', 'role:owner'}.contains(t['workflowTarget']) ||
            RegExp(r'^part:role-[a-zA-Z0-9_-]{1,80}$')
                .hasMatch(t['workflowTarget'])) ||
        t['workflowPerson'] != '' &&
            !RegExp(r'^gh-[0-9]+$').hasMatch(t['workflowPerson']) ||
        t['workflowSender'] != '' &&
            !RegExp(r'^gh-[0-9]+$').hasMatch(t['workflowSender']) ||
        t['workflowRoute'].length > 100 ||
        !const {
          '',
          'work',
          'review',
          'revision',
        }.contains(t['workflowPurpose'])) {
      throw StateError('현재 처리 대상과 전달 경로를 확인하세요.');
    }
    if (t['lockedBy'] != '' &&
        !RegExp(r'^gh-[0-9]+$').hasMatch(t['lockedBy'])) {
      throw StateError('잠금 담당자 ID를 확인하세요.');
    }
    if (!const {'', 'true'}.contains(t['pinned'])) {
      throw StateError('상단 고정 상태를 확인하세요.');
    }
    parseTaskComments(t['comments']);
    t['assignedDate'] = validDate(t['assignedDate'], '작업 지정일', required: true);
    t['dueDate'] = validDate(t['dueDate'], '마감일');
    t['completedDate'] = validDate(t['completedDate'], '완료일');
    if (t['dueDate'] != '' &&
        (t['dueDate'] as String).compareTo(t['assignedDate']) < 0) {
      throw StateError('마감일은 작업 지정일보다 빠를 수 없습니다.');
    }
    if (t['description'].length > 10000 || t['reworkReason'].length > 2000) {
      throw StateError('설명 또는 재작업 사유가 너무 깁니다.');
    }
    if (t['version'] is! int ||
        t['version'] < 1 ||
        t['version'] > maxTaskVersion) {
      throw StateError('작업 버전이 올바르지 않습니다.');
    }
    if (t['updatedAt'] is! String ||
        (t['updatedAt'] as String).length > 40 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
            .hasMatch(t['updatedAt']) ||
        DateTime.tryParse(t['updatedAt']) == null) {
      throw StateError('수정 시각이 올바르지 않습니다.');
    }
    for (final field in ['archivedAt', 'deletedAt']) {
      final archivedAt = t[field] as String;
      if (archivedAt.isNotEmpty &&
          (archivedAt.length > 40 ||
              !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
                  .hasMatch(archivedAt) ||
              DateTime.tryParse(archivedAt) == null ||
              DateTime.parse(archivedAt).toIso8601String().substring(0, 19) !=
                  archivedAt.substring(0, 19))) {
        throw StateError('${fieldLabels[field]}이 올바르지 않습니다.');
      }
    }
    return WorkTask._(t);
  }
  String get id => data['id'];
  String get title => data['title'];
  String get part => data['part'];
  String get status => data['status'];
  String get priority => data['priority'];
  String get assigneeId => data['assigneeId'];
  String get reviewerId => data['reviewerId'];
  String get workflowTarget => data['workflowTarget'];
  String get workflowPerson => data['workflowPerson'];
  String get workflowRoute => data['workflowRoute'];
  String get workflowPurpose => data['workflowPurpose'];
  String get workflowSender => data['workflowSender'];
  bool get isPinned => data['pinned'] == 'true';
  String get lockedBy => data['lockedBy'];
  bool get isLocked => lockedBy.isNotEmpty;
  List<Map<String, dynamic>> get comments =>
      parseTaskComments(data['comments']);
  String get archivedAt => data['archivedAt'];
  bool get isArchived => archivedAt.isNotEmpty;
  String get deletedAt => data['deletedAt'];
  bool get isDeleted => deletedAt.isNotEmpty;
  String get currentId => workflowTarget == 'legacy'
      ? status == 'review'
            ? reviewerId
            : assigneeId
      : workflowPerson;
  String get assignedDate => data['assignedDate'];
  String get dueDate => data['dueDate'];
  String get completedDate => data['completedDate'];
  String get description => data['description'];
  String get reworkReason => data['reworkReason'];
  int get version => data['version'];
  WorkTask copy(Map<String, dynamic> updates) =>
      WorkTask.fromJson({...data, ...updates});
  bool same(WorkTask other) => fields.every((f) => data[f] == other.data[f]);
}

bool isOpenWorkflowStage(WorkTask task, List<WorkflowConnection>? connections) {
  if (connections == null) return false;
  final outgoing = connections
      .where(
        (c) =>
            c.from == task.status &&
            (c.taskParts.isEmpty || c.taskParts.contains(task.part)),
      )
      .toList();
  return outgoing.isNotEmpty &&
      outgoing.every(
        (c) =>
            c.allWorkers &&
            !c.assignedOnly &&
            c.roles.isEmpty &&
            c.taskParts.isEmpty &&
            c.actorParts.isEmpty &&
            c.returnAssigneeId.isEmpty,
      );
}

bool canEditTaskContent(
  Person actor,
  WorkTask task, {
  String? completionStatus = 'done',
  List<WorkflowConnection>? workflowConnections,
  bool manualWorkflow = false,
  ProjectManifest? workflowProject,
}) =>
    !task.isDeleted &&
    !task.isArchived &&
    hasTaskLockAccess(actor, task) &&
    (workflowProject != null
        ? canEditWorkflowTask(actor, task, workflowProject.partWorkflowView)
        : actor.active &&
              (completionStatus == null || task.status != completionStatus) &&
              ((manualWorkflow ||
                          isOpenWorkflowStage(task, workflowConnections)) &&
                      actor.canWork ||
                  task.status != 'review' &&
                      (actor.has('task.editAll') ||
                          actor.has('task.work') &&
                              actor.id == task.assigneeId)));

bool canEditTask(
  Person actor,
  WorkTask task, {
  String? completionStatus = 'done',
  List<WorkflowConnection>? workflowConnections,
  bool manualWorkflow = false,
  ProjectManifest? workflowProject,
}) =>
    !task.isDeleted &&
    !task.isArchived &&
    hasTaskLockAccess(actor, task) &&
    (workflowProject != null
        ? canEditWorkflowTask(actor, task, workflowProject.partWorkflowView)
        : (manualWorkflow ||
                  task.status != 'review' ||
                  isOpenWorkflowStage(task, workflowConnections)) &&
              (completionStatus == null || task.status != completionStatus) &&
              (actor.has('task.assign') ||
                  canEditTaskContent(
                    actor,
                    task,
                    completionStatus: completionStatus,
                    workflowConnections: workflowConnections,
                    manualWorkflow: manualWorkflow,
                  )));

bool canTransitionTask(
  Person actor,
  WorkTask task,
  String status, [
  List<String>? customStages,
  List<WorkflowConnection>? workflowConnections,
  bool manualWorkflow = false,
  ProjectManifest? workflowProject,
]) {
  workflowProject = workflowProject?.partWorkflowView;
  if (task.isDeleted || task.isArchived || !hasTaskLockAccess(actor, task)) {
    return false;
  }
  if (workflowProject?.workflowSheet != null) {
    if (actor.active &&
        workflowProject!.people.any((p) => p.id == actor.id && p.active) &&
        const ['manual-start', 'manual-finish'].any(
          (id) => directWorkflowRoute(task, workflowProject!, id)?.to == status,
        )) {
      return true;
    }
    return availableWorkflowRoutes(
      actor,
      task,
      workflowProject!,
    ).any((r) => workflowProject!.workflowSheet!.stageFor(r.to) == status);
  }
  if (!actor.active) return false;
  if (manualWorkflow) {
    return actor.canWork &&
        status != task.status &&
        customStages?.contains(status) == true &&
        !(task.status == 'done' && customStages?.contains('done') == true);
  }
  final worker =
      actor.has('task.editAll') ||
      actor.has('task.work') && actor.id == task.assigneeId;
  final reviewer =
      actor.has('task.reviewAll') ||
      actor.has('task.review') && actor.id == task.reviewerId;
  if (workflowConnections != null) {
    if (task.status == 'done' && customStages?.contains('done') == true) {
      return false;
    }
    for (final link in workflowConnections) {
      if (link.from != task.status ||
          link.to != status ||
          link.taskParts.isNotEmpty && !link.taskParts.contains(task.part) ||
          link.actorParts.isNotEmpty &&
              !link.actorParts.any(actor.parts.contains) ||
          link.roles.isNotEmpty && !link.roles.contains(actor.role)) {
        continue;
      }
      final partWide = !link.assignedOnly && link.actorParts.isNotEmpty;
      if (link.allWorkers && !link.assignedOnly && actor.canWork) return true;
      final allowed = switch (link.actor) {
        'reviewer' =>
          link.assignedOnly
              ? actor.canReview && actor.id == task.reviewerId
              : partWide
              ? actor.canReview
              : reviewer,
        'authorized' =>
          link.assignedOnly
              ? (link.from == 'review'
                    ? actor.canReview && actor.id == task.reviewerId
                    : actor.canWork && actor.id == task.assigneeId)
              : link.from == 'review'
              ? actor.canReview
              : actor.canWork,
        _ =>
          link.assignedOnly
              ? actor.canWork && actor.id == task.assigneeId
              : partWide
              ? actor.canWork
              : worker,
      };
      if (allowed) return true;
    }
    // Preserve a recovery path for tasks already in a removed/disabled stage.
    final sources = workflowConnections.map((c) => c.from).toSet();
    if (customStages != null &&
        !customStages.contains(task.status) &&
        !sources.contains(task.status) &&
        customStages.contains(status)) {
      return canTransitionTask(actor, task, status, customStages);
    }
    return false;
  }
  if (customStages != null) {
    if (customStages.isEmpty) return false;
    final currentIndex = customStages.indexOf(task.status);
    final targetIndex = customStages.indexOf(status);
    final isWorkflowId =
        const {'todo', 'doing', 'done'}.contains(task.status) ||
        task.status.startsWith('stage-');
    final orphanedStage = isWorkflowId && currentIndex < 0;
    if (task.status == 'review') {
      if (status == 'rework') return reviewer;
      final next = customStages.contains('done') ? 'done' : customStages.last;
      return status == next && reviewer;
    }
    if (task.status == 'rework') {
      return status == customStages.first && worker;
    }
    if (currentIndex >= 0 && targetIndex == currentIndex + 1) {
      return status == 'done' ? reviewer : worker;
    }
    if (orphanedStage && targetIndex >= 0) {
      if (status == 'done' && customStages.contains('done')) return reviewer;
      return task.status == 'done' ? reviewer : worker;
    }
    return false;
  }
  final workStages = ['todo', 'doing'];
  final currentIndex = workStages.indexOf(task.status);
  final targetIndex = workStages.indexOf(status);
  final orphanedCustomStage =
      task.status.startsWith('stage-') && currentIndex < 0;
  return (status == 'doing' &&
          (['todo', 'rework'].contains(task.status) || orphanedCustomStage) &&
          worker) ||
      (targetIndex >= 0 &&
          currentIndex >= 0 &&
          targetIndex == currentIndex + 1 &&
          worker) ||
      (status == 'review' &&
          worker &&
          (task.status == workStages.last || orphanedCustomStage)) ||
      (['done', 'rework'].contains(status) &&
          task.status == 'review' &&
          reviewer);
}

/// Validates one actor's changes against the latest accepted task. Collapsed
/// proposals are valid only when the same actor can perform every intermediate
/// workflow step; no other person's review is inferred from the final state.
void validateTaskMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  bool allowCollapsedTransitions = false,
  List<String>? customStages,
  List<WorkflowConnection>? workflowConnections,
  bool manualWorkflow = false,
  List<String>? projectParts,
  ProjectManifest? workflowProject,
  List<WorkTask>? revisions,
}) {
  workflowProject = workflowProject?.partWorkflowView;
  if (workflowProject?.workflowSheet != null && revisions != null) {
    if (!allowCollapsedTransitions ||
        revisions.isEmpty ||
        revisions.length > maxTaskRevisionAdvance) {
      throw StateError('작업 변경 순서와 제출 버전을 확인하세요.');
    }
    WorkTask? previous = current;
    for (final revision in revisions) {
      if (revision.id != next.id ||
          revision.version != (previous?.version ?? 0) + 1) {
        throw StateError('작업 변경 순서에 누락되거나 다른 작업의 버전이 있습니다.');
      }
      validatePartWorkflowMutation(
        actor: actor,
        next: revision,
        current: previous,
        project: workflowProject!,
      );
      previous = revision;
    }
    if (previous!.version != next.version || !previous.same(next)) {
      throw StateError('변경 순서의 마지막 내용이 제출 작업과 다릅니다.');
    }
    return;
  }
  if (validatePinMutation(
    actor: actor,
    next: next,
    current: current,
    project: workflowProject,
    allowCollapsedTransitions: allowCollapsedTransitions,
  )) {
    return;
  }
  if (validateDeleteMutation(
    actor: actor,
    next: next,
    current: current,
    project: workflowProject,
  )) {
    return;
  }
  if (validateArchiveMutation(
    actor: actor,
    next: next,
    current: current,
    project: workflowProject,
  )) {
    return;
  }
  if (workflowProject?.workflowSheet != null) {
    validatePartWorkflowMutation(
      actor: actor,
      next: next,
      current: current,
      project: workflowProject!,
      allowCollapsedTransitions: allowCollapsedTransitions,
    );
    return;
  }
  if (!actor.canMutate) {
    throw StateError('작업을 변경할 권한이 없습니다.');
  }
  if (next.status == 'done' && next.completedDate.isEmpty) {
    throw StateError('완료 상태에는 완료일이 필요합니다.');
  }
  if (projectParts != null &&
      !projectParts.contains(next.part) &&
      (current == null || current.part != next.part)) {
    throw StateError('프로젝트 설정에서 등록된 파트를 선택하세요.');
  }
  if (current == null) {
    if (!actor.has('task.create')) throw StateError('작업 등록 권한이 필요합니다.');
    final initialStatus = customStages == null
        ? 'todo'
        : workflowInitialStatus(customStages);
    if (initialStatus == null) {
      throw StateError('프로젝트 설정에서 작업을 등록할 일반 단계를 먼저 추가하세요.');
    }
    if (next.version >
        (allowCollapsedTransitions ? maxTaskRevisionAdvance : 1)) {
      throw StateError('신규 작업 버전이 올바르지 않습니다.');
    }
    if ((!allowCollapsedTransitions || next.version == 1) &&
        (next.status != initialStatus || next.reworkReason.isNotEmpty)) {
      throw StateError('신규 작업은 첫 단계에 등록해야 합니다.');
    }
    if (next.version > 1) {
      validateTaskMutation(
        actor: actor,
        next: next,
        current: next.copy({
          'status': initialStatus,
          'completedDate': initialStatus == 'done' ? next.completedDate : '',
          'reworkReason': '',
          'version': 1,
        }),
        allowCollapsedTransitions: allowCollapsedTransitions,
        customStages: customStages,
        workflowConnections: workflowConnections,
        manualWorkflow: manualWorkflow,
      );
    }
    return;
  }
  if (current.id != next.id ||
      next.version <= current.version ||
      next.version - current.version >
          (allowCollapsedTransitions ? maxTaskRevisionAdvance : 1)) {
    throw StateError('작업 ID 또는 변경 버전이 올바르지 않습니다.');
  }
  final completionStatus = customStages == null
      ? 'done'
      : customStages.contains('done')
      ? 'done'
      : null;
  if (current.status == completionStatus && completionStatus != null) {
    throw StateError('완료된 작업은 수정할 수 없습니다. 별도 작업을 등록하세요.');
  }
  final changedAssignments = assignmentFields
      .where((key) => current.data[key] != next.data[key])
      .toSet();
  final ordinaryAssignmentAllowed =
      (manualWorkflow ||
          current.status != 'review' ||
          isOpenWorkflowStage(current, workflowConnections)) &&
      actor.has('task.assign');
  if (!ordinaryAssignmentAllowed &&
      changedAssignments.any((key) => key != 'assigneeId')) {
    throw StateError('배정·일정·우선순위 변경 권한이 필요합니다.');
  }

  final contentChanged = [
    'title',
    'description',
  ].any((key) => current.data[key] != next.data[key]);
  final reasonChanged = current.reworkReason != next.reworkReason;
  // Track whether an authorized path contains an editable state / a rejection.
  // These flags prevent a reviewer-only account from editing submitted content.
  final queue = <(String, String, bool, bool, int)>[
    (
      current.status,
      current.assigneeId,
      canEditTaskContent(
        actor,
        current,
        completionStatus: completionStatus,
        workflowConnections: workflowConnections,
        manualWorkflow: manualWorkflow,
      ),
      false,
      0,
    ),
  ];
  final visited = <String>{};
  var validPath = false;
  final steps = allowCollapsedTransitions
      ? (next.version - current.version).clamp(1, maxWorkflowStages + 2)
      : 1;
  while (queue.isNotEmpty) {
    final (state, assigneeId, editable, rejected, count) = queue.removeAt(0);
    final key = '$state/$assigneeId/$editable/$rejected';
    if (!visited.add(key)) continue;
    if (state == next.status &&
        (!contentChanged || editable) &&
        (!reasonChanged || rejected) &&
        (!rejected || next.reworkReason.trim().isNotEmpty) &&
        (ordinaryAssignmentAllowed || assigneeId == next.assigneeId) &&
        (count > 0 ||
            canEditTask(
              actor,
              current,
              completionStatus: completionStatus,
              workflowConnections: workflowConnections,
              manualWorkflow: manualWorkflow,
            ))) {
      validPath = true;
      break;
    }
    if (state == completionStatus && completionStatus != null ||
        count >= steps ||
        !allowCollapsedTransitions && count > 0) {
      continue;
    }
    final intermediate = current.copy({
      'status': state,
      'assigneeId': assigneeId,
      'completedDate': state == 'done'
          ? state == current.status
                ? current.completedDate
                : next.completedDate
          : '',
    });
    final destinations = customStages == null
        ? statuses.keys
        : [...customStages, 'review', 'rework'];
    for (final destination in destinations) {
      if (!canTransitionTask(
        actor,
        intermediate,
        destination,
        customStages,
        workflowConnections,
        manualWorkflow,
      )) {
        continue;
      }
      final rejection = manualWorkflow
          ? null
          : workflowConnections
                ?.where(
                  (c) =>
                      c.from == state &&
                      c.to == destination &&
                      c.action == 'reject' &&
                      canTransitionTask(
                        actor,
                        intermediate,
                        destination,
                        customStages,
                        [c],
                      ),
                )
                .firstOrNull;
      final isRejection =
          !manualWorkflow &&
          (rejection != null ||
              workflowConnections == null &&
                  state == 'review' &&
                  destination == 'rework');
      final nextAssignee = rejection?.returnAssigneeId.isNotEmpty == true
          ? rejection!.returnAssigneeId
          : assigneeId;
      // With an uncollapsed mutation, status and content edits are distinct.
      if (!allowCollapsedTransitions && contentChanged) continue;
      final becomesEditable =
          destination != 'done' &&
          canEditTaskContent(
            actor,
            intermediate.copy({
              'status': destination,
              'assigneeId': nextAssignee,
              'completedDate': destination == 'done' ? next.completedDate : '',
            }),
            completionStatus: completionStatus,
            workflowConnections: workflowConnections,
            manualWorkflow: manualWorkflow,
          );
      queue.add((
        destination,
        nextAssignee,
        editable || becomesEditable,
        rejected || isRejection,
        count + 1,
      ));
    }
  }
  if (!validPath ||
      !manualWorkflow &&
          next.status == 'rework' &&
          next.reworkReason.trim().isEmpty ||
      reasonChanged && next.reworkReason.trim().isEmpty ||
      current.status == next.status &&
          current.completedDate != next.completedDate ||
      (next.status == completionStatus) != (next.completedDate.isNotEmpty)) {
    throw StateError('현재 권한과 작업 단계에 허용되지 않은 작업 변경입니다.');
  }
}

// Existing task files omit these fields; they remain unlocked and comment-free.
bool hasTaskLockAccess(Person actor, WorkTask task) =>
    !task.isLocked || task.lockedBy == actor.id;

List<Map<String, dynamic>> parseTaskComments(String raw) {
  if (raw.length > 240000) throw StateError('코멘트 데이터가 너무 큽니다.');
  final dynamic value;
  try {
    value = jsonDecode(raw);
  } catch (_) {
    throw StateError('코멘트 데이터 형식을 확인하세요.');
  }
  if (value is! List || value.length > 100) {
    throw StateError('작업당 코멘트는 최대 100개까지 등록할 수 있습니다.');
  }
  final ids = <String>{};
  final result = <Map<String, dynamic>>[];
  for (final entry in value) {
    if (entry is! Map ||
        entry.length != 4 ||
        entry['id'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(entry['id']) ||
        !ids.add(entry['id']) ||
        entry['authorId'] is! String ||
        !RegExp(r'^gh-[0-9]+$').hasMatch(entry['authorId']) ||
        entry['text'] is! String ||
        (entry['text'] as String).trim().isEmpty ||
        (entry['text'] as String).length > 2000 ||
        entry['createdAt'] is! String ||
        (entry['createdAt'] as String).length > 40 ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
            .hasMatch(entry['createdAt']) ||
        DateTime.tryParse(entry['createdAt']) == null) {
      throw StateError('코멘트 작성자, 내용과 시각을 확인하세요.');
    }
    result.add(Map<String, dynamic>.unmodifiable(entry));
  }
  return List.unmodifiable(result);
}

/// Pinned items float ahead of the selected sort; their priorities always win.
int compareTaskPins(WorkTask a, WorkTask b) {
  if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
  if (!a.isPinned) return 0;
  const ranks = {'high': 0, 'normal': 1, 'low': 2};
  return ranks[a.priority]!.compareTo(ranks[b.priority]!);
}
