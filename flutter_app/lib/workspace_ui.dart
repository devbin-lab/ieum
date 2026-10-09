import 'package:flutter/material.dart';

/// Shared desktop rhythm. Window chrome and outer view corners live in app.dart.
abstract final class WorkspaceUi {
  static const ink = Color(0xff302b3c);
  static const muted = Color(0xff74717d);
  static const line = Color(0xffe4e6ea);
  static const surface = Colors.white;
  static const background = Color(0xfffafbfc);
  static const subtle = Color(0xfff4f5f7);
  static const accent = Color(0xff7963d5);
  static const radius = 10.0;
  static const contentPadding = 24.0;
  static const controlHeight = 36.0;
  static const titleStyle = TextStyle(
    fontSize: 23,
    fontWeight: FontWeight.w600,
    color: ink,
    height: 1.35,
    letterSpacing: -.6,
  );
  static const captionStyle = TextStyle(
    fontSize: 11,
    color: muted,
    height: 1.5,
  );
  static const sectionStyle = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: ink,
  );
  static WorkspaceColors colors(BuildContext context) =>
      WorkspaceColors(Theme.of(context).colorScheme);
  static TextStyle titleStyleOf(BuildContext context) =>
      titleStyle.copyWith(color: colors(context).ink);
  static TextStyle captionStyleOf(BuildContext context) =>
      captionStyle.copyWith(color: colors(context).muted);
  static TextStyle sectionStyleOf(BuildContext context) =>
      sectionStyle.copyWith(color: colors(context).ink);
  static EdgeInsets pagePadding(double width) =>
      EdgeInsets.all(width < 600 ? 16 : contentPadding);
}

/// Neutral workspace surfaces, independent from the chosen accent hue.
class WorkspaceColors {
  const WorkspaceColors(this.scheme);
  final ColorScheme scheme;
  bool get isDark => scheme.brightness == Brightness.dark;
  Color get ink => isDark ? const Color(0xffe9eaf0) : WorkspaceUi.ink;
  Color get muted => isDark ? const Color(0xffa0a4b1) : WorkspaceUi.muted;
  Color get line => isDark ? const Color(0xff353943) : WorkspaceUi.line;
  Color get surface => isDark ? const Color(0xff242730) : WorkspaceUi.surface;
  Color get background =>
      isDark ? const Color(0xff1d2027) : WorkspaceUi.background;
  Color get subtle => isDark ? const Color(0xff2c303a) : WorkspaceUi.subtle;
  Color get accent => scheme.primary;
  Color get accentSurface => scheme.primaryContainer;
  Color get onAccent => scheme.onPrimary;
  Color get success =>
      isDark ? const Color(0xff82c69b) : const Color(0xff417458);
  Color get warning =>
      isDark ? const Color(0xfff2ae68) : const Color(0xff96703c);
  Color get danger => scheme.error;
  Color get chrome =>
      isDark ? const Color(0xff292d32) : const Color(0xffe6e8e7);
  Color get chromeHover =>
      isDark ? const Color(0xff3a4046) : const Color(0xffd6dad8);
  Color get chromeInk =>
      isDark ? const Color(0xffc3c9cf) : const Color(0xff505753);
}

class WorkspacePageHeader extends StatelessWidget {
  const WorkspacePageHeader({
    super.key,
    required this.title,
    this.contextLabel,
    this.contextKey,
    this.subtitle,
    this.actions = const [],
  });
  final String title;
  final String? contextLabel, subtitle;
  final Key? contextKey;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final heading = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (contextLabel?.isNotEmpty == true) ...[
            Text(
              contextLabel!,
              key: contextKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: WorkspaceUi.captionStyleOf(context),
            ),
            const SizedBox(height: 5),
          ],
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: WorkspaceUi.titleStyleOf(context),
          ),
          if (subtitle?.isNotEmpty == true) ...[
            const SizedBox(height: 7),
            Text(subtitle!, style: WorkspaceUi.captionStyleOf(context)),
          ],
        ],
      );
      if (bounds.maxWidth < 380 && actions.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading,
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: heading),
          if (actions.isNotEmpty) ...[
            const SizedBox(width: 16),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      );
    },
  );
}

class WorkspacePanel extends StatelessWidget {
  const WorkspacePanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    color: WorkspaceUi.colors(context).surface,
    shape: RoundedRectangleBorder(
      side: BorderSide(color: WorkspaceUi.colors(context).line),
      borderRadius: BorderRadius.circular(WorkspaceUi.radius),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class WorkspaceSectionLabel extends StatelessWidget {
  const WorkspaceSectionLabel({super.key, required this.title, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title, style: WorkspaceUi.sectionStyleOf(context))),
      ?trailing,
    ],
  );
}

class WorkspaceEmptyState extends StatelessWidget {
  const WorkspaceEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: WorkspaceUi.colors(context).muted),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: WorkspaceUi.sectionStyleOf(context),
            ),
            if (message?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: WorkspaceUi.captionStyleOf(context),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    ),
  );
}

/// A neutral navigation tab: selection changes the underline, not a large tile.
class WorkspaceTab extends StatelessWidget {
  const WorkspaceTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        bottom: BorderSide(
          color: selected
              ? WorkspaceUi.colors(context).accent
              : Colors.transparent,
          width: 2,
        ),
      ),
    ),
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: selected
            ? WorkspaceUi.colors(context).ink
            : WorkspaceUi.colors(context).muted,
        backgroundColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        minimumSize: const Size(0, 40),
        textStyle: TextStyle(
          fontFamily: 'Malgun Gothic',
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 6)],
          Text(label),
        ],
      ),
    ),
  );
}
