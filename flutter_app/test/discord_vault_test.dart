import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/discord_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const account = 'gh-123';
  const scope = 'project-1';
  const key = 'device-key';
  final vault = NativeDiscordSecretVault();

  tearDown(
    () => messenger.setMockMethodCallHandler(
      NativeDiscordSecretVault.channel,
      null,
    ),
  );

  test('scoped read write delete never address OAuth credentials', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(NativeDiscordSecretVault.channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'read' ? 'vault-only' : null;
    });
    expect(
      await vault.read(accountId: account, projectScope: scope, key: key),
      'vault-only',
    );
    await vault.write(
      accountId: account,
      projectScope: scope,
      key: key,
      value: 'device-private-key',
    );
    await vault.delete(accountId: account, projectScope: scope, key: key);
    expect(NativeDiscordSecretVault.channel.name, 'ieum/discord_vault');
    expect(calls.map((call) => call.method), ['read', 'write', 'delete']);
    expect(calls.first.arguments, {
      'accountId': account,
      'projectScope': scope,
      'key': key,
    });
    expect((calls[1].arguments as Map)['value'], 'device-private-key');
  });

  test('unsafe scope and oversized multibyte credentials are rejected before native call', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(NativeDiscordSecretVault.channel, (
      _,
    ) async {
      calls++;
      return null;
    });
    await expectLater(
      vault.read(
        accountId: 'gh-123/../../GitHub',
        projectScope: scope,
        key: key,
      ),
      throwsA(isA<DiscordVaultFailure>()),
    );
    await expectLater(
      vault.delete(
        accountId: account,
        projectScope: '../OAuth/credential',
        key: key,
      ),
      throwsA(isA<DiscordVaultFailure>()),
    );
    await expectLater(
      vault.write(
        accountId: account,
        projectScope: scope,
        key: key,
        value: '키' * 854,
      ),
      throwsA(isA<DiscordVaultFailure>()),
    );
    expect(calls, 0);
  });

  test(
    'native failures are redacted and unexpected stored sizes are rejected',
    () async {
      messenger.setMockMethodCallHandler(NativeDiscordSecretVault.channel, (
        _,
      ) async {
        throw PlatformException(
          code: 'vault_error',
          message: 'secret-device-key',
        );
      });
      try {
        await vault.read(accountId: account, projectScope: scope, key: key);
        fail('Expected redacted failure');
      } catch (error) {
        expect(error, isA<DiscordVaultFailure>());
        expect(error.toString(), isNot(contains('secret-device-key')));
      }
      messenger.setMockMethodCallHandler(
        NativeDiscordSecretVault.channel,
        (_) async => 'x' * 2561,
      );
      await expectLater(
        vault.read(accountId: account, projectScope: scope, key: key),
        throwsA(isA<DiscordVaultFailure>()),
      );
    },
  );
}
