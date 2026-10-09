import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'discord_configuration.dart';
import 'discord_credentials.dart';
import 'discord_models.dart';
import 'discord_outbox.dart';
import 'discord_process_lock.dart';
import 'discord_settings.dart';
import 'discord_transport.dart';
import 'discord_vault.dart';
import 'github_sync.dart';
import 'project_service.dart';
import 'store.dart';

/// Only non-secret signed data and encrypted envelopes use the project repo.
class GitHubDiscordConfigurationTransport
    implements DiscordConfigurationTransport {
  GitHubDiscordConfigurationTransport(this.session, this.config, this.guard);
  final GitHubSession session;
  final GitHubConfig config;
  final void Function() guard;
  void _path(String path) {
    if (!path.startsWith('.ieum/notifications/') ||
        path.contains('..') ||
        !RegExp(r'^[A-Za-z0-9_./-]+$').hasMatch(path)) {
      throw const DiscordConfigurationFailure('알림 설정 파일 경로를 확인하세요.');
    }
  }

  @override
  Future<DiscordRemoteDocument?> read(String path) async {
    guard();
    _path(path);
    final file = await session.readJson(config, path);
    guard();
    if (file == null) return null;
    final text = jsonEncode(file['data']);
    if (utf8.encode(text).length > 256 * 1024) {
      throw const DiscordConfigurationFailure('알림 설정 파일의 크기를 확인하세요.');
    }
    return DiscordRemoteDocument(text, file['sha'] as String);
  }

  @override
  Future<void> write(
    String path,
    String json, {
    String? expectedRevision,
  }) async {
    guard();
    _path(path);
    if (utf8.encode(json).length > 256 * 1024) {
      throw const DiscordConfigurationFailure('알림 설정 파일의 크기를 확인하세요.');
    }
    await session.writeJson(
      config,
      path,
      Map<String, dynamic>.from(jsonDecode(json)),
      sha: expectedRevision,
      message: 'Update IEUM Discord notification settings',
    );
    guard();
  }

  @override
  Future<List<String>> list(String prefix) async {
    guard();
    _path(prefix);
    try {
      final result = await session.api.call(
        'GET',
        '/repos/${config.slug}/contents/$prefix',
        query: {'ref': config.base},
      );
      guard();
      final maxItems = prefix.startsWith('.ieum/notifications/envelopes')
          ? 2000
          : 250;
      if (result is! List || result.length > maxItems) {
        throw const DiscordConfigurationFailure('알림 연결 요청 목록을 확인하세요.');
      }
      final paths = <String>[];
      for (final item in result) {
        if (item is! Map || item['path'] is! String) continue;
        final path = item['path'] as String;
        _path(path);
        if (item['type'] == 'file') paths.add(path);
        if (item['type'] == 'dir' && path.split('/').length <= 5) {
          paths.addAll(await list(path));
        }
        if (paths.length > maxItems) {
          throw const DiscordConfigurationFailure('연결 요청 목록이 너무 큽니다.');
        }
      }
      return paths;
    } on GitHubFailure catch (e) {
      if (e.status == 404) return [];
      rethrow;
    }
  }

  @override
  Future<void> delete(String path, {required String expectedRevision}) async {
    guard();
    _path(path);
    await session.api.call(
      'DELETE',
      '/repos/${config.slug}/contents/$path',
      body: {
        'message': 'Remove resolved IEUM Discord connection request',
        'sha': expectedRevision,
        'branch': config.base,
      },
    );
    guard();
  }
}

