import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'popup_ui.dart';
import 'store.dart';
import 'task_handoff.dart';

const _purposeLabels = {'work': '작성', 'review': '검토', 'revision': '수정'};

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
          title: Text(
            plan.transitionName.isEmpty ? '작업 전달 확인' : '${plan.buttonLabel} 확인',
          ),
          icon: Icons.arrow_forward,
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
              if (plan.requiresRecipient) ...[
                const SizedBox(height: 18),
                IgnorePointer(
                  ignoring: !current,
                  child: Opacity(
                    opacity: current ? 1 : .55,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        IeumSelect(
                          key: const Key('task-handoff-receiver-group'),
                          label: '받는 파트',
                          icon: Icons.groups_outlined,
                          value: plan.receiverGroup,
                          values: {
                            '': '개별 담당자 선택',
                            ...plan.receiverGroupOptions,
                          },
                          onChanged: (group) => selectReceiver(group, ''),
                        ),
                        const SizedBox(height: 12),
                        IeumSelect(
                          key: const Key('task-handoff-receiver-person'),
                          label: '받는 담당자',
                          icon: Icons.person_outline_rounded,
                          value: plan.receiverPerson,
                          values: {
                            '': plan.receiverGroup.isEmpty
                                ? '담당자를 선택하세요'
                                : '${plan.receiverGroupOptions[plan.receiverGroup] ?? '파트'} 전체',
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
                      ? '상태를 유지하고 담당자만 변경합니다. 코멘트와 전달 이력이 함께 남습니다.'
                      : '선택한 대상의 ${plan.destinationName} 단계로 전달됩니다. 코멘트와 전달 이력이 함께 남습니다.',
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
                  title: const Text('잠근 채 전달', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    plan.lockOnHandoff
                        ? '특정 담당자 한 명을 선택하세요. 받는 담당자만 수정할 수 있습니다.'
                        : '잠금 없이 전달하면 모든 활성 참여자가 수정할 수 있습니다.',
                    style: const TextStyle(fontSize: 11),
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
                    label: '처리 목적',
                    icon: Icons.assignment_outlined,
                    value: plan.purpose.isEmpty ? 'work' : plan.purpose,
                    values: _purposeLabels,
                    onChanged: (value) => setState(() {
                      selectedPlan = selectedPlan.withPurpose(value);
                    }),
                  ),
                ),
              ],
              if (plan.isCompletion) ...[
                const SizedBox(height: 14),
                const Text(
                  '완료하면 작업 전체의 처리가 끝납니다. 최종 결과를 확인한 뒤 완료하세요.',
                  key: Key('task-handoff-completion-help'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xff6e687b),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xfff7f5fb),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.routeLabel,
                      key: const Key('task-handoff-route'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '다음 처리: ${plan.recipientLabel}',
                      key: const Key('task-handoff-recipient'),
                      style: const TextStyle(fontSize: 13, height: 1.5),
                    ),
                    if (!plan.canSelectPurpose && plan.purpose.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        '처리 목적: ${_purposeLabels[plan.purpose] ?? plan.purpose}',
                        key: const Key('task-handoff-purpose-summary'),
                        style: const TextStyle(fontSize: 12, height: 1.5),
                      ),
                    ],
                  ],
                ),
              ),
              if (plan.maintainsStatus) ...[
                const SizedBox(height: 12),
                const Text(
                  '담당자 배정은 내 할 일과 알림에 적용됩니다. 잠금이 없으면 다른 활성 참여자도 작업 내용을 수정할 수 있습니다.',
                  key: Key('task-handoff-collaboration-help'),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: Color(0xff6e687b),
                  ),
                ),
              ],
              if (plan.editWarning.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  plan.editWarning,
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
                        ? '반려 코멘트 · 필수'
                        : plan.needsComment
                        ? '코멘트 · 필수'
                        : '코멘트 · 선택',
                    hintText: plan.isRejection
                        ? '보완할 내용을 입력하세요.'
                        : '전달할 내용을 입력하세요.',
                  ),
                ),
              ],
              if (!current) ...[
                const SizedBox(height: 16),
                const Text(
                  '작업 또는 프로젝트 설정이 변경되었습니다. 다시 확인하세요.',
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
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('task-handoff-confirm'),
              onPressed:
                  current &&
                      plan.hasRecipientSelection &&
                      (!plan.needsComment || comment.text.trim().isNotEmpty)
                  ? confirm
                  : null,
              child: const Text('최종 확인'),
            ),
          ],
        );
      },
    ),
  );
}
