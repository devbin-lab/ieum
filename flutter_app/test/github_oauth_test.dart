import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_gate.dart';
import 'package:ieum_flutter/project_service.dart';
import 'package:ieum_flutter/store.dart';

import 'github_sync_test.dart' show FakeGitHubApi;

class MemoryVault implements OAuthVault {
  String? value;
  int writes = 0;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String data) async {
    value = data;
    writes++;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

class ScriptedOAuth implements OAuthTransport {
  final responses = <Map<String, dynamic>>[];
  final calls = <({String path, Map<String, String> body})>[];
  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, String> values,
  ) async {
    calls.add((path: path, body: values));
    return responses.removeAt(0);
  }
}

Map<String, dynamic> device({int seconds = 900}) => {
  'device_code': 'test-device-secret',
  'user_code': 'ABCD-EFGH',
  'verification_uri': githubDeviceUrl,
  'expires_in': seconds,
  'interval': 5,
};
Map<String, dynamic> tokens(String suffix, {int? seconds = 28800}) => {
  'access_token': 'test-access-$suffix',
  'refresh_token': 'test-refresh-$suffix',
  'token_type': 'bearer',
  'scope': 'repo',
  'expires_in': ?seconds,
  'refresh_token_expires_in': 15897600,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryVault vault;
  late ScriptedOAuth transport;
  late GitHubOAuth oauth;
  late FakeGitHubApi api;
  late GitHubSession session;
  late DateTime time;
  late List<int> waits;
  setUp(() {
    time = DateTime.utc(2026, 10, 1);
    waits = [];
    vault = MemoryVault();
    transport = ScriptedOAuth();
    api = FakeGitHubApi();
    oauth = GitHubOAuth(
      transport: transport,
      vault: vault,
      now: () => time,
      delay: (duration) async {
        waits.add(duration.inSeconds);
        time = time.add(duration);
      },
    );
    session = GitHubSession(api: api, oauth: oauth);
  });
  tearDown(() => session.signOut());
  Future<void> login({bool remember = true}) async {
    transport.responses.addAll([device(), tokens('first')]);
    await session.signInOAuth(remember: remember, onCode: (_) {});
  }

  test('device pending and slowdown respect polling interval; no client secret is sent', () async {
    transport.responses.addAll([
      device(),
      {'error': 'authorization_pending'},
      {'error': 'slow_down', 'interval': 10},
      tokens('ok'),
    ]);
    final grant = await oauth.start();
    final result = await oauth.poll(grant, () => false);
    expect(waits, [5, 5, 10]);
    expect(result.access, 'test-access-ok');
    expect(transport.calls.first.body['scope'], 'repo offline_access');
    expect(
      transport.calls.every((c) => !c.body.containsKey('client_secret')),
      isTrue,
    );
    expect(
      transport.calls.last.body['grant_type'],
      'urn:ietf:params:oauth:grant-type:device_code',
    );
  });
  test('cancellation and expiry stop polling without token storage', () async {
    transport.responses.add(device(seconds: 5));
    final grant = await oauth.start();
    await expectLater(
      oauth.poll(grant, () => false),
      throwsA(isA<GitHubFailure>()),
    );
    expect(transport.calls, hasLength(1));
    await expectLater(
      oauth.poll(grant, () => true),
      throwsA(isA<GitHubFailure>()),
    );
    expect(vault.value, isNull);
  });
  test(
    'denied, unexpected URL and insufficient scopes are rejected safely',
    () async {
      transport.responses.addAll([
        device(),
        {'error': 'access_denied', 'error_description': 'secret'},
      ]);
      final grant = await oauth.start();
      await expectLater(
        oauth.poll(grant, () => false),
        throwsA(
          isA<GitHubFailure>().having(
            (e) => e.message,
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
      expect(
        () => DeviceGrant.fromJson({
          ...device(),
          'verification_uri': 'https://evil.test',
        }, time),
        throwsA(isA<GitHubFailure>()),
      );
      expect(
        () => OAuthTokens.fromResponse({
          ...tokens('x'),
          'scope': 'read:user',
        }, time),
        throwsA(isA<GitHubFailure>()),
      );
    },
  );
  test(
    'remembered identity restores, while logout removes only credentials',
    () async {
      await login();
      expect(session.user!.id, 'gh-1');
      expect(jsonDecode(vault.value!)['userId'], 'gh-1');
      expect(vault.writes, 1);
      session.signOut(); // Closing the app is not an explicit logout.
      expect(vault.value, isNotNull);
      expect(await session.restoreOAuth(), isTrue);
      expect(session.sessionToken, 'test-access-first');
      await session.logout();
      expect(vault.value, isNull);
      expect(session.user, isNull);
      await expectLater(session.credential(), throwsA(isA<GitHubFailure>()));
    },
  );
  test('memory-only login never writes credentials', () async {
    await login(remember: false);
    expect(vault.writes, 0);
    expect(vault.value, isNull);
    session.signOut();
    expect(await session.restoreOAuth(), isFalse);
  });
  test(
    'temporary restore network failure keeps the vault for a later retry',
    () async {
      await login();
      session.signOut();
      final original = vault.value;
      session = GitHubSession(api: FailingIdentityApi(), oauth: oauth);
      await expectLater(session.restoreOAuth(), throwsA(isA<GitHubFailure>()));
      expect(session.user, isNull);
      expect(vault.value, original);
      session = GitHubSession(api: api, oauth: oauth);
      expect(await session.restoreOAuth(), isTrue);
    },
  );
  test(
    'restore never accepts a different GitHub account or a malformed vault',
    () async {
      await login();
      session.signOut();
      api.identityId = 2;
      await expectLater(session.restoreOAuth(), throwsA(isA<GitHubFailure>()));
      expect(session.user, isNull);
      expect(vault.value, isNull);
      vault.value = 'malformed';
      await expectLater(session.restoreOAuth(), throwsA(isA<GitHubFailure>()));
      expect(vault.value, isNull);
    },
  );
  test(
    'concurrent expiration refreshes once and rotates the stored token',
    () async {
      await login();
      time = time.add(const Duration(hours: 8));
      transport.responses.add(tokens('renewed'));
      final results = await Future.wait([
        session.credential(),
        session.credential(),
        session.oauthCredential(),
      ]);
      expect(results, everyElement('test-access-renewed'));
      expect(
        transport.calls.where((c) => c.body['grant_type'] == 'refresh_token'),
        hasLength(1),
      );
      expect(
        jsonDecode(vault.value!)['tokens']['refresh'],
        'test-refresh-renewed',
      );
    },
  );
  test('expired saved login refreshes before account validation and persists new pair', () async {
    await login();
    session.signOut();
    time = time.add(const Duration(hours: 8));
    transport.responses.add(tokens('restored'));
    // Fake API does not call credential itself; mimic the real HTTP token callback.
    final realCallbackApi = CredentialApi(api, () => session.credential());
    session = GitHubSession(api: realCallbackApi, oauth: oauth);
    expect(await session.restoreOAuth(), isTrue);
    expect(
      jsonDecode(vault.value!)['tokens']['access'],
      'test-access-restored',
    );
  });
  test(
    'expired refresh or changed identity clears the persisted login',
    () async {
      await login();
      time = time.add(const Duration(hours: 8));
      transport.responses.add({'error': 'bad_refresh_token'});
      await expectLater(session.credential(), throwsA(isA<GitHubFailure>()));
      expect(vault.value, isNull);
      expect(session.user, isNull);
      await login();
      time = time.add(const Duration(hours: 8));
      transport.responses.add(tokens('wrong-account'));
      api.identityId = 2;
      await expectLater(session.credential(), throwsA(isA<GitHubFailure>()));
      expect(vault.value, isNull);
    },
  );
  test('cancelling after device request prevents a late login from being persisted', () async {
    transport.responses.add(device());
    await expectLater(
      session.signInOAuth(remember: true, onCode: (_) => session.signOut()),
      throwsA(isA<GitHubFailure>()),
    );
    expect(vault.value, isNull);
    expect(session.user, isNull);
  });
  test('native vault uses fixed channel operations; secrets do not enter preferences', () async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(WindowsOAuthVault.channel, (call) async {
      calls.add(call);
      return call.method == 'read' ? 'vault-only' : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(WindowsOAuthVault.channel, null),
    );
    final native = WindowsOAuthVault();
    expect(await native.read(), 'vault-only');
    await native.write('credential');
    await native.delete();
    expect(calls.map((c) => c.method), ['read', 'write', 'delete']);
    expect(calls[1].arguments, 'credential');
  });
  testWidgets(
    'OAuth login UI fits small window, shows code and supports cancel without native control',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('ieum-oauth-ui-');
      final store = TaskStore(':memory:');
      addTearDown(() {
        store.dispose();
        directory.deleteSync(recursive: true);
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async => call.method == 'isMaximized' ? false : null,
      );
      final wait = Completer<void>();
      oauth = GitHubOAuth(
        transport: transport,
        vault: vault,
        delay: (_) => wait.future,
      );
      session = GitHubSession(api: api, oauth: oauth);
      transport.responses.add(device());
      tester.view.physicalSize = const Size(1160, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Stub the native launcher so testing does not open or focus the user's browser.
      await tester.pumpWidget(
        IeumApp(
          store: store,
          home: ProjectGate(
            session: session,
            preferences: File('${directory.path}/preferences.json'),
            openBrowser: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-token')), findsNothing);
      await tester.tap(find.byKey(const Key('github-login')));
      await tester.pumpAndSettle();
      expect(find.text('ABCD-EFGH'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('oauth-cancel')));
      await tester.tap(find.byKey(const Key('oauth-cancel')));
      wait.complete();
      await tester.pumpAndSettle();
      expect(session.user, isNull);
      expect(vault.value, isNull);
      expect(find.text('로그인을 취소했습니다.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class CredentialApi implements GitHubApi {
  CredentialApi(this.delegate, this.credential);
  final GitHubApi delegate;
  final Future<String> Function() credential;
  bool verifying = false;
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (!verifying) {
      verifying = true;
      try {
        await credential();
      } finally {
        verifying = false;
      }
    }
    return delegate.call(method, path, query: query, body: body);
  }
}

class FailingIdentityApi implements GitHubApi {
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    throw const GitHubFailure('네트워크 연결 실패');
  }
}