/// Lives with one open project. No timer or sender exists while the app is closed.
class DiscordService extends ChangeNotifier {
  DiscordService({
    required this.store,
    required this.sync,
    required this.session,
    DiscordSecretVault? vault,
    DiscordWebhookTransport? webhookTransport,
    NativeDiscordProcessLock? processLock,
  }) {
    accountId = store.profileId;
    scope = DiscordProjectScope(
      repository: sync.config.slug,
      projectId: store.project!.id,
      integrationBranch: sync.config.base,
    );
    credentials = DiscordCredentials(
      vault: vault ?? NativeDiscordSecretVault(),
      accountId: accountId,
      scope: scope,
    );
    configurationService = DiscordConfigurationService(
      scope: scope,
      accountId: accountId,
      ownerId: store.project!.ownerId,
      credentials: credentials,
      transport: GitHubDiscordConfigurationTransport(
        session,
        sync.config,
        _guard,
      ),
      isCurrentMember: (id) =>
          !_disposed && store.people.any((p) => p.id == id && p.active),
    );
    transport = webhookTransport ?? DiscordWebhookTransport();
    outbox = DiscordOutbox(store.db);
    sendingLock = processLock ?? NativeDiscordProcessLock();
    sync.addListener(_onSync);
  }
  final TaskStore store;
  final GitHubSync sync;
  final GitHubSession session;
  late final String accountId;
  late final DiscordProjectScope scope;
  late final DiscordCredentials credentials;
  late final DiscordConfigurationService configurationService;
  late final DiscordWebhookTransport transport;
  late final DiscordOutbox outbox;
  late final NativeDiscordProcessLock sendingLock;
  DiscordConfiguration? configuration;
  List<DiscordPairingRequest> requests = [];
  final Set<String> availableCredentials = {};
  String notice = '', deviceId = '', fingerprint = '';
  bool ready = false, refreshing = false, draining = false, _disposed = false;
  bool hasTrustedPairing = false;
  Timer? _timer;
  Future<void> _sendingFinished = Future<void>.value();

  void _guard() {
    if (_disposed ||
        sync.isDisposed ||
        session.user?.id != accountId ||
        !store.actor.active ||
        store.project?.id != scope.projectId ||
        store.project?.ownerId != configurationService.ownerId ||
        sync.config.slug != scope.repository ||
        sync.config.base != scope.integrationBranch) {
      throw const DiscordConfigurationFailure('프로젝트와 로그인 상태를 다시 확인하세요.');
    }
  }

  void _notify() {
    if (!_disposed && !sync.isDisposed) notifyListeners();
  }

  void _onSync() {
    if (!_disposed) unawaited(drain());
  }

  Future<void> start() async {
    await refresh();
    if (_disposed) return;
    _timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (_disposed || sync.isDisposed || refreshing || draining) return;
    refreshing = true;
    try {
      _guard();
      if (!sendingLock.isHeld &&
          await sendingLock.acquire(
            accountId: accountId,
            scope: scope.storageScope,
          )) {
        _guard();
        outbox.recoverInterrupted();
      }
      final trusted = await credentials.loadTrust();
      hasTrustedPairing = trusted != null;
      final config = trusted == null
          ? await configurationService.readPublicConfiguration()
          : await configurationService.loadConfiguration();
      if (_disposed) return;
      configuration = config;
      ready = false;
      availableCredentials.clear();
      if (config != null && trusted != null) {
        await configurationService.refreshCredentials(
          validatedConfiguration: config,
        );
        final identity = await credentials.getOrCreateIdentity();
        if (_disposed) return;
        deviceId = identity.deviceId;
        fingerprint = (await credentials.crypto.certificate(
          identity,
          accountId,
        )).signingPublicKey;
        ready = config.devices.any(
          (d) =>
              d.deviceId == deviceId &&
              d.githubUserId == accountId &&
              !d.revoked,
        );
        if (ready) {
          for (final route in config.routes) {
            if (await credentials.readWebhook(config, route) != null) {
              availableCredentials.add(route.routeId);
            }
            if (_disposed) return;
          }
        }
      }
      if (_disposed) return;
      store.setMeta('discord.deviceId', ready ? deviceId : '');
      store.setMeta('discord.scope', scope.storageScope);
      store.setMeta(
        'discord.publicRoutes',
        ready && config != null
            ? jsonEncode(config.routes.map((r) => r.json).toList())
            : '',
      );
      requests =
          store.owns &&
              config != null &&
              trusted != null &&
              fingerprint == config.ownerPublicKey
          ? await configurationService.pendingPairingRequests()
          : [];
      if (_disposed) return;
      if (store.owns &&
          config != null &&
          trusted != null &&
          fingerprint == config.ownerPublicKey) {
        await configurationService.cleanupStaleEnvelopes();
      }
      _guard();
      if (sendingLock.isHeld) outbox.prune();
      notice = [
        store.meta('discord.queueNotice'),
        ...configurationService.cleanupWarnings,
        if (!sendingLock.isHeld) '다른 이음 창에서 이 프로젝트의 Discord 알림을 전송하고 있습니다.',
      ].where((s) => s.isNotEmpty).join('\n');
    } catch (error) {
      if (!_disposed && !sync.isDisposed) {
        ready = false;
        store.setMeta('discord.publicRoutes', '');
        notice = _safeError(error);
      }
    } finally {
      refreshing = false;
      _notify();
    }
    if (!_disposed) await drain();
  }

