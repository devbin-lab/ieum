import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'workspace_ui.dart';

class ProjectTimelineView extends StatelessWidget {
  const ProjectTimelineView({
    super.key,
    required this.projectName,
    required this.activityHistory,
    required this.onRefresh,
    this.onOpenTask,
  });

  final String projectName;
  final List<Map<String, dynamic>> activityHistory;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, dynamic>>? onOpenTask;

  @override
  Widget build(BuildContext context) => _TimelineContent(
    projectName: projectName,
    activityHistory: activityHistory,
    onRefresh: onRefresh,
    onOpenTask: onOpenTask,
  );
}

class _TimelineContent extends StatefulWidget {
  const _TimelineContent({
    required this.projectName,
    required this.activityHistory,
    required this.onRefresh,
    this.onOpenTask,
  });

  final String projectName;
  final List<Map<String, dynamic>> activityHistory;
  final VoidCallback onRefresh;
  final ValueChanged<Map<String, dynamic>>? onOpenTask;

  @override
  State<_TimelineContent> createState() => _TimelineContentState();
}

class _TimelineContentState extends State<_TimelineContent> {
  String _query = '';

  @override
  void didUpdateWidget(covariant _TimelineContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectName != widget.projectName) _query = '';
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final events =
        widget.activityHistory
            .where(
              (event) =>
                  query.isEmpty ||
                  [
                    event['taskTitle'],
                    event['message'],
                    event['actorName'],
                  ].join(' ').toLowerCase().contains(query),
            )
            .toList()
          ..sort((a, b) {
            final first = _eventTime(a);
            final second = _eventTime(b);
            if (first == null) return second == null ? 0 : 1;
            if (second == null) return -1;
            return second.compareTo(first);
          });
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final event in events) {
      groups.putIfAbsent(_dayLabel(event), () => []).add(event);
    }
    return LayoutBuilder(
      builder: (context, bounds) {
        final padding = bounds.maxWidth < 600
            ? 16.0
            : WorkspaceUi.contentPadding;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 24, padding, 20),
              child: WorkspacePageHeader(
                title: tr('타임라인'),
                contextLabel: widget.projectName,
                actions: [
                  IconButton(
                    key: const Key('project-timeline-refresh'),
                    tooltip: tr('변경 기록 새로고침'),
                    onPressed: widget.onRefresh,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 16,
                runSpacing: 10,
                children: [
                  SizedBox(
                    width: (bounds.maxWidth - padding * 2).clamp(0.0, 380.0),
                    child: TextField(
                      key: ValueKey(
                        'project-timeline-search-${widget.projectName}',
                      ),
                      onChanged: (value) => setState(() => _query = value),
                      style: TextStyle(
                        fontSize: 12,
                        color: WorkspaceUi.colors(context).ink,
                      ),
                      decoration: InputDecoration(
                        hintText: tr('작업·내용·작업자 검색'),
                        hintStyle: WorkspaceUi.captionStyleOf(context),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        filled: true,
                        fillColor: WorkspaceUi.colors(context).surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: WorkspaceUi.colors(context).line,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: WorkspaceUi.colors(context).line,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Text(
                    query.isEmpty
                        ? tr('변경 기록 {v0}개', args: {'v0': events.length})
                        : tr(
                            '검색 결과 {v0}개 · 전체 {v1}개',
                            args: {
                              'v0': events.length,
                              'v1': widget.activityHistory.length,
                            },
                          ),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: WorkspaceUi.colors(context).line),
            Expanded(
              child: events.isEmpty
                  ? WorkspaceEmptyState(
                      icon: query.isEmpty
                          ? Icons.history_rounded
                          : Icons.search_rounded,
                      title: query.isEmpty
                          ? tr('아직 변경 기록이 없습니다.')
                          : tr('검색 결과가 없습니다.'),
                      message: query.isEmpty
                          ? tr('작업을 등록하거나 변경하면 여기에 표시됩니다.')
                          : tr('다른 검색어를 입력해 보세요.'),
                    )
                  : ListView(
                      key: PageStorageKey(
                        'project-timeline-scroll-${widget.projectName}',
                      ),
                      padding: EdgeInsets.fromLTRB(padding, 12, padding, 24),
                      children: [
                        for (final group in groups.entries) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 12, bottom: 14),
                            child: Text(
                              group.key,
                              style: WorkspaceUi.sectionStyleOf(context),
                            ),
                          ),
                          for (var i = 0; i < group.value.length; i++)
                            _TimelineEntry(
                              event: group.value[i],
                              first: i == 0,
                              last: i == group.value.length - 1,
                              onOpenTask: widget.onOpenTask,
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

DateTime? _eventTime(Map<String, dynamic> event) =>
    DateTime.tryParse('${event['createdAt'] ?? ''}')?.toLocal();

String _dayLabel(Map<String, dynamic> event) {
  final date = _eventTime(event);
  return date == null
      ? tr('날짜 없음')
      : tr(
          '{v0}년 {v1}월 {v2}일',
          args: {'v0': date.year, 'v1': date.month, 'v2': date.day},
        );
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.event,
    required this.first,
    required this.last,
    this.onOpenTask,
  });

  final Map<String, dynamic> event;
  final bool first, last;
  final ValueChanged<Map<String, dynamic>>? onOpenTask;

  @override
  Widget build(BuildContext context) {
    final (label, icon, color) = switch ('${event['kind'] ?? ''}') {
      'created' => (
        tr('작업 등록'),
        Icons.add_task_rounded,
        WorkspaceUi.colors(context).success,
      ),
      'transition' => (
        tr('상태·담당자 변경'),
        Icons.swap_horiz_rounded,
        WorkspaceUi.colors(context).accent,
      ),
      'comment' => (
        tr('댓글'),
        Icons.mode_comment_outlined,
        WorkspaceUi.colors(context).warning,
      ),
      _ => (
        tr('변경'),
        Icons.edit_note_rounded,
        WorkspaceUi.colors(context).muted,
      ),
    };
    final time = _eventTime(event);
    final timeLabel = time == null
        ? ''
        : '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final title = '${event['taskTitle'] ?? ''}'.trim();
    final message = '${event['message'] ?? ''}'.trim();
    final actor = '${event['actorName'] ?? ''}'.trim();
    final canOpen =
        onOpenTask != null && '${event['taskId'] ?? ''}'.trim().isNotEmpty;
    return Stack(
      key: ValueKey('project-timeline-event-${event['id']}'),
      children: [
        Positioned(
          left: 14,
          top: first ? 16 : 0,
          bottom: last ? 28 : 0,
          child: SizedBox(
            width: 1,
            child: ColoredBox(color: WorkspaceUi.colors(context).line),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 40, bottom: 16),
          child: WorkspacePanel(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title.isEmpty ? tr('프로젝트 활동') : title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: WorkspaceUi.sectionStyleOf(context),
                      ),
                    ),
                    if (timeLabel.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Tooltip(
                        message: '${_dayLabel(event)} $timeLabel',
                        child: Text(
                          timeLabel,
                          style: WorkspaceUi.captionStyleOf(context),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                Text(label, style: TextStyle(fontSize: 11, color: color)),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    trEventMessage(message),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: WorkspaceUi.colors(context).ink,
                    ),
                  ),
                ],
                if (actor.isNotEmpty || canOpen) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          actor,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: WorkspaceUi.captionStyleOf(context),
                        ),
                      ),
                      if (canOpen)
                        TextButton.icon(
                          key: ValueKey('project-timeline-open-${event['id']}'),
                          onPressed: () => onOpenTask!(event),
                          icon: const Icon(
                            Icons.arrow_outward_rounded,
                            size: 14,
                          ),
                          label: Text(tr('작업 열기')),
                          style: TextButton.styleFrom(
                            foregroundColor: WorkspaceUi.colors(context).accent,
                            textStyle: const TextStyle(fontSize: 11),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(0, 30),
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        Positioned(
          left: 1,
          top: 9,
          child: Container(
            width: 27,
            height: 27,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .1),
              shape: BoxShape.circle,
              border: Border.all(
                color: WorkspaceUi.colors(context).background,
                width: 2,
              ),
            ),
            child: Icon(icon, size: 15, color: color),
          ),
        ),
      ],
    );
  }
}
