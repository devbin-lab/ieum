import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';
import 'popup_ui.dart';
import 'workspace_ui.dart';
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
  String createLock = '';
  String get draft => [
    title.text,
    assigned.text,
    due.text,
    description.text,
    part,
    priority,
    assigneeId,
    reviewerId,
    createLock,
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
          'lockedBy': createLock == 'creator'
              ? widget.store.profileId
              : createLock == 'assignee'
              ? assigneeId
              : '',
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
      setState(() => error = trError(e));
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
        closeTooltip: widget.task == null ? tr('새 작업 창 닫기') : tr('작업 수정 창 닫기'),
        icon: Icons.assignment_outlined,
        title: Text(
          widget.task == null
              ? tr('새 작업')
              : canSave
              ? tr('작업 수정')
              : tr('작업 내용'),
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
                    trError(trError(widget.store.editLockReason(currentTask!))),
                    style: TextStyle(
                      fontSize: 12,
                      color: WorkspaceUi.colors(context).muted,
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
                decoration: InputDecoration(
                  labelText: tr('작업 제목'),
                  hintText: tr('어떤 작업을 진행하나요?'),
                  counterText: '',
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? tr('제목을 입력하세요.')
                    : null,
              ),
              const SizedBox(height: 19),
              TextFormField(
                key: const Key('task-description'),
                controller: description,
                readOnly: !contentEditable,
                maxLines: 3,
                maxLength: 10000,
                decoration: InputDecoration(
                  labelText: tr('설명'),
                  hintText: tr('작업 내용과 완료 기준을 입력하세요.'),
                  helperText: tr('Markdown 문법을 사용할 수 있습니다.'),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 22),
              WorkspaceSectionLabel(title: tr('담당')),
              const SizedBox(height: 14),
              if (widget.task == null && widget.store.partRules.isEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    tr('프로젝트 설정에서 파트를 추가한 후 작업을 만들 수 있습니다.'),
                    style: TextStyle(
                      fontSize: 12,
                      color: WorkspaceUi.colors(context).muted,
                    ),
                  ),
                ),
              Row(
                children: [
                  Expanded(
                    child: select(
                      'task-part',
                      tr('담당 파트'),
                      part,
                      {
                        if (widget.task != null &&
                            !widget.store.partRules.any(
                              (r) => r.part == widget.task!.part,
                            ))
                          widget.task!.part: tr(
                            '{v0} (삭제된 파트)',
                            args: {'v0': widget.task!.part},
                          ),
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
                    child: widget.task == null
                        ? select('task-assignee', tr('담당자'), assigneeId, {
                            for (final p in widget.store.people.where(
                              (p) => p.canWork,
                            ))
                              p.id: p.name,
                          }, (v) => assigneeId = v)
                        : InputDecorator(
                            decoration: InputDecoration(labelText: tr('담당자')),
                            child: Text(
                              widget.store.currentActorLabel(currentTask!),
                            ),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.task == null
                    ? tr('전달 기능으로 담당자를 변경할 수 있습니다.')
                    : tr('담당자는 작업 상세의 전달 기능으로 변경할 수 있습니다.'),
                key: const Key('task-editor-assignment-help'),
                style: TextStyle(
                  fontSize: 11,
                  color: WorkspaceUi.colors(context).muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              WorkspaceSectionLabel(title: tr('일정')),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const Key('task-assigned'),
                      controller: assigned,
                      readOnly: !assignmentEditable,
                      decoration: InputDecoration(
                        labelText: tr('시작일'),
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
                          validDate(v, tr('시작일'), required: true);
                          return null;
                        } catch (_) {
                          return tr('날짜를 YYYY-MM-DD 형식으로 입력하세요.');
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
                        labelText: tr('마감일'),
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
                          validDate(v, tr('마감일'));
                          return null;
                        } catch (_) {
                          return tr('날짜를 YYYY-MM-DD 형식으로 입력하세요.');
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              select(
                'task-priority',
                tr('우선순위'),
                priority,
                translatedLabels(priorities),
                (v) => priority = v,
              ),
              if (widget.task == null && widget.store.isProject)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: IeumSelect(
                    key: const Key('task-create-lock'),
                    value: createLock,
                    label: tr('수정 허용'),
                    values: {
                      '': tr('모든 참여자 · 잠금 없음'),
                      'creator': tr('작성자만 · 잠금'),
                      'assignee': tr('담당자만 · 잠금'),
                    },
                    onChanged: (value) => setState(() => createLock = value),
                  ),
                ),
              if (error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 15),
                  child: Text(
                    error,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.maybePop(context),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const Key('task-save'),
            onPressed: canSave ? save : () => Navigator.maybePop(context),
            child: Text(
              canSave ? (widget.task == null ? tr('등록') : tr('저장')) : tr('닫기'),
            ),
          ),
        ],
      ),
    ),
  );
}
