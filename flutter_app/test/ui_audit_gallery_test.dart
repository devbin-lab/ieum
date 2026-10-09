import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/app_update.dart';
import 'package:ieum_flutter/app_release.dart';
import 'package:ieum_flutter/update_ui.dart';

import 'app_update_test.dart' show FakeUpdates;

import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/project_gate.dart';
import 'package:ieum_flutter/project_picker.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';

import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_oauth_test.dart' show MemoryVault;
import 'project_test.dart' show member;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('capture complete UI inventory without desktop control', (
    tester,
  ) async {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
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
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    final api = AutoMergeApi();
    final session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn(token: 'mock-only');
    final initial = await session.createProject(config, '호환 · 졸업작품', '김이음');
    final project = ProjectManifest.fromJson({
      ...initial.json,
      'roles': [
        const ProjectRole('role-design', '기획', {
          'task.create',
          'task.work',
          'task.review',
        }).json,
        const ProjectRole('role-art', '아트', {'task.work'}).json,
      ],
      'members': [
        initial.people.first.json,
        {...member(2, 'role-design').json, 'name': '이서연', 'login': 'seoyeon'},
        {
          ...member(3, 'role-art').json,
          'name': '박지훈',
          'login': 'jihoon',
          'parts': ['아트'],
        },
        {
          ...member(4, 'viewer').json,
          'name': '정유진',
          'login': 'yujin',
          'enabled': false,
        },
      ],
    });
    final remote = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      project.json,
      sha: remote!['sha'],
      message: 'mock gallery',
    );
    final raw =
        jsonDecode(
              File('assets/demo-snapshot.json').readAsStringSync(),
            )['tasks']
            as List;
    final seed = raw
        .map(
          (t) => {
            ...t as Map<String, dynamic>,
            'assigneeId': 'gh-2',
            'reviewerId': 'gh-1',
          },
        )
        .toList();
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
      seed: seed,
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', 'tester');
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    final updateDir = Directory.systemTemp.createTempSync(
      'ieum-gallery-update',
    );
    final updater = AppUpdater(
      root: updateDir,
      currentVersion: appVersion,
      source: FakeUpdates(),
    );
    addTearDown(() {
      updater.dispose();
      updateDir.deleteSync(recursive: true);
    });
    final boundary = GlobalKey();
    final phase = Platform.environment['IEUM_AUDIT_PHASE'] ?? 'before';
    Future<void> shot(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: name);
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../.local/ui-audit/$phase/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> tap(String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    Widget app() => RepaintBoundary(
      key: boundary,
      child: UpdateScope(
        updater: updater,
        restart: () async {},
        child: IeumApp(
          store: store,
          home: Workspace(
            store: store,
            sync: sync,
            session: session,
            projectSwitcherBuilder: (_) => ProjectPicker(
              projects: [
                SavedProject(
                  path: ':memory:',
                  name: project.name,
                  projectId: project.id,
                  config: config,
                ),
              ],
              activePath: ':memory:',
              onSelected: (_) {},
              onCreate: () {},
              onJoin: () {},
            ),
          ),
        ),
      ),
    );
    for (final width in [1440.0, 1080.0, 540.0]) {
      tester.view.physicalSize = Size(width, 940);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(Workspace));
      state.rememberView(() {
        state.page = 0;
        state.taskView = TaskView.list;
      });
      await shot('${width.toInt()}-tasks');
      await tap('new-task');
      await shot('${width.toInt()}-task-create');
      await tester.tap(find.byTooltip('작업 등록 닫기'));
      await tester.pumpAndSettle();
      for (final status in ['todo', 'review', 'done']) {
        state.details(store.tasks.firstWhere((t) => t.status == status));
        await shot('${width.toInt()}-task-$status');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
      }
      state.move(store.tasks.firstWhere((t) => t.status == 'review'), 'rework');
      await shot('${width.toInt()}-rework');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tap('view-kanban');
      await shot('${width.toInt()}-kanban');
      for (final section in SettingsSection.values) {
        state.selectSettings(section);
        await shot('${width.toInt()}-${section.name}');
        if (section == SettingsSection.team) {
          await tap('participant-gh-2');
          await shot('${width.toInt()}-member-detail');
          if (width < 1160) {
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await tester.pumpAndSettle();
          }
        }
        if (section == SettingsSection.team) {
          if (find
              .byKey(const Key('close-participant-detail'))
              .evaluate()
              .isNotEmpty) {
            await tap('close-participant-detail');
          }
          await tap('member-actions-gh-2');
          await tester.tap(find.text('역할 변경'));
          await tester.pumpAndSettle();
          await shot('${width.toInt()}-member-edit');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          if (find.byKey(const Key('team-invite')).evaluate().isNotEmpty) {
            await tap('team-invite');
          } else {
            await tester.tap(find.text('GitHub 협업자 초대'));
            await tester.pumpAndSettle();
          }
          await shot('${width.toInt()}-invite');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          if (find.byKey(const Key('team-more')).evaluate().isNotEmpty) {
            await tap('team-more');
            await tap('team-transfer');
          } else {
            await tester.tap(find.text('관리자 권한 이전'));
            await tester.pumpAndSettle();
          }
          await shot('${width.toInt()}-transfer');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
        if (section == SettingsSection.roles) {
          await tap('add-role');
          await shot('${width.toInt()}-role-create');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tap('select-role-role-design');
          await tap('delete-role-role-design');
          await shot('${width.toInt()}-role-delete');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
      }
      state.selectSettings(SettingsSection.projectGeneral);
      await tester.pumpAndSettle();
      await shot('${width.toInt()}-settings-sidebar');
      if (find.byKey(const Key('project-view-sidebar')).evaluate().isEmpty) {
        await tap('project-home');
        await tap('titlebar-sidebar-toggle');
      }
      await tap('project-picker');
      await shot('${width.toInt()}-project-dropdown');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await shot('${width.toInt()}-project-view-open');
      await tap('titlebar-sidebar-toggle');
      await shot('${width.toInt()}-project-view-closed');
      await tap('project-home');
      await tap('sidebar-notifications');
      await shot('${width.toInt()}-inbox');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tap('sidebar-account');
      await shot('${width.toInt()}-account-menu');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
    sync.dispose();
    store.dispose();
    session.signOut();
    final dir = Directory.systemTemp.createTempSync('ieum-gallery');
    final gateStore = TaskStore(':memory:');
    final gateSession = GitHubSession(
      api: AutoMergeApi(),
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    tester.view.physicalSize = const Size(1080, 940);
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: IeumApp(
          store: gateStore,
          home: ProjectGate(
            preferences: File('${dir.path}/prefs.json'),
            session: gateSession,
          ),
        ),
      ),
    );
    await shot('1080-login');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await gateSession.signIn(token: 'mock-only');
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: IeumApp(
          store: gateStore,
          home: ProjectGate(
            preferences: File('${dir.path}/prefs.json'),
            session: gateSession,
          ),
        ),
      ),
    );
    await shot('1080-project-create');
    await tester.tap(find.text('프로젝트 참여'));
    await tester.pumpAndSettle();
    await shot('1080-project-join');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    gateStore.dispose();
    dir.deleteSync(recursive: true);
    debugDisableShadows = true;
  }, skip: Platform.environment['IEUM_AUDIT_PHASE'] == null);
}
