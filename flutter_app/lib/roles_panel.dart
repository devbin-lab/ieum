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
  });
  final TaskStore store;
  final GitHubSync sync;
  final GitHubSession session;
  @override
  State<RolesPanel> createState() => _RolesPanelState();
}

class _RolesPanelState extends State<RolesPanel> {
  bool busy = false, showMembers = false;
  String message = '', query = '';
  String? selected;
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Person definition(String id) =>
      Person('', '', '', id, 0).resolved(widget.store.project!.roles);
  List<Person> members(String id) =>
      widget.store.people.where((p) => p.role == id).toList();
  bool editable(String id) =>
      widget.store.project!.roles.any((r) => r.id == id) &&
      widget.store.actor.has('role.manage') &&
      widget.store.actor.permissions.containsAll(definition(id).permissions);
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
    final latest = await run(
      () => widget.session.loadProject(widget.sync.config),
      silent: true,
    );
    if (!mounted || latest == null || !widget.store.actor.has('role.manage')) {
      return;
    }
    final current = role == null
        ? null
        : latest.roles.where((r) => r.id == role.id).firstOrNull;
    if (role != null && current == null) {
      setState(() => message = '삭제된 역할입니다. 목록을 확인하세요.');
      return;
    }
    final result = await showProjectRoleDialog(
      context,
      widget.store.actor,
      role: current,
    );
    if (result != null && mounted) {
      final saved = await run(
        () => widget.session.saveRole(widget.sync.config, result),
      );
      if (saved != null && mounted) {
        setState(() {
          selected = result.id;
          showMembers = false;
        });
      }
    }
  }

  Future<void> remove(ProjectRole original) async {
    final latest = await run(
      () => widget.session.loadProject(widget.sync.config),
      silent: true,
    );
    if (latest == null || !mounted) return;
    final role = latest.roles.where((r) => r.id == original.id).firstOrNull;
    if (role == null || !editable(role.id)) {
      setState(() => message = '역할이 변경되었거나 삭제 권한이 없습니다.');
      return;
    }
    final affected = members(role.id);
    final candidates =
        [
              'worker',
              'viewer',
              if (widget.store.owns) 'manager',
              ...latest.roles.where((r) => r.id != role.id).map((r) => r.id),
            ]
            .where(
              (id) => widget.store.actor.permissions.containsAll(
                definition(id).permissions,
              ),
            )
            .toList();
    String? replacement;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => IeumDialog(
          title: Text('“${role.name}” 역할 삭제'),
          icon: Icons.delete_outline,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                affected.isEmpty
                    ? '이 역할에 배정된 참여자가 없습니다. 삭제 후 목록에서 제거됩니다.'
                    : '${affected.length}명의 참여자가 사용하고 있습니다. 이동할 역할을 선택하면 재배정과 삭제가 함께 적용됩니다.',
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
              if (affected.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  affected
                      .map((p) => '${p.name}${p.enabled ? '' : ' (비활성화)'}')
                      .join(', '),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 16),
                if (widget.store.actor.has('member.manage') &&
                    candidates.isNotEmpty)
                  IeumSelect(
                    key: const Key('delete-role-replacement'),
                    value: replacement ?? '',
                    values: {
                      '': '이동할 역할 선택',
                      for (final id in candidates) id: definition(id).roleLabel,
                    },
                    onChanged: (value) => update(
                      () => replacement = value.isEmpty ? null : value,
                    ),
                  )
                else
                  const Text('참여자를 다른 역할로 옮기려면 참여자 관리 권한이 필요합니다.'),
                const SizedBox(height: 12),
                const Text(
                  '권한이 줄어드는 경우 진행 중인 작업과 통합 대기 PR의 인수인계를 먼저 확인합니다. 참여자의 활성 상태는 유지됩니다.',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: Color(0xff737b76),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('confirm-delete-role'),
              onPressed: affected.isNotEmpty && replacement == null
                  ? null
                  : () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xffb34b51),
              ),
              child: Text(affected.isEmpty ? '삭제' : '재배정 후 삭제'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) {
      final deleted = await run(
        () => widget.session.deleteRole(
          widget.sync.config,
          role.id,
          replacementRoleId: replacement,
        ),
      );
      if (deleted != null && mounted) {
        setState(() {
          selected = null;
          showMembers = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.store.project!;
    if (selected != null &&
        !roleLabels.containsKey(selected) &&
        !project.roles.any((r) => r.id == selected)) {
      selected = null;
    }
    final id = selected ?? project.roles.firstOrNull?.id;
    final filtered = project.roles
        .where((r) => r.name.toLowerCase().contains(query))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '직무 이름과 권한을 직접 정하세요. 역할을 선택하면 허용된 작업과 배정된 참여자를 확인할 수 있습니다.',
          style: TextStyle(fontSize: 12, height: 1.7, color: Color(0xff737b76)),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            if (widget.store.actor.has('role.manage'))
              FilledButton.icon(
                key: const Key('add-role'),
                onPressed: busy ? null : () => edit(),
                icon: const Icon(Icons.add, size: 17),
                label: const Text('역할 추가'),
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
                SizedBox(width: 220, child: list),
                const SizedBox(width: 24),
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
            hintText: '역할 검색',
            prefixIcon: Icon(Icons.search, size: 18),
            isDense: true,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '직접 만든 역할 · ${widget.store.project!.roles.length}',
          style: const TextStyle(fontSize: 11, color: Color(0xff737b76)),
        ),
        const SizedBox(height: 8),
        if (roles.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              query.isEmpty
                  ? '아직 만든 역할이 없습니다. 역할 추가로 직접 만들어 주세요.'
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
              '기존 참여자 · 고정 권한',
              style: TextStyle(fontSize: 10),
            ),
            children: [
              for (final system in ['owner', 'manager', 'worker', 'viewer'])
                roleRow(system, id),
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
      child: ListTile(
        key: Key('select-role-$id'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        title: Text(
          definition(id).roleLabel,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${members(id).length}명 · 권한 ${definition(id).permissions.length}개',
          style: const TextStyle(fontSize: 10),
        ),
        trailing: roleLabels.containsKey(id)
            ? const Icon(Icons.lock_outline, size: 14)
            : const Icon(Icons.chevron_right, size: 16),
        onTap: () => setState(() {
          selected = id;
          showMembers = false;
        }),
      ),
    ),
  );
  Widget emptyDetail() => Container(
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xffe1e4e3)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.badge_outlined, size: 28, color: Color(0xff737b76)),
        SizedBox(height: 14),
        Text(
          '팀에 필요한 역할을 만들어 주세요.',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        SizedBox(height: 8),
        Text(
          'PD, PM, 기획, 아트처럼 원하는 이름으로 직접 만들고 필요한 권한을 선택하세요. 직무 역할을 자동으로 만들거나 참여자를 자동 배정하지 않습니다.',
          style: TextStyle(fontSize: 12, height: 1.7),
        ),
      ],
    ),
  );
  Widget roleDetail(String id) {
    final person = definition(id), assigned = members(id);
    final role = widget.store.project!.roles
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
            '${role == null ? '시스템 권한' : '사용자 지정 역할'} · ${assigned.length}명 배정 · ${person.permissions.length}개 권한',
            style: const TextStyle(fontSize: 11, color: Color(0xff737b76)),
          ),
          const SizedBox(height: 14),
          if (role != null)
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  key: Key('edit-role-$id'),
                  onPressed: !busy && editable(id) ? () => edit(role) : null,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('수정'),
                ),
                TextButton.icon(
                  key: Key('delete-role-$id'),
                  onPressed: !busy && editable(id) ? () => remove(role) : null,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xffb34b51),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('역할 삭제'),
                ),
              ],
            )
          else
            const Text(
              '프로젝트 운영에 사용하는 고정 권한입니다. 직무 역할은 역할 추가에서 직접 만들 수 있습니다.',
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: Color(0xff737b76),
              ),
            ),
          if (role != null && !editable(id))
            const Text(
              '역할 관리 권한과 이 역할에 포함된 권한이 있어야 수정·삭제할 수 있습니다.',
              style: TextStyle(fontSize: 11, height: 1.6),
            ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const Key('role-permissions-tab'),
                label: const Text('권한'),
                selected: !showMembers,
                onSelected: (_) => setState(() => showMembers = false),
              ),
              ChoiceChip(
                key: const Key('role-members-tab'),
                label: Text('참여자 (${assigned.length})'),
                selected: showMembers,
                onSelected: (_) => setState(() => showMembers = true),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (!showMembers) ...[
            RolePermissionGroups(permissions: person.permissions),
            const Text(
              '검토 중인 작업 본문과 완료된 작업은 권한에 관계없이 잠깁니다.',
              style: TextStyle(
                fontSize: 11,
                height: 1.6,
                color: Color(0xff737b76),
              ),
            ),
          ] else if (assigned.isEmpty)
            const Text('이 역할에 배정된 참여자가 없습니다.', style: TextStyle(fontSize: 12))
          else
            for (final member in assigned)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline, size: 20),
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
