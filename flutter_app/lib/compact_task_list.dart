import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'horizontal_viewport.dart';
import 'models.dart';
import 'workspace_ui.dart';

/// Display values stay with the project view so list rendering cannot change
/// assignee, status, permission or date rules.
class CompactTaskPresentation {
  const CompactTaskPresentation({
    required this.idLabel,
    required this.statusLabel,
    required this.statusColor,
    required this.assigneeLabel,
    required this.priorityLabel,
    required this.priorityColor,
    required this.dateLabel,
    this.assigneeAvatar,
    this.contextLabel = '',
    this.dateTooltip,
  });

  final String idLabel;
  final String statusLabel;
  final Color statusColor;
  final String assigneeLabel;
  final Widget? assigneeAvatar;
  final String priorityLabel;
  final Color priorityColor;
  final String dateLabel;
  final String contextLabel;
  final String? dateTooltip;
}

/// A desktop list optimized for scanning many tasks, with details on demand.
/// The parent owns filtering, paging and all mutations.
class CompactTaskList extends StatelessWidget {
  const CompactTaskList({
    super.key,
    required this.tasks,
    required this.presentationFor,
    required this.onOpenTask,
    this.pinButtonBuilder,
    this.actionsBuilder,
    this.selectedTaskId,
    this.rowKeyBuilder,
  });

  final List<WorkTask> tasks;
  final CompactTaskPresentation Function(WorkTask task) presentationFor;
  final ValueChanged<WorkTask> onOpenTask;
  final Widget Function(WorkTask task)? pinButtonBuilder;
  final Widget Function(WorkTask task)? actionsBuilder;
  final String? selectedTaskId;
  final Key Function(WorkTask task)? rowKeyBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = WorkspaceUi.colors(context);
    final textScale = math.max(
      1.0,
      MediaQuery.textScalerOf(context).scale(12) / 12,
    );
    final metrics = _ListMetrics(textScale);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.line),
        borderRadius: BorderRadius.circular(WorkspaceUi.radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, bounds) {
          final width = math.max(bounds.maxWidth, metrics.minimumWidth);
          final contents = SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _header(context, metrics),
                for (final task in tasks)
                  _taskRow(context, task, presentationFor(task), metrics),
              ],
            ),
          );
          return bounds.maxWidth < metrics.minimumWidth
              ? HorizontalViewport(child: contents)
              : contents;
        },
      ),
    );
  }

  Widget _header(BuildContext context, _ListMetrics metrics) {
    final colors = WorkspaceUi.colors(context);
    Widget heading(String value) => Text(
      tr(value),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 11, color: colors.muted),
    );
    return Container(
      key: const Key('compact-task-header'),
      height: metrics.headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.line, width: .5)),
      ),
      child: _columns(
        metrics,
        task: heading('작업'),
        status: heading('상태'),
        assignee: heading('담당자'),
        priority: heading('우선순위'),
        dates: heading('일정'),
        tools: const SizedBox.shrink(),
      ),
    );
  }

  Widget _taskRow(
    BuildContext context,
    WorkTask task,
    CompactTaskPresentation display,
    _ListMetrics metrics,
  ) {
    final colors = WorkspaceUi.colors(context);
    final taskContext = [
      display.idLabel,
      task.title,
      if (display.contextLabel.isNotEmpty) display.contextLabel,
    ].join('\n');
    final selected = task.id == selectedTaskId;
    return Material(
      color: selected
          ? Color.alphaBlend(
              colors.accent.withValues(alpha: .08),
              colors.surface,
            )
          : colors.surface,
      child: InkWell(
        key: rowKeyBuilder?.call(task) ?? Key('compact-task-row-${task.id}'),
        onTap: () => onOpenTask(task),
        hoverColor: colors.subtle,
        focusColor: colors.accent.withValues(alpha: .12),
        child: Container(
          height: metrics.rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.line, width: .5)),
          ),
          child: _columns(
            metrics,
            task: Tooltip(
              message: taskContext,
              child: Row(
                children: [
                  SizedBox(
                    width: 76 * metrics.scale,
                    child: Text(
                      display.idLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: colors.muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      task.title,
                      key: Key('compact-task-title-${task.id}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            status: Tooltip(
              message: display.statusLabel,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: display.statusColor.withValues(alpha: .09),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    display.statusLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: display.statusColor, fontSize: 10),
                  ),
                ),
              ),
            ),
            assignee: Tooltip(
              message: [
                display.assigneeLabel,
                if (display.contextLabel.isNotEmpty) display.contextLabel,
              ].join('\n'),
              child: Row(
                children: [
                  if (display.assigneeAvatar != null) ...[
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: display.assigneeAvatar,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      display.assigneeLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.ink),
                    ),
                  ),
                ],
              ),
            ),
            priority: Tooltip(
              message: display.priorityLabel,
              child: Row(
                children: [
                  Icon(
                    task.priority == 'high'
                        ? Icons.keyboard_double_arrow_up_rounded
                        : task.priority == 'low'
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.remove_rounded,
                    size: 15,
                    color: display.priorityColor,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      display.priorityLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: display.priorityColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            dates: Tooltip(
              message: display.dateTooltip ?? display.dateLabel,
              child: Text(
                display.dateLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.muted),
              ),
            ),
            tools: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(
                  foregroundColor: colors.muted,
                  minimumSize: const Size(32, 32),
                  maximumSize: const Size(32, 32),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                ),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: pinButtonBuilder?.call(task),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: actionsBuilder?.call(task),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _columns(
    _ListMetrics metrics, {
    required Widget task,
    required Widget status,
    required Widget assignee,
    required Widget priority,
    required Widget dates,
    required Widget tools,
  }) => Row(
    children: [
      Expanded(child: task),
      const SizedBox(width: 12),
      SizedBox(width: 96 * metrics.scale, child: status),
      const SizedBox(width: 12),
      SizedBox(width: 160 * metrics.scale, child: assignee),
      const SizedBox(width: 12),
      SizedBox(width: 80 * metrics.scale, child: priority),
      const SizedBox(width: 12),
      SizedBox(width: 160 * metrics.scale, child: dates),
      const SizedBox(width: 12),
      SizedBox(width: 64, child: tools),
    ],
  );
}

class _ListMetrics {
  const _ListMetrics(this.scale);
  final double scale;
  double get minimumWidth => 920 + (scale - 1) * 710;
  double get rowHeight => 54 + math.max(0, scale - 1) * 20;
  double get headerHeight => 38 + math.max(0, scale - 1) * 16;
}
