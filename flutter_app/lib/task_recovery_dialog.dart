import 'package:flutter/material.dart';

import 'models.dart';
import 'store.dart';

class TaskRecoverySelection {
  const TaskRecoverySelection(this.stageId, this.personId);
  final String stageId, personId;
}

Future<TaskRecoverySelection?> showTaskRecoveryDialog(
  BuildContext context,
  TaskStore store,
  WorkTask task,
) async {
  final stages = store.project!.workflowStages
      .where((s) => !const {'review', 'done'}.contains(s.id))
      .toList();
  final people = store.people.where((p) => p.active).toList();
  if (stages.isEmpty || people.isEmpty) return null;
  var stage = stages.any((s) => s.id == task.status)
      ? task.status
      : stages.first.id;
  var person = people.any((p) => p.id == task.assigneeId)
      ? task.assigneeId
      : people.first.id;
  return showDialog<TaskRecoverySelection>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: const Text('관리자 작업 회수'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(task.title),
              const SizedBox(height: 12),
              const Text(
                '현재 전달을 회수하고 선택한 작업자에게 다시 배정합니다. 작업 내용과 반려 코멘트는 유지됩니다.',
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<String>(
                key: const Key('recovery-stage'),
                initialValue: stage,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '되돌릴 단계'),
                items: [
                  for (final s in stages)
                    DropdownMenuItem(value: s.id, child: Text(s.name)),
                ],
                onChanged: (value) => update(() => stage = value!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                key: const Key('recovery-person'),
                initialValue: person,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '처리할 작업자'),
                items: [
                  for (final p in people)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (value) => update(() => person = value!),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('recovery-confirm'),
            onPressed: () =>
                Navigator.pop(ctx, TaskRecoverySelection(stage, person)),
            child: const Text('회수 후 재배정'),
          ),
        ],
      ),
    ),
  );
}
