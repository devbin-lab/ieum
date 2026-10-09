import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_localizations.dart';
import 'workspace_ui.dart';

String _text(String korean, String english) => isEnglish ? english : tr(korean);

String? _webhookError(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      !{'discord.com', 'discordapp.com'}.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasQuery ||
      uri.hasPort ||
      !RegExp(r'^/api(?:/v\d+)?/webhooks/\d{17,20}/[A-Za-z0-9_-]+$')
          .hasMatch(uri.path)) {
    return _text(
      'Discord에서 복사한 웹훅 주소를 입력하세요.',
      'Enter a webhook URL copied from Discord.',
    );
  }
  return null;
}

enum DiscordNoticeEvent { assignment, handoff, completed, statusChanged }

extension DiscordNoticeEventLabel on DiscordNoticeEvent {
  String get label => switch (this) {
    DiscordNoticeEvent.assignment => _text('작업 배정', 'Assignment'),
    DiscordNoticeEvent.handoff => _text('작업 전달', 'Handoff'),
    DiscordNoticeEvent.completed => _text('작업 완료', 'Completion'),
    DiscordNoticeEvent.statusChanged => _text('상태 변경', 'Status change'),
  };
}

class DiscordPartOption {
  const DiscordPartOption(this.id, this.name);
  final String id, name;
}

class DiscordMemberOption {
  const DiscordMemberOption(this.id, this.name, {this.login = ''});
  final String id, name, login;
}

/// Display data deliberately excludes the webhook URL and encrypted envelopes.
class DiscordChannelView {
  const DiscordChannelView({
    required this.id,
    required this.name,
    required this.enabled,
    required this.events,
    this.partIds = const {},
    this.hasLocalCredential = false,
  });
  final String id, name;
  final bool enabled, hasLocalCredential;
  final Set<DiscordNoticeEvent> events;
  final Set<String> partIds;
}

/// The URL is an ephemeral input. The caller must store it in the local vault.
class DiscordChannelDraft {
  const DiscordChannelDraft({
    this.id,
    required this.name,
    this.webhookUrl,
    required this.enabled,
    required this.events,
    required this.partIds,
  });
  final String? id, webhookUrl;
  final String name;
  final bool enabled;
  final Set<DiscordNoticeEvent> events;
  final Set<String> partIds;
}

enum DiscordDeviceState { disconnected, pending, connected }

class DiscordDeviceRequestView {
  const DiscordDeviceRequestView({
    required this.id,
    required this.memberName,
    required this.deviceName,
    required this.fingerprint,
    this.login = '',
  });
  final String id, memberName, deviceName, fingerprint, login;
}

enum DiscordDeliveryState {
  waitingIntegration,
  ready,
  sending,
  delivered,
  failed,
  uncertain,
  blocked,
}

class DiscordDeliveryView {
  const DiscordDeliveryView({
    required this.id,
    required this.title,
    required this.channelName,
    required this.state,
    required this.createdAt,
    this.safeError,
  });
  final String id, title, channelName;
  final DiscordDeliveryState state;
  final DateTime createdAt;
  // Use an app-owned explanation, never a raw HTTP exception or response body.
  final String? safeError;
}

class DiscordApprovedDeviceView {
  const DiscordApprovedDeviceView({
    required this.id,
    required this.memberName,
    required this.deviceName,
    this.isCurrentDevice = false,
  });
  final String id, memberName, deviceName;
  final bool isCurrentDevice;
}

/// Project settings only. Callbacks enforce membership and owner authorization;
/// this view never sends notifications or treats a typed Discord ID as verified.
class DiscordNotificationsSettings extends StatefulWidget {
  const DiscordNotificationsSettings({
    super.key,
    required this.projectConnected,
    required this.canManageChannels,
    required this.currentMemberName,
    required this.channels,
    required this.parts,
    required this.members,
    required this.deviceState,
    required this.deviceRequests,
    required this.onSaveDiscordId,
    required this.onSaveChannel,
    required this.onDeleteChannel,
    required this.onToggleChannel,
    required this.onCreatePairingCode,
    required this.onClaimPairingCode,
    required this.onDecideDevice,
    this.discordUserId,
    this.onRefresh,
    this.unreadCount = 0,
    this.onOpenInbox,
    this.deliverySummary,
    this.ownDeviceFingerprint,
    this.deliveryHistory = const [],
    this.onRetryDelivery,
    this.onCancelDelivery,
    this.approvedDevices = const [],
    this.onRevokeDevice,
  });

