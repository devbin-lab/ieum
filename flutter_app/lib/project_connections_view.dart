import 'app_localizations.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'store.dart';
import 'sync_recovery_ui.dart';
import 'workspace_ui.dart';

/// An overview of the real project and its local synchronization queue.
/// Configuration and conflict resolution stay in their dedicated settings view.
class ProjectConnectionsView extends StatefulWidget {
  const ProjectConnectionsView({
    super.key,
    required this.store,
    this.sync,
    required this.onOpenSettings,
    required this.onOpenWorkflow,
    required this.onOpenMembers,
    this.automationMessage = '',
    this.automaticRoutes = 0,
  });

  final TaskStore store;
  final GitHubSync? sync;
  final VoidCallback onOpenSettings, onOpenWorkflow, onOpenMembers;
  final String automationMessage;
  final int automaticRoutes;

  @override
  State<ProjectConnectionsView> createState() => _ProjectConnectionsViewState();
}

class _ProjectConnectionsViewState extends State<ProjectConnectionsView> {
  bool _syncing = false;
  String _message = '';

  Future<void> _synchronize() async {
    final sync = widget.sync;
    if (sync == null || _syncing || sync.busy || sync.pulling) return;
    if (sync.retryAt?.isAfter(DateTime.now()) == true) {
      setState(
        () => _message = tr(
          '{v0} 이후 다시 시도할 수 있습니다.',
          args: {'v0': _time(sync.retryAt!)},
        ),
      );
      return;
    }
    setState(() {
      _syncing = true;
      _message = '';
    });
    try {
      await sync.cycle(retryFailed: true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = error is GitHubFailure
              ? error.message
              : tr('동기화를 완료하지 못했습니다. 연결 설정을 확인해 주세요.');
        });
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.store,
      if (widget.sync != null) widget.sync!,
    ]),
    builder: (context, _) {
      final store = widget.store;
      final sync = widget.sync;
      GitHubConfig? config;
      var configError = '';
      try {
        final raw = store.meta('github.config');
        config = raw.isEmpty
            ? null
            : GitHubConfig.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
        config?.validate();
      } catch (_) {
        config = null;
        configError = tr('저장된 연결 설정을 읽지 못했습니다. 연결 설정을 확인해 주세요.');
      }
      final connected = config?.slug.isNotEmpty == true;
      final enabled = connected && config!.enabled && sync != null;
      final busy = _syncing || sync?.busy == true || sync?.pulling == true;
      final retryAt = sync?.retryAt;
      final waiting = retryAt?.isAfter(DateTime.now()) == true;
      final queue = _QueueSummary.read(store);
      final conflicts = _conflictCount(store.meta('github.pullConflicts'));
      final project = store.project;
      final lastPull = DateTime.tryParse(store.meta('github.lastPullAt'));
      final issues = <String>{
        if (configError.isNotEmpty) configError,
        if (_message.isNotEmpty) _message,
        if (store.meta('github.lastPullError').isNotEmpty)
          store.meta('github.lastPullError'),
        ...queue.errors,
        ...?sync?.autoMergeErrors.values.take(3),
      };
      return LayoutBuilder(
        builder: (context, constraints) {
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          final actions = <Widget>[
            if (store.syncRecoveryCount() > 0)
              SyncRecoveryHistoryButton(store: store),
            if (enabled)
              FilledButton.icon(
                key: const Key('connections-sync-now'),
                onPressed: busy || waiting ? null : _synchronize,
                icon: busy
                    ? const SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 16),
                label: Text(busy ? tr('동기화 중…') : tr('지금 동기화')),
              ),
            if (connected)
              OutlinedButton.icon(
                key: const Key('connections-open-settings'),
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.tune_rounded, size: 16),
                label: Text(tr('연결 설정')),
              )
            else
              FilledButton.icon(
                key: const Key('connections-open-settings'),
                onPressed: widget.onOpenSettings,
                icon: const Icon(Icons.add_link_rounded, size: 16),
                label: Text(tr('저장소 연결')),
              ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(padding, 24, padding, 20),
                child: WorkspacePageHeader(
                  title: tr('연결'),
                  contextLabel: project?.name,
                  actions: actions,
                ),
              ),
              Divider(height: 1, color: WorkspaceUi.colors(context).line),
              Expanded(
                child: ListView(
                  key: const Key('connections-content'),
                  padding: EdgeInsets.all(padding),
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        WorkspacePanel(
                          child: connected
                              ? _repositoryDetails(
                                  config!,
                                  enabled: enabled,
                                  busy: busy,
                                  waiting: waiting,
                                  lastPull: lastPull,
                                  retryAt: retryAt,
                                )
                              : WorkspaceEmptyState(
                                  icon: Icons.cloud_outlined,
                                  title: tr('연결된 저장소가 없습니다.'),
                                  message: tr(
                                    'GitHub 저장소를 연결하면 팀과 프로젝트 작업을 공유할 수 있습니다.',
                                  ),
                                ),
                        ),
                        const SizedBox(height: 24),
                        WorkspaceSectionLabel(title: tr('동기화 상태')),
                        const SizedBox(height: 12),
                        WorkspacePanel(
                          child: LayoutBuilder(
                            builder: (context, bounds) {
                              final columns = bounds.maxWidth >= 680
                                  ? 4
                                  : bounds.maxWidth >= 280
                                  ? 2
                                  : 1;
                              final width =
                                  (bounds.maxWidth - 20 * (columns - 1)) /
                                  columns;
                              return Wrap(
                                spacing: 20,
                                runSpacing: 22,
                                children: [
                                  _metric(
                                    context,
                                    width,
                                    tr('전송 대기'),
                                    queue.pending,
                                    tr('기기에 저장된 변경'),
                                    Icons.cloud_upload_outlined,
                                  ),
                                  _metric(
                                    context,
                                    width,
                                    tr('반영 대기'),
                                    queue.sent,
                                    tr('저장소로 전송 완료'),
                                    Icons.merge_outlined,
                                  ),
                                  _metric(
                                    context,
                                    width,
                                    tr('전송 실패'),
                                    queue.failed,
                                    tr('연결 상태 확인 필요'),
                                    Icons.error_outline,
                                    warning: queue.failed > 0,
                                  ),
                                  _metric(
                                    context,
                                    width,
                                    tr('변경 충돌'),
                                    conflicts,
                                    tr('내 변경이 보존됨'),
                                    Icons.call_split,
                                    warning: conflicts > 0,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        SyncRecoveryNotice(store: store),
                        if (issues.isNotEmpty || conflicts > 0) ...[
                          const SizedBox(height: 16),
                          Container(
                            key: const Key('connections-attention'),
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? const Color(0xff443125)
                                  : const Color(0xfffff8ee),
                              border: Border.all(
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? const Color(0xff725438)
                                    : const Color(0xffedddc4),
                              ),
                              borderRadius: BorderRadius.circular(
                                WorkspaceUi.radius,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 17,
                                      color: WorkspaceUi.colors(context)
                                          .warning,
                                    ),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        tr('동기화 확인 필요'),
                                        style: WorkspaceUi.sectionStyleOf(
                                          context,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                if (conflicts > 0)
                                  Padding(
                                    padding: EdgeInsets.only(bottom: 8),
                                    child: Text(
                                      tr(
                                        '같은 작업에 서로 다른 변경이 있습니다. 연결 설정에서 변경 사항을 비교할 수 있습니다.',
                                      ),
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.6,
                                        color: WorkspaceUi.colors(context).ink,
                                      ),
                                    ),
                                  ),
                                for (final issue in issues.take(5))
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text(
                                      issue,
                                      style: TextStyle(
                                        fontSize: 12,
                                        height: 1.6,
                                        color: WorkspaceUi.colors(context)
                                            .muted,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        WorkspaceSectionLabel(title: tr('프로젝트 참여자')),
                        const SizedBox(height: 12),
                        WorkspacePanel(
                          child: LayoutBuilder(
                            builder: (context, bounds) {
                              final summary = Row(
                                children: [
                                  Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      color: WorkspaceUi.colors(context).subtle,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      Icons.group_outlined,
                                      size: 21,
                                      color: WorkspaceUi.colors(context).muted,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      tr(
                                        '{v0}명 참여 중 · {v1}개 파트',
                                        args: {
                                          'v0':
                                              project?.people
                                                  .where(
                                                    (person) =>
                                                        person.canMutate,
                                                  )
                                                  .length ??
                                              0,
                                          'v1': project?.parts.length ?? 0,
                                        },
                                      ),
                                      style: WorkspaceUi.sectionStyleOf(
                                        context,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                              final button = OutlinedButton.icon(
                                key: const Key('connections-open-members'),
                                onPressed: widget.onOpenMembers,
                                icon: const Icon(
                                  Icons.group_outlined,
                                  size: 16,
                                ),
                                label: Text(tr('참여자 관리')),
                              );
                              if (bounds.maxWidth < 450) {
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    summary,
                                    const SizedBox(height: 14),
                                    button,
                                  ],
                                );
                              }
                              return Row(
                                children: [
                                  Expanded(child: summary),
                                  const SizedBox(width: 16),
                                  button,
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    },
  );

  Widget _repositoryDetails(
    GitHubConfig config, {
    required bool enabled,
    required bool busy,
    required bool waiting,
    required DateTime? lastPull,
    required DateTime? retryAt,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: WorkspaceUi.colors(context).subtle,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.cloud_outlined,
              size: 22,
              color: WorkspaceUi.colors(context).ink,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('GitHub 저장소'),
                  style: WorkspaceUi.captionStyleOf(context),
                ),
                const SizedBox(height: 4),
                Text(
                  config.slug,
                  key: const Key('connections-repository'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: WorkspaceUi.colors(context).ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 20),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _badge(
            busy
                ? tr('동기화 중')
                : waiting
                ? tr('재시도 대기')
                : enabled
                ? tr('자동 동기화 켜짐')
                : tr('자동 동기화 꺼짐'),
            enabled && !waiting
                ? WorkspaceUi.colors(context).success
                : WorkspaceUi.colors(context).muted,
          ),
          _badge(
            config.autoMerge ? tr('변경 자동 반영') : tr('변경 승인 필요'),
            WorkspaceUi.colors(context).accent,
          ),
          _badge(
            tr('브랜치 · {v0}', args: {'v0': config.base}),
            WorkspaceUi.colors(context).muted,
          ),
        ],
      ),
      const SizedBox(height: 18),
      Divider(height: 1, color: WorkspaceUi.colors(context).line),
      const SizedBox(height: 14),
      Text(
        lastPull == null
            ? tr('아직 동기화 기록이 없습니다.')
            : tr('최근 업데이트 확인 · {v0}', args: {'v0': _time(lastPull)}),
        key: const Key('connections-last-pull'),
        style: WorkspaceUi.captionStyleOf(context),
      ),
      if (waiting && retryAt != null) ...[
        const SizedBox(height: 5),
        Text(
          tr('{v0} 이후 재시도합니다.', args: {'v0': _time(retryAt)}),
          style: TextStyle(
            fontSize: 11,
            color: WorkspaceUi.colors(context).warning,
          ),
        ),
      ],
    ],
  );
}

Widget _badge(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text(
    text,
    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color),
  ),
);

Widget _metric(
  BuildContext context,
  double width,
  String title,
  int count,
  String caption,
  IconData icon, {
  bool warning = false,
}) => SizedBox(
  width: width,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(
            icon,
            size: 15,
            color: warning
                ? WorkspaceUi.colors(context).warning
                : WorkspaceUi.colors(context).muted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(title, style: WorkspaceUi.captionStyleOf(context)),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '$count',
        style: TextStyle(
          fontSize: 23,
          fontWeight: FontWeight.w600,
          color: warning
              ? WorkspaceUi.colors(context).warning
              : WorkspaceUi.colors(context).ink,
        ),
      ),
      const SizedBox(height: 4),
      Text(
        caption,
        style: TextStyle(
          fontSize: 10,
          color: WorkspaceUi.colors(context).muted,
          height: 1.5,
        ),
      ),
    ],
  ),
);

String _time(DateTime date) {
  final local = date.toLocal();
  final now = DateTime.now();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  return local.year == now.year &&
          local.month == now.month &&
          local.day == now.day
      ? tr('오늘 {v0}', args: {'v0': time})
      : '${local.year}.${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')} $time';
}

int _conflictCount(String raw) {
  if (raw.isEmpty) return 0;
  try {
    final values = jsonDecode(raw) as List;
    return values
        .whereType<Map>()
        .map((entry) => entry['taskId'])
        .whereType<String>()
        .toSet()
        .length;
  } catch (_) {
    return 0;
  }
}

class _QueueSummary {
  const _QueueSummary(this.pending, this.sent, this.failed, this.errors);
  final int pending, sent, failed;
  final List<String> errors;

  factory _QueueSummary.read(TaskStore store) {
    final counts = <String, int>{};
    for (final row in store.db.select(
      "SELECT json_extract(body, '\$.state') AS state, COUNT(*) AS count FROM github_queue WHERE json_valid(body) GROUP BY state",
    )) {
      counts['${row['state']}'] = row['count'] as int;
    }
    final errors = store.db.select(
      "SELECT json_extract(body, '\$.error') AS error FROM github_queue WHERE json_valid(body) AND json_extract(body, '\$.state')='failed' AND json_extract(body, '\$.error') != '' ORDER BY rowid DESC LIMIT 3",
    );
    return _QueueSummary(
      (counts['pending'] ?? 0) + (counts['sending'] ?? 0),
      counts['sent'] ?? 0,
      counts['failed'] ?? 0,
      errors.map((row) => row['error']).whereType<String>().toList(),
    );
  }
}
