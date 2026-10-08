import 'package:flutter/material.dart';

import 'app.dart' show muted;
import 'models.dart';
import 'store.dart';
import 'popup_ui.dart';
import 'draft_guard.dart';

class TaskEditor extends StatefulWidget {
  final TaskStore store;
  final WorkTask? task;
  final DateTime? initialDate;
  const TaskEditor({
    super.key,
    required this.store,
    this.task,
    this.initialDate,
  });
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
  bool lockOnCreate = false;
  String get draft => [
    title.text,
    assigned.text,
    due.text,
    description.text,
    part,
    priority,
    assigneeId,
    reviewerId,
    lockOnCreate.toString(),
  ].join('\u0000');
  bool get dirty => !saved && draft != initialDraft;
  WorkTask? get currentTask =>
      widget.task == null ? null : widget.store.find(widget.task!.id);
  bool get contentEditable => currentTask == null
      ? widget.store.canCreate
      : widget.store.canEditContent(currentTask!);
  bool get assignmentEditable => contentEditable;

  bool get canSave => currentTask == null
      ? widget.store.canCreate && part.isNotEmpty
      : widget.store.canEdit(currentTask!);
  bool get assigneeEditable => assignmentEditable;
  @override
  void initState() {
    super.initState();
    final t = widget.task;
    title = TextEditingController(text: t?.title ?? '');
    final date = widget.initialDate == null
        ? ''
        : widget.initialDate!.toIso8601String().substring(0, 10);
    assigned = TextEditingController(
      text: t?.assignedDate ?? (date.isEmpty ? localDate() : date),
    );
    due = TextEditingController(text: t?.dueDate ?? date);
    description = TextEditingController(text: t?.description ?? '');
    part = t?.part ?? widget.store.partRules.firstOrNull?.part ?? '';
    priority = t?.priority ?? 'normal';
    assigneeId =
        t?.assigneeId ??
        widget.store.partRules.firstOrNull?.assigneeId ??
        widget.store.profileId;
    reviewerId =
        t?.reviewerId ??
        widget.store.partRules.firstOrNull?.reviewerId ??
        widget.store.profileId;
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
    ignoring: !(key == 'task-assignee' ? assigneeEditable : assignmentEditable),
    child: Opacity(
      opacity: (key == 'task-assignee' ? assigneeEditable : assignmentEditable)
          ? 1
          : 0.65,
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
        if (widget.task == null)
          'lockedBy': lockOnCreate ? widget.store.profileId : '',
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
                    widget.store.editLockReason(currentTask!),
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
              if (widget.task == null && widget.store.partRules.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    '프로젝트 설정의 파트 탭에서 파트를 먼저 추가하세요.',
                    style: TextStyle(fontSize: 12, color: muted),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: select(
                      'task-part',
                      '담당 파트',
                      part,
                      {
                        if (widget.task != null &&
                            !widget.store.partRules.any(
                              (r) => r.part == widget.task!.part,
                            ))
                          widget.task!.part: '${widget.task!.part} (삭제된 파트)',
                        for (final r in widget.store.partRules) r.part: r.part,
                      },
                      (v) {
                        part = v;
                        final rule = widget.store.partRules
                            .where((r) => r.part == v)
                            .firstOrNull;
                        if (rule == null) return;
                        if (assigneeEditable) assigneeId = rule.assigneeId;
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
                    child: select(
                      'task-assignee',
                      widget.task == null ? '첫 담당자' : '등록 담당자',
                      assigneeId,
                      {
                        for (final p in widget.store.people.where(
                          (p) => p.canWork,
                        ))
                          p.id: p.name,
                      },
                      (v) => assigneeId = v,
                    ),
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
              Text(
                widget.task == null
                    ? '첫 담당자를 지정합니다. 이후에는 전달 버튼으로 다음 담당자를 선택할 수 있습니다.'
                    : '등록 담당자는 최초 배정 정보입니다. 현재 담당자를 변경하려면 전달 버튼을 사용하세요.',
                key: const Key('task-editor-assignment-help'),
                style: TextStyle(fontSize: 10, color: muted),
              ),
              if (currentTask != null) ...[
                const SizedBox(height: 9),
                Text(
                  '현재 담당자 · ${widget.store.currentActorLabel(currentTask!)}',
                  key: const Key('task-editor-current-assignee'),
                  style: TextStyle(fontSize: 11, color: muted),
                ),
              ],
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
              if (widget.task == null && widget.store.isProject)
                CheckboxListTile(
                  key: const Key('task-create-lock'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '등록 후 내 작업으로 잠금',
                    style: TextStyle(fontSize: 12),
                  ),
                  subtitle: const Text(
                    '다른 참여자는 열람과 코멘트만 가능합니다.',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: lockOnCreate,
                  onChanged: (value) =>
                      setState(() => lockOnCreate = value ?? false),
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