  final bool projectConnected, canManageChannels;
  final String currentMemberName;
  final String? discordUserId, deliverySummary, ownDeviceFingerprint;
  final List<DiscordChannelView> channels;
  final List<DiscordPartOption> parts;
  final List<DiscordMemberOption> members;
  final DiscordDeviceState deviceState;
  final List<DiscordDeviceRequestView> deviceRequests;
  final int unreadCount;
  final VoidCallback? onOpenInbox;
  final Future<void> Function(String? id) onSaveDiscordId;
  final Future<void> Function(DiscordChannelDraft draft) onSaveChannel;
  final Future<void> Function(String id) onDeleteChannel;
  final Future<void> Function(String id, bool enabled) onToggleChannel;
  final Future<String> Function(String memberId) onCreatePairingCode;
  final Future<void> Function(String code) onClaimPairingCode;
  final Future<void> Function(String requestId, bool approve) onDecideDevice;
  final Future<void> Function()? onRefresh;
  final List<DiscordDeliveryView> deliveryHistory;
  final Future<void> Function(String deliveryId)? onRetryDelivery;
  final Future<void> Function(String deliveryId)? onCancelDelivery;
  final List<DiscordApprovedDeviceView> approvedDevices;
  final Future<void> Function(
    String deviceId,
    Map<String, String> replacementUrls,
  )?
  onRevokeDevice;

  @override
  State<DiscordNotificationsSettings> createState() =>
      _DiscordNotificationsSettingsState();
}

