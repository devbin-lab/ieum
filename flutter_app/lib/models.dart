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

class Person {
  final String id, name, initials, role;
  final int color;
  const Person(this.id, this.name, this.initials, this.role, this.color);
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
    person(t['assigneeId']);
    person(t['reviewerId']);
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
    if (t['version'] is! int || t['version'] < 1) {
      throw StateError('작업 버전이 올바르지 않습니다.');
    }
    if (t['updatedAt'] is! String) throw StateError('수정 시각이 올바르지 않습니다.');
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
