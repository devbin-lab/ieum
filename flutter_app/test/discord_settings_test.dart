import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/discord_settings.dart';

DiscordNotificationsSettings settings({
  Future<void> Function(String?)? saveId,
  Future<void> Function(DiscordChannelDraft)? saveChannel,
  Future<void> Function(String)? retry,
  Future<void> Function(String)? claim,
  List<DiscordDeliveryView> history = const [],
  DiscordDeviceState deviceState = DiscordDeviceState.disconnected,
  bool owner = false,
}) => DiscordNotificationsSettings(
  projectConnected: true,
  canManageChannels: owner,
  currentMemberName: 'Team member',
  channels: const [],
  parts: const [],
  members: const [DiscordMemberOption('gh-1', 'Team member')],
  deviceState: deviceState,
  deviceRequests: const [],
  onSaveDiscordId: saveId ?? (_) async {},
  onSaveChannel: saveChannel ?? (_) async {},
  onDeleteChannel: (_) async {},
  onToggleChannel: (_, _) async {},
  onCreatePairingCode: (_) async => 'private-pairing-code',
  onClaimPairingCode: claim ?? (_) async {},
  onDecideDevice: (_, _) async {},
  deliveryHistory: history,
  onRetryDelivery: retry,
);

Future<void> showSettings(WidgetTester tester, Widget widget) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: widget,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => setAppLanguage('ko'));

  testWidgets(
    'status-change notification is on by default and can be disabled independently',
    (tester) async {
      DiscordChannelDraft? saved;
      await showSettings(
        tester,
        settings(owner: true, saveChannel: (draft) async => saved = draft),
      );
      await tester.tap(find.byKey(const Key('discord-add-channel')));
      await tester.pumpAndSettle();
      final statusChange = find.widgetWithText(FilterChip, '상태 변경');
      expect(tester.widget<FilterChip>(statusChange).selected, isTrue);
      await tester.tap(statusChange);
      await tester.pump();
      expect(tester.widget<FilterChip>(statusChange).selected, isFalse);
      await tester.enterText(
        find.byKey(const Key('discord-channel-name')),
        'updates',
      );
      await tester.enterText(
        find.byKey(const Key('discord-webhook-url')),
        'https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz',
      );
      await tester.tap(find.widgetWithText(FilledButton, '저장').last);
      await tester.pumpAndSettle();
      expect(saved, isNotNull);
      expect(
        saved!.events,
        containsAll([
          DiscordNoticeEvent.assignment,
          DiscordNoticeEvent.handoff,
          DiscordNoticeEvent.completed,
        ]),
      );
      expect(saved!.events, isNot(contains(DiscordNoticeEvent.statusChanged)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending member can request access with a replacement code', (
    tester,
  ) async {
    String? submitted;
    await showSettings(
      tester,
      settings(
        deviceState: DiscordDeviceState.pending,
        claim: (code) async => submitted = code,
      ),
    );
    expect(find.text('새 연결 코드 입력'), findsOneWidget);
    await tester.tap(find.byKey(const Key('discord-claim-pairing')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('discord-claim-code')),
      'replacement-code',
    );
    await tester.pump();
    await tester.tap(find.text('연결 요청'));
    await tester.pumpAndSettle();
    expect(submitted, 'replacement-code');
    expect(tester.takeException(), isNull);
  });

  testWidgets('self registration rejects invalid ID and saves numeric ID', (
    tester,
  ) async {
    String? saved;
    await showSettings(
      tester,
      settings(saveId: (value) async => saved = value),
    );
    await tester.enterText(find.byKey(const Key('discord-self-id')), '1234');
    await tester.pump();
    await tester.tap(find.byKey(const Key('discord-save-self-id')));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('17~20자리 숫자 사용자 ID를 입력하세요.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('discord-self-id')),
      '123456789012345678',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('discord-save-self-id')));
    await tester.pumpAndSettle();
    expect(saved, '123456789012345678');
  });

  testWidgets('webhook errors never reveal transport URL or token', (
    tester,
  ) async {
    const token =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    const url = 'https://discord.com/api/webhooks/123456789012345678/$token';
    await showSettings(
      tester,
      settings(
        owner: true,
        saveChannel: (_) async => throw StateError('Network failed for $url'),
      ),
    );
    await tester.tap(find.byKey(const Key('discord-add-channel')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('discord-channel-name')),
      'project-updates',
    );
    await tester.enterText(find.byKey(const Key('discord-webhook-url')), url);
    await tester.tap(find.widgetWithText(FilledButton, '저장').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('채널을 연결하지 못했습니다.'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && (widget.data?.contains(token) ?? false),
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('discord-webhook-url')),
              matching: find.byType(TextField),
            ),
          )
          .obscureText,
      isTrue,
    );
    expect(find.textContaining('Network failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uncertain delivery requires explicit resend confirmation', (
    tester,
  ) async {
    var attempts = 0;
    await showSettings(
      tester,
      settings(
        retry: (_) async => attempts++,
        history: [
          DiscordDeliveryView(
            id: 'delivery-1',
            title: 'Task',
            channelName: 'updates',
            state: DiscordDeliveryState.uncertain,
            createdAt: DateTime(2026, 10, 10),
          ),
        ],
      ),
    );
    await tester.ensureVisible(find.text('다시 전송'));
    await tester.tap(find.text('다시 전송'));
    await tester.pumpAndSettle();
    expect(attempts, 0);
    expect(find.text('알림을 다시 전송할까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(attempts, 0);
    await tester.tap(find.text('다시 전송'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다시 전송').last);
    await tester.pumpAndSettle();
    expect(attempts, 1);
  });

  testWidgets('new settings copy follows English display language', (
    tester,
  ) async {
    setAppLanguage('en');
    await showSettings(tester, settings());
    expect(find.text('My Discord account'), findsOneWidget);
    expect(find.text('Discord channels'), findsOneWidget);
    expect(find.text('Notifications from this device'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
