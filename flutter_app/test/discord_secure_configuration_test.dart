import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/discord_configuration.dart';
import 'package:ieum_flutter/discord_credentials.dart';
import 'package:ieum_flutter/discord_crypto.dart';
import 'package:ieum_flutter/discord_models.dart';
import 'package:ieum_flutter/discord_vault.dart';

class _Vault implements DiscordSecretVault {
  final data = <String, String>{};
  String _key(String accountId, String projectScope, String key) =>
      '$accountId/$projectScope/$key';
  @override
  Future<String?> read({
    required String accountId,
    required String projectScope,
    required String key,
  }) async => data[_key(accountId, projectScope, key)];
  @override
  Future<void> write({
    required String accountId,
    required String projectScope,
    required String key,
    required String value,
  }) async {
    expect(
      utf8.encode(value).length,
      lessThanOrEqualTo(NativeDiscordSecretVault.maxValueBytes),
    );
    data[_key(accountId, projectScope, key)] = value;
  }

  @override
  Future<void> delete({
    required String accountId,
    required String projectScope,
    required String key,
  }) async => data.remove(_key(accountId, projectScope, key));
}

class _Remote implements DiscordConfigurationTransport {
  final data = <String, DiscordRemoteDocument>{};
  var counter = 0;
  @override
  Future<DiscordRemoteDocument?> read(String path) async => data[path];
  @override
  Future<List<String>> list(String prefix) async =>
      data.keys.where((e) => e.startsWith('$prefix/')).toList();
  @override
  Future<void> write(
    String path,
    String content, {
    String? expectedRevision,
  }) async {
    if (data[path]?.revision != expectedRevision) throw StateError('conflict');
    data[path] = DiscordRemoteDocument(content, '${++counter}');
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) async {
    if (data[path]?.revision != expectedRevision) throw StateError('conflict');
    data.remove(path);
  }
}

