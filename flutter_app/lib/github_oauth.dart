import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'github_sync.dart';
import 'github_http.dart';

const githubOAuthClientId = 'Ov23liDTP1YEtuI7SAx0';
const githubDeviceUrl = 'https://github.com/login/device';

abstract interface class OAuthVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class DesktopOAuthVault implements OAuthVault {
  static const channel = MethodChannel('ieum/oauth_credentials');
  @override
  Future<String?> read() => channel.invokeMethod<String>('read');
  @override
  Future<void> write(String value) =>
      channel.invokeMethod<void>('write', value);
  @override
  Future<void> delete() => channel.invokeMethod<void>('delete');
}

abstract interface class OAuthTransport {
  Future<Map<String, dynamic>> post(String path, Map<String, String> values);
}

class HttpOAuthTransport implements OAuthTransport {
  HttpOAuthTransport({GitHubHttpTransport? http})
    : http = http ?? GitHubHttpTransport();
  final GitHubHttpTransport http;
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, String> values,
  ) async {
    if (path != '/login/device/code' && path != '/login/oauth/access_token') {
      throw const GitHubFailure('허용되지 않은 인증 주소입니다.');
    }
    try {
      final response = await http.send(
        'POST',
        Uri.https('github.com', path),
        headers: {
          'Accept': 'application/json',
          'User-Agent': 'IEUM-Desktop',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: Uri(queryParameters: values).query,
        maxBytes: 65536,
      );
      if (response.status != 200) {
        throw GitHubFailure(
          response.status == 407
              ? 'GitHub 인증 연결에 프록시 로그인이 필요합니다. Windows 프록시 설정을 확인하세요. (HTTP 407)'
              : 'GitHub 인증 서버가 요청을 처리하지 못했습니다. 잠시 후 다시 시도하세요. (HTTP ${response.status})',
          response.status,
        );
      }
      return Map<String, dynamic>.from(jsonDecode(response.text) as Map);
    } on GitHubFailure {
      rethrow;
    } catch (error) {
      // Never surface server payloads, device codes or tokens in exception text.
      throw GitHubFailure(githubNetworkMessage(error, authentication: true));
    } finally {
      http.close();
    }
  }
}

class DeviceGrant {
  DeviceGrant.fromJson(Map<String, dynamic> json, DateTime now)
    : deviceCode = json['device_code'] as String,
      userCode = json['user_code'] as String,
      expiresAt = now.add(Duration(seconds: json['expires_in'] as int)),
      interval = Duration(seconds: json['interval'] as int) {
    if (deviceCode.isEmpty ||
        !RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(userCode) ||
        json['verification_uri'] != githubDeviceUrl ||
        interval.inSeconds < 1 ||
        interval.inSeconds > 60 ||
        (json['expires_in'] as int) < 1 ||
        (json['expires_in'] as int) > 1800) {
      throw const GitHubFailure('GitHub 인증 응답을 확인하지 못했습니다.');
    }
  }
  final String deviceCode, userCode;
  final DateTime expiresAt;
  final Duration interval;
}

class OAuthTokens {
  OAuthTokens({
    required this.access,
    required this.scope,
    this.refresh = '',
    this.expiresAt,
    this.refreshExpiresAt,
  });
  factory OAuthTokens.fromResponse(Map<String, dynamic> json, DateTime now) {
    final access = json['access_token'];
    final refresh = json['refresh_token'] ?? '';
    final scope = json['scope'];
    if (access is! String ||
        access.isEmpty ||
        refresh is! String ||
        scope is! String ||
        !scope.split(RegExp(r'[ ,]+')).contains('repo') ||
        json['token_type'] != 'bearer') {
      throw const GitHubFailure('저장소 접근 승인이 필요합니다. GitHub에 다시 로그인하세요.');
    }
    DateTime? expiry(String key) {
      if (json[key] == null) return null;
      if (json[key] is! int || json[key] <= 0) {
        throw const GitHubFailure('인증 만료 정보를 확인하지 못했습니다.');
      }
      return now.add(Duration(seconds: json[key] as int));
    }

    final expires = expiry('expires_in');
    if (expires != null && refresh.isEmpty) {
      throw const GitHubFailure('인증 갱신 정보를 확인하지 못했습니다.');
    }
    return OAuthTokens(
      access: access,
      scope: scope,
      refresh: refresh,
      expiresAt: expires,
      refreshExpiresAt: expiry('refresh_token_expires_in'),
    );
  }
  factory OAuthTokens.fromStored(Map<String, dynamic> json) => OAuthTokens(
    access: json['access'] as String,
    scope: json['scope'] as String,
    refresh: json['refresh'] as String? ?? '',
    expiresAt: json['expiresAt'] == null
        ? null
        : DateTime.parse(json['expiresAt']),
    refreshExpiresAt: json['refreshExpiresAt'] == null
        ? null
        : DateTime.parse(json['refreshExpiresAt']),
  );
  final String access, refresh, scope;
  final DateTime? expiresAt, refreshExpiresAt;
  Map<String, dynamic> toJson() => {
    'access': access,
    'refresh': refresh,
    'scope': scope,
    'expiresAt': expiresAt?.toIso8601String(),
    'refreshExpiresAt': refreshExpiresAt?.toIso8601String(),
  };
}

