import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';

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
      setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        '코멘트',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      for (final comment in widget.task.comments)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xfff3f5f7),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.store.member(comment['authorId']).name} · ${comment['createdAt'].substring(0, 10)}',
                style: const TextStyle(fontSize: 10, color: Color(0xff737e90)),
              ),
              const SizedBox(height: 6),
              SelectableText(
                comment['text'],
                style: const TextStyle(fontSize: 12, height: 1.6),
              ),
            ],
          ),
        ),
      if (widget.store.canComment(widget.task)) ...[
        TextField(
          key: const Key('task-comment-input'),
          controller: text,
          maxLength: 2000,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '의견이나 수정 요청을 남겨 주세요.'),
          onChanged: (_) => setState(() {}),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            key: const Key('task-comment-add'),
            onPressed:
                text.text.trim().isEmpty || widget.task.comments.length >= 100
                ? null
                : add,
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
            label: const Text('코멘트 등록'),
          ),
        ),
        if (widget.task.comments.length >= 100)
          const Text(
            '코멘트는 작업당 최대 100개까지 등록할 수 있습니다.',
            style: TextStyle(fontSize: 11),
          ),
        if (error.isNotEmpty)
          Text(error, style: const TextStyle(fontSize: 11, color: Colors.red)),
      ],
    ],
  );
}