void main() {
  final scope = DiscordProjectScope(
    repository: 'example/team',
    projectId: 'project-1',
    integrationBranch: 'main',
  );
  final instant = DateTime.utc(2026, 10, 10);
  const webhook =
      'https://discord.com/api/webhooks/1558164096040304721/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const rotated =
      'https://discord.com/api/webhooks/1558164096040304721/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  final route = DiscordRoute(
    routeId: 'route-1',
    guildId: '1549005513721774210',
    channelId: '1558164096040304721',
    channelName: '작업 알림',
    partIds: ['planning'],
  );
  late _Vault vault;
  late _Remote remote;
  late Set<String> members;
  late DiscordConfigurationService owner;
  late DiscordConfigurationService member;

  DiscordConfigurationService service(String account) =>
      DiscordConfigurationService(
        scope: scope,
        accountId: account,
        ownerId: 'gh-1',
        credentials: DiscordCredentials(
          vault: vault,
          accountId: account,
          scope: scope,
        ),
        transport: remote,
        isCurrentMember: members.contains,
        now: () => instant,
      );

  setUp(() {
    vault = _Vault();
    remote = _Remote();
    members = {'gh-1', 'gh-2'};
    owner = service('gh-1');
    member = service('gh-2');
  });

  Future<DiscordConfiguration> connectMember() async {
    await owner.initializeOwner();
    await owner.saveRoutes([route], webhookUrls: {'route-1': webhook});
    final code = await owner.createPairingCode('gh-2');
    final request = await member.acceptPairingCode(code);
    expect(
      (await owner.pendingPairingRequests()).single.device.deviceId,
      request.device.deviceId,
    );
    return owner.approvePairing(request);
  }

  test('strict schemas reject unknown keys, oversized data and unsupported versions', () async {
    final config = await owner.initializeOwner();
    expect(
      () => DiscordConfiguration.fromJson({...config.json, 'unknown': true}),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    expect(
      () => DiscordConfiguration.fromJson({...config.json, 'schema': 2}),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    expect(
      () => discordDecode(' ' * (discordMaxDocumentBytes + 1)),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    expect(
      () => DiscordRoute.fromJson({
        ...route.json,
        'eventTypes': ['unknown'],
      }),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
  });

  test(
    'owner signature rejects changed routes and a different pinned trust key',
    () async {
      final config = await owner.initializeOwner();
      final crypto = DiscordCrypto();
      expect(
        await crypto.verifyConfiguration(config, config.ownerPublicKey),
        isTrue,
      );
      final tampered = DiscordConfiguration.fromJson({
        ...config.json,
        'configRevision': 2,
      });
      expect(
        await crypto.verifyConfiguration(tampered, config.ownerPublicKey),
        isFalse,
      );
      final attacker = await crypto.generateIdentity();
      expect(
        await crypto.verifyConfiguration(
          config,
          await crypto.signingPublicKey(attacker),
        ),
        isFalse,
      );
    },
  );

  test('pairing is required, self-targeted, one-time, and remote secrets stay encrypted', () async {
    await owner.initializeOwner();
    await owner.saveRoutes([route], webhookUrls: {'route-1': webhook});
    await expectLater(
      member.loadConfiguration(),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final wrongCode = await owner.createPairingCode('gh-1');
    await expectLater(
      member.acceptPairingCode(wrongCode),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final code = await owner.createPairingCode('gh-2');
    final request = await member.acceptPairingCode(code);
    expect(
      jsonEncode(request.json),
      isNot(contains(DiscordPairingOffer.fromCode(code).secret)),
    );
    final config = await owner.approvePairing(request);
    await expectLater(
      owner.approvePairing(request),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    expect(await member.refreshCredentials(), 1);
    expect(await member.credentials.readWebhook(config, route), webhook);
    for (final doc in remote.data.values) {
      expect(doc.content, isNot(contains(webhook)));
    }
  });

  test(
    'a forged enrollment proof and an expired invitation cannot enroll',
    () async {
      final config = await owner.initializeOwner();
      final crypto = DiscordCrypto();
      final identity = await crypto.generateIdentity();
      final offer = crypto.createPairingOffer(
        config,
        'gh-2',
        instant.add(const Duration(minutes: 15)),
      );
      final request = await crypto.pairingRequest(
        offer,
        identity,
        'gh-2',
        instant,
      );
      final tampered = DiscordPairingRequest.fromJson({
        ...request.json,
        'proof': base64Url.encode(List<int>.filled(32, 1)),
      });
      expect(
        await crypto.verifyPairingRequest(offer, tampered, instant),
        isFalse,
      );
      expect(
        await crypto.verifyPairingRequest(
          offer,
          request,
          instant.add(const Duration(minutes: 15)),
        ),
        isFalse,
      );
      await expectLater(
        crypto.pairingRequest(offer, identity, 'gh-1', instant),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
    },
  );

  test(
    'envelopes bind recipient, channel, revision and authenticated ciphertext',
    () async {
      final config = await connectMember();
      final identity = await member.credentials.getOrCreateIdentity();
      final path = member.envelopePath(
        identity.deviceId,
        route.routeId,
        config.configRevision,
      );
      final envelope = DiscordWebhookEnvelope.fromJson(
        discordDecode(remote.data[path]!.content),
      );
      final crypto = DiscordCrypto();
      expect(
        await crypto.openWebhook(
          envelope: envelope,
          configuration: config,
          route: route,
          identity: identity,
          accountId: 'gh-2',
        ),
        webhook,
      );
      final bad = DiscordWebhookEnvelope.fromJson({
        ...envelope.json,
        'channelId': '1558164096040304722',
      });
      await expectLater(
        crypto.openWebhook(
          envelope: bad,
          configuration: config,
          route: route,
          identity: identity,
          accountId: 'gh-2',
        ),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
      await expectLater(
        crypto.openWebhook(
          envelope: envelope,
          configuration: config,
          route: route,
          identity: await crypto.generateIdentity(),
          accountId: 'gh-2',
        ),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
    },
  );

  test('vault high-water mark rejects signed Git history replay and forged replacement owner', () async {
    final config = await connectMember();
    await member.loadConfiguration();
    final old = remote.data[DiscordConfigurationService.configurationPath]!;
    await owner.saveRoutes([route]);
    await member.loadConfiguration();
    remote.data[DiscordConfigurationService.configurationPath] = old;
    await expectLater(
      member.loadConfiguration(),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final crypto = DiscordCrypto();
    final attacker = await crypto.generateIdentity();
    final replacement = await crypto.signConfiguration(
      DiscordConfiguration(
        scope: scope,
        ownerId: 'gh-1',
        ownerPublicKey: await crypto.signingPublicKey(attacker),
        configRevision: config.configRevision + 9,
        revocationEpoch: config.revocationEpoch,
        updatedAt: instant,
      ),
      attacker,
    );
    remote.data[DiscordConfigurationService.configurationPath] =
        DiscordRemoteDocument(discordCanonical(replacement.json), 'attacker');
    await expectLater(
      member.loadConfiguration(),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
  });

  test(
    'departed accounts are rejected before approval and credentials refresh',
    () async {
      await owner.initializeOwner();
      final code = await owner.createPairingCode('gh-2');
      final request = await member.acceptPairingCode(code);
      members.remove('gh-2');
      await expectLater(
        owner.approvePairing(request),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
      await expectLater(
        member.refreshCredentials(),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
      expect(await owner.pendingPairingRequests(), isEmpty);
    },
  );

  test(
    'revocation rotates disabled routes too and removes former device access',
    () async {
      await connectMember();
      final device = (await member.credentials.getOrCreateIdentity()).deviceId;
      final disabled = DiscordRoute(
        routeId: route.routeId,
        guildId: route.guildId,
        channelId: route.channelId,
        channelName: route.channelName,
        partIds: route.partIds,
        enabled: false,
      );
      await owner.saveRoutes([disabled]);
      await expectLater(
        owner.revokeDevice(device, rotatedWebhookUrls: {}),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
      await expectLater(
        owner.revokeDevice(device, rotatedWebhookUrls: {'route-1': webhook}),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
      final revoked = await owner.revokeDevice(
        device,
        rotatedWebhookUrls: {'route-1': rotated},
      );
      expect(revoked.revocationEpoch, 1);
      expect(
        revoked.devices.singleWhere((e) => e.deviceId == device).revoked,
        isTrue,
      );
      expect(await member.refreshCredentials(), 0);
      expect(
        await member.credentials.readWebhook(revoked, revoked.routes.single),
        isNull,
      );
      expect(await owner.credentials.ownerWebhook('route-1'), rotated);
    },
  );
  test(
    'settings prune obsolete signed envelopes without retaining raw secrets',
    () async {
      final initial = await connectMember();
      expect(initial.configRevision, 3);
      await owner.saveRoutes([route]);
      final latest = await owner.saveRoutes([route]);
      final paths = await remote.list('.ieum/notifications/envelopes');
      expect(paths, hasLength(4));
      for (final path in paths) {
        final envelope = DiscordWebhookEnvelope.fromJson(
          discordDecode(remote.data[path]!.content),
        );
        expect(
          envelope.configRevision,
          greaterThanOrEqualTo(latest.configRevision - 1),
        );
      }
      expect(owner.cleanupWarnings, isEmpty);
    },
  );
  test('a revoked unchanged device can enroll again only after explicit new approval', () async {
    await connectMember();
    final identity = await member.credentials.getOrCreateIdentity();
    final revoked = await owner.revokeDevice(
      identity.deviceId,
      rotatedWebhookUrls: {'route-1': rotated},
    );
    // The member has not refreshed: the new code must advance its existing pin safely.
    final code = await owner.createPairingCode('gh-2');
    final request = await member.acceptPairingCode(code);
    expect(request.device.deviceId, identity.deviceId);
    expect(await member.refreshCredentials(), 0);
    expect(
      await member.credentials.readWebhook(revoked, revoked.routes.single),
      isNull,
    );
    final approved = await owner.approvePairing(request);
    expect(approved.devices, hasLength(2));
    expect(
      approved.devices
          .singleWhere((e) => e.deviceId == identity.deviceId)
          .revoked,
      isFalse,
    );
    expect(await member.refreshCredentials(), 1);
    expect(
      await member.credentials.readWebhook(approved, approved.routes.single),
      rotated,
    );
    await expectLater(
      owner.approvePairing(request),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final activeRequest = await member.acceptPairingCode(
      await owner.createPairingCode('gh-2'),
    );
    await expectLater(
      owner.approvePairing(activeRequest),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
  });
  test('revoked device IDs cannot be re-enrolled with a different key or account', () async {
    await connectMember();
    final identity = await member.credentials.getOrCreateIdentity();
    await owner.revokeDevice(
      identity.deviceId,
      rotatedWebhookUrls: {'route-1': rotated},
    );
    final crypto = DiscordCrypto();
    final fresh = await crypto.generateIdentity();
    final collided = DiscordDeviceIdentity(
      deviceId: identity.deviceId,
      encryptionSeed: fresh.encryptionSeed,
      signingSeed: fresh.signingSeed,
    );
    final offer = DiscordPairingOffer.fromCode(
      await owner.createPairingCode('gh-2'),
    );
    final collisionRequest = await crypto.pairingRequest(
      offer,
      collided,
      'gh-2',
      instant,
    );
    await remote.write(
      '${DiscordConfigurationService.requestsPath}/gh-2/${offer.pairingId}.json',
      discordCanonical(collisionRequest.json),
    );
    await expectLater(
      owner.approvePairing(collisionRequest),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    members.add('gh-3');
    final otherOffer = DiscordPairingOffer.fromCode(
      await owner.createPairingCode('gh-3'),
    );
    final otherRequest = await crypto.pairingRequest(
      otherOffer,
      identity,
      'gh-3',
      instant,
    );
    await remote.write(
      '${DiscordConfigurationService.requestsPath}/gh-3/${otherOffer.pairingId}.json',
      discordCanonical(otherRequest.json),
    );
    await expectLater(
      owner.approvePairing(otherRequest),
      throwsA(isA<DiscordConfigurationFailure>()),
    );
    final current = await owner.loadConfiguration();
    expect(
      current!.devices
          .singleWhere((e) => e.deviceId == identity.deviceId)
          .revoked,
      isTrue,
    );
  });
  test(
    'legacy routes retain signed bytes while exposing compatible status events',
    () async {
      final legacyJson = <String, dynamic>{
        ...route.json,
        'eventTypes': ['assigned', 'completed', 'handedOff'],
      }..remove('notificationVersion');
      final legacy = DiscordRoute.fromJson(legacyJson);
      expect(legacy.notificationVersion, 1);
      expect(
        legacy.effectiveEventTypes,
        contains(DiscordEventType.statusChanged),
      );
      expect(
        legacy.eventTypes,
        isNot(contains(DiscordEventType.statusChanged)),
      );
      expect(discordCanonical(legacy.json), discordCanonical(legacyJson));
      await owner.initializeOwner();
      final signed = await owner.saveRoutes(
        [legacy],
        webhookUrls: {'route-1': webhook},
      );
      final parsed = DiscordConfiguration.fromJson(
        discordDecode(discordCanonical(signed.json)),
      );
      expect(discordCanonical(parsed.json), discordCanonical(signed.json));
      expect(parsed.fingerprint, signed.fingerprint);
      expect(
        await DiscordCrypto().verifyConfiguration(
          parsed,
          signed.ownerPublicKey,
        ),
        isTrue,
      );
      expect(
        parsed.routes.single.json.containsKey('notificationVersion'),
        isFalse,
      );
      final request = await member.acceptPairingCode(
        await owner.createPairingCode('gh-2'),
      );
      await owner.approvePairing(request);
      final revoked = await owner.revokeDevice(
        request.device.deviceId,
        rotatedWebhookUrls: {'route-1': rotated},
      );
      expect(revoked.routes.single.notificationVersion, 1);
      expect(
        revoked.routes.single.json.containsKey('notificationVersion'),
        isFalse,
      );
      expect(
        revoked.routes.single.effectiveEventTypes,
        contains(DiscordEventType.statusChanged),
      );
    },
  );
  test(
    'version 2 routes allow status notifications to be explicitly disabled',
    () {
      final explicit = DiscordRoute.fromJson({
        ...route.json,
        'eventTypes': ['handedOff'],
      });
      expect(explicit.notificationVersion, 2);
      expect(explicit.effectiveEventTypes, {DiscordEventType.handedOff});
      expect(explicit.json['notificationVersion'], 2);
      final legacyWithoutHandoffs = <String, dynamic>{
        ...route.json,
        'eventTypes': ['completed'],
      }..remove('notificationVersion');
      expect(DiscordRoute.fromJson(legacyWithoutHandoffs).effectiveEventTypes, {
        DiscordEventType.completed,
      });
      expect(route.notificationVersion, 2);
      expect(
        route.effectiveEventTypes,
        contains(DiscordEventType.statusChanged),
      );
      expect(
        () => DiscordRoute.fromJson({...route.json, 'notificationVersion': 3}),
        throwsA(isA<DiscordConfigurationFailure>()),
      );
    },
  );
}
