import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_http.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Object? failure;
  late int status;
  late String payload;
  setUp(() {
    calls = [];
    failure = null;
    status = 200;
    payload = '{}';
    messenger.setMockMethodCallHandler(GitHubHttpTransport.channel, (
      call,
    ) async {
      calls.add(call);
      if (failure != null) throw failure!;
      return {
        'status': status,
        'headers': <String, String>{},
        'body': Uint8List.fromList(utf8.encode(payload)),
      };
    });
  });
  tearDown(
    () => messenger.setMockMethodCallHandler(GitHubHttpTransport.channel, null),
  );

  test('OAuth uses the Windows bridge and only sends form data to the fixed endpoint', () async {
    payload = '{"error":"incorrect_client_credentials"}';
    final oauth = HttpOAuthTransport(
      http: GitHubHttpTransport(nativeWindows: true),
    );
    expect(await oauth.post('/login/device/code', {'client_id': 'test-only'}), {
      'error': 'incorrect_client_credentials',
    });
    final sent = calls.single.arguments as Map;
    expect(sent['url'], 'https://github.com/login/device/code');
    expect(sent['method'], 'POST');
    expect(sent['maxBytes'], 65536);
    expect(utf8.decode(sent['body'] as Uint8List), 'client_id=test-only');
    expect((sent['headers'] as Map).containsKey('Authorization'), isFalse);
  });

  test(
    'authentication errors identify the cause without leaking native payloads',
    () async {
      final oauth = HttpOAuthTransport(
        http: GitHubHttpTransport(nativeWindows: true),
      );
      for (final entry in {
        12002: '시간',
        12007: 'DNS',
        12029: '방화벽',
        12175: '인증서',
        12180: '프록시',
      }.entries) {
        failure = PlatformException(
          code: 'winhttp_${entry.key}',
          message: 'secret-token-and-device-code',
          details: 'secret-response',
        );
        try {
          await oauth.post('/login/device/code', {'client_id': 'test'});
          fail('Expected transport failure');
        } on GitHubFailure catch (error) {
          expect(error.message, contains(entry.value));
          expect(error.message, contains('${entry.key}'));
          expect(error.message, isNot(contains('secret')));
        }
      }
    },
  );

  test(
    'proxy authentication and non-JSON block pages have separate explanations',
    () async {
      final oauth = HttpOAuthTransport(
        http: GitHubHttpTransport(nativeWindows: true),
      );
      status = 407;
      payload = '<html>private proxy login</html>';
      await expectLater(
        oauth.post('/login/device/code', {}),
        throwsA(
          isA<GitHubFailure>()
              .having((e) => e.status, 'status', 407)
              .having((e) => e.message, 'message', contains('프록시 로그인')),
        ),
      );
      status = 200;
      await expectLater(
        oauth.post('/login/device/code', {}),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'message',
            contains('응답 형식'),
          ),
        ),
      );
      payload = '["not an object"]';
      await expectLater(
        oauth.post('/login/device/code', {}),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'message',
            contains('응답 형식'),
          ),
        ),
      );
    },
  );

  test('untrusted destinations, non-HTTPS and fragments never reach native transport', () async {
    final http = GitHubHttpTransport(nativeWindows: true);
    for (final url in [
      'https://evil.example/token',
      'http://api.github.com/user',
      'https://github.com/login',
      'https://user@api.github.com/user',
      'https://api.github.com:444/user',
      'https://api.github.com/user#secret',
    ]) {
      await expectLater(
        http.send('POST', Uri.parse(url), headers: {}),
        throwsFormatException,
      );
    }
    expect(calls, isEmpty);
  });

  test(
    'response bodies are bounded and missing bridge has an actionable message',
    () async {
      final http = GitHubHttpTransport(nativeWindows: true);
      payload = 'too large';
      await expectLater(
        http.send(
          'GET',
          Uri.https('api.github.com', '/meta'),
          headers: {},
          maxBytes: 2,
        ),
        throwsFormatException,
      );
      expect(
        githubNetworkMessage(MissingPluginException()),
        contains('최신 설치 파일'),
      );
      expect(
        githubNetworkMessage(const HandshakeException('secret')),
        contains('인증서'),
      );
      expect(githubNetworkMessage(TimeoutException('secret')), contains('시간'));
      expect(
        githubNetworkMessage(const SocketException('secret')),
        contains('DNS'),
      );
    },
  );

  test(
    'Dart transport reports the same safe auth errors without a native module',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.write('{"error":"incorrect_client_credentials"}');
        await request.response.close();
      });
      final oauth = HttpOAuthTransport(
        http: GitHubHttpTransport(
          createClient: () => _LocalClient(server.port),
          nativeWindows: false,
        ),
      );
      try {
        expect(await oauth.post('/login/device/code', {'client_id': 'test'}), {
          'error': 'incorrect_client_credentials',
        });
      } finally {
        await server.close(force: true);
      }
    },
  );
}

class _LocalClient implements HttpClient {
  _LocalClient(this.port);
  final int port;
  final inner = HttpOverrides.runWithHttpOverrides(
    HttpClient.new,
    _RealHttpOverrides(),
  );
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) => inner.openUrl(
    method,
    uri.replace(scheme: 'http', host: '127.0.0.1', port: port),
  );
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RealHttpOverrides extends HttpOverrides {}
