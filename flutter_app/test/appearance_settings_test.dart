import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/app_preferences.dart';
import 'package:ieum_flutter/app_theme.dart';
import 'package:ieum_flutter/appearance_settings.dart';
import 'package:ieum_flutter/settings_shell.dart';

Widget preferenceApp(AppPreferences preferences, Widget child) =>
    AnimatedBuilder(
      animation: preferences,
      builder: (context, _) {
        setAppLanguage(preferences.languageCode);
        return AppPreferencesScope(
          preferences: preferences,
          child: MaterialApp(
            theme: buildAppTheme(
              preferences.accentForBrightness(Brightness.light),
              Brightness.light,
            ),
            darkTheme: buildAppTheme(
              preferences.accentForBrightness(Brightness.dark),
              Brightness.dark,
            ),
            themeMode: preferences.themeMode,
            home: Scaffold(body: SingleChildScrollView(child: child)),
          ),
        );
      },
    );

void main() {
  tearDown(() => setAppLanguage('ko'));

  testWidgets(
    'personal settings contain design and language only in personal navigation',
    (tester) async {
      SettingsSection? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsShell(
              personal: true,
              selected: SettingsSection.general,
              onSelected: (value) => chosen = value,
              contentBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('settings-general')), findsOneWidget);
      expect(find.byKey(const Key('settings-design')), findsOneWidget);
      expect(find.byKey(const Key('settings-language')), findsOneWidget);
      expect(find.byKey(const Key('settings-projectGeneral')), findsNothing);
      await tester.tap(find.byKey(const Key('settings-design')));
      expect(chosen, SettingsSection.design);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsShell(
              personal: false,
              selected: SettingsSection.projectGeneral,
              onSelected: (_) {},
              contentBuilder: (_) => const SizedBox.shrink(),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('settings-projectGeneral')), findsOneWidget);
      expect(find.byKey(const Key('settings-design')), findsNothing);
      expect(find.byKey(const Key('settings-language')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'appearance selections apply mode and validated custom accent, reset keeps language',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        preferenceApp(preferences, const AppearanceSettings()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('appearance-dark')));
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.dark);
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.dark,
      );

      final hex = find.byKey(const Key('appearance-custom-hex'));
      await tester.ensureVisible(hex);
      await tester.enterText(hex, 'nope');
      await tester.tap(find.byKey(const Key('appearance-apply-hex')));
      await tester.pumpAndSettle();
      expect(preferences.accentColor, AppPreferences.defaultAccent);
      expect(find.text('올바른 색상 코드를 입력하세요. (예: #7963D5)'), findsOneWidget);

      await tester.enterText(hex, '#2A8BCA');
      await tester.tap(find.byKey(const Key('appearance-apply-hex')));
      await tester.pumpAndSettle();
      expect(preferences.accentColor, const Color(0xff2a8bca));
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings)))
            .colorScheme
            .primary,
        const Color(0xff2a8bca),
      );

      await preferences.setLanguage('en');
      await tester.pumpAndSettle();
      final reset = find.byKey(const Key('appearance-reset'));
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.light);
      expect(preferences.accentColor, AppPreferences.defaultAccent);
      expect(preferences.languageCode, 'en');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'language changes immediately and language names remain recognizable',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        preferenceApp(preferences, const LanguageSettings()),
      );
      await tester.pumpAndSettle();
      expect(find.text('앱 언어'), findsOneWidget);
      await tester.tap(find.byKey(const Key('appearance-language-en')));
      await tester.pumpAndSettle();
      expect(preferences.languageCode, 'en');
      expect(find.text('App language'), findsOneWidget);
      expect(find.text('한국어'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      await tester.tap(find.byKey(const Key('appearance-language-ko')));
      await tester.pumpAndSettle();
      expect(preferences.languageCode, 'ko');
      expect(find.text('앱 언어'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'system theme follows device brightness and monochrome contrast',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      addTearDown(
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
      );
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      await preferences.setMonochromeAccent();
      await tester.pumpWidget(
        preferenceApp(preferences, const AppearanceSettings()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appearance-system')));
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.system);
      final context = tester.element(find.byType(AppearanceSettings));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(Theme.of(context).colorScheme.primary, Colors.white);
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      await tester.pumpAndSettle();
      expect(Theme.of(context).brightness, Brightness.light);
      expect(Theme.of(context).colorScheme.primary, Colors.black);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('appearance and language settings fit narrow scaled layouts', (
    tester,
  ) async {
    final preferences = AppPreferences();
    addTearDown(preferences.dispose);
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final width in [260.0, 420.0]) {
      for (final child in [
        const AppearanceSettings(),
        const LanguageSettings(),
      ]) {
        await tester.pumpWidget(
          preferenceApp(
            preferences,
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: child),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
