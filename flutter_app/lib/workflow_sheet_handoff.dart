import 'dart:convert';

import 'package:flutter/material.dart';

import 'models.dart';

/// Editor fields for one persisted delivery route.
class SheetHandoffRule {
  const SheetHandoffRule({
    this.id = '',
    this.source = '',
    this.destination = '',
    this.person = '',
    this.action = 'advance',
    this.name = '',
    this.operation = '',
    this.assignment = 'target',
    this.purpose = '',
    this.requiredPurpose = '',
    this.commentRequired = false,
    this.requiredFields = const [],
    this.trigger = 'manual',
    this.labelDx = 0,
    this.labelDy = 0,
  });
  final String id,
      source,
      destination,
      person,
      action,
      name,
      operation,
      assignment,
      purpose,
      requiredPurpose;
  final bool commentRequired;
  final List<String> requiredFields;
  final String trigger;
  bool get requiresComment => commentRequired || action == 'reject';
  final double labelDx, labelDy;
  SheetHandoffRule withLabelOffset(Offset offset) => SheetHandoffRule(
    id: id,
    source: source,
    destination: destination,
    person: person,
    action: action,
    name: name,
    operation: operation,
    assignment: assignment,
    purpose: purpose,
    requiredPurpose: requiredPurpose,
    commentRequired: commentRequired,
    requiredFields: requiredFields,
    trigger: trigger,
    labelDx: offset.dx,
    labelDy: offset.dy,
  );
  String get signature {
    final required = [...requiredFields]..sort();
    return jsonEncode([
      operation.isEmpty ? action : operation,
      name.trim(),
      source,
      destination,
      person,
      assignment,
      purpose,
      requiredPurpose,
      requiresComment,
      required,
      trigger,
    ]);
  }
}

Map<String, String> sheetHandoffGroups(
  List<ProjectRole> roles,
  List<String> parts,
) => {
  '': '모든 작업자',
  for (final role in roles)
    if (parts.contains(role.name)) 'part:${role.id}': '파트 · ${role.name}',
  'role:owner': '관리자',
};

bool sheetGroupContains(
  String group,
  Person person, [
  List<ProjectRole> roles = const [],
]) {
  if (group.isEmpty) return true;
  if (group == 'role:owner') return person.role == 'owner';
  if (!group.startsWith('part:')) return false;
  final part = roles.where((r) => r.id == group.substring(5)).firstOrNull;
  return part != null && person.parts.contains(part.name);
}

String sheetHandoffLabel(
  SheetHandoffRule rule,
  List<ProjectRole> roles,
  List<Person> people,
  List<String> parts,
) {
  final groups = sheetHandoffGroups(roles, parts);
  final sourceGroup = groups[rule.source] ?? '삭제된 파트';
  final source = rule.requiredPurpose.isEmpty
      ? sourceGroup
      : '$sourceGroup · ${workflowPurposeLabels[rule.requiredPurpose]} 처리 중';
  final destination = switch (rule.assignment) {
    'select' =>
      rule.destination.isEmpty
          ? '전달할 때 담당자 선택'
          : '${groups[rule.destination] ?? '삭제된 파트'} · 전달할 때 선택',
    'keep' => '현재 처리 담당자 유지',
    'sender' => '직전 전달자에게 반환',
    'assignee' => '작업 담당자',
    'actor' => '전환 실행자',
    _ =>
      rule.person.isEmpty
          ? rule.destination.isEmpty
                ? '모든 작업자'
                : '${groups[rule.destination] ?? '삭제된 파트'} 전체'
          : people
                    .where((p) => p.id == rule.person && p.active)
                    .firstOrNull
                    ?.name ??
                '참여 불가 작업자',
  };
  final action = switch (rule.action) {
    'approve' => '승인 · ',
    'reject' => '반려 · ',
    _ => '',
  };
  final automatic = rule.trigger == 'onEnter' ? '자동 · ' : '';
  final delivery = rule.purpose.isEmpty
      ? destination
      : '$destination · ${workflowPurposeLabels[rule.purpose]}';
  return rule.name.trim().isNotEmpty
      ? '$automatic${rule.name.trim()}\n$source → $delivery'
      : '$automatic$action$source → $delivery';
}

