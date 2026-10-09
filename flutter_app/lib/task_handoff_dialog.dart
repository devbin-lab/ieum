import 'app_localizations.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'popup_ui.dart';
import 'store.dart';
import 'task_handoff.dart';
import 'workspace_ui.dart';

const _purposeLabels = {'work': '작업', 'review': '검토', 'revision': '수정'};

class TaskHandoffConfirmation {
  const TaskHandoffConfirmation(this.plan, this.reason);
  final TaskHandoffPlan plan;
  final String reason;
}

Future<TaskHandoffConfirmation?> showTaskHandoffDialog(
  BuildContext context, {
  required TaskHandoffPlan plan,
  required TaskStore store,
}) async {
  var selected = plan;
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => TaskHandoffDialog(
      plan: plan,
      store: store,
      onPlanSelected: (value) => selected = value,
    ),
  );
  return reason == null ? null : TaskHandoffConfirmation(selected, reason);
}

/// Reviews a prepared transfer. The caller commits only after a non-null result.
class TaskHandoffDialog extends StatefulWidget {
  const TaskHandoffDialog({
    super.key,
    required this.plan,
    required this.store,
    this.onPlanSelected,
  });
  final TaskHandoffPlan plan;
  final TaskStore store;
  final ValueChanged<TaskHandoffPlan>? onPlanSelected;

  @override
  State<TaskHandoffDialog> createState() => _TaskHandoffDialogState();
}

class _TaskHandoffDialogState extends State<TaskHandoffDialog> {
  final comment = TextEditingController();
  final initialFocus = FocusNode(debugLabel: 'handoff-review');
  bool confirmed = false;
  bool invalidated = false;
  late TaskHandoffPlan selectedPlan;

  @override
  void initState() {
    super.initState();
    selectedPlan = widget.plan;
  }

  void selectReceiver(String group, String person) => setState(() {
    selectedPlan = selectedPlan.withReceiver(group, person);
  });

  @override
  void dispose() {
    comment.dispose();
    initialFocus.dispose();
    super.dispose();
  }

