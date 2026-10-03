import 'dart:async';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'models.dart';
import 'popup_ui.dart';
import 'project_service.dart';
import 'store.dart';
import 'role_editor.dart';
import 'member_policy.dart';
import 'draft_guard.dart';

class TeamPanel extends StatefulWidget {
  const TeamPanel({
    super.key,
    required this.store,
    required this.sync,
    required this.session,
    this.onOpenTasks,
    this.initialMember,
  });
  final ValueChanged<String>? onOpenTasks;
  final String? initialMember;
  final TaskStore store;
  final GitHubSync sync;
  final GitHubSession session;
  @override
  State<TeamPanel> createState() => _TeamPanelState();
}

class _TeamPanelState extends State<TeamPanel> {
  List<Map<String, dynamic>> requests = [];
  bool busy = false;
  String error = '',
      query = '',
      roleFilter = '',
      stateFilter = '',
      partFilter = '',
      selectionNotice = '';
  String? selected;
  final searchController = TextEditingController();
  final rowFocus = <String, FocusNode>{};
  DateTime? checkedAt;
  bool offline = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    selected = widget.initialMember?.isNotEmpty == true
        ? widget.initialMember
        : null;
    widget.store.addListener(storeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(refresh());
    });
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !busy) unawaited(refresh());
    });
  }

  @override
  void dispose() {
    widget.store.removeListener(storeChanged);
    timer?.cancel();
    searchController.dispose();
    for (final focus in rowFocus.values) {
      focus.dispose();
    }
    super.dispose();
  }

  void storeChanged() {
    if (mounted) updateFilters(() {});
  }

  Future<void> invite() async {
    final controller = TextEditingController();
    final projectId = widget.store.project!.id;
    var saving = false, saved = false;
    var message = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> save() async {
            if (saving || controller.text.trim().isEmpty) return;
            update(() {
              saving = true;
              message = '';
            });
            try {
              await widget.session.invite(
                widget.sync.config,
                controller.text.trim(),
                expectedProjectId: projectId,
              );
              if (!ctx.mounted || !mounted) return;
              update(() {
                saved = true;
                saving = false;
              });
              await WidgetsBinding.instance.endOfFrame;
              if (ctx.mounted) Navigator.pop(ctx);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'GitHub 협업자 초대를 보냈습니다. 팀원이 수락해야 합니다. 이음 가입 승인은 별도입니다.',
                    ),
                  ),
                );
              }
            } catch (e) {
              if (ctx.mounted) {
                update(() {
                  saving = false;
                  message = '초대 실패 · 입력 유지: $e';
                });
              }
            }
          }

          return DraftGuard(
            dirty: !saved && controller.text.trim().isNotEmpty,
            busy: saving,
            onSave: save,
            child: IeumDialog(
              title: const Text('GitHub 협업자 초대'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    enabled: !saving,
                    onChanged: (_) => update(() {}),
                    decoration: const InputDecoration(
                      labelText: 'GitHub 계정 아이디',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text('저장소 협업자 초대를 보냅니다. 이음의 역할 배정·가입 승인과 별개의 단계입니다.'),
                  if (message.isNotEmpty)
                    Text(message, style: const TextStyle(color: Colors.red)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.maybePop(ctx),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: saving || controller.text.trim().isEmpty
                      ? null
                      : save,
                  child: Text(saving ? '전송 중…' : '초대 보내기'),
                ),
              ],
            ),
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
  }

  Future<void> transfer() async {
    final projectId = widget.store.project!.id;
    final candidates = widget.store.people
        .where(
          (p) => p.id != widget.store.project!.ownerId && p.active && p.canWork,
        )
        .toList();
    if (candidates.isEmpty) {
      setState(() => error = '관리자 권한을 받을 작업 가능한 참여자를 먼저 승인하세요.');
      return;
    }
    var target = '';
    var saving = false, saved = false;
    var message = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> save() async {
            if (saving || target.isEmpty) return;
            final chosen = candidates.firstWhere((p) => p.id == target);
            update(() => saving = true);
            if (!await confirm(
              '관리자 권한 이전 확인',
              '${chosen.name}이 이음 프로젝트 관리자가 되고, 내 역할은 운영자가 됩니다. GitHub 저장소 소유권·협업자 권한은 이전되지 않습니다.',
            )) {
              if (ctx.mounted) update(() => saving = false);
              return;
            }
            if (!ctx.mounted) return;
            update(() {
              saving = true;
              message = '';
            });
            try {
              final next = await widget.session.transferOwnership(
                widget.sync.config,
                target,
                expectedProjectId: projectId,
                expectedTarget: chosen,
              );
              if (!ctx.mounted || !mounted) return;
              widget.store.updateProject(next);
              update(() {
                saving = false;
                saved = true;
              });
              await WidgetsBinding.instance.endOfFrame;
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              if (ctx.mounted) {
                update(() {
                  saving = false;
                  message = '이전 실패 · 선택 유지: $e';
                });
              }
            }
          }

          return DraftGuard(
            dirty: !saved && target.isNotEmpty,
            busy: saving,
            onSave: save,
            child: IeumDialog(
              title: const Text('관리자 권한 이전'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IgnorePointer(
                    ignoring: saving,
                    child: IeumSelect(
                      value: target,
                      values: {
                        '': '새 관리자 선택',
                        for (final p in candidates)
                          p.id: '${p.name} · @${p.login}',
                      },
                      onChanged: (v) => update(() => target = v),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '이음 프로젝트의 관리자만 변경합니다. GitHub 저장소 소유권과 초대 권한은 별도입니다.',
                  ),
                  if (message.isNotEmpty)
                    Text(message, style: const TextStyle(color: Colors.red)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.maybePop(ctx),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: saving || target.isEmpty ? null : save,
                  child: Text(saving ? '이전 중…' : '관리자 권한 이전'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final project = await widget.session.loadProject(widget.sync.config);
      if (!mounted) return;
      widget.store.updateProject(project);
      updateFilters(() {});
      checkedAt = DateTime.now();
      offline = false;
      if (widget.store.actor.has('member.manage')) {
        requests = await widget.session.requests(widget.sync.config);
      } else {
        requests = [];
      }
    } catch (e) {
      if (mounted) {
        offline = true;
        error = '목록 새로고침 실패 · 마지막 확인 데이터입니다. $e';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  List<String> get assignableRoles =>
      [
            if (widget.store.people.any((p) => p.role == 'manager')) 'manager',
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
      final role = await showProjectRoleDialog(
        context,
        widget.store.actor,
        onSave: (draft) async {
          final next = await widget.session.saveRole(
            widget.sync.config,
            draft,
            expectedProjectId: latest.id,
          );
          if (mounted) widget.store.updateProject(next);
        },
      );
      if (role == null || !mounted) return null;
      setState(() {
        busy = true;
        error = '';
      });
      return role;
    } catch (e) {
      if (mounted) setState(() => error = '$e');
      return null;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => IeumDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('확인'),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> setEnabled(Person person, bool enabled) async {
    if (busy || offline) return;
    if (!enabled) {
      setState(() {
        busy = true;
        error = '';
      });
      try {
        final latest = await widget.session.loadProject(widget.sync.config);
        if (latest.id != widget.store.project!.id) {
          throw StateError('프로젝트가 변경되었습니다.');
        }
        final actor = latest.people
            .where((p) => p.id == widget.store.profileId)
            .firstOrNull;
        final target = latest.people
            .where((p) => p.id == person.id)
            .firstOrNull;
        if (actor == null ||
            target == null ||
            !canManageMemberStatus(actor, target, latest.ownerId)) {
          throw StateError('현재 참여자 상태 변경 권한이 없습니다.');
        }
        final blockers = await GitHubPublisher(widget.session.api)
            .memberBlockers(widget.sync.config, latest, person.id);
        if (!mounted) return;
        widget.store.updateProject(latest);
        if (blockers.isNotEmpty) {
          setState(() {
            selected = person.id;
            error =
                '인수인계 필요: ${blockers.join(', ')}. ${actor.has('task.assign') ? '관련 업무에서 담당자·검토자를 재배정하고 대기 PR을 먼저 처리하세요.' : '업무 배정 권한이 있는 관리자에게 인수인계를 요청하세요.'}';
          });
          return;
        }
      } catch (e) {
        if (mounted) setState(() => error = '비활성화 사전 확인 실패: $e');
        return;
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }
    if (!await confirm(
      enabled ? '참여자 활성화' : '참여자 비활성화',
      '${person.name} · ${memberRoleLabel(person)}\n${enabled ? '보존된 역할로 작업과 업로드를 다시 허용합니다.' : '작업·업로드가 차단됩니다. 남은 업무와 PR이 있으면 인수인계 후 다시 시도해야 합니다.'}',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final next = await widget.session.setMemberEnabled(
        widget.sync.config,
        person.id,
        enabled,
        expectedProjectId: widget.store.project!.id,
        expectedMember: person,
      );
      if (mounted) widget.store.updateProject(next);
    } catch (e) {
      if (mounted) error = '상태 저장 실패: $e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> assign(Person person, {Map<String, dynamic>? request}) async {
    if (busy || offline || assignableRoles.isEmpty) return;
    var role = assignableRoles.contains(person.role) ? person.role : '';
    var enabled = request != null ? true : person.enabled;
    var adding = false, saving = false, saved = false;
    var dialogMessage = '';
    var base = person;
    final projectId = widget.store.project!.id;
    bool dirty() =>
        !saved &&
        (request != null || role != base.role || enabled != base.enabled);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> save() async {
            if (saving || adding || role.isEmpty) {
              update(() => dialogMessage = '역할을 선택하세요.');
              return;
            }
            update(() => saving = true);
            if (!await confirm(
              request == null ? '역할·상태 변경 확인' : '가입 승인 확인',
              '${base.name} · @${base.login}\n역할: ${memberRoleLabel(base)} → ${rolePerson(role).roleLabel}\n상태: ${memberStateLabels[memberState(base)]} → ${enabled ? '활성화' : '비활성화'}\n새 권한: ${rolePerson(role).permissions.map((p) => permissionLabels[p]).join(', ')}\n완료 업무와 검토 본문의 잠금은 유지됩니다.',
            )) {
              if (ctx.mounted) {
                update(() => saving = false);
              }
              return;
            }
            if (!ctx.mounted) return;
            update(() {
              saving = true;
              dialogMessage = '';
            });
            try {
              final draft = Person.fromJson({
                ...base.json,
                'role': role,
                'enabled': enabled,
                'assignedRole': role,
              });
              final next = await widget.session.assign(
                widget.sync.config,
                draft,
                request: request,
                expectedProjectId: projectId,
                expectedMember: request == null ? base : null,
              );
              if (!ctx.mounted || !mounted) return;
              widget.store.updateProject(next);
              update(() {
                saved = true;
                saving = false;
              });
              await WidgetsBinding.instance.endOfFrame;
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              if (ctx.mounted) {
                update(() {
                  saving = false;
                  dialogMessage = '저장 실패 · 초안은 유지됩니다. $e';
                });
              }
            }
          }

          return DraftGuard(
            dirty: dirty(),
            busy: saving || adding,
            onSave: save,
            child: IeumDialog(
              title: Text('${person.name} · 역할과 상태'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@${person.login} · ${widget.store.project!.name}'),
                    Text(
                      '저장된 역할: ${memberRoleLabel(base)} · ${memberStateLabels[memberState(base)]}',
                    ),
                    const SizedBox(height: 16),
                    const Text('상태'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('member-enabled'),
                          onPressed:
                              !saving &&
                                  !adding &&
                                  widget.store.actor.has('member.status')
                              ? () => update(() => enabled = true)
                              : null,
                          icon: Icon(
                            enabled
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 17,
                          ),
                          label: const Text('활성화'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('member-disabled'),
                          onPressed:
                              !saving &&
                                  !adding &&
                                  widget.store.actor.has('member.status')
                              ? () => update(() => enabled = false)
                              : null,
                          icon: Icon(
                            !enabled
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 17,
                          ),
                          label: const Text('비활성화'),
                        ),
                      ],
                    ),
                    const Text(
                      '비활성화 전 남은 업무·검토·PR을 인수인계해야 합니다. 상태 변경은 관리자 권한이 필요합니다.',
                      style: TextStyle(fontSize: 11, height: 1.6),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Expanded(child: Text('역할 · 단일 선택')),
                        if (widget.store.actor.has('role.manage'))
                          TextButton.icon(
                            key: const Key('member-add-role'),
                            onPressed: saving || adding
                                ? null
                                : () async {
                                    update(() => adding = true);
                                    final created = await addRole();
                                    if (ctx.mounted) {
                                      update(() {
                                        adding = false;
                                        if (created != null) {
                                          role = created.id;
                                        } else {
                                          dialogMessage = error;
                                        }
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('역할 추가'),
                          ),
                      ],
                    ),
                    for (final id in assignableRoles)
                      ListTile(
                        key: Key('member-role-$id'),
                        dense: true,
                        leading: Icon(
                          role == id
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        title: Text(rolePerson(id).roleLabel),
                        subtitle: Text(
                          rolePerson(id).permissions.isEmpty
                              ? '목록 조회'
                              : rolePerson(id).permissions
                                    .map((p) => permissionLabels[p])
                                    .join(' · '),
                          style: const TextStyle(fontSize: 11),
                        ),
                        onTap: saving || adding
                            ? null
                            : () => update(() => role = id),
                      ),
                    if (dirty()) const Text('저장하지 않은 변경사항'),
                    if (dialogMessage.isNotEmpty) ...[
                      Text(
                        dialogMessage,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                      if (request == null)
                        TextButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  try {
                                    final latest = await widget.session
                                        .loadProject(widget.sync.config);
                                    if (latest.id != projectId) {
                                      throw StateError('저장소 프로젝트가 변경되었습니다.');
                                    }
                                    final target = latest.people
                                        .where((p) => p.id == person.id)
                                        .firstOrNull;
                                    if (target == null) {
                                      throw StateError('참여자가 삭제되었습니다.');
                                    }
                                    if (ctx.mounted && mounted) {
                                      widget.store.updateProject(latest);
                                      update(() {
                                        base = target;
                                        dialogMessage = '최신 저장값을 확인했습니다. 위 초안을 다시 확인한 뒤 저장하세요.';
                                      });
                                    }
                                  } catch (e) {
                                    if (ctx.mounted) {
                                      update(() => dialogMessage = '$e');
                                    }
                                  }
                                },
                          child: const Text('최신 값 확인 · 초안 유지'),
                        ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving || adding
                      ? null
                      : () => Navigator.maybePop(ctx),
                  child: const Text('취소'),
                ),
                FilledButton(
                  key: const Key('save-member'),
                  onPressed: saving || adding || !dirty() || role.isEmpty
                      ? null
                      : save,
                  child: Text(
                    saving
                        ? '저장소 반영 중…'
                        : request == null
                        ? '저장'
                        : '가입 승인',
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (mounted) await refresh();
  }

  Future<void> reject(Map<String, dynamic> request) async {
    if (!await confirm(
      '참여 요청 거절',
      '${request['member']['name']}의 가입 요청 PR을 닫습니다. 이미 승인된 참여자의 권한은 제거하지 않습니다.',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.session.rejectRequest(
        widget.sync.config,
        request,
        expectedProjectId: widget.store.project!.id,
      );
    } catch (e) {
      if (mounted) error = '요청 거절 실패: $e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted && error.isEmpty) await refresh();
  }

  List<Person> get visible => filterMembers(
    widget.store.people,
    query: query,
    role: roleFilter,
    state: stateFilter,
    part: partFilter,
  );
  void updateFilters(VoidCallback change) => setState(() {
    change();
    if (selected != null && !visible.any((p) => p.id == selected)) {
      selected = null;
      selectionNotice = '선택한 참여자가 검색 결과에서 제외되어 상세를 닫았습니다.';
    }
  });
  void resetFilters() => updateFilters(() {
    query = roleFilter = stateFilter = partFilter = '';
    searchController.clear();
  });
  void closeDetail(String id) {
    setState(() => selected = null);
    rowFocus[id]?.requestFocus();
  }

  Future<void> openDetail(Person person, bool wide) async {
    if (wide) {
      setState(() {
        selected = person.id;
        selectionNotice = '';
      });
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: const Text('참여자 상세'),
        width: 540,
        content: ListenableBuilder(
          listenable: widget.store,
          builder: (_, _) {
            final latest = widget.store.people
                .where((p) => p.id == person.id)
                .firstOrNull;
            return latest == null
                ? const Text('참여자가 더 이상 프로젝트에 없습니다.')
                : detail(latest, close: () => Navigator.pop(ctx));
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
    rowFocus[person.id]?.requestFocus();
  }

  Widget detail(Person person, {VoidCallback? close}) {
    final tasks = widget.store.tasks
        .where((t) => t.assigneeId == person.id || t.reviewerId == person.id)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          person.name,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        SelectableText('@${person.login}'),
        const SizedBox(height: 12),
        Text('역할: ${memberRoleLabel(person)}'),
        Text('참여 상태: ${memberStateLabels[memberState(person)]}'),
        Text('파트: ${person.parts.isEmpty ? '미배정' : person.parts.join(', ')}'),
        if (person.id == widget.store.profileId) const Text('본인'),
        if (person.id == widget.store.project!.ownerId)
          const Text('관리자 · 프로젝트 소유자'),
        const Divider(height: 28),
        Text('관련 업무 ${tasks.length}건'),
        for (final status in statuses.entries)
          Text(
            '${status.value}: ${tasks.where((t) => t.status == status.key).length}건',
          ),
        if (widget.onOpenTasks != null)
          TextButton.icon(
            onPressed: () {
              close?.call();
              widget.onOpenTasks!(person.id);
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('관련 업무 보기'),
          ),
        const Divider(height: 28),
        if (memberReadOnlyReason(
          widget.store.actor,
          person,
          widget.store.project!.ownerId,
        ).isNotEmpty)
          Text(
            memberReadOnlyReason(
              widget.store.actor,
              person,
              widget.store.project!.ownerId,
            ),
            style: const TextStyle(fontSize: 12),
          ),
        if (canAssignMember(
              widget.store.actor,
              person,
              widget.store.project!.ownerId,
            ) &&
            person.role != 'pending')
          OutlinedButton(
            onPressed: busy || offline ? null : () => assign(person),
            child: const Text('역할·상태 변경'),
          ),
      ],
    );
  }

  Widget memberRow(Person person, bool wide) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 620;
      final identity = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              Text(
                person.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (person.id == widget.store.profileId)
                const Text('본인', style: TextStyle(fontSize: 11)),
              if (person.id == widget.store.project!.ownerId)
                const Text('소유자', style: TextStyle(fontSize: 11)),
            ],
          ),
          Text('@${person.login}', style: const TextStyle(fontSize: 11)),
        ],
      );
      return Card(
        margin: const EdgeInsets.only(bottom: 6),
        elevation: 0,
        color: selected == person.id
            ? const Color(0xffe9edeb)
            : const Color(0xfff8f9f8),
        child: ListTile(
          key: Key('participant-${person.id}'),
          focusNode: rowFocus.putIfAbsent(person.id, FocusNode.new),
          onTap: () => openDetail(person, wide),
          title: columns
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: identity),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: Text(
                        memberRoleLabel(person),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: Text(
                        memberStateLabels[memberState(person)]!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: Text(
                        person.parts.isEmpty ? '미배정' : person.parts.join(', '),
                        style: const TextStyle(fontSize: 11, height: 1.6),
                      ),
                    ),
                  ],
                )
              : identity,
          subtitle: columns
              ? null
              : Text(
                  '${memberRoleLabel(person)} · ${memberStateLabels[memberState(person)]} · ${person.parts.isEmpty ? '파트 미배정' : person.parts.join(', ')}',
                  style: const TextStyle(fontSize: 11, height: 1.7),
                ),
          trailing: MenuAnchor(
            menuChildren: [
              MenuItemButton(
                onPressed: () => openDetail(person, wide),
                child: const Text('참여자 상세'),
              ),
              if (canAssignMember(
                    widget.store.actor,
                    person,
                    widget.store.project!.ownerId,
                  ) &&
                  person.role != 'pending')
                MenuItemButton(
                  onPressed: busy || offline ? null : () => assign(person),
                  child: const Text('역할 변경'),
                ),
              if (canManageMemberStatus(
                    widget.store.actor,
                    person,
                    widget.store.project!.ownerId,
                  ) &&
                  person.role != 'disabled') ...[
                const Divider(height: 1),
                MenuItemButton(
                  key: Key('member-status-${person.id}'),
                  onPressed: busy || offline
                      ? null
                      : () => setEnabled(person, !person.enabled),
                  child: Text(person.enabled ? '비활성화' : '활성화'),
                ),
              ],
            ],
            builder: (_, controller, _) => IconButton(
              key: Key('member-actions-${person.id}'),
              tooltip: '${person.name} 추가 작업',
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.more_horiz),
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 800;
      final result = visible;
      final person = result.where((p) => p.id == selected).firstOrNull;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                key: const Key('team-refresh'),
                onPressed: busy ? null : refresh,
                child: const Text('새로고침'),
              ),
              if (widget.store.actor.has('role.manage'))
                OutlinedButton.icon(
                  key: const Key('team-add-role'),
                  onPressed: busy || offline ? null : addRole,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('역할 추가'),
                ),
              if (widget.store.owns) ...[
                OutlinedButton(
                  onPressed: busy || offline ? null : invite,
                  child: const Text('GitHub 협업자 초대'),
                ),
                OutlinedButton(
                  onPressed: busy || offline ? null : transfer,
                  child: const Text('관리자 권한 이전'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          if (busy)
            const LinearProgressIndicator(key: Key('participants-loading')),
          if (error.isNotEmpty)
            Text(error, style: const TextStyle(color: Colors.red)),
          if (checkedAt != null)
            Text(
              '마지막 확인: ${checkedAt!.toLocal()}${offline ? ' · 오프라인/연결 실패 · 변경 불가' : ' · 저장은 GitHub에 즉시 반영'}',
              style: const TextStyle(fontSize: 11),
            ),
          if (!widget.store.actor.has('member.manage'))
            const Text(
              '읽기 전용 · 참여자 관리 권한이 있어야 역할과 요청을 변경할 수 있습니다.',
              style: TextStyle(fontSize: 12),
            ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('participant-search'),
            controller: searchController,
            decoration: const InputDecoration(
              hintText: '이름·GitHub 아이디 검색',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => updateFilters(() => query = value),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 170,
                child: IeumSelect(
                  key: const Key('participant-role-filter'),
                  value: roleFilter,
                  values: {
                    '': '모든 역할',
                    for (final p in widget.store.people)
                      p.role: memberRoleLabel(p),
                  },
                  onChanged: (value) => updateFilters(() => roleFilter = value),
                ),
              ),
              SizedBox(
                width: 150,
                child: IeumSelect(
                  key: const Key('participant-state-filter'),
                  value: stateFilter,
                  values: {'': '모든 상태', ...memberStateLabels},
                  onChanged: (value) =>
                      updateFilters(() => stateFilter = value),
                ),
              ),
              SizedBox(
                width: 150,
                child: IeumSelect(
                  key: const Key('participant-part-filter'),
                  value: partFilter,
                  values: {
                    '': '모든 파트',
                    for (final p in widget.store.people)
                      for (final part in p.parts) part: part,
                  },
                  onChanged: (value) => updateFilters(() => partFilter = value),
                ),
              ),
              TextButton(
                key: const Key('participant-filter-reset'),
                onPressed: resetFilters,
                child: const Text('필터 초기화'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '검색 결과 ${result.length}명 / 프로젝트 참여자 ${widget.store.people.length}명 · 이름순',
            key: const Key('participant-result-count'),
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          if (selectionNotice.isNotEmpty) Text(selectionNotice),
          if (result.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('검색 결과가 없습니다. 검색어와 필터를 초기화하세요.'),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, bounds) => Column(
                    children: [
                      if (bounds.maxWidth >= 620)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 80, 12),
                          child: Row(
                            children: [
                              const Expanded(
                                flex: 3,
                                child: Text(
                                  '참여자',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                flex: 2,
                                child: Text(
                                  '역할',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                flex: 2,
                                child: Text(
                                  '참여 상태',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                flex: 3,
                                child: Text(
                                  '파트',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      for (final p in result) memberRow(p, wide),
                    ],
                  ),
                ),
              ),
              if (wide && person != null) ...[
                const SizedBox(width: 16),
                SizedBox(
                  width: 300,
                  child: Card(
                    elevation: 0,
                    color: const Color(0xfff8f9f8),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: const Key('close-participant-detail'),
                              tooltip: '참여자 상세 닫기',
                              onPressed: () => closeDetail(person.id),
                              icon: const Icon(Icons.close),
                            ),
                          ),
                          detail(person),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.store.actor.has('member.manage')) ...[
            const Divider(height: 28),
            const Text('참여 요청 · 승인 대기'),
            for (final warning in widget.session.requestWarnings)
              Text(
                warning,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            if (!busy && requests.isEmpty)
              const Text('대기 중인 참여 요청이 없습니다.', style: TextStyle(fontSize: 12)),
            for (final request in requests.where(
              (r) => r['projectId'] == widget.store.project!.id,
            ))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${request['member']['name']} · @${request['member']['login']}',
                    ),
                    FilledButton(
                      onPressed: busy || offline
                          ? null
                          : () => assign(
                              Person.fromJson(
                                Map<String, dynamic>.from(request['member']),
                              ),
                              request: request,
                            ),
                      child: const Text('역할 지정 / 승인'),
                    ),
                    TextButton(
                      onPressed: busy || offline ? null : () => reject(request),
                      child: const Text('거절'),
                    ),
                  ],
                ),
              ),
          ],
        ],
      );
    },
  );
}
