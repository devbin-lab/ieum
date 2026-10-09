import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_oauth_test.dart' show MemoryVault;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('all active tabs fit, retain chrome and preserve project data', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
    final preview = Platform.environment['IEUM_UI_PREVIEW_DIR'];
    if (preview != null) {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      for (final font in [
        ('Malgun Gothic', 'C:/Windows/Fonts/malgun.ttf'),
        ('Roboto', 'C:/Windows/Fonts/malgun.ttf'),
        ('Ahem', 'C:/Windows/Fonts/malgun.ttf'),
        (
          'MaterialIcons',
          'C:/Users/devbin0318/develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      ]) {
        final loader = FontLoader(font.$1)
          ..addFont(
            Future.value(ByteData.sublistView(File(font.$2).readAsBytesSync())),
          );
        await tester.runAsync(loader.load);
      }
    }
    const config = GitHubConfig(repository: 'team/data', enabled: false);
    final api = AutoMergeApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn(token: 'mock-only');
    final initial = await session.createProject(config, '프로젝트 작업 공간', '개설자');
    final project = ProjectManifest.fromJson({
      ...initial.json,
      'roles': [
        const ProjectRole('role-plan', '기획', {}).json,
        const ProjectRole('role-pd', 'PD', {}).json,
      ],
      'parts': ['기획', 'PD'],
      'unifiedParts': true,
    });
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
      seed: [
        for (final status in boardStatuses.keys)
          {
            'id': 'preview-$status',
            'title': status == 'doing' ? '기획서 초안 작성' : '프로젝트 작업 $status',
            'part': '기획',
            'priority': 'normal',
            'assigneeId': project.people.first.id,
            'reviewerId': project.people.first.id,
            'status': status,
            'assignedDate': '2026-10-08',
            'dueDate': '2026-10-12',
            'completedDate': status == 'done' ? '2026-10-12' : '',
            'description': '작업 내용과 완료 기준을 확인합니다.',
            'reworkReason': '',
            'version': 1,
            'updatedAt': '2026-10-08T00:00:00Z',
          },
      ],
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'tester');
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    final snapshot = jsonEncode(store.tasks.map((t) => t.data).toList());
    final boundary = GlobalKey();

    Future<void> check(String name, {bool capture = true}) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      final rail = tester.widget<Container>(
        find.byKey(const Key('workspace-sidebar')),
      );
      expect((rail.decoration as BoxDecoration).color, const Color(0xffe6e8e7));
      expect(
        tester
            .widget<Container>(find.byKey(const Key('window-titlebar')))
            .color,
        const Color(0xffe6e8e7),
      );
      final main = tester.widget<Material>(
        find.byKey(const Key('workspace-main-surface')),
      );
      expect(
        (main.shape as RoundedRectangleBorder).borderRadius,
        const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
        ),
      );
      if (preview != null && capture) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$preview/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }

    for (final size in [
      const Size(1440, 920),
      const Size(1080, 760),
      const Size(540, 720),
      const Size(480, 420),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: IeumApp(
            store: store,
            sync: sync,
            session: session,
            home: Workspace(
              store: store,
              sync: sync,
              session: session,
              projectSwitcher: Text(project.name),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      final width = size.width.toInt().toString();
      if (state.projectViewOpen != (size.width >= 1000)) {
        state.toggleProjectView();
        await tester.pumpAndSettle();
      }
      state.rememberView(() {
        state.page = 6;
        state.taskView = TaskView.kanban;
      });
      await check('$width-tasks-board');
      state.rememberView(() => state.taskView = TaskView.list);
      await check('$width-tasks-list');
      state.rememberView(() => state.page = 0);
      await check('$width-schedule');
      state.rememberView(() => state.page = 5);
      await check('$width-connections');
      state.notifications();
      await check('$width-inbox');
      for (final section in SettingsSection.values.where(
        (s) =>
            s != SettingsSection.assignments && s != SettingsSection.workflow,
      )) {
        state.selectSettings(section);
        await check('$width-settings-${section.name}');
      }
      state.rememberView(() {
        state.page = 6;
        state.taskView = TaskView.kanban;
      });
      await tester.pumpAndSettle();
      state.details(store.find('preview-doing'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$width-detail');
      if (preview != null) {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$preview/$width-detail.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byTooltip('작업 상세 닫기'));
      await tester.pumpAndSettle();
    }
    expect(jsonEncode(store.tasks.map((t) => t.data).toList()), snapshot);
    expect(store.changes, isEmpty);
    debugDisableShadows = true;
  });
}