  String _safeError(Object error) => error is DiscordConfigurationFailure
      ? error.message
      : error is DiscordTransportFailure
      ? error.message
      : error is DiscordVaultFailure
      ? error.message
      : error is DiscordProcessLockFailure
      ? error.message
      : 'Discord 알림 연결을 확인하지 못했습니다. 잠시 후 다시 시도하세요.';

  Future<void> saveDiscordId(String? value) async {
    _guard();
    final project = await session.setOwnDiscordUserId(
      sync.config,
      value ?? '',
      expectedProjectId: scope.projectId,
    );
    _guard();
    store.updateProject(project);
    _notify();
  }

  Future<void> _owner() async {
    _guard();
    if (!store.owns) {
      throw const DiscordConfigurationFailure('채널 설정은 프로젝트 관리자만 변경할 수 있습니다.');
    }
    configuration =
        await configurationService.loadConfiguration() ??
        await configurationService.initializeOwner();
    _guard();
  }

  Set<DiscordEventType> _eventTypes(Set<DiscordNoticeEvent> input) => input
      .map(
        (e) => switch (e) {
          DiscordNoticeEvent.assignment => DiscordEventType.assigned,
          DiscordNoticeEvent.handoff => DiscordEventType.handedOff,
          DiscordNoticeEvent.completed => DiscordEventType.completed,
          DiscordNoticeEvent.statusChanged => DiscordEventType.statusChanged,
        },
      )
      .toSet();

  Future<void> saveChannel(DiscordChannelDraft draft) async {
    await _owner();
    final existing = configuration!.routes
        .where((r) => r.routeId == draft.id)
        .firstOrNull;
    final supplied = draft.webhookUrl?.trim();
    final url = supplied?.isNotEmpty == true
        ? supplied!
        : existing == null
        ? null
        : await credentials.ownerWebhook(existing.routeId);
    if (url == null) {
      throw const DiscordConfigurationFailure('채널의 웹훅 URL을 입력하세요.');
    }
    final info = await transport.inspect(url);
    _guard();
    if (info.guildId == null) {
      throw const DiscordConfigurationFailure('서버의 채널 웹훅을 선택하세요.');
    }
    if (draft.partIds.any(
      (id) => !store.project!.roles.any((r) => r.id == id),
    )) {
      throw const DiscordConfigurationFailure('프로젝트의 현재 파트를 선택하세요.');
    }
    final route = DiscordRoute(
      routeId: existing?.routeId ?? 'route-${const Uuid().v4()}',
      guildId: info.guildId!,
      channelId: info.channelId,
      channelName: draft.name.trim(),
      enabled: draft.enabled,
      partIds: draft.partIds.toList(),
      eventTypes: _eventTypes(draft.events),
      secretVersion: existing == null
          ? 1
          : existing.secretVersion + (supplied?.isNotEmpty == true ? 1 : 0),
    );
    configuration = await configurationService.saveRoutes(
      [
        ...configuration!.routes.where((r) => r.routeId != route.routeId),
        route,
      ],
      webhookUrls: {route.routeId: url},
    );
    await refresh();
  }

  Future<void> deleteChannel(String id) async {
    await _owner();
    configuration = await configurationService.saveRoutes(
      configuration!.routes.where((r) => r.routeId != id).toList(),
    );
    await credentials.deleteWebhook(id);
    await refresh();
  }

  Future<void> toggleChannel(String id, bool enabled) async {
    await _owner();
    configuration = await configurationService.saveRoutes([
      for (final route in configuration!.routes)
        route.routeId == id
            ? DiscordRoute(
                routeId: route.routeId,
                guildId: route.guildId,
                channelId: route.channelId,
                channelName: route.channelName,
                partIds: route.partIds,
                eventTypes: route.eventTypes,
                enabled: enabled,
                secretVersion: route.secretVersion,
                notificationVersion: route.notificationVersion,
              )
            : route,
    ]);
    await refresh();
  }

  Future<String> createPairingCode(String memberId) async {
    await _owner();
    if (!store.people.any((p) => p.id == memberId && p.active)) {
      throw const DiscordConfigurationFailure('현재 프로젝트의 참여자를 선택하세요.');
    }
    return configurationService.createPairingCode(memberId);
  }

  Future<void> claimPairingCode(String code) async {
    _guard();
    await configurationService.acceptPairingCode(code);
    await refresh();
  }

