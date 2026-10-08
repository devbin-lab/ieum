import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

const _titlebarSurface = Color(0xffe6e8e7);
const _titlebarHover = Color(0xffd6dad8);
const _titlebarIcon = Color(0xff505753);

/// Lives above the navigator so window controls remain available in dialogs.
class DesktopFrame extends StatefulWidget {
  const DesktopFrame({super.key, required this.child});
  final Widget child;

  @override
  State<DesktopFrame> createState() => _DesktopFrameState();
}

class SidebarTitlebarController extends ChangeNotifier {
  VoidCallback? action;
  VoidCallback? backAction;
  VoidCallback? forwardAction;
  bool open = false;
  bool showSidebar = true;
  bool _disposed = false;

  void configure(
    VoidCallback callback,
    bool isOpen, {
    VoidCallback? back,
    VoidCallback? forward,
    bool showSidebar = true,
  }) {
    if (_disposed) return;
    action = callback;
    backAction = back;
    forwardAction = forward;
    open = isOpen;
    this.showSidebar = showSidebar;
    notifyListeners();
  }

  void clear(VoidCallback callback) {
    if (_disposed) return;
    if (action != callback) return;
    action = null;
    backAction = null;
    forwardAction = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class SidebarTitlebarScope extends InheritedWidget {
  const SidebarTitlebarScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final SidebarTitlebarController controller;

  static SidebarTitlebarController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<SidebarTitlebarScope>()
      ?.controller;

  @override
  bool updateShouldNotify(SidebarTitlebarScope oldWidget) =>
      controller != oldWidget.controller;
}

class _DesktopFrameState extends State<DesktopFrame> {
  final sidebarController = SidebarTitlebarController();

  @override
  void dispose() {
    sidebarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SidebarTitlebarScope(
    controller: sidebarController,
    child: Overlay.wrap(
      child: Column(
        children: [
          IeumTitleBar(sidebarController: sidebarController),
          Expanded(child: widget.child),
        ],
      ),
    ),
  );
}

class IeumTitleBar extends StatefulWidget {
  const IeumTitleBar({super.key, this.sidebarController});

  final SidebarTitlebarController? sidebarController;

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
    color: Colors.transparent,
    child: Container(
      key: const Key('window-titlebar'),
      color: _titlebarSurface,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            if (widget.sidebarController != null)
              AnimatedBuilder(
                animation: widget.sidebarController!,
                builder: (context, _) {
                  final controller = widget.sidebarController!;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _historyButton(
                        key: const Key('titlebar-back'),
                        label: '뒤로가기',
                        forward: false,
                        onPressed: controller.backAction,
                      ),
                      _historyButton(
                        key: const Key('titlebar-forward'),
                        label: '앞으로가기',
                        forward: true,
                        onPressed: controller.forwardAction,
                      ),
                      if (controller.action != null && controller.showSidebar)
                        _sidebarButton(controller),
                    ],
                  );
                },
              ),
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
    ),
  );

  Widget _historyButton({
    required Key key,
    required String label,
    required bool forward,
    required VoidCallback? onPressed,
  }) => _TitlebarButton(
    key: key,
    label: label,
    width: 36,
    onPressed: onPressed,
    child: SizedBox(
      width: 18,
      height: 18,
      child: CustomPaint(
        painter: HistoryArrowPainter(
          forward: forward,
          color: onPressed == null
              ? const Color(0xff69778d)
              : const Color(0xffe2eaf8),
        ),
      ),
    ),
  );

  Widget _sidebarButton(SidebarTitlebarController controller) =>
      _TitlebarButton(
        key: const Key('titlebar-sidebar-toggle'),
        label: controller.open ? '사이드바 접기' : '사이드바 펼치기',
        width: 44,
        onPressed: controller.action,
        child: SizedBox(
          width: 17,
          height: 17,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(end: controller.open ? 1 : 0),
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            builder: (context, progress, _) => CustomPaint(
              key: const Key('titlebar-sidebar-glyph'),
              painter: SidebarGlyphPainter(progress),
            ),
          ),
        ),
      );
}

class _TitlebarButton extends StatefulWidget {
  const _TitlebarButton({
    super.key,
    required this.label,
    required this.width,
    required this.onPressed,
    required this.child,
  });

  final String label;
  final double width;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  State<_TitlebarButton> createState() => _TitlebarButtonState();
}

class _TitlebarButtonState extends State<_TitlebarButton> {
  bool hovered = false;
  bool focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.onPressed != null,
    label: widget.label,
    child: Tooltip(
      message: widget.label,
      excludeFromSemantics: true,
      child: MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: FocusableActionDetector(
          enabled: widget.onPressed != null,
          mouseCursor: widget.onPressed == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          onShowFocusHighlight: (value) => setState(() => focused = value),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: SizedBox(
              width: widget.width,
              height: 36,
              child: Center(
                // One solid hover surface. No ink overlay or color tween: both
                // used to introduce a second visual transition on pointer entry.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hovered && widget.onPressed != null
                        ? _titlebarHover
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                    border: focused && widget.onPressed != null
                        ? Border.all(color: const Color(0xff8faee8))
                        : null,
                  ),
                  child: SizedBox(
                    width: widget.width - 8,
                    height: 28,
                    child: Center(child: widget.child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class HistoryArrowPainter extends CustomPainter {
  const HistoryArrowPainter({required this.forward, required this.color});

  final bool forward;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final direction = forward ? 1.0 : -1.0;
    final tip = Offset(size.width / 2 + direction * 5, size.height / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(
      Offset(size.width / 2 - direction * 6, size.height / 2),
      tip,
      paint,
    );
    canvas.drawLine(tip, tip.translate(-direction * 5, -4.5), paint);
    canvas.drawLine(tip, tip.translate(-direction * 5, 4.5), paint);
  }

  @override
  bool shouldRepaint(covariant HistoryArrowPainter oldDelegate) =>
      oldDelegate.forward != forward || oldDelegate.color != color;
}

class SidebarGlyphPainter extends CustomPainter {
  const SidebarGlyphPainter(this.progress);

  /// 0 = folded, 1 = expanded.
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = _titlebarIcon
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.25;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(1.5, 2.5, size.width - 3, size.height - 5),
        const Radius.circular(3),
      ),
      line,
    );
    final dividerX = size.width * (.29 + .14 * progress);
    final inset = 4 * (1 - progress);
    canvas.drawLine(
      Offset(dividerX, 2.5 + inset),
      Offset(dividerX, size.height - 2.5 - inset),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant SidebarGlyphPainter oldDelegate) =>
      oldDelegate.progress != progress;
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
            hoverColor: widget.close ? const Color(0xffd54c64) : _titlebarHover,
            child: Center(
              child: Icon(
                widget.icon,
                size: 17,
                color: widget.close && hovered ? Colors.white : _titlebarIcon,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
