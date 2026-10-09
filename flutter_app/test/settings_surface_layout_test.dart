import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_panel.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/roles_panel.dart';
import 'package:ieum_flutter/store.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

void main() {
  const owner = Person('gh-1', '관리자', '관', 'owner', 0, login: 'owner');
  const first = ProjectRole('role-design', '기획', {});
  const second = ProjectRole('role-pd', '디렉터', {'member.manage'});
  const project = ProjectManifest(
    'project-layout',
    '설정 배치',
    'gh-1',
    [owner],
    parts: ['기획', '디렉터'],
    roles: [first, second],
  );

  testWidgets(
    'part list selects one management surface and fits narrow content',
    (tester) async {
      final store = TaskStore(':memory:', project: project, identity: owner);
      final sync = GitHubSync(store);
      final session = GitHubSession(
        api: FakeGitHubApi(),
        oauth: GitHubOAuth(vault: MemoryVault()),
      );
      addTearDown(() {
        sync.dispose();
        store.dispose();
      });
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final width in [188.0, 352.0, 880.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: SingleChildScrollView(
                    child: RolesPanel(
                      store: store,
                      sync: sync,
                      session: session,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('role-search')), findsOneWidget);
        final selected = find.byKey(const Key('select-role-role-pd'));
        await tester.ensureVisible(selected);
        await tester.tap(selected);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('edit-role-role-pd')), findsOneWidget);
        expect(find.byKey(const Key('delete-role-role-pd')), findsOneWidget);
        expect(find.byKey(const Key('edit-role-role-design')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('GitHub connection controls and activity fit narrow settings', (
    tester,
  ) async {
    final store = TaskStore(':memory:', project: project, identity: owner);
    final sync = GitHubSync(store);
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final width in [188.0, 352.0, 880.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SingleChildScrollView(child: GitHubPanel(sync: sync)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('github-auto-sync')), findsOneWidget);
      expect(find.byKey(const Key('github-auto-merge')), findsOneWidget);
      expect(find.text('최근 동기화'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
