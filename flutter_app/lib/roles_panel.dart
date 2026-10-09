import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';
import 'github_sync.dart';
import 'project_service.dart';
import 'popup_ui.dart';
import 'role_editor.dart';
import 'permission_ui.dart';
import 'workspace_ui.dart';

class RolesPanel extends StatefulWidget {
  const RolesPanel({
    super.key,
    required this.store,
    required this.sync,
    required this.session,
    this.onMember,
  });
  final ValueChanged<String>? onMember;
  final TaskStore store;
  final GitHubSync sync;
  final GitHubSession session;
  @override
  State<RolesPanel> createState() => _RolesPanelState();
}

class _RolesPanelState extends State<RolesPanel> {
  bool busy = false;
  String message = '', query = '';
  String? selected;
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Person definition(String id) => Person(
    '',
    '',
    '',
    id,
    0,
  ).resolved(widget.store.project!.partWorkflowView.roles);
  List<Person> members(String id) => id == 'owner'
      ? widget.store.people.where((p) => p.role == id).toList()
      : widget.store.project!.partWorkflowView.people
            .where((p) => p.parts.contains(definition(id).roleLabel))
            .toList();
  bool editable(String id) =>
      widget.store.project!.partWorkflowView.roles.any((r) => r.id == id) &&
      widget.store.actor.has('role.manage');
  Future<ProjectManifest?> run(
    Future<ProjectManifest> Function() operation, {
    bool silent = false,
  }) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final project = await operation();
      if (!mounted) return null;
      widget.store.updateProject(project);
      if (!silent) message = tr('변경 사항을 저장했습니다.');
      return project;
    } catch (e) {
      if (mounted) message = '$e';
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> edit([ProjectRole? role]) async {
    if (busy) return;
    final latest = await run(
      () => widget.session.loadProject(widget.sync.config),
      silent: true,
    );
    if (!mounted || latest == null || !widget.store.actor.has('role.manage')) {
      return;
    }
    var current = role == null
        ? null
        : latest.partWorkflowView.roles
              .where((r) => r.id == role.id)
              .firstOrNull;
    if (role != null && current == null) {
      setState(() => message = tr('이 파트가 삭제되었습니다. 목록을 새로고침해 주세요.'));
      return;
    }
    final result = await showProjectRoleDialog(
      context,
      widget.store.actor,
      role: current,
      onReload: current == null
          ? null
          : () async {
              final refreshed = await widget.session.loadProject(
                widget.sync.config,
              );
              if (refreshed.id != latest.id) {
                throw StateError(tr('프로젝트가 변경되었습니다.'));
              }
              final nextRole = refreshed.partWorkflowView.roles
                  .where((r) => r.id == role!.id)
                  .firstOrNull;
              if (nextRole == null) {
                throw StateError(tr('이 파트가 삭제되어 더 이상 수정할 수 없습니다.'));
              }
              current = nextRole;
              if (mounted) widget.store.updateProject(refreshed);
              return nextRole;
            },
      onSave: (draft) async {
        final project = await widget.session.savePermissionPart(
          widget.sync.config,
          draft,
          expectedProjectId: latest.id,
          expectedPart: current,
        );
        if (mounted) widget.store.updateProject(project);
      },
    );
    if (result != null && mounted) {
      setState(() {
        selected = result.id;
        message = tr('변경 사항을 저장했습니다.');
      });
    }
  }

  Future<void> remove(ProjectRole original) async {
    if (busy || !editable(original.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: Text(tr('“{v0}” 파트 삭제', args: {'v0': original.name})),
        content: Text(
          tr(
            '이 파트와 참여자의 파트 배정이 삭제됩니다. 작업 기록은 유지됩니다. 담당 파트가 변경될 작업이 있는지 확인해 주세요.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const Key('confirm-delete-role'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('삭제')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await run(
      () => widget.session.deletePermissionPart(
        widget.sync.config,
        original.id,
        expectedProjectId: widget.store.project!.id,
        expectedPart: original,
      ),
    );
    if (mounted && result != null) setState(() => selected = null);
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.store.project!;
    if (selected != null &&
        !roleLabels.containsKey(selected) &&
        !project.partWorkflowView.roles.any((r) => r.id == selected)) {
      selected = null;
    }
    final id = selected ?? project.partWorkflowView.roles.firstOrNull?.id;
    final filtered = project.partWorkflowView.roles
        .where((r) => r.name.toLowerCase().contains(query))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth >= 480
                    ? constraints.maxWidth -
                          (widget.store.actor.has('role.manage') ? 156 : 48)
                    : constraints.maxWidth,
                height: WorkspaceUi.controlHeight,
                child: TextField(
                  key: const Key('role-search'),
                  controller: search,
                  onChanged: (value) =>
                      setState(() => query = value.trim().toLowerCase()),
                  decoration: InputDecoration(
                    hintText: tr('파트 검색'),
                    prefixIcon: Icon(Icons.search_rounded, size: 18),
                    prefixIconConstraints: BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    isDense: true,
                  ),
                ),
              ),
              if (widget.store.actor.has('role.manage'))
                FilledButton.icon(
                  key: const Key('add-role'),
                  onPressed: busy ? null : () => edit(),
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: Text(tr('파트 추가')),
                ),
              IconButton(
                key: const Key('roles-refresh'),
                tooltip: tr('파트 새로고침'),
                onPressed: busy
                    ? null
                    : () => run(
                        () => widget.session.loadProject(widget.sync.config),
                        silent: true,
                      ),
                icon: const Icon(Icons.refresh_rounded, size: 19),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          tr('파트별로 참여자를 배정하고 참여자·파트 관리 권한을 설정합니다.'),
          style: TextStyle(
            fontSize: 12,
            height: 1.6,
            color: WorkspaceUi.colors(context).muted,
          ),
        ),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: LinearProgressIndicator(),
          ),
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SelectableText(
              message,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final list = roleList(filtered, id);
            final detail = id == null ? emptyDetail() : roleDetail(id);
            if (constraints.maxWidth < 680) {
              return Column(
                key: const Key('roles-stacked'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [list, const SizedBox(height: 16), detail],
              );
            }
            return Row(
              key: const Key('roles-columns'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 228, child: list),
                const SizedBox(width: 20),
                Expanded(child: detail),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget roleList(List<ProjectRole> roles, String? id) => Container(
    key: const Key('role-list'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: WorkspaceUi.colors(context).subtle,
      border: Border.all(color: WorkspaceUi.colors(context).line),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr(
            '파트 · {v0}',
            args: {'v0': widget.store.project!.partWorkflowView.roles.length},
          ),
          style: const TextStyle(fontSize: 11, color: Color(0xff737b76)),
        ),
        const SizedBox(height: 8),
        if (roles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              query.isEmpty ? tr('파트를 추가하면 여기에 표시됩니다.') : tr('검색 결과가 없습니다.'),
              style: const TextStyle(fontSize: 12, height: 1.7),
            ),
          ),
        for (final role in roles) roleRow(role.id, id),
        const Divider(height: 24),
        Material(
          color: Colors.transparent,
          child: ExpansionTile(
            key: const Key('system-roles'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(tr('프로젝트 권한'), style: TextStyle(fontSize: 12)),
            children: [
              for (final system in ['owner']) roleRow(system, id),
            ],
          ),
        ),
      ],
    ),
  );
  Widget roleRow(String id, String? selection) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Material(
      color: selection == id
          ? WorkspaceUi.colors(context).accentSurface
          : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: Key('select-role-$id'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            title: Text(
              trRoleName(id, definition(id).roleLabel),
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              tr('{v0}명 배정', args: {'v0': members(id).length}),
              style: const TextStyle(fontSize: 10),
            ),
            trailing: roleLabels.containsKey(id)
                ? const Icon(Icons.lock_outline, size: 14)
                : const Icon(Icons.chevron_right, size: 16),
            onTap: () => setState(() {
              selected = id;
            }),
          ),
        ],
      ),
    ),
  );
  Widget emptyDetail() => WorkspaceEmptyState(
    icon: Icons.groups_2_outlined,
    title: tr('등록된 파트가 없습니다.'),
    message: tr('파트를 추가해 프로젝트 참여자를 배정할 수 있습니다.'),
    action: OutlinedButton.icon(
      key: const Key('add-first-part'),
      onPressed: busy || !widget.store.actor.has('role.manage')
          ? null
          : () => edit(),
      icon: const Icon(Icons.add_rounded, size: 17),
      label: Text(tr('파트 추가')),
    ),
  );
  Widget roleDetail(String id) {
    final person = definition(id), assigned = members(id);
    final role = widget.store.project!.partWorkflowView.roles
        .where((r) => r.id == id)
        .firstOrNull;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          trRoleName(person.role, person.roleLabel),
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: WorkspaceUi.colors(context).ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          tr(
            '{v0} · {v1}명',
            args: {
              'v0': role == null ? tr('관리자') : tr('파트'),
              'v1': assigned.length,
            },
          ),
          style: WorkspaceUi.captionStyleOf(context),
        ),
      ],
    );
    final actions = role == null
        ? <Widget>[]
        : <Widget>[
            OutlinedButton.icon(
              key: Key('edit-role-$id'),
              onPressed: !busy && editable(id) ? () => edit(role) : null,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text(tr('수정')),
            ),
            TextButton.icon(
              key: Key('delete-role-$id'),
              onPressed: !busy && editable(id) ? () => remove(role) : null,
              style: TextButton.styleFrom(
                foregroundColor: WorkspaceUi.colors(context).danger,
              ),
              icon: const Icon(Icons.delete_outline_rounded, size: 16),
              label: Text(tr('삭제')),
            ),
          ];
    return WorkspacePanel(
      key: const Key('role-detail'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, bounds) {
              if (bounds.maxWidth < 420 && actions.isNotEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: heading),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(width: 16),
                    Wrap(spacing: 8, runSpacing: 8, children: actions),
                  ],
                ],
              );
            },
          ),
          Divider(height: 32, color: WorkspaceUi.colors(context).line),
          if (role == null) ...[
            Text(
              tr(
                '프로젝트·참여자·파트를 관리하고 전달된 작업을 회수할 수 있습니다. 잠긴 작업의 수정 권한은 지정된 담당자에게 있습니다.',
              ),
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: Color(0xff737b76),
              ),
            ),
          ],
          if (role != null && !editable(id))
            Text(
              tr('이 파트를 편집하려면 파트 관리 권한이 필요합니다.'),
              style: TextStyle(fontSize: 11, height: 1.6),
            ),
          const SizedBox(height: 16),
          Text(
            tr('관리 권한'),
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          RolePermissionGroups(
            permissions:
                role?.permissions ?? managementPermissionLabels.keys.toSet(),
          ),
          const SizedBox(height: 16),
          Text(
            tr('배정된 참여자 ({v0})', args: {'v0': assigned.length}),
            key: const Key('role-members-title'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (role != null)
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                tr('파트 배정은 참여자 관리에서 변경할 수 있습니다.'),
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: Color(0xff737b76),
                ),
              ),
            ),
          if (assigned.isEmpty)
            Text(tr('이 파트에 배정된 참여자가 없습니다.'), style: TextStyle(fontSize: 12))
          else
            for (final member in assigned)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline, size: 20),
                onTap: widget.onMember == null
                    ? null
                    : () => widget.onMember!(member.id),
                title: Text(member.name, style: const TextStyle(fontSize: 12)),
                subtitle: Text(
                  tr(
                    '@{v0} · {v1}',
                    args: {
                      'v0': member.login,
                      'v1': member.enabled ? tr('활성화') : tr('비활성화'),
                    },
                  ),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
        ],
      ),
    );
  }
}
