import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'models.dart';

const permissionGroups = {
  '참여자 · 역할 관리': ['member.manage', 'role.manage'],
};
const permissionDescriptions = {
  'member.manage': '참여 요청을 승인하고 일반 참여자의 파트와 활성 상태를 관리합니다.',
  'role.manage': '파트와 역할을 추가·수정·삭제하고 관리 권한을 설정합니다.',
};

class RolePermissionGroups extends StatelessWidget {
  const RolePermissionGroups({
    super.key,
    required this.permissions,
    this.actor,
    this.grantable,
    this.onChanged,
  });
  final Set<String> permissions;
  final Person? actor;
  final Set<String>? grantable;
  final void Function(String, bool)? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final entry in managementPermissionLabels.entries)
        if (onChanged != null)
          CheckboxListTile(
            key: Key('permission-${entry.key}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr(entry.value), style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              tr(permissionDescriptions[entry.key]!),
              style: const TextStyle(fontSize: 11, height: 1.5),
            ),
            value: permissions.contains(entry.key),
            onChanged:
                (grantable?.contains(entry.key) ??
                    actor?.has(entry.key) ??
                    false)
                ? (value) => onChanged!(entry.key, value == true)
                : null,
          )
        else
          ListTile(
            key: Key('permission-summary-${entry.key}'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(tr(entry.value), style: const TextStyle(fontSize: 13)),
            trailing: Icon(
              permissions.contains(entry.key)
                  ? Icons.check_circle_outline
                  : Icons.remove_circle_outline,
              size: 18,
              color: permissions.contains(entry.key)
                  ? const Color(0xff53856c)
                  : const Color(0xffb8bebb),
            ),
          ),
    ],
  );
}
