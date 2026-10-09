import 'discord_credentials.dart';
import 'discord_crypto.dart';
import 'discord_models.dart';

class DiscordRemoteDocument {
  const DiscordRemoteDocument(this.content, this.revision);
  final String content;
  final String revision;
}

/// Implement with authenticated GitHub file CAS operations on the integration branch.
/// Null expectedRevision means create-only, never an unconditional overwrite.
abstract interface class DiscordConfigurationTransport {
  Future<DiscordRemoteDocument?> read(String path);
  Future<void> write(String path, String content, {String? expectedRevision});
  Future<List<String>> list(String prefix);
  Future<void> delete(String path, {required String expectedRevision});
}

class DiscordConfigurationService {
  DiscordConfigurationService({
    required this.scope,
    required String accountId,
    required String ownerId,
    required this.credentials,
    required this.transport,
    required this.isCurrentMember,
    DiscordCrypto? crypto,
    DateTime Function()? now,
  }) : accountId = discordGithubId(accountId),
       ownerId = discordGithubId(ownerId),
       crypto = crypto ?? DiscordCrypto(),
       now = now ?? (() => DateTime.now().toUtc()) {
    if (credentials.accountId != accountId ||
        !scope.matches(credentials.scope)) {
      discordInvalid();
    }
  }
  static const configurationPath = '.ieum/notifications/routes.json';
  static const requestsPath = '.ieum/notifications/requests';
  final DiscordProjectScope scope;
  final String accountId, ownerId;
  final DiscordCredentials credentials;
  final DiscordConfigurationTransport transport;
  final DiscordCrypto crypto;
  final bool Function(String githubUserId) isCurrentMember;
  final DateTime Function() now;
  Future<void> _queue = Future.value();
  final List<String> cleanupWarnings = [];

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _member() {
    if (!isCurrentMember(accountId)) {
      throw const DiscordConfigurationFailure(
        '현재 프로젝트 참여자만 Discord 연결을 사용할 수 있습니다.',
      );
    }
  }

  Future<DiscordDeviceIdentity> _ownerIdentity() async {
    _member();
    if (accountId != ownerId) {
      throw const DiscordConfigurationFailure(
        '프로젝트 소유자만 Discord 채널과 기기를 관리할 수 있습니다.',
      );
    }
    return credentials.getOrCreateIdentity();
  }

  void _scope(DiscordConfiguration config) {
    if (!scope.matches(config.scope) || config.ownerId != ownerId) {
      discordInvalid();
    }
  }

  /// Informational only; an unpaired device must never send from this value.
  Future<DiscordConfiguration?> readPublicConfiguration() async {
    final document = await transport.read(configurationPath);
    if (document == null) return null;
    final config = DiscordConfiguration.fromJson(
      discordDecode(document.content),
    );
    _scope(config);
    if (!await crypto.verifyConfiguration(config, config.ownerPublicKey)) {
      discordInvalid();
    }
    return config;
  }

  Future<DiscordConfiguration?> loadConfiguration() async {
    _member();
    final config = await readPublicConfiguration();
    if (config == null) return null;
    await credentials.acceptConfiguration(config);
    return config;
  }

