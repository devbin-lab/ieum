import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_update.dart';
import 'package:ieum_flutter/update_ui.dart';

class FakeUpdates implements UpdateSource {
  List<int> bytes = utf8.encode('verified executable fixture');
  String version = '0.2.0+3';
  bool corrupt = false, fail = false;
  int downloads = 0;
  int checks = 0;
  Completer<void>? pauseCheck;
  Completer<void>? pause;
  @override
  Future<UpdateRelease?> latest() async {
    checks++;
    if (pauseCheck != null) await pauseCheck!.future;
    return UpdateRelease.fromJson({
      'tag_name': 'v$version',
      'draft': false,
      'prerelease': false,
      'assets': [
        {
          'name': 'Ieum-Windows-x64.exe',
          'id': 42,
          'size': bytes.length,
          'digest': 'sha256:${sha256.convert(bytes)}',
        },
      ],
    });
  }

  @override
  Future<void> download(
    UpdateRelease release,
    File target,
    void Function(int) progress,
  ) async {
    downloads++;
    if (pause != null) await pause!.future;
    if (fail) throw const SocketException('offline');
    await target.writeAsBytes(
      corrupt ? List.filled(bytes.length, 0) : bytes,
      flush: true,
    );
    progress(bytes.length);
  }
}

void main() {
  late Directory root;
  late FakeUpdates source;
  late AppUpdater updater;
  final launches = <String>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ieum-update-test-');
    source = FakeUpdates();
    launches.clear();
    updater = AppUpdater(
      root: root,
      currentVersion: '0.1.1+2',
      source: source,
      launch: (file) async => launches.add(file.path),
    );
  });
  tearDown(() async {
    updater.dispose();
    await root.delete(recursive: true);
  });

  test('versions compare numerically and reject paths/prereleases', () {
    expect(
      ReleaseVersion('0.10.0+1').compareTo(ReleaseVersion('0.9.9+99')),
      greaterThan(0),
    );
    expect(
      ReleaseVersion('1.0.0+4').compareTo(ReleaseVersion('1.0.0+3')),
      greaterThan(0),
    );
    for (final value in [
      '../2.0.0',
      '1.0.0/bad',
      '1.0.0-beta',
      '1.0.0+999999999999',
    ]) {
      expect(() => ReleaseVersion(value), throwsFormatException);
    }
  });
  test(
    'login during an update check schedules another check with new credentials',
    () async {
      source.pauseCheck = Completer<void>();
      final first = updater.check();
      while (source.checks == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      updater.credentialsChanged();
      source.pauseCheck!.complete();
      await first;
      while (source.checks < 2 || updater.busy) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(source.checks, 2);
      expect(source.downloads, 1);
    },
  );
  test('only trusted HTTPS release hosts are allowed', () {
    expect(
      GitHubUpdateSource.trusted(
        Uri.parse('https://release-assets.githubusercontent.com/asset'),
      ),
      isTrue,
    );
    for (final url in [
      'http://github.com/asset',
      'https://github.com.evil.invalid/a',
      'https://user@github.com/a',
    ]) {
      expect(GitHubUpdateSource.trusted(Uri.parse(url)), isFalse);
    }
  });
  test(
    'verified download becomes ready without launching or changing project DB',
    () async {
      final db = File('${root.path}/project.sqlite');
      await db.writeAsString('existing project');
      await updater.check();
      expect(updater.ready, isTrue);
      expect(launches, isEmpty);
      expect(await updater.pending(), isNotNull);
      expect(await db.readAsString(), 'existing project');
      await updater.check();
      expect(source.downloads, 1);
      expect(await updater.restartPending(), isTrue);
      expect(launches.single, updater.packageFor(source.version).path);
    },
  );
  test(
    'corrupt or interrupted download never becomes an executable update',
    () async {
      source.corrupt = true;
      await updater.check();
      expect(updater.ready, isFalse);
      expect(await updater.pointer.exists(), isFalse);
      expect(await updater.restartPending(), isFalse);
      source.corrupt = false;
      source.fail = true;
      await updater.check();
      expect(updater.ready, isFalse);
      expect(await updater.pointer.exists(), isFalse);
    },
  );
  test(
    'failed later download preserves the previously verified update',
    () async {
      await updater.check();
      source.version = '0.3.0+4';
      source.corrupt = true;
      await updater.check();
      expect(updater.ready, isTrue);
      expect(updater.readyVersion, '0.2.0+3');
      expect(
        (await updater.pending())!.path,
        updater.packageFor('0.2.0+3').path,
      );
    },
  );
  test(
    'cached updates are verified again before restart and are not downgraded',
    () async {
      await updater.check();
      await updater.packageFor(source.version).writeAsString('tampered');
      expect(await updater.restartPending(), isFalse);
      expect(launches, isEmpty);
      source.version = '0.1.0+1';
      final before = source.downloads;
      await updater.check();
      expect(source.downloads, before);
    },
  );
  test('a new session recovers ready updates from disk', () async {
    await updater.check();
    final reopened = AppUpdater(
      root: root,
      currentVersion: '0.1.1+2',
      source: source,
      launch: (file) async => launches.add(file.path),
    );
    expect(await reopened.restartPending(), isTrue);
    expect(launches, hasLength(1));
    reopened.dispose();
  });
  testWidgets('update button reports readiness and restarts only after click', (
    tester,
  ) async {
    var restarts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: UpdateScope(
          updater: updater,
          restart: () async {
            restarts++;
          },
          child: const Scaffold(body: UpdateButton()),
        ),
      ),
    );
    await tester.runAsync(updater.check);
    await tester.pump();
    expect(find.text('업데이트 후 재시작'), findsOneWidget);
    expect(restarts, 0);
    await tester.tap(find.byKey(const Key('app-update-button')));
    expect(restarts, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
