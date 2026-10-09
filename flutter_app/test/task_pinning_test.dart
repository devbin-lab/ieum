import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/app.dart';
import 'package:ieum_flutter/models.dart';
import 'package:ieum_flutter/github_sync.dart';
import 'package:ieum_flutter/project_service.dart';

import 'part_workflow_test_fixtures.dart';
import 'task_lock_test.dart' show draft, storeFor, snapshot, validate;
import 'project_schedule_view_test.dart' show task;
import 'github_auto_merge_test.dart' show AutoMergeApi;
import 'github_sync_test.dart' show idle;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('window_manager'),
          (call) async => call.method == 'isMaximized' ? false : null,
        );
  });
  test('existing work defaults to unpinned and invalid flags are rejected', () {
    final original = task('old');
    expect(
      WorkTask.fromJson({...original.data}..remove('pinned')).isPinned,
      isFalse,
    );
    expect(() => original.copy({'pinned': 'false'}), throwsStateError);
    expect(() => original.copy({'pinned': true}), throwsStateError);
  });
  test(
    'pin is persisted, separate, idempotent, versioned and kept during edits',
    () {
      final store = storeFor(routeWorker);
      final original = store.save(draft());
      final pinned = store.setTaskPinned(original.id, true, expectedVersion: 1);
      expect(pinned.isPinned, isTrue);
      expect(pinned.version, 2);
      expect(store.storedTasks.single.isPinned, isTrue);
      expect(
        store.setTaskPinned(original.id, true, expectedVersion: 2).version,
        2,
      );
      expect(
        () => store.setTaskPinned(original.id, false, expectedVersion: 1),
        throwsStateError,
      );
      final edited = store.save({
        ...pinned.data,
        'priority': 'high',
      }, expectedVersion: 2);
      expect(edited.isPinned, isTrue);
      validate(routeWorker, pinned, original);
      validate(routeWorker, edited, pinned);
      final unpinned = store.setTaskPinned(
        original.id,
        false,
        expectedVersion: 3,
      );
      expect(unpinned.isPinned, isFalse);
      expect(
        () => validate(
          routeWorker,
          original.copy({
            'pinned': 'true',
            'description': 'bundled edit',
            'version': 2,
          }),
          original,
        ),
        throwsStateError,
      );
    },
  );
  test(
    'pin ordering takes precedence and uses high normal low within pinned work',
    () {
      final items = [
        task('unpinned-high').copy({'priority': 'high'}),
        task('pinned-low').copy({'pinned': 'true', 'priority': 'low'}),
        task('pinned-normal').copy({'pinned': 'true', 'priority': 'normal'}),
        task('pinned-high').copy({'pinned': 'true', 'priority': 'high'}),
      ]..sort(compareTaskPins);
      expect(items.map((t) => t.id), [
        'pinned-high',
        'pinned-normal',
        'pinned-low',
        'unpinned-high',
      ]);
      expect(
        compareTaskPins(task('a'), task('b').copy({'priority': 'high'})),
        0,
      );
    },
  );
  test(
    'another participant cannot pin locked work, including the administrator',
    () {
      final original = task('locked').copy({'lockedBy': routeWorker.id});
      for (final person in [routeReviewer, routeOwner]) {
        final store = storeFor(person, task: original);
        expect(store.canPin(original), isFalse);
        expect(
          () => store.setTaskPinned(original.id, true, expectedVersion: 1),
          throwsStateError,
        );
        expect(
          () => validate(
            person,
            original.copy({'pinned': 'true', 'version': 2}),
            original,
          ),
          throwsStateError,
        );
      }
      expect(storeFor(routeWorker, task: original).canPin(original), isTrue);
      final done = original.copy({
        'lockedBy': '',
        'status': 'done',
        'completedDate': original.assignedDate,
      });
      final store = storeFor(routeWorker, task: done);
      final pinned = store.setTaskPinned(done.id, true, expectedVersion: 1);
      expect(pinned.isPinned, isTrue);
      expect(store.canEdit(pinned), isFalse);
      expect(
        store.canPin(done.copy({'archivedAt': '2026-10-08T00:00:00Z'})),
        isFalse,
      );
      expect(
        store.canPin(done.copy({'deletedAt': '2026-10-08T00:00:00Z'})),
        isFalse,
      );
    },
  );
  test(
    'pending pin conflicts with a new lock and never disappears silently',
    () {
      final original = task('conflict');
      final store = storeFor(routeWorker, task: original);
      store.setTaskPinned(original.id, true, expectedVersion: 1);
      final result = store.importSnapshot(
        snapshot(original.copy({'lockedBy': routeReviewer.id, 'version': 2})),
      );
      expect(result.conflicts, isNotEmpty);
      expect(store.find(original.id).isPinned, isTrue);
      expect(store.baseline[original.id]!.isLocked, isFalse);
    },
  );
  test('offline registration, pin and edit publish through mocked GitHub with proof', () async {
    final api = AutoMergeApi();
    final session = GitHubSession(api: api);
    addTearDown(session.signOut);
    const config = GitHubConfig(repository: 'team/data', enabled: true);
    await session.signIn(token: 'test-only');
    await session.writeJson(
      config,
      '.ieum/project.json',
      personalReviewProject.json,
      message: 'Fixture',
    );
    api.identityId = 2;
    api.identityLogin = routeWorker.login;
    final store = storeFor(routeWorker);
    store.setMeta('github.config', jsonEncode(config.toJson()));
    store.setMeta('github.login', routeWorker.login);
    var item = store.save(draft());
    item = store.setTaskPinned(item.id, true, expectedVersion: 1);
    item = store.save({
      ...item.data,
      'description': '최종 내용',
    }, expectedVersion: item.version);
    final sync = GitHubSync(store, publisher: GitHubPublisher(api));
    addTearDown(sync.dispose);
    await sync.cycle();
    await idle(sync);
    expect(sync.autoMergeErrors, isEmpty);
    expect(sync.jobs.single['state'], 'merged');
    expect(store.baseline[item.id]!.isPinned, isTrue);
    expect(store.baseline[item.id]!.description, '최종 내용');
  });
  testWidgets(
    'list pin reorders, never opens details, and remains above ordinary work in Kanban',
    (tester) async {
      tester.view.physicalSize = const Size(1480, 940);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = storeFor(routeWorker);
      for (final entry in [
        task(
          'ordinary',
          title: '일반 작업',
        ).copy({'priority': 'high', 'updatedAt': '2026-10-08T08:00:00Z'}),
        task('low', title: '낮은 고정').copy({
          'priority': 'low',
          'pinned': 'true',
          'updatedAt': '2026-10-08T07:00:00Z',
        }),
        task('normal', title: '보통 고정').copy({
          'priority': 'normal',
          'pinned': 'true',
          'updatedAt': '2026-10-08T06:00:00Z',
        }),
        task(
          'high',
          title: '높은 고정',
        ).copy({'priority': 'high', 'updatedAt': '2026-10-08T05:00:00Z'}),
      ]) {
        store.put(entry);
      }
      await tester.pumpWidget(IeumApp(store: store));
      await tester.pumpAndSettle();
      expect(store.canPin(store.find('high')), isTrue);
      await tester.ensureVisible(find.byKey(const Key('task-pin-list-high')));
      await tester.tap(find.byKey(const Key('task-pin-list-high')));
      await tester.pumpAndSettle();
      expect(store.find('high').isPinned, isTrue);
      expect(find.text('작업 상세 닫기'), findsNothing);
      expect(find.byKey(const Key('task-pin-detail-high')), findsNothing);
      final order = ['높은 고정', '보통 고정', '낮은 고정', '일반 작업'];
      for (var i = 0; i < order.length - 1; i++) {
        expect(
          tester.getTopLeft(find.text(order[i])).dy,
          lessThan(tester.getTopLeft(find.text(order[i + 1])).dy),
        );
      }
      await tester.tap(find.byKey(const Key('view-kanban')));
      await tester.pumpAndSettle();
      final column = tester.widget<ListView>(
        find.byKey(const Key('column-items-todo')),
      );
      // Bounded columns build only nearby cards. Assert the actual UI order
      // without requiring offscreen cards to be mounted at the same time.
      final cards =
          (column.childrenDelegate as SliverChildListDelegate).children;
      expect(
        cards.whereType<Padding>().map(
          (item) => ((item.child as Draggable<WorkTask>).child).key,
        ),
        const [
          Key('card-high'),
          Key('card-normal'),
          Key('card-low'),
          Key('card-ordinary'),
        ],
      );
      tester.view.physicalSize = const Size(360, 540);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-list')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('task-pin-compact-high')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
