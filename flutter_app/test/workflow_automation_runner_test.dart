import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';
import 'package:ieum_flutter/workflow_automation.dart';

import 'part_workflow_policy_test.dart' show configured, planner, draft;

const start = WorkflowSheetRoute(
  id: 'auto-start',
  from: 'todo',
  to: 'doing',
  trigger: 'onEnter',
);

Future<void> settleAutomation() => Future<void>.delayed(Duration.zero);

void main() {
  late TaskStore store;
  WorkflowAutomationRunner? automation;
  setUp(() {
    store = TaskStore(
      ':memory:',
      project: configured(links: const [start]),
      identity: planner,
    );
  });
  tearDown(() {
    automation?.dispose();
    automation = null;
    store.dispose();
  });

  test(
    'local creation follows one on-enter route after the save returns',
    () async {
      automation = WorkflowAutomationRunner(store);
      final task = store.save(draft());
      expect(store.find(task.id).status, 'todo');
      await settleAutomation();
      expect(store.find(task.id).status, 'doing');
      expect(store.find(task.id).version, task.version + 1);
      expect(automation!.enabledRouteCount, 1);
      expect(automation!.lastMessage, contains('자동 전달 완료'));
    },
  );

  test(
    'startup, same-status edits and remote status changes never execute',
    () async {
      final task = store.save(draft());
      automation = WorkflowAutomationRunner(store);
      await settleAutomation();
      expect(store.find(task.id).status, 'todo');
      store.save({
        ...draft(),
        'id': task.id,
        'title': '본문 수정',
      }, expectedVersion: task.version);
      await settleAutomation();
      expect(store.find(task.id).status, 'todo');
      final local = store.find(task.id);
      final remoteDoing = local.copy({
        'status': 'doing',
        'version': local.version + 1,
      });
      store.put(remoteDoing);
      store.updateProject(store.project!);
      final remoteTodo = remoteDoing.copy({
        'status': 'todo',
        'version': remoteDoing.version + 1,
      });
      store.put(remoteTodo);
      store.updateProject(store.project!);
      await settleAutomation();
      expect(store.find(task.id).version, remoteTodo.version);
      expect(store.find(task.id).status, 'todo');
      // Even a rollback matching a historical local event must not replay it.
      store.put(remoteDoing);
      store.updateProject(store.project!);
      store.put(local);
      store.updateProject(store.project!);
      await settleAutomation();
      expect(store.find(task.id).version, local.version);
      expect(store.find(task.id).status, 'todo');
    },
  );

  test(
    'ambiguous paths, mandatory input and cycles wait without unsafe hops',
    () async {
      store.updateProject(
        configured(
          links: const [
            start,
            WorkflowSheetRoute(
              id: 'also-start',
              from: 'todo',
              to: 'review',
              trigger: 'onEnter',
            ),
          ],
        ),
      );
      automation = WorkflowAutomationRunner(store);
      final ambiguous = store.save(draft());
      await settleAutomation();
      expect(store.find(ambiguous.id).status, 'todo');
      expect(automation!.lastMessage, contains('여러 개'));
      store.updateProject(
        configured(
          links: const [
            WorkflowSheetRoute(
              id: 'comment',
              from: 'todo',
              to: 'doing',
              trigger: 'onEnter',
              commentRequired: true,
            ),
          ],
        ),
      );
      final needsComment = store.save(draft());
      await settleAutomation();
      expect(store.find(needsComment.id).status, 'todo');
      expect(automation!.lastMessage, contains('코멘트'));
      store.updateProject(
        configured(
          links: const [
            start,
            WorkflowSheetRoute(
              id: 'loop',
              from: 'doing',
              to: 'todo',
              trigger: 'onEnter',
            ),
          ],
        ),
      );
      final cycling = store.save(draft());
      await settleAutomation();
      expect(store.find(cycling.id).status, 'doing');
      expect(store.find(cycling.id).version, cycling.version + 1);
      expect(automation!.lastMessage, contains('순환'));
    },
  );

  test(
    'same-status automatic assignment runs once after entering progress',
    () async {
      store.updateProject(
        configured(
          links: const [
            start,
            WorkflowSheetRoute(
              id: 'auto-progress-handoff',
              from: 'doing',
              to: 'doing',
              destination: 'part:role-pd',
              person: 'gh-3',
              trigger: 'onEnter',
              purpose: 'review',
            ),
          ],
        ),
      );
      automation = WorkflowAutomationRunner(store);
      final task = store.save(draft());
      await settleAutomation();
      final handed = store.find(task.id);
      expect(handed.status, 'doing');
      expect(handed.workflowPerson, 'gh-3');
      expect(handed.workflowPurpose, 'review');
      expect(handed.workflowSender, planner.id);
      expect(handed.version, task.version + 2);
      expect(automation!.lastMessage, contains('해당 담당자의 입력'));
    },
  );

  test('automatic handoff waits for the next recipient while manual collaboration stays open', () async {
    store.updateProject(
      configured(
        links: const [
          WorkflowSheetRoute(
            id: 'auto-receive',
            from: 'todo',
            to: 'doing',
            destination: 'part:role-pd',
            person: 'gh-3',
            trigger: 'onEnter',
          ),
          WorkflowSheetRoute(
            id: 'auto-complete',
            from: 'doing',
            to: 'done',
            trigger: 'onEnter',
          ),
        ],
      ),
    );
    automation = WorkflowAutomationRunner(store);
    final task = store.save(draft());
    await settleAutomation();
    final handed = store.find(task.id);
    expect(handed.status, 'doing');
    expect(handed.workflowPerson, 'gh-3');
    expect(handed.version, task.version + 1);
    expect(store.canEditContent(handed), isTrue);
    expect(store.availableTransfers(handed), isNotEmpty);
    expect(automation!.lastMessage, contains('해당 담당자의 입력'));
  });

  test(
    'a queued run is cancelled if the task changes before the microtask',
    () async {
      automation = WorkflowAutomationRunner(store);
      final task = store.save(draft());
      store.save({
        ...draft(),
        'id': task.id,
        'title': '예약 뒤 수정',
      }, expectedVersion: task.version);
      await settleAutomation();
      expect(store.find(task.id).status, 'todo');
      expect(store.find(task.id).title, '예약 뒤 수정');
    },
  );
}
