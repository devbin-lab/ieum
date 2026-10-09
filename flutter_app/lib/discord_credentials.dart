import 'discord_crypto.dart';
import 'discord_models.dart';
import 'discord_vault.dart';

class DiscordTrustState {
  DiscordTrustState({
    required String ownerId,
    required String ownerPublicKey,
    required this.configRevision,
    required this.revocationEpoch,
    required String configFingerprint,
  }) : ownerId = discordGithubId(ownerId),
       ownerPublicKey = discordBytes(ownerPublicKey, 32),
       configFingerprint = discordString(configFingerprint, max: 64) {
    if (configRevision < 1 ||
        revocationEpoch < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(configFingerprint)) {
      discordInvalid();
    }
  }
  final String ownerId, ownerPublicKey, configFingerprint;
  final int configRevision, revocationEpoch;
  Map<String, dynamic> get json => {
    'schema': discordSchema,
    'ownerId': ownerId,
    'ownerPublicKey': ownerPublicKey,
    'configRevision': configRevision,
    'revocationEpoch': revocationEpoch,
    'configFingerprint': configFingerprint,
  };
  factory DiscordTrustState.fromJson(Object? value) {
    final m = discordObject(value, {
      'schema',
      'ownerId',
      'ownerPublicKey',
      'configRevision',
      'revocationEpoch',
      'configFingerprint',
    });
    if (m['schema'] != discordSchema) discordInvalid();
    return DiscordTrustState(
      ownerId: discordString(m['ownerId']),
      ownerPublicKey: discordString(m['ownerPublicKey']),
      configRevision: discordInteger(m['configRevision'], min: 1),
      revocationEpoch: discordInteger(m['revocationEpoch']),
      configFingerprint: discordString(m['configFingerprint']),
    );
  }
  factory DiscordTrustState.fromConfiguration(DiscordConfiguration config) =>
      DiscordTrustState(
        ownerId: config.ownerId,
        ownerPublicKey: config.ownerPublicKey,
        configRevision: config.configRevision,
        revocationEpoch: config.revocationEpoch,
        configFingerprint: config.fingerprint,
      );

  void check(DiscordConfiguration config) {
    if (config.ownerId != ownerId ||
        config.ownerPublicKey != ownerPublicKey ||
        config.configRevision < configRevision ||
        config.revocationEpoch < revocationEpoch ||
        (config.configRevision == configRevision &&
            config.fingerprint != configFingerprint)) {
      throw const DiscordConfigurationFailure(
        'Discord 연결 설정이 이전 버전이거나 승인된 설정과 다릅니다.',
      );
    }
  }
}

/// Private keys, trust high-water marks and webhook tokens are vault-only.
class DiscordCredentials {
  DiscordCredentials({
    required this.vault,
    required String accountId,
    required this.scope,
    DiscordCrypto? crypto,
  }) : accountId = discordGithubId(accountId),
       crypto = crypto ?? DiscordCrypto();
  final DiscordSecretVault vault;
  final String accountId;
  final DiscordProjectScope scope;
  final DiscordCrypto crypto;
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _queue.then((_) => operation());
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<String?> _read(String key) => vault.read(
    accountId: accountId,
    projectScope: scope.storageScope,
    key: key,
  );
  Future<void> _write(String key, Map<String, dynamic> value) => vault.write(
    accountId: accountId,
    projectScope: scope.storageScope,
    key: key,
    value: discordCanonical(value),
  );
  Future<void> _delete(String key) => vault.delete(
    accountId: accountId,
    projectScope: scope.storageScope,
    key: key,
  );

  Future<DiscordDeviceIdentity> getOrCreateIdentity() => _serial(() async {
    final stored = await _read('device-key');
    if (stored != null) {
      return DiscordDeviceIdentity.fromSecretJson(discordDecode(stored));
    }
    final identity = await crypto.generateIdentity();
    await _write('device-key', identity.secretJson);
    return identity;
  });

  Future<DiscordTrustState?> loadTrust() async {
    final stored = await _read('trust-state');
    return stored == null
        ? null
        : DiscordTrustState.fromJson(discordDecode(stored));
  }

  Future<void> pinTrust(DiscordTrustState trust) => _serial(() async {
    final current = await loadTrust();
    if (current != null &&
        discordCanonical(current.json) != discordCanonical(trust.json)) {
      throw const DiscordConfigurationFailure(
        '이미 신뢰한 Discord 연결이 있습니다. 기존 연결을 해제한 뒤 다시 연결하세요.',
      );
    }
    await _write('trust-state', trust.json);
  });

