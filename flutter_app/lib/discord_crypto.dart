import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as digest;
import 'package:uuid/uuid.dart';

import 'discord_models.dart';
import 'discord_transport.dart' show parseDiscordWebhookUrl;

List<int> _decoded(String value) =>
    base64Url.decode(base64Url.normalize(value));

class DiscordDeviceIdentity {
  DiscordDeviceIdentity({
    required String deviceId,
    required String encryptionSeed,
    required String signingSeed,
  }) : deviceId = discordIdentifier(deviceId),
       encryptionSeed = discordBytes(encryptionSeed, 32),
       signingSeed = discordBytes(signingSeed, 32);
  final String deviceId;
  final String encryptionSeed;
  final String signingSeed;

  /// Only the isolated OS vault may persist this representation.
  Map<String, dynamic> get secretJson => {
    'schema': discordSchema,
    'deviceId': deviceId,
    'encryptionSeed': encryptionSeed,
    'signingSeed': signingSeed,
  };
  factory DiscordDeviceIdentity.fromSecretJson(Object? value) {
    final m = discordObject(value, {
      'schema',
      'deviceId',
      'encryptionSeed',
      'signingSeed',
    });
    if (m['schema'] != discordSchema) discordInvalid();
    return DiscordDeviceIdentity(
      deviceId: discordString(m['deviceId']),
      encryptionSeed: discordString(m['encryptionSeed']),
      signingSeed: discordString(m['signingSeed']),
    );
  }
  @override
  String toString() => 'DiscordDeviceIdentity($deviceId)';
}

/// A short-lived out-of-band invitation; never upload the secretJson/code.
class DiscordPairingOffer {
  DiscordPairingOffer({
    required this.scope,
    required String pairingId,
    required String githubUserId,
    required String ownerPublicKey,
    required this.configRevision,
    required this.revocationEpoch,
    required String configFingerprint,
    required this.expiresAt,
    required String secret,
  }) : pairingId = discordIdentifier(pairingId),
       githubUserId = discordGithubId(githubUserId),
       ownerPublicKey = discordBytes(ownerPublicKey, 32),
       secret = discordBytes(secret, 32),
       configFingerprint = discordString(configFingerprint, max: 64) {
    if (!expiresAt.isUtc ||
        configRevision < 1 ||
        revocationEpoch < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(configFingerprint)) {
      discordInvalid();
    }
  }
  final DiscordProjectScope scope;
  final String pairingId,
      githubUserId,
      ownerPublicKey,
      configFingerprint,
      secret;
  final int configRevision, revocationEpoch;
  final DateTime expiresAt;
  Map<String, dynamic> get secretJson => {
    'schema': discordSchema,
    'scope': scope.json,
    'pairingId': pairingId,
    'githubUserId': githubUserId,
    'ownerPublicKey': ownerPublicKey,
    'configRevision': configRevision,
    'revocationEpoch': revocationEpoch,
    'configFingerprint': configFingerprint,
    'expiresAt': expiresAt.toIso8601String(),
    'secret': secret,
  };
  String get code =>
      'ieum-discord-v1:${base64Url.encode(utf8.encode(discordCanonical(secretJson)))}';
  factory DiscordPairingOffer.fromSecretJson(Object? value) {
    final m = discordObject(value, {
      'schema',
      'scope',
      'pairingId',
      'githubUserId',
      'ownerPublicKey',
      'configRevision',
      'revocationEpoch',
      'configFingerprint',
      'expiresAt',
      'secret',
    });
    if (m['schema'] != discordSchema) discordInvalid();
    return DiscordPairingOffer(
      scope: DiscordProjectScope.fromJson(m['scope']),
      pairingId: discordString(m['pairingId']),
      githubUserId: discordString(m['githubUserId']),
      ownerPublicKey: discordString(m['ownerPublicKey']),
      configRevision: discordInteger(m['configRevision'], min: 1),
      revocationEpoch: discordInteger(m['revocationEpoch']),
      configFingerprint: discordString(m['configFingerprint']),
      expiresAt: discordTimestamp(m['expiresAt']),
      secret: discordString(m['secret']),
    );
  }
  factory DiscordPairingOffer.fromCode(String value) {
    if (!value.startsWith('ieum-discord-v1:') || value.length > 3000) {
      discordInvalid();
    }
    try {
      return DiscordPairingOffer.fromSecretJson(
        discordDecode(utf8.decode(_decoded(value.substring(16)))),
      );
    } on DiscordConfigurationFailure {
      rethrow;
    } catch (_) {
      discordInvalid();
    }
  }
  @override
  String toString() => 'DiscordPairingOffer($pairingId)';
}