  void confirm() {
    if (confirmed) return;
    if (!selectedPlan.hasRecipientSelection) return;
    if (!widget.store.isHandoffCurrent(selectedPlan)) {
      setState(() => invalidated = true);
      return;
    }
    final reason = comment.text.trim();
    if (selectedPlan.needsComment && reason.isEmpty) return;
    confirmed = true;
    widget.onPlanSelected?.call(selectedPlan);
    Navigator.pop(context, reason);
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: initialFocus,
    autofocus: true,
    onKeyEvent: (node, event) =>
        node.hasPrimaryFocus &&
            (event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter)
        ? KeyEventResult.handled
        : KeyEventResult.ignored,
    child: AnimatedBuilder(
      animation: widget.store,
      builder: (context, _) {
        final plan = selectedPlan;
        final current = !invalidated && widget.store.isHandoffCurrent(plan);
        return IeumDialog(
          title: Text(plan.requiresRecipient ? tr('작업 전달') : tr('상태 변경')),
          closeTooltip: tr('확인 창 닫기'),
          icon: plan.requiresRecipient
              ? Icons.arrow_forward_rounded
              : Icons.swap_horiz_rounded,
          width: 480,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                plan.title,
                key: const Key('task-handoff-title'),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: WorkspaceUi.colors(context).subtle,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.swap_horiz_rounded,
                      size: 17,
                      color: WorkspaceUi.colors(context).muted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        plan.maintainsStatus
                            ? tr(
                                '{v0} 유지',
                                args: {
                                  'v0': trStageName(
                                    plan.sourceId,
                                    plan.sourceName,
                                  ),
                                },
                              )
                            : '${trStageName(plan.sourceId, plan.sourceName)} → ${trStageName(plan.destinationId, plan.destinationName)}',
                        key: const Key('task-handoff-route'),
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (plan.requiresRecipient) ...[
                const SizedBox(height: 24),
                WorkspaceSectionLabel(title: tr('전달 대상')),
                const SizedBox(height: 12),
                IgnorePointer(
                  ignoring: !current,
                  child: Opacity(
                    opacity: current ? 1 : .55,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        IeumSelect(
                          key: const Key('task-handoff-receiver-group'),
                          label: tr('파트'),
                          icon: Icons.groups_outlined,
                          value: plan.receiverGroup,
                          values: {
                            '': tr('전체 파트'),
                            ...plan.receiverGroupOptions,
                          },
                          onChanged: (group) => selectReceiver(group, ''),
                        ),
                        const SizedBox(height: 12),
                        IeumSelect(
                          key: const Key('task-handoff-receiver-person'),
                          label: tr('담당자'),
                          icon: Icons.person_outline_rounded,
                          value: plan.receiverPerson,
                          values: {
                            '': plan.receiverGroup.isEmpty
                                ? tr('담당자를 선택하세요')
                                : tr(
                                    '{v0} 전체',
                                    args: {
                                      'v0':
                                          plan.receiverGroupOptions[plan
                                              .receiverGroup] ??
                                          tr('파트'),
                                    },
                                  ),
                            ...plan.availableReceiverPeople,
                          },
                          onChanged: (person) =>
                              selectReceiver(plan.receiverGroup, person),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  plan.maintainsStatus
                      ? tr('작업 상태를 유지한 채 담당자에게 전달합니다.')
                      : tr(
                          '{v0} 상태로 변경하고 담당자에게 전달합니다.',
                          args: {
                            'v0': trStageName(
                              plan.destinationId,
                              plan.destinationName,
                            ),
                          },
                        ),
                  key: const Key('task-handoff-recipient-help'),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xff6e687b),
                  ),
                ),
              ],
              if (plan.requiresRecipient) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const Key('task-handoff-lock'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(
                    tr('받는 담당자만 수정 허용'),
                    style: TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    plan.lockOnHandoff
                        ? tr('담당자를 한 명 선택하면 작업이 잠깁니다.')
                        : tr('잠금 없이 전달하면 모든 참여자가 수정할 수 있습니다.'),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                  value: plan.lockOnHandoff,
                  onChanged: current
                      ? (value) => setState(() {
                          selectedPlan = selectedPlan.withLock(value ?? false);
                        })
                      : null,
                ),
              ],
              if (plan.canSelectPurpose) ...[
                const SizedBox(height: 16),
                IgnorePointer(
                  ignoring: !current,
                  child: IeumSelect(
                    key: const Key('task-handoff-purpose'),
                    label: tr('요청 유형'),
                    icon: Icons.assignment_outlined,
                    value: plan.purpose.isEmpty ? 'work' : plan.purpose,
                    values: translatedLabels(_purposeLabels),
                    onChanged: (value) => setState(() {
                      selectedPlan = selectedPlan.withPurpose(value);
                    }),
                  ),
                ),
              ],
              if (plan.isCompletion) ...[
                const SizedBox(height: 14),
                Text(
                  tr('작업을 완료합니다. 최종 결과를 확인하세요.'),
                  key: Key('task-handoff-completion-help'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xff6e687b),
                  ),
                ),
              ],
              if (plan.requiresRecipient ||
                  !plan.canSelectPurpose && plan.purpose.isNotEmpty) ...[
                const SizedBox(height: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (plan.requiresRecipient)
                      Text(
                        tr('담당자 · {v0}', args: {'v0': plan.recipientLabel}),
                        key: const Key('task-handoff-recipient'),
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    if (!plan.canSelectPurpose && plan.purpose.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        tr(
                          '요청 유형 · {v0}',
                          args: {
                            'v0': tr(
                              _purposeLabels[plan.purpose] ?? plan.purpose,
                            ),
                          },
                        ),
                        key: const Key('task-handoff-purpose-summary'),
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ],
                  ],
                ),
              ],
              if (plan.editWarning.isNotEmpty && !plan.requiresRecipient) ...[
                const SizedBox(height: 16),
                Text(
                  trError(plan.editWarning),
                  key: const Key('task-handoff-edit-warning'),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xff9b6b2a),
                  ),
                ),
              ],
              ...[
                const SizedBox(height: 18),
                TextField(
                  key: const Key('rework-reason'),
                  controller: comment,
                  enabled: current,
                  minLines: 3,
                  maxLines: 4,
                  maxLength: 2000,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: plan.isRejection
                        ? tr('반려 사유 · 필수')
                        : plan.needsComment
                        ? tr('댓글 · 필수')
                        : tr('댓글 · 선택'),
                    hintText: plan.isRejection
                        ? tr('보완할 내용을 입력하세요.')
                        : tr('함께 전달할 내용을 입력하세요.'),
                  ),
                ),
              ],
              if (!current) ...[
                const SizedBox(height: 16),
                Text(
                  tr('작업 정보가 변경되었습니다. 창을 닫고 다시 시도하세요.'),
                  key: Key('task-handoff-stale'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xffa0445a),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              key: const Key('task-handoff-cancel'),
              onPressed: () => Navigator.pop(context),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const Key('task-handoff-confirm'),
              onPressed:
                  current &&
                      plan.hasRecipientSelection &&
                      (!plan.needsComment || comment.text.trim().isNotEmpty)
                  ? confirm
                  : null,
              child: Text(
                plan.requiresRecipient
                    ? tr('전달')
                    : plan.isCompletion
                    ? tr('완료')
                    : tr('변경'),
              ),
            ),
          ],
        );
      },
    ),
  );
}
