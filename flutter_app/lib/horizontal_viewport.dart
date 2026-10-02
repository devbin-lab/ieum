import 'package:flutter/material.dart';

/// Wide data keeps its columns and gains a draggable scrollbar in narrow windows.
class HorizontalViewport extends StatefulWidget {
  const HorizontalViewport({super.key, required this.child});
  final Widget child;

  @override
  State<HorizontalViewport> createState() => _HorizontalViewportState();
}

class _HorizontalViewportState extends State<HorizontalViewport> {
  final controller = ScrollController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scrollbar(
    controller: controller,
    thumbVisibility: true,
    interactive: true,
    child: SingleChildScrollView(
      controller: controller,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.only(bottom: 12),
      child: widget.child,
    ),
  );
}
