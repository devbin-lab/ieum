import 'dart:convert';

import 'package:flutter/services.dart';

/// Separate from OAuth credentials, with explicit account and project scopes.
abstract interface class DiscordSecretVault {
  Future<String?> read({
    required String accountId,
    required String projectScope,
    required String key,
  });
  Future<void> write({
    required String accountId,
    required String projectScope,
    required String key,
    required String value,
  });
  Future<void> delete({
    required String accountId,
    required String projectScope,
    required String key,
  });
}

class DiscordVaultFailure implements Exception {
  const DiscordVaultFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class NativeDiscordSecretVault implements DiscordSecretVault {
  static const channel = MethodChannel('ieum/discord_vault');
  static const maxValueBytes = 2560;

  Map<String, String> _scope(
    String accountId,
    String projectScope,
    String key,
  ) {
    if (!RegExp(r'^gh-[0-9]{1,20}$').hasMatch(accountId) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,96}$').hasMatch(projectScope) ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,96}$').hasMatch(key)) {
      throw const DiscordVaultFailure('Discord 인증 정보의 저장 범위가 올바르지 않습니다.');
    }
    return {'accountId': accountId, 'projectScope': projectScope, 'key': key};
  }

  @override
  Future<String?> read({
    required String accountId,
    required String projectScope,
    required String key,
  }) async {
    final scope = _scope(accountId, projectScope, key);
    try {
      final value = await channel.invokeMethod<String>('read', scope);
      if (value != null && utf8.encode(value).length > maxValueBytes) {
        throw const DiscordVaultFailure('저장된 Discord 인증 정보를 확인하지 못했습니다.');
      }
      return value;
    } on DiscordVaultFailure {
      rethrow;
    } catch (_) {
      throw const DiscordVaultFailure('Windows에 저장된 Discord 인증 정보를 읽지 못했습니다.');
    }
  }

  @override
  Future<void> write({
    required String accountId,
    required String projectScope,
    required String key,
    required String value,
  }) async {
    final scope = _scope(accountId, projectScope, key);
    if (value.isEmpty || utf8.encode(value).length > maxValueBytes) {
      throw const DiscordVaultFailure('저장할 Discord 인증 정보의 크기가 올바르지 않습니다.');
    }
    try {
      await channel.invokeMethod<void>('write', {...scope, 'value': value});
    } catch (_) {
      throw const DiscordVaultFailure(
        'Windows에 Discord 인증 정보를 안전하게 저장하지 못했습니다.',
      );
    }
  }

  @override
  Future<void> delete({
    required String accountId,
    required String projectScope,
    required String key,
  }) async {
    final scope = _scope(accountId, projectScope, key);
    try {
      await channel.invokeMethod<void>('delete', scope);
    } catch (_) {
      throw const DiscordVaultFailure('Windows에 저장된 Discord 인증 정보를 지우지 못했습니다.');
    }
  }
}