  Future<DiscordConfiguration> initializeOwner() => _serial(() async {
    final identity = await _ownerIdentity();
    final key = await crypto.signingPublicKey(identity);
    final remote = await transport.read(configurationPath);
    if (remote != null) {
      final current = DiscordConfiguration.fromJson(
        discordDecode(remote.content),
      );
      _scope(current);
      if (current.ownerPublicKey != key ||
          !await crypto.verifyConfiguration(current, key)) {
        throw const DiscordConfigurationFailure(
          '기존 관리자 기기에서 연결 승인을 받으세요. 관리자 키를 분실했다면 웹훅을 재발급하고 다시 연결해야 합니다.',
        );
      }
      final trust = await credentials.loadTrust();
      if (trust == null) {
        await credentials.pinTrust(
          DiscordTrustState.fromConfiguration(current),
        );
      }
      await credentials.acceptConfiguration(current);
      return current;
    }
    // A previous trusted configuration disappearing is not a fresh setup.
    if (await credentials.loadTrust() != null) {
      throw const DiscordConfigurationFailure(
        '저장소의 Discord 설정이 없어졌습니다. 연결 기록을 확인하세요.',
      );
    }
    final config = await crypto.signConfiguration(
      DiscordConfiguration(
        scope: scope,
        ownerId: ownerId,
        ownerPublicKey: key,
        configRevision: 1,
        revocationEpoch: 0,
        updatedAt: now(),
        devices: [await crypto.certificate(identity, accountId)],
      ),
      identity,
    );
    await transport.write(configurationPath, discordCanonical(config.json));
    await credentials.pinTrust(DiscordTrustState.fromConfiguration(config));
    return config;
  });

  Future<(DiscordConfiguration, DiscordRemoteDocument, DiscordDeviceIdentity)>
  _ownerConfiguration() async {
    final identity = await _ownerIdentity();
    final remote = await transport.read(configurationPath);
    if (remote == null) {
      throw const DiscordConfigurationFailure('Discord 연결을 먼저 등록하세요.');
    }
    final current = DiscordConfiguration.fromJson(
      discordDecode(remote.content),
    );
    _scope(current);
    await credentials.acceptConfiguration(current);
    if (current.ownerPublicKey != await crypto.signingPublicKey(identity)) {
      throw const DiscordConfigurationFailure(
        'Discord 연결을 처음 등록한 관리자 기기에서 설정을 변경하세요.',
      );
    }
    return (current, remote, identity);
  }

  String envelopePath(String deviceId, String routeId, int revision) =>
      '.ieum/notifications/envelopes/${discordIdentifier(deviceId)}/${discordIdentifier(routeId)}-$revision.json';

  Future<void> _publish(
    DiscordConfiguration current,
    DiscordRemoteDocument remote,
    DiscordConfiguration next,
    DiscordDeviceIdentity owner,
    Map<String, String> newSecrets,
  ) async {
    final activeDevices = next.devices
        .where((e) => !e.revoked && isCurrentMember(e.githubUserId))
        .length;
    final activePairs =
        activeDevices * next.routes.where((e) => e.enabled).length;
    if (activePairs > 250) {
      throw const DiscordConfigurationFailure(
        '이 프로젝트의 알림 채널과 승인 기기 연결은 최대 250개까지 지원합니다. 사용하지 않는 연결을 정리하세요.',
      );
    }
    final existingPaths = await transport.list('.ieum/notifications/envelopes');
    if (existingPaths.length + activePairs > 2000) {
      throw const DiscordConfigurationFailure(
        '이전 연결 정보를 정리하고 있습니다. 잠시 후 채널 설정을 다시 저장하세요.',
      );
    }
    final secrets = <String, String>{};
    final envelopes = <String, DiscordWebhookEnvelope>{};
    for (final route in next.routes) {
      final existing = current.routes.where((e) => e.routeId == route.routeId);
      final changedSecret =
          existing.isEmpty ||
          existing.single.secretVersion != route.secretVersion ||
          existing.single.channelId != route.channelId ||
          existing.single.guildId != route.guildId;
      final url =
          newSecrets[route.routeId] ??
          (changedSecret
              ? null
              : await credentials.ownerWebhook(route.routeId));
      if (url == null) {
        if (!route.enabled) continue;
        throw const DiscordConfigurationFailure('채널의 웹훅을 이 관리자 기기에 다시 등록하세요.');
      }
      secrets[route.routeId] = url;
      if (!route.enabled) continue;
      for (final device in next.devices.where(
        (e) => !e.revoked && isCurrentMember(e.githubUserId),
      )) {
        final envelope = await crypto.sealWebhook(
          configuration: next,
          route: route,
          recipient: device,
          webhookUrl: url,
          owner: owner,
        );
        envelopes[envelopePath(
              device.deviceId,
              route.routeId,
              next.configRevision,
            )] =
            envelope;
      }
    }
    // Immutable revision paths make a failed configuration CAS safe to retry.
    for (final entry in envelopes.entries) {
      final previous = await transport.read(entry.key);
      await transport.write(
        entry.key,
        discordCanonical(entry.value.json),
        expectedRevision: previous?.revision,
      );
    }
    await transport.write(
      configurationPath,
      discordCanonical(next.json),
      expectedRevision: remote.revision,
    );
    await credentials.acceptConfiguration(next);
    for (final route in next.routes) {
      final url = secrets[route.routeId];
      if (url != null) await credentials.storeWebhook(next, route, url);
    }
    for (final route in current.routes) {
      if (!next.routes.any((e) => e.routeId == route.routeId)) {
        await credentials.deleteWebhook(route.routeId);
      }
    }
    await _pruneEnvelopes(next);
  }

