import 'dart:async';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'models.dart';
import 'popup_ui.dart';
import 'project_service.dart';
import 'store.dart';
import 'role_editor.dart';

class TeamPanel extends StatefulWidget {
  const TeamPanel({
    super.key,
    required this.store,
    required this.sync,
    required this.session,
  });
  final TaskStore store;
  final GitHubSync sync;
  final GitHubSession session;
  @override
  State<TeamPanel> createState() => _TeamPanelState();
}

class _TeamPanelState extends State<TeamPanel> {
  List<Map<String, dynamic>> requests = [];
  bool busy = false;
  String error = '';
  Timer? timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(refresh());
    });
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !busy) unawaited(refresh());
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> invite() async {
    final controller = TextEditingController();
    final login = await showDialog<String>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: const Text('GitHub 협업자 초대'),
        icon: Icons.person_add_outlined,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: '팀원의 GitHub 계정 이름'),
            ),
            const SizedBox(height: 16),
            const Text(
              '저장소 쓰기 권한 초대를 보냅니다. 팀원이 GitHub에서 초대를 수락한 후 이음에서 가입 요청을 할 수 있습니다.',
              style: TextStyle(fontSize: 12, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('초대 보내기'),
          ),
        ],
      ),
    );
    // The dialog field remains mounted during its dismissal animation.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (login == null || !mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.session.invite(widget.sync.config, login);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('GitHub 협업자 초대를 보냈습니다. 팀원이 초대를 수락해야 합니다.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> transfer() async {
    final candidates = widget.store.people
        .where(
          (p) => p.id != widget.store.project!.ownerId && p.active && p.canWork,
        )
        .toList();
    if (candidates.isEmpty) {
      setState(() => error = '소유권을 받을 작업자 또는 관리자를 먼저 승인하세요.');
      return;
    }
    var target = candidates.first.id;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => IeumDialog(
          title: const Text('프로젝트 소유권 이전'),
          icon: Icons.manage_accounts_outlined,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IeumSelect(
                value: target,
                values: {
                  for (final p in candidates) p.id: '${p.name} · @${p.login}',
                },
                onChanged: (value) => update(() => target = value),
              ),
              const SizedBox(height: 16),
              const Text(
                '선택한 참여자가 이음 프로젝트의 개설자가 됩니다. 내 역할은 관리자으로 변경됩니다. GitHub 저장소의 소유자와 초대 권한은 별도로 관리됩니다.',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, target),
              child: const Text('소유권 이전'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final project = await widget.session.transferOwnership(
        widget.sync.config,
        selected,
      );
      if (mounted) widget.store.updateProject(project);
    } catch (e) {
      if (mounted) error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final project = await widget.session.loadProject(widget.sync.config);
      if (!mounted) return;
      widget.store.updateProject(project);
      if (widget.store.actor.has('member.manage')) {
        requests = await widget.session.requests(widget.sync.config);
      }
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<String> get assignableRoles =>
      [
            'manager',
            'worker',
            'viewer',
            ...widget.store.project!.roles.map((r) => r.id),
          ]
          .where(
            (id) =>
                (widget.store.owns || id != 'manager') &&
                widget.store.actor.permissions.containsAll(
                  rolePerson(id).permissions,
                ),
          )
          .toList();
  Person rolePerson(String id) =>
      Person('', '', '', id, 0).resolved(widget.store.project!.roles);

  Future<ProjectRole?> addRole() async {
    try {
      final latest = await widget.session.loadProject(widget.sync.config);
      if (!mounted) return null;
      widget.store.updateProject(latest);
      if (!widget.store.actor.has('role.manage')) {
        throw StateError('역할 관리 권한이 필요합니다.');
      }
      final role = await showProjectRoleDialog(context, widget.store.actor);
      if (role == null || !mounted) return null;
      setState(() {
        busy = true;
        error = '';
      });
      final next = await widget.session.saveRole(widget.sync.config, role);
      widget.store.updateProject(next);
      return role;
    } catch (e) {
      if (mounted) setState(() => error = '$e');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> setEnabled(Person person, bool enabled) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final next = await widget.session.setMemberEnabled(
        widget.sync.config,
        person.id,
        enabled,
      );
      widget.store.updateProject(next);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> assign(Person person, {Map<String, dynamic>? request}) async {
    var role = assignableRoles.contains(person.role)
        ? person.role
        : assignableRoles.contains('worker')
        ? 'worker'
        : assignableRoles.first;
    var enabled = person.role == 'pending' ? true : person.enabled;
    var adding = false;
    var dialogMessage = '';
    final result = await showDialog<Person>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => IeumDialog(
          title: Text('${person.name} · 역할과 상태'),
          icon: Icons.admin_panel_settings_outlined,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${person.login}',
                style: const TextStyle(color: Color(0xff9990a5)),
              ),
              const SizedBox(height: 18),
              const Text('상태', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('member-enabled'),
                      onPressed:
                          widget.store.actor.has('member.status') && !adding
                          ? () => update(() => enabled = true)
                          : null,
                      icon: Icon(
                        enabled ? Icons.check_circle : Icons.circle_outlined,
                        size: 17,
                      ),
                      label: const Text('활성화'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('member-disabled'),
                      onPressed:
                          widget.store.actor.has('member.status') && !adding
                          ? () => update(() => enabled = false)
                          : null,
                      icon: Icon(
                        !enabled ? Icons.check_circle : Icons.circle_outlined,
                        size: 17,
                      ),
                      label: const Text('비활성화'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                widget.store.actor.has('member.status')
                    ? '비활성화하면 작업 수정·진행·업로드가 차단됩니다. 역할은 보존됩니다.'
                    : '상태는 참여자 상태 관리 권한이 있는 관리자만 변경할 수 있습니다.',
                style: const TextStyle(fontSize: 11, height: 1.6),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '역할',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (widget.store.actor.has('role.manage'))
                    TextButton.icon(
                      key: const Key('member-add-role'),
                      onPressed: adding
                          ? null
                          : () async {
                              update(() {
                                adding = true;
                                dialogMessage = '';
                              });
                              final created = await addRole();
                              if (!ctx.mounted) return;
                              update(() {
                                adding = false;
                                if (created != null) {
                                  role = created.id;
                                } else {
                                  dialogMessage = error;
                                }
                              });
                            },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('역할 추가'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              for (final id in assignableRoles)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: role == id ? const Color(0xfff0ebfc) : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: const BorderSide(color: Color(0xffe9e5ef)),
                    ),
                    child: ListTile(
                      key: Key('member-role-$id'),
                      dense: true,
                      leading: Icon(
                        role == id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        size: 19,
                      ),
                      title: Text(
                        rolePerson(id).roleLabel,
                        style: const TextStyle(fontSize: 12),
                      ),
                      subtitle: Text(
                        rolePerson(id).permissions.isEmpty
                            ? '목록 조회'
                            : rolePerson(id).permissions
                                  .map((p) => permissionLabels[p])
                                  .join(' · '),
                        style: const TextStyle(fontSize: 10, height: 1.5),
                      ),
                      onTap: adding ? null : () => update(() => role = id),
                    ),
                  ),
                ),
              if (dialogMessage.isNotEmpty)
                Text(
                  dialogMessage,
                  style: const TextStyle(
                    color: Color(0xffbd6b7a),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: adding ? null : () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('save-member'),
              onPressed: adding
                  ? null
                  : () => Navigator.pop(
                      ctx,
                      Person.fromJson({
                        ...person.json,
                        'role': role,
                        'enabled': enabled,
                      }),
                    ),
              child: Text(request == null ? '저장' : '가입 승인'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final next = await widget.session.assign(
        widget.sync.config,
        result,
        request: request,
      );
      if (!mounted) return;
      widget.store.updateProject(next);
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xffe9e5ef)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '참여자 ${widget.store.people.length}명',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            OutlinedButton(
              key: const Key('team-refresh'),
              onPressed: busy ? null : refresh,
              child: const Text('새로고침'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.store.actor.has('role.manage'))
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: OutlinedButton.icon(
              key: const Key('team-add-role'),
              onPressed: busy ? null : addRole,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('역할 추가'),
            ),
          ),
        if (widget.store.owns)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 10,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : invite,
                  child: const Text('GitHub 협업자 초대'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : transfer,
                  child: const Text('프로젝트 소유권 이전'),
                ),
              ],
            ),
          ),
        Text(
          '내 역할: ${widget.store.actor.roleLabel}',
          style: const TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 12),
        for (final member in widget.store.people)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${member.name}  @${member.login}\n${member.roleLabel} · ${member.role == 'pending'
                        ? '가입 승인 대기'
                        : member.active
                        ? '활성화'
                        : '비활성화'}',
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                ),
                if (canManageMemberStatus(
                  widget.store.actor,
                  member,
                  widget.store.project!.ownerId,
                ))
                  TextButton(
                    key: Key('member-status-${member.id}'),
                    onPressed: busy
                        ? null
                        : () => setEnabled(member, !member.enabled),
                    child: Text(member.enabled ? '비활성화' : '활성화'),
                  ),
                if (widget.store.actor.has('member.manage') &&
                    (widget.store.owns || member.role != 'manager') &&
                    widget.store.actor.permissions.containsAll(
                      member.permissions,
                    ) &&
                    member.role != 'owner' &&
                    member.role != 'pending')
                  TextButton(
                    onPressed: busy ? null : () => assign(member),
                    child: const Text('역할 변경'),
                  ),
              ],
            ),
          ),
        if (widget.store.actor.has('member.manage')) ...[
          const Divider(height: 24),
          const Text(
            '가입 승인 대기 · 요청을 자동으로 확인합니다.',
            style: TextStyle(fontSize: 12),
          ),
          for (final warning in widget.session.requestWarnings)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                warning,
                style: const TextStyle(fontSize: 11, color: Color(0xffbd6b7a)),
              ),
            ),
          for (final request in requests.where(
            (r) => r['projectId'] == widget.store.project!.id,
          ))
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${request['member']['name']} · @${request['member']['login']}',
                    ),
                  ),
                  FilledButton(
                    onPressed: busy
                        ? null
                        : () => assign(
                            Person.fromJson(
                              Map<String, dynamic>.from(request['member']),
                            ),
                            request: request,
                          ),
                    child: const Text('역할 지정 / 승인'),
                  ),
                ],
              ),
            ),
        ],
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error,
              style: const TextStyle(color: Color(0xffbd6b7a)),
            ),
          ),
      ],
    ),
  );
}