class _DiscordNotificationsSettingsState
    extends State<DiscordNotificationsSettings> {
  late final TextEditingController _discordId = TextEditingController(
    text: widget.discordUserId ?? '',
  );
  bool _busy = false;
  String? _idError;

  @override
  void didUpdateWidget(covariant DiscordNotificationsSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.discordUserId != widget.discordUserId &&
        _discordId.text.trim() == (oldWidget.discordUserId ?? '')) {
      _discordId.text = widget.discordUserId ?? '';
    }
  }

  @override
  void dispose() {
    _discordId.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success.isNotEmpty) _notice(success);
    } catch (_) {
      // Transport exceptions may contain secret URLs. Never render raw errors.
      if (mounted) {
        _notice(
          _text(
            '변경을 저장하지 못했습니다. 연결 상태를 확인하고 다시 시도하세요.',
            'Could not save changes. Check your connection and try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notice(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _saveId() async {
    final value = _discordId.text.trim();
    if (value.isNotEmpty && !RegExp(r'^[0-9]{17,20}$').hasMatch(value)) {
      setState(
        () => _idError = _text(
          '17~20자리 숫자 사용자 ID를 입력하세요.',
          'Enter a 17–20 digit user ID.',
        ),
      );
      return;
    }
    setState(() => _idError = null);
    await _run(
      () => widget.onSaveDiscordId(value.isEmpty ? null : value),
      _text('Discord 사용자 ID를 저장했습니다.', 'Discord user ID saved.'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = WorkspaceUi.colors(context);
    if (!widget.projectConnected) {
      return _panel(
        icon: Icons.notifications_none_rounded,
        title: _text('프로젝트 알림', 'Project notifications'),
        subtitle: _text(
          '프로젝트를 연결하면 작업 알림과 Discord 채널을 설정할 수 있습니다.',
          'Connect a project to configure notifications and Discord channels.',
        ),
        child: const SizedBox.shrink(),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onOpenInbox != null) ...[
          _panel(
            icon: Icons.notifications_none_rounded,
            title: _text('이음 알림', 'Ieum notifications'),
            subtitle: widget.unreadCount == 0
                ? _text('새로운 알림이 없습니다.', 'You are all caught up.')
                : _text(
                    '읽지 않은 알림 ${widget.unreadCount}개',
                    '${widget.unreadCount} unread notifications',
                  ),
            trailing: OutlinedButton(
              onPressed: widget.onOpenInbox,
              child: Text(_text('알림 열기', 'Open inbox')),
            ),
            child: const SizedBox.shrink(),
          ),
          const SizedBox(height: 20),
        ],
        _panel(
          icon: Icons.alternate_email_rounded,
          title: _text('내 Discord 계정', 'My Discord account'),
          subtitle: _text(
            '작업이 배정되거나 전달되면 등록한 사용자 ID로 멘션합니다.',
            'Use your Discord user ID for assignment and handoff mentions.',
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.currentMemberName,
                style: WorkspaceUi.sectionStyleOf(context),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, bounds) {
                  final field = TextField(
                    key: const Key('discord-self-id'),
                    controller: _discordId,
                    enabled: !_busy,
                    maxLength: 20,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (_) => setState(() => _idError = null),
                    onSubmitted: (_) => _saveId(),
                    decoration: InputDecoration(
                      labelText: _text('Discord 사용자 ID', 'Discord user ID'),
                      hintText: '123456789012345678',
                      counterText: '',
                      errorText: _idError,
                      helperText: _text(
                        '닉네임 대신 숫자 ID를 입력하세요.',
                        'Enter the numeric ID, rather than your display name.',
                      ),
                    ),
                  );
                  final save = FilledButton(
                    key: const Key('discord-save-self-id'),
                    onPressed:
                        _busy ||
                            _discordId.text.trim() ==
                                (widget.discordUserId ?? '')
                        ? null
                        : _saveId,
                    child: Text(_text('저장', 'Save')),
                  );
                  if (bounds.maxWidth < 420) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [field, const SizedBox(height: 12), save],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: field),
                      const SizedBox(width: 12),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: save,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Text(
                _text(
                  'Discord 설정 → 고급 → 개발자 모드를 켠 뒤, 내 프로필에서 ‘사용자 ID 복사’를 선택하세요. 비우고 저장하면 멘션을 해제합니다.',
                  'Enable Developer Mode in Discord Settings → Advanced, then choose Copy User ID on your profile. Clear this field to stop mentions.',
                ),
                style: WorkspaceUi.captionStyleOf(context),
              ),
              const SizedBox(height: 8),
              Text(
                _text(
                  '직접 등록한 ID입니다. Discord 계정 로그인이나 서버 가입 여부를 확인하지 않습니다.',
                  'This ID is self-registered. It does not verify Discord account ownership or server membership.',
                ),
                style: WorkspaceUi.captionStyleOf(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _sectionHeading(
          _text('Discord 채널', 'Discord channels'),
          _text(
            '채널마다 받을 알림과 담당 파트를 선택합니다.',
            'Choose notification types and parts for each channel.',
          ),
          actions: [
            if (widget.onRefresh != null)
              IconButton(
                tooltip: _text('새로고침', 'Refresh'),
                onPressed: _busy ? null : () => _run(widget.onRefresh!, ''),
                icon: const Icon(Icons.refresh_rounded, size: 19),
              ),
            if (widget.canManageChannels)
              FilledButton.icon(
                key: const Key('discord-add-channel'),
                onPressed: _busy ? null : () => _editChannel(),
                icon: const Icon(Icons.add_rounded, size: 17),
                label: Text(_text('채널 연결', 'Connect channel')),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (widget.channels.isEmpty)
          _panel(
            icon: Icons.link_rounded,
            title: _text('연결된 채널이 없습니다.', 'No channels connected'),
            subtitle: widget.canManageChannels
                ? _text(
                    'Discord 채널 설정에서 웹훅을 만든 뒤 연결하세요.',
                    'Create a webhook in Discord channel settings, then connect it here.',
                  )
                : _text(
                    '프로젝트 소유자가 Discord 채널을 연결하면 이곳에 표시됩니다.',
                    'Channels will appear here when the project owner connects them.',
                  ),
            child: const SizedBox.shrink(),
          )
        else
          for (final channel in widget.channels) ...[
            _channelCard(channel),
            const SizedBox(height: 10),
          ],
        if (widget.deliverySummary?.isNotEmpty == true)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              widget.deliverySummary!,
              style: WorkspaceUi.captionStyleOf(context),
            ),
          ),
        const SizedBox(height: 24),
        _devicePanel(),
        if (widget.deliveryHistory.isNotEmpty) ...[
          const SizedBox(height: 24),
          _deliveryPanel(),
        ],
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline_rounded, size: 15, color: colors.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _text(
                  '알림은 작업 변경이 GitHub에 반영된 뒤 전송됩니다. 앱이 종료되어 있으면 다음 실행 시 이어서 전송합니다. 채널의 알림 설정에 따라 멘션 알림이 다를 수 있습니다.',
                  'Notifications are sent after changes are integrated into GitHub. Pending notifications resume when the app opens again. Discord notification preferences may affect mention alerts.',
                ),
                style: WorkspaceUi.captionStyleOf(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sectionHeading(
    String title,
    String subtitle, {
    List<Widget> actions = const [],
  }) {
    return LayoutBuilder(
      builder: (context, bounds) {
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: WorkspaceUi.sectionStyleOf(context).copyWith(fontSize: 15),
            ),
            const SizedBox(height: 5),
            Text(subtitle, style: WorkspaceUi.captionStyleOf(context)),
          ],
        );
        if (bounds.maxWidth < 500) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              if (actions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            if (actions.isNotEmpty) ...[const SizedBox(width: 16), ...actions],
          ],
        );
      },
    );
  }

  Widget _panel({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
    Widget? trailing,
  }) => WorkspacePanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: WorkspaceUi.colors(context).muted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: WorkspaceUi.sectionStyleOf(context)
                        .copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 5),
                  Text(subtitle, style: WorkspaceUi.captionStyleOf(context)),
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing],
          ],
        ),
        if (child is! SizedBox) ...[const SizedBox(height: 20), child],
      ],
    ),
  );

  Widget _channelCard(DiscordChannelView channel) {
    final partNames = widget.parts
        .where((part) => channel.partIds.contains(part.id))
        .map((part) => part.name)
        .toList();
    final colors = WorkspaceUi.colors(context);
    return WorkspacePanel(
      key: ValueKey('discord-channel-${channel.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: colors.subtle,
              borderRadius: BorderRadius.circular(9),
            ),
            child: SvgPicture.asset('assets/shortcut-services/discord.svg'),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '# ${channel.name}',
                  style: WorkspaceUi.sectionStyleOf(context),
                ),
                const SizedBox(height: 6),
                Text(
                  channel.partIds.isEmpty
                      ? _text('모든 파트', 'All parts')
                      : partNames.isEmpty
                      ? _text(
                          '지정한 파트가 삭제되었습니다.',
                          'Selected parts are no longer available.',
                        )
                      : partNames.join(' · '),
                  style: WorkspaceUi.captionStyleOf(context),
                ),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final event in DiscordNoticeEvent.values)
                      if (channel.events.contains(event)) _badge(event.label),
                    _badge(
                      channel.hasLocalCredential
                          ? _text('이 기기에서 전송 가능', 'Ready on this device')
                          : _text('기기 연결 필요', 'Device connection required'),
                      warning: !channel.hasLocalCredential,
                    ),
                    if (!channel.enabled) _badge(_text('일시 중지', 'Paused')),
                  ],
                ),
              ],
            ),
          ),
          if (widget.canManageChannels) ...[
            const SizedBox(width: 8),
            Switch.adaptive(
              value: channel.enabled,
              onChanged: _busy
                  ? null
                  : (enabled) => _run(
                      () => widget.onToggleChannel(channel.id, enabled),
                      enabled
                          ? _text(
                              '채널 알림을 켰습니다.',
                              'Channel notifications enabled.',
                            )
                          : _text(
                              '채널 알림을 일시 중지했습니다.',
                              'Channel notifications paused.',
                            ),
                    ),
            ),
            PopupMenuButton<String>(
              tooltip: _text('채널 관리', 'Manage channel'),
              enabled: !_busy,
              onSelected: (action) => action == 'edit'
                  ? _editChannel(channel)
                  : _deleteChannel(channel),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'edit',
                  child: Text(_text('설정 수정', 'Edit settings')),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    _text('연결 해제', 'Disconnect'),
                    style: TextStyle(color: colors.danger),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge(String label, {bool warning = false}) {
    final colors = WorkspaceUi.colors(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: warning ? colors.warning.withValues(alpha: .08) : colors.subtle,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: warning ? colors.warning : colors.muted,
        ),
      ),
    );
  }

  Widget _devicePanel() {
    final state = switch (widget.deviceState) {
      DiscordDeviceState.connected => _text('연결됨', 'Connected'),
      DiscordDeviceState.pending => _text(
        '소유자 승인 대기',
        'Awaiting owner approval',
      ),
      DiscordDeviceState.disconnected => _text('연결되지 않음', 'Not connected'),
    };
    return _panel(
      icon: Icons.devices_rounded,
      title: _text('이 기기의 알림 전송', 'Notifications from this device'),
      subtitle: state,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _text(
              '참여자가 변경한 작업도 채널에 알릴 수 있도록, 프로젝트 소유자가 각 기기의 연결을 승인합니다. Discord ID 등록과는 별도입니다.',
              'The project owner approves each device so members can send project notifications. This is separate from registering a Discord user ID.',
            ),
            style: WorkspaceUi.captionStyleOf(context),
          ),
          const SizedBox(height: 14),
          if (widget.deviceState == DiscordDeviceState.pending &&
              widget.ownDeviceFingerprint?.isNotEmpty == true) ...[
            Text(
              _text('내 기기 확인 코드', 'This device fingerprint'),
              style: WorkspaceUi.sectionStyleOf(context),
            ),
            const SizedBox(height: 8),
            SelectableText(
              widget.ownDeviceFingerprint!,
              style: WorkspaceUi.captionStyleOf(context)
                  .copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 8),
            Text(
              _text(
                '이 코드를 프로젝트 소유자에게 개인 메시지로 전달하세요.',
                'Share this fingerprint privately with the project owner.',
              ),
              style: WorkspaceUi.captionStyleOf(context),
            ),
            const SizedBox(height: 14),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (widget.canManageChannels)
                OutlinedButton.icon(
                  key: const Key('discord-create-pairing'),
                  onPressed:
                      _busy || widget.channels.isEmpty || widget.members.isEmpty
                      ? null
                      : _createPairing,
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: Text(_text('참여자 연결 코드', 'Member connection code')),
                ),
              if (widget.deviceState != DiscordDeviceState.connected)
                OutlinedButton.icon(
                  key: const Key('discord-claim-pairing'),
                  onPressed: _busy ? null : _claimPairing,
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: Text(
                    widget.deviceState == DiscordDeviceState.pending
                        ? _text('새 연결 코드 입력', 'Enter new connection code')
                        : _text('연결 코드 입력', 'Enter connection code'),
                  ),
                ),
            ],
          ),
          if (widget.canManageChannels && widget.deviceRequests.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Text(
              _text('연결 승인 요청', 'Connection requests'),
              style: WorkspaceUi.sectionStyleOf(context),
            ),
            const SizedBox(height: 8),
            for (final request in widget.deviceRequests)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${request.memberName} · ${request.deviceName}',
                      style: WorkspaceUi.sectionStyleOf(context),
                    ),
                    if (request.login.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '@${request.login}',
                        style: WorkspaceUi.captionStyleOf(context),
                      ),
                    ],
                    const SizedBox(height: 7),
                    SelectableText(
                      request.fingerprint,
                      style: WorkspaceUi.captionStyleOf(context)
                          .copyWith(fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      _text(
                        '참여자가 보낸 기기 확인 코드와 일치하는지 확인하세요.',
                        'Confirm this fingerprint matches the code shared by the member.',
                      ),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () => widget.onDecideDevice(request.id, true),
                                  _text(
                                    '기기 연결을 승인했습니다.',
                                    'Device connection approved.',
                                  ),
                                ),
                          child: Text(_text('연결 승인', 'Approve connection')),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () =>
                                      widget.onDecideDevice(request.id, false),
                                  _text(
                                    '연결 요청을 거절했습니다.',
                                    'Connection request declined.',
                                  ),
                                ),
                          child: Text(_text('거절', 'Decline')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
          if (widget.canManageChannels &&
              widget.approvedDevices.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Text(
              _text('승인된 기기', 'Approved devices'),
              style: WorkspaceUi.sectionStyleOf(context),
            ),
            const SizedBox(height: 8),
            for (final device in widget.approvedDevices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: [
                    const Icon(Icons.computer_rounded, size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.memberName,
                            style: WorkspaceUi.sectionStyleOf(context),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            device.isCurrentDevice
                                ? '${device.deviceName} · ${_text('현재 기기', 'This device')}'
                                : device.deviceName,
                            style: WorkspaceUi.captionStyleOf(context),
                          ),
                        ],
                      ),
                    ),
                    if (widget.onRevokeDevice != null)
                      TextButton(
                        onPressed: _busy ? null : () => _revokeDevice(device),
                        child: Text(_text('연결 해제', 'Disconnect')),
                      ),
                  ],
                ),
              ),
          ],
          if (widget.canManageChannels && widget.channels.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              _text(
                '참여자나 기기 연결을 해제한 뒤에는 Discord에서 웹훅 주소를 변경하고 채널 설정에 새 주소를 저장하세요. 이미 기기에 전달한 주소는 원격으로 회수할 수 없습니다.',
                'After disconnecting a member or device, rotate the webhook in Discord and save the new URL in channel settings. URLs already shared with a device cannot be recalled remotely.',
              ),
              style: WorkspaceUi.captionStyleOf(context),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _editChannel([DiscordChannelView? initial]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ChannelDialog(
        initial: initial,
        parts: widget.parts,
        onSave: widget.onSaveChannel,
      ),
    );
  }

  Future<void> _revokeDevice(DiscordApprovedDeviceView device) async {
    final disconnected = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RevokeDeviceDialog(
        device: device,
        channels: widget.channels,
        onRevoke: widget.onRevokeDevice!,
      ),
    );
    if (disconnected == true && mounted) {
      _notice(
        _text(
          '기기 연결을 해제하고 새 웹훅 주소를 저장했습니다.',
          'Device disconnected and replacement webhooks saved.',
        ),
      );
    }
  }

  Widget _deliveryPanel() => _panel(
    icon: Icons.outgoing_mail,
    title: _text('알림 전송 기록', 'Notification delivery history'),
    subtitle: _text(
      '이 기기에서 전송한 최근 알림과 대기 상태를 확인합니다.',
      'Review recent notifications sent or queued by this device.',
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final delivery in widget.deliveryHistory.take(20)) ...[
          _deliveryRow(delivery),
          const Divider(height: 24),
        ],
        if (widget.deliveryHistory.length > 20)
          Text(
            _text('최근 20건을 표시합니다.', 'Showing the latest 20 deliveries.'),
            style: WorkspaceUi.captionStyleOf(context),
          ),
      ],
    ),
  );

  Widget _deliveryRow(DiscordDeliveryView delivery) {
    final colors = WorkspaceUi.colors(context);
    final status = switch (delivery.state) {
      DiscordDeliveryState.waitingIntegration => _text(
        '동기화 대기',
        'Awaiting sync',
      ),
      DiscordDeliveryState.ready => _text('전송 대기', 'Queued'),
      DiscordDeliveryState.sending => _text('전송 중', 'Sending'),
      DiscordDeliveryState.delivered => _text('전송됨', 'Delivered'),
      DiscordDeliveryState.failed => _text('전송 실패', 'Failed'),
      DiscordDeliveryState.uncertain => _text(
        '전송 여부 확인 필요',
        'Delivery unconfirmed',
      ),
      DiscordDeliveryState.blocked => _text('연결 확인 필요', 'Connection required'),
    };
    final uncertain = delivery.state == DiscordDeliveryState.uncertain;
    final needsAction = {
      DiscordDeliveryState.failed,
      DiscordDeliveryState.uncertain,
      DiscordDeliveryState.blocked,
    }.contains(delivery.state);
    final canCancel =
        delivery.state != DiscordDeliveryState.delivered &&
        delivery.state != DiscordDeliveryState.sending;
    final time = delivery.createdAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final error = delivery.safeError;
    final explanation =
        error?.isNotEmpty == true &&
            !RegExp(r'https?://|/webhooks/|[A-Za-z0-9_-]{40,}').hasMatch(error!)
        ? error
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          delivery.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: WorkspaceUi.sectionStyleOf(context),
        ),
        const SizedBox(height: 7),
        Wrap(
          spacing: 10,
          runSpacing: 7,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _badge(status, warning: needsAction),
            Text(
              '# ${delivery.channelName}',
              style: WorkspaceUi.captionStyleOf(context),
            ),
            Text(
              '${time.month}/${time.day} ${two(time.hour)}:${two(time.minute)}',
              style: WorkspaceUi.captionStyleOf(context),
            ),
          ],
        ),
        if (uncertain) ...[
          const SizedBox(height: 9),
          Text(
            _text(
              'Discord에 이미 표시되었을 수 있습니다. 채널을 확인한 뒤 다시 전송하세요.',
              'This notification may already be in Discord. Check the channel before resending.',
            ),
            style: WorkspaceUi.captionStyleOf(context)
                .copyWith(color: colors.warning),
          ),
        ] else if (explanation != null) ...[
          const SizedBox(height: 9),
          Text(explanation, style: WorkspaceUi.captionStyleOf(context)),
        ],
        if ((needsAction && widget.onRetryDelivery != null) ||
            (canCancel && widget.onCancelDelivery != null)) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (needsAction && widget.onRetryDelivery != null)
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _retryDelivery(delivery),
                  icon: const Icon(Icons.refresh_rounded, size: 15),
                  label: Text(_text('다시 전송', 'Resend')),
                ),
              if (canCancel && widget.onCancelDelivery != null)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                          () => widget.onCancelDelivery!(delivery.id),
                          _text(
                            '알림 전송을 취소했습니다.',
                            'Notification delivery canceled.',
                          ),
                        ),
                  child: Text(_text('전송 취소', 'Cancel delivery')),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _retryDelivery(DiscordDeliveryView delivery) async {
    if (delivery.state == DiscordDeliveryState.uncertain) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_text('알림을 다시 전송할까요?', 'Resend this notification?')),
          content: Text(
            _text(
              'Discord가 이미 수신했을 수 있어 같은 알림이 두 번 표시될 수 있습니다. 채널에서 확인한 뒤 전송하세요.',
              'Discord may have already received it, so resending can create a duplicate. Check the channel first.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_text('취소', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_text('다시 전송', 'Resend')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _run(
      () => widget.onRetryDelivery!(delivery.id),
      _text('알림을 전송 대기열에 추가했습니다.', 'Notification queued for delivery.'),
    );
  }

  Future<void> _deleteChannel(DiscordChannelView channel) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('채널 연결 해제', 'Disconnect channel')),
        content: Text(
          _text(
            '‘${channel.name}’ 채널의 알림 연결을 해제합니다. Discord 채널과 기존 메시지는 유지됩니다.',
            'Disconnect notifications for “${channel.name}”. The Discord channel and existing messages will remain.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_text('취소', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_text('연결 해제', 'Disconnect')),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(
        () => widget.onDeleteChannel(channel.id),
        _text('채널 연결을 해제했습니다.', 'Channel disconnected.'),
      );
    }
  }

  Future<void> _createPairing() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PairingDialog(
        members: widget.members,
        onCreate: widget.onCreatePairingCode,
      ),
    );
  }

  Future<void> _claimPairing() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ClaimPairingDialog(onClaim: widget.onClaimPairingCode),
    );
  }
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog({
    required this.initial,
    required this.parts,
    required this.onSave,
  });
  final DiscordChannelView? initial;
  final List<DiscordPartOption> parts;
  final Future<void> Function(DiscordChannelDraft) onSave;
  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  final _webhook = TextEditingController();
  late final Set<DiscordNoticeEvent> _events = {
    ...widget.initial?.events ?? DiscordNoticeEvent.values,
  };
  late final Set<String> _parts = {...widget.initial?.partIds ?? <String>{}};
  late bool _enabled = widget.initial?.enabled ?? true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _webhook.clear();
    _webhook.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_events.isEmpty) {
      setState(
        () => _error = _text(
          '받을 알림을 하나 이상 선택하세요.',
          'Choose at least one notification type.',
        ),
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final url = _webhook.text.trim();
      await widget.onSave(
        DiscordChannelDraft(
          id: widget.initial?.id,
          name: _name.text.trim(),
          webhookUrl: url.isEmpty ? null : url,
          enabled: _enabled,
          events: Set.unmodifiable(_events),
          partIds: Set.unmodifiable(_parts),
        ),
      );
      _webhook.clear();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '채널을 연결하지 못했습니다. 웹훅 주소와 프로젝트 연결 상태를 확인하세요.',
            'Could not connect the channel. Check the webhook URL and project connection.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(
        widget.initial == null
            ? _text('Discord 채널 연결', 'Connect Discord channel')
            : _text('채널 알림 설정', 'Channel notification settings'),
      ),
      content: SizedBox(
        width: 490,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const Key('discord-channel-name'),
                  controller: _name,
                  enabled: !_busy,
                  autofocus: true,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: _text('채널 이름', 'Channel name'),
                    hintText: _text('프로젝트 알림', 'Project notifications'),
                  ),
                  validator: (value) => value?.trim().isEmpty != false
                      ? _text('채널 이름을 입력하세요.', 'Enter a channel name.')
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  key: const Key('discord-webhook-url'),
                  controller: _webhook,
                  enabled: !_busy,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  maxLength: 2048,
                  decoration: InputDecoration(
                    labelText: _text('웹훅 주소', 'Webhook URL'),
                    counterText: '',
                    helperText: widget.initial == null
                        ? _text(
                            'Discord 채널 설정 → 연동 → 웹훅에서 복사하세요.',
                            'Copy it from Discord Channel Settings → Integrations → Webhooks.',
                          )
                        : _text(
                            '주소를 변경할 때만 입력하세요. 기존 주소는 표시하지 않습니다.',
                            'Enter a URL only to replace it. The saved URL stays hidden.',
                          ),
                    helperMaxLines: 3,
                  ),
                  validator: (raw) {
                    final value = raw?.trim() ?? '';
                    if (value.isEmpty && widget.initial != null) return null;
                    return _webhookError(value);
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  _text('받을 알림', 'Notifications'),
                  style: WorkspaceUi.sectionStyleOf(context),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final event in DiscordNoticeEvent.values)
                      FilterChip(
                        label: Text(event.label),
                        selected: _events.contains(event),
                        onSelected: _busy
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  _events.add(event);
                                } else {
                                  _events.remove(event);
                                }
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Text(
                  _text('담당 파트', 'Assigned parts'),
                  style: WorkspaceUi.sectionStyleOf(context),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: Text(_text('모든 파트', 'All parts')),
                      selected: _parts.isEmpty,
                      onSelected: _busy ? null : (_) => setState(_parts.clear),
                    ),
                    for (final part in widget.parts)
                      FilterChip(
                        label: Text(part.name),
                        selected: _parts.contains(part.id),
                        onSelected: _busy
                            ? null
                            : (selected) => setState(() {
                                if (selected) {
                                  _parts.add(part.id);
                                } else {
                                  _parts.remove(part.id);
                                }
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    _text('채널 알림 사용', 'Enable channel notifications'),
                    style: WorkspaceUi.sectionStyleOf(context),
                  ),
                  value: _enabled,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _enabled = value),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(_text('취소', 'Cancel')),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? _text('저장 중…', 'Saving…') : _text('저장', 'Save')),
        ),
      ],
    ),
  );
}

