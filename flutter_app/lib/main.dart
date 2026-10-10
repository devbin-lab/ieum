import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'store.dart';
import 'app.dart';
import 'window_frame.dart';
import 'project_gate.dart';
import 'project_service.dart';
import 'app_update.dart';
import 'app_release.dart';
import 'update_ui.dart';
import 'startup_health.dart';
import 'window_layout.dart';
import 'github_oauth.dart';
import 'app_preferences.dart';
import 'first_run.dart';

import 'package:screen_retriever/screen_retriever.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = GitHubSession();
  // The portable EXE updater is a Windows distribution mechanism. Linux
  // downloads its complete tar bundle from Releases through the settings UI.
  final updaterEnabled =
      Platform.isWindows && Platform.environment['IEUM_DISABLE_UPDATES'] != '1';
  final updater = AppUpdater(
    root: Directory(
      Platform.isWindows
          ? '${Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path}${Platform.pathSeparator}Ieum'
          : '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}updates',
    ),
    currentVersion: appVersion,
    source: GitHubUpdateSource(
      updateRepository,
      credential: session.oauthCredential,
    ),
  );
  if (updaterEnabled && await updater.restartPending()) {
    exit(0);
  }
  await windowManager.ensureInitialized();
  var initialSize = minimumWindowSize;
  try {
    final display = await screenRetriever.getPrimaryDisplay().timeout(
      const Duration(seconds: 2),
    );
    initialSize = initialWindowSize(display.visibleSize ?? display.size);
  } catch (_) {
    // Screen detection failure must not block startup.
  }
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: initialSize,
      minimumSize: minimumWindowSize,
      center: true,
      title: '이음',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Colors.white,
    ),
  );
  // Only the CI smoke process uses an empty, temporary Secret Service keyring.
  final smokeTest =
      Platform.isLinux &&
      Platform.environment['IEUM_SMOKE_TEST'] == '1' &&
      Platform.environment['CI'] == 'true';
  if (smokeTest) {
    final vault = DesktopOAuthVault();
    if (await vault.read() != null) {
      throw StateError('Smoke keyring must be empty');
    }
    await vault.write('ieum-ci-vault-check');
    if (await vault.read() != 'ieum-ci-vault-check') {
      throw StateError('Keyring round trip failed');
    }
    await vault.delete();
    if (await vault.read() != null) throw StateError('Keyring deletion failed');
  }
  var appStarted = false;
  try {
    final base =
        Platform.environment['IEUM_FLUTTER_DATA_DIR'] ??
        '${Platform.environment['APPDATA'] ?? (await getApplicationSupportDirectory()).path}${Platform.pathSeparator}Ieum-Flutter-Prototype';
    await Directory(base).create(recursive: true);
    final preferences = AppPreferences(
      file: File('$base${Platform.pathSeparator}app-preferences.json'),
    );
    await preferences.load();
    final projectPreferences = File(
      '$base${Platform.pathSeparator}project-preferences.json',
    );
    final placeholder = TaskStore(':memory:');
    runApp(
      UpdateScope(
        updater: updater,
        supportsAutomaticInstall: Platform.isWindows,
        restart: () async {
          if (updaterEnabled && await updater.restartPending()) {
            await windowManager.close();
          }
        },
        child: IeumApp(
          store: placeholder,
          preferences: preferences,
          home: FirstRunGate(
            preferences: preferences,
            existingProject: hasSavedProjectCatalog(projectPreferences),
            builder: (openInitialSettings) => ProjectGate(
              session: session,
              preferences: projectPreferences,
              onOpenInitialSettings: openInitialSettings,
            ),
          ),
        ),
      ),
    );
    appStarted = true;
  } catch (e) {
    runApp(
      MaterialApp(
        builder: (context, child) => DesktopFrame(child: child!),
        home: Scaffold(body: Center(child: SelectableText('이음 실행 오류\n$e'))),
      ),
    );
  }
  await windowManager.show();
  await WidgetsBinding.instance.endOfFrame;
  if (appStarted && smokeTest) {
    await File(Platform.environment['IEUM_SMOKE_MARKER']!).writeAsString(
      'IEUM $appVersion: Linux first frame and native keyring passed\n',
      flush: true,
    );
  }
  // The distribution launcher waits for this signal before committing an update.
  final startupMarker = Platform.environment['IEUM_STARTUP_MARKER'];
  if (appStarted && startupMarker != null && Platform.isWindows) {
    try {
      final marker = startupHealthFile(
        '${Platform.environment['LOCALAPPDATA']}${Platform.pathSeparator}Ieum${Platform.pathSeparator}builds',
        startupMarker,
      );
      if (marker != null) {
        await marker.writeAsString(appVersion, flush: true);
      }
    } catch (_) {
      // Startup itself remains usable if the status marker cannot be written.
    }
  }
  if (updaterEnabled) updater.start();
}
