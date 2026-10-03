import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/project_picker.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'project menu, offline notice and restored kanban fit minimum window',
    (tester) async {
      final seed =
          jsonDecode(
                File('assets/demo-snapshot.json').readAsStringSync(),
              )['tasks']
              as List;
      final store = TaskStore(':memory:', seed: seed);
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(1160, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      if (Platform.environment['IEUM_CAPTURE_UI'] == '1') {
        for (final family in ['Malgun Gothic', 'Roboto']) {
          final font = FontLoader(family)
            ..addFont(
              Future.value(
                ByteData.sublistView(
                  File('C:/Windows/Fonts/malgun.ttf').readAsBytesSync(),
                ),
              ),
            );
          await tester.runAsync(font.load);
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  'build/windows/x64/runner/Release/data/flutter_assets/fonts/MaterialIcons-Regular.otf',
                ).readAsBytesSync(),
              ),
            ),
          );
        await tester.runAsync(icons.load);
      }
      final projects = [
        SavedProject(
          path: 'a.sqlite',
          name: '호환 · 졸업작품',
          projectId: 'a',
          config: const GitHubConfig(repository: 'team/hwan'),
        ),
        SavedProject(
          path: 'b.sqlite',
          name: '이음 서비스',
          projectId: 'b',
          config: const GitHubConfig(repository: 'team/ieum'),
        ),
      ];
      var selected = '', created = false;
      final boundary = GlobalKey();
      Future<void> capture(String name) async {
        if (Platform.environment['IEUM_CAPTURE_UI'] != '1') return;
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../.local/qa/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      Widget app({bool offline = true}) => RepaintBoundary(
        key: boundary,
        child: IeumApp(
          store: store,
          home: Workspace(
            store: store,
            sessionNotice: offline
                ? '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 계정을 다시 확인하고 변경을 전송합니다.'
                : null,
            projectSwitcherBuilder: (onSettings) => ProjectPicker(
              onSettings: onSettings,
              projects: projects,
              activePath: 'a.sqlite',
              onSelected: (p) => selected = p.projectId,
              onCreate: () => created = true,
              onJoin: () {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('이음'), findsNothing);
      expect(find.text('IEUM'), findsNothing);
      expect(find.text('팀의 작업을 잇다'), findsNothing);
      final picker = tester.getRect(find.byKey(const Key('project-home')));
      final bell = tester.getRect(
        find.byKey(const Key('sidebar-notifications')),
      );
      final titlebar = tester.getRect(find.byKey(const Key('window-titlebar')));
      expect(bell.top, greaterThan(picker.bottom));
      expect(bell.center.dx, closeTo(picker.center.dx, 1));
      expect(
        tester.getSize(find.byKey(const Key('workspace-sidebar'))).width,
        64,
      );
      expect(picker.top - titlebar.bottom, lessThan(20));
      expect(
        tester.getRect(find.byKey(const Key('nav-0'))).top - picker.bottom,
        lessThan(20),
      );
      expect(find.byKey(const Key('nav-1')), findsNothing);
      expect(find.byKey(const Key('nav-2')), findsNothing);
      expect(find.text('프로젝트 설정'), findsNothing);
      expect(find.text('내 변경내역'), findsNothing);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const Key('sidebar-account'))) +
            const Offset(18, 18),
      );
      await tester.pumpAndSettle();
      final account = tester.getRect(find.byKey(const Key('sidebar-account')));
      final summary = tester.getRect(
        find.byKey(const Key('account-menu-summary')),
      );
      final settings = tester.getRect(
        find.byKey(const Key('account-settings')),
      );
      expect(summary.top, greaterThanOrEqualTo(titlebar.bottom));
      expect(settings.bottom, lessThanOrEqualTo(account.top));
      await capture('account-menu');
      // Clicking outside dismisses the menu without changing the current view.
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-settings')), findsNothing);
      expect(find.byKey(const Key('task-list')), findsOneWidget);
      await tester.tapAt(
        tester.getTopLeft(find.byKey(const Key('sidebar-account'))) +
            const Offset(18, 18),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('account-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-shell')), findsOneWidget);
      expect(find.byKey(const Key('new-task')), findsNothing);
      final navigation = tester.getRect(
        find.byKey(const Key('settings-navigation')),
      );
      final content = tester.getRect(
        find.byKey(const Key('settings-content-scroll')),
      );
      expect(content.left, navigation.right);
      await capture('settings-general');
      await tester.tap(find.byKey(const Key('sidebar-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-settings')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('settings-search')), '배정');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-team')), findsNothing);
      await tester.tap(find.byKey(const Key('settings-assignments')));
      await tester.pumpAndSettle();
      expect(find.text('담당 파트'), findsOneWidget);
      await capture('settings-assignments');
      await tester.enterText(find.byKey(const Key('settings-search')), '없는설정');
      await tester.pumpAndSettle();
      expect(find.text('검색 결과가 없습니다.'), findsOneWidget);
      await tester.tap(find.byTooltip('검색 지우기'));
      await tester.pumpAndSettle();
      for (final section in ['team', 'github', 'notifications']) {
        await tester.tap(find.byKey(Key('settings-$section')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const Key('settings-changes')));
      await tester.pumpAndSettle();
      expect(find.text('개인 브랜치 · PR'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-shell')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      await capture('sidebar-cleanup-offline-list');
      if (Platform.environment['IEUM_CAPTURE_UI'] == '1') {
        await tester.pumpWidget(app(offline: false));
        await tester.pumpAndSettle();
        await capture('sidebar-cleanup-list');
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('sidebar-notifications')));
      await tester.pumpAndSettle();
      expect(find.text('알림 미리보기'), findsOneWidget);
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-kanban')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-IE-101')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await capture('sidebar-cleanup-kanban');
      if (find.byKey(const Key('project-picker')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('sidebar-account')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('project-settings')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      expect(find.text('새 프로젝트 만들기'), findsOneWidget);
      expect(find.text('프로젝트 참여하기'), findsOneWidget);
      await capture('sidebar-cleanup-project-menu');
      await tester.tap(find.byKey(const ValueKey('project-option-b.sqlite')));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      if (find.byKey(const Key('project-picker')).evaluate().isEmpty) {
        await tester.tap(find.byKey(const Key('sidebar-account')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('project-settings')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-create-menu')));
      await tester.pumpAndSettle();
      expect(created, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
