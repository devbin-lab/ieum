const maxProjectShortcuts = 60;

const shortcutServices = {
  'drive': 'Google Drive',
  'notion': 'Notion',
  'jira': 'Jira',
  'discord': 'Discord',
  'kakao': 'KakaoTalk',
  'github': 'GitHub',
  'figma': 'Figma',
  'slack': 'Slack',
  'custom': '직접 입력',
};

/// Shared project bookmarks. Missing or empty lists show no registered links;
/// the service catalog is available separately when adding a shortcut.
class ProjectShortcut {
  const ProjectShortcut({
    required this.id,
    required this.name,
    required this.url,
    this.description = '',
    this.service = 'custom',
    this.iconUrl,
  });

  final String id, name, url, description, service;
  final String? iconUrl;

  String get resolvedService =>
      service == 'custom' ? inferShortcutService(url) : service;

  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    'url': url,
    'description': description,
    'service': service,
    if (iconUrl != null) 'iconUrl': iconUrl,
  };

  factory ProjectShortcut.fromJson(Map<String, dynamic> raw) {
    final name = raw['name'];
    final description = raw['description'] ?? '';
    final service = raw['service'] ?? 'custom';
    if (raw['id'] is! String ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(raw['id']) ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 80 ||
        description is! String ||
        description.length > 160 ||
        !shortcutServices.containsKey(service) ||
        raw['url'] is! String) {
      throw StateError('바로가기 이름과 주소를 확인해 주세요.');
    }
    return ProjectShortcut(
      id: raw['id'],
      name: name.trim(),
      url: normalizeShortcutUrl(raw['url']),
      description: description.trim(),
      service: service,
      iconUrl: _readShortcutIconUrl(raw['iconUrl']),
    );
  }
}

String? _readShortcutIconUrl(Object? value) {
  if (value == null) return null;
  if (value is String) {
    try {
      return normalizeShortcutUrl(value);
    } on StateError {
      // Keep the optional image field's error distinct from the link address.
    }
  }
  throw StateError('올바른 HTTPS 아이콘 주소를 입력해 주세요.');
}

String normalizeShortcutUrl(String input) {
  final value = input.trim();
  if (value.isEmpty ||
      value.length > 2048 ||
      RegExp(r'\s|[\x00-\x1f\x7f]').hasMatch(value)) {
    throw StateError('올바른 HTTPS 주소를 입력해 주세요.');
  }
  final candidate = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(value)
      ? value
      : 'https://$value';
  Uri? uri;
  try {
    uri = Uri.tryParse(candidate);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
      throw const FormatException();
    }
  } on FormatException {
    throw StateError('올바른 HTTPS 주소를 입력해 주세요.');
  }
  return uri.toString();
}

/// Identifies supported services only on their own domains. Invalid input stays
/// a custom link so an unfinished address can be shown while editing.
String inferShortcutService(String url) {
  final uri = _shortcutUri(url);
  if (uri == null) return 'custom';
  final host = uri.host.toLowerCase();
  const domains = {
    'drive': ['drive.google.com', 'docs.google.com', 'doc.google.com'],
    'notion': ['notion.so', 'notion.com', 'notion.site'],
    'jira': ['atlassian.net', 'atlassian.com'],
    'discord': ['discord.com', 'discord.gg'],
    'kakao': ['kakao.com', 'kakaocorp.com'],
    'github': ['github.com'],
    'figma': ['figma.com'],
    'slack': ['slack.com'],
  };
  for (final service in domains.entries) {
    if (service.value.any(
      (domain) => host == domain || host.endsWith('.$domain'),
    )) {
      return service.key;
    }
  }
  return 'custom';
}

/// Starter service pages are distinct from a team's folder, board, or channel.
bool isShortcutServiceHome(ProjectShortcut entry) {
  final uri = _shortcutUri(entry.url);
  if (uri == null) return false;
  final service = entry.resolvedService;
  for (final starter in defaultProjectShortcuts) {
    if (starter.service != service) continue;
    final home = Uri.parse(starter.url);
    if (uri.scheme == home.scheme &&
        uri.host.toLowerCase() == home.host.toLowerCase() &&
        uri.port == home.port &&
        _withoutTrailingSlash(uri.path) == _withoutTrailingSlash(home.path) &&
        uri.query == home.query &&
        uri.fragment == home.fragment) {
      return true;
    }
  }
  return false;
}

Uri? _shortcutUri(String url) {
  try {
    return Uri.parse(normalizeShortcutUrl(url));
  } on StateError {
    return null;
  }
}

String _withoutTrailingSlash(String path) =>
    path.replaceFirst(RegExp(r'/+$'), '');

List<ProjectShortcut>? readProjectShortcuts(Object? value) {
  if (value == null) return null;
  if (value is! List || value.length > maxProjectShortcuts) {
    throw StateError('바로가기는 최대 60개까지 추가할 수 있습니다.');
  }
  final entries = <ProjectShortcut>[];
  for (final raw in value) {
    if (raw is! Map<String, dynamic>) {
      throw StateError('바로가기 이름과 주소를 확인해 주세요.');
    }
    entries.add(ProjectShortcut.fromJson(raw));
  }
  if (entries.map((entry) => entry.id).toSet().length != entries.length) {
    throw StateError('중복된 바로가기 항목을 확인해 주세요.');
  }
  return List.unmodifiable(entries);
}

const defaultProjectShortcuts = [
  ProjectShortcut(
    id: 'starter-drive',
    name: 'Google Drive',
    service: 'drive',
    url: 'https://drive.google.com/',
    description: '공유 파일과 문서',
  ),
  ProjectShortcut(
    id: 'starter-notion',
    name: 'Notion',
    service: 'notion',
    url: 'https://www.notion.com/login',
    description: '팀 문서와 위키',
  ),
  ProjectShortcut(
    id: 'starter-jira',
    name: 'Jira',
    service: 'jira',
    url: 'https://home.atlassian.com/',
    description: '이슈와 프로젝트 보드',
  ),
  ProjectShortcut(
    id: 'starter-discord',
    name: 'Discord',
    service: 'discord',
    url: 'https://discord.com/channels/@me',
    description: '팀 채팅과 음성 회의',
  ),
  ProjectShortcut(
    id: 'starter-kakao',
    name: '카카오톡',
    service: 'kakao',
    url: 'https://www.kakaocorp.com/page/service/service/KakaoTalk',
    description: '팀 채팅과 오픈채팅',
  ),
  ProjectShortcut(
    id: 'starter-github',
    name: 'GitHub',
    service: 'github',
    url: 'https://github.com/',
    description: '코드와 저장소',
  ),
  ProjectShortcut(
    id: 'starter-figma',
    name: 'Figma',
    service: 'figma',
    url: 'https://www.figma.com/',
    description: '디자인과 프로토타입',
  ),
  ProjectShortcut(
    id: 'starter-slack',
    name: 'Slack',
    service: 'slack',
    url: 'https://app.slack.com/client/',
    description: '팀 채널과 메시지',
  ),
];

List<ProjectShortcut> effectiveProjectShortcuts(
  List<ProjectShortcut>? configured, {
  String? repository,
}) => configured ?? const [];
