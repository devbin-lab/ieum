import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'popup_ui.dart';
import 'draft_guard.dart';
import 'permission_ui.dart';

Future<ProjectRole?> showProjectRoleDialog(
  BuildContext context,
  Person actor, {
  ProjectRole? role,
  String initialName = '',
  Future<void> Function(ProjectRole)? onSave,
  Future<ProjectRole?> Function()? onReload,
}) async {
  final name = TextEditingController(text: role?.name ?? initialName);
  final id = role?.id ?? 'role-${const Uuid().v4()}';
  var busy = false, saved = false;
  var error = '';
  var base = role;
  final permissions =
      role?.permissions.where(managementPermissionLabels.containsKey).toSet() ??
      <String>{};
  bool dirty() =>
      !saved &&
      (name.text.trim() != (base?.name ?? '') ||
          permissions.length !=
              (base?.permissions
                      .where(managementPermissionLabels.containsKey)
                      .length ??
                  0) ||
          !permissions.containsAll(
            base?.permissions.where(managementPermissionLabels.containsKey) ??
                const <String>[],
          ));
  final result = await showDialog<ProjectRole>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) {
        Future<void> save() async {
          if (busy || name.text.trim().isEmpty) {
            update(() => error = '파트 이름을 입력하세요.');
            return;
          }
          final draft = ProjectRole(id, name.text.trim(), Set.of(permissions));
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
            title: Text(role == null ? '파트 추가' : '파트 수정'),
            icon: Icons.groups_outlined,
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
                    decoration: const InputDecoration(
                      labelText: '파트 이름',
                      hintText: '예: 기획, PD, 검토 담당',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '작업 등록·진행·검토·통합은 기본 허용됩니다. 작업 전달 조건은 자동화 시트에서 설정합니다.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '관리 권한',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  RolePermissionGroups(
                    permissions: permissions,
                    actor: actor,
                    grantable: {
                      for (final id in managementPermissionLabels.keys)
                        if (actor.has(id) ||
                            (base?.permissions.contains(id) ?? false))
                          id,
                    },
                    onChanged: busy
                        ? null
                        : (id, selected) => update(() {
                            if (selected) {
                              permissions.add(id);
                            } else {
                              permissions.remove(id);
                            }
                          }),
                  ),
                  const SizedBox(height: 14),
                  if (dirty()) const Text('저장하지 않은 변경사항'),
                  if (error.isNotEmpty)
                    Text(error, style: const TextStyle(color: Colors.red)),
                  if (base != null) Text('저장된 파트: ${base!.name}'),
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
