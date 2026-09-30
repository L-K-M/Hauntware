import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/app_transfer_queue.dart';
import 'package:poltergeist_app/services/archive_queue_tasks.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_local_archive_job.dart';

void main() {
  late ArchiveQueueTasks tasks;
  late List<FakeLocalArchiveJob> jobs;
  late List<({List<String> sources, String destination})> createCalls;
  late List<({String archive, String destination})> extractCalls;

  setUp(() {
    jobs = [];
    createCalls = [];
    extractCalls = [];
    tasks = ArchiveQueueTasks.forTesting(
      createZip:
          ({
            required List<String> sourcePaths,
            required String destinationPath,
          }) {
            createCalls.add((
              sources: sourcePaths,
              destination: destinationPath,
            ));
            final job = FakeLocalArchiveJob(
              operation: LocalArchiveOperation.createZip,
            );
            jobs.add(job);
            return job;
          },
      extractZip:
          ({required String archivePath, required String destinationPath}) {
            extractCalls.add((
              archive: archivePath,
              destination: destinationPath,
            ));
            final job = FakeLocalArchiveJob(
              operation: LocalArchiveOperation.extractZip,
            );
            jobs.add(job);
            return job;
          },
    );
  });

  tearDown(() async {
    for (final job in jobs) {
      if (!job.isDone) job.fail(LocalArchiveErrorKind.cancelled);
    }
    await tasks.dispose();
    for (final job in jobs) {
      await job.close();
    }
  });

  test(
    'maps create and extract requests to local archive destinations',
    () async {
      final create = await tasks.createZip(
        roots: const ['/work/report.txt'],
        destinationDirectory: '/work',
      );
      final extract = await tasks.extractZip(
        archivePath: '/downloads/bundle.zip',
        destinationDirectory: '/downloads',
      );

      expect(createCalls.single.sources, ['/work/report.txt']);
      expect(createCalls.single.destination, '/work/report.txt.zip');
      expect(extractCalls.single.archive, '/downloads/bundle.zip');
      expect(extractCalls.single.destination, '/downloads/bundle');
      expect(create.destinationDir, '/work');
      expect(extract.destinationDir, '/downloads');
      expect(extract.spec.destinationDir, '/downloads');
      expect(create.operation, TransferOperation.copy);
      expect(create.source, const LocalFsLocation());
      expect(create.destination, const LocalFsLocation());
      expect(tasks.presentationFor(create.id)?.kind, AppTaskKind.archiveCreate);
      expect(
        tasks.presentationFor(extract.id)?.kind,
        AppTaskKind.archiveExtract,
      );
      expect(tasks.presentationFor(create.id)?.canPauseAcrossRestart, isFalse);
      expect(
        tasks.presentationFor(create.id)?.supports(AppTaskCapability.reveal),
        isTrue,
      );
      expect(
        tasks
            .presentationFor(create.id)
            ?.supports(AppTaskCapability.cancelItem),
        isFalse,
      );
    },
  );

  test('multiple roots use the default Archive.zip name', () async {
    await tasks.createZip(
      roots: const ['/work/a', '/work/b'],
      destinationDirectory: '/exports',
    );

    expect(createCalls.single.destination, '/exports/Archive.zip');
  });

  test('mirrors progress, entry rows, and completion events', () async {
    final events = <TransferQueueEvent>[];
    final subscription = tasks.events.listen(events.add);
    addTearDown(subscription.cancel);
    final task = await tasks.createZip(
      roots: const ['/work/folder'],
      destinationDirectory: '/exports',
    );
    final job = jobs.single;

    job.emit(
      phase: LocalArchivePhase.compressing,
      completedEntries: 0,
      totalEntries: 2,
      processedBytes: 4,
      totalBytes: 12,
      entryName: 'folder/a.txt',
      entryIsDirectory: false,
      entryProcessedBytes: 4,
      entryTotalBytes: 8,
    );
    job.emit(
      phase: LocalArchivePhase.compressing,
      completedEntries: 1,
      totalEntries: 2,
      processedBytes: 8,
      totalBytes: 12,
      entryName: 'folder/a.txt',
      entryIsDirectory: false,
      entryProcessedBytes: 8,
      entryTotalBytes: 8,
    );
    job.emit(
      phase: LocalArchivePhase.compressing,
      completedEntries: 2,
      totalEntries: 2,
      processedBytes: 12,
      totalBytes: 12,
      entryName: 'folder/empty',
      entryIsDirectory: true,
    );

    expect(task.state, TransferTaskState.running);
    expect(task.scanComplete, isTrue);
    expect(task.items, hasLength(2));
    expect(task.items.first.sourcePath, 'folder/a.txt');
    expect(task.items.first.size, 8);
    expect(task.items.first.transferredBytes, 8);
    expect(task.items.first.state, TransferItemState.completed);
    expect(task.items.first.destinationPath, '/exports/folder.zip');
    expect(task.items.last.isDirectory, isTrue);
    expect(task.items.last.destinationPath, '/exports/folder.zip');
    expect(task.items.last.state, TransferItemState.completed);
    expect(task.completedFiles, 2);
    expect(task.transferredBytes, 12);

    job.succeed(
      requestedDestinationPath: '/exports/folder.zip',
      entries: 2,
      uncompressedBytes: 12,
    );
    await job.done;
    await Future<void>.delayed(Duration.zero);

    expect(task.state, TransferTaskState.completed);
    expect(events.whereType<TransferQueueProgressEvent>(), hasLength(3));
    expect(
      events.whereType<TransferQueueItemEvent>().map((event) => event.state),
      containsAll([TransferItemState.active, TransferItemState.completed]),
    );
    expect(
      events.whereType<TransferQueueTaskEvent>().last.state,
      TransferTaskState.completed,
    );
  });

  test(
    'extract reveals its parent live then rebases after Keep Both',
    () async {
      final task = await tasks.extractZip(
        archivePath: '/downloads/bundle.zip',
        destinationDirectory: '/downloads',
      );
      final job = jobs.single;
      job.emit(
        phase: LocalArchivePhase.extracting,
        completedEntries: 0,
        totalEntries: 1,
        processedBytes: 2,
        totalBytes: 8,
        entryName: 'docs/readme.txt',
        entryIsDirectory: false,
        entryProcessedBytes: 2,
        entryTotalBytes: 8,
      );

      // Core stages the output under a hidden name, so live Reveal stays on the
      // existing parent until the atomic commit publishes the output folder.
      expect(task.destinationDir, '/downloads');
      expect(
        task.items.single.destinationPath,
        '/downloads/bundle/docs/readme.txt',
      );

      job.succeed(
        requestedDestinationPath: '/downloads/bundle',
        destinationPath: '/downloads/bundle (2)',
        entries: 1,
        uncompressedBytes: 8,
      );
      await Future<void>.delayed(Duration.zero);

      expect(task.destinationDir, '/downloads/bundle (2)');
      expect(task.spec.destinationDir, '/downloads/bundle (2)');
      expect(
        task.items.single.destinationPath,
        '/downloads/bundle (2)/docs/readme.txt',
      );
    },
  );

  test('create entry paths follow the final Keep Both ZIP', () async {
    final task = await tasks.createZip(
      roots: const ['/work/folder'],
      destinationDirectory: '/exports',
    );
    final job = jobs.single;
    job.emit(
      phase: LocalArchivePhase.compressing,
      completedEntries: 0,
      totalEntries: 1,
      processedBytes: 2,
      totalBytes: 8,
      entryName: 'folder/a.txt',
      entryIsDirectory: false,
      entryProcessedBytes: 2,
      entryTotalBytes: 8,
    );

    expect(task.destinationDir, '/exports');
    expect(task.items.single.destinationPath, '/exports/folder.zip');

    job.succeed(
      requestedDestinationPath: '/exports/folder.zip',
      destinationPath: '/exports/folder (2).zip',
      entries: 1,
      uncompressedBytes: 8,
    );
    await Future<void>.delayed(Duration.zero);

    expect(task.destinationDir, '/exports');
    expect(task.spec.destinationDir, '/exports');
    expect(task.items.single.destinationPath, '/exports/folder (2).zip');
  });

  test(
    'pause resumes and cancellation cleanup waits for job completion',
    () async {
      final task = await tasks.extractZip(
        archivePath: '/downloads/bundle.zip',
        destinationDirectory: '/downloads',
      );
      final job = jobs.single;

      tasks.pause(task.id);
      expect(job.pauseCalls, 1);
      expect(task.state, TransferTaskState.paused);
      tasks.resume(task.id);
      expect(job.resumeCalls, 1);
      expect(task.state, TransferTaskState.scanning);

      tasks.cancel(task.id);
      expect(job.cancelCalls, 1);
      var cleanupFinished = false;
      final cleanup = tasks.waitForCancellationCleanup().then(
        (_) => cleanupFinished = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(cleanupFinished, isFalse);
      expect(task.isTerminal, isFalse);

      job.fail(LocalArchiveErrorKind.cancelled);
      await cleanup;
      expect(task.state, TransferTaskState.cancelled);
    },
  );

  test('retry starts from scratch on the same task row', () async {
    final task = await tasks.createZip(
      roots: const ['/work/a'],
      destinationDirectory: '/exports',
    );
    jobs.single.fail();
    await Future<void>.delayed(Duration.zero);
    expect(task.state, TransferTaskState.failed);
    expect(tasks.canRetry(task.id), isTrue);

    expect(tasks.retry(task.id), isTrue);
    expect(jobs, hasLength(2));
    expect(task.state, TransferTaskState.scanning);
    expect(task.items, isEmpty);
    jobs.last.succeed(
      requestedDestinationPath: '/exports/a.zip',
      entries: 1,
      uncompressedBytes: 5,
    );
    await Future<void>.delayed(Duration.zero);

    expect(task.state, TransferTaskState.completed);
    expect(tasks.remove(task.id), isTrue);
    expect(tasks.tasks, isEmpty);
  });

  test('rowless archive failure has no failed item count', () async {
    final task = await tasks.extractZip(
      archivePath: '/downloads/unsafe.zip',
      destinationDirectory: '/downloads',
    );

    jobs.single.fail(LocalArchiveErrorKind.unsafeEntry);
    await Future<void>.delayed(Duration.zero);

    expect(task.state, TransferTaskState.failed);
    expect(task.items, isEmpty);
    expect(task.failedItems, 0);
  });

  test('failure count comes from failed entry rows', () async {
    final task = await tasks.createZip(
      roots: const ['/work/folder'],
      destinationDirectory: '/exports',
    );
    final job = jobs.single;
    job.emit(
      phase: LocalArchivePhase.compressing,
      completedEntries: 0,
      totalEntries: 1,
      processedBytes: 2,
      totalBytes: 8,
      entryName: 'folder/a.txt',
      entryIsDirectory: false,
      entryProcessedBytes: 2,
      entryTotalBytes: 8,
    );

    job.fail();
    await Future<void>.delayed(Duration.zero);

    expect(task.items.single.state, TransferItemState.failed);
    expect(task.failedItems, 1);
  });

  test('failure after completed entries has no failed item count', () async {
    final task = await tasks.createZip(
      roots: const ['/work/folder'],
      destinationDirectory: '/exports',
    );
    final job = jobs.single;
    job.emit(
      phase: LocalArchivePhase.committing,
      completedEntries: 1,
      totalEntries: 1,
      processedBytes: 8,
      totalBytes: 8,
      entryName: 'folder/a.txt',
      entryIsDirectory: false,
      entryProcessedBytes: 8,
      entryTotalBytes: 8,
    );

    job.fail();
    await Future<void>.delayed(Duration.zero);

    expect(task.items.single.state, TransferItemState.completed);
    expect(task.failedItems, 0);
  });

  test('failure before a job starts has no failed item count', () async {
    final startFailureTasks = ArchiveQueueTasks.forTesting(
      createZip:
          ({
            required List<String> sourcePaths,
            required String destinationPath,
          }) => throw StateError('cannot start'),
      extractZip:
          ({required String archivePath, required String destinationPath}) =>
              throw StateError('cannot start'),
    );
    addTearDown(startFailureTasks.dispose);

    final task = await startFailureTasks.createZip(
      roots: const ['/work/a.txt'],
      destinationDirectory: '/exports',
    );

    expect(task.state, TransferTaskState.failed);
    expect(task.items, isEmpty);
    expect(task.failedItems, 0);
  });
}
