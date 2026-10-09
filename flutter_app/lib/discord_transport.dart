import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

bool isDiscordSnowflake(String value) =>
    RegExp(r'^[0-9]{17,20}$').hasMatch(value) &&
    BigInt.parse(value) > BigInt.zero &&
    BigInt.parse(value) <= BigInt.parse('18446744073709551615');

/// Validates a channel incoming-webhook URL without contacting Discord.
Uri parseDiscordWebhookUrl(String value) {
  Uri? uri;
  try {
    if (value.length <= 1024) uri = Uri.tryParse(value.trim());
  } catch (_) {
    // Parser errors can include the token-bearing input. Never surface them.
  }
  if (uri == null ||
      uri.scheme != 'https' ||
      !const {'discord.com', 'discordapp.com'}.contains(uri.host) ||
      uri.port != 443 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !RegExp(r'^/api/(?:v10/)?webhooks/[0-9]{17,20}/[A-Za-z0-9_-]{16,256}$')
          .hasMatch(uri.path) ||
      uri.path.contains('%') ||
      !isDiscordSnowflake(uri.pathSegments[uri.pathSegments.length - 2])) {
    throw const DiscordTransportFailure('Discord 채널의 웹훅 URL을 입력하세요.');
  }
  return uri;
}

class DiscordTransportFailure implements Exception {
  const DiscordTransportFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class DiscordWebhookInfo {
  const DiscordWebhookInfo({
    required this.id,
    required this.channelId,
    required this.name,
    this.guildId,
  });
  final String id, channelId, name;
  final String? guildId;
}

enum DiscordSendStatus { delivered, retryable, failed, uncertain }

class DiscordSendResult {
  const DiscordSendResult(
    this.status,
    this.message, {
    this.messageId,
    this.retryAfter,
  });
  final DiscordSendStatus status;
  final String message;
  final String? messageId;
  final Duration? retryAfter;
}

/// Injectable request boundary for tests. URL and body stay out of diagnostics.
class DiscordHttpRequest {
  const DiscordHttpRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
    this.maxBytes = 65536,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List body;
  final int maxBytes;
  bool get followRedirects => false;
  @override
  String toString() => 'DiscordHttpRequest($method)';
}

class DiscordHttpReply {
  const DiscordHttpReply(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, String> headers;
  final Uint8List bytes;
}

typedef DiscordRequest = Future<DiscordHttpReply> Function(
  DiscordHttpRequest request,
);

class DiscordWebhookTransport {
  DiscordWebhookTransport({
    DiscordRequest? request,
    HttpClient Function()? createClient,
    bool? nativeWindows,
  }) : _request = request,
       _createClient = createClient,
       _nativeWindows =
           nativeWindows ??
           (Platform.isWindows && request == null && createClient == null);

  static const channel = MethodChannel('ieum/discord_http');
  final DiscordRequest? _request;
  final HttpClient Function()? _createClient;
  final bool _nativeWindows;
  HttpClient? _client;

  void close() {
    _client?.close(force: true);
    _client = null;
  }

  /// GET reads the existing incoming webhook; it sends no test notification.
  Future<DiscordWebhookInfo> inspect(String webhookUrl) async {
    final uri = parseDiscordWebhookUrl(webhookUrl);
    DiscordHttpReply reply;
    try {
      reply = await _send('GET', uri);
    } catch (_) {
      throw const DiscordTransportFailure(
        'Discord 연결을 확인하지 못했습니다. 잠시 후 다시 시도하세요.',
      );
    }
    if (reply.status != 200) {
      throw DiscordTransportFailure(
        _failureMessage(reply.status),
        status: reply.status,
      );
    }
    try {
      final data = jsonDecode(utf8.decode(reply.bytes)) as Map;
      final id = data['id'];
      final channelId = data['channel_id'];
      final guildId = data['guild_id'];
      final name = data['name'];
      if (data['type'] != 1 ||
          id is! String ||
          id != uri.pathSegments[uri.pathSegments.length - 2] ||
          channelId is! String ||
          !isDiscordSnowflake(channelId) ||
          guildId is! String ||
          !isDiscordSnowflake(guildId) ||
          name is! String ||
          name.length > 120) {
        throw const FormatException();
      }
      return DiscordWebhookInfo(
        id: id,
        channelId: channelId,
        guildId: guildId,
        name: name,
      );
    } catch (_) {
      throw const DiscordTransportFailure('Discord 채널 웹훅 정보를 확인하지 못했습니다.');
    }
  }

