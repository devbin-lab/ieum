import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_sync.dart';

// Keep the actual Dart connection pool, redirecting only the destination to a
// local HTTP server so these tests need neither GitHub access nor credentials.
class LocalGitHubClient implements HttpClient {
  LocalGitHubClient(this.port);
  final int port;
  final HttpClient inner = HttpClient();
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) => inner.openUrl(
    method,
    url.replace(scheme: 'http', host: '127.0.0.1', port: port),
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

void main() {
  test(
    'sequential requests reuse TCP connection but refresh credentials',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final ports = <int>[];
      final credentials = <String?>[];
      server.listen((request) async {
        ports.add(request.connectionInfo!.remotePort);
        credentials.add(request.headers.value('authorization'));
        await request.drain<void>();
        request.response.write(jsonEncode({'ok': true}));
        await request.response.close();
      });
      var clients = 0, tokens = 0;
      final api = HttpGitHubApi(
        () async => 'token-${++tokens}',
        createClient: () {
          clients++;
          return LocalGitHubClient(server.port);
        },
      );
      try {
        await api.call('GET', '/user');
        await api.call(
          'POST',
          '/repos/team/data/pulls',
          body: {'title': 'test'},
        );
        expect(clients, 1);
        expect(ports, hasLength(2));
        expect(ports.toSet(), hasLength(1));
        expect(credentials, ['Bearer token-1', 'Bearer token-2']);
        api.close();
        await api.call('GET', '/user');
        expect(clients, 2);
        expect(credentials.last, 'Bearer token-3');
      } finally {
        api.close();
        await server.close(force: true);
      }
    },
  );

  test(
    'pooled connections preserve rate-limit errors and recover next request',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (++requests == 1) {
          request.response.statusCode = 429;
          request.response.headers.set('retry-after', '40');
        }
        request.response.write('{}');
        await request.response.close();
      });
      final api = HttpGitHubApi(
        () async => 'test-token',
        createClient: () => LocalGitHubClient(server.port),
      );
      try {
        await expectLater(
          api.call('GET', '/user'),
          throwsA(
            isA<GitHubFailure>()
                .having((error) => error.status, 'status', 429)
                .having(
                  (error) => error.retryAfter,
                  'retryAfter',
                  const Duration(seconds: 40),
                ),
          ),
        );
        expect(await api.call('GET', '/user'), isEmpty);
      } finally {
        api.close();
        await server.close(force: true);
      }
    },
  );
}
