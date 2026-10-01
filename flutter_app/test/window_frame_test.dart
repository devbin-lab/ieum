import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/window_frame.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final calls = <String>[];
  bool maximized = false;

  setUp(() {
    calls.clear();
    maximized = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'isMaximized':
              return maximized;
            case 'isFullScreen':
              return false;
            case 'maximize':
              maximized = true;
            case 'unmaximize':
              maximized = false;
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> setup(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => DesktopFrame(child: child!),
        home: const Scaffold(body: Text('작업 화면')),
      ),
    );
    await tester.pumpAndSettle();
    calls.clear();
  }

  testWidgets(
    'caption controls call native actions and refresh restore state',
    (tester) async {
      await setup(tester);
      await tester.tap(find.byKey(const Key('window-minimize')));
      await tester.pumpAndSettle();
      expect(calls, contains('minimize'));
      await tester.tap(find.byKey(const Key('window-maximize')));
      await tester.pumpAndSettle();
      expect(calls, contains('maximize'));
      expect(find.byTooltip('이전 크기로 복원'), findsOneWidget);
      await tester.tap(find.byKey(const Key('window-maximize')));
      await tester.pumpAndSettle();
      expect(calls, contains('unmaximize'));
      expect(find.byTooltip('최대화'), findsOneWidget);
      await tester.tap(find.byKey(const Key('window-close')));
      await tester.pumpAndSettle();
      expect(calls, contains('close'));
      expect(calls, isNot(contains('startDragging')));

      maximized = true;
      for (final listener in windowManager.listeners) {
        listener.onWindowMaximize();
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('이전 크기로 복원'), findsOneWidget);
      maximized = false;
      for (final listener in windowManager.listeners) {
        listener.onWindowUnmaximize();
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('최대화'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(windowManager.listeners, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'caption drag and double click delegate to native window manager',
    (tester) async {
      await setup(tester);
      final dragArea = find.byKey(const Key('window-drag-area'));
      await tester.drag(dragArea, const Offset(90, 30));
      await tester.pumpAndSettle();
      expect(calls, contains('startDragging'));

      calls.clear();
      await tester.tap(dragArea);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(dragArea);
      await tester.pumpAndSettle();
      expect(calls, contains('maximize'));
      for (final listener in windowManager.listeners) {
        listener.onWindowMaximize();
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('이전 크기로 복원'), findsOneWidget);

      await tester.tap(dragArea);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(dragArea);
      await tester.pumpAndSettle();
      expect(calls, contains('unmaximize'));
      expect(tester.takeException(), isNull);
    },
  );
}
