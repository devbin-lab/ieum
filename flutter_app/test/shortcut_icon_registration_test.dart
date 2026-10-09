import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_shortcuts_view.dart';
import 'package:ieum_flutter/shortcut_site_icon.dart';
import 'package:ieum_flutter/store.dart';

import 'part_workflow_test_fixtures.dart';

void main() {
  late TaskStore store;
  setUp(() {
    setAppLanguage('ko');
    store = TaskStore(
      ':memory:',
      project: personalReviewProject,
      identity: routeOwner,
    );
  });
  tearDown(() => store.dispose());

  ShortcutSiteIconResult icon(String domain) => ShortcutSiteIconResult(
    url: 'https://$domain/favicon.png',
    bytes: Uint8List(0),
  );

  Future<void> editor(
    WidgetTester tester,
    Future<ShortcutSiteIconResult?> Function(String) discover,
  ) async {
    tester.view.physicalSize = const Size(1200, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectShortcutsView(
            store: store,
            discoverIcon: discover,
            onSave: (entries, expected) async {
              store.updateProject(
                ProjectManifest.fromJson({
                  ...store.project!.json,
                  'shortcuts': entries.map((entry) => entry.json).toList(),
                }),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shortcut-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('shortcut-name')), '팀 문서');
  }

  testWidgets(
    'late metadata from an older address cannot replace the current icon',
    (tester) async {
      final first = Completer<ShortcutSiteIconResult?>();
      final second = Completer<ShortcutSiteIconResult?>();
      await editor(
        tester,
        (url) => url.contains('first.example') ? first.future : second.future,
      );
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'https://first.example/page',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'https://second.example/page',
      );
      await tester.pump(const Duration(milliseconds: 700));
      second.complete(icon('second.example'));
      await tester.pumpAndSettle();
      first.complete(icon('first.example'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      final saved = store.project!.shortcuts!.single;
      expect(saved.url, 'https://second.example/page');
      expect(saved.iconUrl, 'https://second.example/favicon.png');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving before debounce finishes still registers the discovered icon once',
    (tester) async {
      var requests = 0;
      await editor(tester, (_) async {
        requests++;
        return icon('team.example');
      });
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'https://team.example/page',
      );
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      expect(requests, 1);
      expect(
        store.project!.shortcuts!.single.iconUrl,
        'https://team.example/favicon.png',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'choosing the default icon cancels pending results and still saves the link',
    (tester) async {
      final pending = Completer<ShortcutSiteIconResult?>();
      await editor(tester, (_) => pending.future);
      await tester.enterText(
        find.byKey(const Key('shortcut-url')),
        'https://team.example/page',
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.ensureVisible(
        find.byKey(const Key('shortcut-default-icon')),
      );
      await tester.tap(find.byKey(const Key('shortcut-default-icon')));
      await tester.pumpAndSettle();
      pending.complete(icon('team.example'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shortcut-save')));
      await tester.pumpAndSettle();
      expect(store.project!.shortcuts!.single.iconUrl, isNull);
      expect(store.project!.shortcuts!.single.url, 'https://team.example/page');
      expect(store.changes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
