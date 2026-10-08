import 'dart:async';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'models.dart';
import 'project_service.dart';
import 'store.dart';
import 'workflow_stage_order.dart';

class WorkflowPanel extends StatefulWidget {
  const WorkflowPanel({
    super.key,
    required this.store,
    this.sync,
    this.session,
    this.draftStages,
    this.onStagesChanged,
    this.draftMode = false,
  });

  final TaskStore store;
  final GitHubSync? sync;
  final GitHubSession? session;
  final List<WorkflowStage>? draftStages;
  final ValueChanged<List<WorkflowStage>>? onStagesChanged;
  final bool draftMode;

  @override
  State<WorkflowPanel> createState() => _WorkflowPanelState();
}

class _WorkflowPanelState extends State<WorkflowPanel> {
  bool busy = false;
  String notice = '';
  List<WorkflowStage>? _optimisticStages;
  List<WorkflowStage> get stages =>
      widget.draftStages ?? widget.store.project!.workflowStages;
  String? get initialStatusId =>
      stages.where((s) => s.initial).firstOrNull?.id ??
      stages.where((s) => !s.isCompleted).firstOrNull?.id;

  bool get canManage =>
      widget.store.actor.active &&
      widget.store.owns &&
      (widget.draftMode
          ? widget.onStagesChanged != null
          : widget.sync != null && widget.session != null);

  Future<void> addStage() async {
    final currentStages = this.stages;
    if (currentStages.length >= maxWorkflowStages) {
      setState(() => notice = '작업 단계는 최대 $maxWorkflowStages개까지 설정할 수 있습니다.');
      return;
    }
    final created = await editProperties();
    if (created == null || !mounted) return;
    final stages = List<WorkflowStage>.from(currentStages);
    final completionIndex = stages.indexWhere((stage) => stage.isCompleted);
    stages.insert(
      completionIndex < 0 ? stages.length : completionIndex,
      created,
    );
    await _save(withInitial(stages, created));
  }

  List<WorkflowStage> withInitial(
    List<WorkflowStage> stages,
    WorkflowStage changed,
  ) => [
    for (final stage in stages)
      if (changed.initial && stage.id != changed.id)
        WorkflowStage(
          stage.id,
          stage.name,
          category: stage.category,
          editPolicy: stage.editPolicy,
        )
      else
        stage,
  ];

  Future<void> editStage(WorkflowStage stage) async {
    final original = List<WorkflowStage>.of(stages);
    final changed = await editProperties(stage);
    if (changed == null || !mounted) return;
    await _save(
      withInitial([
        for (final entry in original) entry.id == changed.id ? changed : entry,
      ], changed),
      expectedOrder: original,
    );
  }

