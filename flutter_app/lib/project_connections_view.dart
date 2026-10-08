import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'store.dart';

const _ink = Color(0xff253047);
const _muted = Color(0xff737e90);
const _line = Color(0xffe3e7ed);
const _accent = Color(0xff7467c6);

/// A read-only overview of the real project and its local synchronization queue.
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
      setState(() => _message = '${_time(sync.retryAt!)} 이후 다시 시도할 수 있습니다.');
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
              : '동기화를 완료하지 못했습니다. 연결 설정에서 원인을 확인해 주세요.';
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
        configError = '저장된 연결 설정을 읽지 못했습니다. 연결 설정을 확인해 주세요.';
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
        if (store.meta('github.recoveryNotice').isNotEmpty)
          store.meta('github.recoveryNotice'),
        ...queue.errors,
        ...?sync?.autoMergeErrors.values.take(3),
      };
      return LayoutBuilder(
        builder: (context, constraints) {
          final padding = constraints.maxWidth < 640 ? 18.0 : 32.0;
          final available = constraints.maxWidth - padding * 2;
          final columns = available >= 820
              ? 4
              : available >= 370
              ? 2
              : 1;
          final metricWidth = (available - 12 * (columns - 1)) / columns;
          return ListView(
            key: const Key('connections-content'),
            padding: EdgeInsets.all(padding),
            children: [
              const Text(
                '연결',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '팀의 변경이 어디까지 반영되었는지 확인하세요.',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
              const SizedBox(height: 26),
              _section(
                icon: Icons.cloud_outlined,
                title: connected ? 'GitHub 작업 공간' : '작업 공간 연결',
                children: [
                  Text(
                    connected ? config!.slug : 'GitHub 저장소를 연결해 팀과 작업을 공유하세요.',
                    key: const Key('connections-repository'),
                    style: TextStyle(
                      fontSize: connected ? 17 : 14,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                    ),
                  ),
                  if (connected) ...[
                    const SizedBox(height: 8),
                    Text(
                      '통합 브랜치 · ${config!.base}',
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _badge(
                          busy
                              ? '동기화 중'
                              : waiting
                              ? '요청 제한 대기'
                              : enabled
                              ? '자동 동기화 켜짐'
                              : '자동 동기화 꺼짐',
                          enabled && !waiting
                              ? const Color(0xff4e8e77)
                              : _muted,
                        ),
                        _badge(
                          config.autoMerge ? '자동 통합' : '통합 승인 대기',
                          _accent,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      lastPull == null
                          ? '아직 동기화 기록이 없습니다.'
                          : '마지막 가져오기 · ${_time(lastPull)}',
                      key: const Key('connections-last-pull'),
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                    if (waiting) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${_time(retryAt!)} 이후 재시도합니다.',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xffa27739),
                        ),
                      ),
                    ],
                  ] else ...[
                    const SizedBox(height: 8),
                    const Text(
                      '프로젝트의 연결 설정에서 저장소와 동기화 상태를 확인할 수 있습니다.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: _muted,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      if (enabled)
                        FilledButton.icon(
                          key: const Key('connections-sync-now'),
                          onPressed: busy ? null : _synchronize,
                          icon: busy
                              ? const SizedBox(
                                  width: 15,
                                  height: 15,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.sync, size: 17),
                          label: Text(busy ? '동기화 중…' : '지금 동기화'),
                        ),
                      OutlinedButton.icon(
                        key: const Key('connections-open-settings'),
                        onPressed: widget.onOpenSettings,
                        icon: const Icon(Icons.tune, size: 17),
                        label: Text(connected ? '연결 설정 · 문제 해결' : '연결 설정 열기'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _metric(
                    metricWidth,
                    '전송 대기',
                    queue.pending,
                    '이 컴퓨터에 저장됨',
                    Icons.cloud_upload_outlined,
                  ),
                  _metric(
                    metricWidth,
                    '통합 대기',
                    queue.sent,
                    '전송 완료 · 팀 반영 전',
                    Icons.merge_outlined,
                  ),
                  _metric(
                    metricWidth,
                    '전송 실패',
                    queue.failed,
                    '원인 확인 후 재시도',
                    Icons.error_outline,
                    warning: queue.failed > 0,
                  ),
                  _metric(
                    metricWidth,
                    '충돌 작업',
                    conflicts,
                    '개인 변경을 보존 중',
                    Icons.call_split,
                    warning: conflicts > 0,
                  ),
                ],
              ),
              if (issues.isNotEmpty || conflicts > 0) ...[
                const SizedBox(height: 16),
                _section(
                  icon: Icons.info_outline,
                  title: '확인이 필요한 내용',
                  children: [
                    if (conflicts > 0)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          '같은 작업에 서로 다른 변경이 있습니다. 연결 설정에서 내용을 비교하고 복구할 수 있습니다.',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: _ink,
                          ),
                        ),
                      ),
                    for (final issue in issues.take(5))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          issue,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: _muted,
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: widget.onOpenSettings,
                      child: const Text('동기화 상세 확인'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              _section(
                icon: Icons.people_outline,
                title: '팀과 파트',
                children: [
                  Text(
                    '${project?.people.where((person) => person.canMutate).length ?? 0}명 참여 중 · ${project?.parts.length ?? 0}개 파트',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '참여자의 소속 파트는 작업 전달과 처리 대상의 기준이 됩니다.',
                    style: TextStyle(fontSize: 12, height: 1.6, color: _muted),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('connections-open-members'),
                    onPressed: widget.onOpenMembers,
                    icon: const Icon(Icons.group_outlined, size: 17),
                    label: const Text('참여자 관리'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                '로컬 저장 → GitHub 전송 → 팀 통합 → 최신 작업 가져오기\n동기화와 자동 전달은 앱이 실행 중일 때 동작합니다.',
                style: TextStyle(fontSize: 11, height: 1.7, color: _muted),
              ),
            ],
          );
        },
      );
    },
  );
}

Widget _section({
  required IconData icon,
  required String title,
  required List<Widget> children,
}) => Container(
  padding: const EdgeInsets.all(20),
  decoration: BoxDecoration(
    color: Colors.white,
    border: Border.all(color: _line),
    borderRadius: BorderRadius.circular(14),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(icon, size: 18, color: _accent),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _muted,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      ...children,
    ],
  ),
);

Widget _badge(String text, Color color) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .09),
    borderRadius: BorderRadius.circular(8),
  ),
  child: Text(
    text,
    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
  ),
);

Widget _metric(
  double width,
  String title,
  int count,
  String caption,
  IconData icon, {
  bool warning = false,
}) => SizedBox(
  width: width,
  child: Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: warning ? const Color(0xffbe8059) : _muted,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: warning ? const Color(0xffbe8059) : _ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(caption, style: const TextStyle(fontSize: 10, color: _muted)),
      ],
    ),
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
      ? '오늘 $time'
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
