import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/project_picker.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/window_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TaskStore store;
  setUp(() {
    store = TaskStore(
      ':memory:',
      seed:
          jsonDecode(
                File('assets/demo-snapshot.json').readAsStringSync(),
              )['tasks']
              as List,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  tearDown(() => store.dispose());

  testWidgets(
    'titlebar history navigates schedule, alerts, connections and settings',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1440, 940);
      await tester.pumpWidget(
        IeumApp(
          store: store,
          home: Workspace(store: store, projectSwitcher: const Text('현재 프로젝트')),
        ),
      );
      await tester.pumpAndSettle();

      GestureDetector button(String key) => tester.widget<GestureDetector>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is GestureDetector &&
                widget.behavior == HitTestBehavior.opaque,
          ),
        ),
      );
      GestureDetector back() => button('titlebar-back');
      GestureDetector forward() => button('titlebar-forward');

      expect(back().onTap, isNull);
      expect(forward().onTap, isNull);
      await tester.tap(find.byKey(const Key('sidebar-notifications')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsNothing);
      expect(back().onTap, isNotNull);
      await tester.tap(find.byKey(const Key('titlebar-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-list')), findsOneWidget);
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsOneWidget);
      expect(forward().onTap, isNotNull);
      await tester.tap(find.byKey(const Key('titlebar-forward')));
      await tester.pumpAndSettle();
      expect(find.text('알림'), findsWidgets);
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsNothing);
      await tester.tap(find.byKey(const Key('project-home')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-view-tab-connections')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connections-page')), findsOneWidget);
      expect(find.byKey(const Key('project-view-sidebar')), findsOneWidget);
      expect(forward().onTap, isNull);
      await tester.tap(find.byKey(const Key('sidebar-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-shell')), findsOneWidget);
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsNothing);
      expect(back().onTap, isNotNull);
      await tester.tap(find.byKey(const Key('titlebar-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('connections-page')), findsOneWidget);
      await tester.tap(find.byKey(const Key('titlebar-forward')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-shell')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'one home destination, full width table and compact list preserve task access',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1440, 940);
      await tester.pumpWidget(IeumApp(store: store));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nav-0')), findsNothing);
      expect(find.byKey(const Key('project-home')), findsOneWidget);
      final outer = tester.getRect(find.byKey(const Key('task-list')));
      final table = tester.getRect(find.byType(DataTable));
      expect(table.width, closeTo(outer.width - 2, 1));
      tester.view.physicalSize = const Size(540, 940);
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsNothing);
      final task = store.tasks.first;
      final row = find.byKey(Key('compact-task-${task.id}'));
      await tester.ensureVisible(row);
      expect(tester.getRect(row).right, lessThanOrEqualTo(540));
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byTooltip('작업 상세 닫기'), findsOneWidget);
      expect(find.text(task.title), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'task form keeps save and close accessible in short scaled windows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      for (final size in [const Size(540, 470), const Size(1080, 540)]) {
        tester.view.physicalSize = size;
        await tester.pumpWidget(
          IeumApp(
            store: store,
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: const TextScaler.linear(1.3),
              ),
              child: Workspace(store: store),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('new-task')));
        await tester.pumpAndSettle();
        final save = find.byKey(const Key('task-save'));
        expect(save.hitTestable(), findsOneWidget);
        expect(tester.getRect(save).bottom, lessThan(size.height));
        expect(find.byTooltip('새 작업 창 닫기').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('새 작업 창 닫기'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'home sidebar preference survives tabs, history and restart from settings',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      Widget app() => IeumApp(
        store: store,
        home: Workspace(store: store, projectSwitcher: const Text('현재 프로젝트')),
      );
      Future<void> tap(String key) async {
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      Future<void> restoreWithoutAnimation(String key, bool open) async {
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
        void expectRestored() {
          final sidebar = find.byKey(const Key('project-view-sidebar'));
          expect(sidebar, open ? findsOneWidget : findsNothing);
          if (open) {
            expect(tester.getRect(sidebar).left, 56);
            expect(tester.getRect(sidebar).width, 210);
          }
        }

        expectRestored();
        await tester.pump(const Duration(milliseconds: 100));
        expectRestored();
        await tester.pumpAndSettle();
      }

      for (final width in [1440.0, 540.0]) {
        tester.view.physicalSize = Size(width, 940);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await tap('project-home');
        for (final open in [true, false]) {
          if (find
                  .byKey(const Key('project-view-sidebar'))
                  .evaluate()
                  .isNotEmpty !=
              open) {
            await tap('titlebar-sidebar-toggle');
          }
          final preference = open ? 'open' : 'closed';
          // Set an explicit preference even when it matches the initial default.
          if (store.meta('ui.projectView') != preference) {
            await tap('titlebar-sidebar-toggle');
            await tap('titlebar-sidebar-toggle');
          }
          await tap('sidebar-notifications');
          expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
          expect(store.meta('ui.projectView'), preference);
          await restoreWithoutAnimation('project-home', open);
          expect(
            find.byKey(const Key('project-view-sidebar')),
            open ? findsOneWidget : findsNothing,
          );
          // Project tabs are inside the sidebar, so expose them before clicking
          // and restore the closed preference on the destination.
          if (!open) await tap('titlebar-sidebar-toggle');
          await tap('project-view-tab-connections');
          if (!open) await tap('titlebar-sidebar-toggle');
          expect(find.byKey(const Key('connections-page')), findsOneWidget);
          expect(
            find.byKey(const Key('project-view-sidebar')),
            open ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const Key('titlebar-sidebar-toggle')),
            findsOneWidget,
          );
          expect(store.meta('ui.projectView'), preference);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(app());
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('connections-page')), findsOneWidget);
          expect(
            find.byKey(const Key('project-view-sidebar')),
            open ? findsOneWidget : findsNothing,
          );
          expect(
            find.byKey(const Key('titlebar-sidebar-toggle')),
            findsOneWidget,
          );
          await restoreWithoutAnimation('project-home', open);
          for (final settings in ['account-settings', 'project-settings']) {
            await tap('sidebar-account');
            await tap(settings);
            expect(
              find.byKey(const Key('settings-navigation')),
              findsOneWidget,
            );
            expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
            expect(store.meta('ui.projectView'), preference);
            await tester.pumpWidget(const SizedBox());
            await tester.pumpWidget(app());
            await tester.pumpAndSettle();
            expect(store.meta('ui.projectView'), preference);
            await restoreWithoutAnimation('project-home', open);
            expect(
              find.byKey(const Key('project-view-sidebar')),
              open ? findsOneWidget : findsNothing,
            );
          }
        }
        await tap('titlebar-sidebar-toggle');
        await tap('sidebar-notifications');
        await restoreWithoutAnimation('titlebar-back', true);
        await tap('titlebar-forward');
        await restoreWithoutAnimation('project-home', true);
        await tap('titlebar-sidebar-toggle');
        await tap('titlebar-back');
        await tap('titlebar-back');
        expect(find.byKey(const Key('task-list')), findsOneWidget);
        expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
        expect(store.meta('ui.projectView'), 'closed');
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'project view docks, folds, remembers state and never covers icon rail',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1440, 940);
      String selected = '';
      Widget app() => IeumApp(
        store: store,
        home: Workspace(
          store: store,
          projectSwitcherBuilder: (_) => ProjectPicker(
            projects: [
              SavedProject(
                path: 'one',
                name: '첫 프로젝트',
                projectId: 'one',
                config: const GitHubConfig(repository: 'team/one'),
              ),
              SavedProject(
                path: 'two',
                name: '두 번째 프로젝트',
                projectId: 'two',
                config: const GitHubConfig(repository: 'team/two'),
              ),
            ],
            activePath: 'one',
            onSelected: (p) => selected = p.path,
            onCreate: () {},
            onJoin: () {},
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('project-view-sidebar'))).left,
        closeTo(56, .1),
      );
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('project-option-two')));
      await tester.pump();
      expect(selected, 'two');
      double glyphProgress() =>
          (tester
                      .widget<CustomPaint>(
                        find.byKey(const Key('titlebar-sidebar-glyph')),
                      )
                      .painter!
                  as SidebarGlyphPainter)
              .progress;
      expect(glyphProgress(), 1);
      await tester.tap(find.byKey(const Key('titlebar-sidebar-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(glyphProgress(), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(glyphProgress(), 0);
      expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
      expect(
        find.byKey(const Key('titlebar-sidebar-toggle')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
      tester.view.physicalSize = const Size(540, 940);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('titlebar-sidebar-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(glyphProgress(), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(glyphProgress(), 1);
      expect(find.byKey(const Key('project-view-barrier')), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('project-view-sidebar'))).left,
        closeTo(56, .1),
      );
      expect(
        find.byKey(const Key('project-home')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('sidebar-account')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const Key('project-view-settings')), findsNothing);
      await tester.tap(find.byKey(const Key('sidebar-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-shell')), findsOneWidget);
      expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsNothing);
      expect(find.byKey(const Key('settings-category-menu')), findsNothing);
      expect(find.byKey(const Key('settings-section-picker')), findsNothing);
      expect(find.byKey(const Key('settings-navigation')), findsOneWidget);
      final navigation = tester.getRect(
        find.byKey(const Key('settings-navigation')),
      );
      final details = tester.getRect(find.byKey(const Key('settings-shell')));
      expect(navigation.left, 56);
      expect(navigation.width, 210);
      expect(details.left, navigation.right);
      await tester.ensureVisible(find.byKey(const Key('settings-team')));
      await tester.tap(find.byKey(const Key('settings-team')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-navigation')), findsOneWidget);
      expect(find.byKey(const Key('titlebar-sidebar-toggle')), findsNothing);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('settings-content-title')))
            .data,
        '참여자 관리',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
