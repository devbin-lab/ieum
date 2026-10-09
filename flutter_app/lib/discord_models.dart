import 'dart:convert';

import 'package:crypto/crypto.dart' as digest;

const discordSchema = 1;
const discordMaxDocumentBytes = 256 * 1024;

class DiscordConfigurationFailure implements Exception {
  const DiscordConfigurationFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Never discordInvalid() => throw const DiscordConfigurationFailure(
  'Discord 연결 정보의 형식 또는 승인 정보를 확인할 수 없습니다.',
);

Map<String, dynamic> discordObject(
  Object? value,
  Set<String> required, [
  Set<String> optional = const {},
]) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    discordInvalid();
  }
  final map = Map<String, dynamic>.from(value);
  if (!required.every(map.containsKey) ||
      map.keys.any(
        (key) => !required.contains(key) && !optional.contains(key),
      )) {
    discordInvalid();
  }
  return map;
}

Map<String, dynamic> discordDecode(String value) {
  if (utf8.encode(value).length > discordMaxDocumentBytes) discordInvalid();
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      discordInvalid();
    }
    return Map<String, dynamic>.from(decoded);
  } on DiscordConfigurationFailure {
    rethrow;
  } catch (_) {
    discordInvalid();
  }
}

String discordString(Object? value, {int max = 200, bool empty = false}) {
  if (value is! String ||
      value.length > max ||
      (!empty && value.isEmpty) ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    discordInvalid();
  }
  return value;
}

int discordInteger(Object? value, {int min = 0}) {
  if (value is! int || value < min || value > 9007199254740991) {
    discordInvalid();
  }
  return value;
}

String discordGithubId(Object? value) {
  final id = discordString(value, max: 23);
  if (!RegExp(r'^gh-[1-9][0-9]{0,19}$').hasMatch(id)) discordInvalid();
  return id;
}

String discordSnowflake(Object? value, {bool empty = false}) {
  final id = discordString(value, max: 20, empty: empty);
  if (id.isEmpty && empty) return id;
  if (!RegExp(r'^[1-9][0-9]{16,19}$').hasMatch(id) ||
      BigInt.parse(id) > BigInt.parse('18446744073709551615')) {
    discordInvalid();
  }
  return id;
}

String discordIdentifier(Object? value) {
  final id = discordString(value, max: 96);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) discordInvalid();
  return id;
}

String discordBytes(Object? value, int length) {
  final encoded = discordString(value, max: 512);
  try {
    final bytes = base64Url.decode(base64Url.normalize(encoded));
    if (bytes.length != length || base64Url.encode(bytes) != encoded) {
      discordInvalid();
    }
    return encoded;
  } catch (_) {
    discordInvalid();
  }
}

DateTime discordTimestamp(Object? value) {
  final text = discordString(value, max: 32);
  final time = DateTime.tryParse(text);
  if (time == null || !time.isUtc || time.toIso8601String() != text) {
    discordInvalid();
  }
  return time;
}

List<String> discordStrings(Object? value, {int max = 100}) {
  if (value is! List || value.length > max) discordInvalid();
  final list = value.map((e) => discordIdentifier(e)).toList();
  if (list.toSet().length != list.length) discordInvalid();
  return List.unmodifiable(list);
}

/// Canonical bytes are used only for this versioned protocol, not arbitrary JSON.
String discordCanonical(Object? value) {
  Object? sorted(Object? item) {
    if (item is Map<String, dynamic>) {
      final keys = item.keys.toList()..sort();
      return {for (final key in keys) key: sorted(item[key])};
    }
    if (item is List) return item.map(sorted).toList();
    if (item == null || item is String || item is bool || item is int) {
      return item;
    }
    discordInvalid();
  }

  return jsonEncode(sorted(value));
}

