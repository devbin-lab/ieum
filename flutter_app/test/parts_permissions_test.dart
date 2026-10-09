import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/roles_panel.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/task_editor.dart';
import 'package:ieum_flutter/workflow_sheet_handoff.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;
import 'project_test.dart' show member, task;

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
    project = await session.createProject(config, '파트 관리', '개설자');
  });
  tearDown(() => session.signOut());

  test(
    'new and legacy projects start with an empty project part catalogue',
    () {
      expect(project.parts, isEmpty);
      expect(project.people.single.parts, isEmpty);
      final legacy = {...project.json}
        ..remove('parts')
        ..remove('partsUnified')
        ..remove('workflowSheet');
      legacy['members'] = [member(1, 'owner').json];
      final parsed = ProjectManifest.fromJson(legacy);
      expect(parsed.parts, isEmpty);
      expect(parsed.people.single.parts, isEmpty);
      expect(ProjectManifest.fromJson(parsed.json).parts, isEmpty);
      expect(sheetHandoffGroups([], []), {'': '모든 작업자', 'role:owner': '관리자'});
    },
  );

  test('parts persist and deletion clears membership without resurrecting it on re-add', () async {
    const role = ProjectRole('role-director', '디렉터', {});
    project = await session.savePermissionPart(config, role);
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    final guest = Person.fromJson({
      ...member(2, 'unassigned').json,
      'parts': ['디렉터'],
    });
    final file = await session.readJson(config, '.ieum/project.json');
    await session.writeJson(
      config,
      '.ieum/project.json',
      {
        ...project.json,
        'members': [...project.people.map((p) => p.json), guest.json],
      },
      sha: file!['sha'],
      message: 'Fixture',
    );
    project = await session.loadProject(config);
    expect(project.people.last.parts, ['디렉터']);
    project = await session.deletePermissionPart(
      config,
      role.id,
      expectedPart: role,
    );
    expect(project.people.last.parts, isEmpty);
    expect((await session.loadProject(config)).parts, ['기획']);
    project = await session.savePermissionPart(config, role);
    expect(project.people.last.parts, isEmpty);
    final groups = sheetHandoffGroups(project.roles, project.parts);
    expect(groups['part:${role.id}'], '파트 · 디렉터');
    expect(groups.containsKey('part:아트'), isFalse);
  });

  test('duplicate, blank and stale part changes do not overwrite the remote catalogue', () async {
    const planning = ProjectRole('role-plan', '기획', {});
    project = await session.savePermissionPart(config, planning);
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-qa', 'QA', {}),
    );
    for (final invalid in const [
      ProjectRole('role-blank', '', {}),
      ProjectRole('role-duplicate', '기획', {}),
      ProjectRole('role-duplicate-qa', 'qa', {}),
    ]) {
      await expectLater(
        session.savePermissionPart(config, invalid),
        throwsA(anyOf(isA<GitHubFailure>(), isA<StateError>())),
      );
    }
    await expectLater(
      session.savePermissionPart(
        config,
        const ProjectRole('role-plan', '디렉터', {}),
        expectedPart: const ProjectRole('role-plan', '예전 이름', {}),
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect((await session.loadProject(config)).parts, ['기획', 'QA']);
    await expectLater(
      session.savePermissionPart(
        config,
        planning,
        expectedProjectId: 'another',
      ),
      throwsA(isA<GitHubFailure>()),
    );
    await expectLater(
      session.saveParts(config, ['기획']),
      throwsA(isA<GitHubFailure>()),
    );
  });

  test('existing tasks survive part deletion; new tasks must use a registered part', () async {
    project = await session.savePermissionPart(
      config,
      const ProjectRole('role-plan', '기획', {}),
    );
    final store = TaskStore(
      ':memory:',
      project: project,
      identity: project.people.single,
    );
    try {
      final saved = store.save(
        task(project.people.single, project.people.single),
      );
      project = await session.deletePermissionPart(config, 'role-plan');
      store.updateProject(project);
      expect(store.partRules, isEmpty);
      expect(store.find(saved.id).part, '기획');
      final edited = store.save({
        ...saved.data,
        'title': '삭제된 파트의 기존 작업 수정',
      }, expectedVersion: saved.version);
      expect(edited.part, '기획');
      expect(
        () => store.save(task(project.people.single, project.people.single)),
        throwsStateError,
      );
      expect(
        () => validateTaskMutation(
          actor: project.people.single,
          next: saved,
          projectParts: [],
          workflowProject: project,
        ),
        throwsStateError,
      );
      validateTaskMutation(
        actor: project.people.single,
        current: saved,
        next: edited,
        customStages: project.workflowStages.map((s) => s.id).toList(),
        manualWorkflow: true,
        projectParts: [],
        workflowProject: project,
      );
    } finally {
      store.dispose();
    }
  });

  testWidgets(
    'part panel adds and deletes persisted parts from an empty state',
    (tester) async {
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
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RolesPanel(store: store, sync: sync, session: session),
              ),
            ),
          ),
        );
        expect(find.text('등록된 파트가 없습니다.'), findsOneWidget);
        await tester.tap(find.byKey(const Key('add-first-part')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('role-name')), '디렉터');
        await tester.pump();
        await tester.tap(find.byKey(const Key('save-role')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        expect(find.text('디렉터'), findsWidgets);
        expect((await session.loadProject(config)).parts, ['디렉터']);
        final id = store.project!.roles.single.id;
        await tester.tap(find.byKey(Key('delete-role-$id')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-delete-role')));
        await tester.pumpAndSettle();
        expect(find.text('등록된 파트가 없습니다.'), findsOneWidget);
        expect((await session.loadProject(config)).parts, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );

  testWidgets(
    'empty catalogue task editor does not crash or offer removed defaults',
    (tester) async {
      final store = TaskStore(
        ':memory:',
        project: project,
        identity: project.people.single,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: TaskEditor(store: store)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('프로젝트 설정에서 파트를 추가한 후 작업을 만들 수 있습니다.'), findsOneWidget);
        expect(find.text('기획'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }
    },
  );

  testWidgets(
    'permissions settings expose only administrator as a system permission',
    (tester) async {
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
          MaterialApp(
            home: Scaffold(
              body: SettingsShell(
                selected: SettingsSection.roles,
                onSelected: (_) {},
                contentOnly: true,
                contentBuilder: (_) =>
                    RolesPanel(store: store, sync: sync, session: session),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(SettingsSection.roles.title, '파트');
        expect(SettingsSection.assignments.title, '파트');
        await tester.ensureVisible(find.byKey(const Key('system-roles')));
        await tester.tap(find.byKey(const Key('system-roles')));
        await tester.pumpAndSettle();
        expect(find.text('관리자'), findsOneWidget);
        for (final name in ['운영자', '작업자', '열람자']) {
          expect(find.text(name), findsNothing);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        sync.dispose();
        store.dispose();
      }
    },
  );
}