  Future<WorkflowStage?> editProperties([WorkflowStage? stage]) async {
    final currentStages = stages;
    var nameValue = stage?.name ?? '';
    String? error;
    var category = stage?.resolvedCategory ?? 'inProgress';
    const editPolicy = 'everyone';
    var initial = stage == null
        ? currentStages.isEmpty
        : initialStatusId == stage.id;
    WorkflowStage? result;
    void submit(BuildContext dialogContext, StateSetter updateDialog) {
      final value = nameValue.trim();
      final validation = _stageNameError(
        value,
        currentStages.where((item) => item.id != stage?.id).toList(),
      );
      if (validation != null || initial && category == 'done') {
        updateDialog(() => error = validation ?? '시작 상태는 편집 가능한 미완료 상태여야 합니다.');
        return;
      }
      result = WorkflowStage(
        stage?.id ??
            'stage-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        value,
        category: category,
        editPolicy: editPolicy,
        initial: initial,
      );
      Navigator.pop(dialogContext);
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          title: Text(stage == null ? '상태 추가' : '상태 속성'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('workflow-stage-type'),
                    initialValue: category,
                    decoration: const InputDecoration(labelText: '표시할 칸반 열'),
                    items: const [
                      DropdownMenuItem(value: 'todo', child: Text('확인중')),
                      DropdownMenuItem(value: 'inProgress', child: Text('진행중')),
                      DropdownMenuItem(value: 'done', child: Text('완료')),
                    ],
                    onChanged: (value) => updateDialog(() {
                      category = value!;
                      if (category == 'done') initial = false;
                      error = null;
                    }),
                  ),
                  const SizedBox(height: 18),
                  TextFormField(
                    key: const Key('workflow-stage-name'),
                    initialValue: nameValue,
                    autofocus: true,
                    maxLength: 30,
                    onChanged: (value) => updateDialog(() {
                      nameValue = value;
                      error = null;
                    }),
                    decoration: InputDecoration(
                      labelText: '상태 이름',
                      hintText: '예: 확인중, 진행중, 완료',
                      errorText: error,
                    ),
                    onFieldSubmitted: (_) =>
                        submit(dialogContext, updateDialog),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '미완료 작업은 모든 활성 참여자가 수정할 수 있습니다. 담당자 배정은 내 할 일과 알림에 사용됩니다.',
                    key: Key('workflow-stage-collaboration'),
                    style: TextStyle(fontSize: 12, color: Color(0xff6e687b)),
                  ),
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    key: const Key('workflow-stage-initial'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '새 작업의 시작 상태',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      '한 프로젝트에 하나만 지정합니다.',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: initial,
                    onChanged: category == 'done'
                        ? null
                        : (value) => updateDialog(() => initial = value!),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('취소'),
            ),
            FilledButton(
              key: Key(
                stage == null
                    ? 'workflow-stage-confirm-add'
                    : 'workflow-stage-confirm-edit',
              ),
              onPressed: () => submit(dialogContext, updateDialog),
              child: Text(stage == null ? '추가' : '저장'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  String? _stageNameError(String value, List<WorkflowStage> currentStages) {
    if (value.isEmpty) return '단계 이름을 입력하세요.';
    if (value.length > 30) return '단계 이름은 30자 이내로 입력하세요.';
    if (currentStages.any(
      (stage) => stage.name.toLowerCase() == value.toLowerCase(),
    )) {
      return '이미 등록된 단계 이름입니다.';
    }
    return null;
  }

  Future<void> deleteStage(WorkflowStage stage) async {
    final uses = widget.store.tasks
        .where((task) => task.status == stage.id)
        .length;
    if (widget.draftMode && uses > 0) {
      setState(
        () => notice = '현재 $uses개 작업이 이 상태에 있습니다. 작업을 다른 상태로 옮긴 다음 삭제하세요.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('‘${stage.name}’ 단계 삭제'),
        content: Text(
          uses == 0
              ? '이 단계를 프로젝트 칸반에서 삭제합니다.'
              : '현재 $uses개 작업이 이 단계에 있습니다. 삭제 후 작업은 ‘삭제된 단계’에 보존되며, 담당자가 현재 프로젝트의 다른 단계로 옮길 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: Key('workflow-stage-confirm-delete-${stage.id}'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _save(stages.where((item) => item.id != stage.id).toList());
  }

  Future<void> _save(
    List<WorkflowStage> stages, {
    bool optimisticOrder = false,
    List<WorkflowStage>? expectedOrder,
    String successMessage = '작업 단계를 저장했습니다.',
  }) async {
    if (!canManage || busy) return;
    if (widget.draftMode) {
      widget.onStagesChanged?.call(List.unmodifiable(stages));
      setState(() {
        _optimisticStages = null;
        notice = '상태 초안을 변경했습니다. 게시하면 작업에 적용됩니다.';
      });
      return;
    }
    final sync = widget.sync!;
    final session = widget.session!;
    final projectId = widget.store.project!.id;
    final expectedStages = List<WorkflowStage>.from(
      expectedOrder ?? widget.store.project!.workflowStages,
    );
    setState(() {
      busy = true;
      notice = '';
      _optimisticStages = optimisticOrder ? List.unmodifiable(stages) : null;
    });
    try {
      final updated = await session.saveWorkflowStages(
        sync.config,
        stages,
        expectedProjectId: projectId,
        expectedStages: expectedStages,
        reorderOnly: optimisticOrder,
      );
      if (!mounted) return;
      widget.store.updateProject(updated);
      setState(() {
        _optimisticStages = null;
        notice = successMessage;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _optimisticStages = null;
          notice = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final custom =
          _optimisticStages ??
          widget.draftStages ??
          widget.store.project?.workflowStages ??
          const [];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '상태 목록',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              if (canManage)
                FilledButton.icon(
                  key: const Key('workflow-stage-add'),
                  onPressed: busy || custom.length >= maxWorkflowStages
                      ? null
                      : addStage,
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('상태 추가'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.draftMode
                ? '칸반은 확인중·진행중·완료 3열입니다. 담당자 전달은 상태를 유지하며, 오른쪽 시트에서 선택할 전달 흐름을 설정할 수 있습니다.'
                : '미완료 작업은 모든 활성 참여자가 수정할 수 있습니다. 담당자 전달과 작업 상태 변경은 별도로 처리합니다.',
            style: const TextStyle(fontSize: 12, color: Color(0xff6e687b)),
          ),
          const SizedBox(height: 18),
          Container(
            key: const Key('workflow-stage-list'),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xffe1e3e6)),
              borderRadius: BorderRadius.circular(10),
            ),
            clipBehavior: Clip.antiAlias,
            child: WorkflowStageOrder(
              key: ValueKey(widget.store.project?.id),
              stages: custom,
              enabled: canManage && !busy,
              rowBuilder: _stageRow,
              onReorder: (stages, original) => unawaited(
                _save(
                  stages,
                  optimisticOrder: true,
                  expectedOrder: original,
                  successMessage: '단계 순서를 저장했습니다.',
                ),
              ),
            ),
          ),
          if (!widget.store.owns)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '프로젝트 관리자가 상태를 설정합니다.',
                style: TextStyle(fontSize: 11, color: Color(0xff6e687b)),
              ),
            )
          else if (!widget.draftMode &&
              (widget.sync == null || widget.session == null))
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '공유 저장소에 연결하면 프로젝트 단계를 관리할 수 있습니다.',
                style: TextStyle(fontSize: 11, color: Color(0xff6e687b)),
              ),
            ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(
                notice,
                style: TextStyle(
                  fontSize: 12,
                  color: notice.contains('저장했습니다')
                      ? const Color(0xff417458)
                      : const Color(0xffa0445a),
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _stageRow(WorkflowStage stage, int index, Widget handle) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 11),
    child: Row(
      children: [
        if (canManage) handle,
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: switch (stage.resolvedCategory) {
              'done' => const Color(0xff659981),
              'inProgress' => const Color(0xff8076bd),
              _ => const Color(0xff8593a4),
            },
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stage.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 3),
              Text(
                [
                  switch (stage.resolvedCategory) {
                    'todo' => '확인중',
                    'done' => '완료',
                    _ => '진행중',
                  },
                  if (!stage.isCompleted) '공동 편집',
                  if (initialStatusId == stage.id) '시작',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: Color(0xff7f8da1)),
              ),
            ],
          ),
        ),
        if (canManage)
          IconButton(
            key: Key('workflow-stage-edit-${stage.id}'),
            tooltip: '상태 속성 편집',
            onPressed: busy ? null : () => editStage(stage),
            icon: const Icon(Icons.tune_rounded, size: 16),
          ),
        if (canManage)
          IconButton(
            key: Key('workflow-stage-delete-${stage.id}'),
            onPressed: busy ? null : () => deleteStage(stage),
            icon: const Icon(Icons.delete_outline_rounded, size: 16),
            tooltip: '상태 삭제',
            style: IconButton.styleFrom(
              foregroundColor: const Color(0xffa0445a),
              minimumSize: const Size(32, 32),
            ),
          ),
      ],
    ),
  );
}
