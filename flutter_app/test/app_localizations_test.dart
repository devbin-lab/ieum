import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app_localizations.dart';
import 'package:ieum_flutter/project_timeline_view.dart';

void main() {
  setUp(() => setAppLanguage('ko'));
  tearDown(() => setAppLanguage('ko'));

  test('locale changes translate copy and preserve interpolation values', () {
    expect(tr('새 작업'), '새 작업');
    expect(tr('안 읽음 {count}개', args: {'count': 3}), '안 읽음 3개');
    setAppLanguage('en');
    expect(tr('새 작업'), 'New task');
    expect(tr('안 읽음 {count}개', args: {'count': 3}), '3 unread');
    expect(tr('담당자 · {name}', args: {'name': '기획팀 김민수'}), 'Assignee · 기획팀 김민수');
    expect(tr('안 읽음 3개'), '3 unread');
    expect(trError(StateError('프로젝트가 변경되었습니다.')), 'The project has changed.');
    expect(tr('unknown text'), 'unknown text');
    setAppLanguage('unsupported');
    expect(appLanguage, 'ko');
  });

  test('system stage labels localize while custom stage names stay intact', () {
    setAppLanguage('en');
    expect(trStageName('todo', '확인중'), 'To do');
    expect(trStageName('doing', '진행중'), 'In progress');
    expect(trStageName('stage-custom', '확인중'), '확인중');
    expect(trStageName('todo', '기획 확인'), '기획 확인');
    expect(trRoleName('owner', '관리자'), 'Administrator');
    expect(trRoleName('role-custom', '관리자'), '관리자');
    expect(translatedLabels({'normal': '보통'})['normal'], 'Normal');
  });

  testWidgets('timeline English labels preserve Korean task data', (
    tester,
  ) async {
    setAppLanguage('en');
    final records = <Map<String, dynamic>>[
      {
        'id': 'created-1',
        'kind': 'created',
        'createdAt': '2026-10-08T00:00:00Z',
        'taskId': 'TASK-1',
        'taskTitle': '새 작업',
        'actorName': '김민수',
        'message': '작업을 등록했습니다.',
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectTimelineView(
            projectName: '기획 프로젝트',
            activityHistory: records,
            onRefresh: () {},
            onOpenTask: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Timeline'), findsOneWidget);
    expect(find.text('새 작업'), findsOneWidget);
    expect(find.text('김민수'), findsOneWidget);
    expect(find.text('Open task'), findsOneWidget);
    expect(records.single['taskTitle'], '새 작업');
    expect(records.single['message'], '작업을 등록했습니다.');
    expect(tester.takeException(), isNull);
  });
}
