import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/project_gate.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi;
import 'github_oauth_test.dart' show MemoryVault, ScriptedOAuth, device, tokens;

class RateApi extends FakeGitHubApi {
  int? failedStatus;
  String? failedPath;
  bool permissionDenied = false;
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (failedStatus != null && path == failedPath) {
      throw GitHubFailure(
        'audit injected rate limit',
        failedStatus!,
        permissionDenied ? null : const Duration(minutes: 20),
      );
    }
    return super.call(method, path, query: query, body: body);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = GitHubConfig(
    repository: 'team/data',
    enabled: true,
    autoMerge: false,
  );
  for (final scenario in [
    (
      name: 'permission denial still blocks cached account restoration',
      path: '/user',
      status: 403,
      workspace: false,
      identity: false,
    ),
    (
      name: 'network outage control opens cached workspace',
      path: '/user',
      status: 0,
      workspace: true,
      identity: true,
    ),
    (
      name: 'rate limit on identity opens cached workspace',
      path: '/user',
      status: 403,
      workspace: true,
      identity: true,
    ),
    (
      name: 'rate limit on project opens cached workspace',
      path: '/repos/team/data/contents/.ieum/project.json',
      status: 403,
      workspace: true,
      identity: true,
    ),
  ]) {
    testWidgets(scenario.name, (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('ieum-reliability-');
      addTearDown(() => root.deleteSync(recursive: true));
      root.createSync(recursive: true);
      final dir = root.createTempSync('case-');
      final prefs = File('${dir.path}/preferences.json');
      final api = RateApi();
      final vault = MemoryVault();
      final transport = ScriptedOAuth()
        ..responses.addAll([device(), tokens('audit', seconds: null)]);
      final session = GitHubSession(
        api: api,
        oauth: GitHubOAuth(
          vault: vault,
          transport: transport,
          delay: (_) async {},
        ),
      );
      await session.signInOAuth(remember: true, onCode: (_) {});
      final manifest = await session.createProject(
        config,
        'Audit project',
        'Audit owner',
      );
      final databasePath = '${dir.path}/audit.sqlite';
      final db = TaskStore(
        databasePath,
        project: manifest,
        identity: session.named('Audit owner'),
      );
      db.setMeta('github.config', jsonEncode(config.toJson()));
      db.dispose();
      ProjectCatalog(prefs).remember(
        'gh-1',
        SavedProject(
          path: databasePath,
          name: manifest.name,
          projectId: manifest.id,
          config: config,
        ),
      );
      session.signOut();
      api.failedPath = scenario.path;
      api.failedStatus = scenario.status;
      api.permissionDenied = !scenario.workspace;
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectGate(preferences: prefs, session: session),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
      await tester.pumpAndSettle();
      expect(
        find.byType(Workspace),
        scenario.workspace ? findsOneWidget : findsNothing,
      );
      expect(session.user != null, scenario.identity);
      if (scenario.path == '/user') expect(session.offline, scenario.workspace);
      expect(vault.value, isNotNull);
      expect(File(databasePath).existsSync(), isTrue);
      if (!scenario.workspace) {
        expect(find.textContaining('audit injected rate limit'), findsWidgets);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      session.signOut();
    });
  }
}
