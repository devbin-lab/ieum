import 'models.dart';

/// Presentation and action rules use stable IDs, never translated role names.
String memberState(Person person) => person.role == 'pending'
    ? 'pending'
    : person.active
    ? 'active'
    : 'disabled';

const memberStateLabels = {
  'active': '활성화',
  'disabled': '비활성화',
  'pending': '승인 대기',
};

String memberRoleLabel(Person person) => person.role == 'disabled'
    ? '이전 역할 정보 없음'
    : person.role == 'pending'
    ? '미배정'
    : person.roleLabel;

bool canAssignMember(Person actor, Person target, String ownerId) =>
    actor.has('member.manage') &&
    target.id != ownerId &&
    target.role != 'owner' &&
    actor.permissions.containsAll(target.permissions) &&
    (actor.role == 'owner' || target.role != 'manager');

String memberReadOnlyReason(Person actor, Person target, String ownerId) =>
    target.id == ownerId
    ? '관리자의 역할은 전용 관리자 권한 이전으로 변경합니다.'
    : !actor.has('member.manage')
    ? '읽기 전용 · 참여자 관리 권한이 필요합니다.'
    : !canAssignMember(actor, target, ownerId)
    ? '본인보다 높은 권한의 참여자는 변경할 수 없습니다.'
    : '';

List<Person> filterMembers(
  Iterable<Person> people, {
  String query = '',
  String role = '',
  String state = '',
  String part = '',
}) {
  final normalized = query.trim().toLowerCase();
  final result = people
      .where(
        (p) =>
            ('${p.name} ${p.login}').toLowerCase().contains(normalized) &&
            (role.isEmpty || p.role == role) &&
            (state.isEmpty || memberState(p) == state) &&
            (part.isEmpty || p.parts.contains(part)),
      )
      .toList();
  result.sort((a, b) {
    final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return name != 0 ? name : a.id.compareTo(b.id);
  });
  return result;
}
