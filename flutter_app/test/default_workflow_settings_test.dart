import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/github_oauth.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/project_service.dart';

import 'github_oauth_test.dart' show MemoryVault;
import 'github_sync_test.dart' show FakeGitHubApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = GitHubConfig(repository: 'team/data', enabled: true);
  late FakeGitHubApi api;
  late GitHubSession session;
  setUp(() async {
    api = FakeGitHubApi();
    session = GitHubSession(
      api: api,
      oauth: GitHubOAuth(vault: MemoryVault()),
    );
    await session.signIn();
  });
  tearDown(() => session.signOut());

  test(
    'new project persists three statuses with delivery and return actions',
    () async {
      final created = await session.createProject(config, '기본 프로젝트', '개설자');
      final loaded = await session.loadProject(config);
      expect(loaded.id, created.id);
      expect(loaded.workflowStages.map((s) => s.name), ['확인중', '진행중', '완료']);
      final sheet = loaded.workflowSheet!;
      expect(
        sheet.routes.map(
          (r) => '${sheet.stageFor(r.from)!}>${sheet.stageFor(r.to)!}',
        ),
        ['todo>doing', 'doing>doing', 'doing>done', 'doing>doing'],
      );
      expect(
        sheet.routes.every(
          (r) => r.source.isEmpty && r.destination.isEmpty && r.person.isEmpty,
        ),
        isTrue,
      );
      expect(sheet.routes.singleWhere((r) => r.action == 'reject').to, 'doing');
      expect(
        sheet.routes
            .singleWhere((r) => r.effectiveOperation == 'start')
            .assignment,
        'keep',
      );
      final handoff = sheet.routes.singleWhere(
        (r) => r.effectiveOperation == 'handoff',
      );
      expect(handoff.assignment, 'select');
      expect(handoff.purpose, 'review');
      final returned = sheet.routes.singleWhere((r) => r.action == 'reject');
      expect(returned.assignment, 'sender');
      expect(returned.purpose, 'revision');
      expect(returned.requiredPurpose, 'review');
      expect(loaded.usesManualWorkflow, isFalse);
    },
  );

  test('saving a generated default sheet atomically applies the configured catalogue without renaming stages', () async {
    final created = await session.createProject(config, '기본 복원', '개설자');
    final custom = await session.saveWorkflowStages(
      config,
      const [
        WorkflowStage('todo', '접수'),
        WorkflowStage('stage-design', '디자인'),
        WorkflowStage('doing', '제작'),
        WorkflowStage('review', '품질 검토'),
        WorkflowStage('done', '완성'),
      ],
      expectedProjectId: created.id,
      expectedStages: created.workflowStages,
    );
    final generated = WorkflowSheet.defaultFor(
      custom.workflowStages.map((s) => s.id).toList(),
    );
    final writes = api.writes;
    final applied = await session.saveWorkflowSheet(
      config,
      generated,
      expectedProjectId: custom.id,
      expectedSheet: custom.workflowSheet,
    );
    expect(api.writes, writes + 1);
    expect(applied.workflowStages.map((s) => s.name), [
      '접수',
      '디자인',
      '제작',
      '품질 검토',
      '완성',
    ]);
    expect(
      applied.workflowSheet!.stageFor(
        applied.workflowSheet!.outgoing('stage-design').single.to,
      ),
      'doing',
    );
    expect(
      applied.workflowSheet!.stageFor(
        applied.workflowSheet!.outgoing('doing').single.to,
      ),
      'review',
    );
    expect(applied.workflowSheet!.json, generated.json);
    expect(
      jsonEncode((await session.loadProject(config)).json),
      jsonEncode(applied.json),
    );
  });

  test('same display name never replaces a custom stage or the review stage identity', () async {
    final created = await session.createProject(config, '단계 이름', '개설자');
    final stages = await session.saveWorkflowStages(
      config,
      const [
        WorkflowStage('todo', '확인'),
        WorkflowStage('doing', '진행'),
        WorkflowStage('stage-custom-review', '검토'),
        WorkflowStage('review', '검토 (승인)'),
        WorkflowStage('done', '완료'),
      ],
      expectedProjectId: created.id,
      expectedStages: created.workflowStages,
    );
    final applied = await session.saveWorkflowSheet(
      config,
      WorkflowSheet.defaultFor(stages.workflowStages.map((s) => s.id).toList()),
      expectedProjectId: stages.id,
      expectedSheet: stages.workflowSheet,
    );
    expect(
      applied.workflowStages
          .singleWhere((s) => s.id == 'stage-custom-review')
          .name,
      '검토',
    );
    expect(
      applied.workflowStages.singleWhere((s) => s.id == 'review').name,
      '검토 (승인)',
    );
    final approval = applied.workflowSheet!.routes.singleWhere(
      (r) => r.action == 'approve',
    );
    expect(applied.workflowSheet!.stageFor(approval.from), 'review');
    expect(applied.workflowSheet!.stageFor(approval.to), 'done');
  });

  test('saving defaults refuses a stale graph snapshot and keeps the latest routes', () async {
    final created = await session.createProject(config, '동시 수정', '개설자');
    final base = created.workflowSheet!;
    final changed = WorkflowSheet(
      nodes: base.nodes,
      routes: [
        for (final r in base.routes)
          WorkflowSheetRoute(
            id: r.id,
            from: r.from,
            to: r.to,
            action: r.action,
            source: r.source,
            destination: r.id == 'default-next-0'
                ? 'role:owner'
                : r.destination,
          ),
      ],
    );
    final current = await session.saveWorkflowSheet(
      config,
      changed,
      expectedProjectId: created.id,
      expectedSheet: base,
    );
    final writes = api.writes;
    await expectLater(
      session.saveWorkflowSheet(
        config,
        base,
        expectedProjectId: created.id,
        expectedSheet: base,
      ),
      throwsA(isA<GitHubFailure>()),
    );
    expect(api.writes, writes);
    expect(
      (await session.loadProject(config)).workflowSheet!.json,
      current.workflowSheet!.json,
    );
  });
}
