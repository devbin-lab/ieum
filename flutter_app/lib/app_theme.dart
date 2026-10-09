import 'package:flutter/material.dart';

/// Locale participates in Theme equality so all themed UI refreshes immediately
/// when the app language changes, without remounting navigation or drafts.
class AppLanguageTheme extends ThemeExtension<AppLanguageTheme> {
  const AppLanguageTheme(this.code);
  final String code;
  @override
  AppLanguageTheme copyWith({String? code}) =>
      AppLanguageTheme(code ?? this.code);
  @override
  AppLanguageTheme lerp(covariant AppLanguageTheme? other, double t) =>
      t < .5 || other == null ? this : other;
  @override
  bool operator ==(Object other) =>
      other is AppLanguageTheme && other.code == code;
  @override
  int get hashCode => code.hashCode;
}

ThemeData buildAppTheme(
  Color accent,
  Brightness brightness, {
  String languageCode = 'ko',
}) {
  final dark = brightness == Brightness.dark;
  final ink = dark ? const Color(0xffe4e7ec) : const Color(0xff302b3c);
  final muted = dark ? const Color(0xffa5acb8) : const Color(0xff6e687b);
  final line = dark ? const Color(0xff353b46) : const Color(0xffe1e3e6);
  final surface = dark ? const Color(0xff20242c) : Colors.white;
  final canvas = dark ? const Color(0xff181c23) : const Color(0xfffafbfa);
  final onAccent = accent.computeLuminance() > .179
      ? Colors.black
      : Colors.white;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary: onAccent,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: muted,
        outline: line,
        outlineVariant: line,
        surfaceContainerLowest: canvas,
        surfaceContainerLow: dark
            ? const Color(0xff272c35)
            : const Color(0xfff4f5f7),
        surfaceContainer: dark
            ? const Color(0xff2d333d)
            : const Color(0xffeeefF2),
        primaryContainer: Color.alphaBlend(
          accent.withValues(alpha: dark ? .22 : .10),
          surface,
        ),
        onPrimaryContainer: dark
            ? Color.lerp(accent, Colors.white, .55)!
            : Color.lerp(accent, Colors.black, .15)!,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: 'Malgun Gothic',
    colorScheme: scheme,
    extensions: [AppLanguageTheme(languageCode)],
    scaffoldBackgroundColor: canvas,
    dividerColor: line,
    iconTheme: IconThemeData(color: muted, size: 20),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 24,
      shadowColor: Colors.black.withValues(alpha: dark ? .35 : .20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: line),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xff424955) : ink,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      textStyle: const TextStyle(
        fontFamily: 'Malgun Gothic',
        fontSize: 11,
        color: Colors.white,
      ),
      waitDuration: const Duration(milliseconds: 450),
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(fontSize: 14, height: 1.5, color: ink),
      bodyMedium: TextStyle(fontSize: 13, height: 1.5, color: ink),
      bodySmall: TextStyle(fontSize: 11, height: 1.5, color: muted),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      labelLarge: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      labelStyle: TextStyle(fontSize: 12, color: muted),
      hintStyle: TextStyle(fontSize: 12, color: muted),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: scheme.onPrimaryContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontFamily: 'Malgun Gothic',
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: onAccent,
        textStyle: const TextStyle(
          fontFamily: 'Malgun Gothic',
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        minimumSize: const Size(36, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        textStyle: const TextStyle(fontFamily: 'Malgun Gothic', fontSize: 13),
        minimumSize: const Size(36, 36),
        side: BorderSide(color: line),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(surface)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xff424955) : ink,
      contentTextStyle: const TextStyle(color: Colors.white),
    ),
  );
}
