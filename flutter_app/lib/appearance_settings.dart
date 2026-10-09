import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'app_preferences.dart';

/// Personal appearance preferences. Updates are applied immediately by the app.
class AppearanceSettings extends StatefulWidget {
  const AppearanceSettings({super.key});

  @override
  State<AppearanceSettings> createState() => _AppearanceSettingsState();
}

class _AppearanceSettingsState extends State<AppearanceSettings> {
  static const defaultAccent = Color(0xff7963d5);
  static const swatches = <(String, Color)>[
    ('보라', defaultAccent),
    ('파랑', Color(0xff3478d4)),
    ('청록', Color(0xff16878c)),
    ('초록', Color(0xff398759)),
    ('황금', Color(0xffaa780d)),
    ('주황', Color(0xffc26c2d)),
    ('분홍', Color(0xffbe4b83)),
    ('회색', Color(0xff697586)),
  ];

  final hexController = TextEditingController();
  Color? lastAccent;
  String? hexError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final accent = AppPreferencesScope.of(context).accentColor;
    if (lastAccent != accent) {
      lastAccent = accent;
      hexController.text = colorHex(accent);
      hexError = null;
    }
  }

  @override
  void dispose() {
    hexController.dispose();
    super.dispose();
  }

  static String colorHex(Color color) =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  void applyHex(AppPreferences preferences) {
    final match = RegExp(r'^#?([0-9a-fA-F]{6})$')
        .firstMatch(hexController.text.trim());
    if (match == null) {
      setState(() => hexError = '올바른 색상 코드를 입력하세요. (예: #7963D5)');
      return;
    }
    setState(() => hexError = null);
    preferences.setAccentColor(
      Color(0xff000000 | int.parse(match.group(1)!, radix: 16)),
    );
  }

  Future<void> reset(AppPreferences preferences) async {
    await preferences.resetDesign();
    if (mounted) {
      setState(() {
        hexController.text = colorHex(defaultAccent);
        hexError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = AppPreferencesScope.of(context);
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('변경 사항은 바로 적용됩니다.'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            _PreferencePanel(
              title: tr('화면 모드'),
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final choices = [
                    _ModeChoice(
                      key: const Key('appearance-light'),
                      label: tr('라이트'),
                      dark: false,
                      selected: preferences.themeMode == ThemeMode.light,
                      onTap: () => preferences.setThemeMode(ThemeMode.light),
                    ),
                    _ModeChoice(
                      key: const Key('appearance-dark'),
                      label: tr('다크'),
                      dark: true,
                      selected: preferences.themeMode == ThemeMode.dark,
                      onTap: () => preferences.setThemeMode(ThemeMode.dark),
                    ),
                  ];
                  if (bounds.maxWidth < 280) {
                    return Column(
                      children: [
                        choices.first,
                        const SizedBox(height: 12),
                        choices.last,
                      ],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: choices.first),
                      const SizedBox(width: 12),
                      Expanded(child: choices.last),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            _PreferencePanel(
              title: tr('포인트 컬러'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _MonochromeSwatch(
                        selected: preferences.monochromeAccent,
                        onTap: preferences.setMonochromeAccent,
                      ),
                      for (final (label, color) in swatches)
                        Semantics(
                          label: tr(label),
                          button: true,
                          selected:
                              !preferences.monochromeAccent &&
                              preferences.accentColor == color,
                          child: Tooltip(
                            message: tr(label),
                            child: InkResponse(
                              key: Key(
                                'appearance-accent-${color.toARGB32().toRadixString(16)}',
                              ),
                              onTap: () => preferences.setAccentColor(color),
                              radius: 24,
                              child: Container(
                                width: 40,
                                height: 40,
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color:
                                        !preferences.monochromeAccent &&
                                            preferences.accentColor == color
                                        ? colors.onSurface
                                        : Colors.transparent,
                                    width: 1.5,
                                  ),
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                  ),
                                  child:
                                      !preferences.monochromeAccent &&
                                          preferences.accentColor == color
                                      ? Icon(
                                          Icons.check_rounded,
                                          size: 17,
                                          color: color.computeLuminance() > .4
                                              ? Colors.black
                                              : Colors.white,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (preferences.monochromeAccent) ...[
                    const SizedBox(height: 10),
                    Text(
                      tr('라이트 모드에서는 검은색, 다크 모드에서는 흰색이 적용됩니다.'),
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    tr('사용자 지정 색상'),
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: TextField(
                            key: const Key('appearance-custom-hex'),
                            controller: hexController,
                            maxLength: 7,
                            onSubmitted: (_) => applyHex(preferences),
                            onChanged: (_) {
                              if (hexError != null) {
                                setState(() => hexError = null);
                              }
                            },
                            decoration: InputDecoration(
                              labelText: tr('색상 코드'),
                              hintText: '#7963D5',
                              counterText: '',
                              errorText: hexError == null
                                  ? null
                                  : tr(hexError!),
                              errorMaxLines: 3,
                              prefixIcon: Icon(
                                Icons.colorize_outlined,
                                size: 17,
                                color: colors.onSurfaceVariant,
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        height: 42,
                        child: OutlinedButton(
                          key: const Key('appearance-apply-hex'),
                          onPressed: () => applyHex(preferences),
                          child: Text(tr('적용')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _PreferencePanel(
              title: tr('색상 미리보기'),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DecoratedBox(
                    key: const Key('appearance-accent-preview'),
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 10,
                      ),
                      child: Text(
                        tr('버튼'),
                        style: TextStyle(
                          color: colors.onPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.primary.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_rounded,
                            size: 15,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            tr('선택된 항목'),
                            style: TextStyle(
                              color: colors.primary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Text(
                    colorHex(preferences.accentColor),
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('appearance-reset'),
                onPressed: () => reset(preferences),
                icon: const Icon(Icons.restart_alt_rounded, size: 17),
                label: Text(tr('기본 설정으로 되돌리기')),
              ),
            ),
            if (preferences.persistenceError != null)
              _PreferenceError(message: preferences.persistenceError!),
          ],
        ),
      ),
    );
  }
}

class LanguageSettings extends StatelessWidget {
  const LanguageSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final preferences = AppPreferencesScope.of(context);
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              tr('언어를 변경하면 앱 화면에 바로 적용됩니다.'),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            _PreferencePanel(
              title: tr('앱 언어'),
              child: Column(
                children: [
                  for (final (code, nativeName, alternate) in [
                    ('ko', '한국어', 'Korean'),
                    ('en', 'English', '영어'),
                  ]) ...[
                    if (code != 'ko') const SizedBox(height: 10),
                    Semantics(
                      selected: preferences.languageCode == code,
                      button: true,
                      child: Material(
                        color: preferences.languageCode == code
                            ? colors.primary.withValues(alpha: .07)
                            : colors.surface,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9),
                          side: BorderSide(
                            color: preferences.languageCode == code
                                ? colors.primary
                                : colors.outlineVariant,
                          ),
                        ),
                        child: InkWell(
                          key: Key('appearance-language-$code'),
                          borderRadius: BorderRadius.circular(9),
                          onTap: () => preferences.setLanguage(code),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 15,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        nativeName,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: colors.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        alternate,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  preferences.languageCode == code
                                      ? Icons.check_circle_rounded
                                      : Icons.circle_outlined,
                                  size: 20,
                                  color: preferences.languageCode == code
                                      ? colors.primary
                                      : colors.outline,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (preferences.persistenceError != null) ...[
              const SizedBox(height: 16),
              _PreferenceError(message: preferences.persistenceError!),
            ],
          ],
        ),
      ),
    );
  }
}

class _PreferencePanel extends StatelessWidget {
  const _PreferencePanel({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
        color: colors.surface,
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _ModeChoice extends StatelessWidget {
  const _ModeChoice({
    super.key,
    required this.label,
    required this.dark,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool dark, selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .07)
            : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(9),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(9),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 72,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xff202228)
                        : const Color(0xfff8f9fb),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: dark
                          ? const Color(0xff3c4048)
                          : const Color(0xffe0e3e7),
                    ),
                  ),
                  child: Column(
                    children: [
                      Container(height: 12, color: const Color(0xff868990)),
                      Expanded(
                        child: Row(
                          children: [
                            Container(
                              width: 18,
                              color: const Color(0xff868990),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 9,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 45,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        color: dark
                                            ? const Color(0xffc0c3cb)
                                            : const Color(0xffa1a6b1),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: dark
                                              ? const Color(0xff30333b)
                                              : Colors.white,
                                          borderRadius: BorderRadius.circular(
                                            3,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 9),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      dark
                          ? Icons.dark_mode_outlined
                          : Icons.light_mode_outlined,
                      size: 17,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 18,
                      color: selected ? colors.primary : colors.outline,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MonochromeSwatch extends StatelessWidget {
  const _MonochromeSwatch({required this.selected, required this.onTap});
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: tr('흑백'),
      button: true,
      selected: selected,
      child: Tooltip(
        message: tr('흑백'),
        child: InkResponse(
          key: const Key('appearance-accent-monochrome'),
          onTap: onTap,
          radius: 24,
          child: Container(
            width: 40,
            height: 40,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colors.onSurface : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: colors.outlineVariant),
              ),
              child: ClipOval(
                child: CustomPaint(
                  painter: const _MonochromePainter(),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MonochromePainter extends CustomPainter {
  const _MonochromePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final lowerHalf = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(lowerHalf, Paint()..color = Colors.black);
  }

  @override
  bool shouldRepaint(covariant _MonochromePainter oldDelegate) => false;
}

class _PreferenceError extends StatelessWidget {
  const _PreferenceError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Text(
      tr(message),
      style: TextStyle(fontSize: 12, color: colors.error),
    );
  }
}