class DiscordProjectScope {
  DiscordProjectScope({
    required String repository,
    required String projectId,
    required String integrationBranch,
  }) : repository = repository.toLowerCase(),
       projectId = discordIdentifier(projectId),
       integrationBranch = discordString(integrationBranch) {
    if (!RegExp(r'^[a-z0-9_.-]+/[a-z0-9_.-]+$').hasMatch(this.repository) ||
        !RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(integrationBranch) ||
        integrationBranch.contains('..') ||
        integrationBranch.startsWith('/') ||
        integrationBranch.endsWith('/')) {
      discordInvalid();
    }
  }
  final String repository;
  final String projectId;
  final String integrationBranch;
  Map<String, dynamic> get json => {
    'repository': repository,
    'projectId': projectId,
    'integrationBranch': integrationBranch,
  };
  String get storageScope =>
      digest.sha256.convert(utf8.encode(discordCanonical(json))).toString();
  factory DiscordProjectScope.fromJson(Object? value) {
    final m = discordObject(value, {
      'repository',
      'projectId',
      'integrationBranch',
    });
    return DiscordProjectScope(
      repository: discordString(m['repository']),
      projectId: discordString(m['projectId']),
      integrationBranch: discordString(m['integrationBranch']),
    );
  }
  bool matches(DiscordProjectScope other) => storageScope == other.storageScope;
}

enum DiscordEventType { assigned, handedOff, statusChanged, completed }

class DiscordRoute {
  DiscordRoute({
    required String routeId,
    required String guildId,
    required String channelId,
    required String channelName,
    List<String> partIds = const [],
    Set<DiscordEventType> eventTypes = const {
      DiscordEventType.assigned,
      DiscordEventType.handedOff,
      DiscordEventType.statusChanged,
      DiscordEventType.completed,
    },
    this.enabled = true,
    this.secretVersion = 1,
    this.notificationVersion = 2,
  }) : routeId = discordIdentifier(routeId),
       guildId = discordSnowflake(guildId),
       channelId = discordSnowflake(channelId),
       channelName = discordString(channelName, max: 100),
       partIds = discordStrings(partIds),
       eventTypes = Set.unmodifiable(eventTypes) {
    if (secretVersion < 1 ||
        secretVersion > 9007199254740991 ||
        eventTypes.isEmpty ||
        !const {1, 2}.contains(notificationVersion)) {
      discordInvalid();
    }
  }
  final String routeId, guildId, channelId, channelName;
  final List<String> partIds;
  final Set<DiscordEventType> eventTypes;
  final bool enabled;
  final int secretVersion;
  final int notificationVersion;
  Set<DiscordEventType> get effectiveEventTypes => Set.unmodifiable({
    ...eventTypes,
    if (notificationVersion == 1 &&
        eventTypes.contains(DiscordEventType.handedOff))
      DiscordEventType.statusChanged,
  });
  Map<String, dynamic> get json => {
    'routeId': routeId,
    'guildId': guildId,
    'channelId': channelId,
    'channelName': channelName,
    'partIds': partIds,
    'eventTypes': eventTypes.map((e) => e.name).toList()..sort(),
    'enabled': enabled,
    'secretVersion': secretVersion,
    // Adding a field to legacy routes would invalidate their owner signature.
    if (notificationVersion == 2) 'notificationVersion': notificationVersion,
  };
  factory DiscordRoute.fromJson(Object? value) {
    final m = discordObject(
      value,
      {
        'routeId',
        'guildId',
        'channelId',
        'channelName',
        'partIds',
        'eventTypes',
        'enabled',
        'secretVersion',
      },
      {'notificationVersion'},
    );
    if (m['enabled'] is! bool) discordInvalid();
    final names = discordStrings(m['eventTypes'], max: 4);
    final types = <DiscordEventType>{};
    for (final name in names) {
      final matches = DiscordEventType.values.where((e) => e.name == name);
      if (matches.isEmpty) discordInvalid();
      types.add(matches.single);
    }
    return DiscordRoute(
      routeId: discordString(m['routeId']),
      guildId: discordString(m['guildId']),
      channelId: discordString(m['channelId']),
      channelName: discordString(m['channelName']),
      partIds: discordStrings(m['partIds']),
      eventTypes: types,
      enabled: m['enabled'],
      secretVersion: discordInteger(m['secretVersion'], min: 1),
      notificationVersion: m.containsKey('notificationVersion')
          ? discordInteger(m['notificationVersion'], min: 1)
          : 1,
    );
  }
}

