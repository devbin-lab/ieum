import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'models.dart';

/// Captures the pointer on the whole grip, including the gaps between dots.
/// Rows move locally during the gesture; one save is requested on release.
class WorkflowStageOrder extends StatefulWidget {
  const WorkflowStageOrder({
    super.key,
    required this.stages,
    required this.enabled,
    required this.rowBuilder,
    required this.onReorder,
  });

  final List<WorkflowStage> stages;
  final bool enabled;
  final Widget Function(WorkflowStage, int, Widget) rowBuilder;
  final void Function(List<WorkflowStage>, List<WorkflowStage>) onReorder;

  @override
  State<WorkflowStageOrder> createState() => _WorkflowStageOrderState();
}

class _WorkflowStageOrderState extends State<WorkflowStageOrder> {
  static const rowHeight = 56.0;
  final _listKey = GlobalKey();
  List<WorkflowStage>? _preview;
  List<WorkflowStage>? _original;
  String? _draggedId;
  int? _pointer;
  Offset? _position;
  Timer? _scrollTimer;

  @override
  void dispose() {
    _scrollTimer?.cancel();
    super.dispose();
  }

  void _start(PointerDownEvent event, String id) {
    if (!widget.enabled ||
        _pointer != null ||
        event.buttons != kPrimaryButton) {
      return;
    }
    setState(() {
      _pointer = event.pointer;
      _position = event.position;
      _draggedId = id;
      _original = List.of(widget.stages);
      _preview = List.of(widget.stages);
    });
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final scrollable = Scrollable.maybeOf(context);
      final box = scrollable?.context.findRenderObject();
      if (box is! RenderBox || _position == null) return;
      final y = box.globalToLocal(_position!).dy;
      final delta = y < 40 ? -8.0 : (y > box.size.height - 40 ? 8.0 : 0.0);
      if (delta == 0) return;
      final scroll = scrollable!.position;
      scroll.jumpTo(
        (scroll.pixels + delta).clamp(
          scroll.minScrollExtent,
          scroll.maxScrollExtent,
        ),
      );
      _moveTo(_position!);
    });
  }

  void _moveTo(Offset position) {
    final box = _listKey.currentContext?.findRenderObject();
    final stages = _preview;
    if (box is! RenderBox || stages == null || stages.isEmpty) return;
    final index = (box.globalToLocal(position).dy / rowHeight).floor().clamp(
      0,
      stages.length - 1,
    );
    final previous = stages.indexWhere((stage) => stage.id == _draggedId);
    if (previous < 0 || index == previous) return;
    setState(() => stages.insert(index, stages.removeAt(previous)));
  }

  void _finish({bool cancel = false}) {
    final stages = _preview;
    final original = _original;
    _scrollTimer?.cancel();
    setState(() {
      _preview = null;
      _original = null;
      _draggedId = null;
      _pointer = null;
      _position = null;
    });
    if (!cancel &&
        widget.enabled &&
        stages != null &&
        original != null &&
        stages.asMap().entries.any((e) => e.value.id != original[e.key].id)) {
      widget.onReorder(stages, original);
    }
  }

  Widget _handle(WorkflowStage stage) => MouseRegion(
    cursor: !widget.enabled
        ? SystemMouseCursors.basic
        : _draggedId == stage.id
        ? SystemMouseCursors.grabbing
        : SystemMouseCursors.grab,
    child: Tooltip(
      message: '드래그하여 순서 이동',
      child: Listener(
        key: Key('workflow-stage-drag-${stage.id}'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => _start(event, stage.id),
        onPointerMove: (event) {
          if (event.pointer != _pointer) return;
          _position = event.position;
          _moveTo(event.position);
        },
        onPointerUp: (event) {
          if (event.pointer == _pointer) _finish();
        },
        onPointerCancel: (event) {
          if (event.pointer == _pointer) _finish(cancel: true);
        },
        child: SizedBox(
          width: 36,
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var column = 0; column < 2; column++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var row = 0; row < 3; row++)
                        Container(
                          width: 3.5,
                          height: 3.5,
                          margin: const EdgeInsets.symmetric(vertical: 1.25),
                          decoration: BoxDecoration(
                            color: widget.enabled
                                ? const Color(0xff827a90)
                                : const Color(0xffc6c1ce),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final stages = _preview ?? widget.stages;
    return Column(
      key: _listKey,
      children: [
        for (var i = 0; i < stages.length; i++)
          Container(
            key: Key('workflow-stage-row-${stages[i].id}'),
            height: rowHeight,
            decoration: BoxDecoration(
              color: _draggedId == stages[i].id
                  ? const Color(0xffeee8fa)
                  : Colors.transparent,
              border: i == 0
                  ? null
                  : const Border(top: BorderSide(color: Color(0xffe1e3e6))),
            ),
            child: widget.rowBuilder(stages[i], i, _handle(stages[i])),
          ),
      ],
    );
  }
}
