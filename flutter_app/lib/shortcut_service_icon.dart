import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Local service marks stay visible in release builds without icon-font glyphs
/// or a network request to the linked service.
class ShortcutServiceIcon extends StatelessWidget {
  const ShortcutServiceIcon({
    super.key,
    required this.service,
    this.size = 24,
    this.semanticsLabel,
  });

  final String service;
  final double size;
  final String? semanticsLabel;

  static const assets = <String, String>{
    'drive': 'assets/shortcut-services/googledrive.svg',
    'notion': 'assets/shortcut-services/notion.svg',
    'jira': 'assets/shortcut-services/jira.svg',
    'discord': 'assets/shortcut-services/discord.svg',
    'kakao': 'assets/shortcut-services/kakaotalk.svg',
    'github': 'assets/shortcut-services/github.svg',
    'figma': 'assets/shortcut-services/figma.svg',
    'slack': 'assets/shortcut-services/slack.svg',
  };

  static const _names = <String, String>{
    'drive': 'Google Drive',
    'notion': 'Notion',
    'jira': 'Jira',
    'discord': 'Discord',
    'kakao': 'KakaoTalk',
    'github': 'GitHub',
    'figma': 'Figma',
    'slack': 'Slack',
  };

  static const _fullColorServices = {'drive', 'figma', 'slack'};

  static Color colorOf(BuildContext context, String service) {
    final scheme = Theme.of(context).colorScheme;
    final brand = switch (service) {
      'drive' => const Color(0xff4285f4),
      'jira' => const Color(0xff0052cc),
      'discord' => const Color(0xff5865f2),
      'kakao' => const Color(0xff3c1e1e),
      'figma' => const Color(0xfff24e1e),
      'slack' => const Color(0xff4a154b),
      'notion' || 'github' => scheme.onSurface,
      _ => scheme.primary,
    };
    if (Theme.of(context).brightness == Brightness.dark &&
        service != 'notion' &&
        service != 'github' &&
        service != 'custom') {
      return Color.lerp(brand, Colors.white, .4)!;
    }
    return brand;
  }

  @override
  Widget build(BuildContext context) {
    final asset = assets[service];
    final color = colorOf(context, service);
    return SizedBox.square(
      dimension: size,
      child: asset == null
          ? Semantics(
              label: semanticsLabel,
              image: true,
              child: CustomPaint(painter: _LinkPainter(color)),
            )
          : SvgPicture.asset(
              asset,
              width: size,
              height: size,
              colorFilter: _fullColorServices.contains(service)
                  ? null
                  : ColorFilter.mode(color, BlendMode.srcIn),
              semanticsLabel: semanticsLabel ?? _names[service],
              placeholderBuilder: (_) =>
                  CustomPaint(painter: _LinkPainter(color)),
              errorBuilder: (_, _, _) =>
                  CustomPaint(painter: _LinkPainter(color)),
            ),
    );
  }
}

class _LinkPainter extends CustomPainter {
  const _LinkPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.save();
    canvas.scale(scale);
    canvas.translate(12, 12);
    canvas.rotate(-.7853981633974483);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-3.5, -9, 7, 11),
        const Radius.circular(3.5),
      ),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-3.5, -2, 7, 11),
        const Radius.circular(3.5),
      ),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinkPainter oldDelegate) => oldDelegate.color != color;
}
