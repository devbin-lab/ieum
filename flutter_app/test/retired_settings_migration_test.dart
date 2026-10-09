import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  for (final (oldName, expected) in [
    ('assignments', SettingsSection.roles),
    ('workflow', SettingsSection.projectGeneral),
  ]) {
    testWidgets('restores retired $oldName settings to its current section', (
      tester,
    ) async {
      final store = TaskStore(':memory:');
      store.setMeta(
        'ui.workspace',
        jsonEncode({
          'page': 2,
          'settings': oldName,
          'view': 'kanban',
          'projectTabsVersion': 1,
          'lastWorkPage': 0,
        }),
      );
      try {
        await tester.pumpWidget(IeumApp(store: store));
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(Workspace));
        expect(state.page, 2);
        expect(state.settingsSection, expected);
        expect(state.taskView, TaskView.kanban);
        expect(state.lastWorkPage, 0);
        expect(
          jsonDecode(store.meta('ui.workspace'))['settings'],
          expected.name,
        );
        expect(store.tasks, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }
    });
  }

  for (final version in [null, 1]) {
    testWidgets('restores retired page 3 with saved tab version $version', (
      tester,
    ) async {
      final store = TaskStore(':memory:');
      store.setMeta(
        'ui.workspace',
        jsonEncode({
          'page': 3,
          'settings': 'workflow',
          'projectTabsVersion': ?version,
        }),
      );
      try {
        await tester.pumpWidget(IeumApp(store: store));
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(Workspace));
        expect(state.page, 2);
        expect(state.settingsSection, SettingsSection.projectGeneral);
        final saved = jsonDecode(store.meta('ui.workspace'));
        expect(saved['page'], 2);
        expect(saved['settings'], 'projectGeneral');
        expect(saved['projectTabsVersion'], 1);
        expect(store.tasks, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }
    });
  }

  test(
    'current settings names remain stable and unknown names use general',
    () {
      for (final section in SettingsSection.values) {
        expect(SettingsSection.fromSaved(section.name), section);
      }
      expect(SettingsSection.fromSaved('unknown'), SettingsSection.general);
      expect(SettingsSection.fromSaved(null), SettingsSection.general);
    },
  );
}