  /// History remains encrypted in Git; keep active files bounded without mass deletes.
  Future<void> _pruneEnvelopes(DiscordConfiguration config) async {
    cleanupWarnings.clear();
    try {
      final paths = await transport.list('.ieum/notifications/envelopes');
      if (paths.length > 2000) {
        throw const DiscordConfigurationFailure(
          '이전 연결 정보가 많아 한 번에 정리할 수 없습니다.',
        );
      }
      final pattern = RegExp(
        r'^\.ieum/notifications/envelopes/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+-([0-9]+)\.json$',
      );
      final candidates = <(String, int)>[];
      for (final path in paths) {
        final match = pattern.firstMatch(path);
        if (match == null) continue;
        final revision = int.tryParse(match.group(1)!);
        if (revision != null &&
            revision > 0 &&
            revision < config.configRevision - 1) {
          candidates.add((path, revision));
        }
      }
      candidates.sort((a, b) => a.$2.compareTo(b.$2));
      var removed = 0;
      for (final candidate in candidates.take(25)) {
        final remote = await transport.read(candidate.$1);
        if (remote == null) continue;
        final envelope = DiscordWebhookEnvelope.fromJson(
          discordDecode(remote.content),
        );
        if (!scope.matches(envelope.scope) ||
            envelope.configRevision != candidate.$2 ||
            candidate.$1 !=
                envelopePath(
                  envelope.recipientDeviceId,
                  envelope.routeId,
                  envelope.configRevision,
                ) ||
            !await crypto.verify(
              'envelope',
              envelope.unsignedJson,
              envelope.signature,
              config.ownerPublicKey,
            )) {
          continue;
        }
        await transport.delete(candidate.$1, expectedRevision: remote.revision);
        removed++;
      }
      if (candidates.length > removed && candidates.length > 25) {
        cleanupWarnings.add('이전 암호화 연결 정보를 나누어 정리하고 있습니다.');
      }
    } catch (_) {
      // Remote settings are already committed. Do not tell the user they failed.
      cleanupWarnings.add('이전 암호화 연결 정보 정리를 완료하지 못했습니다. 다음 설정 저장 때 다시 시도합니다.');
    }
  }

  /// Called only by the original administrator device while this project is open.
  Future<void> cleanupStaleEnvelopes() => _serial(() async {
    final (current, _, _) = await _ownerConfiguration();
    await _pruneEnvelopes(current);
  });

