import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';

const _ink = Color(0xff293445),
    _muted = Color(0xff748091),
    _line = Color(0xffe6eaf0),
    _accent = Color(0xff7468c5),
    _surface = Color(0xfff7f9fc);

enum _ScheduleMode { calendar, timeline }

/// A projection of project tasks: opening the schedule never creates records.
class ProjectScheduleView extends StatefulWidget {
  const ProjectScheduleView({
    super.key,
    required this.store,
    required this.onOpenTask,
    required this.onEditTask,
    required this.onCreateTask,
  });

  final TaskStore store;
  final ValueChanged<WorkTask> onOpenTask, onEditTask;
  final ValueChanged<DateTime> onCreateTask;

  @override
  State<ProjectScheduleView> createState() => _ProjectScheduleViewState();
}

class _ProjectScheduleViewState extends State<ProjectScheduleView> {
  final search = TextEditingController();
  final timelineHorizontal = ScrollController();
  late DateTime selected = _day(DateTime.now());
  late DateTime month = DateTime(selected.year, selected.month);
  _ScheduleMode mode = _ScheduleMode.calendar;
  bool mine = false, showCompleted = false;

  static DateTime _day(DateTime value) =>
      DateTime(value.year, value.month, value.day);
  static String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  DateTime? _due(WorkTask task) => DateTime.tryParse(task.dueDate);
  bool _overdue(WorkTask task) =>
      !widget.store.isCompleted(task) &&
      (_due(task)?.isBefore(_day(DateTime.now())) ?? false);
  bool _isMine(WorkTask task) => widget.store.isAssignedToMe(task);

  @override
  void dispose() {
    search.dispose();
    timelineHorizontal.dispose();
    super.dispose();
  }

  void _moveMonth(int step) => setState(() {
    month = DateTime(month.year, month.month + step);
    selected = DateTime(
      month.year,
      month.month,
      math.min(selected.day, DateTime(month.year, month.month + 1, 0).day),
    );
  });

