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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final session = GitHubSession();
  final updater = AppUpdater(
    root: Directory(
      '${Platform.environment['LOCALAPPDATA'] ?? Platform.environment['TEMP']}${Platform.pathSeparator}Ieum',
    ),
    currentVersion: appVersion,
    source: GitHubUpdateSource(
      updateRepository,
      credential: () => session.sessionToken,
    ),
  );
  if (Platform.environment['IEUM_DISABLE_UPDATES'] != '1' &&
      await updater.restartPending()) {
    exit(0);
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1480, 980),
      minimumSize: Size(1160, 740),
      title: '이음 · Flutter 프로토타입',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Colors.white,
    ),
  );
  try {
    final base =
        Platform.environment['IEUM_FLUTTER_DATA_DIR'] ??
        '${Platform.environment['APPDATA'] ?? (await getApplicationSupportDirectory()).path}${Platform.pathSeparator}Ieum-Flutter-Prototype';
    await Directory(base).create(recursive: true);
    final placeholder = TaskStore(':memory:');
    runApp(
      UpdateScope(
        updater: updater,
        restart: () async {
          if (await updater.restartPending()) await windowManager.close();
        },
        child: IeumApp(
          store: placeholder,
          home: ProjectGate(
            session: session,
            preferences: File(
              '$base${Platform.pathSeparator}project-preferences.json',
            ),
          ),
        ),
      ),
    );
  } catch (e) {
    runApp(
      MaterialApp(
        builder: (context, child) => DesktopFrame(child: child!),
        home: Scaffold(body: Center(child: SelectableText('이음 실행 오류\n$e'))),
      ),
    );
  }
  await windowManager.show();
  if (Platform.environment['IEUM_DISABLE_UPDATES'] != '1') updater.start();
}
