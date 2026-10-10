import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_localizations_workspace.dart';

/// Application-owned copy only. User-authored task and project data never enters
/// the translation catalog or changes when the display language changes.
String _language = 'ko';
String get appLanguage => _language;
bool get isEnglish => _language == 'en';
void setAppLanguage(String code) => _language = code == 'en' ? 'en' : 'ko';

class AppLocalizations {
  const AppLocalizations(this.locale);
  final Locale locale;
  static const supportedLocales = [Locale('ko'), Locale('en')];
  static const delegate = _AppLocalizationsDelegate();
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) =>
      const ['ko', 'en'].contains(locale.languageCode);
  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(AppLocalizations(locale));
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

String _canonical(String source) {
  var index = 0;
  return source.replaceAllMapped(RegExp(r'\{\w+\}'), (_) => '{v${index++}}');
}

String tr(String source, {Map<String, Object?> args = const {}}) {
  var result = source;
  if (isEnglish) {
    result = _english[source] ?? _english[_canonical(source)] ?? source;
    // Legacy app-owned messages were persisted in Korean. Interpret registered
    // templates only at display time, without altering their source records.
    if (result == source && args.isEmpty) result = _translateLegacy(source);
  }
  if (args.isEmpty) return result;
  final names = RegExp(r'\{(\w+)\}')
      .allMatches(source)
      .map((m) => m[1]!)
      .toList();
  final values = <String, Object?>{...args};
  for (var index = 0; index < names.length; index++) {
    values['v$index'] = args[names[index]];
  }
  return result.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) {
    final key = match[1]!;
    return values.containsKey(key) ? '${values[key] ?? ''}' : match[0]!;
  });
}

String _translateLegacy(String source) {
  for (final entry in _legacyTemplates) {
    final match = entry.$1.firstMatch(source);
    if (match == null) continue;
    return entry.$3.replaceAllMapped(RegExp(r'\{(\w+)\}'), (part) {
      final index = entry.$2.indexOf(part[1]!) + 1;
      return index > 0 && index <= match.groupCount ? match[index]! : part[0]!;
    });
  }
  return source;
}

final _legacyTemplates = <(RegExp, List<String>, String)>[
  for (final entry in _english.entries)
    if (entry.key.contains(RegExp(r'\{\w+\}')) &&
        RegExp(r'[가-힣]').hasMatch(entry.key))
      (
        RegExp(
          '^${entry.key.split(RegExp(r'\{\w+\}')).map(RegExp.escape).join('(.*?)')}\$',
          dotAll: true,
        ),
        RegExp(r'\{(\w+)\}').allMatches(entry.key).map((m) => m[1]!).toList(),
        entry.value,
      ),
];

String trError(Object error) => tr(
  error.toString().replaceFirst(RegExp(r'^(Bad state: |Exception: )'), ''),
);
String trEventMessage(String message) => tr(message);
Map<String, String> translatedLabels(Map<String, String> labels) => {
  for (final entry in labels.entries) entry.key: tr(entry.value),
};

/// System stage names are localized by their stable ID. Custom names remain
/// untouched, even if their text happens to resemble a translated label.
String trStageName(String id, String name) {
  const known = {
    'todo': {'확인중', '할 일'},
    'doing': {'진행중', '진행 중'},
    'review': {'검토중', '검토'},
    'done': {'완료'},
    'hold': {'보류'},
    'drop': {'드랍'},
  };
  return known[id]?.contains(name) == true ? tr(name) : name;
}

String trRoleName(String id, String name) =>
    const {
      'owner',
      'manager',
      'operator',
      'worker',
      'viewer',
      'pending',
      'disabled',
    }.contains(id)
    ? tr(name)
    : name;

