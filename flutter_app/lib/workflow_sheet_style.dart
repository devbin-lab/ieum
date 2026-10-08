import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';

const sheetAccent = Color(0xff556b91);
Color sheetRouteColor(String action) => switch (action) {
  'approve' => const Color(0xff779a89),
  'reject' => const Color(0xffb69a7b),
  _ => const Color(0xff94a5bf),
};
const sheetMenuAnimation = AnimationStyle(
  duration: Duration(milliseconds: 100),
  reverseDuration: Duration(milliseconds: 70),
  curve: Curves.easeOutCubic,
  reverseCurve: Curves.easeInCubic,
);
const sheetMenuShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(12)),
  side: BorderSide(color: Color(0xffe3e8ee)),
);

class WorkflowSheetCardFace extends StatefulWidget {
  const WorkflowSheetCardFace({
    super.key,
    required this.id,
    required this.title,
    required this.stageId,
    required this.selected,
    required this.dragging,
    this.category = '',
    this.locksContent = false,
  });
  final String id, title, stageId;
  final String category;
  final bool locksContent;
  final bool selected, dragging;

  @override
  State<WorkflowSheetCardFace> createState() => _WorkflowSheetCardFaceState();
}

class _WorkflowSheetCardFaceState extends State<WorkflowSheetCardFace> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = hovered || widget.selected || widget.dragging;
    final duration = MediaQuery.disableAnimationsOf(context) || widget.dragging
        ? Duration.zero
        : const Duration(milliseconds: 100);
    final category = widget.category.isNotEmpty
        ? widget.category
        : switch (widget.stageId) {
            'todo' => 'todo',
            'done' => 'done',
            _ => 'inProgress',
          };
    final locked =
        widget.locksContent ||
        widget.category.isEmpty && widget.stageId == 'review';
    final dot = category == 'done'
        ? const Color(0xff659981)
        : locked
        ? const Color(0xffb88a52)
        : category == 'inProgress'
        ? const Color(0xff8076bd)
        : const Color(0xff8593a4);
    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 100),
        curve: Curves.easeOutCubic,
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity, child: child),
        child: MouseRegion(
          onEnter: (_) => setState(() => hovered = true),
          onExit: (_) => setState(() => hovered = false),
          child: AnimatedContainer(
            key: Key('workflow-sheet-${widget.id}-card'),
            duration: duration,
            curve: Curves.easeOutCubic,
            width: 120,
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selected
                    ? sheetAccent
                    : highlighted
                    ? const Color(0xffa7b5c8)
                    : const Color(0xffe0e5ec),
                width: widget.selected ? 1.5 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: highlighted
                      ? const Color(0x181e3553)
                      : const Color(0x0b1e3553),
                  blurRadius: highlighted ? 14 : 8,
                  offset: Offset(0, widget.dragging ? 4 : 2),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: dot.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Icon(
                    category == 'done'
                        ? Icons.check_rounded
                        : locked
                        ? Icons.fact_check_outlined
                        : category == 'inProgress'
                        ? Icons.timelapse_rounded
                        : Icons.inbox_outlined,
                    size: 14,
                    color: dot,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xff344052),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorkflowSheetToolbar extends StatelessWidget {
  const WorkflowSheetToolbar({
    super.key,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onFit,
    this.compact = false,
    this.onArrange,
  });
  final double zoom;
  final bool compact;
  final VoidCallback onZoomIn, onZoomOut, onFit;
  final VoidCallback? onArrange;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    elevation: 2,
    shadowColor: const Color(0x201b304a),
    surfaceTintColor: Colors.transparent,
    shape: sheetMenuShape,
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onArrange != null) ...[
            button(
              'workflow-sheet-arrange',
              '자동 정렬',
              Icons.auto_awesome_mosaic_outlined,
              onArrange!,
            ),
            if (!compact)
              const Padding(
                padding: EdgeInsets.only(right: 10),
                child: Text(
                  '정렬',
                  style: TextStyle(fontSize: 11, color: sheetAccent),
                ),
              ),
            const SizedBox(
              height: 16,
              child: VerticalDivider(width: 9, color: Color(0xffe4e9ef)),
            ),
          ],
          if (!compact)
            button(
              'workflow-sheet-zoom-out',
              '축소',
              Icons.remove_rounded,
              onZoomOut,
            ),
          SizedBox(
            width: 44,
            child: Text(
              '${(zoom * 100).round()}%',
              key: const Key('workflow-sheet-zoom-label'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: Color(0xff6e7b8d),
              ),
            ),
          ),
          if (!compact)
            button('workflow-sheet-zoom-in', '확대', Icons.add_rounded, onZoomIn),
          if (!compact) const SizedBox(width: 6),
          if (!compact)
            const SizedBox(
              height: 16,
              child: VerticalDivider(width: 1, color: Color(0xffe4e9ef)),
            ),
          if (!compact) const SizedBox(width: 6),
          button(
            'workflow-sheet-fit',
            '전체 보기',
            Icons.center_focus_strong_outlined,
            onFit,
          ),
        ],
      ),
    ),
  );

  Widget button(
    String key,
    String tooltip,
    IconData icon,
    VoidCallback action,
  ) => IconButton(
    key: Key(key),
    tooltip: tooltip,
    onPressed: action,
    style: IconButton.styleFrom(
      minimumSize: const Size(30, 30),
      maximumSize: const Size(30, 30),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: const Color(0xff697a90),
      hoverColor: const Color(0xffedf1f6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    ),
    icon: Icon(icon, size: 17),
  );
}

class WorkflowSheetGridPainter extends CustomPainter {
  const WorkflowSheetGridPainter({required this.zoom, required this.camera});
  final double zoom;
  final Offset camera;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfff8fafc),
    );
    final step = (24 * zoom).clamp(12.0, 72.0);
    final origin = size.center(Offset.zero) * zoom + camera;
    final points = <Offset>[];
    for (var x = origin.dx % step; x < size.width; x += step) {
      for (var y = origin.dy % step; y < size.height; y += step) {
        points.add(Offset(x, y));
      }
    }
    canvas.drawPoints(
      PointMode.points,
      points,
      Paint()
        ..color = const Color(0xffe1e7ef)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant WorkflowSheetGridPainter oldDelegate) =>
      zoom != oldDelegate.zoom || camera != oldDelegate.camera;
}
