import 'app_localizations.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'models.dart';
import 'popup_ui.dart';
import 'project_service.dart';
import 'store.dart';
import 'role_editor.dart';
import 'member_policy.dart';
import 'draft_guard.dart';
import 'workspace_ui.dart';

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
  String participantKind(Person person) =>
      person.role == 'owner' ? tr('관리자') : tr('참여자');
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
                  SnackBar(
                    content: Text(
                      tr('GitHub 초대를 보냈습니다. 초대 수락 후 이음에서 참여 요청을 승인해 주세요.'),
                    ),
                  ),
                );
              }
            } catch (e) {
              if (ctx.mounted) {
                update(() {
                  saving = false;
                  message = tr('초대를 보내지 못했습니다. {v0}', args: {'v0': e});
                });
              }
            }
          }

          return DraftGuard(
            dirty: !saved && controller.text.trim().isNotEmpty,
            busy: saving,
            onSave: save,
            child: IeumDialog(
              title: Text(tr('GitHub 협업자 초대')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    enabled: !saving,
                    onChanged: (_) => update(() {}),
                    decoration: InputDecoration(labelText: tr('GitHub 사용자 이름')),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr(
                      '저장소 접근 권한을 위한 GitHub 초대입니다. 프로젝트 참여 승인과 파트 배정은 참여자 관리에서 진행합니다.',
                    ),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                  if (message.isNotEmpty)
                    Text(
                      trError(message),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.maybePop(ctx),
                  child: Text(tr('취소')),
                ),
                FilledButton(
                  onPressed: saving || controller.text.trim().isEmpty
                      ? null
                      : save,
                  child: Text(saving ? tr('전송 중…') : tr('초대 보내기')),
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
      setState(() => error = tr('관리자 권한을 이전할 수 있는 활성 참여자가 없습니다.'));
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
              tr('관리자 권한 이전 확인'),
              tr(
                '{v0} 님이 프로젝트 관리자가 됩니다. 현재 관리자는 일반 참여자로 변경됩니다. GitHub 저장소의 소유권과 접근 권한은 변경되지 않습니다.',
                args: {'v0': chosen.name},
              ),
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
                  message = tr('관리자 권한을 이전하지 못했습니다. {v0}', args: {'v0': e});
                });
              }
            }
          }

          return DraftGuard(
            dirty: !saved && target.isNotEmpty,
            busy: saving,
            onSave: save,
            child: IeumDialog(
              title: Text(tr('관리자 권한 이전')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IgnorePointer(
                    ignoring: saving,
                    child: IeumSelect(
                      value: target,
                      values: {
                        '': tr('새 관리자 선택'),
                        for (final p in candidates)
                          p.id: '${p.name} · @${p.login}',
                      },
                      onChanged: (v) => update(() => target = v),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr('프로젝트 관리자를 변경합니다. GitHub 저장소의 소유권과 접근 권한은 변경되지 않습니다.'),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                  if (message.isNotEmpty)
                    Text(
                      trError(message),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.maybePop(ctx),
                  child: Text(tr('취소')),
                ),
                FilledButton(
                  onPressed: saving || target.isEmpty ? null : save,
                  child: Text(saving ? tr('이전 중…') : tr('관리자 권한 이전')),
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
        error = tr(
          '참여자 목록을 새로고침하지 못했습니다. 마지막으로 확인한 목록을 표시합니다. {v0}',
          args: {'v0': e},
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<ProjectRole?> addRole() async {
    try {
      final latest = await widget.session.loadProject(widget.sync.config);
      if (!mounted) return null;
      widget.store.updateProject(latest);
      if (!widget.store.actor.has('role.manage')) {
        throw StateError(tr('파트 관리 권한이 필요합니다.'));
      }
      final role = await showProjectRoleDialog(
        context,
        widget.store.actor,
        onSave: (draft) async {
          final next = await widget.session.savePermissionPart(
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
              child: Text(tr('취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('확인')),
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
          throw StateError(tr('프로젝트가 변경되었습니다.'));
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
          throw StateError(tr('현재 참여자 상태 변경 권한이 없습니다.'));
        }
        final blockers = await GitHubPublisher(widget.session.api)
            .memberBlockers(widget.sync.config, latest, person.id);
        if (!mounted) return;
        widget.store.updateProject(latest);
        if (blockers.isNotEmpty) {
          setState(() {
            selected = person.id;
            error = tr(
              '인수인계가 필요합니다: {v0}. 관련 작업의 담당자를 변경하고 대기 중인 변경 사항을 처리해 주세요.',
              args: {'v0': blockers.join(', ')},
            );
          });
          return;
        }
      } catch (e) {
        if (mounted) {
          setState(() => error = tr('비활성화 사전 확인 실패: {v0}', args: {'v0': e}));
        }
        return;
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }
    if (!await confirm(
      enabled ? tr('참여자 활성화') : tr('참여자 비활성화'),
      tr(
        '{v0} · {v1}\n{v2}',
        args: {
          'v0': person.name,
          'v1': participantKind(person),
          'v2': enabled
              ? tr('프로젝트 작업과 동기화를 다시 사용할 수 있습니다. 잠긴 작업은 지정된 담당자만 수정할 수 있습니다.')
              : tr(
                  '프로젝트 작업과 동기화를 사용할 수 없게 됩니다. 남은 작업과 전송 중인 변경 사항은 먼저 인수인계해 주세요.',
                ),
        },
      ),
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
      if (mounted) error = tr('상태 저장 실패: {v0}', args: {'v0': e});
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> assign(Person person, {Map<String, dynamic>? request}) async {
    if (busy || offline) return;
    final ownerTarget = person.id == widget.store.project!.ownerId;
    final role = ownerTarget ? 'owner' : 'unassigned';
    var enabled = request != null ? true : person.enabled;
    final parts =
        widget.store.project!.partWorkflowView.people
            .where((p) => p.id == person.id)
            .firstOrNull
            ?.parts
            .toSet() ??
        <String>{};
    final initialParts = {...parts};
    var adding = false, saving = false, saved = false;
    var dialogMessage = '';
    var base = person;
    final projectId = widget.store.project!.id;
    bool dirty() =>
        !saved &&
        (request != null ||
            enabled != base.enabled ||
            parts.length != initialParts.length ||
            !parts.containsAll(initialParts));
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> save() async {
            if (saving || adding) return;
            update(() => saving = true);
            if (!await confirm(
              request == null ? tr('참여자 설정 변경') : tr('프로젝트 참여 승인'),
              tr(
                '{v0} · @{v1}\n소속 파트: {v2} → {v3}\n참여 상태: {v4}',
                args: {
                  'v0': base.name,
                  'v1': base.login,
                  'v2': initialParts.isEmpty
                      ? tr('미배정')
                      : initialParts.join(', '),
                  'v3': parts.isEmpty
                      ? tr('미배정')
                      : widget.store.partRules
                            .where((r) => parts.contains(r.part))
                            .map((r) => r.part)
                            .join(', '),
                  'v4': enabled ? tr('활성화') : tr('비활성화'),
                },
              ),
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
                'parts': [
                  for (final rule in widget.store.partRules)
                    if (parts.contains(rule.part)) rule.part,
                ],
                'enabled': enabled,
                'assignedRole': role,
              });
              final next = await widget.session.assign(
                widget.sync.config,
                draft,
                request: request,
                expectedProjectId: projectId,
                expectedMember: request == null ? base : null,
                unifyParts: true,
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
                  dialogMessage = tr(
                    '변경 사항을 저장하지 못했습니다. 입력한 내용은 유지됩니다. {v0}',
                    args: {'v0': e},
                  );
                });
              }
            }
          }

          return DraftGuard(
            dirty: dirty(),
            busy: saving || adding,
            onSave: save,
            child: IeumDialog(
              title: Text(tr('{v0} · 참여자 설정', args: {'v0': person.name})),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${person.login} · ${widget.store.project!.name}',
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    Text(
                      '${participantKind(base)} · ${tr(memberStateLabels[memberState(base)]!)}',
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('참여 상태'),
                      style: WorkspaceUi.sectionStyleOf(context),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('member-enabled'),
                          onPressed:
                              !saving &&
                                  !adding &&
                                  !ownerTarget &&
                                  widget.store.actor.has('member.status')
                              ? () => update(() => enabled = true)
                              : null,
                          icon: Icon(
                            enabled
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 17,
                          ),
                          label: Text(tr('활성화')),
                        ),
                        OutlinedButton.icon(
                          key: const Key('member-disabled'),
                          onPressed:
                              !saving &&
                                  !adding &&
                                  !ownerTarget &&
                                  widget.store.actor.has('member.status')
                              ? () => update(() => enabled = false)
                              : null,
                          icon: Icon(
                            !enabled
                                ? Icons.check_circle
                                : Icons.circle_outlined,
                            size: 17,
                          ),
                          label: Text(tr('비활성화')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ownerTarget
                          ? tr('소유자의 관리자 권한과 활성 상태는 유지됩니다.')
                          : tr('비활성화하려면 남은 작업과 전송 중인 변경 사항을 먼저 인수인계해 주세요.'),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      tr('소속 파트'),
                      style: WorkspaceUi.sectionStyleOf(context),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final rule in widget.store.partRules)
                          FilterChip(
                            key: Key('member-part-${rule.part}'),
                            label: Text(rule.part),
                            selected: parts.contains(rule.part),
                            onSelected: saving || adding
                                ? null
                                : (selected) => update(() {
                                    if (selected) {
                                      parts.add(rule.part);
                                    } else {
                                      parts.remove(rule.part);
                                    }
                                  }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr('여러 파트에 소속될 수 있습니다. 작업을 전달할 때 파트 또는 담당자를 선택할 수 있습니다.'),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    const SizedBox(height: 16),
                    if (widget.store.actor.has('role.manage'))
                      TextButton.icon(
                        key: const Key('member-add-role'),
                        onPressed: saving || adding
                            ? null
                            : () async {
                                update(() => adding = true);
                                final before = widget.store.project!;
                                final expectedBase = before.unifiedParts
                                    ? base
                                    : ProjectManifest(
                                        before.id,
                                        before.name,
                                        before.ownerId,
                                        [base],
                                        roles: before.roles,
                                        parts: before.parts,
                                      ).partWorkflowView.people.single;
                                final created = await addRole();
                                if (ctx.mounted) {
                                  update(() {
                                    adding = false;
                                    if (created != null) {
                                      final latestBase = widget.store.people
                                          .where((p) => p.id == base.id)
                                          .firstOrNull;
                                      if (latestBase != null &&
                                          jsonEncode(latestBase.json) ==
                                              jsonEncode(expectedBase.json)) {
                                        base = latestBase;
                                        initialParts
                                          ..clear()
                                          ..addAll(base.parts);
                                      }
                                      parts.add(created.name);
                                    } else {
                                      dialogMessage = error;
                                    }
                                  });
                                }
                              },
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(tr('파트 추가')),
                      ),
                    if (dirty())
                      Text(
                        tr('저장되지 않은 변경 사항'),
                        style: WorkspaceUi.captionStyleOf(context),
                      ),
                    if (dialogMessage.isNotEmpty) ...[
                      Text(
                        dialogMessage,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
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
                                      throw StateError(
                                        tr('저장소 프로젝트가 변경되었습니다.'),
                                      );
                                    }
                                    final target = latest.people
                                        .where((p) => p.id == person.id)
                                        .firstOrNull;
                                    if (target == null) {
                                      throw StateError(tr('참여자가 삭제되었습니다.'));
                                    }
                                    if (ctx.mounted && mounted) {
                                      widget.store.updateProject(latest);
                                      update(() {
                                        base = target;
                                        dialogMessage = tr(
                                          '최신 정보를 불러왔습니다. 입력한 내용을 확인한 뒤 다시 저장해 주세요.',
                                        );
                                      });
                                    }
                                  } catch (e) {
                                    if (ctx.mounted) {
                                      update(() => dialogMessage = '$e');
                                    }
                                  }
                                },
                          child: Text(tr('최신 정보 불러오기')),
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
                  child: Text(tr('취소')),
                ),
                FilledButton(
                  key: const Key('save-member'),
                  onPressed: saving || adding || !dirty() ? null : save,
                  child: Text(
                    saving
                        ? tr('저장 중…')
                        : request == null
                        ? tr('저장')
                        : tr('참여 승인'),
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
      tr('참여 요청 거절'),
      tr(
        '{v0} 님의 참여 요청을 거절합니다. 이미 승인된 참여자의 설정은 변경되지 않습니다.',
        args: {'v0': request['member']['name']},
      ),
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
      if (mounted) error = tr('요청 거절 실패: {v0}', args: {'v0': e});
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
      selectionNotice = tr('선택한 참여자가 검색 결과에서 제외되어 상세를 닫았습니다.');
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
        title: Text(tr('참여자 상세')),
        width: 540,
        content: ListenableBuilder(
          listenable: widget.store,
          builder: (_, _) {
            final latest = widget.store.people
                .where((p) => p.id == person.id)
                .firstOrNull;
            return latest == null
                ? Text(tr('참여자가 더 이상 프로젝트에 없습니다.'))
                : detail(latest, close: () => Navigator.pop(ctx));
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('닫기')),
          ),
        ],
      ),
    );
    rowFocus[person.id]?.requestFocus();
  }

  Widget detail(
    Person person, {
    VoidCallback? close,
    bool dismissible = false,
  }) {
    final tasks = widget.store.tasks
        .where((t) => t.assigneeId == person.id || t.reviewerId == person.id)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: WorkspaceUi.colors(context).ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    '@${person.login}',
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ],
              ),
            ),
            if (dismissible)
              IconButton(
                key: const Key('close-participant-detail'),
                tooltip: tr('닫기'),
                onPressed: close,
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
          ],
        ),
        const SizedBox(height: 12),
        memberField(tr('권한'), participantKind(person)),
        memberField(tr('참여 상태'), tr(memberStateLabels[memberState(person)]!)),
        memberField(
          tr('파트'),
          person.parts.isEmpty ? tr('미배정') : person.parts.join(', '),
        ),
        if (person.id == widget.store.profileId ||
            person.id == widget.store.project!.ownerId)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              [
                if (person.id == widget.store.profileId) tr('본인'),
                if (person.id == widget.store.project!.ownerId) tr('프로젝트 소유자'),
              ].join(' · '),
              style: WorkspaceUi.captionStyleOf(context),
            ),
          ),
        const Divider(height: 28),
        Text(
          tr('관련 작업 {v0}건', args: {'v0': tasks.length}),
          style: WorkspaceUi.sectionStyleOf(context),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final status in widget.store.workflowStatuses.entries)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: WorkspaceUi.colors(context).surface,
                  border: Border.all(color: WorkspaceUi.colors(context).line),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${status.value} ${tasks.where((t) => t.status == status.key).length}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
        ),
        if (widget.onOpenTasks != null)
          TextButton.icon(
            onPressed: () {
              close?.call();
              widget.onOpenTasks!(person.id);
            },
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text(tr('관련 작업 보기')),
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
            child: Text(tr('파트 배정')),
          ),
      ],
    );
  }

  Widget toolbar(double width) {
    final heading = Text(
      tr('참여자 {v0}명', args: {'v0': widget.store.people.length}),
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: WorkspaceUi.colors(context).ink,
      ),
    );
    final actions = <Widget>[
      if (widget.store.owns)
        FilledButton.icon(
          key: const Key('team-invite'),
          onPressed: busy || offline ? null : invite,
          icon: const Icon(Icons.person_add_alt_1_outlined, size: 17),
          label: Text(tr('참여자 초대')),
        ),
      IconButton(
        key: const Key('team-refresh'),
        tooltip: tr('새로고침'),
        onPressed: busy ? null : refresh,
        icon: const Icon(Icons.refresh_rounded, size: 20),
      ),
      if (widget.store.actor.has('role.manage') || widget.store.owns)
        MenuAnchor(
          menuChildren: [
            if (widget.store.actor.has('role.manage'))
              MenuItemButton(
                key: const Key('team-add-role'),
                leadingIcon: const Icon(Icons.add_rounded, size: 18),
                onPressed: busy || offline ? null : addRole,
                child: Text(tr('파트 추가')),
              ),
            if (widget.store.owns)
              MenuItemButton(
                key: const Key('team-transfer'),
                leadingIcon: const Icon(Icons.swap_horiz_rounded, size: 18),
                onPressed: busy || offline ? null : transfer,
                child: Text(tr('관리자 권한 이전')),
              ),
          ],
          builder: (_, controller, _) => IconButton(
            key: const Key('team-more'),
            tooltip: tr('더보기'),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ),
    ];
    if (width < 440) {
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
      children: [
        Expanded(child: heading),
        const SizedBox(width: 16),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }

  Widget memberField(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(label, style: WorkspaceUi.captionStyleOf(context)),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );

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
                Text(tr('본인'), style: TextStyle(fontSize: 11)),
              if (person.id == widget.store.project!.ownerId)
                Text(tr('소유자'), style: TextStyle(fontSize: 11)),
            ],
          ),
          Text('@${person.login}', style: const TextStyle(fontSize: 11)),
        ],
      );
      return Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.zero,
          side: BorderSide(color: WorkspaceUi.colors(context).line, width: .5),
        ),
        elevation: 0,
        color: selected == person.id
            ? WorkspaceUi.colors(context).accentSurface
            : WorkspaceUi.colors(context).surface,
        child: ListTile(
          key: Key('participant-${person.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          horizontalTitleGap: 16,
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
                        participantKind(person),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: Text(
                        tr(memberStateLabels[memberState(person)]!),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: Text(
                        person.parts.isEmpty
                            ? tr('미배정')
                            : person.parts.join(', '),
                        style: const TextStyle(fontSize: 11, height: 1.6),
                      ),
                    ),
                  ],
                )
              : identity,
          subtitle: columns
              ? null
              : Text(
                  tr(
                    '{v0} · {v1} · {v2}',
                    args: {
                      'v0': participantKind(person),
                      'v1': tr(memberStateLabels[memberState(person)]!),
                      'v2': person.parts.isEmpty
                          ? tr('파트 미배정')
                          : person.parts.join(', '),
                    },
                  ),
                  style: const TextStyle(fontSize: 11, height: 1.7),
                ),
          trailing: MenuAnchor(
            menuChildren: [
              MenuItemButton(
                onPressed: () => openDetail(person, wide),
                child: Text(tr('참여자 상세')),
              ),
              if (canAssignMember(
                    widget.store.actor,
                    person,
                    widget.store.project!.ownerId,
                  ) &&
                  person.role != 'pending')
                MenuItemButton(
                  onPressed: busy || offline ? null : () => assign(person),
                  child: Text(tr('파트 배정')),
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
                  child: Text(person.enabled ? tr('비활성화') : tr('활성화')),
                ),
              ],
            ],
            builder: (_, controller, _) => IconButton(
              key: Key('member-actions-${person.id}'),
              tooltip: tr('{v0} 더보기', args: {'v0': person.name}),
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
          toolbar(constraints.maxWidth),
          const SizedBox(height: 12),
          if (busy)
            const LinearProgressIndicator(key: Key('participants-loading')),
          if (error.isNotEmpty)
            Text(
              trError(error),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (checkedAt != null)
            Text(
              tr(
                '최근 새로고침 {v0}:{v1}{v2}',
                args: {
                  'v0': checkedAt!.toLocal().hour.toString().padLeft(2, '0'),
                  'v1': checkedAt!.toLocal().minute.toString().padLeft(2, '0'),
                  'v2': offline ? tr(' · 연결을 확인해 주세요.') : '',
                },
              ),
              style: WorkspaceUi.captionStyleOf(context),
            ),
          if (!widget.store.actor.has('member.manage'))
            Text(
              tr('참여자를 변경하려면 참여자 관리 권한이 필요합니다.'),
              style: WorkspaceUi.captionStyleOf(context),
            ),
          const SizedBox(height: 16),
          WorkspacePanel(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, bounds) => Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: bounds.maxWidth < 720
                        ? bounds.maxWidth
                        : bounds.maxWidth - 404,
                    height: WorkspaceUi.controlHeight,
                    child: TextField(
                      key: const Key('participant-search'),
                      controller: searchController,
                      decoration: InputDecoration(
                        hintText: tr('이름 또는 GitHub 사용자 이름'),
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
                      onChanged: (value) => updateFilters(() => query = value),
                    ),
                  ),
                  SizedBox(
                    width: bounds.maxWidth < 420
                        ? bounds.maxWidth
                        : bounds.maxWidth < 720
                        ? (bounds.maxWidth - 96) / 2
                        : 150,
                    height: WorkspaceUi.controlHeight,
                    child: IeumSelect(
                      key: const Key('participant-state-filter'),
                      value: stateFilter,
                      values: {
                        '': tr('모든 상태'),
                        ...translatedLabels(memberStateLabels),
                      },
                      onChanged: (value) =>
                          updateFilters(() => stateFilter = value),
                    ),
                  ),
                  SizedBox(
                    width: bounds.maxWidth < 420
                        ? bounds.maxWidth
                        : bounds.maxWidth < 720
                        ? (bounds.maxWidth - 96) / 2
                        : 150,
                    height: WorkspaceUi.controlHeight,
                    child: IeumSelect(
                      key: const Key('participant-part-filter'),
                      value: partFilter,
                      values: {
                        '': tr('모든 파트'),
                        for (final p in widget.store.people)
                          for (final part in p.parts) part: part,
                      },
                      onChanged: (value) =>
                          updateFilters(() => partFilter = value),
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    height: WorkspaceUi.controlHeight,
                    child: TextButton(
                      key: const Key('participant-filter-reset'),
                      onPressed:
                          query.isEmpty &&
                              roleFilter.isEmpty &&
                              stateFilter.isEmpty &&
                              partFilter.isEmpty
                          ? null
                          : resetFilters,
                      child: Text(tr('초기화')),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              '{v0}명 표시 · 전체 {v1}명',
              args: {'v0': result.length, 'v1': widget.store.people.length},
            ),
            key: const Key('participant-result-count'),
            style: WorkspaceUi.captionStyleOf(context),
          ),
          const SizedBox(height: 10),
          if (selectionNotice.isNotEmpty) Text(selectionNotice),
          if (result.isEmpty)
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(tr('검색 결과가 없습니다. 검색어와 필터를 초기화하세요.')),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: WorkspacePanel(
                  padding: EdgeInsets.zero,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(WorkspaceUi.radius),
                    child: LayoutBuilder(
                      builder: (context, bounds) => Column(
                        children: [
                          if (bounds.maxWidth >= 620)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 80, 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      tr('참여자'),
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      tr('권한'),
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 2,
                                    child: Text(
                                      tr('참여 상태'),
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      tr('파트'),
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
                ),
              ),
              if (wide && person != null) ...[
                const SizedBox(width: 16),
                SizedBox(
                  width: 300,
                  child: WorkspacePanel(
                    padding: const EdgeInsets.all(16),
                    child: detail(
                      person,
                      close: () => closeDetail(person.id),
                      dismissible: true,
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.store.actor.has('member.manage')) ...[
            const Divider(height: 28),
            Text(tr('참여 요청'), style: WorkspaceUi.sectionStyleOf(context)),
            const SizedBox(height: 12),
            for (final warning in widget.session.requestWarnings)
              Text(
                warning,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            if (!busy && requests.isEmpty)
              Text(
                tr('대기 중인 참여 요청이 없습니다.'),
                style: WorkspaceUi.captionStyleOf(context),
              ),
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
                      child: Text(tr('파트 배정 후 승인')),
                    ),
                    TextButton(
                      onPressed: busy || offline ? null : () => reject(request),
                      child: Text(tr('거절')),
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
