import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';
import 'github_sync.dart';
import 'project_service.dart';
import 'popup_ui.dart';
import 'role_editor.dart';
import 'permission_ui.dart';

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
      if (!silent) message = '저장소에 반영했습니다.';
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
      setState(() => message = '삭제된 파트입니다. 목록을 확인하세요.');
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
              if (refreshed.id != latest.id) throw StateError('프로젝트가 변경되었습니다.');
              final nextRole = refreshed.partWorkflowView.roles
                  .where((r) => r.id == role!.id)
                  .firstOrNull;
              if (nextRole == null) {
                throw StateError('파트가 삭제되었습니다. 초안을 다른 이름으로 보관하거나 편집을 종료하세요.');
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
        message = '저장소에 반영했습니다.';
      });
    }
  }

  Future<void> remove(ProjectRole original) async {
    if (busy || !editable(original.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: Text('“${original.name}” 파트 삭제'),
        content: const Text(
          '파트와 참여자의 해당 파트 배정을 삭제합니다. 이 파트를 사용하는 자동화 연결이나 진행 중인 업무가 있으면 먼저 수정하거나 인수인계하세요. 기존 작업 내역은 유지됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('confirm-delete-role'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
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
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (widget.store.actor.has('role.manage'))
              FilledButton.icon(
                key: const Key('add-role'),
                onPressed: busy ? null : () => edit(),
                icon: const Icon(Icons.add, size: 17),
                label: const Text('파트 추가'),
              ),
            OutlinedButton.icon(
              key: const Key('roles-refresh'),
              onPressed: busy
                  ? null
                  : () => run(
                      () => widget.session.loadProject(widget.sync.config),
                      silent: true,
                    ),
              icon: const Icon(Icons.refresh, size: 17),
              label: const Text('새로고침'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Text(
          '파트별로 참여자·역할 관리 권한을 설정합니다. 작업 등록·진행·검토·통합은 기본 허용됩니다.',
          style: TextStyle(fontSize: 12, height: 1.7, color: Color(0xff737b76)),
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
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final list = roleList(filtered, id);
            final detail = id == null ? emptyDetail() : roleDetail(id);
            if (constraints.maxWidth < 680) {
              return Column(
                key: const Key('roles-stacked'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [list, const SizedBox(height: 20), detail],
              );
            }
            return Row(
              key: const Key('roles-columns'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 240, child: list),
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
      color: const Color(0xfff8f9f8),
      border: Border.all(color: const Color(0xffe1e4e3)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const Key('role-search'),
          controller: search,
          onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
          decoration: const InputDecoration(
            hintText: '파트 검색',
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '파트 · ${widget.store.project!.partWorkflowView.roles.length}',
          style: const TextStyle(fontSize: 11, color: Color(0xff737b76)),
        ),
        const SizedBox(height: 8),
        if (roles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              query.isEmpty
                  ? '아직 만든 파트가 없습니다. 파트 추가로 직접 만들어 주세요.'
                  : '검색 결과가 없습니다.',
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
            title: const Text('시스템 권한', style: TextStyle(fontSize: 12)),
            subtitle: const Text(
              '관리자 · 프로젝트 관리',
              style: TextStyle(fontSize: 10),
            ),
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
      color: selection == id ? const Color(0xffe9eeeb) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: Key('select-role-$id'),
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
            title: Text(
              definition(id).roleLabel,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${members(id).length}명 배정',
              style: const TextStyle(fontSize: 10),
            ),
            trailing: roleLabels.containsKey(id)
                ? const Icon(Icons.lock_outline, size: 14)
                : const Icon(Icons.chevron_right, size: 16),
            onTap: () => setState(() {
              selected = id;
            }),
          ),
          if (!roleLabels.containsKey(id))
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
              child: Wrap(
                spacing: 4,
                children: [
                  TextButton.icon(
                    key: Key('edit-role-$id'),
                    onPressed: !busy && editable(id)
                        ? () => edit(
                            widget.store.project!.partWorkflowView.roles
                                .firstWhere((r) => r.id == id),
                          )
                        : null,
                    icon: const Icon(Icons.edit_outlined, size: 15),
                    label: const Text('수정'),
                  ),
                  TextButton.icon(
                    key: Key('delete-role-$id'),
                    onPressed: !busy && editable(id)
                        ? () => remove(
                            widget.store.project!.partWorkflowView.roles
                                .firstWhere((r) => r.id == id),
                          )
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xffb34b51),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 15),
                    label: const Text('삭제'),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
  Widget emptyDetail() => Container(
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffe1e4e3)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.badge_outlined, size: 28, color: Color(0xff737b76)),
        SizedBox(height: 14),
        Text(
          '첫 파트를 추가해 주세요.',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text(
          '기획, PD처럼 소속 파트를 만든 뒤 참여자에게 배정하세요.',
          style: TextStyle(fontSize: 12, height: 1.7),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('add-first-part'),
          onPressed: busy || !widget.store.actor.has('role.manage')
              ? null
              : () => edit(),
          icon: const Icon(Icons.add_rounded, size: 17),
          label: const Text('파트 추가'),
        ),
      ],
    ),
  );
  Widget roleDetail(String id) {
    final person = definition(id), assigned = members(id);
    final role = widget.store.project!.partWorkflowView.roles
        .where((r) => r.id == id)
        .firstOrNull;
    return Container(
      key: const Key('role-detail'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xffe1e4e3)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            person.roleLabel,
            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '${role == null ? '시스템 권한' : '파트'} · ${assigned.length}명 배정',
            style: const TextStyle(fontSize: 11, color: Color(0xff737b76)),
          ),
          const SizedBox(height: 14),
          if (role == null) ...[
            const Text(
              '프로젝트, 참여자, 파트, 작업 단계 자동화를 관리하고 잘못 전달된 작업을 회수합니다. 관리자 이전은 참여자 관리에서 할 수 있습니다.',
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: Color(0xff737b76),
              ),
            ),
          ],
          if (role != null && !editable(id))
            const Text(
              '파트 추가·수정·삭제는 역할 관리 권한이 필요합니다.',
              style: TextStyle(fontSize: 11, height: 1.6),
            ),
          const SizedBox(height: 16),
          const Text(
            '관리 권한',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          RolePermissionGroups(
            permissions:
                role?.permissions ?? managementPermissionLabels.keys.toSet(),
          ),
          const SizedBox(height: 16),
          Text(
            '배정된 참여자 (${assigned.length})',
            key: const Key('role-members-title'),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          if (role != null)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                '이 파트를 조건으로 사용할 작업 단계 연결은 자동화 시트에서 설정합니다.',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: Color(0xff737b76),
                ),
              ),
            ),
          if (assigned.isEmpty)
            const Text('이 파트에 배정된 참여자가 없습니다.', style: TextStyle(fontSize: 12))
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
                  '@${member.login} · ${member.enabled ? '활성화' : '비활성화'}',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
        ],
      ),
    );
  }
}
