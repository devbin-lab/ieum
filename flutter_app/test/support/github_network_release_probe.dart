import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ieum_flutter/github_http.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';

import 'task_registration_release_probe.dart' as registration;

/// Native Release bridge check: no login grant, credentials or live task data.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final marker = Platform.environment['IEUM_REGISTRATION_PROBE_RESULT'];
  final http = GitHubHttpTransport(nativeWindows: true);
  try {
    final response = await http.send(
      'GET',
      Uri.https('api.github.com', '/meta'),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'IEUM-Desktop',
      },
    );
    if (response.status != 200 || jsonDecode(response.text) is! Map) {
      throw StateError('GitHub API connectivity failed');
    }
    // An invalid diagnostic client must return an error without creating a grant.
    try {
      final data = await HttpOAuthTransport(http: http).post(
        '/login/device/code',
        {'client_id': 'ieum-invalid-diagnostic-client'},
      );
      if (data['error'] is! String ||
          data.containsKey('device_code') ||
          data.containsKey('access_token')) {
        throw StateError('OAuth response check failed');
      }
    } on GitHubFailure catch (error) {
      // Invalid clients produce HTTP 404 instead of a login grant.
      if (error.status != 400 && error.status != 404) rethrow;
    }
    registration.main();
  } catch (error) {
    if (marker != null) {
      File(marker).writeAsStringSync(
        'network-failed: ${error is GitHubFailure ? error.message : error.runtimeType}',
      );
    }
    exit(1);
  } finally {
    http.close();
  }
}
