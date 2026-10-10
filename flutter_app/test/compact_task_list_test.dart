import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/compact_task_list.dart';
import 'package:ieum_flutter/horizontal_viewport.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/workspace_ui.dart';

WorkTask task(int index, {String? title}) => WorkTask.fromJson({
  'id': 'task-$index',
  'title': title ?? '작업 $index',
  'part': '기획',
  'priority': 'normal',
  'assigneeId': 'gh-1',
  'reviewerId': 'gh-2',
  'status': 'doing',
  'assignedDate': '2026-10-10',
  'dueDate': '2026-10-20',
  'completedDate': '',
  'description': '본문',
  'reworkReason': '',
  'version': 1,
  'updatedAt': '2026-10-10T00:00:00Z',
});

CompactTaskPresentation presentation(WorkTask task) => CompactTaskPresentation(
  idLabel: 'IE-${task.id}',
  statusLabel: '진행중',
  statusColor: const Color(0xff2f6fda),
  assigneeLabel: 'devbin-lab',
  assigneeAvatar: const CircleAvatar(child: Text('D')),
  priorityLabel: '보통',
  priorityColor: WorkspaceUi.muted,
  dateLabel: '10.10 — 10.20',
  dateTooltip: '2026.10.10 — 2026.10.20',
  contextLabel: '기획 · 검토 요청',
);

Widget listApp(
  Widget list, {
  double width = 1100,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness),
  home: Scaffold(
    body: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: SingleChildScrollView(
        child: SizedBox(width: width, child: list),
      ),
    ),
  ),
);

void main() {
  testWidgets('forty rows stay compact and use the available table width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      listApp(
        CompactTaskList(
          tasks: [for (var i = 0; i < 40; i++) task(i)],
          presentationFor: presentation,
          onOpenTask: (_) {},
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(const Key('compact-task-header'))),
      const Size(1100, 38),
    );
    expect(
      tester.getSize(find.byKey(const Key('compact-task-row-task-0'))),
      const Size(1100, 54),
    );
    expect(tester.getSize(find.byType(CompactTaskList)).height, 38 + 40 * 54);
    expect(find.byType(DataTable), findsNothing);
    expect(find.byType(HorizontalViewport), findsNothing);
  });

  testWidgets('row keyboard activation and tool clicks are independent', (
    tester,
  ) async {
    var opened = 0;
    var pinned = 0;
    var actions = 0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      listApp(
        CompactTaskList(
          tasks: [task(1)],
          presentationFor: presentation,
          onOpenTask: (_) => opened++,
          pinButtonBuilder: (_) => IconButton(
            key: const Key('pin'),
            onPressed: () => pinned++,
            icon: const Icon(Icons.push_pin_outlined),
          ),
          actionsBuilder: (_) => IconButton(
            key: const Key('actions'),
            onPressed: () => actions++,
            icon: const Icon(Icons.more_horiz),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('pin')));
    await tester.tap(find.byKey(const Key('actions')));
    expect(pinned, 1);
    expect(actions, 1);
    expect(opened, 0);

    Focus.of(tester.element(find.byKey(const Key('compact-task-title-task-1'))))
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
    await tester.tap(find.byKey(const Key('compact-task-title-task-1')));
    expect(opened, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large text and long values scroll horizontally without overflow',
    (tester) async {
      final longTitle = List.filled(16, '긴 제목과 작업 내용 ').join();
      await tester.pumpWidget(
        listApp(
          CompactTaskList(
            tasks: [
              task(1, title: longTitle),
              task(2),
            ],
            presentationFor: (value) => CompactTaskPresentation(
              idLabel: 'ID-${List.filled(20, 'long').join()}',
              statusLabel: '매우 긴 사용자 지정 상태 이름',
              statusColor: Colors.blue,
              assigneeLabel: '매우 긴 이름을 사용하는 담당자 계정',
              assigneeAvatar: const CircleAvatar(child: Text('A')),
              priorityLabel: '보통 우선순위',
              priorityColor: Colors.grey,
              dateLabel: '2026.10.10 — 2026.10.20',
              contextLabel: '기획 · 검토 요청',
            ),
            onOpenTask: (_) {},
          ),
          width: 560,
          textScale: 1.4,
          brightness: Brightness.dark,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(HorizontalViewport), findsOneWidget);
      final title = tester.widget<Text>(
        find.byKey(const Key('compact-task-title-task-1')),
      );
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip && widget.message!.contains(longTitle.trim()),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const Key('compact-task-row-task-1'))).height,
        closeTo(62, .01),
      );
      await tester.drag(find.byType(HorizontalViewport), const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected row and caller keys remain available for navigation', (
    tester,
  ) async {
    final rowKey = GlobalKey();
    await tester.pumpWidget(
      listApp(
        CompactTaskList(
          tasks: [task(1), task(2)],
          presentationFor: presentation,
          onOpenTask: (_) {},
          selectedTaskId: 'task-2',
          rowKeyBuilder: (value) => value.id == 'task-2'
              ? rowKey
              : ValueKey('compact-task-row-${value.id}'),
        ),
        width: 700,
      ),
    );
    expect(rowKey.currentContext, isNotNull);
    Material rowMaterial(Finder row) => tester.widget<Material>(
      find.ancestor(of: row, matching: find.byType(Material)).first,
    );
    expect(
      rowMaterial(find.byKey(rowKey)).color,
      isNot(
        rowMaterial(find.byKey(const Key('compact-task-row-task-1'))).color,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
