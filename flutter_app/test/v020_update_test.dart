import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_update.dart';

import 'app_update_test.dart' show FakeUpdates;

void main() {
  test('failed executable is quarantined without blocking current app or retried each launch', () async {
    final directory = await Directory.systemTemp.createTemp(
      'ieum-update-recovery-',
    );
    final source = FakeUpdates();
    var launches = 0;
    final updater = AppUpdater(
      root: directory,
      currentVersion: '0.1.3+4',
      source: source,
      launch: (_) async {
        launches++;
        throw const ProcessException('fixture', [], 'blocked');
      },
    );
    try {
      await updater.check();
      expect(await updater.restartPending(), isFalse);
      expect(updater.ready, isFalse);
      expect(await updater.pointer.exists(), isFalse);
      expect(await updater.blockedFor(source.version).exists(), isTrue);
      await updater.check();
      expect(source.downloads, 1);
      expect(await updater.restartPending(), isFalse);
      expect(launches, 1);
      source.version = '0.2.1+6';
      await updater.check();
      expect(updater.ready, isTrue);
      expect(source.downloads, 2);
    } finally {
      updater.dispose();
      if (directory.parent.absolute.path !=
              Directory.systemTemp.absolute.path ||
          !directory.path.contains('ieum-update-recovery-')) {
        throw StateError('Unsafe test path');
      }
      await directory.delete(recursive: true);
    }
  });
}
