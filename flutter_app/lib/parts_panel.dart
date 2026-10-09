import 'workspace_ui.dart';
import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'models.dart';
import 'project_service.dart';
import 'store.dart';

class PartsPanel extends StatefulWidget {
  const PartsPanel({super.key, required this.store, this.sync, this.session});
  final TaskStore store;
  final GitHubSync? sync;
  final GitHubSession? session;
  @override
  State<PartsPanel> createState() => _PartsPanelState();
}

class _PartsPanelState extends State<PartsPanel> {
  bool busy = false;
  String notice = '';
  bool get canManage =>
      widget.store.actor.has('member.manage') &&
      widget.session != null &&
      widget.sync != null;

  Future<bool> save(List<String> next, List<String> original) async {
    if (busy || !canManage) return false;
    final projectId = widget.store.project!.id;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      final project = await widget.session!.saveParts(
        widget.sync!.config,
        next,
        expectedProjectId: projectId,
        expectedParts: original,
      );
      if (!mounted || widget.store.project?.id != projectId) return false;
      widget.store.updateProject(project);
      setState(() => notice = tr('파트 목록을 저장했습니다.'));
      return true;
    } catch (e) {
      if (mounted) setState(() => notice = '$e');
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    if (busy || widget.session == null || widget.sync == null) return;
    final projectId = widget.store.project!.id;
    setState(() {
      busy = true;
      notice = '';
    });
    try {
      final project = await widget.session!.loadProject(widget.sync!.config);
      if (mounted &&
          project.id == projectId &&
          widget.store.project?.id == projectId) {
        widget.store.updateProject(project);
      }
    } catch (e) {
      if (mounted) setState(() => notice = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add() async {
    final controller = TextEditingController();
    var saving = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> submit() async {
            if (saving) return;
            final original = widget.store.project!.parts;
            final name = controller.text.trim();
            final next = [...original, name];
            if (!validProjectParts(next)) {
              update(
                () => error = tr(
                  '중복되지 않는 이름을 1~40자로 입력하세요. 최대 50개까지 등록할 수 있습니다.',
                ),
              );
              return;
            }
            update(() {
              saving = true;
              error = null;
            });
            final success = await save(next, original);
            if (!ctx.mounted) return;
            if (success) {
              Navigator.pop(ctx);
            } else {
              update(() {
                saving = false;
                error = notice;
              });
            }
          }

          return PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: Text(tr('파트 추가')),
              content: SizedBox(
                width: 340,
                child: TextField(
                  key: const Key('part-name'),
                  controller: controller,
                  autofocus: true,
                  enabled: !saving,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: tr('파트 이름'),
                    hintText: tr('예: 기획, 디렉터'),
                    errorText: error,
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving ? null : () => Navigator.pop(ctx),
                  child: Text(tr('취소')),
                ),
                FilledButton(
                  key: const Key('part-save'),
                  onPressed: saving ? null : submit,
                  child: Text(saving ? tr('저장 중') : tr('추가')),
                ),
              ],
            ),
          );
        },
      ),
    );
    // The route finishes its exit animation after its result completes.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final project = widget.store.project!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                key: const Key('part-add'),
                onPressed: busy || !canManage ? null : add,
                icon: const Icon(Icons.add_rounded, size: 17),
                label: Text(tr('파트 추가')),
              ),
              OutlinedButton.icon(
                key: const Key('parts-refresh'),
                onPressed: busy ? null : refresh,
                icon: const Icon(Icons.refresh_rounded, size: 17),
                label: Text(tr('새로고침')),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tr('파트를 만든 후 참여자 관리에서 소속 파트를 지정하세요.'),
            style: TextStyle(fontSize: 12, color: Color(0xff7a8581)),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                trError(notice),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          const SizedBox(height: 20),
          if (project.parts.isEmpty)
            Container(
              key: const Key('parts-empty'),
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                border: Border.all(color: WorkspaceUi.colors(context).line),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.groups_outlined,
                    size: 26,
                    color: Color(0xff8b9892),
                  ),
                  SizedBox(height: 12),
                  Text(
                    tr('등록된 파트가 없습니다.'),
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                  SizedBox(height: 6),
                  Text(
                    tr('파트 추가 버튼으로 필요한 파트를 만들어 주세요.'),
                    style: TextStyle(fontSize: 12, color: Color(0xff7a8581)),
                  ),
                ],
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: WorkspaceUi.colors(context).line),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  for (final part in project.parts)
                    ListTile(
                      key: ValueKey('part-row-$part'),
                      leading: const Icon(Icons.groups_outlined, size: 20),
                      title: Text(part, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        tr(
                          '소속 {v0}명',
                          args: {
                            'v0': project.people
                                .where((p) => p.parts.contains(part))
                                .length,
                          },
                        ),
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        key: ValueKey('part-delete-$part'),
                        tooltip: tr('파트 삭제'),
                        onPressed: busy || !canManage
                            ? null
                            : () => save(
                                project.parts.where((p) => p != part).toList(),
                                project.parts,
                              ),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 18,
                          color: Color(0xffb66e76),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            tr('삭제한 파트의 참여자 배정은 해제되며, 기존 작업 내역은 유지됩니다.'),
            style: TextStyle(fontSize: 11, color: Color(0xff929d98)),
          ),
        ],
      );
    },
  );
}
