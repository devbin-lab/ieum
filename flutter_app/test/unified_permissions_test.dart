import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/roles_panel.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/team_panel.dart';
import 'package:ieum_flutter/workflow_sheet_handoff.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'project_test.dart' show member;

const config = GitHubConfig(repository: 'team/data', enabled: true);
const planning = ProjectRole('role-plan', '기획', {'task.create', 'task.work'});
const review = ProjectRole('role-pd', 'PD', {'task.review'});
const participantPermissions = defaultTaskPermissions;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeGitHubApi api;
  late GitHubSession session;
  late ProjectManifest project;
  setUp(() async {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
    project = await session.createProject(config, '통합 권한', '관리자');
  });
  tearDown(() => session.signOut());

  Future<void> write(Map<String, dynamic> data) async {
    final file = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      data,
      sha: file!['sha'],
      message: 'Fixture',
    );
    project = await session.loadProject(config);
  }

  Map<String, dynamic> legacyJson() => {...project.json}
    ..remove('workflowSheet')
    ..remove('partsUnified');

  test('one saved part defines the task catalogue and ignores historical fine grants', () async {
    final before = api.writes;
    project = await session.savePermissionPart(config, planning);
    expect(api.writes, before + 1);
    expect(project.unifiedParts, isTrue);
    expect(project.parts, ['기획']);
    expect(project.roles.single.permissions, isEmpty);
    expect(project.roles.single.id, planning.id);
    final loaded = await session.loadProject(config);
    expect(loaded.parts, ['기획']);
    expect(sheetHandoffGroups(loaded.roles, loaded.parts), {
      '': '모든 작업자',
      'part:role-plan': '파트 · 기획',
      'role:owner': '관리자',
    });
    for (final oldCall in [
      () => session.saveParts(config, []),
      () => session.saveRole(config, review),
      () => session.deleteRole(config, planning.id),
    ]) {
      await expectLater(oldCall(), throwsA(isA<GitHubFailure>()));
    }
    expect((await session.loadProject(config)).parts, ['기획']);
  });

  test('legacy catalogues preserve custom part identity, membership and inactive status', () async {
    await write({
      ...legacyJson(),
      'roles': [review.json],
      'parts': ['아트'],
      'members': [
        ...project.people.map((p) => p.json),
        {
          ...member(2, review.id).json,
          'parts': ['아트'],
          'enabled': false,
        },
        {
          ...member(3, 'worker').json,
          'parts': ['아트'],
        },
      ],
    });
    final first = project.partWorkflowView, second = project.partWorkflowView;
    expect(first.roles.map((r) => r.id), second.roles.map((r) => r.id));
    expect(first.parts, containsAll(['아트', 'PD']));
    expect(first.parts, isNot(contains('작업자')));
    expect(first.roles.first.id, review.id);
    expect(first.roles.every((r) => r.permissions.isEmpty), isTrue);
    expect(first.people[1].parts, containsAll(['아트', 'PD']));
    expect(first.people[1].has('task.review'), isFalse);
    expect(first.people[1].enabled, isFalse);
    expect(first.people[2].permissions, participantPermissions);
    project = await session.savePermissionPart(config, planning);
    expect(project.parts, containsAll(['아트', 'PD', '기획']));
    expect(project.people[1].role, 'unassigned');
    expect(project.people[1].enabled, isFalse);
    expect(project.people[2].canWork, isTrue);
    expect(project.people.first.permissions, permissionLabels.keys.toSet());
  });

  test('legacy builtin label collisions preserve part IDs without synthesizing permission parts', () async {
    const sameName = ProjectRole('role-same-name', '작업자', {'task.review'});
    await write({
      ...legacyJson(),
      'roles': [sameName.json, review.json],
      'parts': ['작업자', 'pd'],
      'members': [
        ...project.people.map((p) => p.json),
        member(2, 'worker').json,
        {
          ...member(3, 'unassigned').json,
          'parts': ['작업자', 'pd'],
        },
        member(4, sameName.id).json,
      ],
    });
    final unified = project.partWorkflowView;
    final worker = unified.people.firstWhere((p) => p.id == 'gh-2');
    final assigned = unified.people.firstWhere((p) => p.id == 'gh-3');
    expect(worker.parts, isEmpty);
    expect(worker.permissions, participantPermissions);
    expect(assigned.parts, ['작업자', 'PD']);
    expect(assigned.permissions, participantPermissions);
    expect(unified.people.last.parts, ['작업자']);
    expect(
      unified.roles.map((r) => r.id),
      containsAll([sameName.id, review.id]),
    );
    expect(unified.roles.every((r) => r.permissions.isEmpty), isTrue);
    expect(unified.parts, isNot(contains('작업자 (기존 권한)')));
    project = await session.savePermissionPart(config, planning);
    expect(
      project.people.firstWhere((p) => p.id == 'gh-2').permissions,
      participantPermissions,
    );
    expect(project.people.firstWhere((p) => p.id == 'gh-3').parts, [
      '작업자',
      'PD',
    ]);
  });

  test('deleting one assigned part preserves the other and participant baseline abilities', () async {
    project = await session.savePermissionPart(config, planning);
    project = await session.savePermissionPart(config, review);
    await write({
      ...project.json,
      'members': [
        ...project.people.map((p) => p.json),
        {
          ...member(2, 'unassigned').json,
          'parts': ['기획', 'PD'],
        },
      ],
    });
    expect(project.people.last.permissions, participantPermissions);
    expect(project.people.last.roleLabel, '기획, PD');
    project = await session.deletePermissionPart(
      config,
      review.id,
      expectedPart: project.roles.firstWhere((r) => r.id == review.id),
    );
    expect(project.parts, ['기획']);
    expect(project.people.last.parts, ['기획']);
    expect(project.people.last.permissions, participantPermissions);
    expect(project.people.last.has('role.manage'), isFalse);
    expect(project.people.first.has('role.manage'), isTrue);
  });

  test('renaming a part preserves stable ID, membership and participant status; stale edits fail', () async {
    project = await session.savePermissionPart(config, planning);
    await write({
      ...project.json,
      'members': [
        ...project.people.map((p) => p.json),
        {
          ...member(2, 'unassigned').json,
          'parts': ['기획'],
        },
      ],
    });
    const renamed = ProjectRole('role-plan', '기획팀', {
      'task.create',
      'task.work',
    });
    project = await session.savePermissionPart(
      config,
      renamed,
      expectedPart: project.roles.firstWhere((r) => r.id == planning.id),
    );
    expect(project.people.last.parts, ['기획팀']);
    expect(project.people.last.permissions, participantPermissions);
    expect(project.people.last.enabled, isTrue);
    expect(project.roles.single.id, planning.id);
    await expectLater(
      session.savePermissionPart(config, planning, expectedPart: planning),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.deletePermissionPart(config, planning.id, expectedPart: planning),
      throwsA(isA<GitHubFailure>()),
    );
    expect((await session.loadProject(config)).parts, ['기획팀']);
  });

  test(
    'delegated participant managers assign parts without gaining ownership',
    () async {
      project = await session.savePermissionPart(config, planning);
      project = await session.savePermissionPart(config, review);
      const delegate = ProjectRole('role-delegate', '배정 담당', {
        'member.manage',
        'task.work',
      });
      project = await session.savePermissionPart(config, delegate);
      await write({
        ...project.json,
        'members': [
          ...project.people.map((p) => p.json),
          {...member(2, 'unassigned').json, 'parts': []},
          {
            ...member(3, 'unassigned').json,
            'parts': ['배정 담당'],
          },
        ],
      });
      api.identityId = 3;
      api.identityLogin = 'guest';
      await session.signIn();
      final delegated = (await session.loadProject(config)).people
          .firstWhere((p) => p.id == 'gh-3');
      expect(delegated.has('member.manage'), isTrue);
      expect(delegated.has('role.manage'), isFalse);
      project = await session.assign(
        config,
        Person.fromJson({
          ...member(2, 'unassigned').json,
          'parts': ['PD'],
        }),
        unifyParts: true,
      );
      expect(
        (await session.loadProject(config)).people
            .firstWhere((p) => p.id == 'gh-2')
            .parts,
        ['PD'],
      );
      expect(project.ownerId, 'gh-1');
      api.identityId = 1;
      api.identityLogin = 'tester';
      await session.signIn();
      project = await session.assign(
        config,
        Person.fromJson({
          ...member(2, 'unassigned').json,
          'parts': ['기획', 'PD'],
        }),
        unifyParts: true,
      );
      expect(project.people.firstWhere((p) => p.id == 'gh-2').canWork, isTrue);
      expect(
        project.people.firstWhere((p) => p.id == 'gh-2').canReview,
        isTrue,
      );
    },
  );

  test(
    'legacy administrator-named part and fine grants never promote its member',
    () async {
      final impostor = ProjectRole(
        'role-impostor',
        '관리자',
        permissionLabels.keys.toSet(),
      );
      await write({
        ...legacyJson(),
        'roles': [impostor.json],
        'members': [
          project.people.first.json,
          {
            ...member(2, impostor.id).json,
            'permissions': permissionLabels.keys.toList(),
          },
        ],
      });
      final migrated = project.people.last;
      expect(migrated.role, 'unassigned');
      expect(migrated.parts, ['관리자']);
      expect(migrated.permissions, participantPermissions);
      expect(migrated.has('member.manage'), isFalse);
      expect(migrated.has('task.integrate'), isTrue);
      expect(project.ownerId, project.people.first.id);
      project = await session.savePermissionPart(config, planning);
      expect(project.roles.first.id, impostor.id);
      expect(project.people.last.parts, ['관리자']);
      expect(project.people.last.has('role.manage'), isFalse);
    },
  );

  testWidgets(
    'part screen provides name-only creation in the empty detail and has no separate permission navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (const bool.fromEnvironment('IEUM_UI_PREVIEW')) {
        await tester.runAsync(() async {
          await (FontLoader('Malgun Gothic')..addFont(
                File('C:/Windows/Fonts/malgun.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.single,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      store.setMeta('github.login', store.actor.login);
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('unified-preview'),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(fontFamily: 'Malgun Gothic'),
              home: Scaffold(
                body: SettingsShell(
                  selected: SettingsSection.roles,
                  onSelected: (_) {},
                  contentBuilder: (_) =>
                      RolesPanel(store: store, sync: sync, session: session),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('등록된 파트가 없습니다.'), findsOneWidget);
        expect(find.text('첫 역할을 추가해 주세요.'), findsNothing);
        expect(find.byKey(const Key('settings-nav-assignments')), findsNothing);
        await tester.tap(find.byKey(const Key('add-first-part')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('role-name')), '기획');
        expect(find.byKey(const Key('role-preset-작업 권한')), findsNothing);
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-role')));
        await tester.pumpAndSettle();
        expect(store.project!.parts, ['기획']);
        expect(store.project!.roles.single.permissions, isEmpty);
        expect(store.partRules.single.part, '기획');
        if (const bool.fromEnvironment('IEUM_UI_PREVIEW')) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('unified-preview')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('../.local/unified-permissions-preview.png')
                .writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
        final id = store.project!.roles.single.id;
        await tester.tap(find.byKey(Key('delete-role-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-role')));
        await tester.pumpAndSettle();
        expect(store.project!.parts, isEmpty);
        expect(store.project!.roles, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );

  testWidgets(
    'member editor assigns parts without a separate permission role selector',
    (tester) async {
      project = await session.savePermissionPart(config, planning);
      await write({
        ...project.json,
        'members': [
          ...project.people.map((p) => p.json),
          {...member(2, 'unassigned').json, 'parts': []},
        ],
      });
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TeamPanel(
                  store: store,
                  sync: sync,
                  session: session,
                  initialMember: 'gh-2',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('파트 배정').first);
        await tester.tap(find.text('파트 배정').first);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('member-role-unassigned')), findsNothing);
        await tester.ensureVisible(find.byKey(const Key('member-part-기획')));
        await tester.tap(find.byKey(const Key('member-part-기획')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('save-member')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '확인'));
        await tester.pumpAndSettle();
        expect(store.member('gh-2').parts, ['기획']);
        expect(store.member('gh-2').canWork, isTrue);
        expect(store.member('gh-2').has('role.manage'), isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );
}
