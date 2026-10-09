import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ieum_flutter/workspace_ui.dart';
import 'package:ieum_flutter/work_status_palette.dart';

double contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return (first > second ? first + .05 : second + .05) /
      (first > second ? second + .05 : first + .05);
}

void main() {
  test('workspace text and status labels remain readable in both modes', () {
    for (final brightness in Brightness.values) {
      final palette = WorkspaceColors(
        ColorScheme.fromSeed(seedColor: Colors.teal, brightness: brightness),
      );
      expect(contrast(palette.ink, palette.surface), greaterThanOrEqualTo(7));
      expect(
        contrast(palette.muted, palette.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(palette.chromeInk, palette.chrome),
        greaterThanOrEqualTo(4.5),
      );
      // Existing light status hues remain unchanged; dark variants must retain
      // readable labels on their new graphite-tinted status surfaces.
      if (brightness != Brightness.dark) continue;
      for (final status in [
        'todo',
        'doing',
        'review',
        'done',
        'hold',
        'drop',
      ]) {
        expect(
          contrast(
            statusColor(status, brightness: brightness),
            stageSurfaceColor(status, brightness: brightness),
          ),
          greaterThanOrEqualTo(3),
          reason: '$status in $brightness',
        );
      }
    }
  });

  testWidgets('shared panels and selected tabs respond to theme changes', (
    tester,
  ) async {
    Future<void> mount(Brightness brightness, Color accent) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent,
              brightness: brightness,
            ),
          ),
          home: Scaffold(
            body: WorkspacePanel(
              child: WorkspaceTab(
                label: '작업',
                selected: true,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await mount(Brightness.light, Colors.teal);
    final lightMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WorkspacePanel),
            matching: find.byType(Material),
          )
          .first,
    );
    final lightTab = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(WorkspaceTab),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final lightBorder = (lightTab.decoration as BoxDecoration).border as Border;

    await mount(Brightness.dark, Colors.orange);
    final darkMaterial = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(WorkspacePanel),
            matching: find.byType(Material),
          )
          .first,
    );
    final darkTab = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(WorkspaceTab),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final darkBorder = (darkTab.decoration as BoxDecoration).border as Border;
    expect(darkMaterial.color, isNot(lightMaterial.color));
    expect(darkBorder.bottom.color, isNot(lightBorder.bottom.color));
    expect(tester.takeException(), isNull);
  });
}