  Future<void> acceptConfiguration(DiscordConfiguration config) => _serial(
    () async {
      final trust = await loadTrust();
      if (trust == null) {
        throw const DiscordConfigurationFailure('이 기기의 Discord 연결 승인이 필요합니다.');
      }
      trust.check(config);
      if (!scope.matches(config.scope) ||
          !await crypto.verifyConfiguration(config, trust.ownerPublicKey)) {
        discordInvalid();
      }
      await _write(
        'trust-state',
        DiscordTrustState.fromConfiguration(config).json,
      );
    },
  );

  Future<void> savePairingOffer(DiscordPairingOffer offer) {
    if (!offer.scope.matches(scope)) discordInvalid();
    return _write('pairing-${offer.pairingId}', offer.secretJson);
  }

  Future<DiscordPairingOffer?> loadPairingOffer(String pairingId) async {
    final stored = await _read('pairing-${discordIdentifier(pairingId)}');
    return stored == null
        ? null
        : DiscordPairingOffer.fromSecretJson(discordDecode(stored));
  }

  Future<void> deletePairingOffer(String pairingId) =>
      _delete('pairing-${discordIdentifier(pairingId)}');

  Future<void> storeWebhook(
    DiscordConfiguration config,
    DiscordRoute route,
    String webhookUrl,
  ) async {
    crypto.validateWebhook(webhookUrl);
    final trust = await loadTrust();
    if (trust == null || !scope.matches(config.scope)) discordInvalid();
    if (!config.routes.any(
      (e) => discordCanonical(e.json) == discordCanonical(route.json),
    )) {
      discordInvalid();
    }
    trust.check(config);
    if (!await crypto.verifyConfiguration(config, trust.ownerPublicKey)) {
      discordInvalid();
    }
    await _write('route-${route.routeId}', {
      'schema': discordSchema,
      'routeId': route.routeId,
      'guildId': route.guildId,
      'channelId': route.channelId,
      'secretVersion': route.secretVersion,
      'configRevision': config.configRevision,
      'revocationEpoch': config.revocationEpoch,
      'webhookUrl': webhookUrl,
    });
  }

  Future<String?> readWebhook(
    DiscordConfiguration config,
    DiscordRoute route,
  ) async {
    final trust = await loadTrust();
    if (trust == null || !scope.matches(config.scope) || !route.enabled) {
      return null;
    }
    trust.check(config);
    if (!await crypto.verifyConfiguration(config, trust.ownerPublicKey)) {
      discordInvalid();
    }
    final identity = await getOrCreateIdentity();
    final own = config.devices.where((e) => e.deviceId == identity.deviceId);
    if (own.length != 1 ||
        own.single.revoked ||
        own.single.githubUserId != accountId) {
      return null;
    }
    final actual = await crypto.certificate(identity, accountId);
    if (actual.encryptionPublicKey != own.single.encryptionPublicKey ||
        actual.signingPublicKey != own.single.signingPublicKey) {
      discordInvalid();
    }
    final stored = await _read('route-${route.routeId}');
    if (stored == null) return null;
    final m = discordObject(discordDecode(stored), {
      'schema',
      'routeId',
      'guildId',
      'channelId',
      'secretVersion',
      'configRevision',
      'revocationEpoch',
      'webhookUrl',
    });
    if (m['schema'] != discordSchema ||
        m['routeId'] != route.routeId ||
        m['guildId'] != route.guildId ||
        m['channelId'] != route.channelId ||
        m['secretVersion'] != route.secretVersion ||
        m['configRevision'] != config.configRevision ||
        m['revocationEpoch'] != config.revocationEpoch) {
      return null;
    }
    return discordString(m['webhookUrl'], max: 1024);
  }

  /// Owner-only access to old tokens while atomically advancing configuration.
  Future<String?> ownerWebhook(String routeId) async {
    final stored = await _read('route-${discordIdentifier(routeId)}');
    if (stored == null) return null;
    final m = discordObject(discordDecode(stored), {
      'schema',
      'routeId',
      'guildId',
      'channelId',
      'secretVersion',
      'configRevision',
      'revocationEpoch',
      'webhookUrl',
    });
    if (m['schema'] != discordSchema || m['routeId'] != routeId) {
      discordInvalid();
    }
    return discordString(m['webhookUrl'], max: 1024);
  }

  Future<void> deleteWebhook(String routeId) =>
      _delete('route-${discordIdentifier(routeId)}');
}
