import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

class DiscordProcessLockFailure implements Exception {
  const DiscordProcessLockFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One Discord sender owns an account/project lock across Windows processes.
/// Calls on one instance are ordered so a pending acquire cannot outlive release.
/// A per-instance claim prevents an old service from releasing a newer lease.
class NativeDiscordProcessLock {
  static const channel = MethodChannel('ieum/discord_process_lock');
  final String _claim = const Uuid().v4();
  Future<void> _pending = Future<void>.value();
  String? _heldScope;
  bool get isHeld => _heldScope != null;

  Future<T> _ordered<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<bool> acquire({required String accountId, required String scope}) =>
      _ordered(() async {
        if (!RegExp(r'^gh-[0-9]{1,20}$').hasMatch(accountId) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(scope)) {
          throw const DiscordProcessLockFailure(
            'Discord 전송 잠금의 계정과 프로젝트 범위가 올바르지 않습니다.',
          );
        }
        final target = '$accountId/$scope';
        if (_heldScope != null) return _heldScope == target;
        try {
          final acquired = await channel.invokeMethod<bool>('acquire', {
            'accountId': accountId,
            'scope': scope,
            'claim': _claim,
          });
          if (acquired == null) {
            throw const DiscordProcessLockFailure(
              'Discord 전송 잠금의 응답을 확인하지 못했습니다.',
            );
          }
          if (acquired) _heldScope = target;
          return acquired;
        } on DiscordProcessLockFailure {
          rethrow;
        } catch (_) {
          throw const DiscordProcessLockFailure(
            'Discord 전송 잠금을 확인하지 못했습니다. 앱을 다시 실행하세요.',
          );
        }
      });

  Future<void> release() => _ordered(() async {
    if (_heldScope == null) return;
    try {
      await channel.invokeMethod<void>('release', {'claim': _claim});
      _heldScope = null;
    } catch (_) {
      throw const DiscordProcessLockFailure(
        'Discord 전송 잠금을 해제하지 못했습니다. 앱을 다시 실행하세요.',
      );
    }
  });
}
