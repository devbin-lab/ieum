import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/app_theme.dart';
import 'package:ieum_flutter/github_panel.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_connections_view.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/sync_recovery_ui.dart';

import 'github_sync_test.dart' show FakeGitHubApi;

const legacyNotice = '손상된 전송 기록을 복구 기록에 보관했습니다. 저장된 작업을 기준으로 전송을 다시 준비합니다.';

String archive(TaskStore store, int number) {
  final body = jsonEncode({
    'table': 'github_queue',
    'recordId': 'TASK-$number',
    'raw': jsonEncode({'title': '원본 작업 $number'}),
    'error': 'Bad state: 작업 데이터에 지원하지 않는 항목이 있습니다.',
    'createdAt': '2026-10-08T00:10:15Z',
  });
  store.db.execute('INSERT INTO sync_recovery VALUES (?,?)', [
    'recovery-$number',
    body,
  ]);
  store.setMeta('github.recoveryNotice', legacyNotice);
  return body;
}

void main() {
  setUp(() => setAppLanguage('ko'));
  tearDown(() => setAppLanguage('ko'));

  test('acknowledgment persists after reopening without changing original records or uploads', () async {
    final folder = await Directory.systemTemp.createTemp(
      'ieum-recovery-notice-',
    );
    final path = '${folder.path}/project.sqlite';
    var store = TaskStore(path);
    try {
      final original = archive(store, 1);
      store.db.execute('INSERT INTO github_queue VALUES (?,?)', [
        'untouched',
        '{"state":"pending"}',
      ]);
      store.acknowledgeSyncRecoveryNotice(
        through: store.latestSyncRecoveryIndex,
      );
      expect(store.hasSyncRecoveryNotice, isFalse);
      expect(
        store.db.select('SELECT body FROM sync_recovery').single['body'],
        original,
      );
      expect(
        store.db.select('SELECT body FROM github_queue').single['body'],
        '{"state":"pending"}',
      );
      store.dispose();
      store = TaskStore(path);
      expect(store.hasSyncRecoveryNotice, isFalse);
      expect(store.syncRecoveryRecords().single.taskTitle, '원본 작업 1');
      expect(store.syncRecoveryCount(), 1);
    } finally {
      store.dispose();
      await folder.delete(recursive: true);
    }
  });

  test('confirming an older notice cannot dismiss a new recovery event', () {
    final store = TaskStore(':memory:');
    final api = FakeGitHubApi();
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(() {
      sync.dispose();
      store.dispose();
    });
    store.db.execute('INSERT INTO github_queue VALUES (?,?)', ['first', '{']);
    expect(sync.jobs, isEmpty);
    final shown = store.latestSyncRecoveryIndex;
    expect(
      store.syncRecoveryRecords().single.reason,
      '전송 기록의 형식이 올바르지 않아 읽을 수 없었습니다.',
    );
    store.db.execute('INSERT INTO github_queue VALUES (?,?)', ['second', '{']);
    expect(sync.jobs, isEmpty);
    store.acknowledgeSyncRecoveryNotice(through: shown);
    expect(store.hasSyncRecoveryNotice, isTrue);
    expect(store.syncRecoveryCount(), 2);
    store.acknowledgeSyncRecoveryNotice(through: store.latestSyncRecoveryIndex);
    expect(store.hasSyncRecoveryNotice, isFalse);
    expect(store.syncRecoveryCount(), 2);
    expect(api.calls, isEmpty);
  });

  testWidgets(
    'recovery reasons and original errors remain available after confirmation',
    (tester) async {
      final store = TaskStore(':memory:');
      addTearDown(store.dispose);
      archive(store, 1);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Colors.black, Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  SyncRecoveryHistoryButton(store: store),
                  SyncRecoveryNotice(store: store),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('sync-recovery-view-records')));
      await tester.pumpAndSettle();
      expect(find.text('원본 작업 1'), findsOneWidget);
      expect(find.text('당시 앱에서 지원하지 않는 작업 항목이 포함되어 있었습니다.'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('sync-recovery-details-recovery-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('작업 데이터에 지원하지 않는 항목이 있습니다.'), findsOneWidget);
      expect(find.text('TASK-1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-recovery-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-recovery-notice')), findsNothing);
      expect(find.byKey(const Key('sync-recovery-history')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-recovery-history')));
      await tester.pumpAndSettle();
      expect(find.text('원본 작업 1'), findsOneWidget);
      expect(store.syncRecoveryCount(), 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'history is paginated in small dark windows and retains unseen newer notices',
    (tester) async {
      final store = TaskStore(':memory:');
      addTearDown(store.dispose);
      for (var i = 0; i < 12; i++) {
        archive(store, i);
      }
      tester.view.physicalSize = const Size(320, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      setAppLanguage('en');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Colors.white, Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SyncRecoveryNotice(store: store),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('sync-recovery-view-records')));
      await tester.pumpAndSettle();
      expect(find.text('12 records · Page 1 of 2'), findsOneWidget);
      expect(find.text('Previous'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
      expect(find.text('원본 작업 11'), findsOneWidget);
      expect(find.text('원본 작업 1'), findsNothing);
      await tester.tap(find.byKey(const Key('sync-recovery-next')));
      await tester.pumpAndSettle();
      expect(find.text('12 records · Page 2 of 2'), findsOneWidget);
      expect(find.text('원본 작업 1'), findsOneWidget);
      expect(find.text('원본 작업 11'), findsNothing);
      archive(store, 12);
      await tester.tap(find.byKey(const Key('sync-recovery-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-recovery-notice')), findsOneWidget);
      expect(store.hasSyncRecoveryNotice, isTrue);
      expect(store.syncRecoveryCount(), 13);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'both connection screens share acknowledgment and keep history accessible',
    (tester) async {
      final store = TaskStore(':memory:');
      final sync = GitHubSync(
        store,
        publisher: GitHubPublisher(FakeGitHubApi()),
      );
      addTearDown(() {
        sync.dispose();
        store.dispose();
      });
      archive(store, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: GitHubPanel(sync: sync)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-recovery-notice')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('sync-recovery-acknowledge')),
      );
      await tester.tap(find.byKey(const Key('sync-recovery-acknowledge')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-recovery-notice')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectConnectionsView(
              store: store,
              onOpenSettings: () {},
              onOpenWorkflow: () {},
              onOpenMembers: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sync-recovery-notice')), findsNothing);
      expect(find.byKey(const Key('sync-recovery-history')), findsOneWidget);
      await tester.tap(find.byKey(const Key('sync-recovery-history')));
      await tester.pumpAndSettle();
      expect(find.text('원본 작업 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
