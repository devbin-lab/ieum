import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'workspace_ui.dart';

class IeumBrand extends StatelessWidget {
  const IeumBrand({super.key, this.size = 48, this.showName = true});
  final double size;
  final bool showName;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * .14),
        decoration: BoxDecoration(
          color: const Color(0xff22252b),
          borderRadius: BorderRadius.circular(size * .23),
        ),
        child: Image.asset(
          'assets/branding/app_icon.png',
          filterQuality: FilterQuality.high,
          errorBuilder: (_, error, stack) =>
              Icon(Icons.all_inclusive, size: size * .72, color: Colors.white),
        ),
      ),
      if (showName) ...[
        const SizedBox(width: 12),
        const Text(
          'IEUM',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
      ],
    ],
  );
}

/// The initial screen shares the app's neutral surfaces and rounded main view;
/// it adds no window chrome of its own.
class StartupSurface extends StatelessWidget {
  const StartupSurface({
    super.key,
    required this.title,
    required this.description,
    required this.child,
    this.footer,
  });
  final String title, description;
  final Widget child;
  final Widget? footer;
  @override
  Widget build(BuildContext context) {
    final colors = WorkspaceUi.colors(context);
    return Scaffold(
      backgroundColor: colors.background,
      body: LayoutBuilder(
        builder: (context, bounds) {
          final compact = bounds.maxWidth < 880;
          final padding = bounds.maxWidth < 600
              ? 16.0
              : compact
              ? 24.0
              : 36.0;
          final intro = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              IeumBrand(size: compact ? 40 : 56),
              if (!compact) ...[
                const SizedBox(height: 36),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: compact ? 26 : 34,
                    fontWeight: FontWeight.w600,
                    height: 1.28,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.75,
                    color: colors.muted,
                  ),
                ),
                const SizedBox(height: 34),
                _Feature(
                  icon: Icons.view_kanban_outlined,
                  title: isEnglish
                      ? 'A clear view of every task'
                      : '한눈에 보이는 팀의 작업',
                ),
                const SizedBox(height: 16),
                _Feature(
                  icon: Icons.calendar_month_outlined,
                  title: isEnglish
                      ? 'Tasks and schedules, together'
                      : '작업과 이어지는 일정',
                ),
                const SizedBox(height: 16),
                _Feature(
                  icon: Icons.sync_outlined,
                  title: isEnglish
                      ? 'Synced through your GitHub project'
                      : 'GitHub로 연결되는 작업 공간',
                ),
              ],
            ],
          );
          final panel = Container(
            padding: EdgeInsets.all(bounds.maxWidth < 600 ? 20 : 30),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border.all(color: colors.line),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: colors.isDark ? .08 : .025,
                  ),
                  blurRadius: 28,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          );
          return SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: bounds.maxHeight),
              child: Padding(
                padding: EdgeInsets.all(padding),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1060),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (compact) ...[
                          intro,
                          const SizedBox(height: 20),
                          panel,
                        ] else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(flex: 4, child: intro),
                              const SizedBox(width: 60),
                              Expanded(flex: 6, child: panel),
                            ],
                          ),
                        if (footer != null) ...[
                          const SizedBox(height: 18),
                          footer!,
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title});
  final IconData icon;
  final String title;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: WorkspaceUi.colors(context).muted),
      const SizedBox(width: 10),
      Expanded(
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: WorkspaceUi.colors(context).muted,
          ),
        ),
      ),
    ],
  );
}
