import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'models.dart';
import 'store.dart';
import 'github_sync.dart';
import 'project_service.dart';
import 'popup_ui.dart';

class RolesPanel extends StatefulWidget {
  const RolesPanel({
    super.key,
    required this.store,
    required this.sync,
    required this.session,
  });
  final TaskStore store;
  final GitHubSync sync;
  final GitHubSession session;
  @override
  State<RolesPanel> createState() => _RolesPanelState();
}

class _RolesPanelState extends State<RolesPanel> {
  bool busy = false;
  String message = '';
  Future<void> run(Future<ProjectManifest> Function() operation) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final project = await operation();
      widget.store.updateProject(project);
      if (mounted) setState(() => message = 'GitHub에 반영했습니다.');
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit([ProjectRole? role]) async {
    // Refresh before displaying grantable permissions. Service checks again on save.
    await run(() => widget.session.loadProject(widget.sync.config));
    if (!mounted || !widget.store.actor.has('role.manage')) return;
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
                    onChanged: widget.store.actor.has(entry.key)
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
    if (result != null && mounted) {
      await run(() => widget.session.saveRole(widget.sync.config, result));
    }
  }

  Future<void> remove(ProjectRole role) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: const Text('역할 삭제'),
        icon: Icons.delete_outline,
        content: Text('“${role.name}” 역할을 삭제할까요? 사용 중인 역할은 삭제할 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await run(() => widget.session.deleteRole(widget.sync.config, role.id));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          if (widget.store.actor.has('role.manage'))
            FilledButton.icon(
              key: const Key('add-role'),
              onPressed: busy ? null : () => edit(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('역할 추가'),
            ),
          OutlinedButton(
            onPressed: busy
                ? null
                : () =>
                      run(() => widget.session.loadProject(widget.sync.config)),
            child: const Text('새로고침'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      const Text(
        '기본 역할은 유지되며 사용자 지정 역할에 필요한 권한을 조합할 수 있습니다. 검토 중인 본문과 완료된 작업은 권한에 관계없이 잠깁니다.',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
      const SizedBox(height: 16),
      for (final id in ['owner', 'manager', 'worker', 'viewer'])
        roleCard(
          roleLabels[id]!,
          Person('', '', '', id, 0).permissions,
          builtin: true,
        ),
      for (final role in widget.store.project!.roles)
        roleCard(role.name, role.permissions, role: role),
      if (busy) const LinearProgressIndicator(),
      if (message.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: SelectableText(message),
        ),
    ],
  );
  Widget roleCard(
    String name,
    Set<String> permissions, {
    bool builtin = false,
    ProjectRole? role,
  }) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffe5e8e6)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (builtin)
              const Text(
                '기본 역할',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            if (!builtin &&
                widget.store.actor.has('role.manage') &&
                widget.store.actor.permissions.containsAll(permissions)) ...[
              TextButton(
                onPressed: busy ? null : () => edit(role),
                child: const Text('수정'),
              ),
              TextButton(
                onPressed: busy ? null : () => remove(role!),
                child: const Text('삭제'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Text(
          permissions.isEmpty
              ? '목록 조회'
              : permissions.map((p) => permissionLabels[p]).join(' · '),
          style: const TextStyle(fontSize: 12, height: 1.7),
        ),
      ],
    ),
  );
}
