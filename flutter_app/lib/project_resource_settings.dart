import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'github_sync.dart';
import 'project_service.dart';
import 'store.dart';
import 'workspace_ui.dart';

class ProjectResourceSettings extends StatefulWidget {
  const ProjectResourceSettings({
    super.key,
    required this.store,
    this.sync,
    this.session,
  });
  final TaskStore store;
  final GitHubSync? sync;
  final GitHubSession? session;
  @override
  State<ProjectResourceSettings> createState() =>
      _ProjectResourceSettingsState();
}

class _ProjectResourceSettingsState extends State<ProjectResourceSettings> {
  bool busy = false;
  String notice = '';

  Future<void> changeLimit() async {
    final project = widget.store.project!;
    final controller = TextEditingController(
      text: '${project.attachmentLimitMb}',
    );
    String? error;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(tr('첨부 파일 한도')),
          content: SizedBox(
            width: 320,
            child: TextField(
              key: const Key('attachment-limit-input'),
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('파일당 최대 용량'),
                suffixText: 'MB',
                helperText: tr('1~50MB로 설정할 수 있습니다.'),
                errorText: error,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('취소')),
            ),
            FilledButton(
              key: const Key('attachment-limit-save'),
              onPressed: () {
                final value = int.tryParse(controller.text.trim());
                if (value == null || value < 1 || value > 50) {
                  update(() => error = tr('1~50MB로 설정할 수 있습니다.'));
                } else {
                  Navigator.pop(context, value);
                }
              },
              child: Text(tr('저장')),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    controller.dispose();
    if (result == null || !mounted) return;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      final saved = await widget.session!.setAttachmentLimit(
        widget.sync!.config,
        result,
        expectedProjectId: project.id,
        expectedLimitMb: project.attachmentLimitMb,
      );
      if (!mounted) return;
      widget.store.updateProject(saved);
      notice = tr('변경 사항을 저장했습니다.');
    } catch (error) {
      notice = error is GitHubFailure
          ? tr(error.message)
          : error is StateError
          ? tr(error.message)
          : tr('자료를 처리하지 못했습니다. 다시 시도해 주세요.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.store.project;
    final canManage =
        project != null &&
        widget.store.actor.active &&
        widget.store.actor.id == project.ownerId &&
        widget.session != null &&
        widget.sync != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WorkspaceSectionLabel(title: tr('자료')),
        const SizedBox(height: 12),
        WorkspacePanel(
          child: Wrap(
            spacing: 20,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('파일당 최대 용량'),
                    style: WorkspaceUi.sectionStyleOf(context),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${project?.attachmentLimitMb ?? 50} MB',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('변경한 한도는 새로 첨부하는 파일부터 적용됩니다.'),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ],
              ),
              if (canManage)
                OutlinedButton(
                  key: const Key('change-attachment-limit'),
                  onPressed: busy ? null : changeLimit,
                  child: Text(busy ? tr('저장 중…') : tr('변경')),
                ),
            ],
          ),
        ),
        if (notice.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(notice, style: WorkspaceUi.captionStyleOf(context)),
          ),
      ],
    );
  }
}
