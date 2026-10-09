import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:ieum_flutter/discord_outbox.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/store.dart';

void main() {
  late TaskStore store;
  late DiscordOutbox outbox;
  const owner = Person(
    'gh-1',
    'Owner',
    'O',
    'owner',
    0xff000000,
    login: 'owner',
    parts: ['Plan'],
  );
  const worker = Person(
    'gh-2',
    'Worker',
    'W',
    'worker',
    0xff000000,
    login: 'worker',
    parts: ['Plan'],
  );
  final project = ProjectManifest.fromJson({
    'schemaVersion': 1,
    'projectId': 'test',
    'name': 'Test',
    'ownerId': owner.id,
    'members': [owner.json, worker.json],
    'parts': ['Plan'],
    'roles': [const ProjectRole('role-plan', 'Plan', {}).json],
  });
  final seed =
      jsonDecode(File('assets/demo-snapshot.json').readAsStringSync())['tasks']
          as List;
  late WorkTask task;
  Map<String, dynamic> route(String id, {List<String> partIds = const []}) => {
    'routeId': id,
    'channelId': '12345678901234567',
    'guildId': '23456789012345678',
    'channelName': 'Tasks',
    'enabled': true,
    'eventTypes': ['assigned', 'handedOff', 'completed'],
    'partIds': partIds,
    'secretVersion': 1,
  };
  void capture({
    List<Map<String, dynamic>>? routes,
    String eventType = 'task.assigned',
    String previousStatusName = '',
  }) => outbox.capture(
    task: task,
    project: project,
    actorId: owner.id,
    deviceId: 'origin',
    scope: 'scope',
    routes: routes ?? [route('all')],
    eventType: eventType,
    at: DateTime.now().toUtc().toIso8601String(),
    statusName: '확인중',
    previousStatusName: previousStatusName,
  );
  Map<String, dynamic> receipt(String state, {String? author}) => {
    'revision': 'r1',
    'state': state,
    'commitSha': 'accepted-own-commit',
    'proposal': {
      'authorId': author ?? owner.id,
      'changes': [
        {'task': task.data},
      ],
    },
  };
  setUp(() {
    store = TaskStore(':memory:');
    outbox = DiscordOutbox(store.db);
    task = WorkTask.fromJson(
      Map<String, dynamic>.from(seed.first),
    ).copy({'workflowTarget': 'part:role-plan', 'workflowPerson': worker.id});
  });
  tearDown(() => store.dispose());

  test(
    'legacy channel includes progress changes after exact own integration',
    () {
      task = task.copy({'status': 'doing'});
      capture(eventType: 'task.moved', previousStatusName: '대기');
      final event = outbox.rows('discord_events').single;
      expect(event['type'], 'statusChanged');
      expect(event['previousStatus'], '대기');
      outbox.bind(task, 'r1', project);
      outbox.integrated(receipt('sent'), owner.id);
      expect(outbox.rows('discord_deliveries'), isEmpty);
      outbox.integrated(receipt('merged'), owner.id);
      outbox.integrated(receipt('merged'), owner.id);
      expect(outbox.rows('discord_deliveries'), hasLength(1));
    },
  );

  test('explicit status-change opt-out does not become an implicit legacy fallback', () {
    task = task.copy({'status': 'doing'});
    capture(
      eventType: 'task.doing',
      routes: [
        {...route('new'), 'notificationVersion': 2},
      ],
    );
    expect(outbox.rows('discord_events'), isEmpty);
    capture(
      eventType: 'task.doing',
      routes: [
        {
          ...route('new'),
          'notificationVersion': 2,
          'eventTypes': ['statusChanged'],
        },
      ],
    );
    expect(outbox.rows('discord_events').single['type'], 'statusChanged');
  });

  test(
    'real project start and hold transitions bind a status-change delivery',
    () {
      final live = TaskStore(':memory:', project: project, identity: owner);
      addTearDown(live.dispose);
      live.setMeta(
        'github.config',
        jsonEncode(const GitHubConfig(repository: 'team/data').toJson()),
      );
      live.setMeta('discord.publicRoutes', jsonEncode([route('existing')]));
      live.setMeta('discord.deviceId', 'origin');
      live.setMeta('discord.scope', 'scope');
      var registered = live.save({
        'title': 'Plan work',
        'part': 'Plan',
        'priority': 'normal',
        'assigneeId': owner.id,
        'reviewerId': owner.id,
        'assignedDate': '2026-10-10',
        'dueDate': '',
        'description': '',
      });
      final notifications = DiscordOutbox(live.db);
      final start = live
          .availableHandoffs(registered)
          .singleWhere((p) => p.routeId == 'manual-start');
      live.confirmHandoff(start);
      registered = live.find(registered.id);
      final changed = notifications
          .rows('discord_events')
          .singleWhere((e) => e['type'] == 'statusChanged');
      expect(changed['previousStatus'], '확인중');
      expect(changed['status'], '진행중');
      expect(changed['recipients'], [owner.id]);
      expect(changed['revision'], isNotEmpty);
      notifications.integrated({
        'revision': changed['revision'],
        'state': 'merged',
        'commitSha': 'own',
        'proposal': {
          'authorId': owner.id,
          'changes': [
            {'task': registered.data},
          ],
        },
      }, owner.id);
      expect(notifications.rows('discord_deliveries'), hasLength(1));
      final pause = live
          .availableHandoffs(registered)
          .singleWhere((p) => p.destinationId == 'hold');
      live.confirmHandoff(pause, reason: '추가 자료 대기');
      expect(
        notifications
            .rows('discord_events')
            .where((e) => e['type'] == 'statusChanged'),
        hasLength(2),
      );
    },
  );

  test(
    'plain edits keep an assignment pending for the updated exact proposal',
    () {
      capture(eventType: 'task.created');
      outbox.bind(task, 'r1', project);
      task = task.copy({
        'version': task.version + 1,
        'title': 'Edited before publishing',
      });
      outbox.bind(task, 'r1', project);
      expect(
        outbox.rows('discord_events').single['state'],
        'waitingIntegration',
      );
      outbox.integrated(receipt('merged'), owner.id);
      expect(outbox.rows('discord_deliveries'), hasLength(1));
      expect(outbox.rows('discord_events').single['title'], task.title);
    },
  );

  test(
    'changed recipient without a new capture cancels the old destination',
    () {
      capture();
      outbox.bind(task, 'r1', project);
      task = task.copy({
        'version': task.version + 1,
        'workflowPerson': owner.id,
      });
      outbox.bind(task, 'r2', project);
      expect(outbox.rows('discord_events').single['state'], 'cancelled');
      outbox.integrated(receipt('merged'), owner.id);
      expect(outbox.rows('discord_deliveries'), isEmpty);
    },
  );

  test('comments on a completed task do not emit completion again', () {
    task = task.copy({'status': 'done'});
    capture(eventType: 'task.comment');
    expect(outbox.rows('discord_events'), isEmpty);
    capture(eventType: 'task.moved');
    expect(outbox.rows('discord_events').single['type'], 'completed');
  });

  test(
    'retention compacts terminal snapshots while preserving pending work',
    () {
      capture();
      final terminal = outbox.rows('discord_events').single;
      final old = DateTime.now()
          .subtract(const Duration(days: 40))
          .toUtc()
          .toIso8601String();
      outbox.put('discord_events', {
        ...terminal,
        'state': 'delivered',
        'createdAt': old,
      });
      capture();
      outbox.prune();
      final rows = outbox.rows('discord_events');
      expect(
        rows.singleWhere((r) => r['state'] == 'delivered').containsKey('task'),
        isFalse,
      );
      expect(
        rows
            .singleWhere((r) => r['state'] == 'waitingIntegration')
            .containsKey('task'),
        isTrue,
      );
    },
  );

  test('queue lookups and bounded history retain older pending deliveries', () {
    outbox.put('discord_events', {
      'id': 'pending-event',
      'taskId': task.id,
      'state': 'waitingIntegration',
      'createdAt': '2026-01-01T00:00:00.000Z',
    });
    outbox.put('discord_deliveries', {
      'id': 'pending-delivery',
      'eventId': 'pending-event',
      'state': 'retry_wait',
      'createdAt': '2026-01-01T00:00:00.000Z',
    });
    for (var i = 0; i < 220; i++) {
      outbox.put('discord_events', {
        'id': 'done-event-$i',
        'taskId': 'other',
        'state': 'delivered',
        'createdAt': '2026-02-01T00:00:00.000Z',
      });
      outbox.put('discord_deliveries', {
        'id': 'done-delivery-$i',
        'eventId': 'done-event-$i',
        'state': 'delivered',
        'createdAt': '2026-02-01T00:00:00.000Z',
      });
    }
    expect(outbox.event('pending-event')?['taskId'], task.id);
    expect(outbox.delivery('pending-delivery')?['state'], 'retry_wait');
    expect(outbox.event('absent'), isNull);
    expect(outbox.history('discord_deliveries'), hasLength(200));
    expect(
      outbox.history('discord_deliveries', limit: 2).first['id'],
      'done-delivery-219',
    );
    expect(outbox.pendingDeliveries().single['id'], 'pending-delivery');
    expect(
      outbox.waitingEvents(taskId: task.id, limit: 1).single['id'],
      'pending-event',
    );
    expect(outbox.waitingEvents(taskId: 'other'), isEmpty);
    outbox.put('discord_events', {
      'id': 'later-insert',
      'state': 'waitingIntegration',
      'createdAt': '2025-01-01T00:00:00.000Z',
    });
    expect(outbox.waitingEvents(limit: 1).single['id'], 'pending-event');
    outbox.put('discord_deliveries', {
      'id': 'cancelled-delivery',
      'state': 'cancelled',
      'createdAt': '2027-01-01T00:00:00.000Z',
    });
    expect(
      outbox
          .history('discord_deliveries', limit: 1, includeCancelled: false)
          .single['id'],
      'done-delivery-219',
    );
  });

  test('an event settles only after its own channel deliveries finish', () {
    outbox.put('discord_events', {'id': 'event', 'state': 'ready'});
    final first = {'id': 'first', 'eventId': 'event', 'state': 'ready'};
    final second = {'id': 'second', 'eventId': 'event', 'state': 'retry_wait'};
    outbox.put('discord_deliveries', first);
    outbox.put('discord_deliveries', second);
    outbox.put('discord_deliveries', {
      'id': 'other',
      'eventId': 'unrelated',
      'state': 'ready',
    });
    outbox.settle({...first, 'state': 'delivered'});
    expect(outbox.event('event')?['state'], 'ready');
    outbox.cancel('second');
    expect(outbox.event('event')?['state'], 'delivered');
    expect(outbox.delivery('other')?['state'], 'ready');
  });

  test(
    'existing malformed queue records do not break indexing or maintenance',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      for (final table in ['discord_events', 'discord_deliveries']) {
        db.execute(
          'CREATE TABLE $table(id TEXT PRIMARY KEY,body TEXT NOT NULL)',
        );
        db.execute('INSERT INTO $table VALUES (?,?)', ['broken', '{invalid']);
      }
      DiscordOutbox.initialize(db);
      final queue = DiscordOutbox(db);
      queue.recoverInterrupted();
      queue.prune();
      expect(queue.history('discord_events'), isEmpty);
      expect(queue.pendingDeliveries(), isEmpty);
      expect(queue.event('broken'), isNull);
      // Preserve corrupt records for diagnosis instead of silently discarding them.
      expect(
        db.select('SELECT body FROM discord_events').single['body'],
        '{invalid',
      );
    },
  );

  test('submitted or foreign receipts never send; exact own integrated receipt creates one delivery', () {
    capture();
    outbox.bind(task, 'r1', project);
    outbox.integrated(receipt('sent'), owner.id);
    outbox.integrated(receipt('merged', author: worker.id), owner.id);
    outbox.integrated({...receipt('merged'), 'commitSha': ''}, owner.id);
    expect(outbox.rows('discord_deliveries'), isEmpty);
    outbox.integrated(receipt('merged'), owner.id);
    outbox.integrated(receipt('merged'), owner.id);
    expect(outbox.rows('discord_deliveries'), hasLength(1));
  });
  test('specific part route overrides all and channel duplicates collapse', () {
    capture(
      routes: [
        route('all'),
        route('part-a', partIds: ['role-plan']),
        route('part-b', partIds: ['role-plan']),
      ],
    );
    final selected = outbox.rows('discord_events').single['routes'] as List;
    expect(selected, hasLength(1));
    expect(selected.single['routeId'], 'part-a');
  });
  test('explicit person overrides whole-part mention, unrestricted tasks mention nobody', () {
    expect(discordTaskRecipients(task, project).map((p) => p.id), [worker.id]);
    expect(
      discordTaskRecipients(task.copy({'workflowPerson': ''}), project),
      hasLength(2),
    );
    expect(
      discordTaskRecipients(
        task.copy({'workflowPerson': '', 'workflowTarget': ''}),
        project,
      ),
      isEmpty,
    );
  });
  test(
    'claim is atomic; interrupted sends require deliberate uncertain retry',
    () {
      capture();
      outbox.bind(task, 'r1', project);
      outbox.integrated(receipt('merged'), owner.id);
      final row = outbox.rows('discord_deliveries').single;
      expect(outbox.claim(row), isTrue);
      expect(outbox.claim(row), isFalse);
      outbox.recoverInterrupted();
      expect(outbox.rows('discord_deliveries').single['state'], 'uncertain');
      expect(
        () => outbox.retry(row['id'], confirmedUncertain: false),
        throwsStateError,
      );
      outbox.retry(row['id'], confirmedUncertain: true);
      expect(outbox.rows('discord_deliveries').single['state'], 'ready');
    },
  );
  test(
    'different accepted content and version do not release a saved event',
    () {
      capture();
      outbox.bind(task, 'r1', project);
      final job = receipt('merged');
      job['proposal']['changes'][0]['task'] = task.copy({
        'title': 'Different accepted task',
      }).data;
      outbox.integrated(job, owner.id);
      expect(outbox.rows('discord_deliveries'), isEmpty);
    },
  );
}
