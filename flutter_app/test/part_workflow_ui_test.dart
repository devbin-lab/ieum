import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/role_editor.dart';
import 'package:ieum_flutter/roles_panel.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/team_panel.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'project_test.dart' show member;

const config = GitHubConfig(repository: 'team/data', enabled: true);

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
    project = await session.createProject(config, '파트 워크플로', '관리자');
  });
  tearDown(() => session.signOut());

  Future<void> write(Map<String, dynamic> data) async {
    final file = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      data,
      sha: file!['sha'],
      message: 'Part UI fixture',
    );
    project = await session.loadProject(config);
  }

  Future<void> openPanel(
    WidgetTester tester,
    TaskStore store,
    GitHubSync sync, {
    bool team = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: team
                ? TeamPanel(store: store, sync: sync, session: session)
                : RolesPanel(store: store, sync: sync, session: session),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('parts have name-only CRUD and fixed administrator description', (
    tester,
  ) async {
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.first,
    );
    store.setMeta('github.config', jsonEncode(config.toJson()));
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    try {
      await openPanel(tester, store, sync);
      await tester.tap(find.byKey(const Key('add-first-part')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('permission-search')), findsNothing);
      expect(find.byKey(const Key('role-preset-작업 권한')), findsNothing);
      await tester.enterText(find.byKey(const Key('role-name')), '기획');
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      final saved = store.project!.roles.single;
      expect(saved.permissions, isEmpty);
      expect(store.project!.parts, ['기획']);
      expect(find.byKey(const Key('role-permissions-tab')), findsNothing);
      expect(find.byKey(const Key('role-members-title')), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('edit-role-${saved.id}')));
      await tester.tap(find.byKey(Key('edit-role-${saved.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), '기획팀');
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      expect(store.project!.roles.single.id, saved.id);
      expect(store.project!.parts, ['기획팀']);
      await tester.ensureVisible(find.byKey(const Key('system-roles')));
      await tester.tap(find.byKey(const Key('system-roles')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('select-role-owner')));
      await tester.tap(find.byKey(const Key('select-role-owner')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('copy-system-role-owner')), findsNothing);
      expect(find.byKey(const Key('delete-role-owner')), findsNothing);
      expect(find.textContaining('잘못 전달된 작업을 회수'), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('select-role-${saved.id}')));
      await tester.tap(find.byKey(Key('select-role-${saved.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(Key('delete-role-${saved.id}')));
      await tester.tap(find.byKey(Key('delete-role-${saved.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-role')));
      await tester.pumpAndSettle();
      expect(store.project!.parts, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
      store.dispose();
    }
  });

  testWidgets(
    'part members are visible without a permission tab and cannot manage parts',
    (tester) async {
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-plan', '기획', {}),
      );
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
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.last,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      try {
        await openPanel(tester, store, sync);
        expect(find.text(project.people.last.name), findsOneWidget);
        expect(find.byKey(const Key('add-role')), findsNothing);
        expect(
          tester
              .widget<TextButton>(find.byKey(const Key('edit-role-role-plan')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const Key('delete-role-role-plan')),
              )
              .onPressed,
          isNull,
        );
        expect(find.byKey(const Key('permission-task.work')), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );

  testWidgets(
    'member part assignment preserves inactive state and has no grant editor',
    (tester) async {
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-plan', '기획', {}),
      );
      await write({
        ...project.json,
        'members': [
          ...project.people.map((p) => p.json),
          {...member(2, 'unassigned').json, 'parts': [], 'enabled': false},
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
        await openPanel(tester, store, sync, team: true);
        await tester.ensureVisible(
          find.byKey(const Key('member-actions-gh-2')),
        );
        await tester.tap(find.byKey(const Key('member-actions-gh-2')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('파트 배정').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('member-role-unassigned')), findsNothing);
        expect(find.textContaining('적용 권한:'), findsNothing);
        await tester.tap(find.byKey(const Key('member-part-기획')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-member')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '확인'));
        await tester.pumpAndSettle();
        expect(store.member('gh-2').parts, ['기획']);
        expect(store.member('gh-2').enabled, isFalse);
        expect(store.member('gh-2').role, 'unassigned');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );

  testWidgets(
    'owner can assign their own parts from both member menu and detail',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-plan', '기획', {}),
      );
      project = await session.savePermissionPart(
        config,
        const ProjectRole('role-pd', 'PD', {}),
      );
      final ownerId = project.ownerId;
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      try {
        await openPanel(tester, store, sync, team: true);
        await tester.tap(find.byKey(Key('member-actions-$ownerId')));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(MenuItemButton, '파트 배정'), findsOneWidget);
        expect(find.byKey(Key('member-status-$ownerId')), findsNothing);
        await tester.tap(find.widgetWithText(MenuItemButton, '참여자 상세'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, '파트 배정'));
        await tester.pumpAndSettle();
        for (final key in ['member-enabled', 'member-disabled']) {
          expect(
            tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
            isNull,
          );
        }
        await tester.tap(find.byKey(const Key('member-part-기획')));
        await tester.tap(find.byKey(const Key('member-part-PD')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-member')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '확인'));
        await tester.pumpAndSettle();
        expect(store.member(ownerId).parts, ['기획', 'PD']);
        expect(store.member(ownerId).role, 'owner');
        expect(store.member(ownerId).active, isTrue);
        expect(store.project!.ownerId, ownerId);
        expect((await session.loadProject(config)).people.first.parts, [
          '기획',
          'PD',
        ]);
        await tester.tap(find.byKey(Key('member-actions-$ownerId')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(MenuItemButton, '파트 배정'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('member-part-기획')));
        await tester.tap(find.byKey(const Key('member-part-PD')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-member')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '확인'));
        await tester.pumpAndSettle();
        expect(store.member(ownerId).parts, isEmpty);
        expect(store.member(ownerId).role, 'owner');
        expect(store.member(ownerId).active, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );

  testWidgets(
    'part editor exposes only participant and role management settings',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.first,
      );
      store.setMeta('github.config', jsonEncode(config.toJson()));
      final sync = GitHubSync(store, publisher: GitHubPublisher(api));
      try {
        await openPanel(tester, store, sync);
        await tester.tap(find.byKey(const Key('add-first-part')));
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsNWidgets(2));
        expect(find.byKey(const Key('permission-task.create')), findsNothing);
        expect(find.byKey(const Key('permission-task.work')), findsNothing);
        expect(find.byKey(const Key('permission-task.review')), findsNothing);
        expect(
          find.byKey(const Key('permission-task.integrate')),
          findsNothing,
        );
        await tester.enterText(find.byKey(const Key('role-name')), '운영 파트');
        await tester.tap(find.byKey(const Key('permission-member.manage')));
        await tester.tap(find.byKey(const Key('permission-role.manage')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-role')));
        await tester.pumpAndSettle();
        expect(store.project!.roles.single.permissions, {
          'member.manage',
          'role.manage',
        });
        final saved = store.project!.roles.single;
        await tester.tap(find.byKey(Key('edit-role-${saved.id}')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const Key('permission-member.manage')),
              )
              .value,
          isTrue,
        );
        await tester.tap(find.byKey(const Key('permission-member.manage')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-role')));
        await tester.pumpAndSettle();
        expect(store.project!.roles.single.permissions, {'role.manage'});
        expect((await session.loadProject(config)).roles.single.permissions, {
          'role.manage',
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );

  testWidgets('name-only editor preserves draft after a rejected save', (
    tester,
  ) async {
    ProjectRole? attempted;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showProjectRoleDialog(
              context,
              project.people.first,
              role: const ProjectRole('role-plan', '기획', {'task.work'}),
              onSave: (value) async {
                attempted = value;
                throw StateError('stale fixture');
              },
            ),
            child: const Text('수정'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('수정'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('role-name')), '기획팀');
    await tester.pump();
    await tester.tap(find.byKey(const Key('save-role')));
    await tester.pumpAndSettle();
    expect(attempted!.permissions, isEmpty);
    expect(attempted!.id, 'role-plan');
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('role-name')))
          .controller!
          .text,
      '기획팀',
    );
    expect(find.textContaining('stale fixture'), findsOneWidget);
    expect(find.byKey(const Key('permission-task.work')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('inline part creation rebases only its own legacy migration', (
    tester,
  ) async {
    final legacy = {...project.json}
      ..remove('workflowSheet')
      ..remove('partsUnified');
    await write({
      ...legacy,
      'parts': ['기획'],
      'members': [
        project.people.first.json,
        {
          ...member(2, 'worker').json,
          'parts': ['기획'],
          'enabled': false,
        },
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
      await openPanel(tester, store, sync, team: true);
      await tester.ensureVisible(find.byKey(const Key('member-actions-gh-2')));
      await tester.tap(find.byKey(const Key('member-actions-gh-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('파트 배정').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('member-add-role')));
      await tester.tap(find.byKey(const Key('member-add-role')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('role-name')), 'PD');
      await tester.pump();
      await tester.tap(find.byKey(const Key('save-role')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pumpAndSettle();
      expect(store.project!.parts, containsAll(['기획', 'PD']));
      await tester.ensureVisible(find.byKey(const Key('save-member')));
      await tester.tap(find.byKey(const Key('save-member')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '확인'));
      await tester.pumpAndSettle();
      expect(store.member('gh-2').parts, ['기획', 'PD']);
      expect(store.member('gh-2').enabled, isFalse);
      expect(store.member('gh-2').role, 'unassigned');
      expect(find.textContaining('저장 실패'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      sync.dispose();
      store.dispose();
    }
  });
}
