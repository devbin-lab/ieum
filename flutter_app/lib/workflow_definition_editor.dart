import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'models.dart';
import 'project_service.dart';
import 'store.dart';
import 'workflow_panel.dart';
import 'workflow_sheet_canvas.dart';

/// One local draft for both statuses and transitions. Publishing is atomic.
class WorkflowDefinitionEditor extends StatefulWidget {
  const WorkflowDefinitionEditor({
    super.key,
    required this.store,
    this.sync,
    this.session,
  });
  final TaskStore store;
  final GitHubSync? sync;
  final GitHubSession? session;

  @override
  State<WorkflowDefinitionEditor> createState() =>
      _WorkflowDefinitionEditorState();
}

class _WorkflowDefinitionEditorState extends State<WorkflowDefinitionEditor> {
  late String projectId;
  late List<WorkflowStage> baseStages, draftStages;
  WorkflowSheet? baseSheet;
  late WorkflowSheet initialSheet, draftSheet;
  bool busy = false;
  bool showFlow = false;
  String notice = '';
  bool get canEdit => widget.store.actor.active && widget.store.owns;
  bool get canPublish =>
      canEdit && widget.sync != null && widget.session != null;
  String get draftKey => 'workflow.draft.$projectId';
  String stagesJson(List<WorkflowStage> stages) =>
      jsonEncode(stages.map((s) => s.json).toList());
  bool get dirty =>
      stagesJson(baseStages) != stagesJson(draftStages) ||
      jsonEncode(initialSheet.json) != jsonEncode(draftSheet.json);
  ProjectManifest get rawProject => ProjectManifest.fromJson(
    Map<String, dynamic>.from(jsonDecode(widget.store.meta('project'))),
  );
  bool get conflict {
    final current = rawProject;
    return current.id != projectId ||
        stagesJson(current.workflowStages) != stagesJson(baseStages) ||
        jsonEncode(current.workflowSheet?.json) != jsonEncode(baseSheet?.json);
  }

  @override
  void initState() {
    super.initState();
    loadCurrent(restore: true);
  }

  void loadCurrent({bool restore = false}) {
    final raw = rawProject;
    projectId = raw.id;
    baseStages = List.unmodifiable(raw.workflowStages);
    draftStages = baseStages;
    baseSheet = raw.workflowSheet;
    initialSheet = raw.partWorkflowView.workflowSheet!;
    draftSheet = initialSheet;
    notice = '';
    if (!restore) {
      widget.store.setMeta(draftKey, '');
      return;
    }
    final local = widget.store.meta(draftKey);
    if (local.isEmpty || !canEdit) return;
    try {
      final value = Map<String, dynamic>.from(jsonDecode(local));
      if (value['projectId'] != projectId || value['schemaVersion'] != 1) {
        return;
      }
      List<WorkflowStage> readStages(String key) => List.unmodifiable(
        (value[key] as List).map(
          (s) => WorkflowStage.fromJson(Map<String, dynamic>.from(s)),
        ),
      );
      baseStages = readStages('baseStages');
      draftStages = readStages('stages');
      baseSheet = value['baseSheet'] == null
          ? null
          : WorkflowSheet.fromJson(
              Map<String, dynamic>.from(value['baseSheet']),
            );
      initialSheet =
          baseSheet ??
          WorkflowSheet.defaultFor(baseStages.map((s) => s.id).toList());
      draftSheet = WorkflowSheet.fromJson(
        Map<String, dynamic>.from(value['sheet']),
      );
      notice = '이 컴퓨터에 저장된 초안을 불러왔습니다.';
    } catch (_) {
      baseStages = List.unmodifiable(raw.workflowStages);
      draftStages = baseStages;
      baseSheet = raw.workflowSheet;
      initialSheet = raw.partWorkflowView.workflowSheet!;
      draftSheet = initialSheet;
      notice = '저장된 초안을 읽을 수 없어 현재 적용된 흐름을 표시합니다.';
    }
  }

  void persistDraft() {
    if (!canEdit) return;
    widget.store.setMeta(
      draftKey,
      dirty
          ? jsonEncode({
              'schemaVersion': 1,
              'projectId': projectId,
              'baseStages': baseStages.map((s) => s.json).toList(),
              'baseSheet': baseSheet?.json,
              'stages': draftStages.map((s) => s.json).toList(),
              'sheet': draftSheet.json,
            })
          : '',
    );
  }

  void changeStages(List<WorkflowStage> next) {
    final ids = next.map((s) => s.id).toSet();
    final retainedNodes = draftSheet.nodes
        .where((n) => ids.contains(n.stageId))
        .toList();
    var x = retainedNodes.isEmpty
        ? -140.0
        : retainedNodes.map((n) => n.x).reduce((a, b) => a > b ? a : b) + 280;
    for (final stage in next) {
      if (!draftStages.any((s) => s.id == stage.id)) {
        retainedNodes.add(WorkflowSheetNode(stage.id, stage.id, x: x));
        x += 280;
      }
    }
    final nodeIds = retainedNodes.map((n) => n.id).toSet();
    setState(() {
      draftStages = List.unmodifiable(next);
      draftSheet = WorkflowSheet(
        nodes: retainedNodes,
        routes: draftSheet.routes
            .where((r) => nodeIds.contains(r.from) && nodeIds.contains(r.to))
            .toList(),
      );
      notice = '';
    });
    persistDraft();
  }