class DiscordDeviceCertificate {
  DiscordDeviceCertificate({
    required String githubUserId,
    required String deviceId,
    required String encryptionPublicKey,
    required String signingPublicKey,
    this.revoked = false,
  }) : githubUserId = discordGithubId(githubUserId),
       deviceId = discordIdentifier(deviceId),
       encryptionPublicKey = discordBytes(encryptionPublicKey, 32),
       signingPublicKey = discordBytes(signingPublicKey, 32);
  final String githubUserId, deviceId, encryptionPublicKey, signingPublicKey;
  final bool revoked;
  Map<String, dynamic> get json => {
    'githubUserId': githubUserId,
    'deviceId': deviceId,
    'encryptionPublicKey': encryptionPublicKey,
    'signingPublicKey': signingPublicKey,
    'revoked': revoked,
  };
  factory DiscordDeviceCertificate.fromJson(Object? value) {
    final m = discordObject(value, {
      'githubUserId',
      'deviceId',
      'encryptionPublicKey',
      'signingPublicKey',
      'revoked',
    });
    if (m['revoked'] is! bool) discordInvalid();
    return DiscordDeviceCertificate(
      githubUserId: discordString(m['githubUserId']),
      deviceId: discordString(m['deviceId']),
      encryptionPublicKey: discordString(m['encryptionPublicKey']),
      signingPublicKey: discordString(m['signingPublicKey']),
      revoked: m['revoked'],
    );
  }
}

class DiscordConfiguration {
  DiscordConfiguration({
    required this.scope,
    required String ownerId,
    required String ownerPublicKey,
    required this.configRevision,
    required this.revocationEpoch,
    required this.updatedAt,
    List<DiscordRoute> routes = const [],
    List<DiscordDeviceCertificate> devices = const [],
    this.signature = '',
  }) : ownerId = discordGithubId(ownerId),
       ownerPublicKey = discordBytes(ownerPublicKey, 32),
       routes = List.unmodifiable(routes),
       devices = List.unmodifiable(devices) {
    if (configRevision < 1 ||
        revocationEpoch < 0 ||
        !updatedAt.isUtc ||
        routes.length > 100 ||
        devices.length > 200 ||
        routes.map((e) => e.routeId).toSet().length != routes.length ||
        devices.map((e) => e.deviceId).toSet().length != devices.length) {
      discordInvalid();
    }
    if (signature.isNotEmpty) discordBytes(signature, 64);
  }
  final DiscordProjectScope scope;
  final String ownerId, ownerPublicKey, signature;
  final int configRevision, revocationEpoch;
  final DateTime updatedAt;
  final List<DiscordRoute> routes;
  final List<DiscordDeviceCertificate> devices;
  Map<String, dynamic> get unsignedJson => {
    'schema': discordSchema,
    'scope': scope.json,
    'ownerId': ownerId,
    'ownerPublicKey': ownerPublicKey,
    'configRevision': configRevision,
    'revocationEpoch': revocationEpoch,
    'updatedAt': updatedAt.toIso8601String(),
    'routes': routes.map((e) => e.json).toList(),
    'devices': devices.map((e) => e.json).toList(),
  };
  Map<String, dynamic> get json => {...unsignedJson, 'signature': signature};
  String get fingerprint =>
      digest.sha256.convert(utf8.encode(discordCanonical(json))).toString();
  DiscordConfiguration signed(String signature) => DiscordConfiguration(
    scope: scope,
    ownerId: ownerId,
    ownerPublicKey: ownerPublicKey,
    configRevision: configRevision,
    revocationEpoch: revocationEpoch,
    updatedAt: updatedAt,
    routes: routes,
    devices: devices,
    signature: signature,
  );
  factory DiscordConfiguration.fromJson(Object? value) {
    final m = discordObject(value, {
      'schema',
      'scope',
      'ownerId',
      'ownerPublicKey',
      'configRevision',
      'revocationEpoch',
      'updatedAt',
      'routes',
      'devices',
      'signature',
    });
    if (m['schema'] != discordSchema ||
        m['routes'] is! List ||
        m['devices'] is! List ||
        (m['routes'] as List).length > 100 ||
        (m['devices'] as List).length > 200) {
      discordInvalid();
    }
    return DiscordConfiguration(
      scope: DiscordProjectScope.fromJson(m['scope']),
      ownerId: discordString(m['ownerId']),
      ownerPublicKey: discordString(m['ownerPublicKey']),
      configRevision: discordInteger(m['configRevision'], min: 1),
      revocationEpoch: discordInteger(m['revocationEpoch']),
      updatedAt: discordTimestamp(m['updatedAt']),
      routes: (m['routes'] as List).map(DiscordRoute.fromJson).toList(),
      devices: (m['devices'] as List)
          .map(DiscordDeviceCertificate.fromJson)
          .toList(),
      signature: discordBytes(m['signature'], 64),
    );
  }
}

