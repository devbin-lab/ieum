import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/app_preferences.dart';
import 'package:ieum_flutter/app_theme.dart';
import 'package:ieum_flutter/first_run.dart';
import 'package:ieum_flutter/project_gate.dart';
import 'package:ieum_flutter/project_service.dart';

Widget setupApp(AppPreferences preferences, Widget home, {double scale = 1}) =>
    AnimatedBuilder(
      animation: preferences,
      builder: (context, child) {
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: home,
          ),
        );
      },
    );

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    setAppLanguage('ko');
    directory = await Directory.systemTemp.createTemp('ieum-first-run-');
    file = File('${directory.path}/app-preferences.json');
  });
  tearDown(() async {
    setAppLanguage('ko');
    await directory.delete(recursive: true);
  });

  test(
    'an unfinished setup remains unfinished after preferences and restart',
    () async {
      final preferences = AppPreferences(file: file);
      addTearDown(preferences.dispose);
      await preferences.load();
      expect(preferences.onboardingComplete, isFalse);
      await preferences.setThemeMode(ThemeMode.dark);
      await preferences.setLanguage('en');
      final restored = AppPreferences(file: file);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.onboardingComplete, isFalse);
      expect(restored.themeMode, ThemeMode.dark);
      expect(restored.languageCode, 'en');
      expect(await restored.completeOnboarding(), isTrue);
      await preferences.load();
      expect(preferences.onboardingComplete, isTrue);
    },
  );

  test('legacy preferences and catalogs bypass setup without changing user choices', () async {
    await file.writeAsString(
      jsonEncode({
        'schema': 1,
        'theme': 'dark',
        'accent': '16878c',
        'language': 'en',
      }),
    );
    final preferences = AppPreferences(file: file);
    addTearDown(preferences.dispose);
    await preferences.load();
    expect(preferences.onboardingComplete, isTrue);
    expect(preferences.themeMode, ThemeMode.dark);
    expect(preferences.languageCode, 'en');
    final catalog = File('${directory.path}/projects.json');
    await catalog.writeAsString('{broken');
    expect(hasSavedProjectCatalog(catalog), isFalse);
    await File('${catalog.path}.bak').writeAsString(
      jsonEncode({
        'schema': 2,
        'accounts': {
          'gh-1': {
            'projects': [
              {
                'path': '${directory.path}/saved.sqlite',
                'name': 'Existing',
                'projectId': 'existing',
                'repository': 'team/project',
                'base': 'main',
                'branch': 'ieum/user',
                'enabled': true,
              },
            ],
          },
        },
      }),
    );
    expect(hasSavedProjectCatalog(catalog), isTrue);
  });

  test('save failure keeps setup unfinished and permits retry', () async {
    final blocker = File('${directory.path}/blocked');
    await blocker.writeAsString('blocks directory creation');
    final preferences = AppPreferences(
      file: File('${blocker.path}/prefs.json'),
    );
    addTearDown(preferences.dispose);
    expect(await preferences.completeOnboarding(), isFalse);
    expect(preferences.onboardingComplete, isFalse);
    expect(preferences.persistenceError, isNotNull);
    await blocker.delete();
    expect(await preferences.completeOnboarding(), isTrue);
    expect(preferences.onboardingComplete, isTrue);
  });

  testWidgets(
    'skip mounts authentication once and keeps it alive when revisiting',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      var mounts = 0;
      final home = FirstRunGate(
        preferences: preferences,
        builder: (open) =>
            _AuthenticationStub(onMount: () => mounts++, onSettings: open),
      );
      await tester.pumpWidget(setupApp(preferences, home));
      await tester.pumpAndSettle();
      expect(mounts, 0);
      await tester.ensureVisible(find.byKey(const Key('setup-skip')));
      await tester.tap(find.byKey(const Key('setup-skip')));
      await tester.pumpAndSettle();
      expect(mounts, 1);
      expect(preferences.onboardingComplete, isTrue);
      await tester.tap(find.byKey(const Key('stub-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('setup-next')), findsOneWidget);
      expect(mounts, 1);
      await tester.ensureVisible(find.byKey(const Key('setup-skip')));
      await tester.tap(find.byKey(const Key('setup-skip')));
      await tester.pumpAndSettle();
      expect(mounts, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'existing projects bypass welcome even without local appearance preferences',
    (tester) async {
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      await tester.pumpWidget(
        setupApp(
          preferences,
          FirstRunGate(
            preferences: preferences,
            existingProject: true,
            builder: (_) => const Scaffold(body: Text('existing-project')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('existing-project'), findsOneWidget);
      expect(find.byKey(const Key('setup-next')), findsNothing);
    },
  );

  testWidgets(
    'authentication starts only after setup and login fits a narrow scaled window',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 420);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      final session = _SignedOutSession();
      await tester.pumpWidget(
        setupApp(
          preferences,
          FirstRunGate(
            preferences: preferences,
            builder: (open) => ProjectGate(
              session: session,
              preferences: File('${directory.path}/projects.json'),
              onOpenInitialSettings: open,
            ),
          ),
          scale: 1.4,
        ),
      );
      await tester.pumpAndSettle();
      expect(session.restoreCalls, 0);
      await tester.ensureVisible(find.byKey(const Key('setup-skip')));
      await tester.tap(find.byKey(const Key('setup-skip')));
      await tester.pumpAndSettle();
      expect(session.restoreCalls, 1);
      await tester.ensureVisible(find.byKey(const Key('github-login')));
      expect(find.byKey(const Key('github-login')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const Key('open-initial-settings')),
      );
      await tester.tap(find.byKey(const Key('open-initial-settings')));
      await tester.pumpAndSettle();
      expect(session.restoreCalls, 1);
      expect(find.byKey(const Key('setup-next')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'complete flow applies defaults and remains usable at minimum size with large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(480, 420);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      var completed = 0;
      await tester.pumpWidget(
        setupApp(
          preferences,
          FirstRunWizard(
            preferences: preferences,
            onFinished: () => completed++,
          ),
          scale: 1.6,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('setup-next')));
      await tester.tap(find.byKey(const Key('setup-next')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('setup-theme-system')));
      await tester.tap(find.byKey(const Key('setup-theme-system')));
      await tester.pumpAndSettle();
      expect(preferences.themeMode, ThemeMode.system);
      await tester.ensureVisible(
        find.byKey(const Key('setup-accent-monochrome')),
      );
      await tester.tap(find.byKey(const Key('setup-accent-monochrome')));
      await tester.pumpAndSettle();
      expect(preferences.monochromeAccent, isTrue);
      expect(preferences.onboardingComplete, isFalse);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('setup-next')));
      await tester.tap(find.byKey(const Key('setup-next')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('setup-finish')));
      await tester.tap(find.byKey(const Key('setup-finish')));
      await tester.pumpAndSettle();
      expect(completed, 1);
      expect(preferences.onboardingComplete, isTrue);
    },
  );
}

class _SignedOutSession extends GitHubSession {
  int restoreCalls = 0;
  @override
  Future<bool> restoreOAuth() async {
    restoreCalls++;
    return false;
  }
}

class _AuthenticationStub extends StatefulWidget {
  const _AuthenticationStub({required this.onMount, required this.onSettings});
  final VoidCallback onMount, onSettings;
  @override
  State<_AuthenticationStub> createState() => _AuthenticationStubState();
}

class _AuthenticationStubState extends State<_AuthenticationStub> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        key: const Key('stub-settings'),
        onPressed: widget.onSettings,
        child: const Text('Initial preferences'),
      ),
    ),
  );
}