class _PairingDialog extends StatefulWidget {
  const _PairingDialog({required this.members, required this.onCreate});
  final List<DiscordMemberOption> members;
  final Future<String> Function(String memberId) onCreate;
  @override
  State<_PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<_PairingDialog> {
  String? _member, _code, _error;
  bool _busy = false, _copied = false;

  Future<void> _create() async {
    if (_member == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await widget.onCreate(_member!);
      if (mounted) setState(() => _code = code);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '연결 코드를 만들지 못했습니다. 다시 시도하세요.',
            'Could not create a connection code. Please try again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(_text('참여자 기기 연결', 'Connect a member device')),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const Key('discord-pairing-member'),
                initialValue: _member,
                isExpanded: true,
                decoration: InputDecoration(labelText: _text('참여자', 'Member')),
                items: [
                  for (final member in widget.members)
                    DropdownMenuItem(
                      value: member.id,
                      child: Text(
                        member.login.isEmpty
                            ? member.name
                            : '${member.name} · @${member.login}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy || _code != null
                    ? null
                    : (value) => setState(() => _member = value),
              ),
              const SizedBox(height: 16),
              Text(
                _text(
                  '선택한 참여자에게 코드를 개인 메시지로 전달하세요. 참여자가 코드를 입력한 뒤, 기기 확인 코드를 비교하고 연결을 승인합니다.',
                  'Share this code privately with the selected member. After they enter it, compare the device fingerprint and approve their connection.',
                ),
                style: WorkspaceUi.captionStyleOf(context),
              ),
              if (_code != null) ...[
                const SizedBox(height: 18),
                WorkspacePanel(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _text('개인 연결 코드', 'Private connection code'),
                        style: WorkspaceUi.sectionStyleOf(context),
                      ),
                      const SizedBox(height: 10),
                      SelectableText(
                        _code!,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: _code!),
                            );
                            if (mounted) setState(() => _copied = true);
                          },
                          icon: Icon(
                            _copied ? Icons.check_rounded : Icons.copy_rounded,
                            size: 15,
                          ),
                          label: Text(
                            _copied
                                ? _text('복사됨', 'Copied')
                                : _text('코드 복사', 'Copy code'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  _text(
                    '공개 채널이나 저장소에 올리지 마세요. 코드는 일회용이며 제한된 시간 동안 유효합니다.',
                    'Keep this code out of public channels and repositories. It is single-use and expires shortly.',
                  ),
                  style: WorkspaceUi.captionStyleOf(context),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(_text('닫기', 'Close')),
        ),
        if (_code == null)
          FilledButton(
            onPressed: _busy || _member == null ? null : _create,
            child: Text(
              _busy
                  ? _text('생성 중…', 'Creating…')
                  : _text('코드 만들기', 'Create code'),
            ),
          ),
      ],
    ),
  );
}

class _RevokeDeviceDialog extends StatefulWidget {
  const _RevokeDeviceDialog({
    required this.device,
    required this.channels,
    required this.onRevoke,
  });
  final DiscordApprovedDeviceView device;
  final List<DiscordChannelView> channels;
  final Future<void> Function(String, Map<String, String>) onRevoke;
  @override
  State<_RevokeDeviceDialog> createState() => _RevokeDeviceDialogState();
}

class _RevokeDeviceDialogState extends State<_RevokeDeviceDialog> {
  final _form = GlobalKey<FormState>();
  late final _urls = {
    for (final channel in widget.channels) channel.id: TextEditingController(),
  };
  bool _busy = false, _rotated = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in _urls.values) {
      controller.clear();
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _revoke() async {
    if (_busy ||
        !_form.currentState!.validate() ||
        (widget.channels.isNotEmpty && !_rotated)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRevoke(widget.device.id, {
        for (final entry in _urls.entries) entry.key: entry.value.text.trim(),
      });
      for (final controller in _urls.values) {
        controller.clear();
      }
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '연결을 해제하지 못했습니다. 기존 웹훅을 삭제했는지 확인하고 새 주소로 다시 시도하세요.',
            'Could not disconnect this device. Confirm old webhooks were deleted and try the replacement URLs again.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(_text('기기 연결 해제', 'Disconnect device')),
      content: SizedBox(
        width: 490,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${widget.device.memberName} · ${widget.device.deviceName}',
                  style: WorkspaceUi.sectionStyleOf(context),
                ),
                const SizedBox(height: 14),
                Text(
                  _text(
                    '이미 기기에 전달한 웹훅 주소를 차단하려면 Discord에서 기존 웹훅을 삭제하고 새 웹훅을 만들어야 합니다. 일시 중지한 채널도 포함해 모든 연결을 변경하세요.',
                    'To invalidate URLs already shared with this device, delete the old webhooks in Discord and create replacements for every channel, including paused channels.',
                  ),
                  style: WorkspaceUi.captionStyleOf(context),
                ),
                const SizedBox(height: 12),
                Text(
                  _text(
                    'Discord 채널 설정 → 연동 → 웹훅',
                    'Discord Channel Settings → Integrations → Webhooks',
                  ),
                  style: WorkspaceUi.captionStyleOf(context),
                ),
                for (final channel in widget.channels) ...[
                  const SizedBox(height: 18),
                  TextFormField(
                    key: ValueKey('discord-revoke-url-${channel.id}'),
                    controller: _urls[channel.id],
                    enabled: !_busy,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 2048,
                    decoration: InputDecoration(
                      labelText: '# ${channel.name}',
                      hintText: _text('새 웹훅 주소', 'Replacement webhook URL'),
                      counterText: '',
                    ),
                    validator: (value) => _webhookError(value ?? ''),
                  ),
                ],
                if (widget.channels.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  CheckboxListTile(
                    value: _rotated,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _rotated = value ?? false),
                    title: Text(
                      _text(
                        '기존 웹훅을 삭제하고 새 웹훅을 만들었습니다.',
                        'I deleted the old webhooks and created replacements.',
                      ),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(_text('취소', 'Cancel')),
        ),
        FilledButton(
          onPressed: _busy || (widget.channels.isNotEmpty && !_rotated)
              ? null
              : _revoke,
          child: Text(
            _busy
                ? _text('저장 중…', 'Saving…')
                : _text('주소 변경 및 연결 해제', 'Replace webhooks and disconnect'),
          ),
        ),
      ],
    ),
  );
}

class _ClaimPairingDialog extends StatefulWidget {
  const _ClaimPairingDialog({required this.onClaim});
  final Future<void> Function(String code) onClaim;
  @override
  State<_ClaimPairingDialog> createState() => _ClaimPairingDialogState();
}

class _ClaimPairingDialogState extends State<_ClaimPairingDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<void> _claim() async {
    if (_busy || _code.text.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onClaim(_code.text.trim());
      _code.clear();
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '연결 코드를 확인하세요. 만료되었거나 다른 참여자에게 발급된 코드일 수 있습니다.',
            'Check the connection code. It may have expired or been issued to another member.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text(_text('이 기기 연결', 'Connect this device')),
      content: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _text(
                '프로젝트 소유자가 발급한 개인 연결 코드를 입력하세요.',
                'Enter the private connection code provided by the project owner.',
              ),
              style: WorkspaceUi.captionStyleOf(context),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('discord-claim-code'),
              controller: _code,
              enabled: !_busy,
              obscureText: true,
              autofocus: true,
              maxLength: 2048,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: _text('연결 코드', 'Connection code'),
                counterText: '',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _text(
                '요청 후 표시되는 기기 확인 코드를 소유자에게 전달하세요. 승인이 완료되면 이 기기에서도 알림을 전송할 수 있습니다.',
                'Share the fingerprint shown after requesting access with the owner. Once approved, this device can send notifications.',
              ),
              style: WorkspaceUi.captionStyleOf(context),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(_text('취소', 'Cancel')),
        ),
        FilledButton(
          onPressed: _busy || _code.text.trim().isEmpty ? null : _claim,
          child: Text(
            _busy
                ? _text('요청 중…', 'Requesting…')
                : _text('연결 요청', 'Request connection'),
          ),
        ),
      ],
    ),
  );
}
