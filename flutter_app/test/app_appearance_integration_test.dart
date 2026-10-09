import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/app_preferences.dart';
import 'package:ieum_flutter/appearance_settings.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_editor.dart';

import 'part_workflow_test_fixtures.dart';
import 'task_deletion_test.dart' show task;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  setUp(() {
    setAppLanguage('ko');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          windowChannel,
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  tearDown(() {
    setAppLanguage('ko');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowChannel, null);
  });

  TaskStore fixture() {
    final project = ProjectManifest.fromJson({
      ...personalReviewProject.json,
      'name': '작업',
    });
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: routeWorker,
      seed: [
        task().copy({'title': '진행중', 'description': '사용자가 작성한 한국어 설명'}).data,
      ],
    );
    store.setMeta(
      'ui.workspace',
      jsonEncode({
        'page': 6,
        'view': 'kanban',
        'lastWorkPage': 6,
        'projectTabsVersion': 1,
      }),
    );
    addTearDown(store.dispose);
    return store;
  }

  Future<void> mount(
    WidgetTester tester,
    TaskStore store,
    AppPreferences preferences,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      IeumApp(
        store: store,
        preferences: preferences,
        home: Workspace(
          store: store,
          projectSwitcher: Text(store.project!.name),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> personalSettings(WidgetTester tester, String section) async {
    await tester.tap(find.byKey(const Key('sidebar-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('settings-$section')));
    await tester.pumpAndSettle();
  }

  BorderRadiusGeometry mainCorners(WidgetTester tester) =>
      (tester
                  .widget<Material>(
                    find.byKey(const Key('workspace-main-surface')),
                  )
                  .shape!
              as RoundedRectangleBorder)
          .borderRadius;

  testWidgets(
    'personal design controls update the actual app theme and preserve workspace structure',
    (tester) async {
      final store = fixture();
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      final taskSnapshot = jsonEncode(
        store.tasks.map((task) => task.data).toList(),
      );
      await mount(tester, store, preferences);
      final corners = mainCorners(tester);
      expect(find.byKey(const Key('task-kanban')), findsOneWidget);

      await personalSettings(tester, 'design');
      expect(find.byType(AppearanceSettings), findsOneWidget);
      expect(find.byKey(const Key('settings-language')), findsOneWidget);
      expect(find.byKey(const Key('settings-projectGeneral')), findsNothing);
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsNothing);
      await tester.tap(find.byKey(const Key('appearance-dark')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appearance-accent-ff3478d4')));
      await tester.pumpAndSettle();

      final materialApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(materialApp.themeMode, ThemeMode.dark);
      expect(
        materialApp.darkTheme!.colorScheme.primary,
        const Color(0xff3478d4),
      );
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings))).brightness,
        Brightness.dark,
      );
      expect(preferences.accentColor, const Color(0xff3478d4));
      expect(mainCorners(tester), corners);
      final chrome = tester
          .widget<Container>(find.byKey(const Key('window-titlebar')))
          .color;
      final rail = tester.widget<Container>(
        find.byKey(const Key('workspace-sidebar')),
      );
      expect((rail.decoration! as BoxDecoration).color, chrome);
      expect(chrome, isNot(const Color(0xff3478d4)));

      await tester.tap(find.byKey(const Key('project-home')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-kanban')), findsOneWidget);
      expect(jsonDecode(store.meta('ui.workspace'))['view'], 'kanban');
      expect(
        jsonEncode(store.tasks.map((task) => task.data).toList()),
        taskSnapshot,
      );
      expect(mainCorners(tester), corners);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'diagonal monochrome swatch switches black and white with the actual app theme',
    (tester) async {
      final store = fixture();
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      final snapshot = jsonEncode(
        store.tasks.map((task) => task.data).toList(),
      );
      await mount(tester, store, preferences);
      await personalSettings(tester, 'design');

      await tester.tap(find.byKey(const Key('appearance-accent-monochrome')));
      await tester.pumpAndSettle();
      expect(preferences.monochromeAccent, isTrue);
      var colors = Theme.of(tester.element(find.byType(AppearanceSettings)))
          .colorScheme;
      expect(colors.primary, Colors.black);
      expect(colors.onPrimary, Colors.white);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.theme!.colorScheme.primary, Colors.black);
      expect(app.darkTheme!.colorScheme.primary, Colors.white);

      await tester.tap(find.byKey(const Key('appearance-dark')));
      await tester.pumpAndSettle();
      colors = Theme.of(tester.element(find.byType(AppearanceSettings)))
          .colorScheme;
      expect(preferences.monochromeAccent, isTrue);
      expect(colors.primary, Colors.white);
      expect(colors.onPrimary, Colors.black);

      await tester.tap(find.byKey(const Key('appearance-light')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings)))
            .colorScheme
            .primary,
        Colors.black,
      );
      await tester.tap(find.byKey(const Key('appearance-accent-ff3478d4')));
      await tester.pumpAndSettle();
      expect(preferences.monochromeAccent, isFalse);
      expect(preferences.accentColor, const Color(0xff3478d4));
      await tester.tap(find.byKey(const Key('appearance-dark')));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(AppearanceSettings)))
            .colorScheme
            .primary,
        const Color(0xff3478d4),
      );
      expect(
        jsonEncode(store.tasks.map((task) => task.data).toList()),
        snapshot,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'language choice translates app controls while preserving Korean user data and active view',
    (tester) async {
      final store = fixture();
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      final taskSnapshot = jsonEncode(
        store.tasks.map((task) => task.data).toList(),
      );
      final projectSnapshot = jsonEncode(store.project!.json);
      await mount(tester, store, preferences);

      await personalSettings(tester, 'language');
      await tester.tap(find.byKey(const Key('appearance-language-en')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('en'),
      );
      expect(find.text('App language'), findsOneWidget);
      await tester.tap(find.byKey(const Key('project-home')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-kanban')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('project-view-tab-schedule')),
          matching: find.text('Schedule'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('project-view-tab-timeline')),
          matching: find.text('Timeline'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('new-task')),
          matching: find.text('New task'),
        ),
        findsOneWidget,
      );
      expect(find.text('In progress'), findsWidgets);
      expect(find.text('진행중'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('workspace-project-name')))
            .data,
        '작업',
      );

      await tester.tap(find.byKey(const Key('sidebar-account')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('account-menu-summary')),
          matching: find.text('기획자'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('account-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appearance-language-ko')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-home')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('ko'),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('new-task')),
          matching: find.text('새 작업'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('project-view-tab-schedule')),
          matching: find.text('일정'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('task-kanban')), findsOneWidget);
      expect(
        jsonEncode(store.tasks.map((task) => task.data).toList()),
        taskSnapshot,
      );
      expect(jsonEncode(store.project!.json), projectSnapshot);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'open task editor keeps unsaved draft across theme accent and language changes',
    (tester) async {
      final store = fixture();
      final preferences = AppPreferences();
      addTearDown(preferences.dispose);
      final snapshot = jsonEncode(
        store.tasks.map((task) => task.data).toList(),
      );
      await mount(tester, store, preferences);
      await tester.tap(find.byKey(const Key('new-task')));
      await tester.pumpAndSettle();
      final editorState = tester.state(find.byType(TaskEditor));
      const draftTitle = '진행중 · 작성 중인 초안';
      const draftDescription = '사용자가 입력한 설명은 설정을 변경해도 유지되어야 합니다.';
      await tester.enterText(find.byKey(const Key('task-title')), draftTitle);
      await tester.enterText(
        find.byKey(const Key('task-description')),
        draftDescription,
      );

      await preferences.setThemeMode(ThemeMode.dark);
      await preferences.setAccentColor(const Color(0xff16878c));
      await preferences.setLanguage('en');
      await tester.pumpAndSettle();
      expect(
        identical(tester.state(find.byType(TaskEditor)), editorState),
        isTrue,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('task-title')))
            .controller!
            .text,
        draftTitle,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('task-description')))
            .controller!
            .text,
        draftDescription,
      );
      expect(
        Theme.of(tester.element(find.byType(TaskEditor))).brightness,
        Brightness.dark,
      );
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).locale,
        const Locale('en'),
      );

      await preferences.setLanguage('ko');
      await preferences.setThemeMode(ThemeMode.light);
      await tester.pumpAndSettle();
      expect(
        identical(tester.state(find.byType(TaskEditor)), editorState),
        isTrue,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('task-title')))
            .controller!
            .text,
        draftTitle,
      );
      expect(
        jsonEncode(store.tasks.map((task) => task.data).toList()),
        snapshot,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
