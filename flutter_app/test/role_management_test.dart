import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/roles_panel.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi;
import 'github_oauth_test.dart' show MemoryVault;
import 'project_test.dart' show member;
import 'roles_profile_test.dart' show RacingApi;

const config = GitHubConfig(repository: 'team/data', enabled: true);
const sourceRole = ProjectRole('role-design', '기획', {
  'task.work',
  'task.review',
});
const targetRole = ProjectRole('role-next', '기획 검토', {
  'task.work',
  'task.review',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeGitHubApi api;
  late GitHubSession session;
  late ProjectManifest project;
  Future<void> write(ProjectManifest value) async {
    final file = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      value.json,
      sha: file!['sha'],
      message: 'fixture',
    );
    project = value;
  }

  Future<void> start(FakeGitHubApi value) async {
    api = value;
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
    project = await session.createProject(config, '역할 관리', '개설자');
  }

  setUp(() => start(FakeGitHubApi()));
  tearDown(() => session.signOut());

  test(
    'project starts without parts and manually created PD and PM are name-only',
    () async {
      expect(project.roles, isEmpty);
      expect(roleLabels['owner'], '관리자');
      expect(roleLabels['manager'], '운영자');
      expect(project.people.first.permissions, permissionLabels.keys.toSet());
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-pd', 'PD', {'task.reviewAll'}),
      );
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-pm', 'PM', {'task.create', 'task.assign'}),
      );
      expect(project.roles.map((r) => r.name), ['PD', 'PM']);
      expect(project.roles.every((r) => r.permissions.isEmpty), isTrue);
      expect(
        Person(
          '',
          '',
          '',
          'role-pd',
          0,
        ).resolved(project.roles).has('task.create'),
        isFalse,
      );
      expect(
        Person(
          '',
          '',
          '',
          'role-pm',
          0,
        ).resolved(project.roles).has('task.reviewAll'),
        isFalse,
      );
    },
  );

  test('pre-existing custom administrator name remains loadable after system label change', () {
    final old = ProjectManifest(
      project.id,
      project.name,
      project.ownerId,
      project.people,
      parts: const ['기획'],
      roles: [
        const ProjectRole('role-old-admin', '관리자', {'task.review'}),
      ],
    );
    expect(ProjectManifest.fromJson(old.json).roles.single.name, '관리자');
  });

  test('delete used part atomically clears active and inactive memberships while retaining identity and status', () async {
    final inactive = Person.fromJson({
      ...member(2, sourceRole.id).json,
      'enabled': false,
    });
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, inactive, member(3, sourceRole.id)],
        parts: const ['기획'],
        roles: [sourceRole, targetRole],
      ),
    );
    final writes = api.writes;
    final result = await session.deletePermissionPart(config, sourceRole.id);
    expect(api.writes, writes + 1);
    expect(result.roles.single.id, targetRole.id);
    final moved = result.people.firstWhere((p) => p.id == 'gh-2');
    expect(moved.role, 'unassigned');
    expect(moved.enabled, isFalse);
    expect(moved.name, inactive.name);
    expect(moved.login, inactive.login);
    expect(moved.parts, isEmpty);
    expect(result.people.firstWhere((p) => p.id == 'gh-3').canWork, isTrue);
  });

  test('deletion rejects missing parts and administrator, and legacy grants cannot delegate management', () async {
    const designer = ProjectRole('role-designer', '역할 설계자', {
      'role.manage',
      'task.work',
      'task.review',
    });
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [
          project.people.first,
          member(2, sourceRole.id),
          member(3, designer.id),
        ],
        parts: const ['기획'],
        roles: [sourceRole, targetRole, designer],
      ),
    );
    for (final id in ['role-missing', 'owner']) {
      await expectLater(
        session.deletePermissionPart(config, id),
        throwsA(isA<GitHubFailure>()),
      );
    }
    api.identityId = 3;
    await session.signIn();
    final writes = api.writes;
    await expectLater(
      session.deletePermissionPart(config, sourceRole.id),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    await expectLater(
      session.deletePermissionPart(config, targetRole.id),
      throwsA(isA<GitHubFailure>()),
    );
    api.identityId = 1;
    await session.signIn();
    await expectLater(
      session.deleteRole(config, sourceRole.id),
      throwsA(isA<GitHubFailure>()),
    );
    final deleted = await session.deletePermissionPart(config, targetRole.id);
    expect(deleted.roles.any((r) => r.id == targetRole.id), isFalse);
  });

  test('pending task PR blocks member deactivation while name-only part removal preserves participation', () async {
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, sourceRole.id)],
        parts: const ['기획'],
        roles: [sourceRole, targetRole],
      ),
    );
    api.prs.add({
      'number': 1,
      'state': 'open',
      'base': {'ref': 'main'},
      'head': {'ref': 'ieum/tasks/guest/TASK-1'},
      'user': {'id': 2},
    });
    final writes = api.writes;
    await expectLater(
      session.setMemberEnabled(config, 'gh-2', false),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    final result = await session.deletePermissionPart(config, sourceRole.id);
    expect(result.people.last.role, 'unassigned');
    expect(result.people.last.active, isTrue);
    expect(api.prs.single['state'], 'open');
  });

  test('concurrent manifest update retries role deletion while preserving project edits', () async {
    session.signOut();
    final racing = RacingApi();
    await start(racing);
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, sourceRole.id)],
        parts: const ['기획'],
        roles: [sourceRole, targetRole],
      ),
    );
    racing.race = true;
    final result = await session.deletePermissionPart(config, sourceRole.id);
    expect(result.name, '동시에 바뀐 프로젝트 이름');
    expect(result.people.last.role, 'unassigned');
    expect((await session.loadProject(config)).roles.single.id, targetRole.id);
  });

  testWidgets('responsive part sheet removes deleted part membership', (
    tester,
  ) async {
    const pd = ProjectRole('role-pd', 'PD', {'task.reviewAll'});
    const pm = ProjectRole('role-pm', 'PM', {'task.create', 'task.assign'});
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [
          project.people.first,
          Person.fromJson({...member(2, pd.id).json, 'enabled': false}),
        ],
        parts: const ['기획'],
        roles: [pd, pm],
      ),
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    for (final size in [
      const Size(1080, 960),
      const Size(560, 960),
      const Size(360, 640),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: RolesPanel(store: store, sync: sync, session: session),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key(size.width >= 680 ? 'roles-columns' : 'roles-stacked')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }
    expect(find.byKey(const Key('role-members-title')), findsOneWidget);
    expect(find.byKey(const Key('role-permissions-tab')), findsNothing);
    expect(find.textContaining('비활성화'), findsWidgets);
    await tester.ensureVisible(find.byKey(const Key('delete-role-role-pd')));
    await tester.tap(find.byKey(const Key('delete-role-role-pd')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('delete-role-replacement')), findsNothing);
    await tester.tap(find.byKey(const Key('confirm-delete-role')));
    await tester.pumpAndSettle();
    expect(store.project!.roles.any((r) => r.name == 'PM'), isTrue);
    expect(store.project!.roles.any((r) => r.id == pd.id), isFalse);
    expect(store.people.last.role, 'unassigned');
    expect(store.people.last.enabled, isFalse);
    expect(tester.takeException(), isNull);
    expect(SettingsSection.team.title, '참여자 관리');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('headless settings role preview fits portrait half screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    if (Platform.environment['IEUM_CAPTURE_ROLES_UI'] == '1') {
      final font = FontLoader('PreviewKorean');
      font.addFont(
        Future.value(
          ByteData.sublistView(
            File(r'C:\Windows\Fonts\malgun.ttf').readAsBytesSync(),
          ),
        ),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(
        Future.value(
          ByteData.sublistView(
            File(
              r'C:\Users\devbin0318\develop\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
            ).readAsBytesSync(),
          ),
        ),
      );
      await icons.load();
    }
    const pd = ProjectRole('role-pd', 'PD', {'task.reviewAll'});
    const pm = ProjectRole('role-pm', 'PM', {'task.create', 'task.assign'});
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, pd.id)],
        parts: const ['기획'],
        roles: [pd, pm],
      ),
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'PreviewKorean',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff7963d5)),
        ),
        home: RepaintBoundary(
          key: boundary,
          child: SettingsShell(
            selected: SettingsSection.roles,
            onSelected: (_) {},
            contentBuilder: (_) =>
                RolesPanel(store: store, sync: sync, session: session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (Platform.environment['IEUM_CAPTURE_ROLES_UI'] == '1') {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(r'D:\GitHub\ieum\.local\roles-settings-preview.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'compact part sheet keeps name CRUD controls visible and persists each operation',
    (tester) async {
      tester.view.physicalSize = const Size(560, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      addTearDown(() {
        sync.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: RolesPanel(store: store, sync: sync, session: session),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('add-role')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), '검토 담당');
      expect(find.byKey(const Key('role-preset-검토 권한')), findsNothing);
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final role = store.project!.roles.single;
      expect(role.name, '검토 담당');
      expect(role.permissions, isEmpty);
      expect(find.byKey(Key('edit-role-${role.id}')), findsOneWidget);
      expect(find.byKey(Key('delete-role-${role.id}')), findsOneWidget);
      expect(find.byKey(const Key('compact-role-select')), findsNothing);
      await tester.ensureVisible(find.byKey(Key('edit-role-${role.id}')));
      await tester.tap(find.byKey(Key('edit-role-${role.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), '작업 담당');
      expect(find.byKey(const Key('role-clear-permissions')), findsNothing);
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(store.project!.roles.single.id, role.id);
      expect(store.project!.roles.single.name, '작업 담당');
      expect(store.project!.roles.single.permissions, isEmpty);
      await tester.ensureVisible(find.byKey(Key('delete-role-${role.id}')));
      await tester.tap(find.byKey(Key('delete-role-${role.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-role')));
      await tester.pumpAndSettle();
      expect(store.project!.roles, isEmpty);
      expect((await session.loadProject(config)).roles, isEmpty);
      expect(store.people.single.role, 'owner');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('administrator is fixed and cannot be copied into a part', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(560, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RolesPanel(store: store, sync: sync, session: session),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('system-roles')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('select-role-owner')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('copy-system-role-owner')), findsNothing);
    expect(find.byKey(const Key('permission-search')), findsNothing);
    expect(store.project!.roles, isEmpty);
    expect(store.people.single.role, 'owner');
    expect(find.byKey(const Key('delete-role-owner')), findsNothing);
    expect(find.textContaining('잘못 전달된 작업을 회수'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('member without role management sees disabled custom mutations', (
    tester,
  ) async {
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, 'viewer')],
        parts: const ['기획'],
        roles: [sourceRole],
      ),
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: member(2, 'viewer'),
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RolesPanel(store: store, sync: sync, session: session),
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('add-role')), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(Key('edit-role-${sourceRole.id}')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(Key('delete-role-${sourceRole.id}')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
