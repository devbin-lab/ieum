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
  'reworkReason': '재작업 사유',
};
const statuses = {
  'todo': '할 일',
  'doing': '진행 중',
  'review': '검토',
  'rework': '재작업',
  'done': '완료',
};
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
  });
  bool get manages => role == 'owner' || role == 'manager';
  bool get active => ['owner', 'manager', 'worker', 'viewer'].contains(role);
  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    'role': role,
    'login': login,
    'parts': parts,
  };
  factory Person.fromJson(Map<String, dynamic> data) {
    final id = data['id'],
        name = data['name'],
        role = data['role'],
        login = data['login'];
    if (id is! String ||
        !RegExp(r'^gh-[0-9]+$').hasMatch(id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 40 ||
        login is! String ||
        !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(login) ||
        !roleLabels.containsKey(role) ||
        data['parts'] is! List) {
      throw StateError('참여자 정보가 올바르지 않습니다.');
    }
    final parts = List<String>.from(data['parts']);
    if (parts.any((p) => !rules.any((r) => r.part == p))) {
      throw StateError('담당 파트가 올바르지 않습니다.');
    }
    return Person(
      id,
      name.trim(),
      name.trim().substring(0, 1),
      role as String,
      0xff7963d5,
      login: login,
      parts: List.unmodifiable(parts),
    );
  }
}

const roleLabels = {
  'owner': '개설자',
  'manager': 'PD / PM',
  'worker': '작업자',
  'viewer': '열람자',
  'pending': '가입 승인 대기',
  'disabled': '참여 중지',
};

class ProjectManifest {
  final String id, name, ownerId;
  final List<Person> people;
  const ProjectManifest(this.id, this.name, this.ownerId, this.people);
  Map<String, dynamic> get json => {
    'schemaVersion': 1,
    'projectId': id,
    'name': name,
    'ownerId': ownerId,
    'members': people.map((p) => p.json).toList(),
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
    final people = (raw['members'] as List)
        .map((p) => Person.fromJson(Map<String, dynamic>.from(p)))
        .toList();
    if (people.map((p) => p.id).toSet().length != people.length ||
        people.where((p) => p.role == 'owner').length != 1 ||
        !people.any((p) => p.id == raw['ownerId'] && p.role == 'owner')) {
      throw StateError('프로젝트 개설자와 참여자 정보를 확인하세요.');
    }
    return ProjectManifest(
      raw['projectId'],
      (raw['name'] as String).trim(),
      raw['ownerId'],
      List.unmodifiable(people),
    );
  }
}

const members = [
  Person('planner', '기획 담당자', '기', 'worker', 0xff8263eb),
  Person('dev', '개발 담당자', '개', 'worker', 0xff4486c6),
  Person('artist', '아트 담당자', '아', 'worker', 0xffc56b86),
  Person('pm', 'PD / PM', 'P', 'manager', 0xff557d6d),
];
Person person(String id) => members.firstWhere(
  (p) => p.id == id,
  orElse: () => throw StateError('등록된 테스트 사용자를 선택하세요.'),
);

class PartRule {
  final String part, assigneeId, reviewerId, nextPart;
  const PartRule(this.part, this.assigneeId, this.reviewerId, this.nextPart);
}

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
      throw StateError('작업 데이터에 지원하지 않는 항목이 있습니다.');
    }
    final t = Map<String, dynamic>.from(raw);
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
    if (!rules.any((r) => r.part == t['part']) ||
        !statuses.containsKey(t['status']) ||
        !priorities.containsKey(t['priority'])) {
      throw StateError('담당 파트, 상태, 우선순위를 확인하세요.');
    }
    for (final key in ['assigneeId', 'reviewerId']) {
      if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(t[key])) {
        throw StateError('담당자 ID가 올바르지 않습니다.');
      }
    }
    t['assignedDate'] = validDate(t['assignedDate'], '작업 지정일', required: true);
    t['dueDate'] = validDate(t['dueDate'], '마감일');
    t['completedDate'] = validDate(t['completedDate'], '완료일');
    if (t['dueDate'] != '' &&
        (t['dueDate'] as String).compareTo(t['assignedDate']) < 0) {
      throw StateError('마감일은 작업 지정일보다 빠를 수 없습니다.');
    }
    if ((t['status'] == 'done') != (t['completedDate'] != '')) {
      throw StateError('완료일은 최종 승인 시에만 기록됩니다.');
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
    return WorkTask._(t);
  }
  String get id => data['id'];
  String get title => data['title'];
  String get part => data['part'];
  String get status => data['status'];
  String get priority => data['priority'];
  String get assigneeId => data['assigneeId'];
  String get reviewerId => data['reviewerId'];
  String get currentId => status == 'review' ? reviewerId : assigneeId;
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