class GitHubOAuth {
  GitHubOAuth({
    OAuthTransport? transport,
    OAuthVault? vault,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  }) : transport = transport ?? HttpOAuthTransport(),
       vault = vault ?? DesktopOAuthVault(),
       now = now ?? DateTime.now,
       delay = delay ?? Future<void>.delayed;
  final OAuthTransport transport;
  final OAuthVault vault;
  final DateTime Function() now;
  final Future<void> Function(Duration) delay;
  Future<DeviceGrant> start() async {
    final data = await transport.post('/login/device/code', {
      'client_id': githubOAuthClientId,
      'scope': 'repo offline_access',
    });
    if (data.containsKey('error')) {
      throw const GitHubFailure(
        'GitHub 로그인을 시작할 수 없습니다. 앱의 Device Flow 설정을 확인하세요.',
      );
    }
    return DeviceGrant.fromJson(data, now());
  }

  Future<OAuthTokens> poll(DeviceGrant grant, bool Function() cancelled) async {
    var interval = grant.interval;
    while (!cancelled() && now().isBefore(grant.expiresAt)) {
      await delay(interval);
      if (cancelled()) throw const GitHubFailure('로그인을 취소했습니다.');
      if (!now().isBefore(grant.expiresAt)) break;
      final data = await transport.post('/login/oauth/access_token', {
        'client_id': githubOAuthClientId,
        'device_code': grant.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      });
      if (cancelled()) throw const GitHubFailure('로그인을 취소했습니다.');
      switch (data['error']) {
        case null:
          return OAuthTokens.fromResponse(data, now());
        case 'authorization_pending':
          continue;
        case 'slow_down':
          final seconds = data['interval'];
          interval = Duration(
            seconds: seconds is int && seconds > interval.inSeconds
                ? seconds
                : interval.inSeconds + 5,
          );
          continue;
        case 'access_denied':
          throw const GitHubFailure('GitHub에서 로그인이 거절되었습니다. 다시 로그인하세요.');
        case 'expired_token':
          throw const GitHubFailure('인증 코드가 만료되었습니다. 다시 로그인하세요.');
        default:
          throw const GitHubFailure('GitHub 인증에 실패했습니다. 다시 로그인하세요.');
      }
    }
    throw GitHubFailure(
      cancelled() ? '로그인을 취소했습니다.' : '인증 코드가 만료되었습니다. 다시 로그인하세요.',
    );
  }

  Future<OAuthTokens> refresh(OAuthTokens current) async {
    if (current.refresh.isEmpty ||
        (current.refreshExpiresAt != null &&
            !now().isBefore(current.refreshExpiresAt!))) {
      throw const GitHubFailure('로그인이 만료되었습니다. GitHub에 다시 로그인하세요.', 401);
    }
    final data = await transport.post('/login/oauth/access_token', {
      'client_id': githubOAuthClientId,
      'grant_type': 'refresh_token',
      'refresh_token': current.refresh,
    });
    if (data.containsKey('error')) {
      throw const GitHubFailure('로그인이 만료되었습니다. GitHub에 다시 로그인하세요.', 401);
    }
    return OAuthTokens.fromResponse(data, now());
  }
}
