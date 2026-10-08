import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/notification_inbox.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  final today = DateTime.now();
  final records = [
    {
      'id': 'review',
      'projectPath': 'alpha',
      'projectName': '호환 · 졸업작품',
      'title': '보스 전투 기획안 검토를 요청했습니다.',
      'eventType': 'task.review',
      'createdAt': today.toIso8601String(),
      'read': false,
      'isMyMention': true,
      'reason': '수정된 공격 패턴과 연출 흐름을 확인해 주세요.',
    },
    {
      'id': 'assigned',
      'projectPath': 'alpha',
      'projectName': '호환 · 졸업작품',
      'title': '튜토리얼 진행 흐름 정리 작업이 배정되었습니다.',
      'eventType': 'task.assigned',
      'createdAt': today.toIso8601String(),
      'read': true,
    },
    {
      'id': 'done',
      'projectPath': 'beta',
      'projectName': '이음',
      'title': '알림 화면 정돈 작업이 완료되었습니다.',
      'eventType': 'task.done',
      'createdAt': DateTime(
        today.year,
        today.month,
        today.day - 1,
        16,
        20,
      ).toIso8601String(),
      'read': false,
    },
  ];

  testWidgets(
    'restored notification tab loads history and keeps the project view closed',
    (tester) async {
      final store = TaskStore(':memory:');
      addTearDown(store.dispose);
      store.db.execute('INSERT INTO notification_outbox VALUES (?,?)', [
        records.first['id'],
        jsonEncode(records.first),
      ]);
      store.setMeta('ui.workspace', jsonEncode({'page': 4}));
      store.setMeta('ui.projectView', 'open');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      await tester.pumpWidget(
        IeumApp(
          store: store,
          home: Workspace(store: store, projectSwitcher: const Text('프로젝트 선택')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(records.first['title'] as String), findsOneWidget);
      expect(find.byKey(const Key('project-view-sidebar')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'inbox fits narrow, portrait and wide windows, including scaled text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final capture = Platform.environment['IEUM_CAPTURE_INBOX'] == '1';
      if (capture) {
        for (final font in [
          ('Malgun Gothic', 'C:/Windows/Fonts/malgun.ttf'),
          ('Roboto', 'C:/Windows/Fonts/malgun.ttf'),
          ('Ahem', 'C:/Windows/Fonts/malgun.ttf'),
          (
            'MaterialIcons',
            'C:/Users/devbin0318/develop/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ),
        ]) {
          final loader = FontLoader(font.$1)
            ..addFont(
              Future.value(
                ByteData.sublistView(File(font.$2).readAsBytesSync()),
              ),
            );
          await tester.runAsync(loader.load);
        }
      }
      for (final width in [320.0, 476.0, 1016.0, 1376.0]) {
        tester.view.physicalSize = Size(width, 860);
        for (final empty in [false, true]) {
          for (final scale in [1.0, 1.5]) {
            final boundary = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(
                  fontFamily: 'Malgun Gothic',
                  useMaterial3: true,
                  outlinedButtonTheme: OutlinedButtonThemeData(
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                home: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 860),
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Scaffold(
                    backgroundColor: const Color(0xfffafbfa),
                    body: RepaintBoundary(
                      key: boundary,
                      child: ColoredBox(
                        color: const Color(0xfffafbfa),
                        child: NotificationInbox(
                          notifications: empty ? [] : records,
                          projects: const {
                            'all': '모든 프로젝트',
                            'alpha': '호환 · 졸업작품',
                            'beta': '이음',
                          },
                          selectedProject: 'all',
                          unreadOnly: false,
                          mentionsOnly: false,
                          onProjectChanged: (_) {},
                          onUnreadChanged: (_) {},
                          onMentionsChanged: (_) {},
                          onResetFilters: () {},
                          onRefresh: () {},
                          onRead: (_) {},
                          onReadVisible: (_) {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$width / $empty / $scale',
            );
            final filter = tester.getRect(
              find.byKey(const Key('notification-project-filter')),
            );
            expect(filter.right, lessThanOrEqualTo(width));
            expect(filter.left, greaterThanOrEqualTo(0));
            if (capture && scale == 1 && width != 320 && width != 1376) {
              await tester.runAsync(() async {
                final image =
                    await (boundary.currentContext!.findRenderObject()
                            as RenderRepaintBoundary)
                        .toImage();
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  '../.local/ui-audit/notification-polish/${width.toInt()}-${empty ? 'empty' : 'inbox'}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(bytes!.buffer.asUint8List());
                image.dispose();
              });
            }
          }
        }
      }
    },
  );

  testWidgets(
    'selecting an alert opens its details on the right and on narrow screens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.physicalSize = const Size(1200, 820);
      final detailed = {
        ...records.first,
        'taskId': 'TASK-REVIEW',
        'taskDescription': '공격 패턴의 순서와 검토 기준을 확인합니다.',
        'taskStatus': '검토',
        'taskAssigneeName': '작업자',
      };
      String? selected;
      String? marked;
      Widget app() => MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NotificationInbox(
              notifications: [detailed],
              projects: const {'all': '모든 프로젝트', 'alpha': '호환 · 졸업작품'},
              selectedProject: 'all',
              selectedNotificationKey: selected,
              unreadOnly: false,
              mentionsOnly: false,
              onProjectChanged: (_) {},
              onUnreadChanged: (_) {},
              onMentionsChanged: (_) {},
              onResetFilters: () {},
              onRefresh: () {},
              onRead: (n) => marked = n['id'] as String,
              onReadVisible: (_) {},
              onSelect: (n) =>
                  setState(() => selected = '${n['projectPath']}:${n['id']}'),
              onCloseDetail: () => setState(() => selected = null),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('notification-detail-empty')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('notification-alpha-review')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notification-detail')), findsOneWidget);
      expect(find.text('공격 패턴의 순서와 검토 기준을 확인합니다.'), findsOneWidget);
      expect(find.text('검토'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notification-detail-mark-read')));
      expect(marked, 'review');
      await tester.tap(find.byKey(const Key('notification-detail-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('notification-detail-empty')),
        findsOneWidget,
      );

      tester.view.physicalSize = const Size(540, 820);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('notification-alpha-review')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notification-detail')), findsOneWidget);
      expect(
        find.byKey(const Key('notification-project-filter')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('notification-detail-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('notification-project-filter')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('project and mention filters scope counts', (tester) async {
    var project = 'all';
    var mentions = false;
    var unread = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NotificationInbox(
              notifications: records,
              projects: const {
                'all': '모든 프로젝트',
                'alpha': '호환',
                'beta': '이음',
                'empty': '빈 프로젝트',
              },
              selectedProject: project,
              unreadOnly: unread,
              mentionsOnly: mentions,
              onProjectChanged: (v) => setState(() => project = v),
              onUnreadChanged: (v) => setState(() => unread = v),
              onMentionsChanged: (v) => setState(() => mentions = v),
              onResetFilters: () => setState(() {
                project = 'all';
                mentions = false;
                unread = false;
              }),
              onRefresh: () {},
              onRead: (_) {},
              onReadVisible: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('3개 · 안 읽음 2개'), findsOneWidget);
    expect(find.text('오늘'), findsOneWidget);
    expect(find.text('어제'), findsOneWidget);
    await tester.tap(find.byKey(const Key('notification-project-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('option-alpha')));
    await tester.pumpAndSettle();
    expect(find.text('2개 · 안 읽음 1개'), findsOneWidget);
    expect(find.text(records[2]['title'] as String), findsNothing);
    await tester.tap(find.byKey(const Key('notification-mentions-filter')));
    await tester.pumpAndSettle();
    expect(find.text('1개 · 안 읽음 1개'), findsOneWidget);
    await tester.tap(find.byKey(const Key('notification-project-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('option-empty')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reset-notification-filters')));
    await tester.pumpAndSettle();
    expect(find.text('3개 · 안 읽음 2개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
