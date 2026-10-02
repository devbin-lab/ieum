import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Lives above the navigator so window controls remain available in dialogs.
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Overlay.wrap(
    child: Column(
      children: [
        const IeumTitleBar(),
        Expanded(child: child),
      ],
    ),
  );
}

class IeumTitleBar extends StatefulWidget {
  const IeumTitleBar({super.key});

  @override
  State<IeumTitleBar> createState() => _IeumTitleBarState();
}

class _IeumTitleBarState extends State<IeumTitleBar> with WindowListener {
  bool maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    refreshMaximized();
  }

  Future<void> refreshMaximized() async {
    final value = await windowManager.isMaximized();
    if (mounted) setState(() => maximized = value);
  }

  @override
  void onWindowMaximize() => refreshMaximized();
  @override
  void onWindowUnmaximize() => refreshMaximized();
  @override
  void onWindowRestore() => refreshMaximized();

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> toggleMaximized() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
    await refreshMaximized();
  }

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xfff1f3f2),
    child: Container(
      key: const Key('window-titlebar'),
      height: 36,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xffe1e4e3))),
      ),
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              key: const Key('window-drag-area'),
              child: const SizedBox.expand(
                child: ColoredBox(color: Colors.transparent),
              ),
            ),
          ),
          _WindowButton(
            key: const Key('window-minimize'),
            label: '최소화',
            icon: Icons.remove_rounded,
            onPressed: windowManager.minimize,
          ),
          _WindowButton(
            key: const Key('window-maximize'),
            label: maximized ? '이전 크기로 복원' : '최대화',
            icon: maximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            onPressed: toggleMaximized,
          ),
          _WindowButton(
            key: const Key('window-close'),
            label: '닫기',
            icon: Icons.close_rounded,
            close: true,
            onPressed: windowManager.close,
          ),
        ],
      ),
    ),
  );
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.close = false,
  });
  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
  final bool close;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.label,
    child: MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: Semantics(
        label: widget.label,
        button: true,
        child: SizedBox(
          width: 48,
          height: 36,
          child: InkWell(
            onTap: widget.onPressed,
            hoverColor: widget.close
                ? const Color(0xffd54c64)
                : const Color(0xffe9e3f5),
            child: Center(
              child: Icon(
                widget.icon,
                size: 17,
                color: widget.close && hovered
                    ? Colors.white
                    : const Color(0xff635b72),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
