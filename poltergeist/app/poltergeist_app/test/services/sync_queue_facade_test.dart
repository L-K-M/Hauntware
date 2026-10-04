// The activity-panel seam's unit coverage (M8, 05 §10): task-row
// minting, per-item event rollups, the pause/cancel/retry verb
// routing, and the composite queue's ownership split.
@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_app/services/archive_queue_tasks.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/fake_app_transfer_queue.dart';
import '../support/fake_local_archive_job.dart';
import '../support/sync_harness.dart';

TransferTaskSpec _spec() => TransferTaskSpec(
  source: const LocalFsLocation(),
  destination: const LocalFsLocation(),
  rootPaths: const ['/left'],
  destinationDir: '/right',
  policy: ResolvedConflictPolicy(),
);

SyncPlan _plan() => testPlan(testSyncPair(), [
  testItem(
    'a.txt',
    left: testFile(size: 10),
    suggested: SyncActionType.copyLeftToRight,
    reason: SyncReason.onlyOnLeft,
  ),
  testItem(
    'dir',
    left: testDir,
    suggested: SyncActionType.makeDirRight,
    reason: SyncReason.onlyOnLeft,
  ),
  // Skip/conflict rows carry no work — they never get a panel row.
  testItem('same.txt', left: testFile(), right: testFile()),
]);

({ArchiveQueueTasks tasks, List<FakeLocalArchiveJob> jobs}) _archives() {
  final jobs = <FakeLocalArchiveJob>[];
  return (
    tasks: ArchiveQueueTasks.forTesting(
      createZip:
          ({
            required List<String> sourcePaths,
            required String destinationPath,
          }) {
            final job = FakeLocalArchiveJob(
              operation: LocalArchiveOperation.createZip,
            );
            jobs.add(job);
            return job;
          },
      extractZip:
          ({required String archivePath, required String destinationPath}) {
            final job = FakeLocalArchiveJob(
              operation: LocalArchiveOperation.extractZip,
            );
            jobs.add(job);
            return job;
          },
    ),
    jobs: jobs,
  );
}

Future<void> _disposeArchives(
  ArchiveQueueTasks tasks,
  List<FakeLocalArchiveJob> jobs,
) async {
  for (final job in jobs) {
    if (!job.isDone) job.fail(LocalArchiveErrorKind.cancelled);
  }
  await tasks.dispose();
  for (final job in jobs) {
    await job.close();
  }
}

