import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';
import 'workspace_ui.dart';

class TaskCommentsPanel extends StatefulWidget {
  const TaskCommentsPanel({super.key, required this.store, required this.task});
  final TaskStore store;
  final WorkTask task;
  @override
  State<TaskCommentsPanel> createState() => _TaskCommentsPanelState();
}

class _TaskCommentsPanelState extends State<TaskCommentsPanel> {
  final text = TextEditingController();
  String error = '';
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void add() {
    try {
      widget.store.addTaskComment(
        widget.task.id,
        text.text,
        expectedVersion: widget.task.version,
      );
      text.clear();
      setState(() => error = '');
    } catch (e) {
      setState(() => error = trError(e));
    }
  }

  String timestamp(dynamic value) {
    final date = DateTime.tryParse(value.toString())?.toLocal();
    if (date == null) return '';
    String two(int value) => value.toString().padLeft(2, '0');
    return '${date.year}.${two(date.month)}.${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  Widget commentCard(Map<String, dynamic> comment) {
    final author = widget.store.member(comment['authorId']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: Color(author.color).withValues(alpha: .13),
            foregroundColor: Color(author.color),
            child: Text(
              author.name.isEmpty ? '?' : author.name.characters.first,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      author.name,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      timestamp(comment['createdAt']),
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                    if (comment['context'] == 'review')
                      Text(
                        tr('검토'),
                        style: TextStyle(
                          fontSize: 10,
                          color: Color(0xff8c652d),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(
                  comment['text'],
                  style: const TextStyle(fontSize: 12, height: 1.6),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WorkspaceSectionLabel(
        title: tr('댓글'),
        trailing: widget.task.comments.isEmpty
            ? null
            : Text(
                '${widget.task.comments.length}',
                style: WorkspaceUi.captionStyleOf(context),
              ),
      ),
      const SizedBox(height: 12),
      for (final comment in widget.task.comments) commentCard(comment),
      if (widget.store.canComment(widget.task)) ...[
        TextField(
          key: const Key('task-comment-input'),
          controller: text,
          maxLength: 2000,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: tr('댓글을 입력하세요.'),
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '${text.text.length}/2000',
              style: WorkspaceUi.captionStyleOf(context),
            ),
            const Spacer(),
            OutlinedButton.icon(
              key: const Key('task-comment-add'),
              onPressed:
                  text.text.trim().isEmpty || widget.task.comments.length >= 100
                  ? null
                  : add,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
              label: Text(tr('등록')),
            ),
          ],
        ),
        if (widget.task.comments.length >= 100)
          Text(
            tr('이 작업의 댓글이 최대 개수(100개)에 도달했습니다.'),
            style: TextStyle(fontSize: 11),
          ),
        if (error.isNotEmpty)
          Text(
            trError(error),
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    ],
  );
}
