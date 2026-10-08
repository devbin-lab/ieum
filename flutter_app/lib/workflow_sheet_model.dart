/// Persisted stage routing, independent of the editor and project models.
class WorkflowSheetNode {
  const WorkflowSheetNode(this.id, this.stageId, {this.x = 0, this.y = 0});

  final String id, stageId;
  final double x, y;

  Map<String, dynamic> get json => {
    'id': id,
    'stageId': stageId,
    'x': x,
    'y': y,
  };

  factory WorkflowSheetNode.fromJson(Map<String, dynamic> value) {
    final x = value['x'] ?? 0, y = value['y'] ?? 0;
    if (!_validId(value['id']) ||
        !_validId(value['stageId']) ||
        x is! num ||
        y is! num ||
        !x.isFinite ||
        !y.isFinite ||
        x.abs() > 100000 ||
        y.abs() > 100000) {
      throw StateError('자동화 카드의 단계와 위치를 확인하세요.');
    }
    return WorkflowSheetNode(
      value['id'],
      value['stageId'],
      x: x.toDouble(),
      y: y.toDouble(),
    );
  }
}

class WorkflowSheetRoute {
  const WorkflowSheetRoute({
    required this.id,
    required this.from,
    required this.to,
    this.source = '',
    this.destination = '',
    this.person = '',
    this.action = 'advance',
    this.labelDx = 0,
    this.labelDy = 0,
    this.name = '',
    this.operation = '',
    this.assignment = 'target',
    this.commentRequired = false,
    this.requiredFields = const [],
    this.trigger = 'manual',
    this.purpose = '',
    this.requiredPurpose = '',
  });

  final String id, from, to, source, destination, person, action;

  /// Diagram offsets only; these do not change the delivery policy.
  final double labelDx, labelDy;
  final String name, operation, assignment;
  final bool commentRequired;
  final List<String> requiredFields;
  final String trigger;
  final String purpose, requiredPurpose;
  String get effectiveOperation => operation.isEmpty ? action : operation;
  bool get requiresComment => commentRequired || action == 'reject';
  String get buttonName => name.isNotEmpty
      ? name
      : switch (action) {
          'approve' => '승인',
          'reject' => '반려',
          _ => '전달',
        };

  Map<String, dynamic> get json => {
    'id': id,
    'from': from,
    'to': to,
    'source': source,
    'destination': destination,
    'person': person,
    'action': action,
    if (labelDx != 0) 'labelDx': labelDx,
    if (labelDy != 0) 'labelDy': labelDy,
    if (name.isNotEmpty) 'name': name,
    if (operation.isNotEmpty) 'operation': operation,
    if (assignment != 'target') 'assignment': assignment,
    if (commentRequired) 'commentRequired': true,
    if (requiredFields.isNotEmpty) 'requiredFields': requiredFields,
    if (trigger != 'manual') 'trigger': trigger,
    if (purpose.isNotEmpty) 'purpose': purpose,
    if (requiredPurpose.isNotEmpty) 'requiredPurpose': requiredPurpose,
  };