/// All algorithms come from package:cryptography; no protocol secrets are logged.
class DiscordCrypto {
  final _x25519 = X25519();
  final _ed25519 = Ed25519();
  final _aes = AesGcm.with256bits();
  final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  Future<DiscordDeviceIdentity> generateIdentity() async {
    final encryption = await (await _x25519.newKeyPair())
        .extractPrivateKeyBytes();
    final signing = await (await _ed25519.newKeyPair())
        .extractPrivateKeyBytes();
    return DiscordDeviceIdentity(
      deviceId: const Uuid().v4(),
      encryptionSeed: base64Url.encode(encryption),
      signingSeed: base64Url.encode(signing),
    );
  }

  Future<SimpleKeyPair> _encryption(DiscordDeviceIdentity identity) =>
      _x25519.newKeyPairFromSeed(_decoded(identity.encryptionSeed));
  Future<SimpleKeyPair> _signing(DiscordDeviceIdentity identity) =>
      _ed25519.newKeyPairFromSeed(_decoded(identity.signingSeed));

  Future<DiscordDeviceCertificate> certificate(
    DiscordDeviceIdentity identity,
    String githubUserId,
  ) async {
    final encryption = await (await _encryption(identity)).extractPublicKey();
    final signing = await (await _signing(identity)).extractPublicKey();
    return DiscordDeviceCertificate(
      githubUserId: githubUserId,
      deviceId: identity.deviceId,
      encryptionPublicKey: base64Url.encode(encryption.bytes),
      signingPublicKey: base64Url.encode(signing.bytes),
    );
  }

  Future<String> signingPublicKey(DiscordDeviceIdentity identity) async =>
      base64Url.encode(
        (await (await _signing(identity)).extractPublicKey()).bytes,
      );

  List<int> _signedBytes(String domain, Map<String, dynamic> value) =>
      utf8.encode('ieum-discord-v1/$domain\n${discordCanonical(value)}');

  Future<String> sign(
    String domain,
    Map<String, dynamic> value,
    DiscordDeviceIdentity identity,
  ) async => base64Url.encode(
    (await _ed25519.sign(
      _signedBytes(domain, value),
      keyPair: await _signing(identity),
    )).bytes,
  );

