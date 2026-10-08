import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// JSON requests only. Downloads keep their streaming transport.
class GitHubHttpReply {
  const GitHubHttpReply(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
  String get text => utf8.decode(bytes);
}

class GitHubHttpTransport {
  GitHubHttpTransport({
    HttpClient Function()? createClient,
    bool? nativeWindows,
  }) : _createClient = createClient,
       _nativeWindows =
           nativeWindows ?? (Platform.isWindows && createClient == null);

  static const channel = MethodChannel('ieum/github_http');
  final HttpClient Function()? _createClient;
  final bool _nativeWindows;
  HttpClient? _client;

  void close() {
    _client?.close();
    _client = null;
  }

  Future<GitHubHttpReply> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    String body = '',
    int maxBytes = 32 * 1024 * 1024,
  }) async {
    final oauth =
        uri.host == 'github.com' &&
        const [
          '/login/device/code',
          '/login/oauth/access_token',
        ].contains(uri.path);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.port != 443 ||
        uri.fragment.isNotEmpty ||
        !(uri.host == 'api.github.com' || oauth) ||
        (oauth && method != 'POST') ||
        !const [
          'GET',
          'POST',
          'PUT',
          'PATCH',
          'DELETE',
          'HEAD',
        ].contains(method) ||
        maxBytes < 1 ||
        maxBytes > 32 * 1024 * 1024) {
      throw const FormatException('허용되지 않은 GitHub 요청입니다.');
    }
    if (_nativeWindows) {
      final result = await channel.invokeMapMethod<String, dynamic>('request', {
        'method': method,
        'url': uri.toString(),
        'headers': headers,
        'body': Uint8List.fromList(utf8.encode(body)),
        'maxBytes': maxBytes,
      });
      if (result == null ||
          result['status'] is! int ||
          result['body'] is! Uint8List ||
          result['headers'] is! Map) {
        throw const FormatException('GitHub 통신 응답을 확인하지 못했습니다.');
      }
      final bytes = result['body'] as Uint8List;
      if (bytes.length > maxBytes) throw const FormatException('응답 크기 초과');
      return GitHubHttpReply(
        result['status'] as int,
        Map<String, String>.from(result['headers'] as Map),
        bytes,
      );
    }

    final client = _client ??=
        (_createClient?.call() ??
              (HttpClient()..findProxy = HttpClient.findProxyFromEnvironment))
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 15);
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body.isNotEmpty) request.add(utf8.encode(body));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > maxBytes) {
        client.close(force: true);
        _client = null;
        throw const FormatException('응답 크기 초과');
      }
      bytes.add(chunk);
    }
    final values = <String, String>{};
    response.headers.forEach(
      (name, value) => values[name.toLowerCase()] = value.join(', '),
    );
    return GitHubHttpReply(response.statusCode, values, bytes.takeBytes());
  }
}

/// Never includes raw exception text, server payloads, credentials or URLs.
String githubNetworkMessage(Object error, {bool authentication = false}) {
  final prefix = authentication ? 'GitHub 인증' : 'GitHub';
  if (error is PlatformException) {
    final code = int.tryParse(error.code.replaceFirst('winhttp_', ''));
    return switch (code) {
      12002 => '$prefix 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요. (12002)',
      12007 => '$prefix 서버 주소를 찾지 못했습니다. DNS·프록시 설정을 확인하세요. (12007)',
      12029 || 12030 => '$prefix 서버 연결에 실패했습니다. 방화벽·프록시 설정을 확인하세요. ($code)',
      12037 || 12038 || 12044 || 12045 || 12057 || 12157 || 12175 =>
        '$prefix 보안 인증서 확인에 실패했습니다. PC 날짜·시간과 보안 프로그램·인증서 설정을 확인하세요. ($code)',
      12166 ||
      12167 ||
      12178 ||
      12180 => '$prefix 프록시 설정을 적용하지 못했습니다. Windows 프록시 설정을 확인하세요. ($code)',
      12152 => '$prefix 서버 응답이 올바르지 않거나 너무 큽니다. 프록시·보안 프로그램 설정을 확인하세요. (12152)',
      _ =>
        '$prefix 통신을 처리하지 못했습니다. 앱을 다시 실행하세요.${code == null ? '' : ' ($code)'}',
    };
  }
  if (error is HandshakeException || error is TlsException) {
    return '$prefix 보안 인증서 확인에 실패했습니다. PC 날짜·시간과 보안 프로그램·인증서 설정을 확인하세요.';
  }
  if (error is TimeoutException) {
    return '$prefix 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요.';
  }
  if (error is SocketException) {
    return '$prefix 서버에 연결하지 못했습니다. DNS·방화벽·프록시 설정을 확인하세요.';
  }
  if (error is FormatException || error is TypeError) {
    return '$prefix 응답 형식이 올바르지 않습니다. 보안 프로그램·프록시의 접속 차단 여부를 확인하세요.';
  }
  if (error is HttpException) {
    return '$prefix 서버 응답을 받는 중 연결이 중단되었습니다. 프록시·보안 프로그램 설정을 확인하세요.';
  }
  if (error is MissingPluginException) {
    return '$prefix 통신 모듈이 없습니다. 최신 설치 파일로 다시 설치하세요.';
  }
  return '$prefix 통신을 처리하지 못했습니다. 최신 설치 파일로 다시 실행하세요.';
}
