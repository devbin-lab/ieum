import 'app_localizations.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'popup_ui.dart';
import 'sync_recovery_ui.dart';
import 'workspace_ui.dart';

class GitHubPanel extends StatelessWidget {
  const GitHubPanel({super.key, required this.sync});
  final GitHubSync sync;

  Future<void> resolve(BuildContext context, String taskId) async {
    final task = sync.store.find(taskId);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: Text(tr('저장소 버전 적용')),
        icon: Icons.restore_outlined,
        content: Text(
          tr(
            '“{v0}”의 내 변경을 백업한 뒤 저장소의 최신 버전을 적용합니다. 이 작업에 제출된 변경 요청은 닫힙니다.',
            args: {'v0': task.title},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('백업 후 적용')),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      await sync.acceptRemote(taskId, expectedVersion: task.version);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('내 변경을 백업하고 저장소의 최신 버전을 적용했습니다.'))),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trError(e))));
      }
    }
  }

  Future<void> configure(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => GitHubConfigDialog(sync: sync),
  );
  Future<void> review(BuildContext context, String url) async {
    try {
      final config = sync.config;
      final data = await sync.publisher.review(config, url);
      if (!context.mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => IeumDialog(
          title: Text(data['title'] as String),
          icon: Icons.rule_outlined,
          width: 700,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr('변경 사항을 확인한 뒤 프로젝트에 반영할 수 있습니다.'),
                style: TextStyle(
                  fontSize: 12,
                  color: WorkspaceUi.colors(context).muted,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                tr('커밋 {v0}', args: {'v0': data['sha']}),
                style: TextStyle(
                  fontSize: 10,
                  color: WorkspaceUi.colors(context).muted,
                ),
              ),
              for (final file in data['files'] as List) ...[
                const SizedBox(height: 16),
                Text(
                  file['filename'] as String,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: WorkspaceUi.colors(context).subtle,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    file['patch'] as String,
                    style: const TextStyle(fontSize: 11, height: 1.5),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('통합 승인')),
            ),
          ],
        ),
      );
      if (accepted != true || !context.mounted) return;
      if (sync.config.slug != config.slug || sync.config.base != config.base) {
        throw GitHubFailure(tr('검토 중 연결 설정이 변경되었습니다. 다시 확인하세요.'));
      }
      await sync.approve(data);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trError(e))));
      }
    }
  }

  Future<void> enable(BuildContext context) async {
    try {
      await sync.connect(
        GitHubConfig.fromJson({...sync.config.toJson(), 'enabled': true}),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trError(error))));
      }
    }
  }

  Widget property(BuildContext context, String title, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(title, style: WorkspaceUi.captionStyleOf(context)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 12,
              color: WorkspaceUi.colors(context).ink,
            ),
          ),
        ),
      ],
    ),
  );

  Widget jobRow(BuildContext context, Map<String, dynamic> job) {
    final state = job['state'];
    final label = switch (state) {
      'pending' => tr('전송 대기'),
      'sending' => tr('전송 중'),
      'sent' =>
        sync.autoMergeEnabled ? tr('전송 완료 · 자동 반영 대기') : tr('전송 완료 · 승인 대기'),
      'merged' => tr('프로젝트에 반영됨'),
      _ => tr('전송 실패 · 재시도 대기'),
    };
    final failed = (job['error'] as String? ?? '').isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              failed
                  ? Icons.error_outline_rounded
                  : state == 'merged'
                  ? Icons.check_circle_outline_rounded
                  : Icons.sync_rounded,
              size: 18,
              color: failed
                  ? WorkspaceUi.colors(context).danger
                  : WorkspaceUi.colors(context).muted,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  job['title'] as String,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(label, style: WorkspaceUi.captionStyleOf(context)),
                if (failed) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    job['error'] as String,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xffb34b51),
                    ),
                  ),
                ],
                if (job['prUrl'] != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    job['prUrl'] as String,
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([sync, sync.store]),
    builder: (context, _) {
      final config = sync.config;
      final busy = sync.busy || sync.pulling;
      final savedConflicts = sync.store.meta('github.pullConflicts');
      final conflicts = savedConflicts.isEmpty
          ? <dynamic>[]
          : jsonDecode(savedConflicts) as List;
      final jobs = sync.jobs.take(20).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WorkspacePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WorkspaceSectionLabel(
                  title: tr('저장소 연결'),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: config.enabled
                          ? const Color(0xffedf6ef)
                          : WorkspaceUi.colors(context).subtle,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      busy
                          ? tr('동기화 중')
                          : config.enabled
                          ? tr('연결됨')
                          : tr('동기화 꺼짐'),
                      style: TextStyle(
                        fontSize: 11,
                        color: config.enabled
                            ? const Color(0xff417458)
                            : WorkspaceUi.colors(context).muted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                property(
                  context,
                  tr('저장소'),
                  config.slug.isEmpty ? tr('연결되지 않음') : config.slug,
                ),
                property(
                  context,
                  tr('기준 브랜치'),
                  config.base.isEmpty ? '—' : config.base,
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (config.enabled)
                      FilledButton.icon(
                        key: const Key('github-sync-now'),
                        onPressed: busy
                            ? null
                            : () => sync.cycle(retryFailed: true),
                        icon: const Icon(Icons.sync_rounded, size: 17),
                        label: Text(tr('지금 동기화')),
                      ),
                    SyncRecoveryHistoryButton(store: sync.store),
                    if (!sync.store.isProject)
                      OutlinedButton.icon(
                        key: const Key('github-configure'),
                        onPressed: busy ? null : () => configure(context),
                        icon: const Icon(Icons.settings_outlined, size: 17),
                        label: Text(
                          config.enabled ? tr('연결 설정') : tr('저장소 연결'),
                        ),
                      ),
                  ],
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 14),
                    child: LinearProgressIndicator(),
                  ),
                if (sync.pullMessage.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      sync.pullMessage,
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                  ),
                SyncRecoveryNotice(store: sync.store),
                if (sync.retryAt?.isAfter(DateTime.now()) == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      tr(
                        'GitHub 요청 제한 · {v0} 이후 재시도',
                        args: {
                          'v0': sync.retryAt!.toLocal().toString().substring(
                            11,
                            19,
                          ),
                        },
                      ),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xffbd9655),
                      ),
                    ),
                  ),
                Divider(height: 32, color: WorkspaceUi.colors(context).line),
                SwitchListTile(
                  key: const Key('github-auto-sync'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('자동 동기화'), style: TextStyle(fontSize: 12)),
                  subtitle: Text(
                    tr('저장한 변경을 전송하고 팀의 최신 작업을 가져옵니다.'),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                  value: config.enabled,
                  onChanged: busy
                      ? null
                      : (value) => value
                            ? sync.store.isProject
                                  ? enable(context)
                                  : configure(context)
                            : sync.disable(),
                ),
                if (sync.store.isProject) ...[
                  Divider(height: 16, color: WorkspaceUi.colors(context).line),
                  SwitchListTile(
                    key: const Key('github-auto-merge'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr('자동 통합'), style: TextStyle(fontSize: 12)),
                    subtitle: Text(
                      tr('충돌이 없는 변경 요청을 승인 없이 프로젝트에 반영합니다.'),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    value: sync.autoMergeEnabled,
                    onChanged: busy
                        ? null
                        : (value) => sync.setAutoMerge(value),
                  ),
                  if (sync.autoMergeMessage.isNotEmpty)
                    Text(
                      sync.autoMergeMessage,
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                ],
              ],
            ),
          ),
          if (conflicts.isNotEmpty) ...[
            const SizedBox(height: 20),
            WorkspacePanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  WorkspaceSectionLabel(title: tr('확인이 필요한 변경')),
                  for (final conflict in conflicts) ...[
                    const SizedBox(height: 16),
                    Text(
                      '${conflict['title']} · ${conflict['field']}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xffb34b51),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      tr(
                        '내 변경: {v0}\n저장소 변경: {v1}',
                        args: {
                          'v0': conflict['local'],
                          'v1': conflict['remote'],
                        },
                      ),
                      style: const TextStyle(fontSize: 11, height: 1.6),
                    ),
                    if (conflict['taskId'] is String)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => resolve(
                                  context,
                                  conflict['taskId'] as String,
                                ),
                          child: Text(tr('저장소 버전 적용')),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          WorkspacePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WorkspaceSectionLabel(
                  title: tr('최근 동기화'),
                  trailing: Text(
                    tr('{v0}건', args: {'v0': jobs.length}),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ),
                const SizedBox(height: 8),
                if (jobs.isEmpty)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      tr('아직 전송한 변경이 없습니다.'),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                  ),
                for (var i = 0; i < jobs.length && i < 5; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: WorkspaceUi.colors(context).line),
                  jobRow(context, Map<String, dynamic>.from(jobs[i])),
                ],
                if (jobs.length > 5)
                  ExpansionTile(
                    key: const Key('github-more-history'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: EdgeInsets.zero,
                    title: Text(
                      tr('이전 전송 내역 {v0}건', args: {'v0': jobs.length - 5}),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    children: [
                      for (final job in jobs.skip(5))
                        jobRow(context, Map<String, dynamic>.from(job)),
                    ],
                  ),
              ],
            ),
          ),
          if (sync.openRequests.isNotEmpty) ...[
            const SizedBox(height: 20),
            WorkspacePanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  WorkspaceSectionLabel(title: tr('승인 대기 중인 변경')),
                  for (final pr in sync.openRequests) ...[
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '#${pr['number']} ${pr['title']}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        if (!sync.store.isProject || sync.store.owns)
                          OutlinedButton(
                            onPressed: busy
                                ? null
                                : () =>
                                      review(context, pr['html_url'] as String),
                            child: Text(tr('변경 확인')),
                          ),
                      ],
                    ),
                    if (sync.autoMergeErrors[pr['html_url']] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '#${pr['number']} · ${sync.autoMergeErrors[pr['html_url']]}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xffb34b51),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}

class GitHubConfigDialog extends StatefulWidget {
  const GitHubConfigDialog({super.key, required this.sync});
  final GitHubSync sync;
  @override
  State<GitHubConfigDialog> createState() => _GitHubConfigDialogState();
}

class _GitHubConfigDialogState extends State<GitHubConfigDialog> {
  late final TextEditingController repository, base, branch;
  final token = TextEditingController();
  bool connecting = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    final config = widget.sync.config;
    repository = TextEditingController(text: config.repository);
    base = TextEditingController(text: config.base);
    branch = TextEditingController(text: config.branch);
  }

  @override
  void dispose() {
    for (final controller in [repository, base, branch, token]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> connect() async {
    setState(() {
      connecting = true;
      error = '';
    });
    try {
      await widget.sync.connect(
        GitHubConfig(
          repository: repository.text.trim(),
          base: base.text.trim(),
          branch: branch.text.trim(),
          enabled: true,
          separatePr: true,
          autoMerge: widget.sync.config.autoMerge,
        ),
        token: token.text,
      );
      token.clear();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          connecting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => IeumDialog(
    title: Text(tr('GitHub 저장소 연결')),
    icon: Icons.merge_outlined,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('프로젝트 작업을 함께 관리할 GitHub 저장소를 연결합니다.'),
          style: TextStyle(
            fontSize: 12,
            color: WorkspaceUi.colors(context).muted,
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          key: const Key('github-repository'),
          controller: repository,
          enabled: !connecting,
          decoration: InputDecoration(
            labelText: tr('저장소'),
            hintText: 'team/project-data',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: base,
          enabled: !connecting,
          decoration: InputDecoration(
            labelText: tr('기준 브랜치'),
            hintText: 'main',
          ),
        ),
        const SizedBox(height: 16),
        ExpansionTile(
          key: const Key('github-advanced-settings'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 12),
          initiallyExpanded: branch.text.isNotEmpty,
          title: Text(tr('고급 설정'), style: WorkspaceUi.sectionStyleOf(context)),
          children: [
            TextField(
              controller: branch,
              enabled: !connecting,
              decoration: InputDecoration(
                labelText: tr('작업 브랜치 접두사 (선택)'),
                hintText: tr('ieum/사용자 이름'),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('github-token'),
              controller: token,
              enabled: !connecting,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: tr('인증 토큰 (선택)'),
                hintText: tr('비워 두면 저장된 Git 인증 사용'),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              tr(
                '토큰은 앱을 종료하면 삭제됩니다. 저장소의 Contents 및 Pull requests 읽기·쓰기 권한이 필요합니다.',
              ),
              style: WorkspaceUi.captionStyleOf(context),
            ),
            const SizedBox(height: 12),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          tr('연결하면 자동 동기화가 켜집니다. 변경 사항이 충돌하면 내 작업을 보존하고 알려드립니다.'),
          style: WorkspaceUi.captionStyleOf(context),
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error,
              style: const TextStyle(fontSize: 11, color: Color(0xffbd6b7a)),
            ),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: connecting ? null : () => Navigator.pop(context),
        child: Text(tr('취소')),
      ),
      FilledButton(
        onPressed: connecting ? null : connect,
        child: Text(connecting ? tr('연결 중…') : tr('연결')),
      ),
    ],
  );
}
