import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/discord_transport.dart';

const webhookId = '1558160679847075910';
const channelId = '1558164096040304721';
const guildId = '1549005513721774210';
const secret = 'test_token_never_printed_123456789';
const webhook = 'https://discord.com/api/webhooks/$webhookId/$secret';
const recipient = '1558164096040304000';

DiscordHttpReply reply(
  int status,
  Object body, {
  Map<String, String>? headers,
}) => DiscordHttpReply(
  status,
  headers ?? {},
  Uint8List.fromList(utf8.encode(jsonEncode(body))),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('webhook allowlist rejects credentials, redirects and other endpoints before I/O', () async {
    var requests = 0;
    final transport = DiscordWebhookTransport(
      request: (_) async {
        requests++;
        return reply(200, {});
      },
    );
    for (final url in [
      webhook.replaceFirst('https:', 'http:'),
      webhook.replaceFirst('discord.com', 'discord.com.evil.test'),
      webhook.replaceFirst('discord.com', 'someone@discord.com'),
      '$webhook?wait=false',
      '$webhook#fragment',
      '$webhook/messages/1558164096040304000',
      webhook.replaceFirst('/api/', '/api/v9/'),
      webhook.replaceFirst(webhookId, '18446744073709551616'),
      webhook.replaceFirst(secret, 'short'),
    ]) {
      await expectLater(
        transport.inspect(url),
        throwsA(isA<DiscordTransportFailure>()),
      );
    }
    expect(requests, 0);
    expect(
      parseDiscordWebhookUrl(webhook.replaceFirst('/api/', '/api/v10/')).host,
      'discord.com',
    );
  });

  test('inspect performs GET only and verifies incoming webhook and channel identity', () async {
    final requests = <DiscordHttpRequest>[];
    final transport = DiscordWebhookTransport(
      request: (request) async {
        requests.add(request);
        return reply(200, {
          'id': webhookId,
          'type': 1,
          'channel_id': channelId,
          'guild_id': guildId,
          'name': '이음 알림',
          'token': secret,
        });
      },
    );
    final info = await transport.inspect(webhook);
    expect(info.id, webhookId);
    expect(info.channelId, channelId);
    expect(info.name, '이음 알림');
    expect(requests.single.method, 'GET');
    expect(requests.single.body, isEmpty);
    expect(requests.single.followRedirects, isFalse);
    expect(requests.single.headers.containsKey('Authorization'), isFalse);
    expect(requests.single.toString(), isNot(contains(secret)));
  });

  test(
    'inspect rejects non-incoming webhooks and redacts exception payloads',
    () async {
      final invalid = DiscordWebhookTransport(
        request: (_) async => reply(200, {
          'id': webhookId,
          'type': 2,
          'channel_id': channelId,
          'guild_id': guildId,
          'name': 'application webhook',
        }),
      );
      await expectLater(
        invalid.inspect(webhook),
        throwsA(isA<DiscordTransportFailure>()),
      );
      final network = DiscordWebhookTransport(
        request: (_) async {
          throw Exception('Request failed at $webhook');
        },
      );
      try {
        await network.inspect(webhook);
        fail('Expected a redacted failure');
      } catch (error) {
        expect(error, isA<DiscordTransportFailure>());
        expect(error.toString(), isNot(contains(secret)));
        expect(error.toString(), isNot(contains('discord.com')));
      }
    },
  );

  test('send requires acknowledgement and restricts mentions to explicit deduplicated users', () async {
    final requests = <DiscordHttpRequest>[];
    final transport = DiscordWebhookTransport(
      request: (request) async {
        requests.add(request);
        return reply(200, {'id': '1558164096040304999'});
      },
    );
    final result = await transport.send(
      webhook,
      payload: {
        'content': '<@$recipient> 새 작업이 배정되었습니다. @everyone',
        'allowed_mentions': {
          'parse': ['everyone', 'roles', 'users'],
        },
      },
      userIds: [recipient, recipient],
    );
    expect(result.status, DiscordSendStatus.delivered);
    expect(result.messageId, '1558164096040304999');
    final request = requests.single;
    expect(request.method, 'POST');
    expect(request.uri.queryParameters, {'wait': 'true'});
    expect(request.followRedirects, isFalse);
    final body = jsonDecode(utf8.decode(request.body)) as Map;
    expect(body['allowed_mentions'], {
      'parse': [],
      'users': [recipient],
    });
  });

  test('only known 429 response supplies a safe retry delay, without retrying internally', () async {
    var requests = 0;
    final transport = DiscordWebhookTransport(
      request: (_) async {
        requests++;
        return reply(429, {'retry_after': 1.2345});
      },
    );
    final result = await transport.send(webhook, payload: {'content': '알림'});
    expect(result.status, DiscordSendStatus.retryable);
    expect(result.retryAfter, const Duration(milliseconds: 1235));
    expect(requests, 1);
    final badDelay = DiscordWebhookTransport(
      request: (_) async => reply(429, {'retry_after': 99999999}),
    );
    expect(
      (await badDelay.send(webhook, payload: {'content': '알림'})).status,
      DiscordSendStatus.failed,
    );
  });

  test(
    'lost replies, server errors and malformed acknowledgement stay uncertain',
    () async {
      for (final response in [
        reply(500, {'token': secret}),
        reply(204, {}),
        reply(200, {'id': 'not-a-message'}),
        DiscordHttpReply(200, {}, Uint8List.fromList([0xff])),
      ]) {
        var requests = 0;
        final transport = DiscordWebhookTransport(
          request: (_) async {
            requests++;
            return response;
          },
        );
        final result = await transport.send(
          webhook,
          payload: {'content': '알림'},
        );
        expect(result.status, DiscordSendStatus.uncertain);
        expect(result.retryAfter, isNull);
        expect(result.message, isNot(contains(secret)));
        expect(requests, 1);
      }
      final timeout = DiscordWebhookTransport(
        request: (_) async {
          throw TimeoutException('token=$secret');
        },
      );
      final result = await timeout.send(webhook, payload: {'content': '알림'});
      expect(result.status, DiscordSendStatus.uncertain);
      expect(result.message, isNot(contains(secret)));
    },
  );

  test('redirect and revoked webhook fail without following or exposing server errors', () async {
    for (final status in [302, 401, 403, 404]) {
      var requests = 0;
      final transport = DiscordWebhookTransport(
        request: (_) async {
          requests++;
          return reply(
            status,
            {'error': secret},
            headers: {'location': 'https://evil.test'},
          );
        },
      );
      final result = await transport.send(webhook, payload: {'content': '알림'});
      expect(result.status, DiscordSendStatus.failed);
      expect(result.message, isNot(contains(secret)));
      expect(requests, 1);
    }
  });

  test(
    'invalid and oversized content or mentions cannot reach the network',
    () async {
      var requests = 0;
      final transport = DiscordWebhookTransport(
        request: (_) async {
          requests++;
          return reply(200, {'id': channelId});
        },
      );
      for (final payload in <Map<String, Object?>>[
        {},
        {'content': 'a' * 2001},
        {'content': '알림', 'attachments': []},
        {'embeds': List.filled(11, {})},
        {
          'content': '알림',
          'embeds': [
            {'description': 'a' * 65536},
          ],
        },
      ]) {
        await expectLater(
          transport.send(webhook, payload: payload),
          throwsA(isA<DiscordTransportFailure>()),
        );
      }
      await expectLater(
        transport.send(
          webhook,
          payload: {'content': '알림'},
          userIds: ['@someone'],
        ),
        throwsA(isA<DiscordTransportFailure>()),
      );
      expect(requests, 0);
    },
  );

  test('native requests use the separate Discord channel with bounded response and explicit wait', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(DiscordWebhookTransport.channel, (
      call,
    ) async {
      calls.add(call);
      return {
        'status': 200,
        'headers': <String, String>{},
        'body': Uint8List.fromList(utf8.encode(jsonEncode({'id': channelId}))),
      };
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        DiscordWebhookTransport.channel,
        null,
      ),
    );
    final result = await DiscordWebhookTransport(nativeWindows: true)
        .send(webhook, payload: {'content': '알림'});
    expect(result.status, DiscordSendStatus.delivered);
    expect(DiscordWebhookTransport.channel.name, 'ieum/discord_http');
    final args = calls.single.arguments as Map;
    expect(args['maxBytes'], 65536);
    expect(args['method'], 'POST');
    expect(Uri.parse(args['url'] as String).queryParameters, {'wait': 'true'});
  });
}