  Future<DiscordConfiguration> saveRoutes(
    List<DiscordRoute> routes, {
    Map<String, String> webhookUrls = const {},
  }) => _serial(() async {
    final (current, remote, owner) = await _ownerConfiguration();
    for (final route in routes) {
      final previous = current.routes.where((e) => e.routeId == route.routeId);
      if (previous.isEmpty) continue;
      final old = previous.single;
      if (route.secretVersion < old.secretVersion ||
          ((route.channelId != old.channelId || route.guildId != old.guildId) &&
              route.secretVersion <= old.secretVersion)) {
        discordInvalid();
      }
      final supplied = webhookUrls[route.routeId];
      if (supplied != null &&
          supplied != await credentials.ownerWebhook(route.routeId) &&
          route.secretVersion <= old.secretVersion) {
        throw const DiscordConfigurationFailure('웹훅을 교체할 때는 연결 버전도 갱신해야 합니다.');
      }
    }
    final next = await crypto.signConfiguration(
      DiscordConfiguration(
        scope: scope,
        ownerId: ownerId,
        ownerPublicKey: current.ownerPublicKey,
        configRevision: current.configRevision + 1,
        revocationEpoch: current.revocationEpoch,
        updatedAt: now(),
        routes: routes,
        devices: current.devices,
      ),
      owner,
    );
    await _publish(current, remote, next, owner, webhookUrls);
    return next;
  });

  Future<String> createPairingCode(String targetGithubUserId) =>
      _serial(() async {
        final (current, _, _) = await _ownerConfiguration();
        final target = discordGithubId(targetGithubUserId);
        if (!isCurrentMember(target)) {
          throw const DiscordConfigurationFailure('현재 프로젝트 참여자를 선택하세요.');
        }
        final offer = crypto.createPairingOffer(
          current,
          target,
          now().add(const Duration(minutes: 15)),
        );
        await credentials.savePairingOffer(offer);
        return offer.code;
      });

  Future<DiscordPairingRequest> acceptPairingCode(String code) =>
      _serial(() async {
        _member();
        final offer = DiscordPairingOffer.fromCode(code.trim());
        if (!offer.scope.matches(scope) || offer.githubUserId != accountId) {
          discordInvalid();
        }
        final current = await readPublicConfiguration();
        if (current == null ||
            current.ownerPublicKey != offer.ownerPublicKey ||
            current.configRevision < offer.configRevision ||
            current.revocationEpoch != offer.revocationEpoch ||
            (current.configRevision == offer.configRevision &&
                current.fingerprint != offer.configFingerprint)) {
          discordInvalid();
        }
        final request = await crypto.pairingRequest(
          offer,
          await credentials.getOrCreateIdentity(),
          accountId,
          now(),
        );
        final existingTrust = await credentials.loadTrust();
        if (existingTrust == null) {
          await credentials.pinTrust(
            DiscordTrustState(
              ownerId: ownerId,
              ownerPublicKey: offer.ownerPublicKey,
              configRevision: offer.configRevision,
              revocationEpoch: offer.revocationEpoch,
              configFingerprint: offer.configFingerprint,
            ),
          );
        } else {
          // Re-enrollment retains the existing owner pin and rollback boundary.
          existingTrust.check(current);
        }
        await credentials.acceptConfiguration(current);
        final path = '$requestsPath/$accountId/${request.pairingId}.json';
        final previous = await transport.read(path);
        if (previous != null &&
            discordCanonical(discordDecode(previous.content)) !=
                discordCanonical(request.json)) {
          throw const DiscordConfigurationFailure(
            '이 연결 코드로 다른 기기의 요청이 등록되었습니다. 새 코드를 요청하세요.',
          );
        }
        if (previous == null) {
          await transport.write(path, discordCanonical(request.json));
        }
        return request;
      });

