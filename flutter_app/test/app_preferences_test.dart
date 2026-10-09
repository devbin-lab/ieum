import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_preferences.dart';

void main() {
  late Directory temporary;
  late File preferencesFile;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('ieum-preferences-test-');
    preferencesFile = File(
      '${temporary.path}${Platform.pathSeparator}preferences.json',
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'preferences persist and reload without changing personal defaults',
    () async {
      final preferences = AppPreferences(file: preferencesFile);
      addTearDown(preferences.dispose);
      await preferences.load();
      expect(preferences.themeMode, ThemeMode.light);
      expect(preferences.accentColor, AppPreferences.defaultAccent);
      expect(preferences.languageCode, 'ko');
      expect(preferences.persistenceError, isNull);

      await preferences.setThemeMode(ThemeMode.dark);
      await preferences.setAccentColor(const Color(0x883478d4));
      await preferences.setLanguage('en');
      expect(preferences.accentColor, const Color(0xff3478d4));

      final restored = AppPreferences(file: preferencesFile);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.themeMode, ThemeMode.dark);
      expect(restored.accentColor, const Color(0xff3478d4));
      expect(restored.languageCode, 'en');
      expect(restored.persistenceError, isNull);
      expect(await File('${preferencesFile.path}.tmp').exists(), isFalse);

      await preferences.resetDesign();
      await restored.load();
      expect(restored.themeMode, ThemeMode.light);
      expect(restored.accentColor, AppPreferences.defaultAccent);
      expect(restored.languageCode, 'en');
    },
  );

  test('monochrome accent follows the theme and survives reload', () async {
    final preferences = AppPreferences(file: preferencesFile);
    addTearDown(preferences.dispose);

    await preferences.setMonochromeAccent();
    expect(preferences.monochromeAccent, isTrue);
    expect(preferences.accentColor, Colors.black);
    expect(preferences.accentForBrightness(Brightness.light), Colors.black);
    expect(preferences.accentForBrightness(Brightness.dark), Colors.white);

    await preferences.setThemeMode(ThemeMode.dark);
    expect(preferences.accentColor, Colors.white);
    final restored = AppPreferences(file: preferencesFile);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.monochromeAccent, isTrue);
    expect(restored.accentColor, Colors.white);

    await restored.setThemeMode(ThemeMode.light);
    expect(restored.accentColor, Colors.black);
    // Returning to the previously stored fixed color must exit adaptive mode.
    await restored.setAccentColor(AppPreferences.defaultAccent);
    expect(restored.monochromeAccent, isFalse);
    expect(restored.accentColor, AppPreferences.defaultAccent);
    expect(
      jsonDecode(await preferencesFile.readAsString())['accentMode'],
      isNull,
    );
    await preferences.load();
    expect(preferences.monochromeAccent, isFalse);
    expect(preferences.accentColor, AppPreferences.defaultAccent);

    await preferences.setMonochromeAccent();
    await preferences.resetDesign();
    await restored.load();
    expect(restored.monochromeAccent, isFalse);
    expect(restored.accentColor, AppPreferences.defaultAccent);
  });

  test('rapid changes serialize to the last complete snapshot', () async {
    final preferences = AppPreferences(file: preferencesFile);
    addTearDown(preferences.dispose);
    final writes = <Future<void>>[];
    for (var i = 0; i < 12; i++) {
      writes.add(
        preferences.setThemeMode(i.isEven ? ThemeMode.dark : ThemeMode.light),
      );
      writes.add(
        preferences.setAccentColor(Color(0xff000000 | (i + 1) * 0x10203)),
      );
      writes.add(preferences.setLanguage(i.isEven ? 'en' : 'ko'));
    }
    writes.add(preferences.setThemeMode(ThemeMode.dark));
    writes.add(preferences.setAccentColor(const Color(0xff16878c)));
    writes.add(preferences.setLanguage('en'));
    await Future.wait(writes);

    final data = jsonDecode(
      await preferencesFile.readAsString(),
    ) as Map<String, dynamic>;
    expect(data, {
      'schema': 1,
      'theme': 'dark',
      'accent': '16878c',
      'language': 'en',
    });
    expect(preferences.persistenceError, isNull);
    final restored = AppPreferences(file: preferencesFile);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.themeMode, preferences.themeMode);
    expect(restored.accentColor, preferences.accentColor);
    expect(restored.languageCode, preferences.languageCode);
  });

  test(
    'unknown schema and invalid values safely retain supported defaults',
    () async {
      for (final data in [
        {'schema': 50, 'theme': 'dark', 'accent': '3478d4', 'language': 'en'},
        {
          'schema': 1,
          'theme': 'unsupported',
          'accent': 'not-a-color',
          'language': 'fr',
        },
        {'schema': 1, 'theme': null, 'accent': 1234, 'language': []},
        ['unexpected', 'shape'],
      ]) {
        await preferencesFile.writeAsString(jsonEncode(data));
        final preferences = AppPreferences(file: preferencesFile);
        try {
          await preferences.load();
          expect(preferences.themeMode, ThemeMode.light);
          expect(preferences.accentColor, AppPreferences.defaultAccent);
          expect(preferences.languageCode, 'ko');
          expect(preferences.persistenceError, isNull);
        } finally {
          preferences.dispose();
        }
      }
    },
  );

  test('corrupt JSON reports the problem and can be repaired by a preference change', () async {
    await preferencesFile.writeAsString('{"schema":1,"theme":');
    final preferences = AppPreferences(file: preferencesFile);
    addTearDown(preferences.dispose);
    await expectLater(preferences.load(), completes);
    expect(preferences.themeMode, ThemeMode.light);
    expect(preferences.accentColor, AppPreferences.defaultAccent);
    expect(preferences.languageCode, 'ko');
    expect(preferences.persistenceError, isNotNull);

    await preferences.setLanguage('en');
    expect(preferences.persistenceError, isNull);
    final data = jsonDecode(
      await preferencesFile.readAsString(),
    ) as Map<String, dynamic>;
    expect(data['language'], 'en');
    expect(data['theme'], 'light');
  });

  test('unsupported language and automatic theme are rejected without changing state', () async {
    final preferences = AppPreferences(file: preferencesFile);
    addTearDown(preferences.dispose);
    expect(() => preferences.setLanguage('fr'), throwsArgumentError);
    expect(
      () => preferences.setThemeMode(ThemeMode.system),
      throwsArgumentError,
    );
    expect(preferences.languageCode, 'ko');
    expect(preferences.themeMode, ThemeMode.light);
    expect(preferences.persistenceError, isNull);
    expect(await preferencesFile.exists(), isFalse);
  });

  test(
    'save failure keeps the application responsive and permits retry',
    () async {
      final blockedParent = File(
        '${temporary.path}${Platform.pathSeparator}blocked',
      );
      await blockedParent.writeAsString(
        'This fixture blocks creation of a directory.',
      );
      final target = File(
        '${blockedParent.path}${Platform.pathSeparator}preferences.json',
      );
      final preferences = AppPreferences(file: target);
      addTearDown(preferences.dispose);
      var notifications = 0;
      preferences.addListener(() => notifications++);

      await expectLater(preferences.setThemeMode(ThemeMode.dark), completes);
      expect(preferences.themeMode, ThemeMode.dark);
      expect(preferences.persistenceError, isNotNull);
      expect(notifications, greaterThan(0));

      await expectLater(preferences.setLanguage('en'), completes);
      expect(preferences.languageCode, 'en');
      expect(preferences.persistenceError, isNotNull);

      await blockedParent.delete();
      await preferences.setLanguage('en');
      expect(preferences.persistenceError, isNull);
      final restored = AppPreferences(file: target);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.themeMode, ThemeMode.dark);
      expect(restored.languageCode, 'en');
    },
  );
}
