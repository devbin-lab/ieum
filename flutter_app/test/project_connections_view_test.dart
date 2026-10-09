import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/project_connections_view.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  testWidgets(
    'connections hub fits narrow views and exposes real queue states without changing them',
    (tester) async {
      final store = TaskStore(':memory:');
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(480, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.setMeta(
        'github.config',
        jsonEncode({
          'repository': 'team/a-project-with-a-long-repository-name',
          'base': 'main',
          'enabled': true,
        }),
      );
      store.setMeta(
        'github.pullConflicts',
        jsonEncode([
          {'taskId': 'TASK-1', 'field': 'title'},
          {'taskId': 'TASK-1', 'field': 'status'},
        ]),
      );
      for (final state in ['pending', 'sent', 'failed']) {
        store.db.execute('INSERT INTO github_queue VALUES (?, ?)', [
          state,
          jsonEncode({
            'state': state,
            'error': state == 'failed' ? '저장소 접근 권한을 확인해 주세요.' : '',
          }),
        ]);
      }
      var settings = 0, members = 0;
      Widget view() => MaterialApp(
        home: Scaffold(
          body: ProjectConnectionsView(
            store: store,
            onOpenSettings: () => settings++,
            onOpenWorkflow: () {},
            onOpenMembers: () => members++,
            automaticRoutes: 2,
          ),
        ),
      );
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        find.text('team/a-project-with-a-long-repository-name'),
        findsOneWidget,
      );
      expect(find.text('반영 대기'), findsOneWidget);
      expect(find.text('아직 동기화 기록이 없습니다.'), findsOneWidget);
      expect(find.text('1'), findsNWidgets(4));
      expect(find.byKey(const Key('connections-sync-now')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('connections-open-settings')));
      expect(settings, 1);
      expect(find.byKey(const Key('connections-open-workflow')), findsNothing);
      final membersButton = find.byKey(const Key('connections-open-members'));
      final contentScrollable = find.descendant(
        of: find.byKey(const Key('connections-content')),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        membersButton,
        220,
        scrollable: contentScrollable,
      );
      await tester.pumpAndSettle();
      expect(membersButton.hitTestable(), findsOneWidget);
      await tester.tap(membersButton);
      expect(members, 1);
      tester.view.physicalSize = const Size(300, 520);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      store.setMeta('github.config', '');
      await tester.pumpWidget(view());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('connections-open-settings')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('저장소 연결'), findsOneWidget);
      expect(
        store.db
            .select('SELECT COUNT(*) AS count FROM github_queue')
            .single['count'],
        3,
      );
      expect(store.tasks, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