  /// Known 429 replies can be retried after retryAfter. Other ambiguous sends
  /// require an explicit retry; a lost reply does not mean the send failed.
  Future<DiscordSendResult> send(
    String webhookUrl, {
    required Map<String, Object?> payload,
    List<String> userIds = const [],
  }) async {
    final uri = parseDiscordWebhookUrl(webhookUrl);
    final ids = userIds.toSet().toList();
    if (ids.length > 100 || ids.any((id) => !isDiscordSnowflake(id))) {
      throw const DiscordTransportFailure('Discord 멘션 대상이 올바르지 않습니다.');
    }
    // Callers may supply allowed_mentions, but can never enable broad mentions.
    final safePayload = <String, Object?>{
      ...payload,
      'allowed_mentions': {'parse': <String>[], 'users': ids},
    };
    Uint8List body;
    try {
      if (safePayload.keys.any(
        (key) => !const {
          'content',
          'embeds',
          'username',
          'avatar_url',
          'allowed_mentions',
        }.contains(key),
      )) {
        throw const FormatException();
      }
      final content = safePayload['content'];
      final embeds = safePayload['embeds'];
      if ((content != null && (content is! String || content.length > 2000)) ||
          (embeds != null && (embeds is! List || embeds.length > 10)) ||
          ((content == null || content == '') &&
              (embeds == null || (embeds as List).isEmpty))) {
        throw const FormatException();
      }
      body = Uint8List.fromList(utf8.encode(jsonEncode(safePayload)));
      if (body.length > 65536) throw const FormatException();
    } catch (_) {
      throw const DiscordTransportFailure('Discord 알림 내용의 형식이나 크기가 올바르지 않습니다.');
    }
    DiscordHttpReply reply;
    try {
      reply = await _send(
        'POST',
        uri.replace(queryParameters: {'wait': 'true'}),
        body,
      );
    } catch (_) {
      return const DiscordSendResult(
        DiscordSendStatus.uncertain,
        'Discord 수신 여부를 확인하지 못했습니다. 채널을 확인한 뒤 다시 전송하세요.',
      );
    }
    if (reply.status == 429) {
      final delay = _retryAfter(reply);
      if (delay == null) {
        return const DiscordSendResult(
          DiscordSendStatus.failed,
          'Discord 전송 제한의 대기 시간을 확인하지 못했습니다. 잠시 후 다시 시도하세요.',
        );
      }
      return DiscordSendResult(
        DiscordSendStatus.retryable,
        'Discord 전송 제한으로 잠시 대기합니다.',
        retryAfter: delay,
      );
    }
    if (reply.status >= 500 && reply.status <= 599) {
      return const DiscordSendResult(
        DiscordSendStatus.uncertain,
        'Discord 수신 여부를 확인하지 못했습니다. 채널을 확인한 뒤 다시 전송하세요.',
      );
    }
    if (reply.status >= 200 && reply.status < 300 && reply.status != 200) {
      return const DiscordSendResult(
        DiscordSendStatus.uncertain,
        'Discord 수신 응답을 확인하지 못했습니다. 채널을 확인한 뒤 다시 전송하세요.',
      );
    }
    if (reply.status != 200) {
      return DiscordSendResult(
        DiscordSendStatus.failed,
        _failureMessage(reply.status),
      );
    }
    try {
      final data = jsonDecode(utf8.decode(reply.bytes)) as Map;
      final id = data['id'];
      if (id is! String || !isDiscordSnowflake(id)) {
        throw const FormatException();
      }
      return DiscordSendResult(
        DiscordSendStatus.delivered,
        'Discord 알림을 전송했습니다.',
        messageId: id,
      );
    } catch (_) {
      return const DiscordSendResult(
        DiscordSendStatus.uncertain,
        'Discord 수신 응답을 확인하지 못했습니다. 채널을 확인한 뒤 다시 전송하세요.',
      );
    }
  }

