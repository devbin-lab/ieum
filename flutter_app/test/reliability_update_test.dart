import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_update.dart';

import 'github_transport_test.dart' show LocalGitHubClient;

void main() {
  for (final rejectCredential in [false, true]) {
    test(
      'public update works when ${rejectCredential ? 'GitHub rejects' : 'vault cannot supply'} the credential',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final authorization = <String?>[];
        server.listen((request) async {
          await request.drain<void>();
          final token = request.headers.value('authorization');
          authorization.add(token);
          if (token != null) {
            request.response.statusCode = 401;
            request.response.write('{}');
          } else {
            request.response.write(
              jsonEncode({
                'tag_name': 'v0.3.0',
                'draft': false,
                'prerelease': false,
                'assets': [
                  {
                    'name': 'Ieum-Windows-x64.exe',
                    'id': 1,
                    'size': 1,
                    'digest': 'sha256:${List.filled(64, 'a').join()}',
                  },
                ],
              }),
            );
          }
          await request.response.close();
        });
        final source = GitHubUpdateSource(
          'devbin-lab/ieum',
          credential: () async {
            if (!rejectCredential) {
              throw const SocketException('credential unavailable');
            }
            return 'revoked-fixture';
          },
          createClient: () => LocalGitHubClient(server.port),
        );
        try {
          expect((await source.latest())!.version.label, '0.3.0');
          expect(authorization.last, isNull);
          expect(authorization, hasLength(rejectCredential ? 2 : 1));
        } finally {
          await server.close(force: true);
        }
      },
    );
  }
}
