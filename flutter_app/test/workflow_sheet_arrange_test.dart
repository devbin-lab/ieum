import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';

void main() {
  testWidgets(
    'arrange restores readable stage order and fits labels without changing routing',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (const bool.fromEnvironment('IEUM_UI_PREVIEW')) {
        await tester.runAsync(() async {
          await (FontLoader('Malgun Gothic')..addFont(
                File('C:/Windows/Fonts/malgun.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      const sheet = WorkflowSheet(
        nodes: [
          WorkflowSheetNode('todo', 'todo', x: -600, y: 180),
          WorkflowSheetNode('doing', 'doing', x: 50, y: 310),
          WorkflowSheetNode('review', 'review', x: 500, y: -200),
          WorkflowSheetNode('done', 'done', x: 800, y: 70),
        ],
        routes: [
          WorkflowSheetRoute(id: 'start', from: 'todo', to: 'doing'),
          WorkflowSheetRoute(
            id: 'submit',
            from: 'doing',
            to: 'review',
            labelDx: 400,
            labelDy: 300,
          ),
          WorkflowSheetRoute(
            id: 'reject',
            from: 'review',
            to: 'todo',
            action: 'reject',
          ),
          WorkflowSheetRoute(
            id: 'approve',
            from: 'review',
            to: 'done',
            action: 'approve',
          ),
        ],
      );
      WorkflowSheet? arranged;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true, fontFamily: 'Malgun Gothic'),
          home: Scaffold(
            body: WorkflowSheetCanvas(
              stageCatalog: const [
                WorkflowStage('todo', '확인중'),
                WorkflowStage('doing', '진행중'),
                WorkflowStage('review', '검토'),
                WorkflowStage('done', '완료'),
              ],
              value: sheet,
              onChanged: (s) => arranged = s,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-sheet-arrange')));
      await tester.pumpAndSettle();
      expect(arranged!.policyJson, sheet.policyJson);
      expect(arranged!.nodes.map((n) => n.y).toSet(), {0.0});
      final ordered = arranged!.nodes.map((n) => n.x).toList();
      expect(ordered, ordered.toList()..sort());
      expect(
        arranged!.routes.every((r) => r.labelDx == 0 && r.labelDy == 0),
        isTrue,
      );
      final viewport = tester.getRect(
        find.byKey(const Key('workflow-sheet-viewport')),
      );
      for (final route in sheet.routes) {
        final rect = tester.getRect(
          find.byKey(Key('workflow-sheet-route-${route.from}-${route.to}-0')),
        );
        expect(viewport.contains(rect.topLeft), isTrue);
        expect(viewport.contains(rect.bottomRight), isTrue);
      }
      final firstLayout = arranged!.json;
      await tester.tap(find.byKey(const Key('workflow-sheet-arrange')));
      await tester.pumpAndSettle();
      expect(arranged!.json, firstLayout);
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('IEUM_UI_PREVIEW')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('workflow-sheet-render-boundary')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('../.local/workflow-polish.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
}