class DiscordWebhookEnvelope {
  DiscordWebhookEnvelope({
    required this.scope,
    required String routeId,
    required String guildId,
    required String channelId,
    required String recipientDeviceId,
    required this.secretVersion,
    required this.configRevision,
    required this.revocationEpoch,
    required String ephemeralPublicKey,
    required String nonce,
    required String ciphertext,
    required String mac,
    this.signature = '',
  }) : routeId = discordIdentifier(routeId),
       guildId = discordSnowflake(guildId),
       channelId = discordSnowflake(channelId),
       recipientDeviceId = discordIdentifier(recipientDeviceId),
       ephemeralPublicKey = discordBytes(ephemeralPublicKey, 32),
       nonce = discordBytes(nonce, 12),
       mac = discordBytes(mac, 16),
       ciphertext = discordString(ciphertext, max: 2048) {
    if (secretVersion < 1 || configRevision < 1 || revocationEpoch < 0) {
      discordInvalid();
    }
    try {
      final bytes = base64Url.decode(base64Url.normalize(ciphertext));
      if (bytes.isEmpty ||
          bytes.length > 1024 ||
          base64Url.encode(bytes) != ciphertext) {
        discordInvalid();
      }
    } catch (_) {
      discordInvalid();
    }
    if (signature.isNotEmpty) discordBytes(signature, 64);
  }
  final DiscordProjectScope scope;
  final String routeId,
      guildId,
      channelId,
      recipientDeviceId,
      ephemeralPublicKey,
      nonce,
      ciphertext,
      mac,
      signature;
  final int secretVersion, configRevision, revocationEpoch;
  Map<String, dynamic> get context => {
    'schema': discordSchema,
    'scope': scope.json,
    'routeId': routeId,
    'guildId': guildId,
    'channelId': channelId,
    'recipientDeviceId': recipientDeviceId,
    'secretVersion': secretVersion,
    'configRevision': configRevision,
    'revocationEpoch': revocationEpoch,
    'ephemeralPublicKey': ephemeralPublicKey,
  };
  Map<String, dynamic> get unsignedJson => {
    ...context,
    'nonce': nonce,
    'ciphertext': ciphertext,
    'mac': mac,
  };
  Map<String, dynamic> get json => {...unsignedJson, 'signature': signature};
  DiscordWebhookEnvelope signed(String value) => DiscordWebhookEnvelope(
    scope: scope,
    routeId: routeId,
    guildId: guildId,
    channelId: channelId,
    recipientDeviceId: recipientDeviceId,
    secretVersion: secretVersion,
    configRevision: configRevision,
    revocationEpoch: revocationEpoch,
    ephemeralPublicKey: ephemeralPublicKey,
    nonce: nonce,
    ciphertext: ciphertext,
    mac: mac,
    signature: value,
  );
  factory DiscordWebhookEnvelope.fromJson(Object? value) {
    final m = discordObject(value, {
      'schema',
      'scope',
      'routeId',
      'guildId',
      'channelId',
      'recipientDeviceId',
      'secretVersion',
      'configRevision',
      'revocationEpoch',
      'ephemeralPublicKey',
      'nonce',
      'ciphertext',
      'mac',
      'signature',
    });
    if (m['schema'] != discordSchema) discordInvalid();
    return DiscordWebhookEnvelope(
      scope: DiscordProjectScope.fromJson(m['scope']),
      routeId: discordString(m['routeId']),
      guildId: discordString(m['guildId']),
      channelId: discordString(m['channelId']),
      recipientDeviceId: discordString(m['recipientDeviceId']),
      secretVersion: discordInteger(m['secretVersion'], min: 1),
      configRevision: discordInteger(m['configRevision'], min: 1),
      revocationEpoch: discordInteger(m['revocationEpoch']),
      ephemeralPublicKey: discordString(m['ephemeralPublicKey']),
      nonce: discordString(m['nonce']),
      ciphertext: discordString(m['ciphertext']),
      mac: discordString(m['mac']),
      signature: discordBytes(m['signature'], 64),
    );
  }
}