  Future<void> decideDevice(String id, bool approve) async {
    await _owner();
    final request = requests.where((r) => r.device.deviceId == id).firstOrNull;
    if (request == null) {
      throw const DiscordConfigurationFailure('연결 요청을 새로고침하세요.');
    }
    if (approve) {
      await configurationService.approvePairing(request);
    } else {
      await configurationService.rejectPairing(request);
    }
    await refresh();
  }

  Future<void> revokeDevice(
    String id,
    Map<String, String> replacementUrls,
  ) async {
    await _owner();
    for (final route in configuration!.routes) {
      final replacement = replacementUrls[route.routeId];
      if (replacement == null) {
        throw const DiscordConfigurationFailure('모든 채널의 새 웹훅을 입력하세요.');
      }
      final fresh = await transport.inspect(replacement);
      _guard();
      if (fresh.channelId != route.channelId ||
          fresh.guildId != route.guildId) {
        throw const DiscordConfigurationFailure('기존과 같은 서버·채널의 새 웹훅을 입력하세요.');
      }
      final old = await credentials.ownerWebhook(route.routeId);
      if (old != null) {
        var invalidated = false;
        try {
          await transport.inspect(old);
        } on DiscordTransportFailure catch (error) {
          invalidated = error.status == 404;
        }
        if (!invalidated) {
          throw const DiscordConfigurationFailure(
            'Discord에서 기존 웹훅을 삭제한 뒤 다시 시도하세요.',
          );
        }
      }
    }
    configuration = await configurationService.revokeDevice(
      id,
      rotatedWebhookUrls: replacementUrls,
    );
    await refresh();
  }

