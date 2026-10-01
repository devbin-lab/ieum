import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_catalog.dart';
import 'package:ieum_flutter/project_picker.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'project menu, offline notice and restored kanban fit minimum window',
    (tester) async {
      final seed =
          jsonDecode(
                File('assets/demo-snapshot.json').readAsStringSync(),
              )['tasks']
              as List;
      final store = TaskStore(':memory:', seed: seed);
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(1160, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('window_manager'),
            (call) async => call.method == 'isMaximized' ? false : null,
          );
      if (Platform.environment['IEUM_CAPTURE_UI'] == '1') {
        final font = FontLoader('Malgun Gothic')
          ..addFont(
            Future.value(
              ByteData.sublistView(
                File('C:/Windows/Fonts/malgun.ttf').readAsBytesSync(),
              ),
            ),
          );
        await tester.runAsync(font.load);
      }
      final projects = [
        SavedProject(
          path: 'a.sqlite',
          name: '호환 · 졸업작품',
          projectId: 'a',
          config: const GitHubConfig(repository: 'team/hwan'),
        ),
        SavedProject(
          path: 'b.sqlite',
          name: '이음 서비스',
          projectId: 'b',
          config: const GitHubConfig(repository: 'team/ieum'),
        ),
      ];
      var selected = '', created = false;
      final boundary = GlobalKey();
      Widget app() => RepaintBoundary(
        key: boundary,
        child: IeumApp(
          store: store,
          home: Workspace(
            store: store,
            sessionNotice:
                '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 계정을 다시 확인하고 변경을 전송합니다.',
            projectSwitcher: ProjectPicker(
              projects: projects,
              activePath: 'a.sqlite',
              onSelected: (p) => selected = p.projectId,
              onCreate: () => created = true,
              onJoin: () {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-kanban')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-IE-101')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      expect(find.text('새 프로젝트 만들기'), findsOneWidget);
      expect(find.text('프로젝트 참여하기'), findsOneWidget);
      if (Platform.environment['IEUM_CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('../.local/qa/v020-workspace.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.byKey(const ValueKey('project-option-b.sqlite')));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      await tester.tap(find.byKey(const Key('project-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('project-create-menu')));
      await tester.pumpAndSettle();
      expect(created, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
