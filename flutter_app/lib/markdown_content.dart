import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'app_localizations.dart';
import 'desktop_platform.dart';
import 'task_resources_model.dart';

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({super.key, required this.data});
  final String data;

  static Future<void> openLink(BuildContext context, String? url) async {
    if (url == null || !validResourceUrl(url)) return;
    try {
      await openDesktopUrl(url);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('링크를 열지 못했습니다. 주소를 복사해서 확인하세요.'))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: TextStyle(fontSize: 12, height: 1.8, color: colors.onSurface),
        h1: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: colors.onSurface,
        ),
        h2: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
        h3: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
        code: TextStyle(
          fontSize: 11,
          fontFamily: 'Consolas',
          color: colors.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          border: Border(
            left: BorderSide(color: colors.outlineVariant, width: 3),
          ),
        ),
        tableBorder: TableBorder.all(color: colors.outlineVariant),
        a: TextStyle(
          color: colors.primary,
          decoration: TextDecoration.underline,
        ),
      ),
      onTapLink: (_, url, _) => openLink(context, url),
      imageBuilder: (uri, title, alt) => TextButton.icon(
        onPressed: validResourceUrl(uri.toString())
            ? () => openLink(context, uri.toString())
            : null,
        icon: const Icon(Icons.image_outlined, size: 16),
        label: Text(alt ?? title ?? tr('이미지')),
      ),
    );
  }
}
