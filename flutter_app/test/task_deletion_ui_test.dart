import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/task_editor.dart';

import 'task_deletion_test.dart' show storeFor, task;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  testWidgets('registration works after every existing task is deleted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = storeFor(seed: task());
    store.deleteTask('delete-task', expectedVersion: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => TaskEditor(store: store),
              ),
              child: const Text('등록'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('등록'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('task-title')), '삭제 후 새 작업 등록');
    await tester.enterText(
      find.byKey(const Key('task-description')),
      '입력 내용을 유지합니다.',
    );
    await tester.tap(find.byKey(const Key('task-save')));
    await tester.pumpAndSettle();
    expect(store.tasks.single.title, '삭제 후 새 작업 등록');
    expect(store.tasks.single.description, '입력 내용을 유지합니다.');
    expect(store.storedTasks, hasLength(2));
    expect(find.byType(TaskEditor), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'task deletion requires confirmation and leaves no card after deletion',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = storeFor(seed: task());
      await tester.pumpWidget(IeumApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-kanban')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('card-delete-task')));
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('task-delete-delete-task'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('작업을 삭제할까요?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('task-delete-cancel')));
      await tester.pumpAndSettle();
      expect(store.find('delete-task').version, 1);
      expect(store.changes, isEmpty);
      await tester.tap(button);
      await tester.pumpAndSettle();
      // The confirmation remains usable at the supported narrow window width.
      tester.view.physicalSize = const Size(360, 540);
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('task-delete-confirm'));
      expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(540));
      expect(tester.takeException(), isNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(store.tasks, isEmpty);
      expect(find.byKey(const Key('card-delete-task')), findsNothing);
      expect(find.byKey(const Key('task-delete-delete-task')), findsNothing);
      expect(store.changes, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
}
