import 'dart:convert';

import 'package:flutter/material.dart';

import 'github_sync.dart';
import 'popup_ui.dart';

const _purple = Color(0xff7963d5),
    _muted = Color(0xff9990a5),
    _border = Color(0xffe9e5ef);

class GitHubPanel extends StatelessWidget {
  const GitHubPanel({super.key, required this.sync});
  final GitHubSync sync;

  Future<void> resolve(BuildContext context, String taskId) async {
    final task = sync.store.find(taskId);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: const Text('통합본으로 맞추기'),
        icon: Icons.restore_outlined,
        content: Text(
          '“${task.title}”의 개인 변경을 복구 기록에 보관하고 최신 통합본을 적용합니다. 이 작업의 제출 중인 PR은 닫습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('백업 후 통합본 적용'),
          ),
        ],
      ),
    );
    if (accepted != true || !context.mounted) return;
    try {
      await sync.acceptRemote(taskId, expectedVersion: task.version);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('개인 변경을 백업하고 통합본을 적용했습니다.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
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
              const Text(
                '아래 변경을 확인하고 통합을 승인하세요.',
                style: TextStyle(fontSize: 12, color: _muted),
              ),
              const SizedBox(height: 12),
              SelectableText(
                '커밋 ${data['sha']}',
                style: const TextStyle(fontSize: 10, color: _muted),
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
                    color: const Color(0xfffaf8fd),
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
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('통합 승인'),
            ),
          ],
        ),
      );
      if (accepted != true || !context.mounted) return;
      if (sync.config.slug != config.slug || sync.config.base != config.base) {
        throw const GitHubFailure('검토 중 연결 설정이 변경되었습니다. 다시 확인하세요.');
      }
      await sync.approve(data);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: sync,
    builder: (context, _) {
      final config = sync.config;
      final busy = sync.busy || sync.pulling;
      final savedConflicts = sync.store.meta('github.pullConflicts');
      final conflicts = savedConflicts.isEmpty
          ? <dynamic>[]
          : jsonDecode(savedConflicts) as List;
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.merge_outlined, color: _purple),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'GitHub 자동 동기화',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              config.enabled
                  ? '${config.slug} · 작업별 PR · ${sync.autoMergeEnabled ? '자동 통합' : '통합 승인 대기'} · 자동 가져오기'
                  : '저장소를 연결하면 등록·수정·상태 변경을 자동으로 제출합니다.',
              style: const TextStyle(fontSize: 12, color: _muted),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('github-configure'),
                  onPressed: busy || sync.store.isProject
                      ? null
                      : () => configure(context),
                  child: Text(
                    sync.store.isProject
                        ? '프로젝트 저장소에 연결됨'
                        : config.enabled
                        ? '연결 설정'
                        : '저장소 연결',
                  ),
                ),
                if (sync.store.isProject && !config.enabled)
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () async {
                            try {
                              await sync.connect(
                                GitHubConfig.fromJson({
                                  ...config.toJson(),
                                  'enabled': true,
                                }),
                              );
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(
                                  context,
                                ).showSnackBar(SnackBar(content: Text('$e')));
                              }
                            }
                          },
                    child: const Text('자동 동기화 켜기'),
                  ),
                if (config.enabled) ...[
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => sync.cycle(retryFailed: true),
                    child: const Text('지금 동기화 / 재시도'),
                  ),
                  TextButton(
                    onPressed: sync.disable,
                    child: const Text('자동 동기화 끄기'),
                  ),
                ],
              ],
            ),
            if (sync.pullMessage.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  sync.pullMessage,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                '저장 직후 자동 전송 · 변경 확인 약 10초',
                style: TextStyle(fontSize: 11, color: _muted),
              ),
            ),
            if (sync.store.meta('github.recoveryNotice').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  sync.store.meta('github.recoveryNotice'),
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xffbd9655),
                  ),
                ),
              ),
            if (sync.retryAt?.isAfter(DateTime.now()) == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'GitHub 요청 제한 · ${sync.retryAt!.toLocal().toString().substring(11, 19)} 이후 재시도',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xffbd9655),
                  ),
                ),
              ),
            for (final conflict in conflicts) ...[
              const Divider(height: 25, color: _border),
              Text(
                '${conflict['title']} · ${conflict['field']}',
                style: const TextStyle(fontSize: 12, color: Color(0xffbd6b7a)),
              ),
              const SizedBox(height: 6),
              SelectableText(
                '내 변경: ${conflict['local']}\n통합본: ${conflict['remote']}',
                style: const TextStyle(fontSize: 11, height: 1.6),
              ),
              if (conflict['taskId'] is String)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => resolve(context, conflict['taskId'] as String),
                  child: const Text('개인 변경 백업 후 통합본 적용'),
                ),
            ],
            for (final job in sync.jobs.take(20)) ...[
              const Divider(height: 25, color: _border),
              Text(
                job['title'] as String,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(switch (job['state']) {
                'pending' => '자동 제출 대기',
                'sending' => '커밋·PR 제출 중',
                'sent' =>
                  sync.autoMergeEnabled
                      ? 'PR 제출 완료 · 자동 통합 확인 중'
                      : 'PR 제출 완료 · 통합 승인 대기',
                'merged' => '통합 완료 · 내 DB 반영',
                _ => '전송 실패 · 자동 재시도 대기',
              }, style: const TextStyle(fontSize: 11, color: _purple)),
              if ((job['error'] as String? ?? '').isNotEmpty)
                Text(
                  job['error'] as String,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xffbd6b7a),
                  ),
                ),
              if (job['prUrl'] != null)
                SelectableText(
                  job['prUrl'] as String,
                  style: const TextStyle(fontSize: 10, color: _muted),
                ),
            ],
            if (sync.openRequests.isNotEmpty) ...[
              const Divider(height: 30, color: _border),
              const Text(
                '팀의 통합 대기',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              for (final pr in sync.openRequests)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '#${pr['number']} ${pr['title']}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                      if (sync.store.manages)
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () => review(context, pr['html_url'] as String),
                          child: const Text(
                            '변경 확인',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                    ],
                  ),
                ),
              for (final pr in sync.openRequests)
                if (sync.autoMergeErrors[pr['html_url']] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '#${pr['number']} · ${sync.autoMergeErrors[pr['html_url']]}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xffbd6b7a),
                      ),
                    ),
                  ),
            ],
            if (sync.store.isProject) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    sync.autoMergeEnabled
                        ? '정상 작업 PR은 자동으로 통합합니다.'
                        : 'PR 통합은 수동 승인합니다.',
                    style: const TextStyle(fontSize: 11, color: _muted),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => sync.setAutoMerge(!config.autoMerge),
                    child: Text(
                      sync.autoMergeEnabled ? '자동 통합 끄기' : '자동 통합 켜기',
                    ),
                  ),
                ],
              ),
              if (sync.autoMergeMessage.isNotEmpty)
                Text(
                  sync.autoMergeMessage,
                  style: const TextStyle(fontSize: 11, color: _muted),
                ),
            ],
          ],
        ),
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
    title: const Text('GitHub 저장소 연결'),
    icon: Icons.merge_outlined,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '팀 작업 데이터를 보관할 저장소를 지정하세요.',
          style: TextStyle(fontSize: 12, color: _muted),
        ),
        const SizedBox(height: 20),
        TextField(
          key: const Key('github-repository'),
          controller: repository,
          enabled: !connecting,
          decoration: const InputDecoration(
            labelText: '소유자 / 저장소',
            hintText: 'team/project-data',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: base,
          enabled: !connecting,
          decoration: const InputDecoration(
            labelText: '통합 브랜치',
            hintText: 'main',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: branch,
          enabled: !connecting,
          decoration: const InputDecoration(
            labelText: '작업 브랜치 접두사 (선택)',
            hintText: '비워 두면 ieum/내 GitHub 이름',
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
          decoration: const InputDecoration(
            labelText: '세션 토큰 (선택)',
            hintText: '비워 두면 컴퓨터의 저장된 Git 인증 사용',
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          '토큰은 앱 메모리에만 보관합니다. 토큰 사용 시 대상 저장소의 Contents·Pull requests 읽기/쓰기 권한이 필요합니다.',
          style: TextStyle(fontSize: 10, color: _muted, height: 1.6),
        ),
        const SizedBox(height: 12),
        const Text(
          '작업별 커밋·PR을 자동 생성하고, 30초마다 승인된 통합 브랜치의 변경을 가져옵니다. 충돌이 있으면 개인 변경을 보존하고 안내합니다.',
          style: TextStyle(fontSize: 11, color: _purple, height: 1.6),
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
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: connecting ? null : connect,
        child: Text(connecting ? '연결 확인 중…' : '확인 후 자동 동기화 켜기'),
      ),
    ],
  );
}
