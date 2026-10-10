import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'workspace_ui.dart';

import 'task_handoff.dart';
import 'work_status_palette.dart';

class TaskDetailMenuAction {
  const TaskDetailMenuAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });
  final Key key;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;
}

/// Sticky task header: one primary action, status changes, and utility tools.
class TaskDetailToolbar extends StatelessWidget {
  const TaskDetailToolbar({
    super.key,
    required this.taskId,
    required this.title,
    required this.statusKey,
    required this.statusLabel,
    required this.onClose,
    required this.statusActions,
    required this.onStatusSelected,
    required this.menuActions,
    this.primaryAction,
    this.onEdit,
    this.displayId,
    this.onOpenInTasks,
  });
  final String taskId, title, statusKey, statusLabel;
  final String? displayId;
  final VoidCallback onClose;
  final VoidCallback? onEdit;
  final VoidCallback? onOpenInTasks;
  final Widget? primaryAction;
  final List<TaskHandoffPlan> statusActions;
  final ValueChanged<TaskHandoffPlan> onStatusSelected;
  final List<TaskDetailMenuAction> menuActions;

  MenuStyle menuStyle(BuildContext context) => MenuStyle(
    backgroundColor: WidgetStatePropertyAll(
      WorkspaceUi.colors(context).surface,
    ),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    elevation: const WidgetStatePropertyAll(10),
    shadowColor: WidgetStatePropertyAll(
      WorkspaceUi.colors(context).ink.withValues(alpha: .15),
    ),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
    minimumSize: const WidgetStatePropertyAll(Size(220, 0)),
    maximumSize: const WidgetStatePropertyAll(Size(280, 360)),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: WorkspaceUi.colors(context).line),
      ),
    ),
  );
  ButtonStyle itemStyle(BuildContext context, {bool destructive = false}) =>
      ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(
          destructive
              ? WorkspaceUi.colors(context).danger
              : WorkspaceUi.colors(context).ink,
        ),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontFamily: 'Malgun Gothic', fontSize: 12),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
  Widget menuHeading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, color: WorkspaceUi.colors(context).muted),
    ),
  );
  IconData statusIcon(TaskHandoffPlan plan) => switch (plan.destinationId) {
    'hold' => Icons.pause_circle_outline_rounded,
    'drop' => Icons.remove_circle_outline_rounded,
    'done' => Icons.check_circle_outline_rounded,
    'review' => Icons.fact_check_outlined,
    _ => Icons.play_arrow_rounded,
  };

  Widget statusControl(BuildContext context) {
    final normal = statusActions
        .where((p) => !const {'hold', 'drop'}.contains(p.destinationId))
        .toList();
    final parked = statusActions
        .where((p) => const {'hold', 'drop'}.contains(p.destinationId))
        .toList();
    return MenuAnchor(
      consumeOutsideTap: true,
      style: menuStyle(context),
      alignmentOffset: const Offset(0, 6),
      menuChildren: [
        menuHeading(context, tr('상태 변경')),
        for (final plan in normal)
          MenuItemButton(
            key: ValueKey('task-status-action-${plan.taskId}-${plan.routeId}'),
            onPressed: () => onStatusSelected(plan),
            style: itemStyle(context),
            leadingIcon: Icon(
              statusIcon(plan),
              size: 17,
              color: statusColor(
                plan.destinationId,
                brightness: Theme.of(context).brightness,
              ),
            ),
            child: Text(plan.buttonLabel),
          ),
        if (normal.isNotEmpty && parked.isNotEmpty) const Divider(height: 13),
        for (final plan in parked)
          MenuItemButton(
            key: ValueKey('task-status-action-${plan.taskId}-${plan.routeId}'),
            onPressed: () => onStatusSelected(plan),
            style: itemStyle(context),
            leadingIcon: Icon(
              statusIcon(plan),
              size: 17,
              color: statusColor(
                plan.destinationId,
                brightness: Theme.of(context).brightness,
              ),
            ),
            child: Text(plan.buttonLabel),
          ),
      ],
      builder: (context, controller, _) => Tooltip(
        message: statusActions.isEmpty ? tr('현재 상태') : tr('상태 변경'),
        child: OutlinedButton(
          key: ValueKey('task-status-menu-$taskId'),
          onPressed: statusActions.isEmpty
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
          style: OutlinedButton.styleFrom(
            foregroundColor: statusColor(
              statusKey,
              brightness: Theme.of(context).brightness,
            ),
            disabledForegroundColor: statusColor(
              statusKey,
              brightness: Theme.of(context).brightness,
            ),
            backgroundColor: stageSurfaceColor(
              statusKey,
              brightness: Theme.of(context).brightness,
            ),
            side: BorderSide(
              color: statusColor(
                statusKey,
                brightness: Theme.of(context).brightness,
              ).withValues(alpha: .20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            minimumSize: const Size(0, 36),
            textStyle: const TextStyle(
              fontFamily: 'Malgun Gothic',
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 6,
                color: statusColor(
                  statusKey,
                  brightness: Theme.of(context).brightness,
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  statusLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (statusActions.isNotEmpty) ...[
                const SizedBox(width: 6),
                const Icon(Icons.expand_more_rounded, size: 16),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget moreMenu(BuildContext context) => MenuAnchor(
    consumeOutsideTap: true,
    style: menuStyle(context),
    alignmentOffset: const Offset(0, 6),
    menuChildren: [
      menuHeading(context, tr('작업 관리')),
      for (final entry in menuActions.where((entry) => !entry.destructive))
        MenuItemButton(
          key: entry.key,
          onPressed: entry.onPressed,
          style: itemStyle(context),
          leadingIcon: Icon(entry.icon, size: 17),
          child: Text(entry.label),
        ),
      if (menuActions.any((entry) => entry.destructive)) ...[
        const Divider(height: 13),
        for (final entry in menuActions.where((entry) => entry.destructive))
          MenuItemButton(
            key: entry.key,
            onPressed: entry.onPressed,
            style: itemStyle(context, destructive: true),
            leadingIcon: Icon(
              entry.icon,
              size: 17,
              color: WorkspaceUi.colors(context).danger,
            ),
            child: Text(entry.label),
          ),
      ],
    ],
    builder: (context, controller, _) => IconButton(
      key: ValueKey('task-more-$taskId'),
      tooltip: tr('더보기'),
      onPressed: () =>
          controller.isOpen ? controller.close() : controller.open(),
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      color: WorkspaceUi.colors(context).muted,
    ),
  );

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('task-detail-toolbar-$taskId'),
    padding: const EdgeInsets.fromLTRB(24, 12, 16, 20),
    decoration: BoxDecoration(
      color: WorkspaceUi.colors(context).surface,
      border: Border(
        bottom: BorderSide(color: WorkspaceUi.colors(context).line),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: taskId,
                child: Text(
                  displayId ?? taskId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: WorkspaceUi.colors(context).muted,
                  ),
                ),
              ),
            ),
            if (onOpenInTasks != null)
              TextButton.icon(
                key: ValueKey('task-open-in-workspace-$taskId'),
                onPressed: onOpenInTasks,
                icon: const Icon(Icons.north_east_rounded, size: 15),
                label: Text(tr('작업으로 이동')),
                style: TextButton.styleFrom(
                  foregroundColor: WorkspaceUi.colors(context).muted,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(
                    fontFamily: 'Malgun Gothic',
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            if (onEdit != null)
              IconButton(
                key: ValueKey('task-edit-$taskId'),
                tooltip: tr('작업 수정'),
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                color: WorkspaceUi.colors(context).muted,
              ),
            if (menuActions.isNotEmpty) moreMenu(context),
            IconButton(
              tooltip: tr('작업 상세 닫기'),
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 20),
              color: WorkspaceUi.colors(context).muted,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Tooltip(
          message: title,
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 21,
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: WorkspaceUi.colors(context).ink,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [statusControl(context), ?primaryAction],
        ),
      ],
    ),
  );
}
