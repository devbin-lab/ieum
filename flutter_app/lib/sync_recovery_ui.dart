import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'popup_ui.dart';
import 'store.dart';
import 'sync_recovery_record.dart';
import 'workspace_ui.dart';

Future<void> showSyncRecoveryHistory(BuildContext context, TaskStore store) =>
    showDialog<void>(
      context: context,
      builder: (_) => _RecoveryHistoryDialog(store: store),
    );

class SyncRecoveryHistoryButton extends StatelessWidget {
  const SyncRecoveryHistoryButton({super.key, required this.store});
  final TaskStore store;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) => store.syncRecoveryCount() == 0
        ? const SizedBox.shrink()
        : TextButton.icon(
            key: const Key('sync-recovery-history'),
            onPressed: () => showSyncRecoveryHistory(context, store),
            icon: const Icon(Icons.history_rounded, size: 16),
            label: Text(tr('복구 기록')),
          ),
  );
}

class SyncRecoveryNotice extends StatelessWidget {
  const SyncRecoveryNotice({super.key, required this.store});
  final TaskStore store;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: store,
    builder: (context, _) {
      if (!store.hasSyncRecoveryNotice) return const SizedBox.shrink();
      final through = store.latestSyncRecoveryIndex;
      final colors = WorkspaceUi.colors(context);
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Container(
          key: const Key('sync-recovery-notice'),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          decoration: BoxDecoration(
            color: colors.warning.withValues(alpha: .07),
            border: Border.all(color: colors.warning.withValues(alpha: .24)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.history_rounded, size: 17, color: colors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('전송 기록을 복구했습니다.'),
                      style: WorkspaceUi.sectionStyleOf(context),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                tr('읽지 못한 기록은 보관했습니다. 저장된 작업을 기준으로 전송을 다시 준비합니다.'),
                style: WorkspaceUi.captionStyleOf(context),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton(
                    key: const Key('sync-recovery-view-records'),
                    onPressed: () => showSyncRecoveryHistory(context, store),
                    child: Text(tr('기록 보기')),
                  ),
                  TextButton(
                    key: const Key('sync-recovery-acknowledge'),
                    onPressed: () =>
                        store.acknowledgeSyncRecoveryNotice(through: through),
                    child: Text(tr('확인')),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _RecoveryHistoryDialog extends StatefulWidget {
  const _RecoveryHistoryDialog({required this.store});
  final TaskStore store;
  @override
  State<_RecoveryHistoryDialog> createState() => _RecoveryHistoryDialogState();
}

class _RecoveryHistoryDialogState extends State<_RecoveryHistoryDialog> {
  static const pageSize = 10;
  late final through = widget.store.latestSyncRecoveryIndex;
  late final count = widget.store.syncRecoveryCount(through: through);
  int page = 0;
  final expanded = <String>{};

  String time(String value) {
    final date = DateTime.tryParse(value)?.toLocal();
    return date == null
        ? tr('시간 정보 없음')
        : date.toString().substring(0, 16).replaceAll('-', '.');
  }

  Widget record(SyncRecoveryRecord item) {
    final colors = WorkspaceUi.colors(context);
    final source = switch (item.source) {
      'github_queue' => tr('전송 대기열'),
      'github_sent' => tr('전송 완료 기록'),
      _ => tr('전송 기록'),
    };
    return Padding(
      key: ValueKey('sync-recovery-record-${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${time(item.createdAt)} · $source',
            style: WorkspaceUi.captionStyleOf(context),
          ),
          const SizedBox(height: 7),
          Text(
            item.taskTitle.isEmpty ? tr('작업 정보 없음') : item.taskTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: WorkspaceUi.sectionStyleOf(context),
          ),
          const SizedBox(height: 8),
          Text(
            tr(item.reason),
            style: TextStyle(fontSize: 12, height: 1.6, color: colors.ink),
          ),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey('sync-recovery-details-${item.id}'),
              onPressed: () => setState(() {
                if (!expanded.add(item.id)) expanded.remove(item.id);
              }),
              icon: Icon(
                expanded.contains(item.id)
                    ? Icons.expand_less
                    : Icons.expand_more,
                size: 17,
              ),
              label: Text(tr('오류 세부정보')),
            ),
          ),
          if (expanded.contains(item.id))
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.subtle,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(tr('오류 내용'), style: WorkspaceUi.captionStyleOf(context)),
                  const SizedBox(height: 5),
                  SelectableText(
                    trError(item.error).characters.take(4000).toString(),
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.6,
                      color: colors.ink,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    tr('기록 식별자'),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                  const SizedBox(height: 5),
                  SelectableText(
                    item.recordId.isEmpty ? item.id : item.recordId,
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.store.syncRecoveryRecords(
      through: through,
      offset: page * pageSize,
      limit: pageSize,
    );
    final pages = count == 0 ? 1 : (count + pageSize - 1) ~/ pageSize;
    return IeumDialog(
      title: Text(tr('복구 기록')),
      icon: Icons.history_rounded,
      width: 640,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(
              '읽지 못한 전송 기록의 발생 이유와 원본 오류를 확인할 수 있습니다. 작업 데이터는 복구 과정에서 삭제하지 않습니다.',
            ),
            style: WorkspaceUi.captionStyleOf(context),
          ),
          const SizedBox(height: 12),
          Text(
            tr(
              '총 {v0}건 · {v1}/{v2} 페이지',
              args: {'v0': count, 'v1': page + 1, 'v2': pages},
            ),
            style: WorkspaceUi.captionStyleOf(context),
          ),
          if (records.isEmpty) ...[
            const SizedBox(height: 24),
            Text(tr('보관된 복구 기록이 없습니다.')),
          ],
          for (final item in records) ...[
            record(item),
            Divider(height: 1, color: WorkspaceUi.colors(context).line),
          ],
        ],
      ),
      actions: [
        if (pages > 1) ...[
          TextButton(
            key: const Key('sync-recovery-previous'),
            onPressed: page > 0 ? () => setState(() => page--) : null,
            child: Text(tr('이전')),
          ),
          TextButton(
            key: const Key('sync-recovery-next'),
            onPressed: page + 1 < pages ? () => setState(() => page++) : null,
            child: Text(tr('다음')),
          ),
        ],
        FilledButton(
          key: const Key('sync-recovery-confirm'),
          onPressed: () {
            widget.store.acknowledgeSyncRecoveryNotice(through: through);
            Navigator.pop(context);
          },
          child: Text(tr('확인')),
        ),
      ],
    );
  }
}
