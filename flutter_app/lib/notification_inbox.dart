import 'app_localizations.dart';

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'models.dart';
import 'popup_ui.dart';
import 'workspace_ui.dart';

/// A responsive inbox surface; project data and read actions stay in Workspace.
class NotificationInbox extends StatelessWidget {
  const NotificationInbox({
    super.key,
    required this.notifications,
    required this.projects,
    required this.selectedProject,
    this.selectedNotificationKey,
    required this.unreadOnly,
    required this.mentionsOnly,
    required this.onProjectChanged,
    required this.onUnreadChanged,
    required this.onMentionsChanged,
    required this.onResetFilters,
    required this.onRefresh,
    required this.onRead,
    required this.onReadVisible,
    this.onSelect,
    this.onCloseDetail,
    this.onOpenTask,
  });

  final List<Map<String, dynamic>> notifications;
  final Map<String, String> projects;
  final String selectedProject;
  final String? selectedNotificationKey;
  final bool unreadOnly, mentionsOnly;
  final ValueChanged<String> onProjectChanged;
  final ValueChanged<bool> onUnreadChanged, onMentionsChanged;
  final VoidCallback onResetFilters, onRefresh;
  final ValueChanged<Map<String, dynamic>> onRead;
  final ValueChanged<List<Map<String, dynamic>>> onReadVisible;
  final ValueChanged<Map<String, dynamic>>? onSelect;
  final VoidCallback? onCloseDetail;
  final ValueChanged<Map<String, dynamic>>? onOpenTask;