  Future<void> resetToThreeStageFlow() async {
    if (!canEdit || busy) return;
    final selectedProjectId = projectId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('3단계 기본 흐름으로 구성'),
        content: const Text(
          '초안을 확인중·진행중·완료와 담당자 전달 흐름으로 바꿉니다. 전달·반려는 진행중을 유지하며, 상태와 담당자는 별도로 변경합니다. 초안은 게시 후 적용되며, 작업이 남아 있는 상태는 먼저 정리해야 합니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('workflow-three-stage-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('초안 구성'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || projectId != selectedProjectId) {
      return;
    }
    setState(() {
      draftStages = List.unmodifiable(defaultWorkflowStages);
      draftSheet = WorkflowSheet.defaultFor(
        defaultWorkflowStages.map((stage) => stage.id).toList(),
      );
      notice = '3단계 기본 흐름을 초안으로 구성했습니다. 전달 대상은 작업을 넘길 때 선택합니다.';
    });
    persistDraft();
  }

  List<String> get validation {
    final problems = <String>[];
    final project = rawProject.partWorkflowView;
    final groups = {
      '',
      'role:owner',
      ...project.roles.map((part) => 'part:${part.id}'),
    };
    final stageIds = draftStages.map((s) => s.id).toSet();
    if (draftStages.isEmpty || !draftStages.any((s) => !s.isCompleted)) {
      problems.add('새 작업이 시작할 수 있는 상태가 필요합니다.');
    }
    if (draftStages.where((s) => s.initial).length > 1) {
      problems.add('시작 상태는 하나만 지정하세요.');
    }
    if (draftStages.any((s) => s.initial && s.isCompleted)) {
      problems.add('완료 상태는 시작 상태로 지정할 수 없습니다.');
    }
    if (draftSheet.nodes.any((n) => !stageIds.contains(n.stageId))) {
      problems.add('삭제된 상태를 사용하는 카드를 정리하세요.');
    }
    if (baseStages.any(
      (s) =>
          !stageIds.contains(s.id) &&
          widget.store.tasks.any((task) => task.status == s.id),
    )) {
      problems.add('작업이 남아 있는 상태는 삭제할 수 없습니다.');
    }
    final signatures = <String>{};
    for (final route in draftSheet.routes) {
      if (!groups.contains(route.source) ||
          !groups.contains(route.destination)) {
        problems.add('전환에 지정된 파트가 삭제되었습니다. 전달 조건을 다시 선택하세요.');
      }
      if (route.assignment == 'target' && route.person.isNotEmpty) {
        final recipient = project.people
            .where((person) => person.id == route.person && person.active)
            .firstOrNull;
        final part = project.roles
            .where((part) => 'part:${part.id}' == route.destination)
            .firstOrNull;
        if (recipient == null ||
            route.destination == 'role:owner' &&
                recipient.id != project.ownerId ||
            part != null && !recipient.parts.contains(part.name)) {
          problems.add('받는 작업자의 참여 상태와 파트 배정을 확인하세요.');
        }
      }
      final required = [...route.requiredFields]..sort();
      if (!signatures.add(
        jsonEncode([
          draftSheet.stageFor(route.from),
          draftSheet.stageFor(route.to),
          route.effectiveOperation,
          route.name,
          route.source,
          route.destination,
          route.person,
          route.assignment,
          route.purpose,
          route.requiredPurpose,
          route.requiresComment,
          required,
          route.trigger,
        ]),
      )) {
        problems.add('같은 상태 사이에 중복된 전환 조건이 있습니다.');
      }
    }
    try {
      WorkflowSheet.fromJson(draftSheet.json);
      for (final stage in draftStages) {
        WorkflowStage.fromJson(stage.json);
      }
    } catch (error) {
      problems.add(error.toString().replaceFirst('Bad state: ', ''));
    }
    return problems.toSet().toList();
  }

  Future<void> publish() async {
    if (!canPublish ||
        busy ||
        conflict ||
        validation.isNotEmpty ||
        !dirty && baseSheet != null) {
      return;
    }
    final submittedProjectId = projectId;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      final saved = await widget.session!.saveWorkflowDefinition(
        widget.sync!.config,
        draftStages,
        draftSheet,
        expectedProjectId: submittedProjectId,
        expectedStages: baseStages,
        expectedSheet: baseSheet,
      );
      if (!mounted || widget.store.project?.id != submittedProjectId) return;
      widget.store.updateProject(saved);
      setState(() {
        loadCurrent();
        notice = '상태와 전환을 함께 게시했습니다. 이제 작업에 적용됩니다.';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => notice = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final current = rawProject;
      if (current.id != projectId) {
        loadCurrent(restore: true);
      } else if (!dirty && !busy && conflict) {
        loadCurrent();
      }
      final conflicts = conflict;
      final problems = validation;
      final project = current.partWorkflowView;
      final stateLabel = conflicts
          ? '원격 변경 있음'
          : dirty
          ? '초안 · 이 컴퓨터에 자동 저장됨'
          : baseSheet == null
          ? '기본 초안'
          : '현재 적용 중';
      return ColoredBox(
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              key: const Key('workflow-sheet-save-bar'),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xffe8ebe9))),
              ),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    '워크플로',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xff344052),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: conflicts
                          ? const Color(0xfffff4e9)
                          : dirty
                          ? const Color(0xffeff3f8)
                          : const Color(0xffedf5f0),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      stateLabel,
                      key: const Key('workflow-sheet-save-status'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xff556b91),
                      ),
                    ),
                  ),
                  if (canEdit) ...[
                    OutlinedButton.icon(
                      key: const Key('workflow-three-stage-default'),
                      onPressed: busy ? null : resetToThreeStageFlow,
                      icon: const Icon(Icons.view_kanban_outlined, size: 16),
                      label: const Text('3단계 기본 흐름'),
                    ),
                    TextButton(
                      key: const Key('workflow-sheet-reload'),
                      onPressed: busy ? null : () => setState(loadCurrent),
                      child: Text(conflicts ? '현재 흐름 불러오기' : '초안 취소'),
                    ),
                    FilledButton.icon(
                      key: const Key('workflow-sheet-save'),
                      onPressed:
                          !canPublish ||
                              busy ||
                              conflicts ||
                              problems.isNotEmpty ||
                              !dirty && baseSheet != null
                          ? null
                          : publish,
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.publish_rounded, size: 17),
                      label: const Text('게시 · 적용'),
                    ),
                  ],
                ],
              ),
            ),
            if (notice.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  notice,
                  key: const Key('workflow-sheet-save-notice'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff64748b),
                  ),
                ),
              ),
            if (conflicts)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '적용된 흐름이 변경되었습니다. 초안은 보존되며 현재 흐름을 다시 불러온 뒤 게시할 수 있습니다.',
                  style: TextStyle(fontSize: 11, color: Color(0xffa06d3e)),
                ),
              ),
            if (problems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  problems.join('\n'),
                  key: const Key('workflow-sheet-validation'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xffa0445a),
                  ),
                ),
              ),
            if (canEdit && !canPublish)
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '초안은 이 컴퓨터에 저장됩니다. 공유 저장소에 연결하면 게시할 수 있습니다.',
                  style: TextStyle(fontSize: 11, color: Color(0xff64748b)),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                key: const Key('workflow-settings-split'),
                builder: (context, bounds) {
                  final states = SingleChildScrollView(
                    key: const Key('workflow-settings-left'),
                    padding: const EdgeInsets.all(20),
                    child: WorkflowPanel(
                      key: ValueKey('workflow-status-draft-$projectId'),
                      store: widget.store,
                      sync: widget.sync,
                      session: widget.session,
                      draftMode: true,
                      draftStages: draftStages,
                      onStagesChanged: busy ? null : changeStages,
                    ),
                  );
                  final flow = ColoredBox(
                    key: const Key('workflow-automation-space'),
                    color: Colors.white,
                    child: WorkflowSheetCanvas(
                      key: ValueKey('workflow-definition-sheet-$projectId'),
                      value: draftSheet,
                      readOnly: !canEdit || busy,
                      stageCatalog: draftStages,
                      roles: project.roles,
                      people: project.people,
                      parts: project.parts,
                      onChanged: (next) {
                        setState(() {
                          draftSheet = next;
                          notice = '';
                        });
                        persistDraft();
                      },
                    ),
                  );
                  if (bounds.maxWidth >= 900) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: states),
                        const VerticalDivider(
                          width: 1,
                          color: Color(0xffe8ebe9),
                        ),
                        Expanded(child: flow),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: SegmentedButton<bool>(
                          key: const Key('workflow-compact-view'),
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: false,
                              icon: Icon(Icons.view_list_outlined, size: 16),
                              label: Text('상태'),
                            ),
                            ButtonSegment(
                              value: true,
                              icon: Icon(Icons.account_tree_outlined, size: 16),
                              label: Text('흐름'),
                            ),
                          ],
                          selected: {showFlow},
                          onSelectionChanged: (value) =>
                              setState(() => showFlow = value.first),
                        ),
                      ),
                      Expanded(
                        child: IndexedStack(
                          index: showFlow ? 1 : 0,
                          sizing: StackFit.expand,
                          children: [states, flow],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}