  Future<DiscordHttpReply> _send(
    String method,
    Uri uri, [
    Uint8List? body,
  ]) async {
    final request = DiscordHttpRequest(
      method: method,
      uri: uri,
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': 'IEUM-Desktop',
      },
      body: body ?? Uint8List(0),
    );
    final injected = _request;
    DiscordHttpReply reply;
    if (injected != null) {
      reply = await injected(request).timeout(const Duration(seconds: 40));
    } else if (_nativeWindows) {
      final result = await channel
          .invokeMapMethod<String, dynamic>('request', {
            'method': request.method,
            'url': request.uri.toString(),
            'headers': request.headers,
            'body': request.body,
            'maxBytes': request.maxBytes,
          })
          .timeout(const Duration(seconds: 65));
      if (result == null ||
          result['status'] is! int ||
          result['headers'] is! Map ||
          result['body'] is! Uint8List) {
        throw const DiscordTransportFailure('Discord 통신 응답을 확인하지 못했습니다.');
      }
      reply = DiscordHttpReply(
        result['status'] as int,
        Map<String, String>.from(result['headers'] as Map),
        result['body'] as Uint8List,
      );
    } else {
      reply = await _dartRequest(request).timeout(
        const Duration(seconds: 65),
        onTimeout: () {
          close();
          throw TimeoutException('Discord request timed out');
        },
      );
    }
    if (reply.bytes.length > request.maxBytes ||
        reply.status < 100 ||
        reply.status > 599) {
      throw const DiscordTransportFailure('Discord 응답 크기나 형식이 올바르지 않습니다.');
    }
    return reply;
  }

  Future<DiscordHttpReply> _dartRequest(DiscordHttpRequest data) async {
    final client = _client ??=
        (_createClient?.call() ??
              (HttpClient()..findProxy = HttpClient.findProxyFromEnvironment))
          ..connectionTimeout = const Duration(seconds: 15)
          ..idleTimeout = const Duration(seconds: 15);
    final request = await client
        .openUrl(data.method, data.uri)
        .timeout(const Duration(seconds: 20));
    request.followRedirects = false;
    data.headers.forEach(request.headers.set);
    if (data.body.isNotEmpty) request.add(data.body);
    final response = await request.close().timeout(const Duration(seconds: 30));
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > data.maxBytes) {
        close();
        throw const DiscordTransportFailure('Discord 응답 크기를 초과했습니다.');
      }
      bytes.add(chunk);
    }
    final headers = <String, String>{};
    response.headers.forEach(
      (name, values) => headers[name.toLowerCase()] = values.join(', '),
    );
    return DiscordHttpReply(response.statusCode, headers, bytes.takeBytes());
  }

  Duration? _retryAfter(DiscordHttpReply reply) {
    num? seconds;
    try {
      final value =
          (jsonDecode(utf8.decode(reply.bytes)) as Map)['retry_after'];
      if (value is num) seconds = value;
    } catch (_) {
      // Rate-limit headers are safe to use when the JSON body is unavailable.
    }
    seconds ??= num.tryParse(reply.headers['retry-after'] ?? '');
    if (seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        seconds > 86400) {
      return null;
    }
    return Duration(
      milliseconds: (seconds * 1000).ceil().clamp(1000, 86400000),
    );
  }

  String _failureMessage(int status) => switch (status) {
    401 || 403 || 404 => 'Discord 웹훅을 사용할 수 없습니다. 채널 연결을 다시 확인하세요.',
    429 => 'Discord 전송 제한에 도달했습니다. 잠시 후 다시 시도하세요.',
    >= 300 && < 400 => 'Discord가 다른 주소로 연결을 요청해 전송을 중단했습니다.',
    _ => 'Discord 요청을 처리하지 못했습니다. (HTTP $status)',
  };
}