  Future<void> drain() async {
    if (_disposed ||
        sync.isDisposed ||
        draining ||
        refreshing ||
        !sendingLock.isHeld ||
        !ready ||
        configuration == null) {
      return;
    }
    draining = true;
    final finished = Completer<void>();
    _sendingFinished = finished.future;
    try {
      _guard();
      final pending = outbox.pendingDeliveries();
      if (pending.isEmpty) return;
      // Check the latest signed route/device state before each sending batch.
      final latest = await configurationService.loadConfiguration();
      _guard();
      if (latest == null ||
          !latest.devices.any(
            (d) =>
                d.deviceId == deviceId &&
                d.githubUserId == accountId &&
                !d.revoked,
          )) {
        ready = false;
        store.setMeta('discord.publicRoutes', '');
        return;
      }
      configuration = latest;
      await configurationService.refreshCredentials(
        validatedConfiguration: latest,
      );
      _guard();
      final now = DateTime.now();
      for (final row in pending.reversed) {
        _guard();
        if (!const {'ready', 'retry_wait'}.contains(row['state']) ||
            DateTime.tryParse(row['retryAt'] as String? ?? '')?.isAfter(now) ==
                true) {
          continue;
        }
        final event = outbox.event(row['eventId'] as String);
        if (event == null ||
            event['scope'] != scope.storageScope ||
            event['originDeviceId'] != deviceId) {
          continue;
        }
        final savedRoute = DiscordRoute.fromJson(row['route']);
        final current = configuration!.routes
            .where((r) => r.routeId == savedRoute.routeId)
            .firstOrNull;
        if (current == null ||
            !current.enabled ||
            current.channelId != savedRoute.channelId ||
            current.guildId != savedRoute.guildId ||
            current.secretVersion != savedRoute.secretVersion) {
          outbox.settle({
            ...row,
            'state': 'blocked',
            'error': '채널 설정이 변경되었습니다. 취소하거나 연결을 확인하세요.',
          });
          continue;
        }
        if (!current.effectiveEventTypes.any((e) => e.name == event['type'])) {
          outbox.settle({
            ...row,
            'state': 'blocked',
            'error': '이 알림 종류가 채널 설정에서 꺼졌습니다.',
          });
          continue;
        }
        final url = await credentials.readWebhook(configuration!, current);
        if (_disposed) return;
        if (url == null) continue;
        _guard();
        try {
          final actual = await transport.inspect(url);
          _guard();
          if (actual.channelId != current.channelId ||
              actual.guildId != current.guildId) {
            outbox.settle({
              ...row,
              'state': 'blocked',
              'error': '웹훅의 실제 채널이 변경되었습니다. 연결을 다시 등록하세요.',
            });
            continue;
          }
        } on DiscordTransportFailure catch (error) {
          if (_disposed || sync.isDisposed) return;
          final attempts = (row['attempts'] as int? ?? 0) + 1;
          outbox.settle({
            ...row,
            'attempts': attempts,
            'state': error.status != null || attempts >= 5
                ? 'failed'
                : 'retry_wait',
            'retryAt': DateTime.now()
                .add(const Duration(seconds: 60))
                .toUtc()
                .toIso8601String(),
            'error': error.message,
          });
          continue;
        }
        if (!outbox.claim(row)) continue;
        final recipients = (event['recipients'] as List)
            .cast<String>()
            .map(store.member)
            .where((p) => p.active)
            .toList();
        final ids = recipients
            .map((p) => p.discordUserId)
            .where((id) => id.isNotEmpty)
            .toSet()
            .take(100)
            .toList();
        final mention = recipients
            .take(100)
            .map(
              (p) => p.discordUserId.isEmpty ? p.name : '<@${p.discordUserId}>',
            )
            .join(' · ');
        final type = switch (event['type']) {
          'assigned' => '작업 배정',
          'handedOff' => '작업 전달',
          'statusChanged' => '상태 변경',
          _ => '작업 완료',
        };
        DiscordSendResult result;
        try {
          result = await transport.send(
            url,
            userIds: ids,
            payload: {
              'username': '이음',
              'content': _short(
                '$mention${recipients.length > 100 ? ' 외 ${recipients.length - 100}명' : ''}',
                2000,
              ),
              'embeds': [
                {
                  'title': _short('$type · ${event['title']}', 256),
                  'description': _short(
                    '상태: ${event['previousStatus'] == null ? '' : '${event['previousStatus']} → '}${event['status']}\n처리: ${store.member(event['actorId'] as String).name}',
                    4096,
                  ),
                  'footer': {
                    'text': _short(
                      '${store.project!.name} · ${event['taskId']}',
                      2048,
                    ),
                  },
                  'timestamp': event['createdAt'],
                },
              ],
            },
          );
        } on DiscordTransportFailure catch (error) {
          // These errors are raised before POST; no delivery took place.
          _guard();
          outbox.settle({
            ...row,
            'state': 'failed',
            'attempts': (row['attempts'] as int? ?? 0) + 1,
            'error': error.message,
          });
          continue;
        }
        _guard();
        final attempts = (row['attempts'] as int? ?? 0) + 1;
        outbox.settle({
          ...row,
          'attempts': attempts,
          'state': switch (result.status) {
            DiscordSendStatus.delivered => 'delivered',
            DiscordSendStatus.uncertain => 'uncertain',
            DiscordSendStatus.failed => 'failed',
            DiscordSendStatus.retryable =>
              attempts < 5 ? 'retry_wait' : 'failed',
          },
          'error': result.status == DiscordSendStatus.delivered
              ? ''
              : result.message,
          'messageId': result.messageId ?? '',
          'retryAt': DateTime.now()
              .add(result.retryAfter ?? const Duration(seconds: 60))
              .toUtc()
              .toIso8601String(),
        });
        _notify();
      }
    } catch (error) {
      if (!_disposed) notice = _safeError(error);
    } finally {
      draining = false;
      finished.complete();
      _notify();
    }
  }

  Future<void> retry(String id) async {
    _guard();
    final row = outbox.delivery(id);
    if (row != null && configuration != null) {
      final old = DiscordRoute.fromJson(row['route']);
      final current = configuration!.routes
          .where((r) => r.routeId == old.routeId)
          .firstOrNull;
      if (current == null ||
          !current.enabled ||
          current.channelId != old.channelId ||
          current.guildId != old.guildId) {
        throw const DiscordConfigurationFailure('기존 알림 채널을 확인하거나 이 전송을 취소하세요.');
      }
      outbox.put('discord_deliveries', {...row, 'route': current.json});
    }
    outbox.retry(id, confirmedUncertain: true);
    await drain();
  }

  Future<void> cancel(String id) async {
    _guard();
    outbox.cancel(id);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    sync.removeListener(_onSync);
    transport.close();
    unawaited(
      _sendingFinished
          .then((_) => sendingLock.release())
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  static String _short(String value, int limit) {
    if (value.length <= limit) return value;
    var end = limit - 1;
    if (value.codeUnitAt(end - 1) >= 0xd800 &&
        value.codeUnitAt(end - 1) <= 0xdbff) {
      end--;
    }
    return '${value.substring(0, end)}…';
  }
}