  void _today() => setState(() {
    selected = _day(DateTime.now());
    month = DateTime(selected.year, selected.month);
  });

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final query = search.text.trim().toLowerCase();
      final tasks =
          widget.store.tasks.where((task) {
            return (task.data['archivedAt'] as String? ?? '').isEmpty &&
                (showCompleted || !widget.store.isCompleted(task)) &&
                (!mine || _isMine(task)) &&
                (query.isEmpty ||
                    '${task.title} ${task.id} ${task.part}'
                        .toLowerCase()
                        .contains(query));
          }).toList()..sort((a, b) {
            final order = (a.dueDate.isEmpty ? '9999' : a.dueDate).compareTo(
              b.dueDate.isEmpty ? '9999' : b.dueDate,
            );
            return order == 0 ? a.title.compareTo(b.title) : order;
          });
      return Material(
        key: const Key('schedule-content'),
        color: Colors.white,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final inset = bounds.maxWidth < 700 ? 16.0 : 28.0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(80, bounds.maxHeight * .48),
                  ),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(inset, 22, inset, 18),
                      child: _header(tasks, bounds.maxWidth - inset * 2),
                    ),
                  ),
                ),
                const Divider(height: 1, color: _line),
                Expanded(
                  child: mode == _ScheduleMode.calendar
                      ? _calendar(tasks, bounds.maxWidth)
                      : _timeline(tasks),
                ),
              ],
            );
          },
        ),
      );
    },
  );

  Widget _header(List<WorkTask> tasks, double width) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 16,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            '일정',
            style: TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w700,
              color: _ink,
            ),
          ),
          Text(
            '${tasks.length}개 작업 · 지연 ${tasks.where(_overdue).length}개',
            style: const TextStyle(fontSize: 12, color: _muted),
          ),
          if (widget.store.canCreate)
            FilledButton.icon(
              key: const Key('schedule-create'),
              onPressed: () => widget.onCreateTask(selected),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('작업 등록'),
            ),
        ],
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 14,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: math.min(width, 270),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${month.year}년 ${month.month}월',
                    key: const Key('schedule-month'),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _ink,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('schedule-previous-month'),
                  tooltip: '이전 달',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _moveMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded, size: 20),
                ),
                IconButton(
                  key: const Key('schedule-next-month'),
                  tooltip: '다음 달',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _moveMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
                TextButton(onPressed: _today, child: const Text('오늘')),
              ],
            ),
          ),
          SegmentedButton<_ScheduleMode>(
            key: const Key('schedule-mode'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: _ScheduleMode.calendar,
                icon: Icon(Icons.calendar_month_outlined, size: 17),
                label: Text('달력'),
              ),
              ButtonSegment(
                value: _ScheduleMode.timeline,
                icon: Icon(Icons.view_timeline_outlined, size: 17),
                label: Text('타임라인'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (value) => setState(() => mode = value.first),
            style: SegmentedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
              foregroundColor: _muted,
              selectedForegroundColor: _accent,
              selectedBackgroundColor: const Color(0xfff0edfb),
              side: const BorderSide(color: _line),
            ),
          ),
          SizedBox(
            width: math.min(width, 230),
            child: TextField(
              key: const Key('schedule-search'),
              controller: search,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12),
              decoration: InputDecoration(
                hintText: '일정 검색',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '검색 초기화',
                        onPressed: () => setState(search.clear),
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(9),
                  borderSide: const BorderSide(color: _line),
                ),
              ),
            ),
          ),
          FilterChip(
            key: const Key('schedule-mine'),
            label: const Text('내 일정'),
            selected: mine,
            onSelected: (value) => setState(() => mine = value),
          ),
          FilterChip(
            key: const Key('schedule-completed'),
            label: const Text('완료 포함'),
            selected: showCompleted,
            onSelected: (value) => setState(() => showCompleted = value),
          ),
        ],
      ),
    ],
  );

  Widget _calendar(List<WorkTask> tasks, double width) {
    final narrow = width < 700;
    final split = width >= 1100;
    final dates = <String, List<WorkTask>>{};
    final first = DateTime(month.year, month.month, 1);
    final start = DateTime(
      first.year,
      first.month,
      first.day - first.weekday + 1,
    );
    // Bound work to the visible grid, even for tasks spanning decades.
    for (var offset = 0; offset < 42; offset++) {
      final day = DateTime(start.year, start.month, start.day + offset);
      dates[_date(day)] = tasks.where((t) => taskScheduledOn(t, day)).toList();
    }
    final calendar = _monthGrid(tasks, dates, narrow: narrow);
    if (split) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: SingleChildScrollView(child: calendar)),
          const VerticalDivider(width: 1, color: _line),
          SizedBox(width: 330, child: _agenda(tasks)),
        ],
      );
    }
    return CustomScrollView(
      key: const PageStorageKey('schedule-calendar-scroll'),
      slivers: [
        SliverToBoxAdapter(child: calendar),
        SliverToBoxAdapter(child: _agendaHeading()),
        ..._agendaSlivers(tasks),
      ],
    );
  }

  Widget _monthGrid(
    List<WorkTask> tasks,
    Map<String, List<WorkTask>> dates, {
    required bool narrow,
  }) {
    final first = DateTime(month.year, month.month, 1);
    final start = first.subtract(Duration(days: first.weekday - 1));
    final today = _day(DateTime.now());
    var previousLanes = <String, int>{};
    return Padding(
      padding: EdgeInsets.all(narrow ? 12 : 20),
      child: Column(
        children: [
          Row(
            children: [
              for (final day in const ['월', '화', '수', '목', '금', '토', '일'])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      day,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, color: _muted),
                    ),
                  ),
                ),
            ],
          ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: _line),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: List.generate(6, (week) {
                final weekStart = DateTime(
                  start.year,
                  start.month,
                  start.day + week * 7,
                );
                final spans = calendarWeekSpans(
                  tasks,
                  weekStart,
                  previousLanes: previousLanes,
                );
                previousLanes = {
                  for (final span in spans) span.task.id: span.lane,
                };
                return LayoutBuilder(
                  builder: (context, bounds) {
                    final dayWidth = bounds.maxWidth / 7;
                    return SizedBox(
                      height: narrow ? 64 : 116,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: List.generate(7, (weekday) {
                                final day = DateTime(
                                  weekStart.year,
                                  weekStart.month,
                                  weekStart.day + weekday,
                                );
                                final entries =
                                    dates[_date(day)] ?? const <WorkTask>[];
                                final active = _sameDay(day, selected);
                                final current = _sameDay(day, today);
                                final inMonth = day.month == month.month;
                                final hidden = spans
                                    .where(
                                      (span) =>
                                          span.lane >= 2 &&
                                          span.firstDay <= weekday &&
                                          span.lastDay >= weekday,
                                    )
                                    .length;
                                return Expanded(
                                  child: Semantics(
                                    label:
                                        '${_date(day)} 예정 ${entries.length}개',
                                    selected: active,
                                    button: true,
                                    child: InkWell(
                                      key: Key('schedule-day-${_date(day)}'),
                                      onTap: () => setState(() {
                                        selected = day;
                                        month = DateTime(day.year, day.month);
                                      }),
                                      child: Container(
                                        padding: EdgeInsets.all(narrow ? 3 : 7),
                                        decoration: BoxDecoration(
                                          color: active
                                              ? const Color(0xfff2effb)
                                              : inMonth
                                              ? Colors.white
                                              : _surface,
                                          border: Border(
                                            right: weekday == 6
                                                ? BorderSide.none
                                                : const BorderSide(
                                                    color: _line,
                                                  ),
                                            bottom: week == 5
                                                ? BorderSide.none
                                                : const BorderSide(
                                                    color: _line,
                                                  ),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: narrow
                                              ? CrossAxisAlignment.center
                                              : CrossAxisAlignment.start,
                                          children: [
                                            Container(
                                              width: 24,
                                              height: 24,
                                              alignment: Alignment.center,
                                              decoration: BoxDecoration(
                                                color: current
                                                    ? _accent
                                                    : Colors.transparent,
                                                borderRadius:
                                                    BorderRadius.circular(7),
                                              ),
                                              child: Text(
                                                '${day.day}',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: active || current
                                                      ? FontWeight.w700
                                                      : FontWeight.w400,
                                                  color: current
                                                      ? Colors.white
                                                      : inMonth
                                                      ? _ink
                                                      : _muted.withValues(
                                                          alpha: .45,
                                                        ),
                                                ),
                                              ),
                                            ),
                                            const Spacer(),
                                            if (hidden > 0)
                                              Text(
                                                '+$hidden',
                                                maxLines: 1,
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: _muted,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }),
                            ),
                          ),
                          for (final span in spans.where(
                            (span) => span.lane < 2,
                          ))
                            Positioned(
                              left:
                                  span.firstDay * dayWidth +
                                  (span.continuesBefore ? 0 : 5),
                              right:
                                  (6 - span.lastDay) * dayWidth +
                                  (span.continuesAfter ? 0 : 5),
                              top:
                                  (narrow ? 32 : 35) +
                                  span.lane * (narrow ? 9 : 26),
                              height: narrow ? 6 : 22,
                              child: _calendarTaskSpan(
                                span,
                                weekStart,
                                narrow: narrow,
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                );
              }),
            ),
          ),
          const SizedBox(height: 10),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '지정일 ~ 마감일 · 날짜를 선택하면 해당 기간의 작업을 확인할 수 있습니다.',
              style: TextStyle(fontSize: 11, color: _muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _calendarTaskSpan(
    CalendarTaskSpan span,
    DateTime weekStart, {
    required bool narrow,
  }) {
    final task = span.task;
    final color = _taskColor(task);
    final radius = BorderRadius.horizontal(
      left: span.continuesBefore ? Radius.zero : const Radius.circular(5),
      right: span.continuesAfter ? Radius.zero : const Radius.circular(5),
    );
    return IgnorePointer(
      ignoring: narrow,
      child: Tooltip(
        message:
            '${task.title} · ${task.assignedDate} ~ ${task.dueDate.isEmpty ? '마감 미정' : task.dueDate}',
        child: Material(
          key: Key('calendar-span-${task.id}-${_date(weekStart)}'),
          color: Color.alphaBlend(color.withValues(alpha: .12), Colors.white),
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => widget.onOpenTask(task),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: narrow ? 0 : 6),
              child: narrow
                  ? const SizedBox()
                  : Row(
                      children: [
                        if (span.continuesBefore) ...[
                          Icon(
                            Icons.chevron_left_rounded,
                            size: 12,
                            color: color,
                          ),
                          const SizedBox(width: 2),
                        ],
                        Expanded(
                          child: Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: color),
                          ),
                        ),
                        if (span.continuesAfter)
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 12,
                            color: color,
                          ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Color _taskColor(WorkTask task) => widget.store.isCompleted(task)
      ? const Color(0xff528d73)
      : _overdue(task)
      ? const Color(0xffb06a55)
      : _accent;

  Widget _agendaHeading() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
    child: Row(
      children: [
        Expanded(
          child: Text(
            '${selected.month}월 ${selected.day}일',
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: _ink,
            ),
          ),
        ),
        if (widget.store.canCreate)
          IconButton(
            tooltip: '선택한 날짜에 작업 등록',
            onPressed: () => widget.onCreateTask(selected),
            icon: const Icon(Icons.add_rounded, size: 19, color: _accent),
          ),
      ],
    ),
  );

  Widget _agenda(List<WorkTask> tasks) => CustomScrollView(
    key: const PageStorageKey('schedule-agenda-scroll'),
    slivers: [
      SliverToBoxAdapter(child: _agendaHeading()),
      ..._agendaSlivers(tasks),
    ],
  );

  List<Widget> _agendaSlivers(List<WorkTask> tasks) {
    final dated = tasks
        .where((t) => t.dueDate.isNotEmpty && taskScheduledOn(t, selected))
        .toList();
    final unscheduled = tasks.where((t) => t.dueDate.isEmpty).toList();
    return [
      if (dated.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Text(
              '이 날짜에 예정된 작업이 없습니다.',
              style: TextStyle(fontSize: 12, height: 1.6, color: _muted),
            ),
          ),
        ),
      SliverList.builder(
        itemCount: dated.length,
        itemBuilder: (_, index) => _agendaTask(dated[index]),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
          child: Text(
            '마감 미정 · ${unscheduled.length}',
            key: const Key('schedule-undated-heading'),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _muted,
            ),
          ),
        ),
      ),
      if (unscheduled.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Text(
              '마감일이 정해지지 않은 작업이 없습니다.',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          ),
        ),
      SliverList.builder(
        itemCount: unscheduled.length,
        itemBuilder: (_, index) => _agendaTask(unscheduled[index]),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  Widget _agendaTask(WorkTask task) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Material(
      key: Key('schedule-agenda-${task.id}'),
      color: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => widget.onOpenTask(task),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                height: 36,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: _taskColor(task),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: _ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${widget.store.workflowStatusName(task.status)} · '
                      '${widget.store.currentActorLabel(task)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: _muted),
                    ),
                  ],
                ),
              ),
              if (widget.store.canEdit(task))
                IconButton(
                  key: Key('schedule-edit-${task.id}'),
                  tooltip: '일정 수정',
                  onPressed: () => widget.onEditTask(task),
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_calendar_outlined, size: 17),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _timeline(List<WorkTask> tasks) {
    final end = DateTime(month.year, month.month + 1, 0);
    final dated = tasks.where((task) {
      final due = _due(task);
      if (due == null) return false;
      final start = DateTime.tryParse(task.assignedDate) ?? due;
      return !due.isBefore(month) && !start.isAfter(end);
    }).toList();
    final undated = tasks.where((task) => task.dueDate.isEmpty).toList();
    return LayoutBuilder(
      builder: (context, bounds) {
        const labelWidth = 230.0, dayWidth = 34.0;
        final width = math.max(
          bounds.maxWidth,
          labelWidth + end.day * dayWidth,
        );
        return Scrollbar(
          controller: timelineHorizontal,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: timelineHorizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: bounds.maxHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        const SizedBox(
                          width: labelWidth,
                          child: Padding(
                            padding: EdgeInsets.only(left: 20),
                            child: Text(
                              '작업 지정일 → 마감일',
                              style: TextStyle(fontSize: 11, color: _muted),
                            ),
                          ),
                        ),
                        for (var day = 1; day <= end.day; day++)
                          SizedBox(
                            key: Key('timeline-day-$day'),
                            width: dayWidth,
                            child: Text(
                              '$day',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: _line),
                  Expanded(
                    child: ListView.builder(
                      key: const Key('schedule-timeline-rows'),
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: dated.length + undated.length + 1,
                      itemBuilder: (context, index) {
                        if (index == dated.length) {
                          return SizedBox(
                            height: 54,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                              child: Text(
                                '${dated.isEmpty ? '이번 달에 진행하는 작업이 없습니다.  ·  ' : ''}'
                                '마감 미정 ${undated.length}개',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: _muted,
                                ),
                              ),
                            ),
                          );
                        }
                        final task = index < dated.length
                            ? dated[index]
                            : undated[index - dated.length - 1];
                        final due = _due(task);
                        final assigned = DateTime.tryParse(task.assignedDate);
                        final startDay =
                            assigned == null || assigned.isBefore(month)
                            ? 1
                            : assigned.day;
                        final endDay = due == null
                            ? startDay
                            : due.isAfter(end)
                            ? end.day
                            : due.day;
                        return SizedBox(
                          key: Key('schedule-timeline-${task.id}'),
                          height: 54,
                          child: Row(
                            children: [
                              SizedBox(
                                width: labelWidth,
                                child: ListTile(
                                  dense: true,
                                  onTap: () => widget.onOpenTask(task),
                                  title: Text(
                                    task.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: _ink,
                                    ),
                                  ),
                                  subtitle: Text(
                                    widget.store.member(task.assigneeId).name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: _muted,
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: due == null
                                    ? Align(
                                        alignment: Alignment.centerLeft,
                                        child: widget.store.canEdit(task)
                                            ? TextButton.icon(
                                                onPressed: () =>
                                                    widget.onEditTask(task),
                                                icon: const Icon(
                                                  Icons.edit_calendar_outlined,
                                                  size: 16,
                                                ),
                                                label: const Text('마감일 정하기'),
                                              )
                                            : const Text(
                                                '마감일 미정',
                                                style: TextStyle(
                                                  color: _muted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                      )
                                    : Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          for (
                                            var day = 0;
                                            day < end.day;
                                            day++
                                          )
                                            Positioned(
                                              left: day * dayWidth,
                                              top: 0,
                                              bottom: 0,
                                              width: 1,
                                              child: const ColoredBox(
                                                color: _line,
                                              ),
                                            ),
                                          Positioned(
                                            left: (startDay - 1) * dayWidth + 3,
                                            top: 12,
                                            height: 30,
                                            width:
                                                math.max(
                                                      1,
                                                      endDay - startDay + 1,
                                                    ) *
                                                    dayWidth -
                                                6,
                                            child: Tooltip(
                                              message:
                                                  '${task.title}\n${task.assignedDate} → ${task.dueDate}',
                                              child: Material(
                                                color: _taskColor(task)
                                                    .withValues(alpha: .15),
                                                borderRadius:
                                                    BorderRadius.circular(7),
                                                child: InkWell(
                                                  borderRadius:
                                                      BorderRadius.circular(7),
                                                  onTap: () =>
                                                      widget.onOpenTask(task),
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 6,
                                                        ),
                                                    child: Text(
                                                      task.title,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      maxLines: 1,
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        color: _taskColor(task),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// An inclusive date-only interval. A missing deadline displays its start day.
bool taskScheduledOn(WorkTask task, DateTime day) {
  final date = DateTime(day.year, day.month, day.day);
  final start = DateTime.parse(task.assignedDate);
  final end = task.dueDate.isEmpty ? start : DateTime.parse(task.dueDate);
  return !date.isBefore(start) && !date.isAfter(end);
}

/// One uninterrupted portion of a task interval in a seven-day calendar row.
class CalendarTaskSpan {
  const CalendarTaskSpan(
    this.task,
    this.firstDay,
    this.lastDay,
    this.lane, {
    required this.continuesBefore,
    required this.continuesAfter,
  });
  final WorkTask task;
  final int firstDay, lastDay, lane;
  final bool continuesBefore, continuesAfter;
}

/// Allocate whole intervals, rather than independent per-day entries. Keep
/// continuing visible lanes stable and hide excess events behind the day count.
List<CalendarTaskSpan> calendarWeekSpans(
  List<WorkTask> tasks,
  DateTime weekStart, {
  Map<String, int> previousLanes = const {},
}) {
  final start = DateTime(weekStart.year, weekStart.month, weekStart.day);
  final end = DateTime(start.year, start.month, start.day + 6);
  final visible =
      tasks.where((task) {
        final assigned = DateTime.parse(task.assignedDate);
        final due = task.dueDate.isEmpty
            ? assigned
            : DateTime.parse(task.dueDate);
        return !assigned.isAfter(end) && !due.isBefore(start);
      }).toList()..sort((a, b) {
        bool continuing(WorkTask task) =>
            DateTime.parse(task.assignedDate).isBefore(start) &&
            (previousLanes[task.id] ?? 2) < 2;
        final continued = (continuing(a) ? 0 : 1).compareTo(
          continuing(b) ? 0 : 1,
        );
        if (continued != 0) return continued;
        final first = a.assignedDate.compareTo(b.assignedDate);
        if (first != 0) return first;
        final last = (b.dueDate.isEmpty ? b.assignedDate : b.dueDate).compareTo(
          a.dueDate.isEmpty ? a.assignedDate : a.dueDate,
        );
        return last == 0 ? a.id.compareTo(b.id) : last;
      });
  final occupied = <int>[];
  final spans = <CalendarTaskSpan>[];
  for (final task in visible) {
    final assigned = DateTime.parse(task.assignedDate);
    final due = task.dueDate.isEmpty ? assigned : DateTime.parse(task.dueDate);
    int column(DateTime value) =>
        DateTime.utc(value.year, value.month, value.day)
            .difference(DateTime.utc(start.year, start.month, start.day))
            .inDays
            .clamp(0, 6);
    final first = column(assigned), last = column(due);
    final mask = ((1 << (last - first + 1)) - 1) << first;
    final preferred = previousLanes[task.id];
    var lane = 0;
    if (preferred != null &&
        preferred < 2 &&
        (preferred >= occupied.length || occupied[preferred] & mask == 0)) {
      lane = preferred;
    } else {
      while (lane < occupied.length && occupied[lane] & mask != 0) {
        lane++;
      }
    }
    while (occupied.length <= lane) {
      occupied.add(0);
    }
    occupied[lane] |= mask;
    spans.add(
      CalendarTaskSpan(
        task,
        first,
        last,
        lane,
        continuesBefore: assigned.isBefore(start),
        continuesAfter: due.isAfter(end),
      ),
    );
  }
  return spans;
}
