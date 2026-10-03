import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'popup_ui.dart';
import 'permission_ui.dart';
import 'draft_guard.dart';

Future<ProjectRole?> showProjectRoleDialog(
  BuildContext context,
  Person actor, {
  ProjectRole? role,
  Future<void> Function(ProjectRole)? onSave,
  Future<ProjectRole?> Function()? onReload,
}) async {
  final name = TextEditingController(text: role?.name ?? '');
  final permissions = {...?role?.permissions};
  final id = role?.id ?? 'role-${const Uuid().v4()}';
  var busy = false, saved = false;
  var error = '';
  var base = role;
  bool dirty() =>
      !saved &&
      (name.text.trim() != (base?.name ?? '') ||
          permissions.length != (base?.permissions.length ?? 0) ||
          !permissions.containsAll(base?.permissions ?? {}));
  final result = await showDialog<ProjectRole>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) {
        Future<void> save() async {
          if (busy || name.text.trim().isEmpty) {
            update(() => error = '역할 이름을 입력하세요.');
            return;
          }
          final draft = ProjectRole(id, name.text.trim(), {...permissions});
          update(() {
            busy = true;
            error = '';
          });
          try {
            if (onSave != null) await onSave(draft);
            if (!ctx.mounted) return;
            update(() {
              saved = true;
              busy = false;
            });
            await WidgetsBinding.instance.endOfFrame;
            if (ctx.mounted) Navigator.pop(ctx, draft);
          } catch (e) {
            if (ctx.mounted) {
              update(() {
                busy = false;
                error = '$e';
              });
            }
          }
        }

        return DraftGuard(
          dirty: dirty(),
          busy: busy,
          onSave: save,
          child: IeumDialog(
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
                    enabled: !busy,
                    onChanged: (_) => update(() {}),
                    decoration: const InputDecoration(labelText: '역할 이름'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '보유한 권한 안에서 부여할 수 있습니다. 역할 관리 권한을 부여하면 다른 역할도 만들 수 있습니다.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  if (dirty()) const Text('저장하지 않은 변경사항'),
                  if (error.isNotEmpty)
                    Text(error, style: const TextStyle(color: Colors.red)),
                  if (base != null)
                    Text(
                      '저장된 역할: ${base!.name} · ${base!.permissions.length}개 권한',
                    ),
                  if (error.isNotEmpty && onReload != null)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              update(() => busy = true);
                              try {
                                final latest = await onReload();
                                if (ctx.mounted) {
                                  update(() {
                                    base = latest;
                                    error =
                                        '최신 저장값을 확인했습니다. 초안을 비교한 뒤 다시 저장하세요.';
                                  });
                                }
                              } catch (e) {
                                if (ctx.mounted) update(() => error = '$e');
                              } finally {
                                if (ctx.mounted) update(() => busy = false);
                              }
                            },
                      child: const Text('최신 값 확인 · 초안 유지'),
                    ),
                  RolePermissionGroups(
                    permissions: permissions,
                    actor: actor,
                    onChanged: busy
                        ? null
                        : (id, value) => update(() {
                            if (value) {
                              permissions.add(id);
                            } else {
                              permissions.remove(id);
                            }
                          }),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.maybePop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const Key('save-role'),
                onPressed: busy || !dirty() ? null : save,
                child: Text(
                  busy
                      ? '저장소 반영 중…'
                      : error.isEmpty
                      ? '저장'
                      : '다시 저장',
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 250));
  name.dispose();
  return result;
}
