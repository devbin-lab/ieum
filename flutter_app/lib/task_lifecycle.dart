part of 'models.dart';

const provenanceFields = ['creatorId', 'initialAssigneeId', 'createdAt'];

void validateResourceMutation(
  Person actor,
  WorkTask next,
  WorkTask? current,
  ProjectManifest? project,
) {
  final previous = {
    for (final resource in current?.resources ?? <TaskResource>[])
      resource.id: resource,
  };
  for (final resource in next.resources) {
    final old = previous[resource.id];
    if (old != null) {
      if (jsonEncode(old.json) != jsonEncode(resource.json)) {
        throw StateError('등록한 자료는 교체하지 않고 새 자료로 추가하세요.');
      }
    } else if (resource.authorId != actor.id ||
        !resource.isLink &&
            resource.size >
                (project?.attachmentLimitMb ?? defaultAttachmentLimitMb) *
                    attachmentMegabyte) {
      throw StateError('첨부 자료의 등록자 또는 프로젝트 파일 한도를 확인하세요.');
    }
  }
}

List<Map<String, dynamic>> parseTaskTransitions(String raw) {
  if (raw.length > 320000) throw StateError('전달 기록이 너무 큽니다.');
  dynamic decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    throw StateError('전달 기록 형식을 확인하세요.');
  }
  if (decoded is! List || decoded.length > 100) {
    throw StateError('전달 기록 개수를 확인하세요.');
  }
  final ids = <String>{};
  const keys = {
    'id',
    'from',
    'to',
    'purpose',
    'actorId',
    'recipientId',
    'recipientGroup',
    'version',
    'createdAt',
    'comment',
    'action',
  };
  return List.unmodifiable(
    decoded.map((dynamic entry) {
      if (entry is! Map ||
          entry.keys.toSet().difference(keys).isNotEmpty ||
          entry.length != keys.length ||
          keys.where((k) => k != 'version').any((k) => entry[k] is! String) ||
          !RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(entry['id']) ||
          !ids.add(entry['id']) ||
          !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(entry['actorId']) ||
          entry['recipientId'] != '' &&
              !RegExp(r'^[A-Za-z0-9_-]{1,80}$')
                  .hasMatch(entry['recipientId']) ||
          (entry['recipientGroup'] as String).length > 100 ||
          !const {
            '',
            'work',
            'review',
            'revision',
          }.contains(entry['purpose']) ||
          !(statuses.containsKey(entry['from']) ||
              (entry['from'] as String).startsWith('stage-')) ||
          !(statuses.containsKey(entry['to']) ||
              (entry['to'] as String).startsWith('stage-')) ||
          !directWorkflowRouteIds.contains(entry['action']) ||
          entry['version'] is! int ||
          entry['version'] < 2 ||
          entry['version'] > maxTaskVersion ||
          (entry['comment'] as String).length > 2000 ||
          (entry['createdAt'] as String).length > 40 ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
              .hasMatch(entry['createdAt']) ||
          DateTime.tryParse(entry['createdAt']) == null) {
        throw StateError('전달 기록의 담당자·단계·시각을 확인하세요.');
      }
      return Map<String, dynamic>.unmodifiable(
        Map<String, dynamic>.from(entry),
      );
    }),
  );
}

void validateTaskProvenance(Person actor, WorkTask next, WorkTask? current) {
  if (current != null) {
    if (provenanceFields.any((f) => next.data[f] != current.data[f])) {
      throw StateError('최초 작성자·담당자·등록 시각은 변경할 수 없습니다.');
    }
  } else if (next.creatorId.isNotEmpty &&
          (next.creatorId != actor.id ||
              next.initialAssigneeId != next.assigneeId ||
              next.createdAt.isEmpty) ||
      next.creatorId.isEmpty &&
          (next.initialAssigneeId.isNotEmpty || next.createdAt.isNotEmpty)) {
    throw StateError('최초 작성자와 등록 담당자를 확인하세요.');
  }
}

String appendTaskTransition(
  WorkTask task,
  WorkflowSheetRoute route, {
  required String actorId,
  required String person,
  required String group,
  required String purpose,
  required String at,
  required String comment,
}) {
  final events = [
    ...task.transitionHistory,
    <String, dynamic>{
      'id': '${task.id}-$actorId-${nextTaskVersion(task.version)}',
      'from': task.status,
      'to': route.to,
      'purpose': purpose,
      'actorId': actorId,
      'recipientId': person,
      'recipientGroup': group,
      'version': nextTaskVersion(task.version),
      'createdAt': at,
      'comment': comment.trim(),
      'action': route.id,
    },
  ];
  return jsonEncode(
    events.skip((events.length - 100).clamp(0, events.length)).toList(),
  );
}
