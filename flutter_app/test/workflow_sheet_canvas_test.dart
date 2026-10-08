import 'dart:math' as math;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/settings_shell.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/workflow_sheet_canvas.dart';

const legacyWorkflowStages = [
  WorkflowStage('todo', '확인중'),
  WorkflowStage('doing', '진행중'),
  WorkflowStage('review', '검토'),
  WorkflowStage('done', '완료'),
];

void main() {
  var previewFontsLoaded = false;
  final savedMenuPreviews = <String>{};
  Future<void> openSheet(
    WidgetTester tester, {
    List<WorkflowStage> stages = legacyWorkflowStages,
    List<ProjectRole> roles = const [],
    List<Person> people = const [],
    List<String> parts = const [],
  }) async {
    if (const bool.fromEnvironment('IEUM_UI_PREVIEW') && !previewFontsLoaded) {
      await tester.runAsync(() async {
        await (FontLoader('Malgun Gothic')..addFont(
              File('C:/Windows/Fonts/malgun.ttf')
                  .readAsBytes()
                  .then(ByteData.sublistView),
            ))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      previewFontsLoaded = true;
    }
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: const Key('workflow-menu-preview-root'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(useMaterial3: true, fontFamily: 'Malgun Gothic'),
          home: Scaffold(
            body: SettingsShell(
              selected: SettingsSection.workflow,
              onSelected: (_) {},
              contentOnly: true,
              contentBuilder: (_) => const Text('단계 목록'),
              workflowStages: stages,
              workflowRoles: roles,
              workflowPeople: people,
              workflowParts: parts,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final card = find.byKey(const Key('workflow-sheet-todo-card'));
  final viewport = find.byKey(const Key('workflow-sheet-viewport'));

  Future<void> menuPreview(WidgetTester tester, String name) async {
    if (!const bool.fromEnvironment('IEUM_UI_PREVIEW') ||
        !savedMenuPreviews.add(name)) {
      return;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const Key('workflow-menu-preview-root')),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../.local/workflow-$name-menu.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> connectFrom(WidgetTester tester, String id) async {
    await tester.tap(
      find.byKey(Key('workflow-sheet-$id-card')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workflow-sheet-connect-menu')),
      findsOneWidget,
    );
    expect(find.text('단계 불러오기'), findsNothing);
    final menuBounds = tester.getRect(
      find.byKey(const Key('workflow-sheet-connect-menu')),
    );
    final boardBounds = tester.getRect(viewport);
    expect(menuBounds.left, greaterThanOrEqualTo(boardBounds.left));
    expect(menuBounds.right, lessThanOrEqualTo(boardBounds.right));
    await menuPreview(tester, 'card');
    await tester.tap(find.byKey(const Key('workflow-sheet-connect-menu')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workflow-sheet-connect-mode')),
      findsOneWidget,
    );
  }

  Future<void> wheel(WidgetTester tester, Offset position, double dy) async {
    await tester.sendEventToBinding(
      PointerScrollEvent(position: position, scrollDelta: Offset(0, dy)),
    );
    await tester.pump();
  }

  Future<void> importAt(
    WidgetTester tester,
    Offset position,
    String stageId,
  ) async {
    await tester.tapAt(position, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('단계 불러오기'), findsOneWidget);
    expect(find.byKey(const Key('workflow-sheet-connect-menu')), findsNothing);
    await menuPreview(tester, 'import');
    await tester.tap(find.byKey(Key('workflow-sheet-import-$stageId')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'role handoffs filter recipients, add separate routes and remove only one route',
    (tester) async {
      const roles = [
        ProjectRole('role-plan', '기획', {'task.work'}),
        ProjectRole('role-review', 'QA', {'task.review'}),
        ProjectRole('role-art', '아트', {}),
      ];
      final people = [
        const Person(
          'planner',
          '기획자',
          '기',
          'role-plan',
          0,
          parts: ['기획'],
        ).resolved(roles),
        const Person(
          'reviewer',
          '검토자',
          '검',
          'role-review',
          0,
          parts: ['QA'],
        ).resolved(roles),
        const Person('inactive', '중지된 작업자', '중', 'worker', 0, enabled: false),
      ];
      await openSheet(
        tester,
        roles: roles,
        people: people,
        parts: ['기획', 'QA', '아트'],
      );
      await connectFrom(tester, 'doing');
      await tester.tap(find.byKey(const Key('workflow-sheet-review-card')));
      await tester.pumpAndSettle();
      final badge = find.byKey(
        const Key('workflow-sheet-route-doing-review-0'),
      );
      await tester.tap(badge);
      await tester.pumpAndSettle();
      Future<void> choose(int index, String label) async {
        final prefix = [
          'workflow-route-source-',
          'workflow-route-destination-',
        ][index];
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButtonFormField<String> &&
              widget.key.toString().contains(prefix),
        );
        await tester.ensureVisible(field);
        await tester.tap(field);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await choose(0, '파트 · 기획');
      await choose(1, '파트 · QA');
      final personField = find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.key.toString().contains('workflow-route-person-'),
      );
      await tester.ensureVisible(personField);
      await tester.tap(personField);
      await tester.pumpAndSettle();
      expect(find.text('검토자'), findsOneWidget);
      expect(find.text('기획자'), findsNothing);
      expect(find.text('중지된 작업자'), findsNothing);
      await tester.tap(find.text('검토자'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      expect(find.text('파트 · 기획\n→ 검토자'), findsOneWidget);
      expect(
        tester.getRect(badge).bottom,
        lessThan(
          tester
              .getRect(find.byKey(const Key('workflow-sheet-doing-card')))
              .top,
        ),
      );
      await tester.tap(badge);
      await tester.pumpAndSettle();
      await choose(1, '파트 · 아트');
      final recipient = tester.widget<DropdownButtonFormField<String>>(
        personField,
      );
      expect(recipient.initialValue, '');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(find.text('파트 · 기획\n→ 검토자'), findsOneWidget);
      await tester.tap(badge);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('workflow-route-add')));
      await tester.tap(find.byKey(const Key('workflow-route-add')));
      await tester.pumpAndSettle();
      await choose(0, '파트 · 기획');
      await choose(1, '파트 · QA');
      await tester.tap(find.byKey(const Key('workflow-route-save')));
      await tester.pumpAndSettle();
      final second = find.byKey(
        const Key('workflow-sheet-route-doing-review-1'),
      );
      expect(second, findsOneWidget);
      expect(find.text('파트 · 기획\n→ 파트 · QA 전체'), findsOneWidget);
      await menuPreview(tester, 'multiple-routes');
      await tester.tap(second);
      await tester.pumpAndSettle();
      final selected = tester.widget<ListTile>(
        find.byKey(const Key('workflow-route-option-1')),
      );
      expect(selected.selected, isTrue);
      await menuPreview(tester, 'route-editor');
      await tester.tap(find.byKey(const Key('workflow-route-delete')));
      await tester.pumpAndSettle();
      expect(second, findsNothing);
      expect(find.text('파트 · 기획\n→ 검토자'), findsOneWidget);
      expect(
        find.byKey(const Key('workflow-sheet-link-doing-review')),
        findsOneWidget,
      );
      await menuPreview(tester, 'routes');
      for (var i = 0; i < 6; i++) {
        await tester.tap(find.byKey(const Key('workflow-sheet-zoom-in')));
        await tester.pumpAndSettle();
      }
      expect(
        tester.getRect(badge).bottom,
        lessThan(
          tester
              .getRect(find.byKey(const Key('workflow-sheet-doing-card')))
              .top,
        ),
      );
      await tester.tap(find.byKey(const Key('workflow-sheet-fit')));
      await tester.pumpAndSettle();
      await tester.tap(badge);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-route-delete')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-link-doing-review')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('compact sheet keeps the fit control visible without overflow', (
    tester,
  ) async {
    await openSheet(tester);
    tester.view.physicalSize = const Size(320, 600);
    await tester.pumpAndSettle();
    final area = tester.getRect(viewport);
    final fit = find.byKey(const Key('workflow-sheet-fit'));
    expect(area.contains(tester.getCenter(fit)), isTrue);
    await tester.tap(fit);
    await tester.pumpAndSettle();
    for (final id in ['todo', 'doing', 'review', 'done']) {
      final rect = tester.getRect(find.byKey(Key('workflow-sheet-$id-card')));
      expect(area.contains(rect.topLeft), isTrue);
      expect(area.contains(rect.bottomRight), isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'zoom controls and fit view recover the cards without changing links',
    (tester) async {
      await openSheet(tester);
      for (final (from, to) in [
        ('todo', 'doing'),
        ('doing', 'review'),
        ('review', 'done'),
      ]) {
        await connectFrom(tester, from);
        await tester.tap(find.byKey(Key('workflow-sheet-$to-card')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('workflow-sheet-zoom-in')));
      await tester.pumpAndSettle();
      expect(tester.getRect(card).width, greaterThan(120));
      await tester.tap(find.byKey(const Key('workflow-sheet-zoom-out')));
      await tester.pumpAndSettle();
      expect(tester.getRect(card).width, closeTo(120, 0.01));
      final pan = await tester.startGesture(
        tester.getRect(viewport).topLeft + const Offset(40, 80),
        kind: PointerDeviceKind.mouse,
      );
      await pan.moveBy(const Offset(480, -180));
      await tester.pump();
      await pan.up();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('workflow-sheet-fit')));
      await tester.pumpAndSettle();
      final area = tester.getRect(viewport);
      for (final id in ['todo', 'doing', 'review', 'done']) {
        final rect = tester.getRect(find.byKey(Key('workflow-sheet-$id-card')));
        expect(area.contains(rect.topLeft), isTrue);
        expect(area.contains(rect.bottomRight), isTrue);
      }
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is WorkflowSheetLinkPainter,
        ),
        findsNWidgets(3),
      );
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('IEUM_UI_PREVIEW')) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('workflow-sheet-render-boundary')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../.local/workflow-sheet-polish.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );

  testWidgets(
    'deleting a card removes its links but preserves other cards and the catalog',
    (tester) async {
      await openSheet(tester);
      final firstPosition =
          tester.getRect(viewport).topLeft + const Offset(150, 140);
      await importAt(tester, firstPosition, 'doing');
      await importAt(tester, firstPosition + const Offset(220, 0), 'doing');
      await connectFrom(tester, 'todo');
      await tester.tap(
        find.byKey(const Key('workflow-sheet-doing-copy-1-card')),
      );
      await tester.pumpAndSettle();
      await connectFrom(tester, 'doing-copy-1');
      await tester.tap(find.byKey(const Key('workflow-sheet-done-card')));
      await tester.pumpAndSettle();
      await connectFrom(tester, 'review');
      await tester.tap(find.byKey(const Key('workflow-sheet-done-card')));
      await tester.pumpAndSettle();
      final others = [
        for (final id in ['todo', 'doing', 'review', 'done', 'doing-copy-2'])
          find.byKey(Key('workflow-sheet-$id-card')),
      ];
      final positions = [for (final finder in others) tester.getCenter(finder)];
      Future<void> remove(String id) async {
        await tester.tap(
          find.byKey(Key('workflow-sheet-$id-card')),
          buttons: kSecondaryButton,
        );
        await tester.pumpAndSettle();
        expect(find.text('단계 불러오기'), findsNothing);
        await tester.tap(find.byKey(const Key('workflow-sheet-delete-menu')));
        await tester.pumpAndSettle();
      }

      await remove('doing-copy-1');
      expect(
        find.byKey(const Key('workflow-sheet-doing-copy-1-card')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workflow-sheet-link-todo-doing-copy-1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workflow-sheet-link-doing-copy-1-done')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workflow-sheet-link-review-done')),
        findsOneWidget,
      );
      for (var i = 0; i < others.length; i++) {
        expect(tester.getCenter(others[i]), positions[i]);
      }
      await importAt(tester, firstPosition, 'doing');
      expect(
        find.byKey(const Key('workflow-sheet-doing-copy-3-card')),
        findsOneWidget,
      );
      await connectFrom(tester, 'todo');
      await remove('todo');
      expect(card, findsNothing);
      expect(
        find.byKey(const Key('workflow-sheet-connect-mode')),
        findsNothing,
      );
      for (var i = 1; i < others.length; i++) {
        expect(tester.getCenter(others[i]), positions[i]);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'registered custom stages import at the clicked position after pan and zoom',
    (tester) async {
      await openSheet(
        tester,
        stages: [
          ...legacyWorkflowStages,
          const WorkflowStage('stage-qa', '품질 확인'),
        ],
      );
      final pan = await tester.startGesture(
        tester.getRect(viewport).topLeft + const Offset(40, 80),
        kind: PointerDeviceKind.mouse,
      );
      await pan.moveBy(const Offset(20, 30));
      await tester.pump();
      await pan.up();
      await tester.pumpAndSettle();
      await wheel(tester, tester.getRect(viewport).center, -60);
      final original = tester.getCenter(card);
      final position =
          tester.getRect(viewport).topLeft + const Offset(150, 180);
      await importAt(tester, position, 'stage-qa');
      final imported = find.byKey(
        const Key('workflow-sheet-stage-qa-copy-1-card'),
      );
      expect((tester.getCenter(imported) - position).distance, lessThan(0.01));
      expect(tester.getCenter(card), original);
      expect(find.text('품질 확인'), findsOneWidget);
      await connectFrom(tester, 'stage-qa-copy-1');
      await tester.tap(find.byKey(const Key('workflow-sheet-doing-card')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-link-stage-qa-copy-1-doing')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('repeated imports make independent draggable connectable cards', (
    tester,
  ) async {
    await openSheet(tester);
    final firstPosition =
        tester.getRect(viewport).topLeft + const Offset(150, 140);
    final secondPosition = firstPosition + const Offset(220, 0);
    await importAt(tester, firstPosition, 'doing');
    await importAt(tester, secondPosition, 'doing');
    final first = find.byKey(const Key('workflow-sheet-doing-copy-1-card'));
    final second = find.byKey(const Key('workflow-sheet-doing-copy-2-card'));
    final original = tester.getCenter(
      find.byKey(const Key('workflow-sheet-doing-card')),
    );
    final drag = await tester.startGesture(
      tester.getCenter(first),
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(40, 70));
    await tester.pump();
    await drag.up();
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(first) - firstPosition - const Offset(40, 70)).distance,
      lessThan(0.01),
    );
    expect(tester.getCenter(second), secondPosition);
    expect(
      tester.getCenter(find.byKey(const Key('workflow-sheet-doing-card'))),
      original,
    );
    await connectFrom(tester, 'doing-copy-1');
    await tester.tap(second);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workflow-sheet-link-doing-copy-1-doing-copy-2')),
      findsOneWidget,
    );
    await connectFrom(tester, 'doing-copy-1');
    await tester.tap(find.byKey(const Key('workflow-sheet-review-card')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('workflow-sheet-link-doing-copy-1-review')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'catalog rename and deletion update placed cards and their connections',
    (tester) async {
      await openSheet(
        tester,
        stages: [
          ...legacyWorkflowStages,
          const WorkflowStage('stage-qa', '품질 확인'),
        ],
      );
      final position =
          tester.getRect(viewport).topLeft + const Offset(160, 140);
      await importAt(tester, position, 'stage-qa');
      await connectFrom(tester, 'todo');
      await tester.tap(
        find.byKey(const Key('workflow-sheet-stage-qa-copy-1-card')),
      );
      await tester.pumpAndSettle();
      final line = find.byKey(
        const Key('workflow-sheet-link-todo-stage-qa-copy-1'),
      );
      expect(line, findsOneWidget);
      await openSheet(
        tester,
        stages: [
          ...legacyWorkflowStages,
          const WorkflowStage('stage-qa', '품질 승인'),
        ],
      );
      expect(find.text('품질 승인'), findsOneWidget);
      expect(find.text('품질 확인'), findsNothing);
      expect(line, findsOneWidget);
      await openSheet(tester);
      expect(
        find.byKey(const Key('workflow-sheet-stage-qa-copy-1-card')),
        findsNothing,
      );
      expect(line, findsNothing);
      await tester.tapAt(position, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-import-stage-qa')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workflow-sheet-import-todo')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'right click connection mode makes directed and self links without duplicate geometry',
    (tester) async {
      await openSheet(tester);
      await connectFrom(tester, 'todo');
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-link-todo-todo')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workflow-sheet-connect-mode')),
        findsNothing,
      );
      await connectFrom(tester, 'todo');
      await tester.tap(find.byKey(const Key('workflow-sheet-doing-card')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-link-todo-doing')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('workflow-sheet-link-doing-todo')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('workflow-sheet-connect-mode')),
        findsNothing,
      );
      await connectFrom(tester, 'todo');
      await tester.tap(find.byKey(const Key('workflow-sheet-doing-card')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-link-todo-doing')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty space and Escape cancel connection without creating links',
    (tester) async {
      await openSheet(tester);
      await connectFrom(tester, 'review');
      await tester.tapAt(
        tester.getRect(viewport).topLeft + const Offset(40, 80),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-connect-mode')),
        findsNothing,
      );
      await connectFrom(tester, 'done');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('workflow-sheet-connect-mode')),
        findsNothing,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint &&
              widget.painter is WorkflowSheetLinkPainter,
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'connection endpoints follow both cards through dragging pan and zoom',
    (tester) async {
      await openSheet(tester);
      await connectFrom(tester, 'todo');
      final target = find.byKey(const Key('workflow-sheet-doing-card'));
      await tester.tap(target);
      await tester.pumpAndSettle();
      final line = find.byKey(const Key('workflow-sheet-link-todo-doing'));
      void expectAttached() {
        final painter =
            tester.widget<CustomPaint>(line).painter
                as WorkflowSheetLinkPainter;
        expect(
          (painter.from.center +
                  tester.getTopLeft(viewport) -
                  tester.getCenter(card))
              .distance,
          lessThan(0.01),
        );
        expect(
          (painter.to.center +
                  tester.getTopLeft(viewport) -
                  tester.getCenter(target))
              .distance,
          lessThan(0.01),
        );
        expect(painter.from.width, closeTo(tester.getRect(card).width, 0.01));
      }

      expectAttached();
      final drag = await tester.startGesture(
        tester.getCenter(card),
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveBy(const Offset(80, 80));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expectAttached();
      final pan = await tester.startGesture(
        tester.getRect(viewport).topLeft + const Offset(40, 80),
        kind: PointerDeviceKind.mouse,
      );
      await pan.moveBy(const Offset(30, 20));
      await tester.pump();
      await pan.up();
      await tester.pumpAndSettle();
      await wheel(tester, tester.getRect(viewport).center, -60);
      expectAttached();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wheel zoom uses the sheet center regardless of the cursor position',
    (tester) async {
      await openSheet(tester);
      final original = tester.getRect(card);
      final left = tester.getRect(
        find.byKey(const Key('workflow-settings-left')),
      );
      final center = tester.getRect(viewport).center;
      final pointer = original.center + const Offset(90, 60);
      await wheel(tester, pointer, -120);
      final enlarged = tester.getRect(card);
      final factor = math.exp(120 / 300);
      expect(enlarged.width, closeTo(original.width * factor, 0.01));
      final expected = center + (original.center - center) * factor;
      expect((enlarged.center - expected).distance, lessThan(0.01));
      expect(
        tester.getRect(find.byKey(const Key('workflow-settings-left'))),
        left,
      );
      await wheel(tester, center - const Offset(80, 50), 120);
      expect(tester.getRect(card).width, closeTo(original.width, 0.01));
      expect(
        (tester.getCenter(card) - original.center).distance,
        lessThan(0.01),
      );
      // Wheel events over the left pane cannot zoom the sheet.
      await wheel(tester, left.center, -120);
      expect(tester.getRect(card).width, closeTo(original.width, 0.01));
    },
  );

  testWidgets('left mouse drag on empty space pans the sheet after zoom', (
    tester,
  ) async {
    await openSheet(tester);
    final center = tester.getRect(viewport).center;
    final cards = [
      for (final id in ['todo', 'doing', 'review', 'done'])
        find.byKey(Key('workflow-sheet-$id-card')),
    ];
    final start = tester.getRect(viewport).topLeft + const Offset(80, 80);
    await wheel(tester, start, -120);
    final positions = [for (final finder in cards) tester.getCenter(finder)];
    final left = tester.getRect(
      find.byKey(const Key('workflow-settings-left')),
    );
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    const movement = Offset(100, 50);
    await gesture.moveBy(movement);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    for (var i = 0; i < cards.length; i++) {
      expect(
        (tester.getCenter(cards[i]) - positions[i] - movement).distance,
        lessThan(0.01),
      );
    }
    expect(
      tester.getRect(find.byKey(const Key('workflow-settings-left'))),
      left,
    );
    // Further zoom is anchored to the viewport center even after panning.
    final before = tester.getCenter(card);
    await wheel(tester, start, -120);
    final expected = center + (before - center) * math.exp(120 / 300);
    expect((tester.getCenter(card) - expected).distance, lessThan(0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mouse dragging follows the pointer after zoom and stays on release',
    (tester) async {
      await openSheet(tester);
      final card = find.byKey(const Key('workflow-sheet-doing-card'));
      await wheel(tester, tester.getCenter(card), -160);
      final initial = tester.getCenter(card);
      final others = [
        for (final id in ['todo', 'review', 'done'])
          find.byKey(Key('workflow-sheet-$id-card')),
      ];
      final originalOthers = [
        for (final finder in others) tester.getCenter(finder),
      ];
      final gesture = await tester.startGesture(
        initial,
        kind: PointerDeviceKind.mouse,
      );
      const movement = Offset(110, 65);
      await gesture.moveBy(movement);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        (tester.getCenter(card) - initial - movement).distance,
        lessThan(0.01),
      );
      final dropped = tester.getCenter(card);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getCenter(card), dropped);
      for (var i = 0; i < others.length; i++) {
        expect(tester.getCenter(others[i]), originalOthers[i]);
      }
      // Dragging also works when the card has been zoomed out.
      await wheel(tester, dropped, 10000);
      expect(tester.getRect(card).width, closeTo(48, 0.01));
      final small = tester.getCenter(card);
      final second = await tester.startGesture(
        small,
        kind: PointerDeviceKind.mouse,
      );
      await second.moveBy(const Offset(-80, -40));
      await tester.pump();
      await second.up();
      await tester.pumpAndSettle();
      expect(
        (tester.getCenter(card) - small - const Offset(-80, -40)).distance,
        lessThan(0.01),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