  factory WorkflowSheetRoute.fromJson(Map<String, dynamic> value) {
    final source = value['source'] ?? '';
    final destination = value['destination'] ?? '';
    final person = value['person'] ?? '';
    final action = value['action'] ?? 'advance';
    final labelDx = value['labelDx'] ?? 0;
    final labelDy = value['labelDy'] ?? 0;
    final name = value['name'] ?? '';
    final operation = value['operation'] ?? '';
    final assignment = value['assignment'] ?? 'target';
    final purpose = value['purpose'] ?? '';
    final requiredPurpose = value['requiredPurpose'] ?? '';
    final requiredFields = value['requiredFields'] ?? const [];
    final trigger = value['trigger'] ?? 'manual';
    if (!_validId(value['id']) ||
        !_validId(value['from']) ||
        !_validId(value['to']) ||
        !_validGroup(source) ||
        !_validGroup(destination) ||
        person is! String ||
        person.isNotEmpty && !_validId(person) ||
        !const {'advance', 'approve', 'reject'}.contains(action) ||
        !_validOffset(labelDx) ||
        !_validOffset(labelDy) ||
        name is! String ||
        name.trim().length > 80 ||
        operation is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{0,80}$').hasMatch(operation) ||
        !const {
          'target',
          'keep',
          'assignee',
          'actor',
          'select',
          'sender',
        }.contains(assignment) ||
        !const {'', 'work', 'review', 'revision'}.contains(purpose) ||
        !const {'', 'work', 'review', 'revision'}.contains(requiredPurpose) ||
        !const {'manual', 'onEnter'}.contains(trigger) ||
        value['commentRequired'] != null && value['commentRequired'] is! bool ||
        requiredFields is! List ||
        requiredFields.length > 2 ||
        requiredFields.any(
          (f) => !const {'description', 'dueDate'}.contains(f),
        ) ||
        requiredFields.toSet().length != requiredFields.length) {
      throw StateError('자동화 연결의 파트와 전달 대상을 확인하세요.');
    }
    return WorkflowSheetRoute(
      id: value['id'],
      from: value['from'],
      to: value['to'],
      source: source,
      destination: destination,
      person: person,
      action: action,
      labelDx: (labelDx as num).toDouble(),
      labelDy: (labelDy as num).toDouble(),
      name: name.trim(),
      operation: operation,
      assignment: assignment,
      commentRequired: value['commentRequired'] == true,
      requiredFields: List.unmodifiable(requiredFields.cast<String>()),
      trigger: trigger,
      purpose: purpose,
      requiredPurpose: requiredPurpose,
    );
  }
}

class WorkflowSheet {
  const WorkflowSheet({this.nodes = const [], this.routes = const []});

  final List<WorkflowSheetNode> nodes;
  final List<WorkflowSheetRoute> routes;

  Map<String, dynamic> get json => {
    'schemaVersion': 2,
    'nodes': nodes.map((n) => n.json).toList(),
    'routes': routes.map((r) => r.json).toList(),
  };

  String? stageFor(String nodeId) {
    for (final node in nodes) {
      if (node.id == nodeId) return node.stageId;
    }
    return null;
  }

  List<WorkflowSheetRoute> outgoing(String stageId) =>
      List.unmodifiable(routes.where((r) => stageFor(r.from) == stageId));

  /// Layout and alias-card identity do not affect a prepared task handoff.
  Map<String, dynamic> get policyJson {
    final stageIds = nodes.map((n) => n.stageId).toSet().toList()..sort();
    final ordered = [...routes]..sort((a, b) => a.id.compareTo(b.id));
    return {
      'stages': stageIds,
      'routes': [
        for (final route in ordered)
          {
            'id': route.id,
            'from': stageFor(route.from),
            'to': stageFor(route.to),
            'source': route.source,
            'destination': route.destination,
            'person': route.person,
            'action': route.action,
            if (route.name.isNotEmpty) 'name': route.name,
            if (route.operation.isNotEmpty) 'operation': route.operation,
            if (route.assignment != 'target') 'assignment': route.assignment,
            if (route.commentRequired) 'commentRequired': true,
            if (route.trigger != 'manual') 'trigger': route.trigger,
            if (route.purpose.isNotEmpty) 'purpose': route.purpose,
            if (route.requiredPurpose.isNotEmpty)
              'requiredPurpose': route.requiredPurpose,
            if (route.requiredFields.isNotEmpty)
              'requiredFields': route.requiredFields,
          },
      ],
    };
  }