  @override
  Widget build(BuildContext context) {
    final project = projects.containsKey(selectedProject)
        ? selectedProject
        : 'all';
    final scoped = notifications
        .where((n) => project == 'all' || n['projectPath'] == project)
        .toList();
    final matching = scoped
        .where((n) => !mentionsOnly || n['isMyMention'] == true)
        .toList();
    final filtered = matching
        .where((n) => !unreadOnly || n['read'] != true)
        .toList();
    final unread = matching.where((n) => n['read'] != true).length;
    final hasFilters = project != 'all' || unreadOnly || mentionsOnly;
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final notification in filtered) {
      groups.putIfAbsent(_dayLabel(notification), () => []).add(notification);
    }
    final selected = scoped
        .where(
          (notification) =>
              _notificationKey(notification) == selectedNotificationKey,
        )
        .firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final padding = constraints.maxWidth < 700 ? 18.0 : 24.0;
        final paneWidth = wide
            ? (constraints.maxWidth - 1) / 2
            : constraints.maxWidth;
        final width = max(0.0, paneWidth - padding * 2);
        final compact = width < 520;
        final list = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 20, padding, 12),
              child: WorkspaceSectionLabel(
                title: tr('내 작업 알림'),
                trailing: Text(
                  tr('안 읽음 {v0}개', args: {'v0': unread}),
                  style: WorkspaceUi.captionStyleOf(context),
                ),
              ),
            ),
            Padding(
              key: const Key('notification-filter-bar'),
              padding: EdgeInsets.fromLTRB(padding, 16, padding, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    label: tr('알림 프로젝트 선택'),
                    child: IeumSelect(
                      key: const Key('notification-project-filter'),
                      icon: Icons.folder_outlined,
                      value: project,
                      values: projects,
                      onChanged: onProjectChanged,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _filterButton(
                        context,
                        'notification-unread-filter',
                        tr('안 읽음'),
                        Icons.mark_email_unread_outlined,
                        unreadOnly,
                        () => onUnreadChanged(!unreadOnly),
                      ),
                      _filterButton(
                        context,
                        'notification-mentions-filter',
                        tr('내 멘션'),
                        Icons.alternate_email_rounded,
                        mentionsOnly,
                        () => onMentionsChanged(!mentionsOnly),
                      ),
                      if (hasFilters)
                        TextButton(
                          key: const Key('reset-notification-filters'),
                          onPressed: onResetFilters,
                          style: TextButton.styleFrom(
                            foregroundColor: WorkspaceUi.colors(context).muted,
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: Text(tr('초기화')),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: WorkspaceUi.colors(context).line),
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 14, padding, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('{v0}개', args: {'v0': filtered.length}),
                      style: TextStyle(
                        fontSize: 11,
                        color: WorkspaceUi.colors(context).muted,
                      ),
                    ),
                  ),
                  Text(
                    tr('최신순'),
                    style: TextStyle(
                      fontSize: 11,
                      color: WorkspaceUi.colors(context).muted,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: const PageStorageKey('notification-list-scroll'),
                padding: EdgeInsets.fromLTRB(padding, 0, padding, 24),
                children: [
                  if (filtered.isEmpty)
                    _emptyState(scoped.isEmpty)
                  else
                    for (final group in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        child: Text(
                          group.key,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: WorkspaceUi.colors(context).muted,
                          ),
                        ),
                      ),
                      for (final notification in group.value) ...[
                        _notificationRow(
                          context,
                          notification,
                          compact,
                          selectedNotificationKey ==
                              _notificationKey(notification),
                          wide: wide,
                        ),
                        const SizedBox(height: 6),
                      ],
                      const SizedBox(height: 12),
                    ],
                ],
              ),
            ),
          ],
        );
        final panes = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: list),
                  Container(
                    key: const Key('notification-center-divider'),
                    width: 1,
                    color: WorkspaceUi.colors(context).line,
                  ),
                  Expanded(
                    child: selected == null
                        ? _emptyDetail(context)
                        : _detailScroll(
                            context,
                            selected,
                            padding,
                            onClose: onCloseDetail,
                          ),
                  ),
                ],
              )
            : list;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 24, padding, 12),
              child: Row(
                children: [
                  Expanded(child: WorkspacePageHeader(title: tr('알림'))),
                  IconButton(
                    key: const Key('refresh-notifications'),
                    tooltip: tr('알림 새로고침'),
                    onPressed: onRefresh,
                    icon: const Icon(Icons.refresh_rounded, size: 19),
                  ),
                ],
              ),
            ),
            Expanded(child: panes),
          ],
        );
      },
    );
  }

  Widget _emptyDetail(BuildContext context) => Center(
    key: Key('notification-empty-detail'),
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        tr('상세 내용을 보기 위해 알림을 선택하세요.'),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: WorkspaceUi.colors(context).muted.withValues(alpha: .8),
        ),
      ),
    ),
  );
  String _notificationKey(Map<String, dynamic> notification) =>
      '${notification['projectPath']}:${notification['id']}';

  (String, IconData, Color) _eventInfo(
    BuildContext context,
    Map<String, dynamic> notification,
  ) => switch ('${notification['eventType'] ?? ''}') {
    'task.created' => (
      tr('작업 등록'),
      Icons.add_task_rounded,
      WorkspaceUi.colors(context).accent,
    ),
    'task.assigned' => (
      tr('작업 배정'),
      Icons.assignment_ind_outlined,
      WorkspaceUi.colors(context).accent,
    ),
    'task.moved' => (
      tr('상태 변경'),
      Icons.view_kanban_outlined,
      WorkspaceUi.colors(context).accent,
    ),
    'task.review' || 'task.reviewing' => (
      tr('검토 요청'),
      Icons.rate_review_outlined,
      WorkspaceUi.colors(context).warning,
    ),
    'task.done' => (
      tr('작업 완료'),
      Icons.task_alt_rounded,
      WorkspaceUi.colors(context).success,
    ),
    'task.rework' || 'task.rejected' => (
      tr('반려'),
      Icons.replay_rounded,
      WorkspaceUi.colors(context).danger,
    ),
    _ => (
      tr(statuses[notification['status']] ?? '작업 알림'),
      Icons.notifications_none_rounded,
      WorkspaceUi.colors(context).accent,
    ),
  };

  Widget _detailScroll(
    BuildContext context,
    Map<String, dynamic> notification,
    double padding, {
    bool narrow = false,
    VoidCallback? onClose,
    VoidCallback? onOpen,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(padding, 24, padding, 18),
          child: Row(
            children: [
              if (narrow) ...[
                IconButton(
                  key: const Key('notification-detail-back'),
                  tooltip: tr('알림 목록으로'),
                  onPressed: onClose,
                  icon: const Icon(Icons.arrow_back_rounded, size: 19),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  tr('알림 상세'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: WorkspaceUi.colors(context).ink,
                  ),
                ),
              ),
              if (notification['read'] != true)
                TextButton.icon(
                  key: const Key('notification-detail-mark-read'),
                  onPressed: () => onRead(notification),
                  icon: const Icon(Icons.done_rounded, size: 16),
                  label: Text(tr('읽음으로 표시')),
                  style: TextButton.styleFrom(
                    foregroundColor: WorkspaceUi.colors(context).muted,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              if (!narrow)
                IconButton(
                  key: const Key('notification-detail-close'),
                  tooltip: tr('알림 상세 닫기'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: WorkspaceUi.colors(context).line),
        Expanded(
          child: SingleChildScrollView(
            key: const PageStorageKey('notification-detail-scroll'),
            padding: EdgeInsets.fromLTRB(padding, 24, padding, 32),
            child: _detailCard(context, notification),
          ),
        ),
        if ('${notification['taskId'] ?? ''}'.isNotEmpty && onOpenTask != null)
          Container(
            padding: EdgeInsets.fromLTRB(padding, 12, padding, 16),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: WorkspaceUi.colors(context).line),
              ),
            ),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                key: const Key('notification-open-task'),
                onPressed: onOpen ?? () => onOpenTask!(notification),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: Text(tr('작업 열기')),
              ),
            ),
          ),
      ],
    );
  }

  Widget _detailCard(BuildContext context, Map<String, dynamic> notification) {
    final (eventLabel, eventIcon, eventColor) = _eventInfo(
      context,
      notification,
    );
    final occurred = DateTime.tryParse('${notification['createdAt'] ?? ''}')
        ?.toLocal();
    final timestamp = occurred == null
        ? tr('시간 미정')
        : '${occurred.year}.${occurred.month.toString().padLeft(2, '0')}.${occurred.day.toString().padLeft(2, '0')} '
              '${occurred.hour.toString().padLeft(2, '0')}:${occurred.minute.toString().padLeft(2, '0')}';
    final reason = '${notification['reason'] ?? ''}'.trim();
    final description = '${notification['taskDescription'] ?? ''}'.trim();
    final taskId = '${notification['taskId'] ?? ''}'.trim();
    final taskStatus = '${notification['taskStatus'] ?? ''}'.trim();
    final projectSlug = '${notification['projectSlug'] ?? ''}'.trim();
    final unread = notification['read'] != true;
    return Container(
      key: const Key('notification-detail'),
      width: double.infinity,
      padding: EdgeInsets.zero,
      decoration: BoxDecoration(
        color: WorkspaceUi.colors(context).surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(eventIcon, size: 18, color: eventColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  eventLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: eventColor,
                  ),
                ),
              ),
              Text(
                unread ? tr('안 읽음') : tr('읽음'),
                style: TextStyle(
                  fontSize: 11,
                  color: WorkspaceUi.colors(context).muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            tr('{v0}', args: {'v0': notification['title'] ?? tr('작업 알림')}),
            style: TextStyle(
              fontSize: 22,
              height: 1.45,
              fontWeight: FontWeight.w700,
              color: WorkspaceUi.colors(context).ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              '{v0} · {v1}',
              args: {
                'v0': notification['projectName'] ?? tr('프로젝트'),
                'v1': timestamp,
              },
            ),
            style: TextStyle(
              fontSize: 11,
              color: WorkspaceUi.colors(context).muted,
            ),
          ),
          if (projectSlug.isNotEmpty && projectSlug != '로컬') ...[
            const SizedBox(height: 4),
            Text(
              projectSlug,
              style: TextStyle(
                fontSize: 11,
                color: WorkspaceUi.colors(context).muted,
              ),
            ),
          ],
          const SizedBox(height: 22),
          Divider(height: 1, color: WorkspaceUi.colors(context).line),
          const SizedBox(height: 20),
          Text(
            tr('알림 내용'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: WorkspaceUi.colors(context).ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            reason.isEmpty ? eventLabel : reason,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: WorkspaceUi.colors(context).ink,
            ),
          ),
          if (taskId.isNotEmpty) ...[
            const SizedBox(height: 22),
            Divider(height: 1, color: WorkspaceUi.colors(context).line),
            const SizedBox(height: 20),
            Text(
              tr('작업 정보'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: WorkspaceUi.colors(context).ink,
              ),
            ),
            const SizedBox(height: 12),
            if (description.isNotEmpty) ...[
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.7,
                  color: WorkspaceUi.colors(context).ink,
                ),
              ),
              const SizedBox(height: 18),
            ],
            _detailField(
              context,
              tr('작업 ID'),
              _taskReference(taskId),
              tooltip: taskId,
            ),
            if (taskStatus.isNotEmpty)
              _detailField(
                context,
                tr('상태'),
                trStageName('${notification['status'] ?? ''}', taskStatus),
              ),
            _detailField(
              context,
              tr('담당 파트'),
              '${notification['taskPart'] ?? ''}',
            ),
            _detailField(
              context,
              tr('담당자'),
              '${notification['taskAssigneeName'] ?? ''}',
            ),
            _detailField(
              context,
              tr('검토자'),
              '${notification['taskReviewerName'] ?? ''}',
            ),
            _detailField(
              context,
              tr('우선순위'),
              tr('${notification['taskPriority'] ?? ''}'),
            ),
            _detailField(
              context,
              tr('마감일'),
              _displayDate('${notification['taskDueDate'] ?? ''}'),
            ),
          ],
        ],
      ),
    );
  }

  String _taskReference(String id) => id.startsWith('TASK-') && id.length >= 6
      ? 'IE-${id.substring(id.length - 6).toUpperCase()}'
      : id;

  String _displayDate(String value) {
    final date = DateTime.tryParse(value);
    return date == null
        ? value
        : '${date.year}.${date.month.toString().padLeft(2, '0')}.'
              '${date.day.toString().padLeft(2, '0')}';
  }

  Widget _detailField(
    BuildContext context,
    String label,
    String value, {
    String? tooltip,
  }) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: WorkspaceUi.colors(context).muted,
              ),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: tooltip ?? value,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 11,
                  color: WorkspaceUi.colors(context).ink,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterButton(
    BuildContext context,
    String key,
    String label,
    IconData icon,
    bool selected,
    VoidCallback onPressed,
  ) => Semantics(
    selected: selected,
    child: OutlinedButton.icon(
      key: Key(key),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        backgroundColor: selected
            ? WorkspaceUi.colors(context).accentSurface
            : WorkspaceUi.colors(context).surface,
        foregroundColor: selected
            ? WorkspaceUi.colors(context).accent
            : WorkspaceUi.colors(context).muted,
        side: BorderSide(
          color: selected
              ? WorkspaceUi.colors(context).accent.withValues(alpha: .3)
              : WorkspaceUi.colors(context).line,
        ),
        textStyle: const TextStyle(fontSize: 12, fontFamily: 'Malgun Gothic'),
      ),
      icon: Icon(selected ? Icons.check_rounded : icon, size: 16),
      label: Text(label),
    ),
  );

  Widget _emptyState(bool noNotifications) => Padding(
    key: const Key('notification-empty-state'),
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: WorkspaceEmptyState(
      icon: noNotifications
          ? Icons.notifications_none_rounded
          : Icons.filter_alt_outlined,
      title: noNotifications ? tr('아직 도착한 알림이 없습니다.') : tr('조건에 맞는 알림이 없습니다.'),
    ),
  );

  Widget _notificationRow(
    BuildContext context,
    Map<String, dynamic> n,
    bool compact,
    bool selected, {
    required bool wide,
  }) {
    final unread = n['read'] != true;
    final (label, icon, color) = _eventInfo(context, n);
    final date = DateTime.tryParse('${n['createdAt'] ?? ''}')?.toLocal();
    final time = date == null
        ? tr('시간 미정')
        : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final reason = '${n['reason'] ?? ''}'.trim();
    final background = selected
        ? WorkspaceUi.colors(context).accentSurface
        : unread
        ? WorkspaceUi.colors(context).subtle
        : WorkspaceUi.colors(context).background;
    return Material(
      key: ValueKey('notification-${n['projectPath']}-${n['id']}'),
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected
              ? WorkspaceUi.colors(context).accent.withValues(alpha: .3)
              : WorkspaceUi.colors(context).line,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onSelect == null
            ? null
            : () => _openDetail(context, n, wide: wide),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 17, color: color),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('{v0}', args: {'v0': n['title'] ?? tr('작업 알림')}),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                        color: WorkspaceUi.colors(context).ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          tr(
                            '{v0}',
                            args: {'v0': n['projectName'] ?? tr('프로젝트')},
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: WorkspaceUi.colors(context).muted,
                          ),
                        ),
                        Text(
                          label,
                          style: TextStyle(fontSize: 11, color: color),
                        ),
                        if (n['isMyMention'] == true)
                          Text(
                            tr('@ 내 멘션'),
                            style: TextStyle(
                              fontSize: 11,
                              color: WorkspaceUi.colors(context).accent,
                            ),
                          ),
                        if (compact)
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 10,
                              color: WorkspaceUi.colors(context).muted,
                            ),
                          ),
                      ],
                    ),
                    if (reason.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Text(
                        reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: WorkspaceUi.colors(context).muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: compact ? 28 : 48,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (!compact)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                        child: Text(
                          time,
                          style: TextStyle(
                            fontSize: 10,
                            color: WorkspaceUi.colors(context).muted,
                          ),
                        ),
                      ),
                    if (unread)
                      IconButton(
                        key: ValueKey('mark-notification-read-${n['id']}'),
                        tooltip: tr('읽음으로 표시'),
                        onPressed: () => onRead(n),
                        constraints: const BoxConstraints.tightFor(
                          width: 28,
                          height: 28,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.done_rounded,
                          size: 16,
                          color: WorkspaceUi.colors(context).muted,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(
    BuildContext context,
    Map<String, dynamic> notification, {
    required bool wide,
  }) {
    onSelect?.call(notification);
    if (notification['read'] != true) onRead(notification);
    if (wide) return;
    final size = MediaQuery.sizeOf(context);
    unawaited(
      showDialog<bool>(
        context: context,
        builder: (dialogContext) => Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: min(560, size.width - 48),
            height: min(680, size.height - 48),
            child: _detailScroll(
              context,
              {...notification, 'read': true},
              24,
              narrow: true,
              onClose: () => Navigator.pop(dialogContext),
              onOpen: () => Navigator.pop(dialogContext, true),
            ),
          ),
        ),
      ).then((openTask) {
        onCloseDetail?.call();
        if (openTask == true) onOpenTask?.call(notification);
      }),
    );
  }

  String _dayLabel(Map<String, dynamic> notification) {
    final date = DateTime.tryParse('${notification['createdAt'] ?? ''}')
        ?.toLocal();
    if (date == null) return tr('이전 기록');
    final now = DateTime.now();
    final day = DateTime(date.year, date.month, date.day);
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return tr('오늘');
    if (day == DateTime(now.year, now.month, now.day - 1)) return tr('어제');
    return tr(
      '{v0}년 {v1}월 {v2}일',
      args: {'v0': date.year, 'v1': date.month, 'v2': date.day},
    );
  }
}
