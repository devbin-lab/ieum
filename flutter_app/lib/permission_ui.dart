import 'package:flutter/material.dart';

import 'models.dart';

const permissionGroups = {
  '작업 등록 · 진행': ['task.create', 'task.assign', 'task.work', 'task.editAll'],
  '검토 · 통합': ['task.review', 'task.reviewAll', 'task.integrate'],
  '참여자 · 역할 관리': ['member.manage', 'member.status', 'role.manage'],
};
const permissionDescriptions = {
  'task.create': '새 작업을 등록합니다.',
  'task.assign': '담당자, 검토자, 일정과 우선순위를 배정합니다.',
  'task.work': '범위: 본인 담당 작업. 검토·완료 본문은 수정할 수 없습니다.',
  'task.editAll': '범위: 프로젝트 전체. 검토·완료 본문은 수정할 수 없습니다.',
  'task.review': '본인에게 배정된 검토를 승인하거나 재작업을 요청합니다.',
  'task.reviewAll': '프로젝트의 모든 작업을 검토할 수 있습니다.',
  'task.integrate': '다른 참여자의 작업 변경을 GitHub에 통합합니다.',
  'member.manage': '범위: 이 프로젝트 참여자. 자기 승격·관리자 일반 재배정은 제한됩니다.',
  'member.status': '참여자를 활성화하거나 작업·업로드를 중지합니다.',
  'role.manage': '보유한 권한 안에서 역할을 추가, 수정, 삭제합니다.',
};

class RolePermissionGroups extends StatefulWidget {
  const RolePermissionGroups({
    super.key,
    required this.permissions,
    this.actor,
    this.onChanged,
  });
  final Set<String> permissions;
  final Person? actor;
  final void Function(String, bool)? onChanged;
  @override
  State<RolePermissionGroups> createState() => _RolePermissionGroupsState();
}

class _RolePermissionGroupsState extends State<RolePermissionGroups> {
  String query = '';
  Set<String> get permissions => widget.permissions;
  Person? get actor => widget.actor;
  void Function(String, bool)? get onChanged => widget.onChanged;
  bool matches(String id) =>
      '${permissionLabels[id]} ${permissionDescriptions[id]}'
          .toLowerCase()
          .contains(query.trim().toLowerCase());
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        key: const Key('permission-search'),
        decoration: const InputDecoration(
          hintText: '권한 이름·설명 검색',
          prefixIcon: Icon(Icons.search),
        ),
        onChanged: (value) => setState(() => query = value),
      ),
      const SizedBox(height: 12),
      if (!permissionLabels.keys.any(matches))
        const Text('검색 결과가 없습니다. 검색어를 지워 주세요.'),
      for (final group in permissionGroups.entries)
        if (group.value.any(matches))
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '${group.key}  ·  ${group.value.where(permissions.contains).length}/${group.value.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0xffe1e4e3)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    children: [
                      for (final id in group.value.where(matches)) ...[
                        if (id != group.value.where(matches).first)
                          const Divider(height: 1, indent: 14, endIndent: 14),
                        if (onChanged != null)
                          CheckboxListTile(
                            key: Key('permission-$id'),
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            controlAffinity: ListTileControlAffinity.trailing,
                            title: Text(
                              permissionLabels[id]!,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: Text(
                              permissionDescriptions[id]!,
                              style: const TextStyle(fontSize: 12, height: 1.5),
                            ),
                            value: permissions.contains(id),
                            onChanged: actor?.has(id) == true
                                ? (value) => onChanged!(id, value == true)
                                : null,
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        permissionLabels[id]!,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        permissionDescriptions[id]!,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          height: 1.5,
                                          color: Color(0xff737b76),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Tooltip(
                                  message: permissions.contains(id)
                                      ? '허용'
                                      : '허용하지 않음',
                                  child: Icon(
                                    permissions.contains(id)
                                        ? Icons.check_circle_outline
                                        : Icons.remove_circle_outline,
                                    size: 18,
                                    color: permissions.contains(id)
                                        ? const Color(0xff53856c)
                                        : const Color(0xffb8bebb),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
    ],
  );
}