bool canEditTaskContent(Person actor, WorkTask task) =>
    actor.active &&
    !['review', 'done'].contains(task.status) &&
    (actor.manages || actor.role == 'worker' && actor.id == task.assigneeId);

bool canEditTask(Person actor, WorkTask task) =>
    task.status != 'done' && (actor.manages || canEditTaskContent(actor, task));

bool canTransitionTask(Person actor, WorkTask task, String status) {
  if (!actor.active || actor.role == 'viewer') return false;
  final worker = actor.id == task.assigneeId || actor.manages;
  final reviewer = actor.id == task.reviewerId || actor.manages;
  return status == 'doing' &&
          ['todo', 'rework'].contains(task.status) &&
          worker ||
      status == 'review' && task.status == 'doing' && worker ||
      ['done', 'rework'].contains(status) &&
          task.status == 'review' &&
          reviewer;
}

/// Validates one actor's changes against the latest accepted task. Collapsed
/// proposals are valid only when the same actor can perform every intermediate
/// workflow step; no other person's review is inferred from the final state.
void validateTaskMutation({
  required Person actor,
  required WorkTask next,
  WorkTask? current,
  bool allowCollapsedTransitions = false,
}) {
  if (!actor.active || actor.role == 'viewer') {
    throw StateError('작업을 변경할 권한이 없습니다.');
  }
  if (current == null) {
    if (!actor.manages) throw StateError('작업 등록은 개설자 또는 PD / PM에게 허용됩니다.');
    if (next.version >
        (allowCollapsedTransitions ? maxTaskRevisionAdvance : 1)) {
      throw StateError('신규 작업 버전이 올바르지 않습니다.');
    }
    if ((!allowCollapsedTransitions || next.version == 1) &&
        (next.status != 'todo' || next.reworkReason.isNotEmpty)) {
      throw StateError('신규 작업은 할 일 상태로 등록해야 합니다.');
    }
    if (next.version > 1) {
      validateTaskMutation(
        actor: actor,
        next: next,
        current: next.copy({
          'status': 'todo',
          'completedDate': '',
          'reworkReason': '',
          'version': 1,
        }),
        allowCollapsedTransitions: allowCollapsedTransitions,
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
  if (current.status == 'done') {
    throw StateError('완료된 작업은 수정할 수 없습니다. 별도 작업을 등록하세요.');
  }
  if (!actor.manages &&
      assignmentFields.any((key) => current.data[key] != next.data[key])) {
    throw StateError('배정·일정·우선순위 변경은 PD / PM에게 허용됩니다.');
  }

  final contentChanged = [
    'title',
    'description',
  ].any((key) => current.data[key] != next.data[key]);
  final reasonChanged = current.reworkReason != next.reworkReason;
  // Track whether an authorized path contains an editable state / a rejection.
  // These flags prevent a reviewer-only account from editing submitted content.
  final queue = <(String, bool, bool, int)>[
    (current.status, canEditTaskContent(actor, current), false, 0),
  ];
  final visited = <String>{};
  var validPath = false;
  final steps = allowCollapsedTransitions
      ? (next.version - current.version).clamp(1, 20)
      : 1;
  while (queue.isNotEmpty) {
    final (state, editable, rejected, count) = queue.removeAt(0);
    final key = '$state/$editable/$rejected';
    if (!visited.add(key)) continue;
    if (state == next.status &&
        (!contentChanged || editable) &&
        (!reasonChanged || rejected) &&
        (count > 0 || canEditTask(actor, current))) {
      validPath = true;
      break;
    }
    if (state == 'done' ||
        count >= steps ||
        !allowCollapsedTransitions && count > 0) {
      continue;
    }
    final intermediate = current.copy({
      'status': state,
      'completedDate': state == 'done' ? next.completedDate : '',
    });
    for (final destination in statuses.keys) {
      if (!canTransitionTask(actor, intermediate, destination)) continue;
      // With an uncollapsed mutation, status and content edits are distinct.
      if (!allowCollapsedTransitions && contentChanged) continue;
      final becomesEditable =
          !['review', 'done'].contains(destination) &&
          (actor.manages || actor.id == current.assigneeId);
      queue.add((
        destination,
        editable || becomesEditable,
        rejected || destination == 'rework',
        count + 1,
      ));
    }
  }
  if (!validPath ||
      next.status == 'rework' && next.reworkReason.isEmpty ||
      reasonChanged && next.reworkReason.isEmpty ||
      current.status == next.status &&
          current.completedDate != next.completedDate) {
    throw StateError('현재 담당자와 검토 순서에 허용되지 않은 작업 변경입니다.');
  }
}
