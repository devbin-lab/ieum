import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Local app preferences, deliberately separate from shared project data.
class AppPreferences extends ChangeNotifier {
  AppPreferences({this.file});

  static const defaultAccent = Color(0xff7963d5);
  final File? file;
  ThemeMode _themeMode = ThemeMode.light;
  Color _accentColor = defaultAccent;
  bool _monochromeAccent = false;
  String _languageCode = 'ko';
  String? _persistenceError;
  Future<void> _writes = Future<void>.value();
  bool _disposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get monochromeAccent => _monochromeAccent;
  Color get accentColor => accentForBrightness(
    _themeMode == ThemeMode.dark ? Brightness.dark : Brightness.light,
  );
  Color accentForBrightness(Brightness brightness) => _monochromeAccent
      ? brightness == Brightness.dark
            ? Colors.white
            : Colors.black
      : _accentColor;
  String get languageCode => _languageCode;
  String? get persistenceError => _persistenceError;

  Future<void> load() async {
    if (file == null || !await file!.exists()) return;
    try {
      final data = jsonDecode(await file!.readAsString());
      if (data is! Map || data['schema'] != 1) return;
      _themeMode = data['theme'] == 'dark' ? ThemeMode.dark : ThemeMode.light;
      final accent = data['accent'];
      if (accent is String && RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(accent)) {
        _accentColor = Color(0xff000000 | int.parse(accent, radix: 16));
      }
      _monochromeAccent = data['accentMode'] == 'monochrome';
      _languageCode = data['language'] == 'en' ? 'en' : 'ko';
      _persistenceError = null;
      _notify();
    } on Object {
      // A corrupt preferences file must not prevent login or opening projects.
      _persistenceError = '설정을 불러오지 못했습니다. 기본 설정을 사용합니다.';
      _notify();
    }
  }

  Future<void> setThemeMode(ThemeMode mode) {
    if (mode == ThemeMode.system) {
      throw ArgumentError.value(mode, 'mode', 'Choose light or dark');
    }
    if (_themeMode == mode && _persistenceError == null) {
      return Future<void>.value();
    }
    _themeMode = mode;
    return _save();
  }

  Future<void> setAccentColor(Color color) {
    final opaque = color.withValues(alpha: 1);
    if (!_monochromeAccent &&
        _accentColor == opaque &&
        _persistenceError == null) {
      return Future<void>.value();
    }
    _monochromeAccent = false;
    _accentColor = opaque;
    return _save();
  }

  Future<void> setMonochromeAccent() {
    if (_monochromeAccent && _persistenceError == null) {
      return Future<void>.value();
    }
    _monochromeAccent = true;
    return _save();
  }

  Future<void> setLanguage(String code) {
    if (code != 'ko' && code != 'en') {
      throw ArgumentError.value(code, 'code', 'Unsupported app language');
    }
    if (_languageCode == code && _persistenceError == null) {
      return Future<void>.value();
    }
    _languageCode = code;
    return _save();
  }

  Future<void> resetDesign() {
    _themeMode = ThemeMode.light;
    _accentColor = defaultAccent;
    _monochromeAccent = false;
    return _save();
  }

  Future<void> _save() {
    _persistenceError = null;
    final snapshot = jsonEncode({
      'schema': 1,
      'theme': _themeMode == ThemeMode.dark ? 'dark' : 'light',
      'accent': (_accentColor.toARGB32() & 0xffffff)
          .toRadixString(16)
          .padLeft(6, '0'),
      if (_monochromeAccent) 'accentMode': 'monochrome',
      'language': _languageCode,
    });
    _notify();
    final next = _writes.then((_) async {
      if (file == null) return;
      try {
        await file!.parent.create(recursive: true);
        final pending = File('${file!.path}.tmp');
        await pending.writeAsString(snapshot, flush: true);
        await pending.rename(file!.path);
        _persistenceError = null;
      } on Object {
        _persistenceError = '설정을 저장하지 못했습니다. 다시 시도해 주세요.';
      }
      _notify();
    });
    _writes = next;
    return next;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class AppPreferencesScope extends InheritedNotifier<AppPreferences> {
  const AppPreferencesScope({
    super.key,
    required AppPreferences preferences,
    required super.child,
  }) : super(notifier: preferences);

  static AppPreferences? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AppPreferencesScope>()
      ?.notifier;

  static AppPreferences of(BuildContext context) {
    final preferences = maybeOf(context);
    assert(preferences != null, 'AppPreferencesScope is missing');
    return preferences!;
  }
}
