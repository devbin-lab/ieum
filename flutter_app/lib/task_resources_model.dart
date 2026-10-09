import 'dart:convert';

const defaultAttachmentLimitMb = 50;
const maxAttachmentLimitMb = 50;
const attachmentMegabyte = 1024 * 1024;
const maxTaskResources = 30;

bool validResourceUrl(String value) {
  final uri = Uri.tryParse(value);
  return value.length <= 4000 &&
      uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}

class TaskResource {
  TaskResource({
    required this.id,
    required this.name,
    required this.authorId,
    required this.createdAt,
    this.url = '',
    this.size = 0,
    this.sha256 = '',
    this.blobSha = '',
  });
  final String id, name, authorId, createdAt, url, sha256, blobSha;
  final int size;
  bool get isLink => url.isNotEmpty;
  bool get isMarkdown =>
      !isLink &&
      (name.toLowerCase().endsWith('.md') ||
          name.toLowerCase().endsWith('.markdown'));
  String get repositoryPath => '.ieum/files/$sha256';
  Map<String, dynamic> get json => {
    'id': id,
    'name': name,
    'authorId': authorId,
    'createdAt': createdAt,
    'url': url,
    'size': size,
    'sha256': sha256,
    'blobSha': blobSha,
  };

  factory TaskResource.fromJson(Map<String, dynamic> data) {
    const strings = [
      'id',
      'name',
      'authorId',
      'createdAt',
      'url',
      'sha256',
      'blobSha',
    ];
    if (data.length != strings.length + 1 ||
        strings.any((key) => data[key] is! String) ||
        data['size'] is! int ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(data['id']) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(data['authorId']) ||
        (data['name'] as String).trim().isEmpty ||
        (data['name'] as String).length > 240 ||
        (data['url'] == '' &&
            RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(data['name'])) ||
        data['name'] == '.' ||
        data['name'] == '..' ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
            .hasMatch(data['createdAt']) ||
        DateTime.tryParse(data['createdAt']) == null) {
      throw StateError('첨부 자료의 이름과 등록 정보를 확인하세요.');
    }
    final link = (data['url'] as String).isNotEmpty;
    if (link
        ? !validResourceUrl(data['url']) ||
              data['size'] != 0 ||
              data['sha256'] != '' ||
              data['blobSha'] != ''
        : data['size'] < 0 ||
              data['size'] > maxAttachmentLimitMb * attachmentMegabyte ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['sha256']) ||
              !RegExp(r'^[a-f0-9]{40}$').hasMatch(data['blobSha'])) {
      throw StateError('첨부 파일 크기 또는 링크 주소를 확인하세요.');
    }
    return TaskResource(
      id: data['id'],
      name: data['name'],
      authorId: data['authorId'],
      createdAt: data['createdAt'],
      url: data['url'],
      size: data['size'],
      sha256: data['sha256'],
      blobSha: data['blobSha'],
    );
  }
}

List<TaskResource> parseTaskResources(String source) {
  if (source.length > 160000) throw StateError('첨부 자료 목록이 너무 큽니다.');
  dynamic raw;
  try {
    raw = jsonDecode(source);
  } catch (_) {
    throw StateError('첨부 자료 목록을 읽을 수 없습니다.');
  }
  if (raw is! List || raw.length > maxTaskResources) {
    throw StateError('작업에는 자료를 최대 30개까지 첨부할 수 있습니다.');
  }
  final items = raw.map((item) {
    if (item is! Map) throw StateError('첨부 자료 형식이 올바르지 않습니다.');
    return TaskResource.fromJson(Map<String, dynamic>.from(item));
  }).toList();
  if (items.map((item) => item.id).toSet().length != items.length) {
    throw StateError('첨부 자료 ID가 중복됩니다.');
  }
  return List.unmodifiable(items);
}