final _english = <String, String>{
  '디자인': 'Appearance',
  '언어': 'Language',
  '화면 모드': 'Theme',
  '라이트': 'Light',
  '다크': 'Dark',
  '시스템': 'System',
  '포인트 컬러': 'Accent color',
  '사용자 지정 색상': 'Custom color',
  '화면 미리보기': 'Preview',
  '설정 초기화': 'Reset settings',
  '기본 설정으로 되돌리기': 'Restore defaults',
  '변경 사항은 바로 적용됩니다.': 'Changes take effect immediately.',
  '색상 코드': 'Color code',
  '적용': 'Apply',
  '취소': 'Cancel',
  '앱 언어': 'App language',
  '한국어': 'Korean',
  '영어': 'English',
  '언어를 변경하면 앱 화면에 바로 적용됩니다.': 'The selected language applies immediately.',
  '올바른 색상 코드를 입력하세요. (예: #7963D5)':
      'Enter a valid color code, such as #7963D5.',
  '개인 설정': 'Personal settings',
  '일반': 'General',
  '프로젝트 설정': 'Project settings',
  '설정 검색': 'Search settings',
  '검색 지우기': 'Clear search',
  '검색 결과가 없습니다.': 'No results found.',
  '계정 및 앱 환경 설정': 'Account and app preferences',
  '작업 진행': 'In progress',
  '색상 미리보기': 'Color preview',
  '저장': 'Save',
  '보라': 'Purple',
  '파랑': 'Blue',
  '청록': 'Teal',
  '초록': 'Green',
  '황금': 'Gold',
  '주황': 'Orange',
  '분홍': 'Pink',
  '회색': 'Gray',
  '버튼': 'Button',
  '선택된 항목': 'Selected item',
  '개인': 'Personal',
  '설정': 'Settings',
  '버전 계정 이름': 'Version account name',
  '테마 라이트 다크 모드 색상 포인트': 'Theme light dark mode color accent',
  '한국어 영어 번역 언어': 'Korean English translation language',
  '저장 폴더 저장소': 'Storage folder repository',
  '앱 알림함 작업 배정': 'App inbox task assignment',
  '팀원 파트 가입 승인': 'Members teams join approval',
  '파트 추가 수정 삭제 배정': 'Team add edit delete assignment',
  '작업 단계': 'Task statuses',
  '칸반 상태 단계 추가 삭제': 'Kanban status stage add delete',
  'GitHub 동기화': 'GitHub sync',
  '통합': 'Integration',
  '저장소 브랜치 PR 전송': 'Repository branch PR send',
  '내 변경 기록': 'My changes',
  '변경안 가져오기 내보내기': 'Changes import export',
  '브라우저에서 {v0} 을 직접 열어주세요.': 'Open {v0} in your browser.',
  '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 자동으로 동기화합니다.':
      'Offline · Your saved project is open. It will sync when you reconnect.',
  '프로젝트 열기가 취소되었습니다.': 'Opening the project was canceled.',
  '이름 변경 전송 대기: {v0}': 'Name update pending: {v0}',
  'DB를 저장할 로컬 폴더의 전체 경로를 지정하세요.':
      'Enter the full path to the local data folder.',
  '프로젝트 이름은 1~80자로 입력하세요.': 'Enter a project name of 1–80 characters.',
  'DB 파일이 없습니다. 프로젝트 참여에서 기존 DB 저장 폴더를 선택하세요.': 'The data file is missing. Join the project using its existing data folder.',
  '이 계정과 프로젝트에 등록된 DB가 아닙니다. 내 계정으로 참여하세요.': 'This data belongs to a different account or project. Join with your own account.',
  '이 DB와 연결된 프로젝트 저장소가 아닙니다.':
      'This repository does not match the saved project.',
  '내 작업 공간을 준비하고 있어요': 'Preparing your workspace…',
  '프로젝트 시작하기': 'Get started',
  '이음에 로그인': 'Sign in to Ieum',
  '@{v0} · GitHub 인증 완료': '@{v0} · Connected to GitHub',
  'GitHub 계정으로 인증한 뒤 프로젝트를 만들거나 참여하세요.':
      'Sign in with GitHub to create or join a project.',
  'GitHub에서 이음의 저장소 접근을 승인하면 로그인됩니다.\n작업 등록·PR·동기화를 위해 저장소 권한을 요청합니다.': 'Authorize Ieum on GitHub to sign in.\nRepository access is used to save tasks, create pull requests, and sync.',
  '이 컴퓨터에서 로그인 유지': 'Keep me signed in on this computer',
  'GitHub 인증 코드': 'GitHub verification code',
  '브라우저에 위 코드를 입력하고 이음의 접근을 승인하세요.\n인증 코드가 만료되면 다시 로그인할 수 있습니다.': 'Enter this code in your browser and authorize Ieum.\nIf the code expires, start sign-in again.',
  '코드 복사': 'Copy code',
  'GitHub 인증 페이지 열기': 'Open GitHub verification',
  '로그인 취소': 'Cancel sign-in',
  '로그인 확인 중…': 'Checking sign-in…',
  'GitHub 승인 대기 중…': 'Waiting for GitHub authorization…',
  'GitHub로 로그인': 'Sign in with GitHub',
  'GitHub 계정 만들기': 'Create a GitHub account',
  '고급 연결 닫기': 'Hide advanced options',
  '고급 연결': 'Advanced connection',
  '세션 토큰 (선택)': 'Session token (optional)',
  '비워 두면 컴퓨터에 저장된 Git 인증 사용': 'Leave blank to use saved Git credentials',
  '토큰은 앱 메모리에만 보관합니다. 이음 비밀번호는 만들지 않습니다.\nGitHub 계정이 없다면 GitHub에서 계정을 만든 뒤 저장소 초대를 받으세요.': 'Tokens are kept in memory only. No Ieum password is needed.\nCreate a GitHub account and accept a repository invitation to join.',
  '계정 확인 중…': 'Checking account…',
  'GitHub 연결 / 로그인': 'Connect to GitHub',
  '현재 프로젝트로 돌아가기': 'Return to project',
  '최근 프로젝트 열기': 'Open recent project',
  '프로젝트 생성': 'Create project',
  '프로젝트 참여': 'Join project',
  '프로젝트 이름': 'Project name',
  'GitHub 저장소': 'GitHub repository',
  '소유자/저장소 또는 HTTPS 주소': 'owner/repository or HTTPS URL',
  '이름 / 닉네임': 'Display name',
  '이 컴퓨터에 안전하게 저장': 'Saved locally on this computer',
  '작업은 자동 저장되고 GitHub와 동기화됩니다.\n인터넷이 끊겨도 저장된 프로젝트에서 작업할 수 있습니다.': 'Tasks are saved automatically and synced with GitHub.\nYou can keep working on saved projects while offline.',
  '저장 위치 닫기': 'Hide storage options',
  '저장 위치 변경': 'Change storage location',
  '로컬 저장 폴더': 'Local data folder',
  '저장 위치 선택': 'Choose storage location',
  '폴더 선택': 'Choose folder',
  '프로젝트를 만들고 팀의 작업을 시작합니다. 파트는 프로젝트 설정에서 추가할 수 있습니다.': 'Create a project to start working with your team. Add teams in project settings.',
  '먼저 GitHub 저장소 초대를 수락해 주세요. 참여 요청을 관리자가 승인하면 작업을 시작할 수 있습니다.': 'Accept the GitHub repository invitation first. You can work after an administrator approves your request.',
  '프로젝트 준비 중…': 'Preparing project…',
  '참여 요청': 'Join requests',
  '로그아웃': 'Sign out',
  '새 작업 창 닫기': 'Close new task',
  '작업 수정 창 닫기': 'Close task editor',
  '새 작업': 'New task',
  '작업 수정': 'Edit task',
  '작업 내용': 'Task details',
  '작업 제목': 'Task title',
  '어떤 작업을 진행하나요?': 'What needs to be done?',
  '제목을 입력하세요.': 'Enter a title.',
  '설명': 'Description',
  '작업 내용과 완료 기준을 입력하세요.': 'Describe the work and completion criteria.',
  '담당': 'Assignment',
  '프로젝트 설정에서 파트를 추가한 후 작업을 만들 수 있습니다.':
      'Add a team in project settings before creating a task.',
  '담당 파트': 'Team',
  '{v0} (삭제된 파트)': '{v0} (deleted team)',
  '담당자': 'Assignee',
  '최초 담당자': 'Initial assignee',
  '전달 기능으로 담당자를 변경할 수 있습니다.': 'Use handoff to change the assignee.',
  '최초 배정 정보입니다. 현재 담당자는 전달 기능으로 변경하세요.': 'This is the original assignment. Use handoff to change the current assignee.',
  '현재 담당자 · {v0}': 'Current assignee · {v0}',
  '일정': 'Schedule',
  '시작일': 'Start date',
  '날짜를 YYYY-MM-DD 형식으로 입력하세요.': 'Enter a date in YYYY-MM-DD format.',
  '마감일': 'Due date',
  '우선순위': 'Priority',
  '수정 허용': 'Editing access',
  '모든 참여자 · 잠금 없음': 'All members · Unlocked',
  '작성자만 · 잠금': 'Creator only · Locked',
  '담당자만 · 잠금': 'Assignee only · Locked',
  '등록': 'Add',
  '닫기': 'Close',
  '작업': 'Tasks',
  '검토': 'Review',
  '수정': 'Edit',
  '작업 전달': 'Hand off task',
  '상태 변경': 'Change status',
  '확인 창 닫기': 'Close confirmation',
  '전달 대상': 'Recipient',
  '파트': 'Teams',
  '전체 파트': 'All teams',
  '모든 파트': 'All teams',
  '담당자를 선택하세요': 'Select an assignee',
  '{v0} 전체': 'Everyone in {v0}',
  '작업 상태를 유지한 채 담당자에게 전달합니다.': 'Hand off the task without changing its status.',
  '{v0} 상태로 변경하고 담당자에게 전달합니다.':
      'Change the status to {v0} and hand off the task.',
  '받는 담당자만 수정 허용': 'Only the recipient can edit',
  '담당자를 한 명 선택하면 작업이 잠깁니다.': 'Selecting one assignee locks the task to them.',
  '잠금 없이 전달하면 모든 참여자가 수정할 수 있습니다.':
      'All members can edit when the task is handed off without a lock.',
  '요청 유형': 'Request type',
  '작업을 완료합니다. 최종 결과를 확인하세요.':
      'Check the final result before completing the task.',
  '담당자 · {v0}': 'Assignee · {v0}',
  '요청 유형 · {v0}': 'Request type · {v0}',
  '반려 사유 · 필수': 'Rejection reason · Required',
  '댓글 · 필수': 'Comment · Required',
  '댓글 · 선택': 'Comment · Optional',
  '보완할 내용을 입력하세요.': 'Describe what needs to be revised.',
  '함께 전달할 내용을 입력하세요.': 'Add a message for the recipient.',
  '작업 정보가 변경되었습니다. 창을 닫고 다시 시도하세요.':
      'This task has changed. Close this window and try again.',
  '전달': 'Hand off',
  '완료': 'Done',
  '변경': 'Change',
  '관리자': 'Administrator',
  '참여자': 'Members',
  'GitHub 초대를 보냈습니다. 초대 수락 후 이음에서 참여 요청을 승인해 주세요.': 'GitHub invitation sent. Approve the join request in Ieum after the invitation is accepted.',
  '초대를 보내지 못했습니다. {v0}': 'Could not send the invitation. {v0}',
  'GitHub 협업자 초대': 'Invite GitHub collaborator',
  'GitHub 사용자 이름': 'GitHub username',
  '저장소 접근 권한을 위한 GitHub 초대입니다. 프로젝트 참여 승인과 파트 배정은 참여자 관리에서 진행합니다.': 'This invitation grants repository access. Approve project membership and assign teams in Members.',
  '전송 중…': 'Sending…',
  '초대 보내기': 'Send invitation',
  '관리자 권한을 이전할 수 있는 활성 참여자가 없습니다.':
      'No active member is available to become administrator.',
  '관리자 권한 이전 확인': 'Confirm administrator transfer',
  '{v0} 님이 프로젝트 관리자가 됩니다. 현재 관리자는 일반 참여자로 변경됩니다. GitHub 저장소의 소유권과 접근 권한은 변경되지 않습니다.': '{v0} will become the project administrator. You will become a regular member. GitHub repository ownership and access will stay the same.',
  '관리자 권한을 이전하지 못했습니다. {v0}': 'Could not transfer administrator access. {v0}',
  '관리자 권한 이전': 'Transfer administrator access',
  '새 관리자 선택': 'Select new administrator',
  '프로젝트 관리자를 변경합니다. GitHub 저장소의 소유권과 접근 권한은 변경되지 않습니다.': 'Change the project administrator. GitHub repository ownership and access will stay the same.',
  '이전 중…': 'Transferring…',
  '참여자 목록을 새로고침하지 못했습니다. 마지막으로 확인한 목록을 표시합니다. {v0}':
      'Could not refresh members. Showing the last available list. {v0}',
  '파트 관리 권한이 필요합니다.': 'Team management permission is required.',
  '확인': 'Confirm',
  '프로젝트가 변경되었습니다.': 'The project has changed.',
  '현재 참여자 상태 변경 권한이 없습니다.': 'You cannot change this member\'s status.',
  '인수인계가 필요합니다: {v0}. 관련 작업의 담당자를 변경하고 대기 중인 변경 사항을 처리해 주세요.': 'Handoff required: {v0}. Reassign related tasks and resolve pending changes.',
  '비활성화 사전 확인 실패: {v0}': 'Could not check deactivation requirements: {v0}',
  '참여자 활성화': 'Activate member',
  '참여자 비활성화': 'Deactivate member',
  '프로젝트 작업과 동기화를 다시 사용할 수 있습니다. 잠긴 작업은 지정된 담당자만 수정할 수 있습니다.': 'Project work and syncing will be enabled again. Locked tasks can only be edited by their assignee.',
  '프로젝트 작업과 동기화를 사용할 수 없게 됩니다. 남은 작업과 전송 중인 변경 사항은 먼저 인수인계해 주세요.': 'Project work and syncing will be disabled. Hand off remaining tasks and pending changes first.',
  '상태 저장 실패: {v0}': 'Could not save status: {v0}',
  '참여자 설정 변경': 'Update member settings',
  '프로젝트 참여 승인': 'Approve project membership',
  '{v0} · @{v1}\n소속 파트: {v2} → {v3}\n참여 상태: {v4}':
      '{v0} · @{v1}\nTeams: {v2} → {v3}\nMembership: {v4}',
  '변경 사항을 저장하지 못했습니다. 입력한 내용은 유지됩니다. {v0}':
      'Could not save changes. Your edits have been preserved. {v0}',
  '{v0} · 참여자 설정': '{v0} · Member settings',
  '참여 상태': 'Membership status',
  '활성화': 'Active',
  '비활성화': 'Inactive',
  '소유자의 관리자 권한과 활성 상태는 유지됩니다.':
      'The owner retains administrator access and active status.',
  '비활성화하려면 남은 작업과 전송 중인 변경 사항을 먼저 인수인계해 주세요.': 'Hand off remaining tasks and pending changes before deactivating this member.',
  '소속 파트': 'Teams',
  '여러 파트에 소속될 수 있습니다. 작업을 전달할 때 파트 또는 담당자를 선택할 수 있습니다.': 'Members can belong to multiple teams. Choose a team or person when handing off a task.',
  '파트 추가': 'Add team',
  '저장되지 않은 변경 사항': 'Unsaved changes',
  '저장소 프로젝트가 변경되었습니다.': 'The repository project has changed.',
  '참여자가 삭제되었습니다.': 'This member has been removed.',
  '최신 정보를 불러왔습니다. 입력한 내용을 확인한 뒤 다시 저장해 주세요.':
      'Latest information loaded. Check your edits and save again.',
  '최신 정보 불러오기': 'Load latest information',
  '저장 중…': 'Saving…',
  '참여 승인': 'Approve membership',
  '참여 요청 거절': 'Decline join request',
  '{v0} 님의 참여 요청을 거절합니다. 이미 승인된 참여자의 설정은 변경되지 않습니다.': 'Decline the join request from {v0}. Existing member settings will stay the same.',
  '요청 거절 실패: {v0}': 'Could not decline the request: {v0}',
  '선택한 참여자가 검색 결과에서 제외되어 상세를 닫았습니다.': 'The selected member is no longer in the results. Their details have been closed.',
  '참여자 상세': 'Member details',
  '참여자가 더 이상 프로젝트에 없습니다.': 'This member is no longer in the project.',
  '권한': 'Permissions',
  '미배정': 'Unassigned',
  '본인': 'You',
  '프로젝트 소유자': 'Project owner',
  '관련 작업 {v0}건': 'Related tasks · {v0}',
  '관련 작업 보기': 'View related tasks',
  '파트 배정': 'Assign teams',
  '참여자 {v0}명': '{v0} members',
  '참여자 초대': 'Invite member',
  '새로고침': 'Refresh',
  '더보기': 'More',
  '소유자': 'Owner',
  '{v0} 더보기': 'More options for {v0}',
  '최근 새로고침 {v0}:{v1}{v2}': 'Last refreshed {v0}:{v1}{v2}',
  ' · 연결을 확인해 주세요.': ' · Check your connection.',
  '파트 미배정': 'No team',
  '참여자를 변경하려면 참여자 관리 권한이 필요합니다.':
      'Member management permission is required to edit members.',
  '이름 또는 GitHub 사용자 이름': 'Name or GitHub username',
  '모든 상태': 'All statuses',
  '초기화': 'Reset',
  '{v0}명 표시 · 전체 {v1}명': '{v0} of {v1} members',
  '검색 결과가 없습니다. 검색어와 필터를 초기화하세요.':
      'No results found. Clear the search and filters.',
  '대기 중인 참여 요청이 없습니다.': 'No pending join requests.',
  '파트 배정 후 승인': 'Assign teams and approve',
  '거절': 'Decline',
  '변경 사항을 저장했습니다.': 'Changes saved.',
  '이 파트가 삭제되었습니다. 목록을 새로고침해 주세요.': 'This team was deleted. Refresh the list.',
  '이 파트가 삭제되어 더 이상 수정할 수 없습니다.':
      'This team was deleted and can no longer be edited.',
  '“{v0}” 파트 삭제': 'Delete team “{v0}”',
  '이 파트와 참여자의 파트 배정이 삭제됩니다. 작업 기록은 유지됩니다. 담당 파트가 변경될 작업이 있는지 확인해 주세요.': 'This team and its member assignments will be removed. Task history will be preserved. Check affected tasks before continuing.',
  '삭제': 'Delete',
  '파트 검색': 'Search teams',
  '파트 새로고침': 'Refresh teams',
  '파트별로 참여자를 배정하고 참여자·파트 관리 권한을 설정합니다.':
      'Assign members to teams and configure management permissions.',
  '파트 · {v0}': 'Teams · {v0}',
  '파트를 추가하면 여기에 표시됩니다.': 'Teams you add will appear here.',
  '프로젝트 권한': 'Project permissions',
  '{v0}명 배정': '{v0} members assigned',
  '등록된 파트가 없습니다.': 'No teams yet.',
  '파트를 추가해 프로젝트 참여자를 배정할 수 있습니다.': 'Add a team to organize project members.',
  '{v0} · {v1}명': '{v0} · {v1} members',
  '프로젝트·참여자·파트를 관리하고 전달된 작업을 회수할 수 있습니다. 잠긴 작업의 수정 권한은 지정된 담당자에게 있습니다.': 'Manage the project, members, and teams, and recover handed-off tasks. Locked tasks can only be edited by their assigned owner.',
  '이 파트를 편집하려면 파트 관리 권한이 필요합니다.':
      'Team management permission is required to edit this team.',
  '관리 권한': 'Management permissions',
  '배정된 참여자 ({v0})': 'Assigned members ({v0})',
  '파트 배정은 참여자 관리에서 변경할 수 있습니다.': 'Change team assignments in Members.',
  '이 파트에 배정된 참여자가 없습니다.': 'No members are assigned to this team.',
  '파트 목록을 저장했습니다.': 'Teams saved.',
  '중복되지 않는 이름을 1~40자로 입력하세요. 최대 50개까지 등록할 수 있습니다.':
      'Use a unique name of 1–40 characters. You can add up to 50 teams.',
  '파트 이름': 'Team name',
  '예: 기획, 디렉터': 'For example: Design, Director',
  '저장 중': 'Saving…',
  '추가': 'Add',
  '파트를 만든 후 참여자 관리에서 소속 파트를 지정하세요.':
      'Create teams, then assign members in Members.',
  '파트 추가 버튼으로 필요한 파트를 만들어 주세요.': 'Use Add team to create the teams you need.',
  '소속 {v0}명': '{v0} members',
  '파트 삭제': 'Delete team',
  '삭제한 파트의 참여자 배정은 해제되며, 기존 작업 내역은 유지됩니다.': 'Deleting a team removes its member assignments. Existing task history is preserved.',
  '파트 이름을 입력하세요.': 'Enter a team name.',
  '파트 수정': 'Edit team',
  '예: 기획, PD, 검토 담당': 'For example: Design, Producer, Reviewer',
  '작업은 누구나 등록하고 수정할 수 있습니다. 잠근 작업은 지정된 담당자만 수정할 수 있습니다.': 'Anyone can create and edit tasks. Locked tasks can only be edited by their assigned person.',
  '저장하지 않은 변경사항': 'Unsaved changes',
  '저장된 파트: {v0}': 'Saved team: {v0}',
  '최신 저장값을 확인했습니다. 초안을 비교한 뒤 다시 저장하세요.':
      'Latest saved values loaded. Compare your draft and save again.',
  '최신 값 확인 · 초안 유지': 'Load latest · Keep draft',
  '저장소 반영 중…': 'Updating repository…',
  '다시 저장': 'Save again',
  '저장소 버전 적용': 'Use repository version',
  '“{v0}”의 내 변경을 백업한 뒤 저장소의 최신 버전을 적용합니다. 이 작업에 제출된 변경 요청은 닫힙니다.': 'Back up your changes to “{v0}” and apply the latest repository version. Submitted pull requests for this task will be closed.',
  '백업 후 적용': 'Back up and apply',
  '내 변경을 백업하고 저장소의 최신 버전을 적용했습니다.': 'Your changes were backed up and the latest repository version was applied.',
  '변경 사항을 확인한 뒤 프로젝트에 반영할 수 있습니다.':
      'Review these changes before applying them to the project.',
  '커밋 {v0}': 'Commit {v0}',
  '통합 승인': 'Approve merge',
  '검토 중 연결 설정이 변경되었습니다. 다시 확인하세요.':
      'Connection settings changed during review. Check them again.',
  '전송 대기': 'Pending upload',
  '전송 중': 'Uploading',
  '전송 완료 · 자동 반영 대기': 'Uploaded · Waiting for auto-merge',
  '전송 완료 · 승인 대기': 'Uploaded · Waiting for approval',
  '프로젝트에 반영됨': 'Applied to project',
  '전송 실패 · 재시도 대기': 'Upload failed · Waiting to retry',
  '저장소 연결': 'Connect repository',
  '동기화 중': 'Syncing',
  '연결됨': 'Connected',
  '동기화 꺼짐': 'Sync disabled',
  '저장소': 'Repository',
  '연결되지 않음': 'Not connected',
  '기준 브랜치': 'Base branch',
  '지금 동기화': 'Sync now',
  '연결 설정': 'Connection settings',
  'GitHub 요청 제한 · {v0} 이후 재시도': 'GitHub rate limit · Retry after {v0}',
  '자동 동기화': 'Automatic sync',
  '저장한 변경을 전송하고 팀의 최신 작업을 가져옵니다.':
      'Upload saved changes and fetch the team\'s latest work.',
  '자동 통합': 'Automatic merge',
  '충돌이 없는 변경 요청을 승인 없이 프로젝트에 반영합니다.':
      'Apply conflict-free pull requests without manual approval.',
  '확인이 필요한 변경': 'Changes needing attention',
  '내 변경: {v0}\n저장소 변경: {v1}': 'Your changes: {v0}\nRepository changes: {v1}',
  '최근 동기화': 'Recent sync activity',
  '{v0}건': '{v0} items',
  '아직 전송한 변경이 없습니다.': 'No changes have been uploaded yet.',
  '이전 전송 내역 {v0}건': '{v0} earlier uploads',
  '승인 대기 중인 변경': 'Changes awaiting approval',
  '변경 확인': 'Review changes',
  'GitHub 저장소 연결': 'Connect GitHub repository',
  '프로젝트 작업을 함께 관리할 GitHub 저장소를 연결합니다.':
      'Connect a GitHub repository to collaborate on project tasks.',
  '고급 설정': 'Advanced settings',
  '작업 브랜치 접두사 (선택)': 'Work branch prefix (optional)',
  'ieum/사용자 이름': 'ieum/username',
  '인증 토큰 (선택)': 'Access token (optional)',
  '비워 두면 저장된 Git 인증 사용': 'Leave blank to use saved Git credentials',
  '토큰은 앱을 종료하면 삭제됩니다. 저장소의 Contents 및 Pull requests 읽기·쓰기 권한이 필요합니다.': 'Tokens are cleared when you close the app. Repository Contents and Pull requests read/write access is required.',
  '연결하면 자동 동기화가 켜집니다. 변경 사항이 충돌하면 내 작업을 보존하고 알려드립니다.': 'Connecting enables automatic sync. If changes conflict, your work is preserved and you will be notified.',
  '연결 중…': 'Connecting…',
  '연결': 'Connections',
  '내 프로젝트': 'My projects',
  '새 프로젝트 만들기': 'Create new project',
  '프로젝트 참여하기': 'Join a project',
  '{v0} · {v1}개 프로젝트': '{v0} · {v1} projects',
  '프로젝트 선택': 'Select project',
  '변경사항을 저장하거나 버릴 수 있습니다. 저장 실패 시 편집 내용이 유지됩니다.':
      'Save or discard your changes. If saving fails, your edits will be kept.',
  '계속 편집': 'Keep editing',
  '변경 버리기': 'Discard changes',
  '댓글': 'Comments',
  '댓글을 입력하세요.': 'Write a comment…',
  '이 작업의 댓글이 최대 개수(100개)에 도달했습니다.':
      'This task has reached the limit of 100 comments.',
  '참여자 · 역할 관리': 'Member and team management',
  '참여 요청을 승인하고 일반 참여자의 파트와 활성 상태를 관리합니다.':
      'Approve join requests and manage member teams and active status.',
  '파트와 역할을 추가·수정·삭제하고 관리 권한을 설정합니다.':
      'Add, edit, and remove teams, and configure management permissions.',
  'Linux 업데이트 다운로드': 'Download Linux update',
  'https://github.com/{v0}/releases/latest 에서 Linux 빌드를 받으세요.':
      'Download the Linux build from https://github.com/{v0}/releases/latest.',
  '{v0} · 다음 실행 때 자동 적용': '{v0} · Installs on next launch',
  '현재 {v0} · 클릭하여 확인': 'Current {v0} · Check for updates',
  '다운로드': 'Download',
  '관리자 작업 회수': 'Recover task',
  '현재 전달을 회수하고 선택한 작업자에게 다시 배정합니다. 작업 내용과 반려 코멘트는 유지됩니다.': 'Recover the current handoff and reassign the task. Task content and comments will be kept.',
  '되돌릴 단계': 'Return to status',
  '처리할 작업자': 'New assignee',
  '회수 후 재배정': 'Recover and reassign',
  '내 작업 알림': 'My task notifications',
  '안 읽음 {v0}개': '{v0} unread',
  '알림 프로젝트 선택': 'Choose notification project',
  '안 읽음': 'Unread',
  '내 멘션': 'Mentions',
  '{v0}개': '{v0} items',
  '최신순': 'Newest first',
  '알림': 'Notifications',
  '알림 새로고침': 'Refresh notifications',
  '상세 내용을 보기 위해 알림을 선택하세요.': 'Select a notification to view its details.',
  '작업 등록': 'Task created',
  '작업 배정': 'Task assigned',
  '검토 요청': 'Review requested',
  '작업 완료': 'Task completed',
  '반려': 'Rejected',
  '작업 알림': 'Task notification',
  '알림 목록으로': 'Back to notifications',
  '알림 상세': 'Notification details',
  '읽음으로 표시': 'Mark as read',
  '알림 상세 닫기': 'Close notification details',
  '작업 열기': 'Open task',
  '시간 미정': 'Time unavailable',
  '읽음': 'Read',
  '로컬': 'Local',
  '알림 내용': 'Notification',
  '작업 정보': 'Task information',
  '작업 ID': 'Task ID',
  '상태': 'Status',
  '검토자': 'Reviewer',
  '아직 도착한 알림이 없습니다.': 'No notifications yet.',
  '조건에 맞는 알림이 없습니다.': 'No notifications match these filters.',
  '@ 내 멘션': '@ Mentioned you',
  '이전 기록': 'Earlier',
  '오늘': 'Today',
  '어제': 'Yesterday',
  '{v0}년 {v1}월 {v2}일': '{v0}-{v1}-{v2}',
  '{v0} · 마감 미정': '{v0} · No due date',
  '프로젝트': 'Project',
  '작업 검색': 'Search tasks',
  '검색어 지우기': 'Clear search',
  '내 일정': 'My schedule',
  '완료 포함': 'Include completed',
  '{v0}개 작업{v1}': '{v0} tasks{v1}',
  ' · 지연 {v0}개': ' · {v0} overdue',
  '이전 달': 'Previous month',
  '{v0}년 {v1}월': '{v0}-{v1}',
  '다음 달': 'Next month',
  '달력': 'Calendar',
  '타임라인': 'Timeline',
  '목록': 'List',
  '월': 'Mon',
  '화': 'Tue',
  '수': 'Wed',
  '목': 'Thu',
  '금': 'Fri',
  '토': 'Sat',
  '일': 'Sun',
  '{v0} 예정 {v1}개': '{v0} · {v1} scheduled',
  '{v0}월 {v1}일 ({v2})': '{v0}/{v1} ({v2})',
  '예정된 작업이 없습니다.': 'No tasks scheduled.',
  '마감 미정 · {v0}': 'No due date · {v0}',
  '마감 미정 작업이 없습니다.': 'No tasks without a due date.',
  '일정 수정': 'Edit schedule',
  '이번 달 일정': 'This month',
  '이번 달에 예정된 작업이 없습니다.': 'No tasks scheduled this month.',
  '마감 미정': 'No due date',
  '작업 · 기간': 'Task · Date range',
  '{v0}마감 미정 {v1}개': '{v0}{v1} tasks without a due date',
  '마감일 설정': 'Set due date',
  '마감일 미정': 'No due date',
  '변경 기록 새로고침': 'Refresh activity',
  '작업·내용·작업자 검색': 'Search tasks, activity, or people',
  '변경 기록 {v0}개': '{v0} activity records',
  '검색 결과 {v0}개 · 전체 {v1}개': '{v0} of {v1} activity records',
  '아직 변경 기록이 없습니다.': 'No activity yet.',
  '작업을 등록하거나 변경하면 여기에 표시됩니다.': 'Task creation and updates will appear here.',
  '다른 검색어를 입력해 보세요.': 'Try another search term.',
  '날짜 없음': 'Date unavailable',
  '상태·담당자 변경': 'Status or assignee changed',
  '프로젝트 활동': 'Project activity',
  '{v0} 이후 다시 시도할 수 있습니다.': 'You can try again after {v0}.',
  '동기화를 완료하지 못했습니다. 연결 설정을 확인해 주세요.':
      'Could not complete sync. Check your connection settings.',
  '저장된 연결 설정을 읽지 못했습니다. 연결 설정을 확인해 주세요.': 'Could not read saved connection settings. Check the connection settings.',
  '동기화 중…': 'Syncing…',
  '연결된 저장소가 없습니다.': 'No repository connected.',
  'GitHub 저장소를 연결하면 팀과 프로젝트 작업을 공유할 수 있습니다.':
      'Connect a GitHub repository to share project work with your team.',
  '동기화 상태': 'Sync status',
  '기기에 저장된 변경': 'Changes saved on this device',
  '반영 대기': 'Waiting to apply',
  '저장소로 전송 완료': 'Uploaded to repository',
  '전송 실패': 'Upload failed',
  '연결 상태 확인 필요': 'Check connection',
  '변경 충돌': 'Conflicting changes',
  '내 변경이 보존됨': 'Your changes are preserved',
  '동기화 확인 필요': 'Sync needs attention',
  '같은 작업에 서로 다른 변경이 있습니다. 연결 설정에서 변경 사항을 비교할 수 있습니다.':
      'This task has conflicting changes. Compare them in connection settings.',
  '프로젝트 참여자': 'Project members',
  '{v0}명 참여 중 · {v1}개 파트': '{v0} members · {v1} teams',
  '참여자 관리': 'Members',
  '재시도 대기': 'Waiting to retry',
  '자동 동기화 켜짐': 'Automatic sync on',
  '자동 동기화 꺼짐': 'Automatic sync off',
  '변경 자동 반영': 'Changes applied automatically',
  '변경 승인 필요': 'Changes require approval',
  '브랜치 · {v0}': 'Branch · {v0}',
  '아직 동기화 기록이 없습니다.': 'No sync activity yet.',
  '최근 업데이트 확인 · {v0}': 'Last checked · {v0}',
  '{v0} 이후 재시도합니다.': 'Retrying after {v0}.',
  '오늘 {v0}': 'Today {v0}',
  '현재 상태': 'Current status',
  '작업 관리': 'Task actions',
  '작업 상세 닫기': 'Close task details',
  '뒤로가기': 'Back',
  '앞으로가기': 'Forward',
  '최소화': 'Minimize',
  '이전 크기로 복원': 'Restore',
  '최대화': 'Maximize',
  '사이드바 접기': 'Collapse sidebar',
  '사이드바 펼치기': 'Expand sidebar',
  '팝업 닫기': 'Close popup',
  '날짜 선택': 'Choose date',
  '{v0}년': '{v0}',
  '{v0}월': '{v0}',
  '날짜 적용': 'Apply date',
  '확인중': 'To do',
  '할 일': 'To do',
  '진행중': 'In progress',
  '진행 중': 'In progress',
  '검토중': 'In review',
  '보류': 'On hold',
  '드랍': 'Dropped',
  '재작업': 'Rework',
  '높음': 'High',
  '보통': 'Normal',
  '낮음': 'Low',
  '미정': 'Not set',
  '기록 없음': 'No record',
  '모든 작업자': 'All members',
  '운영자': 'Manager',
  '작업자': 'Member',
  '열람자': 'Viewer',
  '가입 대기': 'Pending approval',
  '승인 대기': 'Pending approval',
  '이전 역할 정보 없음': 'Previous role unavailable',
  '{v0} 유지': 'Keep {v0}',
  '전달 대상을 선택하세요': 'Select a recipient',
  '자동 업데이트': 'Automatic updates',
  '업데이트 확인 중': 'Checking for updates…',
  '업데이트 다운로드 중': 'Downloading update…',
  '업데이트 후 재시작': 'Restart to update',
  '업데이트 재시도': 'Retry update',
  '배포 버전 없음 · 접근 권한 확인': 'No release available · Check access',
  '업데이트 실행 실패 · 현재 버전 유지': 'Update failed · Keeping current version',
  '업데이트 실행 실패 · 수정 버전 대기': 'Update failed · Waiting for a fixed release',
  '새 버전을 실행하지 못했습니다. 현재 앱을 계속 사용할 수 있습니다.':
      'Could not launch the update. You can keep using the current version.',
  '실행에 실패한 배포본의 반복 적용을 중지했습니다.':
      'Stopped retrying a release that failed to launch.',
  '최신 버전 {v0}': 'Latest version {v0}',
  '작업을 찾을 수 없습니다.': 'Task not found.',
  '작업이 변경되었습니다. 다시 열어 확인하세요.':
      'This task has changed. Reopen it to view the latest version.',
  '작업이 변경되었습니다. 내용을 다시 확인하세요.':
      'This task has changed. Check the latest details.',
  '작업이 변경되었습니다. 다시 확인하세요.': 'This task has changed. Check it again.',
  '작업이 변경되었습니다. 최신 내용을 다시 확인하세요.':
      'This task has changed. Check the latest details.',
  '최신 작업과 잠금 담당자를 확인하세요.': 'Check the latest task version and lock owner.',
  '잠금 담당자와 최신 작업 버전을 확인하세요.': 'Check the lock owner and latest task version.',
  '프로젝트 설정에서 등록된 파트를 선택하세요.': 'Select a team registered in project settings.',
  '전달받을 활성 파트 또는 작업자를 선택하세요.': 'Select an active team or member as recipient.',
  '전달받을 파트 또는 작업자를 선택하세요.': 'Select a team or member as recipient.',
  '관리자만 작업을 회수할 수 있습니다.': 'Only an administrator can recover tasks.',
  '현재 상태에서는 이 동작을 실행할 수 없습니다.':
      'This action is unavailable in the current status.',
  '승인된 작업자 또는 관리자를 담당자로 지정하세요.': 'Assign an approved member or administrator.',
  '이 작업을 보관·복원할 권한이 없습니다.': 'You cannot archive or restore this task.',
  '작업 등록 권한이 필요합니다.': 'Task creation permission is required.',
  '참여자 관리 권한이 필요합니다.': 'Member management permission is required.',
  '읽기 전용 · 참여자 관리 권한이 필요합니다.':
      'Read only · Member management permission is required.',
  '이 참여자의 배정은 변경할 수 없습니다.': 'This member\'s assignment cannot be changed.',
  '작업이나 전환 조건이 변경되었습니다. 최신 내용을 확인하고 다시 진행하세요.': 'The task or transition conditions changed. Check the latest details and try again.',
  'GitHub 인증 응답을 확인하지 못했습니다.':
      'Could not read the GitHub authentication response.',
  '저장소 접근 승인이 필요합니다. GitHub에 다시 로그인하세요.':
      'Repository authorization is required. Sign in to GitHub again.',
  '로그인을 취소했습니다.': 'Sign-in canceled.',
  '로그인 코드가 만료되었습니다. 다시 로그인하세요.': 'The sign-in code expired. Sign in again.',
  'GitHub 인증 통신에 실패했습니다. 인터넷 연결을 확인하세요.': 'Could not connect to GitHub authentication. Check your internet connection.',
  '연결된 프로젝트 정보가 다릅니다.': 'The connected project does not match.',
  '프로젝트 설정에서 작업을 등록할 일반 단계를 먼저 추가하세요.':
      'Add a task status in project settings before creating a task.',
  '비활성': 'Inactive',
  '참여자 관리 권한': 'Manage members',
  '파트 관리 권한': 'Manage teams',
  '멤버 관리': 'Manage members',
  '역할 관리': 'Manage teams',
  '작업내용': 'Task',
  '작업 상태': 'Status',
  '작업 지정일': 'Start date',
  '완료일': 'Completed date',
  '최근 전환 코멘트': 'Latest handoff message',
  '현재 처리 파트': 'Current team',
  '현재 처리 작업자': 'Current assignee',
  '전달 경로': 'Handoff route',
  '처리 목적': 'Request type',
  '직전 전달자': 'Last sender',
  '보관 시각': 'Archived at',
  '삭제 시각': 'Deleted at',
  '잠금 담당자': 'Lock owner',
  '코멘트': 'Comments',
  '상단 고정': 'Pinned',
  '최초 작성자': 'Created by',
  '등록 시각': 'Created at',
  '보류 전 상태': 'Status before hold',
  '전달·검토 기록': 'Handoff and review history',
  ...workspaceEnglish,
};