Future<List<SheetHandoffRule>?> editSheetHandoff(
  BuildContext context, {
  required String from,
  required String to,
  required List<SheetHandoffRule> routes,
  required List<ProjectRole> roles,
  required List<Person> people,
  required List<String> parts,
  String fromStage = '',
  String toStage = '',
  String toCategory = '',
  int initialIndex = 0,
}) async {
  final groups = sheetHandoffGroups(roles, parts);
  final defaultAction = toCategory == 'done' || toStage == 'done'
      ? 'approve'
      : fromStage == 'review'
      ? 'reject'
      : 'advance';
  final workers = people.where((p) => p.active).toList();
  final drafts = [...routes];
  var index = initialIndex.clamp(0, drafts.length);
  if (index == drafts.length) {
    drafts.add(SheetHandoffRule(action: defaultAction));
  }
  bool valid(SheetHandoffRule rule) =>
      groups.containsKey(rule.source) &&
      rule.name.trim().length <= 80 &&
      (!(const {'target', 'select'}.contains(rule.assignment)) ||
          groups.containsKey(rule.destination)) &&
      (rule.assignment != 'target' ||
          rule.person.isEmpty ||
          workers.any(
            (p) =>
                p.id == rule.person &&
                sheetGroupContains(rule.destination, p, roles),
          ));
  void change({
    String? source,
    String? destination,
    String? person,
    String? name,
    String? action,
    String? assignment,
    String? purpose,
    String? requiredPurpose,
    bool? commentRequired,
    List<String>? requiredFields,
    String? trigger,
  }) {
    final old = drafts[index];
    drafts[index] = SheetHandoffRule(
      id: old.id,
      source: source ?? old.source,
      destination: destination ?? old.destination,
      person: person ?? old.person,
      action: action ?? old.action,
      name: name ?? old.name,
      operation: old.operation,
      assignment: assignment ?? old.assignment,
      purpose: purpose ?? old.purpose,
      requiredPurpose: requiredPurpose ?? old.requiredPurpose,
      commentRequired: commentRequired ?? old.commentRequired,
      requiredFields: requiredFields ?? old.requiredFields,
      trigger: trigger ?? old.trigger,
      labelDx: old.labelDx,
      labelDy: old.labelDy,
    );
  }

  return showDialog<List<SheetHandoffRule>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) {
        final source = drafts[index].source;
        final destination = drafts[index].destination;
        final person = drafts[index].person;
        final rule = drafts[index];
        final duplicate =
            drafts.map((r) => r.signature).toSet().length != drafts.length;
        final eligible = workers
            .where((p) => sheetGroupContains(destination, p, roles))
            .toList();
        final personValid =
            person.isEmpty || eligible.any((p) => p.id == person);
        Widget groupField(
          String label,
          String key,
          String value,
          ValueChanged<String> change,
        ) => DropdownButtonFormField<String>(
          key: ValueKey('$key-$index-$value'),
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          items: [
            if (!groups.containsKey(value))
              DropdownMenuItem(
                value: value,
                enabled: false,
                child: const Text('삭제된 파트 · 다시 선택하세요.'),
              ),
            for (final entry in groups.entries)
              DropdownMenuItem(
                value: entry.key,
                child: Text(entry.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) {
            if (value != null) update(() => change(value));
          },
        );
        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            '전환 · $from → $to',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '전환 경로',
                    style: TextStyle(color: Color(0xff7f8da1), fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '추가로 선택할 전달 흐름입니다. 일치하는 파트 경로가 전체 경로보다 우선하며, 기본 담당자 전달과 공동 편집은 계속 사용할 수 있습니다.',
                    style: TextStyle(color: Color(0xff64748b), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  for (var i = 0; i < drafts.length; i++)
                    ListTile(
                      key: Key('workflow-route-option-$i'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      selected: index == i,
                      selectedTileColor: const Color(0xffeff3f8),
                      leading: const Icon(Icons.alt_route_rounded, size: 18),
                      title: Text(
                        sheetHandoffLabel(drafts[i], roles, people, parts),
                        style: const TextStyle(fontSize: 12),
                      ),
                      onTap: () => update(() => index = i),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('workflow-route-add'),
                      onPressed: () => update(() {
                        index = drafts.length;
                        drafts.add(SheetHandoffRule(action: defaultAction));
                      }),
                      icon: const Icon(Icons.add_rounded, size: 16),
                      label: const Text('경로 추가'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    key: ValueKey('workflow-route-name-$index'),
                    initialValue: rule.name,
                    maxLength: 80,
                    decoration: const InputDecoration(
                      labelText: '전환 버튼 이름',
                      hintText: '예: QA 검토 요청, PD에게 전달',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => update(() => change(name: value)),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('workflow-route-action-$index'),
                    initialValue: rule.action,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '동작',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'advance', child: Text('전달')),
                      DropdownMenuItem(value: 'approve', child: Text('승인')),
                      DropdownMenuItem(value: 'reject', child: Text('반려')),
                    ],
                    onChanged: (value) {
                      if (value != null) update(() => change(action: value));
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('workflow-route-purpose-$index'),
                    initialValue: rule.purpose,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '전달 후 처리 목적',
                      helperText: '검토와 수정 요청은 담당자에게 전달하는 동작입니다.',
                      helperMaxLines: 2,
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('현재 목적 유지')),
                      DropdownMenuItem(value: 'work', child: Text('작성')),
                      DropdownMenuItem(value: 'review', child: Text('검토')),
                      DropdownMenuItem(value: 'revision', child: Text('수정')),
                    ],
                    onChanged: (value) {
                      if (value != null) update(() => change(purpose: value));
                    },
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    '실행 조건',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xff46546a),
                    ),
                  ),
                  const SizedBox(height: 12),
                  groupField(
                    '전달하는 파트',
                    'workflow-route-source',
                    source,
                    (v) => change(source: v),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('workflow-route-required-purpose-$index'),
                    initialValue: rule.requiredPurpose,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '현재 처리 목적 조건',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('제한 없음')),
                      DropdownMenuItem(value: 'work', child: Text('작성 중일 때')),
                      DropdownMenuItem(value: 'review', child: Text('검토 중일 때')),
                      DropdownMenuItem(
                        value: 'revision',
                        child: Text('수정 중일 때'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        update(() => change(requiredPurpose: value));
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('workflow-route-assignment-$index'),
                    initialValue: rule.assignment,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '전환 후 처리 담당자',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'select',
                        child: Text('전달할 때 파트·담당자 선택'),
                      ),
                      DropdownMenuItem(
                        value: 'target',
                        child: Text('받는 파트·작업자 지정'),
                      ),
                      DropdownMenuItem(
                        value: 'keep',
                        child: Text('현재 처리 담당자 유지'),
                      ),
                      DropdownMenuItem(
                        value: 'assignee',
                        child: Text('등록 담당자에게 반환'),
                      ),
                      DropdownMenuItem(
                        value: 'sender',
                        child: Text('직전 전달자에게 반환'),
                      ),
                      DropdownMenuItem(
                        value: 'actor',
                        child: Text('전환 실행자에게 배정'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        update(
                          () => change(
                            assignment: value,
                            destination:
                                const {'target', 'select'}.contains(value)
                                ? null
                                : '',
                            person: value == 'target' ? null : '',
                          ),
                        );
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  if (const {'target', 'select'}.contains(rule.assignment)) ...[
                    groupField(
                      rule.assignment == 'select' ? '선택 가능한 파트' : '받는 파트',
                      'workflow-route-destination',
                      destination,
                      (v) {
                        change(destination: v, person: '');
                      },
                    ),
                    if (rule.assignment == 'select')
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '전달 버튼을 누르면 이 범위에서 파트와 담당자를 선택합니다. 모든 작업자를 선택하면 전체 파트에서 고를 수 있습니다.',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xff64748b),
                          ),
                        ),
                      ),
                  ],
                  if (rule.assignment == 'target') ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'workflow-route-person-$index-$destination-$person',
                      ),
                      initialValue: personValid ? person : '',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '받는 작업자',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(
                            destination.isEmpty ? '모든 작업자' : '선택한 파트 전체',
                          ),
                        ),
                        for (final p in eligible)
                          DropdownMenuItem(value: p.id, child: Text(p.name)),
                      ],
                      onChanged: (v) {
                        if (v != null) update(() => change(person: v));
                      },
                    ),
                    if (!personValid)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          '기존 작업자가 이 그룹에 없습니다. 받을 작업자를 다시 선택하세요.',
                          style: TextStyle(
                            color: Color(0xffb86a72),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                  if (!groups.containsKey(source) ||
                      const {'target', 'select'}.contains(rule.assignment) &&
                          !groups.containsKey(destination))
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '삭제된 파트를 다시 선택해야 이 경로를 사용할 수 있습니다.',
                        style: TextStyle(
                          color: Color(0xffb86a72),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  const Divider(height: 24),
                  SwitchListTile.adaptive(
                    key: const Key('workflow-route-auto'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '상태에 들어오면 자동 전달',
                      style: TextStyle(fontSize: 12),
                    ),
                    subtitle: const Text(
                      '이 앱에서 작업을 등록하거나 상태를 바꿀 때 실행합니다. 조건이 하나로 정해지고 필수 입력이 채워져야 합니다.',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: rule.trigger == 'onEnter',
                    onChanged: (value) => update(
                      () => change(trigger: value ? 'onEnter' : 'manual'),
                    ),
                  ),
                  if (rule.trigger == 'onEnter' && rule.requiresComment)
                    const Text(
                      '코멘트가 필요한 경로는 수동 확인을 기다립니다.',
                      style: TextStyle(fontSize: 11, color: Color(0xffa16b37)),
                    ),
                  if (rule.trigger == 'onEnter' && rule.assignment == 'select')
                    const Text(
                      '받는 담당자를 전달할 때 선택하는 경로는 수동 확인을 기다립니다.',
                      style: TextStyle(fontSize: 11, color: Color(0xffa16b37)),
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    '전환 전 필수 입력',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xff46546a),
                    ),
                  ),
                  CheckboxListTile(
                    key: const Key('workflow-route-required-comment'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('코멘트', style: TextStyle(fontSize: 12)),
                    subtitle: rule.action == 'reject'
                        ? const Text(
                            '반려할 때는 코멘트가 항상 필요합니다.',
                            style: TextStyle(fontSize: 11),
                          )
                        : null,
                    value: rule.requiresComment,
                    onChanged: rule.action == 'reject'
                        ? null
                        : (value) =>
                              update(() => change(commentRequired: value!)),
                  ),
                  for (final field in const {
                    'description': '작업 설명',
                    'dueDate': '마감일',
                  }.entries)
                    CheckboxListTile(
                      key: Key('workflow-route-required-${field.key}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        field.value,
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: rule.requiredFields.contains(field.key),
                      onChanged: (value) => update(
                        () => change(
                          requiredFields: [
                            ...drafts[index].requiredFields.where(
                              (entry) => entry != field.key,
                            ),
                            if (value == true) field.key,
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (duplicate)
                    const Text(
                      '같은 전달 조건이 중복되어 있습니다. 경로를 수정하거나 삭제하세요.',
                      key: Key('workflow-route-duplicate'),
                      style: TextStyle(color: Color(0xffb86a72), fontSize: 12),
                    ),
                  if (drafts.any((r) => !valid(r)))
                    const Text(
                      '모든 경로의 파트와 작업자를 확인하세요.',
                      style: TextStyle(color: Color(0xffb86a72), fontSize: 12),
                    ),
                  Text(
                    sheetHandoffLabel(rule, roles, people, parts),
                    key: const Key('workflow-route-preview'),
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xff64748b),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (drafts.isNotEmpty)
              TextButton(
                key: const Key('workflow-route-delete'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xffb86a72),
                ),
                onPressed: () =>
                    Navigator.pop(ctx, [...drafts]..removeAt(index)),
                child: const Text('경로 삭제'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('workflow-route-save'),
              onPressed: duplicate || drafts.any((r) => !valid(r))
                  ? null
                  : () {
                      Navigator.pop(ctx, [...drafts]);
                    },
              child: const Text('적용'),
            ),
          ],
        );
      },
    ),
  );
}
