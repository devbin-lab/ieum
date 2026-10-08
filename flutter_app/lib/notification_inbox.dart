import 'dart:math';

import 'package:flutter/material.dart';

import 'models.dart';
import 'popup_ui.dart';

const _accent = Color(0xff7963d5),
    _ink = Color(0xff302b3c),
    _muted = Color(0xff6e687b),
    _line = Color(0xffe1e3e6);

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
    final selected = notifications
        .where((n) => _notificationKey(n) == selectedNotificationKey)
        .firstOrNull;
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < 700 ? 20.0 : 36.0;
        final wide = constraints.maxWidth >= 900;
        final paneWidth = wide
            ? (constraints.maxWidth - 1) / 2
            : constraints.maxWidth;
        final width = max(0.0, paneWidth - padding * 2);
        final compact = width < 600;
        final actions = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const Key('refresh-notifications'),
              tooltip: '알림 새로고침',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 20),
            ),
          ],
        );
        final list = SingleChildScrollView(
          key: const PageStorageKey('notification-list-scroll'),
          padding: EdgeInsets.fromLTRB(padding, wide ? 32 : 24, padding, 36),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '알림',
                          style: TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -1,
                            color: _ink,
                          ),
                        ),
                      ),
                      if (!compact) actions,
                    ],
                  ),
                  if (compact) ...[
                    Align(alignment: Alignment.centerRight, child: actions),
                  ],
                  SizedBox(height: compact ? 14 : 24),
                  Container(
                    key: const Key('notification-filter-bar'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: _line),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: LayoutBuilder(
                      builder: (context, filterConstraints) {
                        return Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: filterConstraints.maxWidth < 560
                                  ? filterConstraints.maxWidth
                                  : 260,
                              child: Semantics(
                                label: '알림 프로젝트 선택',
                                child: IeumSelect(
                                  key: const Key('notification-project-filter'),
                                  icon: Icons.folder_outlined,
                                  value: project,
                                  values: projects,
                                  onChanged: onProjectChanged,
                                ),
                              ),
                            ),
                            _filterButton(
                              'notification-unread-filter',
                              '안 읽음',
                              Icons.mark_email_unread_outlined,
                              unreadOnly,
                              () => onUnreadChanged(!unreadOnly),
                            ),
                            _filterButton(
                              'notification-mentions-filter',
                              '내 멘션',
                              Icons.alternate_email_rounded,
                              mentionsOnly,
                              () => onMentionsChanged(!mentionsOnly),
                            ),
                            if (hasFilters)
                              TextButton.icon(
                                key: const Key('reset-notification-filters'),
                                onPressed: onResetFilters,
                                icon: const Icon(
                                  Icons.restart_alt_rounded,
                                  size: 17,
                                ),
                                label: const Text('초기화'),
                                style: TextButton.styleFrom(
                                  foregroundColor: _muted,
                                  minimumSize: const Size(0, 42),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        '알림 내역',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _ink,
                        ),
                      ),
                      Text(
                        '${filtered.length}개 · 안 읽음 $unread개',
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                      const Text(
                        '최신순',
                        style: TextStyle(fontSize: 11, color: _muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (filtered.isEmpty)
                    _emptyState(scoped.isEmpty)
                  else
                    for (final group in groups.entries) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text(
                          group.key,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _muted,
                          ),
                        ),
                      ),
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        foregroundDecoration: BoxDecoration(
                          border: Border.all(color: _line),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < group.value.length; i++) ...[
                              if (i > 0)
                                const Divider(
                                  height: 1,
                                  thickness: 1,
                                  color: _line,
                                ),
                              _notificationRow(
                                group.value[i],
                                compact,
                                selectedNotificationKey ==
                                    _notificationKey(group.value[i]),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                    ],
                ],
              ),
            ),
          ),
        );
        if (!wide) {
          return selected == null
              ? list
              : _detailScroll(selected, padding, narrow: true);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: list),
            Container(
              key: const Key('notification-center-divider'),
              width: 1,
              color: _line,
            ),
            Expanded(child: _detailScroll(selected, padding)),
          ],
        );
      },
    );
  }

  String _notificationKey(Map<String, dynamic> notification) =>
      '${notification['projectPath']}:${notification['id']}';

  (String, IconData, Color) _eventInfo(Map<String, dynamic> notification) =>
      switch ('${notification['eventType'] ?? ''}') {
        'task.created' => ('새 작업 등록', Icons.add_task_rounded, _accent),
        'task.assigned' => ('작업 배정', Icons.assignment_ind_outlined, _accent),
        'task.moved' => ('단계 변경', Icons.view_kanban_outlined, _accent),
        'task.review' || 'task.reviewing' => (
          '검토 요청',
          Icons.rate_review_outlined,
          const Color(0xff8c652d),
        ),
        'task.done' => (
          '작업 완료',
          Icons.task_alt_rounded,
          const Color(0xff417458),
        ),
        'task.rework' || 'task.rejected' => (
          '반려',
          Icons.replay_rounded,
          const Color(0xffa0445a),
        ),
        _ => (
          statuses[notification['status']] ?? '작업 알림',
          Icons.notifications_none_rounded,
          _accent,
        ),
      };

  Widget _detailScroll(
    Map<String, dynamic>? notification,
    double padding, {
    bool narrow = false,
  }) {
    if (notification == null) {
      return Center(
        child: Padding(
          key: const Key('notification-detail-empty'),
          padding: EdgeInsets.symmetric(horizontal: padding),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.mark_email_read_outlined, size: 30, color: _accent),
              SizedBox(height: 16),
              Text(
                '상세 내용을 보기 위해 알림을 선택하세요.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xff5b5668),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return SingleChildScrollView(
      key: const PageStorageKey('notification-detail-scroll'),
      padding: EdgeInsets.fromLTRB(padding, narrow ? 24 : 32, padding, 36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (narrow)
                IconButton(
                  key: const Key('notification-detail-back'),
                  tooltip: '알림 목록으로',
                  onPressed: onCloseDetail,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              const Expanded(
                child: Text(
                  '알림 상세',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
              ),
              if (!narrow)
                IconButton(
                  key: const Key('notification-detail-close'),
                  tooltip: '상세 닫기',
                  onPressed: onCloseDetail,
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _detailCard(notification),
        ],
      ),
    );
  }

  Widget _detailCard(Map<String, dynamic> notification) {
    final (eventLabel, eventIcon, eventColor) = _eventInfo(notification);
    final occurred = DateTime.tryParse('${notification['createdAt'] ?? ''}')
        ?.toLocal();
    final timestamp = occurred == null
        ? '시간 정보 없음'
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
      padding: const EdgeInsets.all(24),
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
                unread ? '안 읽음' : '읽음',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            '${notification['title'] ?? '작업 알림'}',
            style: const TextStyle(
              fontSize: 18,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${notification['projectName'] ?? '프로젝트'} · $timestamp',
            style: const TextStyle(fontSize: 11, color: _muted),
          ),
          if (projectSlug.isNotEmpty && projectSlug != '로컬') ...[
            const SizedBox(height: 4),
            Text(
              projectSlug,
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ],
          const SizedBox(height: 22),
          const Divider(height: 1, color: _line),
          const SizedBox(height: 20),
          const Text(
            '알림 내용',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            reason.isEmpty ? '$eventLabel 알림입니다.' : reason,
            style: const TextStyle(fontSize: 13, height: 1.6, color: _ink),
          ),
          if (taskId.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Divider(height: 1, color: _line),
            const SizedBox(height: 20),
            const Text(
              '현재 작업',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: _ink,
              ),
            ),
            const SizedBox(height: 12),
            if (description.isNotEmpty) ...[
              Text(
                description,
                style: const TextStyle(fontSize: 12, height: 1.7, color: _ink),
              ),
              const SizedBox(height: 18),
            ],
            _detailField('작업 ID', taskId),
            if (taskStatus.isNotEmpty) _detailField('현재 상태', taskStatus),
            _detailField('담당 파트', '${notification['taskPart'] ?? ''}'),
            _detailField('담당자', '${notification['taskAssigneeName'] ?? ''}'),
            _detailField('검토자', '${notification['taskReviewerName'] ?? ''}'),
            _detailField('우선순위', '${notification['taskPriority'] ?? ''}'),
            _detailField('마감일', '${notification['taskDueDate'] ?? ''}'),
          ],
          if (unread) ...[
            const SizedBox(height: 24),
            OutlinedButton.icon(
              key: const Key('notification-detail-mark-read'),
              onPressed: () => onRead(notification),
              icon: const Icon(Icons.done_rounded, size: 17),
              label: const Text('읽음 처리'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailField(String label, String value) {
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
              style: const TextStyle(fontSize: 11, color: _muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 11, color: _ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterButton(
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
        minimumSize: const Size(0, 42),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        backgroundColor: selected ? const Color(0xfff1edfc) : Colors.white,
        foregroundColor: selected ? _accent : _muted,
        side: BorderSide(color: selected ? const Color(0xffd6ccf4) : _line),
        textStyle: const TextStyle(fontSize: 12, fontFamily: 'Malgun Gothic'),
      ),
      icon: Icon(selected ? Icons.check_rounded : icon, size: 16),
      label: Text(label),
    ),
  );

  Widget _emptyState(bool noNotifications) => Container(
    key: const Key('notification-empty-state'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 44),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: _line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xfff1edfc),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            noNotifications
                ? Icons.notifications_none_rounded
                : Icons.filter_alt_outlined,
            size: 26,
            color: _accent,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          noNotifications ? '아직 도착한 알림이 없습니다.' : '조건에 맞는 알림이 없습니다.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _ink,
          ),
        ),
        const SizedBox(height: 8),
        if (noNotifications)
          const Text(
            '내게 배정된 작업이나 검토 요청이 도착하면\n시간순으로 이곳에 쌓입니다.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.7, color: _muted),
          ),
      ],
    ),
  );

  Widget _notificationRow(Map<String, dynamic> n, bool compact, bool selected) {
    final unread = n['read'] != true;
    final (label, icon, color) = _eventInfo(n);
    final date = DateTime.tryParse('${n['createdAt'] ?? ''}')?.toLocal();
    final time = date == null
        ? '시간 미상'
        : '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    final reason = '${n['reason'] ?? ''}'.trim();
    return InkWell(
      onTap: onSelect == null ? null : () => onSelect!(n),
      child: Container(
        key: ValueKey('notification-${n['projectPath']}-${n['id']}'),
        color: selected
            ? const Color(0xffeae6f7)
            : unread
            ? const Color(0xffeef0f0)
            : const Color(0xfff5f6f6),
        padding: EdgeInsets.all(compact ? 14 : 18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 19, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${n['title'] ?? '작업 알림'}',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '${n['projectName'] ?? '프로젝트'}',
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                      Text(label, style: TextStyle(fontSize: 11, color: color)),
                      if (n['isMyMention'] == true)
                        const Text(
                          '@ 내 멘션',
                          style: TextStyle(fontSize: 11, color: _accent),
                        ),
                      if (compact)
                        Text(
                          time,
                          style: const TextStyle(fontSize: 11, color: _muted),
                        ),
                    ],
                  ),
                  if (reason.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      reason,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: _muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: compact ? 32 : 82,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!compact)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, bottom: 4),
                      child: Text(
                        time,
                        style: const TextStyle(fontSize: 11, color: _muted),
                      ),
                    ),
                  if (unread)
                    IconButton(
                      key: ValueKey('mark-notification-read-${n['id']}'),
                      tooltip: '읽음 처리',
                      onPressed: () => onRead(n),
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.done_rounded,
                        size: 18,
                        color: _accent,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _dayLabel(Map<String, dynamic> notification) {
    final date = DateTime.tryParse('${notification['createdAt'] ?? ''}')
        ?.toLocal();
    if (date == null) return '이전 알림';
    final now = DateTime.now();
    final day = DateTime(date.year, date.month, date.day);
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return '오늘';
    if (day == DateTime(now.year, now.month, now.day - 1)) return '어제';
    return '${date.year}년 ${date.month}월 ${date.day}일';
  }
}
