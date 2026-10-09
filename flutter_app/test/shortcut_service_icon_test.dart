import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/shortcut_service_icon.dart';

void main() {
  testWidgets('bundled service SVGs contain visible vector artwork', (
    tester,
  ) async {
    for (final entry in ShortcutServiceIcon.assets.entries) {
      final pixels = await tester.runAsync(() async {
        final source = await rootBundle.loadString(entry.value);
        final picture = await vg.loadPicture(SvgStringLoader(source), null);
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
          ..scale(48 / picture.size.longestSide)
          ..drawPicture(picture.picture);
        final fitted = recorder.endRecording();
        final image = await fitted.toImage(48, 48);
        try {
          return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        } finally {
          image.dispose();
          fitted.dispose();
          picture.picture.dispose();
        }
      });
      expect(pixels, isNotNull, reason: entry.key);
      var painted = 0;
      for (var offset = 3; offset < pixels!.lengthInBytes; offset += 4) {
        if (pixels.getUint8(offset) > 0) painted++;
      }
      expect(painted, greaterThan(10), reason: '${entry.key} is blank');
    }
  });

  testWidgets('all service marks and custom fallback render in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: boundaryKey,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final service in [
                      ...ShortcutServiceIcon.assets.keys,
                      'custom',
                    ])
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: ShortcutServiceIcon(service: service),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future.wait([
          for (final asset in ShortcutServiceIcon.assets.values)
            SvgAssetLoader(asset).loadBytes(null),
        ]);
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SvgPicture), findsNWidgets(8));
      final boundary =
          boundaryKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      final pixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return pixels;
      });
      expect(pixels, isNotNull);
      for (var icon = 0; icon < 9; icon++) {
        var painted = 0;
        for (var y = 8; y < 32; y++) {
          for (var x = icon * 40 + 8; x < icon * 40 + 32; x++) {
            final alphaOffset = (y * 360 + x) * 4 + 3;
            if (pixels!.getUint8(alphaOffset) > 0) painted++;
          }
        }
        expect(
          painted,
          greaterThan(10),
          reason: 'Icon $icon is blank in ${brightness.name} mode',
        );
      }
    }
  });
}