  factory WorkflowSheet.fromJson(Map<String, dynamic> value) {
    final nodeValues = value['nodes'];
    final routeValues = value['routes'];
    if (!const {1, 2}.contains(value['schemaVersion']) ||
        nodeValues is! List ||
        nodeValues.length > 100 ||
        routeValues is! List ||
        routeValues.length > 300 ||
        nodeValues.any((n) => n is! Map) ||
        routeValues.any((r) => r is! Map)) {
      throw StateError('자동화 시트 형식과 카드·연결 개수를 확인하세요.');
    }
    final nodes = nodeValues
        .map((n) => WorkflowSheetNode.fromJson(Map<String, dynamic>.from(n)))
        .toList();
    final routes = routeValues
        .map((r) => WorkflowSheetRoute.fromJson(Map<String, dynamic>.from(r)))
        .toList();
    final sheet = WorkflowSheet(
      nodes: List.unmodifiable(nodes),
      routes: List.unmodifiable(routes),
    );
    if (nodes.map((n) => n.id).toSet().length != nodes.length ||
        routes.map((r) => r.id).toSet().length != routes.length ||
        routes.any(
          (r) => sheet.stageFor(r.from) == null || sheet.stageFor(r.to) == null,
        )) {
      throw StateError('자동화 카드와 연결 ID가 중복되었거나 연결 단계가 올바르지 않습니다.');
    }
    return sheet;
  }

  factory WorkflowSheet.defaultFor(List<String> stageIds) {
    final ids = stageIds.toSet().toList();
    if (ids.length == 3 && ids.toSet().containsAll({'todo', 'doing', 'done'})) {
      return WorkflowSheet(
        nodes: [
          for (var i = 0; i < ids.length; i++)
            WorkflowSheetNode(ids[i], ids[i], x: (i - 1) * 190),
        ],
        routes: const [
          WorkflowSheetRoute(
            id: 'default-start',
            from: 'todo',
            to: 'doing',
            name: '처리 시작',
            operation: 'start',
            assignment: 'keep',
          ),
          WorkflowSheetRoute(
            id: 'default-handoff',
            from: 'doing',
            to: 'doing',
            name: '담당자에게 전달',
            operation: 'handoff',
            assignment: 'select',
            purpose: 'review',
          ),
          WorkflowSheetRoute(
            id: 'default-finish',
            from: 'doing',
            to: 'done',
            name: '최종 완료',
            operation: 'finish',
            assignment: 'keep',
            action: 'approve',
          ),
          WorkflowSheetRoute(
            id: 'default-return',
            from: 'doing',
            to: 'doing',
            operation: 'return',
            action: 'reject',
            assignment: 'sender',
            purpose: 'revision',
            requiredPurpose: 'review',
          ),
        ],
      );
    }
    final ordinary = ids.where((id) => id != 'review' && id != 'done').toList();
    final routes = <WorkflowSheetRoute>[];
    for (var i = 0; i < ordinary.length; i++) {
      final from = ordinary[i];
      final to = i + 1 < ordinary.length
          ? ordinary[i + 1]
          : ids.contains('review')
          ? 'review'
          : ids.contains('done')
          ? 'done'
          : null;
      if (to == null) continue;
      routes.add(WorkflowSheetRoute(id: 'default-next-$i', from: from, to: to));
    }
    if (ids.contains('review') && ids.contains('done')) {
      routes.add(
        const WorkflowSheetRoute(
          id: 'default-review-approve',
          from: 'review',
          to: 'done',
          action: 'approve',
        ),
      );
    }
    final returnStage = ordinary.contains('todo')
        ? 'todo'
        : ordinary.firstOrNull;
    if (ids.contains('review') && returnStage != null) {
      routes.add(
        WorkflowSheetRoute(
          id: 'default-review-return',
          from: 'review',
          to: returnStage,
          action: 'reject',
        ),
      );
    }
    return WorkflowSheet(
      nodes: [
        for (var i = 0; i < ids.length; i++)
          WorkflowSheetNode(
            ids[i],
            ids[i],
            x: (i - (ids.length - 1) / 2) * 150,
          ),
      ],
      routes: routes,
    );
  }
}

bool _validId(dynamic value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{1,100}$').hasMatch(value);

bool _validOffset(dynamic value) =>
    value is num && value.isFinite && value.abs() <= 100000;

bool _validGroup(dynamic value) =>
    value is String &&
    (value.isEmpty ||
        value == 'role:owner' ||
        value.startsWith('part:') && _validId(value.substring(5)));