  Future<List<DiscordPairingRequest>> pendingPairingRequests() async {
    final (current, _, _) = await _ownerConfiguration();
    final paths = await transport.list(requestsPath);
    if (paths.length > 500) {
      throw const DiscordConfigurationFailure(
        '기기 연결 요청이 너무 많습니다. 이전 요청을 정리하세요.',
      );
    }
    final requests = <DiscordPairingRequest>[];
    for (final path in paths) {
      if (!RegExp(
        r'^\.ieum/notifications/requests/gh-[1-9][0-9]{0,19}/[A-Za-z0-9_-]+\.json$',
      ).hasMatch(path)) {
        continue;
      }
      try {
        final remote = await transport.read(path);
        if (remote == null) continue;
        final request = DiscordPairingRequest.fromJson(
          discordDecode(remote.content),
        );
        final offer = await credentials.loadPairingOffer(request.pairingId);
        if (offer != null &&
            isCurrentMember(request.githubUserId) &&
            request.revocationEpoch == current.revocationEpoch &&
            request.ownerPublicKey == current.ownerPublicKey &&
            path ==
                '$requestsPath/${request.githubUserId}/${request.pairingId}.json' &&
            await crypto.verifyPairingRequest(offer, request, now())) {
          requests.add(request);
        }
      } on DiscordConfigurationFailure {
        continue;
      }
    }
    return List.unmodifiable(requests);
  }

  Future<DiscordConfiguration> approvePairing(DiscordPairingRequest request) =>
      _serial(() async {
        final (current, remote, owner) = await _ownerConfiguration();
        final offer = await credentials.loadPairingOffer(request.pairingId);
        if (offer == null ||
            !isCurrentMember(request.githubUserId) ||
            request.ownerPublicKey != current.ownerPublicKey ||
            request.revocationEpoch != current.revocationEpoch ||
            !await crypto.verifyPairingRequest(offer, request, now())) {
          throw const DiscordConfigurationFailure(
            '연결 요청이 만료되었거나 승인할 수 없는 요청입니다. 새 코드를 발급하세요.',
          );
        }
        final requestPath =
            '$requestsPath/${request.githubUserId}/${request.pairingId}.json';
        final stored = await transport.read(requestPath);
        if (stored == null ||
            discordCanonical(discordDecode(stored.content)) !=
                discordCanonical(request.json)) {
          discordInvalid();
        }
        final previousDevice = current.devices
            .where((e) => e.deviceId == request.device.deviceId)
            .firstOrNull;
        if (previousDevice != null && !previousDevice.revoked) {
          throw const DiscordConfigurationFailure('이미 연결된 기기입니다.');
        }
        if (previousDevice != null &&
            (previousDevice.githubUserId != request.device.githubUserId ||
                previousDevice.encryptionPublicKey !=
                    request.device.encryptionPublicKey ||
                previousDevice.signingPublicKey !=
                    request.device.signingPublicKey)) {
          throw const DiscordConfigurationFailure(
            '이 기기의 기존 계정이나 인증 키와 다른 요청입니다. 새 기기로 연결하세요.',
          );
        }
        final next = await crypto.signConfiguration(
          DiscordConfiguration(
            scope: scope,
            ownerId: ownerId,
            ownerPublicKey: current.ownerPublicKey,
            configRevision: current.configRevision + 1,
            revocationEpoch: current.revocationEpoch,
            updatedAt: now(),
            routes: current.routes,
            devices: previousDevice == null
                ? [...current.devices, request.device]
                : [
                    for (final device in current.devices)
                      device.deviceId == request.device.deviceId
                          ? request.device
                          : device,
                  ],
          ),
          owner,
        );
        // Approval itself is explicit and scoped. Only then distribute any credentials.
        // Burn the invitation before publishing: a failed approval needs a new code.
        // This prevents reuse when a remote write succeeds but a later local call fails.
        await credentials.deletePairingOffer(request.pairingId);
        await _publish(current, remote, next, owner, const {});
        await transport.delete(requestPath, expectedRevision: stored.revision);
        return next;
      });

  Future<void> rejectPairing(DiscordPairingRequest request) =>
      _serial(() async {
        await _ownerConfiguration();
        await credentials.deletePairingOffer(request.pairingId);
        final path =
            '$requestsPath/${request.githubUserId}/${request.pairingId}.json';
        final stored = await transport.read(path);
        if (stored != null) {
          await transport.delete(path, expectedRevision: stored.revision);
        }
      });

