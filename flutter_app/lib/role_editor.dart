import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'popup_ui.dart';

Future<ProjectRole?> showProjectRoleDialog(
  BuildContext context,
  Person actor, {
  ProjectRole? role,
}) async {
  final name = TextEditingController(text: role?.name ?? '');
  final permissions = {...?role?.permissions};
  final id = role?.id ?? 'role-${const Uuid().v4()}';
  final result = await showDialog<ProjectRole>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => IeumDialog(
        title: Text(role == null ? '역할 추가' : '역할 수정'),
        icon: Icons.admin_panel_settings_outlined,
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('role-name'),
                controller: name,
                maxLength: 40,
                decoration: const InputDecoration(labelText: '역할 이름'),
              ),
              const SizedBox(height: 12),
              const Text(
                '보유한 권한 안에서 부여할 수 있습니다. 역할 관리 권한을 부여하면 다른 역할도 만들 수 있습니다.',
                style: TextStyle(fontSize: 12),
              ),
              for (final entry in permissionLabels.entries)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  key: Key('permission-${entry.key}'),
                  title: Text(
                    entry.value,
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: permissions.contains(entry.key),
                  onChanged: actor.has(entry.key)
                      ? (value) => update(() {
                          if (value == true) {
                            permissions.add(entry.key);
                          } else {
                            permissions.remove(entry.key);
                          }
                        })
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('save-role'),
            onPressed: () {
              if (name.text.trim().isNotEmpty) {
                Navigator.pop(
                  ctx,
                  ProjectRole(id, name.text.trim(), permissions),
                );
              }
            },
            child: const Text('저장'),
          ),
        ],
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  name.dispose();
  return result;
}
