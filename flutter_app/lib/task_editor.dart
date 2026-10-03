import 'package:flutter/material.dart';

import 'app.dart' show muted;
import 'models.dart';
import 'store.dart';
import 'popup_ui.dart';
import 'draft_guard.dart';

class ReworkDialog extends StatefulWidget {
  const ReworkDialog({super.key});
  @override
  State<ReworkDialog> createState() => _ReworkDialogState();
}

class _ReworkDialogState extends State<ReworkDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IeumDialog(
    title: const Text('재작업 요청'),
    icon: Icons.rate_review_outlined,
    content: SizedBox(
      width: 400,
      child: TextField(
        key: const Key('rework-reason'),
        controller: controller,
        autofocus: true,
        maxLines: 4,
        maxLength: 2000,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(labelText: '재작업 사유'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.maybePop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: controller.text.trim().isEmpty
            ? null
            : () => Navigator.pop(context, controller.text),
        child: const Text('재작업 요청'),
      ),
    ],
  );
}

class TaskEditor extends StatefulWidget {
  final TaskStore store;
  final WorkTask? task;
  const TaskEditor({super.key, required this.store, this.task});
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  final formKey = GlobalKey<FormState>();
  late TextEditingController title, assigned, due, description;
  late String part, priority, assigneeId, reviewerId;
  String error = '';
  String initialDraft = '';
  bool saved = false;
  String get draft => [
    title.text,
    assigned.text,
    due.text,
    description.text,
    part,
    priority,
    assigneeId,
    reviewerId,
  ].join('\u0000');
  bool get dirty => !saved && draft != initialDraft;
  WorkTask? get currentTask =>
      widget.task == null ? null : widget.store.find(widget.task!.id);
  bool get contentEditable => currentTask == null
      ? widget.store.canCreate
      : widget.store.canEditContent(currentTask!);
  bool get assignmentEditable =>
      currentTask?.status != 'done' &&
      (!widget.store.isProject ||
          (widget.task == null
              ? widget.store.canCreate
              : widget.store.actor.has('task.assign')));
  bool get canSave => currentTask == null
      ? widget.store.canCreate
      : widget.store.canEdit(currentTask!);
  @override
  void initState() {
    super.initState();
    final t = widget.task;
    title = TextEditingController(text: t?.title ?? '');
    assigned = TextEditingController(text: t?.assignedDate ?? localDate());
    due = TextEditingController(text: t?.dueDate ?? '');
    description = TextEditingController(text: t?.description ?? '');
    part = t?.part ?? widget.store.partRules.first.part;
    priority = t?.priority ?? 'normal';
    assigneeId = t?.assigneeId ?? widget.store.partRules.first.assigneeId;
    reviewerId = t?.reviewerId ?? widget.store.partRules.first.reviewerId;
    initialDraft = draft;
    for (final c in [title, assigned, due, description]) {
      c.addListener(() {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    for (final c in [title, assigned, due, description]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> date(TextEditingController c) async {
    final current = DateTime.tryParse(c.text) ?? DateTime.now();
    final result = await showDialog<DateTime>(
      context: context,
      builder: (_) => IeumDateDialog(initialDate: current),
    );
    if (result != null && mounted) {
      c.text =
          '${result.year.toString().padLeft(4, '0')}-${result.month.toString().padLeft(2, '0')}-${result.day.toString().padLeft(2, '0')}';
    }
  }

  Widget select(
    String key,
    String label,
    String value,
    Map<String, String> values,
    ValueChanged<String> change,
  ) => IgnorePointer(
    ignoring: !assignmentEditable,
    child: Opacity(
      opacity: assignmentEditable ? 1 : 0.65,
      child: IeumSelect(
        key: ValueKey('$key-$value'),
        value: value,
        label: label,
        values: values,
        colors: key == 'task-priority'
            ? const {
                'high': Color(0xffbe8951),
                'normal': Color(0xff7963d5),
                'low': Color(0xff7b9b84),
              }
            : key == 'task-assignee' || key == 'task-reviewer'
            ? {for (final m in widget.store.people) m.id: Color(m.color)}
            : const {},
        onChanged: (v) => setState(() => change(v)),
      ),
    ),
  );
  Future<void> save() async {
    if (!formKey.currentState!.validate()) return;
    try {
      widget.store.save({
        if (widget.task != null) 'id': widget.task!.id,
        'title': title.text,
        'part': part,
        'priority': priority,
        'assigneeId': assigneeId,
        'reviewerId': reviewerId,
        'assignedDate': assigned.text,
        'dueDate': due.text,
        'description': description.text,
      }, expectedVersion: widget.task?.version);
      setState(() => saved = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => DraftGuard(
      dirty: dirty,
      onSave: save,
      child: IeumDialog(
        width: 560,
        closeTooltip: '작업 등록 닫기',
        icon: Icons.assignment_outlined,
        title: Text(
          widget.task == null
              ? '새 작업 등록'
              : canSave
              ? '작업 수정'
              : '작업 내용',
        ),
        content: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (currentTask != null && !contentEditable)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    '${widget.store.editLockReason(currentTask!)}'
                    '${assignmentEditable && currentTask!.status == 'review' ? '\n관리자는 담당자와 검토자, 일정을 조정할 수 있습니다.' : ''}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: muted,
                      height: 1.5,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              TextFormField(
                key: const Key('task-title'),
                controller: title,
                autofocus: contentEditable,
                readOnly: !contentEditable,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: '작업내용',
                  hintText: '어떤 작업을 진행하나요?',
                  counterText: '',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? '작업내용을 입력하세요.'
                    : null,
              ),
              const SizedBox(height: 19),
              Row(
                children: [
                  Expanded(
                    child: select(
                      'task-part',
                      '담당 파트',
                      part,
                      {for (final r in widget.store.partRules) r.part: r.part},
                      (v) {
                        part = v;
                        final rule = widget.store.partRules.firstWhere(
                          (r) => r.part == v,
                        );
                        assigneeId = rule.assigneeId;
                        reviewerId = rule.reviewerId;
                      },
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: select(
                      'task-priority',
                      '우선순위',
                      priority,
                      priorities,
                      (v) => priority = v,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 19),
              Row(
                children: [
                  Expanded(
                    child: select('task-assignee', '담당자', assigneeId, {
                      for (final p in widget.store.people.where(
                        (p) => p.canWork,
                      ))
                        p.id: p.name,
                    }, (v) => assigneeId = v),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: select('task-reviewer', '검토자', reviewerId, {
                      for (final p in widget.store.people.where(
                        (p) => p.canReview,
                      ))
                        p.id: p.name,
                    }, (v) => reviewerId = v),
                  ),
                ],
              ),
              const SizedBox(height: 19),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('task-assigned'),
                      controller: assigned,
                      readOnly: !assignmentEditable,
                      decoration: InputDecoration(
                        labelText: '작업 지정일',
                        hintText: 'YYYY-MM-DD',
                        suffixIcon: IconButton(
                          onPressed: !assignmentEditable
                              ? null
                              : () => date(assigned),
                          icon: const Icon(
                            Icons.calendar_month_outlined,
                            size: 16,
                          ),
                        ),
                      ),
                      validator: (v) {
                        try {
                          validDate(v, '작업 지정일', required: true);
                          return null;
                        } catch (_) {
                          return 'YYYY-MM-DD 형식을 확인하세요.';
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: TextFormField(
                      key: const Key('task-due'),
                      controller: due,
                      readOnly: !assignmentEditable,
                      decoration: InputDecoration(
                        labelText: '마감일',
                        hintText: 'YYYY-MM-DD',
                        suffixIcon: IconButton(
                          onPressed: !assignmentEditable
                              ? null
                              : () => date(due),
                          icon: const Icon(
                            Icons.calendar_month_outlined,
                            size: 16,
                          ),
                        ),
                      ),
                      validator: (v) {
                        try {
                          validDate(v, '마감일');
                          return null;
                        } catch (_) {
                          return 'YYYY-MM-DD 형식을 확인하세요.';
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 13),
              const Text(
                '파트를 선택하면 기본 담당자와 검토자가 자동 배정됩니다.',
                style: TextStyle(fontSize: 10, color: muted),
              ),
              const SizedBox(height: 22),
              TextFormField(
                key: const Key('task-description'),
                controller: description,
                readOnly: !contentEditable,
                maxLines: 3,
                maxLength: 10000,
                decoration: const InputDecoration(
                  labelText: '설명',
                  hintText: '완료 조건이나 참고 내용을 적어 주세요.',
                  counterText: '',
                ),
              ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: Text(
                    error,
                    style: const TextStyle(fontSize: 12, color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('task-save'),
            onPressed: canSave ? save : () => Navigator.maybePop(context),
            child: Text(canSave ? '작업 저장' : '닫기'),
          ),
        ],
      ),
    ),
  );
}
