import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'project_service.dart';
import 'store.dart';
import 'workflow_sheet_canvas.dart';
import 'workflow_sheet_model.dart';

/// Keeps edits separate from the policy currently used by project tasks.
class WorkflowSheetSettings extends StatefulWidget {
  const WorkflowSheetSettings({
    super.key,
    required this.store,
    this.sync,
    this.session,
  });

  final TaskStore store;
  final GitHubSync? sync;
  final GitHubSession? session;

  @override
  State<WorkflowSheetSettings> createState() => _WorkflowSheetSettingsState();
}

class _WorkflowSheetSettingsState extends State<WorkflowSheetSettings> {
  late String projectId;
  WorkflowSheet? base;
  late WorkflowSheet initial, draft;
  bool busy = false;
  String notice = '';

  bool get dirty => jsonEncode(draft.json) != jsonEncode(initial.json);
  bool get canManage =>
      widget.store.actor.active &&
      widget.store.owns &&
      widget.sync != null &&
      widget.session != null;

  @override
  void initState() {
    super.initState();
    loadCurrent();
  }

  void loadCurrent() {
    final project = widget.store.project!;
    projectId = project.id;
    base = project.workflowSheet;
    initial = project.partWorkflowView.workflowSheet!;
    draft = initial;
    notice = '';
  }

  Future<void> save() async {
    if (!canManage || busy || !dirty && base != null) return;
    final expectedProjectId = projectId;
    final submitted = draft;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      final validated = WorkflowSheet.fromJson(submitted.json);
      final saved = await widget.session!.saveWorkflowSheet(
        widget.sync!.config,
        validated,
        expectedProjectId: expectedProjectId,
        expectedSheet: base,
      );
      if (!mounted || widget.store.project?.id != expectedProjectId) return;
      widget.store.updateProject(saved);
      setState(() {
        base = saved.workflowSheet;
        initial = saved.partWorkflowView.workflowSheet!;
        draft = initial;
        notice = '자동화 시트를 저장하고 작업에 적용했습니다.';
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
      final rawProject = widget.store.project!;
      if (rawProject.id != projectId ||
          !dirty &&
              jsonEncode(rawProject.workflowSheet?.json) !=
                  jsonEncode(base?.json)) {
        loadCurrent();
      }
      final project = rawProject.partWorkflowView;
      final conflict =
          dirty &&
          jsonEncode(rawProject.workflowSheet?.json) != jsonEncode(base?.json);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const Key('workflow-sheet-save-bar'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xffe8ebe9))),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  canManage
                      ? conflict
                            ? '원격 변경 있음 · 새로 불러오기 필요'
                            : dirty
                            ? '저장하지 않은 변경사항'
                            : base == null
                            ? '기본 흐름 · 저장하면 적용됩니다.'
                            : '저장된 흐름 적용 중'
                      : '관리자가 작업 흐름을 설정합니다.',
                  key: const Key('workflow-sheet-save-status'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff7f8da1),
                  ),
                ),
                if (canManage) ...[
                  TextButton(
                    key: const Key('workflow-sheet-reload'),
                    onPressed: busy ? null : () => setState(loadCurrent),
                    child: const Text('변경 취소'),
                  ),
                  FilledButton.icon(
                    key: const Key('workflow-sheet-save'),
                    onPressed: busy || conflict || !dirty && base != null
                        ? null
                        : save,
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 16),
                    label: const Text('저장 · 적용'),
                  ),
                ],
              ],
            ),
          ),
          if (notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                notice,
                key: const Key('workflow-sheet-save-notice'),
                style: const TextStyle(fontSize: 11, color: Color(0xff64748b)),
              ),
            ),
          Expanded(
            child: WorkflowSheetCanvas(
              key: ValueKey('workflow-sheet-$projectId'),
              value: draft,
              readOnly: !canManage || busy,
              onChanged: (next) => setState(() {
                draft = next;
                notice = '';
              }),
              stageCatalog: project.workflowStages,
              roles: project.roles,
              people: project.people,
              parts: project.parts,
            ),
          ),
        ],
      );
    },
  );
}