void main() {
  late SyncQueueTasks tasks;

  SyncTaskBinding begin() => tasks.beginTask(
    spec: _spec(),
    plan: _plan(),
    pause: SyncRunPause(),
    cancellation: RemoteTransferCancellation(),
    retry: () async {},
  );

  setUp(() => tasks = SyncQueueTasks());

  test('beginTask mints one running row per actionable item', () {
    final binding = begin();
    final task = binding.task;
    expect(task.state, TransferTaskState.running);
    expect(task.items, hasLength(2));
    expect(task.totalFiles, 1);
    expect(task.totalDirectories, 1);
    expect(task.totalBytes, 10);
    expect(binding.itemFor('same.txt'), isNull);
    expect(tasks.tasks, contains(task));
  });

  test('item events mirror states and roll up counts', () {
    final binding = begin();
    final item = _plan().items.first;
    binding.emitItemStarted(item);
    expect(binding.itemFor('a.txt')!.state, TransferItemState.active);
    binding.emitProgress('a.txt', 5, 10);
    expect(binding.itemFor('a.txt')!.transferredBytes, 5);
    // Mid-flight progress never commits to the task rollup.
    expect(binding.task.transferredBytes, 0);
    item.status = SyncItemStatus.done;
    binding.emitItemFinished(item);
    expect(binding.itemFor('a.txt')!.state, TransferItemState.completed);
    expect(binding.task.completedFiles, 1);
    expect(binding.task.transferredBytes, 10);
  });

  test('pause/resume/cancel route to the run controls', () {
    final pause = SyncRunPause();
    final cancellation = RemoteTransferCancellation();
    final binding = tasks.beginTask(
      spec: _spec(),
      plan: _plan(),
      pause: pause,
      cancellation: cancellation,
      retry: () async {},
    );
    expect(tasks.setPaused(binding.task.id, true), isTrue);
    expect(pause.isPaused, isTrue);
    expect(binding.task.state, TransferTaskState.paused);
    expect(tasks.setPaused(binding.task.id, false), isTrue);
    expect(pause.isPaused, isFalse);
    expect(tasks.cancel(binding.task.id), isTrue);
    expect(cancellation.isCancelled, isTrue);
  });

  test('retry restarts a failed task through the binding', () async {
    var retried = 0;
    final binding = tasks.beginTask(
      spec: _spec(),
      plan: _plan(),
      pause: SyncRunPause(),
      cancellation: RemoteTransferCancellation(),
      retry: () async => retried++,
    );
    binding.emitTaskState(TransferTaskState.failed);
    expect(tasks.canRetry(binding.task.id), isTrue);
    expect(tasks.retry(binding.task.id), isTrue);
    expect(retried, 1);
    expect(binding.task.state, TransferTaskState.running);
    // A completed task refuses retry — nothing left to drive.
    binding.emitTaskState(TransferTaskState.completed);
    expect(tasks.canRetry(binding.task.id), isFalse);
  });

  test('retry and terminal success clear stale sync failures', () {
    final plan = _plan();
    final binding = tasks.beginTask(
      spec: _spec(),
      plan: plan,
      pause: SyncRunPause(),
      cancellation: RemoteTransferCancellation(),
      retry: () async {},
    );
    final item = plan.items.first;
    binding.emitItemStarted(item);
    binding.emitProgress(item.relativePath, 4, 10);
    item
      ..status = SyncItemStatus.failed
      ..error = 'first attempt failed';
    binding.emitItemFinished(item);
    binding.emitTaskState(
      TransferTaskState.failed,
      error: 'first attempt failed',
      failureKind: RemoteFileErrorKind.permissionDenied,
    );

    expect(tasks.retry(binding.task.id), isTrue);
    expect(binding.task.error, isNull);
    expect(binding.task.failureKind, isNull);
    expect(binding.task.failedItems, 0);
    expect(
      binding.itemFor(item.relativePath)?.state,
      TransferItemState.pending,
    );
    expect(binding.itemFor(item.relativePath)?.error, isNull);
    expect(binding.itemFor(item.relativePath)?.transferredBytes, 0);

    binding.emitItemStarted(item);
    item
      ..status = SyncItemStatus.failed
      ..error = 'current attempt failed';
    binding.emitItemFinished(item);
    binding.emitTaskState(TransferTaskState.paused);
    binding.emitTaskState(TransferTaskState.running);
    expect(binding.task.error, 'current attempt failed');
    expect(binding.task.failedItems, 1);

    binding.emitTaskState(
      TransferTaskState.failed,
      failureKind: RemoteFileErrorKind.other,
    );
    expect(tasks.retry(binding.task.id), isTrue);
    binding.emitItemStarted(item);
    item.status = SyncItemStatus.done;
    binding.emitItemFinished(item);
    binding.emitTaskState(TransferTaskState.completed);

    expect(binding.task.error, isNull);
    expect(binding.task.failureKind, isNull);
    expect(binding.task.failedItems, 0);
    expect(binding.itemFor(item.relativePath)?.error, isNull);
  });

  test('cancelled sync clears stale task failure metadata', () {
    final binding = begin();
    binding.emitTaskState(
      TransferTaskState.running,
      error: 'one item failed before cancellation',
      failureKind: RemoteFileErrorKind.other,
    );

    binding.emitTaskState(TransferTaskState.cancelled);

    expect(binding.task.error, isNull);
    expect(binding.task.failureKind, isNull);
  });

  test('retry resets only rows the executor will retry', () {
    final plan = _plan();
    final binding = tasks.beginTask(
      spec: _spec(),
      plan: plan,
      pause: SyncRunPause(),
      cancellation: RemoteTransferCancellation(),
      retry: () async {},
    );
    final failed = plan.items[0]
      ..status = SyncItemStatus.failed
      ..error = 'copy failed';
    final conflicted = plan.items[1]
      ..status = SyncItemStatus.conflicted
      ..error = 'source changed';
    binding.emitItemFinished(failed);
    binding.emitItemFinished(conflicted);
    binding.emitTaskState(TransferTaskState.failed);

    expect(tasks.retry(binding.task.id), isTrue);

    expect(
      binding.itemFor(failed.relativePath)?.state,
      TransferItemState.pending,
    );
    expect(
      binding.itemFor(conflicted.relativePath)?.state,
      TransferItemState.failed,
    );
    expect(binding.task.failedItems, 1);
  });

  test('remove drops terminal rows only', () {
    final binding = begin();
    expect(tasks.remove(binding.task.id), isFalse);
    binding.emitTaskState(TransferTaskState.completed);
    expect(tasks.remove(binding.task.id), isTrue);
    expect(tasks.tasks, isEmpty);
  });

  group('CompositeAppTransferQueue', () {
    test('verbs route by task-id ownership', () {
      final inner = FakeAppTransferQueue();
      final innerTask = inner.addTask();
      final archives = _archives();
      addTearDown(() => _disposeArchives(archives.tasks, archives.jobs));
      final composite = CompositeAppTransferQueue(inner, tasks, archives.tasks);
      final binding = begin();

      // Reads concatenate both surfaces.
      expect(
        composite.tasks.map((t) => t.id),
        containsAll([innerTask.id, binding.task.id]),
      );

      // Inner-owned verbs never reach the sync registry.
      composite.pauseTask(innerTask.id);
      expect(inner.pauseTaskCalls, [innerTask.id]);
      composite.cancelTask(innerTask.id);
      expect(inner.cancelTaskCalls, [innerTask.id]);

      // Sync-owned verbs never reach the inner queue.
      composite.pauseTask(binding.task.id);
      expect(binding.task.state, TransferTaskState.paused);
      expect(inner.pauseTaskCalls, hasLength(1));
      composite.resumeTask(binding.task.id);
      expect(binding.task.state, TransferTaskState.running);
      composite.cancelTask(binding.task.id);
      expect(inner.cancelTaskCalls, hasLength(1));
    });

    test('both event streams merge into one', () async {
      final inner = FakeAppTransferQueue();
      final archives = _archives();
      addTearDown(() => _disposeArchives(archives.tasks, archives.jobs));
      final composite = CompositeAppTransferQueue(inner, tasks, archives.tasks);
      final seen = <TransferQueueEvent>[];
      final sub = composite.events.listen(seen.add);
      addTearDown(sub.cancel);
      inner.addTask();
      begin();
      await archives.tasks.createZip(
        roots: const ['/left/a.txt'],
        destinationDirectory: '/right',
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(3));
      expect(seen, everyElement(isA<TransferQueueTaskEvent>()));
    });

    test('enqueue and queue-level verbs stay inner-owned', () {
      final inner = FakeAppTransferQueue();
      final archives = _archives();
      addTearDown(() => _disposeArchives(archives.tasks, archives.jobs));
      final composite = CompositeAppTransferQueue(inner, tasks, archives.tasks);
      composite.enqueue(_spec());
      expect(inner.enqueuedSpecs, hasLength(1));
      composite.pauseQueue();
      expect(inner.pauseQueueCalls, 1);
      composite.resumeQueue();
      expect(inner.resumeQueueCalls, 1);
      expect(composite.isPaused, inner.isPaused);
    });

    test('archive verbs route by ownership and expose presentation', () async {
      final inner = FakeAppTransferQueue();
      final archives = _archives();
      addTearDown(() => _disposeArchives(archives.tasks, archives.jobs));
      final composite = CompositeAppTransferQueue(inner, tasks, archives.tasks);
      final task = await archives.tasks.extractZip(
        archivePath: '/left/a.zip',
        destinationDirectory: '/right',
      );
      final job = archives.jobs.single;

      expect(composite.tasks, contains(task));
      expect(
        composite.presentationFor(task.id).kind,
        AppTaskKind.archiveExtract,
      );
      composite.pauseTask(task.id);
      composite.resumeTask(task.id);
      composite.cancelTask(task.id);
      expect(job.pauseCalls, 1);
      expect(job.resumeCalls, 1);
      expect(job.cancelCalls, 1);
      expect(inner.pauseTaskCalls, isEmpty);
      expect(inner.resumeTaskCalls, isEmpty);
      expect(inner.cancelTaskCalls, isEmpty);
      expect(composite.cancelItem(task.id, 'entry'), isFalse);
      expect(composite.moveTask(task.id), isFalse);
    });

    test('flush waits for archive cancellation cleanup', () async {
      final inner = FakeAppTransferQueue();
      final archives = _archives();
      addTearDown(() => _disposeArchives(archives.tasks, archives.jobs));
      final composite = CompositeAppTransferQueue(inner, tasks, archives.tasks);
      final task = await archives.tasks.createZip(
        roots: const ['/left/a.txt'],
        destinationDirectory: '/right',
      );
      final job = archives.jobs.single;
      composite.cancelTask(task.id);

      var flushed = false;
      final flush = composite.flushJournal().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(inner.flushJournalCalls, 1);
      expect(flushed, isFalse);
      job.fail(LocalArchiveErrorKind.cancelled);
      await flush;
      expect(flushed, isTrue);
    });

    test('flush waits for a settling sync run', () async {
      final inner = FakeAppTransferQueue();
      final archives = _archives();
      addTearDown(() => _disposeArchives(archives.tasks, archives.jobs));
      final composite = CompositeAppTransferQueue(inner, tasks, archives.tasks);
      final settling = Completer<void>();
      tasks.trackSettlingRun(settling.future);

      var flushed = false;
      final flush = composite.flushJournal().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);

      expect(inner.flushJournalCalls, 1);
      expect(flushed, isFalse);

      settling.complete();
      await flush;
      expect(flushed, isTrue);
    });
  });
}
