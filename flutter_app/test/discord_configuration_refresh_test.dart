import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/discord_configuration.dart';
import 'package:ieum_flutter/discord_credentials.dart';
import 'package:ieum_flutter/discord_crypto.dart';
import 'package:ieum_flutter/discord_models.dart';
import 'package:ieum_flutter/discord_vault.dart';

class _Vault implements DiscordSecretVault {
  final entries = <String, String>{};
  String _key(String accountId, String projectScope, String key) =>
      '$accountId/$projectScope/$key';
  @override
  Future<String?> read({
    required String accountId,
    required String projectScope,
    required String key,
  }) async => entries[_key(accountId, projectScope, key)];
  @override
  Future<void> write({
    required String accountId,
    required String projectScope,
    required String key,
    required String value,
  }) async {
    entries[_key(accountId, projectScope, key)] = value;
  }

  @override
  Future<void> delete({
    required String accountId,
    required String projectScope,
    required String key,
  }) async {
    entries.remove(_key(accountId, projectScope, key));
  }
}

class _Remote implements DiscordConfigurationTransport {
  final documents = <String, DiscordRemoteDocument>{};
  final reads = <String>[];
  var revision = 0;
  @override
  Future<DiscordRemoteDocument?> read(String path) async {
    reads.add(path);
    return documents[path];
  }

  @override
  Future<List<String>> list(String prefix) async =>
      documents.keys.where((path) => path.startsWith('$prefix/')).toList();
  @override
  Future<void> write(
    String path,
    String content, {
    String? expectedRevision,
  }) async {
    if (documents[path]?.revision != expectedRevision) {
      throw StateError('CAS conflict');
    }
    documents[path] = DiscordRemoteDocument(content, '${++revision}');
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) async {
    if (documents[path]?.revision != expectedRevision) {
      throw StateError('CAS conflict');
    }
    documents.remove(path);
  }
}

void main() {
  final scope = DiscordProjectScope(
    repository: 'example/team',
    projectId: 'project-1',
    integrationBranch: 'main',
  );
  const webhook =
      'https://discord.com/api/webhooks/1558164096040304721/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late _Remote remote;
  late DiscordConfigurationService owner;
  late Set<String> members;
  late DiscordConfiguration initial, current;
  setUp(() async {
    remote = _Remote();
    members = {'gh-1'};
    owner = DiscordConfigurationService(
      scope: scope,
      accountId: 'gh-1',
      ownerId: 'gh-1',
      credentials: DiscordCredentials(
        vault: _Vault(),
        accountId: 'gh-1',
        scope: scope,
      ),
      transport: remote,
      isCurrentMember: members.contains,
    );
    initial = await owner.initializeOwner();
    current = await owner.saveRoutes(
      [
        DiscordRoute(
          routeId: 'route-1',
          guildId: '1549005513721774210',
          channelId: '1558164096040304721',
          channelName: '작업 알림',
        ),
      ],
      webhookUrls: {'route-1': webhook},
    );
    remote.reads.clear();
  });

  test(
    'same-batch snapshot refresh performs one configuration GET, not two',
    () async {
      final snapshot = await owner.loadConfiguration();
      expect(
        await owner.refreshCredentials(validatedConfiguration: snapshot),
        1,
      );
      expect(remote.reads, [DiscordConfigurationService.configurationPath]);
      remote.reads.clear();
      expect(await owner.refreshCredentials(), 1);
      expect(remote.reads, [DiscordConfigurationService.configurationPath]);
    },
  );

  test(
    'snapshot path retains membership, owner and project scope checks',
    () async {
      members.clear();
      await expectLater(
        owner.refreshCredentials(validatedConfiguration: current),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
      members.add('gh-1');
      for (final document in [
        {...current.json, 'ownerId': 'gh-2'},
        {
          ...current.json,
          'scope': DiscordProjectScope(
            repository: 'example/other',
            projectId: 'project-1',
            integrationBranch: 'main',
          ).json,
        },
      ]) {
        await expectLater(
          owner.refreshCredentials(
            validatedConfiguration: DiscordConfiguration.fromJson(document),
          ),
          throwsA(isA<DiscordConfigurationFailure>()),
        );
      }
      expect(remote.reads, isEmpty);
    },
  );

  test('snapshot cannot roll back revision, change pinned owner or bypass signature verification', () async {
    await expectLater(
      owner.refreshCredentials(validatedConfiguration: initial),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final tampered = DiscordConfiguration.fromJson({
      ...current.json,
      'configRevision': current.configRevision + 1,
    });
    await expectLater(
      owner.refreshCredentials(validatedConfiguration: tampered),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final crypto = DiscordCrypto();
    final attacker = await crypto.generateIdentity();
    final forged = await crypto.signConfiguration(
      DiscordConfiguration.fromJson({
        ...current.json,
        'configRevision': current.configRevision + 1,
        'ownerPublicKey': await crypto.signingPublicKey(attacker),
      }),
      attacker,
    );
    await expectLater(
      owner.refreshCredentials(validatedConfiguration: forged),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    expect(remote.reads, isEmpty);
  });

  test(
    'a valid signed snapshot with a revoked sender cannot recover credentials',
    () async {
      final identity = await owner.credentials.getOrCreateIdentity();
      final revoked = await owner.crypto.signConfiguration(
        DiscordConfiguration.fromJson({
          ...current.json,
          'configRevision': current.configRevision + 1,
          'revocationEpoch': current.revocationEpoch + 1,
          'devices': [
            {...current.devices.single.json, 'revoked': true},
          ],
        }),
        identity,
      );
      expect(
        await owner.refreshCredentials(validatedConfiguration: revoked),
        0,
      );
      expect(
        await owner.credentials.readWebhook(revoked, revoked.routes.single),
        isNull,
      );
      expect(remote.reads, isEmpty);
    },
  );
}