  Future<bool> verify(
    String domain,
    Map<String, dynamic> value,
    String signature,
    String publicKey,
  ) async {
    try {
      discordBytes(signature, 64);
      discordBytes(publicKey, 32);
      return await _ed25519.verify(
        _signedBytes(domain, value),
        signature: Signature(
          _decoded(signature),
          publicKey: SimplePublicKey(
            _decoded(publicKey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  Future<DiscordConfiguration> signConfiguration(
    DiscordConfiguration config,
    DiscordDeviceIdentity owner,
  ) async {
    if (await signingPublicKey(owner) != config.ownerPublicKey) {
      discordInvalid();
    }
    return config.signed(
      await sign('configuration', config.unsignedJson, owner),
    );
  }

  Future<bool> verifyConfiguration(
    DiscordConfiguration config,
    String trustedOwnerKey,
  ) async =>
      config.ownerPublicKey == trustedOwnerKey &&
      await verify(
        'configuration',
        config.unsignedJson,
        config.signature,
        trustedOwnerKey,
      );

  Future<SecretKey> _envelopeKey(
    SecretKey secret,
    Map<String, dynamic> context,
  ) async {
    final bytes = await secret.extractBytes();
    // RFC 7748: reject low-order remote points (all-zero shared secret).
    if (bytes.every((byte) => byte == 0)) discordInvalid();
    return _hkdf.deriveKey(
      secretKey: SecretKey(bytes),
      nonce: digest.sha256
          .convert(utf8.encode('ieum-discord-v1/envelope'))
          .bytes,
      info: utf8.encode(discordCanonical(context)),
    );
  }

  Future<DiscordWebhookEnvelope> sealWebhook({
    required DiscordConfiguration configuration,
    required DiscordRoute route,
    required DiscordDeviceCertificate recipient,
    required String webhookUrl,
    required DiscordDeviceIdentity owner,
  }) async {
    if (recipient.revoked ||
        configuration.ownerPublicKey != await signingPublicKey(owner) ||
        !configuration.routes.any(
          (e) => discordCanonical(e.json) == discordCanonical(route.json),
        ) ||
        !configuration.devices.any(
          (e) => discordCanonical(e.json) == discordCanonical(recipient.json),
        )) {
      discordInvalid();
    }
    validateWebhook(webhookUrl);
    final ephemeral = await _x25519.newKeyPair();
    final publicKey = base64Url.encode(
      (await ephemeral.extractPublicKey()).bytes,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: SimplePublicKey(
        _decoded(recipient.encryptionPublicKey),
        type: KeyPairType.x25519,
      ),
    );
    final context = {
      'schema': discordSchema,
      'scope': configuration.scope.json,
      'routeId': route.routeId,
      'guildId': route.guildId,
      'channelId': route.channelId,
      'recipientDeviceId': recipient.deviceId,
      'secretVersion': route.secretVersion,
      'configRevision': configuration.configRevision,
      'revocationEpoch': configuration.revocationEpoch,
      'ephemeralPublicKey': publicKey,
    };
    final box = await _aes.encrypt(
      utf8.encode(webhookUrl),
      secretKey: await _envelopeKey(shared, context),
      aad: utf8.encode(discordCanonical(context)),
    );
    final envelope = DiscordWebhookEnvelope(
      scope: configuration.scope,
      routeId: route.routeId,
      guildId: route.guildId,
      channelId: route.channelId,
      recipientDeviceId: recipient.deviceId,
      secretVersion: route.secretVersion,
      configRevision: configuration.configRevision,
      revocationEpoch: configuration.revocationEpoch,
      ephemeralPublicKey: publicKey,
      nonce: base64Url.encode(box.nonce),
      ciphertext: base64Url.encode(box.cipherText),
      mac: base64Url.encode(box.mac.bytes),
    );
    return envelope.signed(
      await sign('envelope', envelope.unsignedJson, owner),
    );
  }

  Future<String> openWebhook({
    required DiscordWebhookEnvelope envelope,
    required DiscordConfiguration configuration,
    required DiscordRoute route,
    required DiscordDeviceIdentity identity,
    required String accountId,
  }) async {
    final certificates = configuration.devices.where(
      (e) => e.deviceId == identity.deviceId,
    );
    if (!envelope.scope.matches(configuration.scope) ||
        envelope.recipientDeviceId != identity.deviceId ||
        envelope.routeId != route.routeId ||
        envelope.guildId != route.guildId ||
        envelope.channelId != route.channelId ||
        envelope.secretVersion != route.secretVersion ||
        envelope.configRevision != configuration.configRevision ||
        envelope.revocationEpoch != configuration.revocationEpoch ||
        certificates.length != 1 ||
        certificates.single.revoked ||
        certificates.single.githubUserId != accountId ||
        !configuration.routes.any(
          (e) => discordCanonical(e.json) == discordCanonical(route.json),
        ) ||
        !await verify(
          'envelope',
          envelope.unsignedJson,
          envelope.signature,
          configuration.ownerPublicKey,
        )) {
      discordInvalid();
    }
    final ownCertificate = await certificate(identity, accountId);
    if (ownCertificate.encryptionPublicKey !=
            certificates.single.encryptionPublicKey ||
        ownCertificate.signingPublicKey !=
            certificates.single.signingPublicKey) {
      discordInvalid();
    }
    try {
      final shared = await _x25519.sharedSecretKey(
        keyPair: await _encryption(identity),
        remotePublicKey: SimplePublicKey(
          _decoded(envelope.ephemeralPublicKey),
          type: KeyPairType.x25519,
        ),
      );
      final clear = await _aes.decrypt(
        SecretBox(
          _decoded(envelope.ciphertext),
          nonce: _decoded(envelope.nonce),
          mac: Mac(_decoded(envelope.mac)),
        ),
        secretKey: await _envelopeKey(shared, envelope.context),
        aad: utf8.encode(discordCanonical(envelope.context)),
      );
      final url = utf8.decode(clear);
      validateWebhook(url);
      return url;
    } catch (_) {
      discordInvalid();
    }
  }

  void validateWebhook(String value) {
    try {
      parseDiscordWebhookUrl(value);
    } catch (_) {
      discordInvalid();
    }
  }

  DiscordPairingOffer createPairingOffer(
    DiscordConfiguration config,
    String targetGithubId,
    DateTime expiresAt,
  ) {
    final random = Random.secure();
    return DiscordPairingOffer(
      scope: config.scope,
      pairingId: const Uuid().v4(),
      githubUserId: targetGithubId,
      ownerPublicKey: config.ownerPublicKey,
      configRevision: config.configRevision,
      revocationEpoch: config.revocationEpoch,
      configFingerprint: config.fingerprint,
      expiresAt: expiresAt,
      secret: base64Url.encode(List.generate(32, (_) => random.nextInt(256))),
    );
  }

  Future<String> _pairingProof(
    DiscordPairingOffer offer,
    Map<String, dynamic> value,
  ) async => base64Url.encode(
    (await Hmac.sha256().calculateMac(
      _signedBytes('pairing-proof', value),
      secretKey: SecretKey(_decoded(offer.secret)),
    )).bytes,
  );

  Future<DiscordPairingRequest> pairingRequest(
    DiscordPairingOffer offer,
    DiscordDeviceIdentity identity,
    String accountId,
    DateTime now,
  ) async {
    if (accountId != offer.githubUserId ||
        !now.isBefore(offer.expiresAt) ||
        offer.expiresAt.difference(now) > const Duration(minutes: 16)) {
      discordInvalid();
    }
    final device = await certificate(identity, accountId);
    final unsigned = {
      'schema': discordSchema,
      'scope': offer.scope.json,
      'pairingId': offer.pairingId,
      'githubUserId': offer.githubUserId,
      'ownerPublicKey': offer.ownerPublicKey,
      'configRevision': offer.configRevision,
      'revocationEpoch': offer.revocationEpoch,
      'configFingerprint': offer.configFingerprint,
      'expiresAt': offer.expiresAt.toIso8601String(),
      'device': device.json,
    };
    final request = DiscordPairingRequest(
      scope: offer.scope,
      pairingId: offer.pairingId,
      githubUserId: accountId,
      ownerPublicKey: offer.ownerPublicKey,
      configRevision: offer.configRevision,
      revocationEpoch: offer.revocationEpoch,
      configFingerprint: offer.configFingerprint,
      expiresAt: offer.expiresAt,
      device: device,
      proof: await _pairingProof(offer, unsigned),
    );
    return request.signed(
      await sign('pairing-request', request.unsignedJson, identity),
    );
  }

  Future<bool> verifyPairingRequest(
    DiscordPairingOffer offer,
    DiscordPairingRequest request,
    DateTime now,
  ) async {
    if (!offer.scope.matches(request.scope) ||
        offer.pairingId != request.pairingId ||
        offer.githubUserId != request.githubUserId ||
        offer.ownerPublicKey != request.ownerPublicKey ||
        offer.configRevision != request.configRevision ||
        offer.revocationEpoch != request.revocationEpoch ||
        offer.configFingerprint != request.configFingerprint ||
        offer.expiresAt != request.expiresAt ||
        !now.isBefore(offer.expiresAt)) {
      return false;
    }
    final expected = _decoded(await _pairingProof(offer, request.proofJson));
    final actual = _decoded(request.proof);
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ actual[i];
    }
    return difference == 0 &&
        await verify(
          'pairing-request',
          request.unsignedJson,
          request.signature,
          request.device.signingPublicKey,
        );
  }
}