class DiscordPairingRequest {
  DiscordPairingRequest({
    required this.scope,
    required String pairingId,
    required String githubUserId,
    required String ownerPublicKey,
    required this.configRevision,
    required this.revocationEpoch,
    required String configFingerprint,
    required this.expiresAt,
    required this.device,
    required String proof,
    this.signature = '',
  }) : pairingId = discordIdentifier(pairingId),
       githubUserId = discordGithubId(githubUserId),
       ownerPublicKey = discordBytes(ownerPublicKey, 32),
       configFingerprint = discordString(configFingerprint, max: 64),
       proof = discordBytes(proof, 32) {
    if (githubUserId != device.githubUserId ||
        !expiresAt.isUtc ||
        configRevision < 1 ||
        revocationEpoch < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(configFingerprint) ||
        device.revoked) {
      discordInvalid();
    }
    if (signature.isNotEmpty) discordBytes(signature, 64);
  }
  final DiscordProjectScope scope;
  final String pairingId,
      githubUserId,
      ownerPublicKey,
      configFingerprint,
      proof,
      signature;
  final int configRevision, revocationEpoch;
  final DateTime expiresAt;
  final DiscordDeviceCertificate device;
  Map<String, dynamic> get proofJson => {
    'schema': discordSchema,
    'scope': scope.json,
    'pairingId': pairingId,
    'githubUserId': githubUserId,
    'ownerPublicKey': ownerPublicKey,
    'configRevision': configRevision,
    'revocationEpoch': revocationEpoch,
    'configFingerprint': configFingerprint,
    'expiresAt': expiresAt.toIso8601String(),
    'device': device.json,
  };
  Map<String, dynamic> get unsignedJson => {...proofJson, 'proof': proof};
  Map<String, dynamic> get json => {...unsignedJson, 'signature': signature};
  DiscordPairingRequest signed(String value) => DiscordPairingRequest(
    scope: scope,
    pairingId: pairingId,
    githubUserId: githubUserId,
    ownerPublicKey: ownerPublicKey,
    configRevision: configRevision,
    revocationEpoch: revocationEpoch,
    configFingerprint: configFingerprint,
    expiresAt: expiresAt,
    device: device,
    proof: proof,
    signature: value,
  );
  factory DiscordPairingRequest.fromJson(Object? value) {
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
      'device',
      'proof',
      'signature',
    });
    if (m['schema'] != discordSchema) discordInvalid();
    return DiscordPairingRequest(
      scope: DiscordProjectScope.fromJson(m['scope']),
      pairingId: discordString(m['pairingId']),
      githubUserId: discordString(m['githubUserId']),
      ownerPublicKey: discordString(m['ownerPublicKey']),
      configRevision: discordInteger(m['configRevision'], min: 1),
      revocationEpoch: discordInteger(m['revocationEpoch']),
      configFingerprint: discordString(m['configFingerprint']),
      expiresAt: discordTimestamp(m['expiresAt']),
      device: DiscordDeviceCertificate.fromJson(m['device']),
      proof: discordString(m['proof']),
      signature: discordBytes(m['signature'], 64),
    );
  }
}
