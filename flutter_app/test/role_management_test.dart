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

  test('project starts without automatically created job roles; manual PD and PM differ', () async {
    expect(project.roles, isEmpty);
    expect(roleLabels['manager'], '관리자');
    project = await session.saveRole(
      config,
      const ProjectRole('role-pd', 'PD', {'task.reviewAll'}),
    );
    project = await session.saveRole(
      config,
      const ProjectRole('role-pm', 'PM', {'task.create', 'task.assign'}),
    );
    expect(project.roles.map((r) => r.name), ['PD', 'PM']);
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
  });

  test('pre-existing custom administrator name remains loadable after system label change', () {
    final old = ProjectManifest(
      project.id,
      project.name,
      project.ownerId,
      project.people,
      roles: [
        const ProjectRole('role-old-admin', '관리자', {'task.review'}),
      ],
    );
    expect(ProjectManifest.fromJson(old.json).roles.single.name, '관리자');
  });

  test('delete used role atomically reassigns active and inactive members retaining identity and status', () async {
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
        roles: [sourceRole, targetRole],
      ),
    );
    final writes = api.writes;
    final result = await session.deleteRole(
      config,
      sourceRole.id,
      replacementRoleId: targetRole.id,
    );
    expect(api.writes, writes + 1);
    expect(result.roles.single.id, targetRole.id);
    final moved = result.people.firstWhere((p) => p.id == 'gh-2');
    expect(moved.role, targetRole.id);
    expect(moved.enabled, isFalse);
    expect(moved.name, inactive.name);
    expect(moved.login, inactive.login);
    expect(moved.parts, inactive.parts);
    expect(result.people.firstWhere((p) => p.id == 'gh-3').canWork, isTrue);
  });

  test('delete rejects missing target, deleted target and self target, and requires membership authority', () async {
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
        roles: [sourceRole, targetRole, designer],
      ),
    );
    for (final id in [null, sourceRole.id, 'role-missing', 'owner']) {
      await expectLater(
        session.deleteRole(config, sourceRole.id, replacementRoleId: id),
        throwsA(isA<GitHubFailure>()),
      );
    }
    api.identityId = 3;
    await session.signIn();
    final writes = api.writes;
    await expectLater(
      session.deleteRole(
        config,
        sourceRole.id,
        replacementRoleId: targetRole.id,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    // Unassigned roles still need only role management permission.
    final deleted = await session.deleteRole(config, targetRole.id);
    expect(deleted.roles.any((r) => r.id == targetRole.id), isFalse);
  });

  test('pending task PR blocks rights loss; equivalent replacement preserves workflow', () async {
    await write(
      ProjectManifest(
        project.id,
        project.name,
        project.ownerId,
        [project.people.first, member(2, sourceRole.id)],
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
      session.deleteRole(config, sourceRole.id, replacementRoleId: 'viewer'),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    final result = await session.deleteRole(
      config,
      sourceRole.id,
      replacementRoleId: targetRole.id,
    );
    expect(result.people.last.role, targetRole.id);
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
        roles: [sourceRole, targetRole],
      ),
    );
    racing.race = true;
    final result = await session.deleteRole(
      config,
      sourceRole.id,
      replacementRoleId: targetRole.id,
    );
    expect(result.name, '동시에 바뀐 프로젝트 이름');
    expect(result.people.last.role, targetRole.id);
    expect((await session.loadProject(config)).roles.single.id, targetRole.id);
  });

  testWidgets(
    'responsive role management shows groups, members and explicit reassignment on deletion',
    (tester) async {
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
          find.byKey(
            Key(size.width >= 680 ? 'roles-columns' : 'roles-stacked'),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.ensureVisible(find.byKey(const Key('role-members-tab')));
      await tester.tap(find.byKey(const Key('role-members-tab')));
      await tester.pumpAndSettle();
      expect(find.textContaining('비활성화'), findsWidgets);
      await tester.ensureVisible(find.byKey(const Key('delete-role-role-pd')));
      await tester.tap(find.byKey(const Key('delete-role-role-pd')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('confirm-delete-role')))
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const Key('delete-role-replacement')),
      );
      await tester.tap(find.byKey(const Key('delete-role-replacement')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('option-role-pm')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-role')));
      await tester.pumpAndSettle();
      expect(store.project!.roles.single.name, 'PM');
      expect(store.people.last.role, pm.id);
      expect(store.people.last.enabled, isFalse);
      expect(tester.takeException(), isNull);
      expect(SettingsSection.team.title, '참여자 관리');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

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
}
