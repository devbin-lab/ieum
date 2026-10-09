import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/app_theme.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/popup_ui.dart';
import 'package:ieum_flutter/project_shortcuts_view.dart';
import 'package:ieum_flutter/shortcut_site_icon.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_test_fixtures.dart';

void main() {
  final previewKey = GlobalKey();
  final preview = Platform.environment['IEUM_SHORTCUTS_PREVIEW_DIR'];
  Future<void> capture(WidgetTester tester, String name) async {
    if (preview == null) return;
    await tester.runAsync(() async {
      final boundary =
          previewKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final image = await boundary.toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        Directory(preview).createSync(recursive: true);
        File('$preview/$name.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  late TaskStore store;
  setUp(() {
    setAppLanguage('ko');
    store = TaskStore(
      ':memory:',
      project: personalReviewProject,
      identity: routeOwner,
    );
  });
  tearDown(() {
    store.dispose();
    setAppLanguage('ko');
  });

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> save(
    List<ProjectShortcut> next,
    List<ProjectShortcut>? expected,
  ) async {
    expect(
      jsonEncode(store.project!.shortcuts?.map((entry) => entry.json).toList()),
      jsonEncode(expected?.map((entry) => entry.json).toList()),
    );
    store.updateProject(
      ProjectManifest.fromJson({
        ...store.project!.json,
        'shortcuts': next.map((entry) => entry.json).toList(),
      }),
    );
  }

  void seedShortcuts([
    List<ProjectShortcut> entries = defaultProjectShortcuts,
  ]) {
    store.updateProject(
      ProjectManifest.fromJson({
        ...store.project!.json,
        'shortcuts': entries.map((entry) => entry.json).toList(),
      }),
    );
  }

  Widget view({
    SaveProjectShortcuts? onSave,
    Future<void> Function(String)? onOpen,
    Future<ShortcutSiteIconResult?> Function(String)? discoverIcon,
    bool dark = false,
  }) => RepaintBoundary(
    key: previewKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(
        const Color(0xff7963d5),
        dark ? Brightness.dark : Brightness.light,
        languageCode: appLanguage,
      ),
      home: Scaffold(
        body: ProjectShortcutsView(
          store: store,
          repository: 'team/data',
          onSave: onSave,
          onOpen: onOpen,
          discoverIcon: discoverIcon ?? (_) async => null,
        ),
      ),
    ),
  );

  testWidgets(
    'catalog browsing does not register tools; adding requires a team URL',
    (tester) async {
      await size(tester, const Size(1200, 900));
      final opened = <String>[];
      await tester.pumpWidget(
        view(onSave: save, onOpen: (url) async => opened.add(url)),
      );
      await tester.pumpAndSettle();
      expect(store.project!.shortcuts, isNull);
      expect(find.text('등록된 바로가기가 없습니다.'), findsOneWidget);
      expect(find.text('Google Drive'), findsNothing);
      expect(find.text('GitHub'), findsNothing);
      expect(
        find.byKey(const Key('shortcut-open-starter-github')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('shortcuts-browse-tools')));
      await tester.pumpAndSettle();
      for (final entry in defaultProjectShortcuts) {
        expect(
          find.byKey(Key('shortcut-catalog-${entry.service}')),
          findsOneWidget,
        );
      }
      expect(store.project!.shortcuts, isNull);
      expect(opened, isEmpty);
      expect(store.tasks, isEmpty);
      expect(store.changes, isEmpty);
      expect(store.db.select('SELECT * FROM github_queue'), isEmpty);

      await tester.tap(find.byKey(const Key('shortcut-catalog-add-github')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('shortcut-url')))
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('shortcut-name')))
            .controller!
            .text,
        'GitHub',
      );
      expect(store.project!.shortcuts, isNull);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shortcuts-registered-tab')));
      await tester.pumpAndSettle();
      expect(find.text('등록된 바로가기가 없습니다.'), findsOneWidget);
      expect(find.text('GitHub'), findsNothing);
      await tester.tap(find.byKey(const Key('shortcuts-catalog-tab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shortcut-catalog-add-notion')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('shortcut-url')))
            .controller!
            .text,
        isEmpty,
      );
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      expect(find.text('올바른 HTTPS 주소를 입력해 주세요.'), findsOneWidget);
      expect(store.project!.shortcuts, isNull);
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'team.notion.site/wiki',
      );
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      final saved = store.project!.shortcuts!.single;
      expect(saved.id, isNot('starter-notion'));
      expect(saved.name, 'Notion');
      expect(saved.service, 'notion');
      expect(saved.url, 'https://team.notion.site/wiki');
      expect(find.byKey(Key('shortcut-open-${saved.id}')), findsOneWidget);
      expect(find.byKey(const Key('shortcut-catalog-notion')), findsNothing);
      expect(store.tasks, isEmpty);
      expect(store.changes, isEmpty);
      expect(store.db.select('SELECT * FROM github_queue'), isEmpty);
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicitly registered links open directly and menus do not open destinations',
    (tester) async {
      await size(tester, const Size(1200, 840));
      seedShortcuts();
      if (preview != null) {
        await tester.runAsync(() async {
          for (final font in [
            ('Malgun Gothic', 'C:/Windows/Fonts/malgun.ttf'),
            (
              'MaterialIcons',
              'C:/Users/devbin0318/develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ]) {
            final loader = FontLoader(font.$1)
              ..addFont(
                Future.value(
                  ByteData.sublistView(File(font.$2).readAsBytesSync()),
                ),
              );
            await loader.load();
          }
        });
      }
      final opened = <String>[];
      await tester.pumpWidget(
        view(onSave: save, onOpen: (url) async => opened.add(url)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Google Drive'), findsOneWidget);
      await capture(tester, 'shortcuts');
      if (preview != null) {
        await tester.tap(find.byKey(const Key('shortcuts-catalog-tab')));
        await tester.pumpAndSettle();
        await capture(tester, 'shortcut-catalog');
        await tester.tap(find.byKey(const Key('shortcut-catalog-add-github')));
        await tester.pumpAndSettle();
        await capture(tester, 'shortcut-add');
        await tester.tap(find.text('취소'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shortcuts-registered-tab')));
        await tester.pumpAndSettle();
      }
      expect(find.text('Discord'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shortcut-menu-starter-drive')));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester.tap(find.text('수정'));
      await tester.pumpAndSettle();
      expect(find.text('바로가기 수정'), findsOneWidget);
      await capture(tester, 'shortcut-editor');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester.tap(find.byKey(const Key('shortcut-open-starter-github')));
      await tester.pumpAndSettle();
      expect(opened, ['https://github.com/']);
      expect(store.project!.shortcuts!.length, 8);
      expect(store.tasks, isEmpty);
      expect(store.changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('add, search, edit and delete affect only project links', (
    tester,
  ) async {
    await size(tester, const Size(1200, 840));
    await tester.pumpWidget(view(onSave: save));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcut-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shortcut-name')), '팀 위키');
    await tester.enterText(
      find.byKey(const Key('shortcut-url')),
      'team.notion.site/wiki',
    );
    await tester.enterText(
      find.byKey(const Key('shortcut-description')),
      '팀 문서',
    );
    await tester.tap(find.byKey(const Key('shortcut-save')));
    await tester.pumpAndSettle();
    final id = store.project!.shortcuts!
        .singleWhere((entry) => entry.name == '팀 위키')
        .id;
    expect(store.project!.shortcuts!.length, 1);
    await tester.enterText(find.byKey(const Key('shortcuts-search')), '팀 위키');
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(Key('shortcut-open-$id')),
        matching: find.text('팀 위키'),
      ),
      findsOneWidget,
    );
    expect(find.text('Google Drive'), findsNothing);
    await tester.tap(find.byKey(Key('shortcut-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shortcut-name')), '팀 위키 최신');
    await tester.enterText(
      find.byKey(const Key('shortcut-url')),
      'https://team.notion.site/updated',
    );
    await tester.tap(find.byKey(const Key('shortcut-save')));
    await tester.pumpAndSettle();
    expect(
      store.project!.shortcuts!.singleWhere((entry) => entry.id == id).url,
      'https://team.notion.site/updated',
    );
    await tester.tap(find.byKey(Key('shortcut-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcut-confirm-delete')));
    await tester.pumpAndSettle();
    expect(store.project!.shortcuts, isEmpty);
    expect(store.project!.shortcuts!.any((entry) => entry.id == id), isFalse);
    expect(store.tasks, isEmpty);
    expect(store.changes, isEmpty);
    expect(store.db.select('SELECT * FROM github_queue'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed saves retain the draft and do not duplicate on retry', (
    tester,
  ) async {
    await size(tester, const Size(900, 760));
    var attempts = 0;
    await tester.pumpWidget(
      view(
        onSave: (next, expected) async {
          if (++attempts == 1) {
            throw const GitHubFailure('바로가기를 저장하지 못했습니다. 다시 시도해 주세요.');
          }
          await save(next, expected);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcuts-catalog-tab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcut-catalog-add-notion')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shortcut-name')), '공유 문서');
    await tester.enterText(
      find.byKey(const Key('shortcut-url')),
      'team.notion.site/retry',
    );
    await tester.tap(find.byKey(const Key('shortcut-save')));
    await tester.pumpAndSettle();
    expect(find.text('바로가기를 저장하지 못했습니다. 다시 시도해 주세요.'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const Key('shortcut-name')))
          .controller!
          .text,
      '공유 문서',
    );
    expect(store.project!.shortcuts, isNull);
    await tester.tap(find.byKey(const Key('shortcut-save')));
    await tester.pumpAndSettle();
    expect(
      store.project!.shortcuts!.where((entry) => entry.name == '공유 문서').length,
      1,
    );
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'small dark English views and editor fit; read-only viewers cannot edit',
    (tester) async {
      setAppLanguage('en');
      await size(tester, const Size(320, 540));
      await tester.pumpWidget(view(onSave: save, dark: true));
      await tester.pumpAndSettle();
      expect(find.text('Shortcuts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shortcut-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcut-url')), findsOneWidget);
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a shortcut name.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      seedShortcuts();
      await tester.pumpWidget(view(dark: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shortcut-add')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('shortcut-menu-starter-drive')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shortcut-menu-starter-drive')));
      await tester.pumpAndSettle();
      expect(find.text('Copy link'), findsOneWidget);
      expect(find.text('Edit shortcut'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'favorites and filters persist locally without changing team links',
    (tester) async {
      await size(tester, const Size(1200, 840));
      seedShortcuts();
      final sharedBefore = jsonEncode(
        store.project!.shortcuts!.map((entry) => entry.json).toList(),
      );
      final opened = <String>[];
      await tester.pumpWidget(
        view(onSave: save, onOpen: (url) async => opened.add(url)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('shortcut-favorite-starter-discord')),
      );
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(
        jsonEncode(
          store.project!.shortcuts!.map((entry) => entry.json).toList(),
        ),
        sharedBefore,
      );
      expect(store.changes, isEmpty);
      expect(store.db.select('SELECT * FROM github_queue'), isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(view(onSave: save));
      await tester.pumpAndSettle();
      expect(find.text('즐겨찾기'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('shortcut-favorite-starter-discord')),
            )
            .isSelected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('shortcuts-service-filter')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('option-figma')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('option-figma')));
      await tester.pumpAndSettle();
      expect(find.text('Discord'), findsNothing);
      expect(
        find.byKey(const Key('shortcut-open-starter-figma')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('shortcuts-search')),
        'no matches',
      );
      await tester.pumpAndSettle();
      expect(find.text('선택한 필터에 해당하는 바로가기가 없습니다.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(view(onSave: save));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IeumSelect>(
              find.byKey(const Key('shortcuts-service-filter')),
            )
            .value,
        'figma',
      );
      expect(
        find.byKey(const Key('shortcut-open-starter-figma')),
        findsOneWidget,
      );
      expect(
        jsonEncode(
          store.project!.shortcuts!.map((entry) => entry.json).toList(),
        ),
        sharedBefore,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'team address setup detects services and preserves authored names',
    (tester) async {
      await size(tester, const Size(1200, 840));
      seedShortcuts();
      final opened = <String>[];
      await tester.pumpWidget(
        view(onSave: save, onOpen: (url) async => opened.add(url)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shortcut-menu-starter-drive')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('수정'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await tester.enterText(find.byKey(const Key('shortcut-name')), '공유 문서');
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'docs.google.com/document/d/team/edit',
      );
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      final saved = store.project!.shortcuts!.singleWhere(
        (entry) => entry.id == 'starter-drive',
      );
      expect(saved.name, '공유 문서');
      expect(saved.service, 'drive');
      expect(saved.url, 'https://docs.google.com/document/d/team/edit');
      expect(store.project!.shortcuts!.length, 8);
      await tester.tap(find.byKey(const Key('shortcut-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'discord.gg/team',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('shortcut-name')))
            .controller!
            .text,
        'Discord',
      );
      await tester.enterText(find.byKey(const Key('shortcut-name')), '회의실');
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'app.slack.com/client/team/channel',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('shortcut-name')))
            .controller!
            .text,
        '회의실',
      );
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      expect(
        store.project!.shortcuts!
            .singleWhere((entry) => entry.name == '회의실')
            .service,
        'slack',
      );
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shortcut tab preserves the project sidebar and saved navigation',
    (tester) async {
      await size(tester, const Size(1280, 840));
      Widget workspace() => MaterialApp(
        home: Scaffold(
          body: Workspace(store: store, projectSwitcher: const Text('프로젝트 선택')),
        ),
      );
      await tester.pumpWidget(workspace());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-view-tab-shortcuts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('project-shortcuts-page')), findsOneWidget);
      expect(find.byKey(const Key('project-view-sidebar')), findsOneWidget);
      expect(jsonDecode(store.meta('ui.workspace'))['page'], 8);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(workspace());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('project-shortcuts-page')), findsOneWidget);
      expect(find.byKey(const Key('project-view-sidebar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
