import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/project_timeline_view.dart';

void main() {
  testWidgets(
    'timeline sorts, searches and opens tasks without changing records',
    (tester) async {
      final history = [
        {
          'id': 'old',
          'taskId': 'task-a',
          'taskTitle': '기획서 초안',
          'kind': 'created',
          'actorName': '작성자',
          'message': '작업을 등록했습니다.',
          'createdAt': '2026-10-08T00:00:00Z',
        },
        {
          'id': 'new',
          'taskId': 'task-b',
          'taskTitle': '출시 검토',
          'kind': 'comment',
          'actorName': '검토자',
          'message': '완료 기준을 확인했습니다.',
          'createdAt': '2026-10-08T01:00:00Z',
        },
      ];
      final original = jsonEncode(history);
      Map<String, dynamic>? opened;
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProjectTimelineView(
              projectName: 'Test',
              activityHistory: history,
              onRefresh: () => refreshes++,
              onOpenTask: (event) => opened = event,
            ),
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text('출시 검토')).dy,
        lessThan(tester.getTopLeft(find.text('기획서 초안')).dy),
      );
      await tester.tap(find.byKey(const Key('project-timeline-open-new')));
      expect(opened?['taskId'], 'task-b');
      await tester.enterText(find.byType(TextField), '검토자');
      await tester.pump();
      expect(find.text('출시 검토'), findsOneWidget);
      expect(find.text('기획서 초안'), findsNothing);
      await tester.tap(find.byKey(const Key('project-timeline-refresh')));
      expect(refreshes, 1);
      expect(jsonEncode(history), original);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('timeline fits narrow widths with long text and empty results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectTimelineView(
            projectName: '긴 프로젝트 이름도 자연스럽게 표시됩니다',
            activityHistory: const [
              {
                'id': 'long',
                'taskId': 'task-a',
                'taskTitle': '일정과작업을관리하는매우긴작업제목입니다',
                'kind': 'transition',
                'actorName': '매우 긴 이름을 가진 담당자',
                'message': '담당자를 변경하고 작업을 검토중으로 옮겼습니다.',
                'createdAt': '2026-10-08T00:00:00Z',
              },
            ],
            onRefresh: () {},
            onOpenTask: (_) {},
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), '없는 내용');
    await tester.pump();
    expect(find.text('검색 결과가 없습니다.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