  /// A leaked token remains usable outside IEUM. Require Discord token rotation.
  Future<DiscordConfiguration> revokeDevice(
    String deviceId, {
    required Map<String, String> rotatedWebhookUrls,
  }) => _serial(() async {
    final (current, remote, owner) = await _ownerConfiguration();
    if (deviceId == owner.deviceId ||
        !current.devices.any((e) => e.deviceId == deviceId && !e.revoked)) {
      throw const DiscordConfigurationFailure(
        '해제할 참여 기기를 선택하세요. 관리자 기기는 여기서 해제할 수 없습니다.',
      );
    }
    final routes = <DiscordRoute>[];
    for (final route in current.routes) {
      final rotated = rotatedWebhookUrls[route.routeId];
      if (rotated == null ||
          rotated == await credentials.ownerWebhook(route.routeId)) {
        throw const DiscordConfigurationFailure(
          '기기를 해제하려면 Discord에서 비활성 채널을 포함한 모든 채널의 웹훅을 재발급해 등록하세요.',
        );
      }
      routes.add(
        DiscordRoute(
          routeId: route.routeId,
          guildId: route.guildId,
          channelId: route.channelId,
          channelName: route.channelName,
          partIds: route.partIds,
          eventTypes: route.eventTypes,
          notificationVersion: route.notificationVersion,
          enabled: route.enabled,
          secretVersion: route.secretVersion + 1,
        ),
      );
    }
    final devices = current.devices
        .map(
          (e) => e.deviceId == deviceId
              ? DiscordDeviceCertificate(
                  githubUserId: e.githubUserId,
                  deviceId: e.deviceId,
                  encryptionPublicKey: e.encryptionPublicKey,
                  signingPublicKey: e.signingPublicKey,
                  revoked: true,
                )
              : e,
        )
        .toList();
    final next = await crypto.signConfiguration(
      DiscordConfiguration(
        scope: scope,
        ownerId: ownerId,
        ownerPublicKey: current.ownerPublicKey,
        configRevision: current.configRevision + 1,
        revocationEpoch: current.revocationEpoch + 1,
        updatedAt: now(),
        routes: routes,
        devices: devices,
      ),
      owner,
    );
    await _publish(current, remote, next, owner, rotatedWebhookUrls);
    return next;
  });

  /// A snapshot fetched for the same batch avoids another GitHub read, while
  /// membership, scope, pinned owner key and revision checks still apply.
  Future<int> refreshCredentials({
    DiscordConfiguration? validatedConfiguration,
  }) async {
    final config = validatedConfiguration ?? await loadConfiguration();
    if (config == null) return 0;
    if (validatedConfiguration != null) {
      _member();
      _scope(config);
      await credentials.acceptConfiguration(config);
    }
    final identity = await credentials.getOrCreateIdentity();
    final certificates = config.devices.where(
      (e) => e.deviceId == identity.deviceId,
    );
    if (certificates.length != 1 ||
        certificates.single.revoked ||
        certificates.single.githubUserId != accountId) {
      return 0;
    }
    var count = 0;
    for (final route in config.routes.where((e) => e.enabled)) {
      if (await credentials.readWebhook(config, route) != null) {
        count++;
        continue;
      }
      final path = envelopePath(
        identity.deviceId,
        route.routeId,
        config.configRevision,
      );
      final stored = await transport.read(path);
      if (stored == null) continue;
      final envelope = DiscordWebhookEnvelope.fromJson(
        discordDecode(stored.content),
      );
      final url = await crypto.openWebhook(
        envelope: envelope,
        configuration: config,
        route: route,
        identity: identity,
        accountId: accountId,
      );
      await credentials.storeWebhook(config, route, url);
      count++;
    }
    return count;
  }
}
