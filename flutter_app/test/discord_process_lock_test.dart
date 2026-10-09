import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/discord_process_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final scope = 'a' * 64;

  tearDown(
    () => messenger.setMockMethodCallHandler(
      NativeDiscordProcessLock.channel,
      null,
    ),
  );

  test(
    'account and hash scope are validated before any native lock operation',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(NativeDiscordProcessLock.channel, (
        _,
      ) async {
        calls++;
        return true;
      });
      final lock = NativeDiscordProcessLock();
      await expectLater(
        lock.acquire(accountId: 'gh-123/other', scope: scope),
        throwsA(isA<DiscordProcessLockFailure>()),
      );
      await expectLater(
        lock.acquire(accountId: 'gh-123', scope: 'project-name'),
        throwsA(isA<DiscordProcessLockFailure>()),
      );
      await expectLater(
        lock.acquire(accountId: 'gh-123', scope: 'A' * 64),
        throwsA(isA<DiscordProcessLockFailure>()),
      );
      expect(calls, 0);
      expect(lock.isHeld, false);
    },
  );

  test(
    'contended lock returns false; only a successful acquisition is released',
    () async {
      final calls = <MethodCall>[];
      var free = false;
      messenger.setMockMethodCallHandler(NativeDiscordProcessLock.channel, (
        call,
      ) async {
        calls.add(call);
        return call.method == 'acquire' ? free : null;
      });
      final lock = NativeDiscordProcessLock();
      expect(await lock.acquire(accountId: 'gh-123', scope: scope), false);
      await lock.release();
      expect(calls.length, 1);
      free = true;
      expect(await lock.acquire(accountId: 'gh-123', scope: scope), true);
      expect(lock.isHeld, true);
      expect(await lock.acquire(accountId: 'gh-123', scope: scope), true);
      expect(await lock.acquire(accountId: 'gh-123', scope: 'b' * 64), false);
      await lock.release();
      expect(lock.isHeld, false);
      expect(calls.map((call) => call.method), [
        'acquire',
        'acquire',
        'release',
      ]);
      final acquire = calls[1].arguments as Map;
      expect(acquire['accountId'], 'gh-123');
      expect(acquire['scope'], scope);
      expect((calls.last.arguments as Map)['claim'], acquire['claim']);
    },
  );

  test(
    'pending acquisition finishes before release and a new acquisition',
    () async {
      final calls = <String>[];
      final wait = Completer<bool>();
      messenger.setMockMethodCallHandler(NativeDiscordProcessLock.channel, (
        call,
      ) async {
        calls.add(call.method);
        if (call.method == 'acquire' && calls.length == 1) return wait.future;
        return call.method == 'acquire' ? true : null;
      });
      final lock = NativeDiscordProcessLock();
      final acquiring = lock.acquire(accountId: 'gh-123', scope: scope);
      final releasing = lock.release();
      final reacquiring = lock.acquire(accountId: 'gh-123', scope: 'b' * 64);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['acquire']);
      wait.complete(true);
      expect(await acquiring, true);
      await releasing;
      expect(await reacquiring, true);
      expect(calls, ['acquire', 'release', 'acquire']);
      await lock.release();
    },
  );

  test(
    'separate Dart services have separate claims and cannot release each other',
    () async {
      String? owner;
      final claims = <String>[];
      messenger.setMockMethodCallHandler(NativeDiscordProcessLock.channel, (
        call,
      ) async {
        final claim = (call.arguments as Map)['claim'] as String;
        if (call.method == 'acquire') {
          claims.add(claim);
          if (owner != null && owner != claim) return false;
          owner = claim;
          return true;
        }
        if (owner == claim) owner = null;
        return null;
      });
      final first = NativeDiscordProcessLock();
      final second = NativeDiscordProcessLock();
      expect(await first.acquire(accountId: 'gh-123', scope: scope), true);
      expect(await second.acquire(accountId: 'gh-123', scope: scope), false);
      await second.release();
      expect(owner, claims.first);
      await first.release();
      expect(await second.acquire(accountId: 'gh-123', scope: scope), true);
      await first.release();
      expect(second.isHeld, true);
      expect(owner, claims.last);
      expect(claims.first, isNot(claims.last));
      await second.release();
    },
  );

  test('native error messages are redacted and failures do not poison call ordering', () async {
    var fail = true;
    messenger.setMockMethodCallHandler(NativeDiscordProcessLock.channel, (
      call,
    ) async {
      if (fail) {
        throw PlatformException(
          code: 'lock',
          message: 'secret debugging details',
        );
      }
      return call.method == 'acquire' ? true : null;
    });
    final lock = NativeDiscordProcessLock();
    try {
      await lock.acquire(accountId: 'gh-123', scope: scope);
      expect(true, false, reason: 'Expected a lock failure');
    } catch (error) {
      expect(error, isA<DiscordProcessLockFailure>());
      expect(error.toString(), isNot(contains('secret debugging details')));
    }
    expect(lock.isHeld, false);
    fail = false;
    expect(await lock.acquire(accountId: 'gh-123', scope: scope), true);
    await lock.release();
  });
}
