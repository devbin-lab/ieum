import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/window_frame.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'titlebar hover stays identical from entry through dwell and rebuild',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      final controller = SidebarTitlebarController();
      var backCalls = 0, forwardCalls = 0, sidebarCalls = 0;
      void configure({bool enabled = true}) => controller.configure(
        () => sidebarCalls++,
        true,
        back: enabled ? () => backCalls++ : null,
        forward: enabled ? () => forwardCalls++ : null,
      );
      configure();
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            useMaterial3: true,
            hoverColor: Colors.red,
            highlightColor: Colors.purple,
          ),
          home: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox(
                width: 400,
                child: IeumTitleBar(sidebarController: controller),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<List<int>> pixels(Rect rect) async =>
          (await tester.runAsync(() async {
            final image =
                await (boundaryKey.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            try {
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!.buffer.asUint8List();
              return <int>[
                for (var y = rect.top.toInt(); y < rect.bottom.toInt(); y++)
                  ...bytes.sublist(
                    (y * image.width + rect.left.toInt()) * 4,
                    (y * image.width + rect.right.toInt()) * 4,
                  ),
              ];
            } finally {
              image.dispose();
            }
          }))!;

      final mouse = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: const Offset(200, 18));
      for (final key in [
        'titlebar-back',
        'titlebar-forward',
        'titlebar-sidebar-toggle',
      ]) {
        final target = find.byKey(Key(key));
        final rect = tester.getRect(target);
        final idle = await pixels(rect);
        await mouse.moveTo(rect.center);
        await tester.pump();
        final entered = await pixels(rect);
        expect(
          entered,
          isNot(equals(idle)),
          reason: '$key must highlight on entry',
        );
        final background = Rect.fromLTWH(rect.center.dx, 7, 1, 1);
        expect(
          await pixels(background),
          [214, 218, 216, 255],
          reason:
              '$key must show the final solid gray in the first hover frame',
        );
        for (final ms in [16, 64, 130, 250, 750, 1000]) {
          await tester.pump(Duration(milliseconds: ms));
          expect(
            await pixels(rect),
            entered,
            reason: '$key changed color during hover after another ${ms}ms',
          );
        }
        // Moving between the inset background and its padding is still one target.
        await mouse.moveTo(Offset(rect.left + 1, rect.center.dy));
        await tester.pump();
        expect(await pixels(rect), entered);
        configure();
        await tester.pump();
        expect(
          await pixels(rect),
          entered,
          reason: 'controller rebuild reset $key hover',
        );
        await tester.tap(target);
        await tester.pump();
        expect(
          await pixels(rect),
          entered,
          reason: 'click added another background',
        );
        await mouse.moveTo(const Offset(200, 18));
        await tester.pump();
        expect(await pixels(rect), idle, reason: 'hover must clear on exit');
      }
      expect([backCalls, forwardCalls, sidebarCalls], [1, 1, 1]);

      // Keyboard activation survives replacing the Material buttons.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(backCalls, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(forwardCalls, 2);

      configure(enabled: false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('titlebar-back')));
      expect(backCalls, 2);
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
