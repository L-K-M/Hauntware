// Deterministic contract tests for the engine-side transfer queue
// (packages/poltergeist_core/lib/src/transfer/), M4's first slice.
//
// No sockets: remote endpoints are FakeTreeFileSystems behind a
// FakeQueueConnectionManager whose leases mirror the real pool's
// leaseTransferChannel contract (block at capacity, deterministic
// release); the local endpoint is the production LocalFileSystem over a
// real temp dir, which exercises the §2.3 safety walk for free. Every
// gate is a Completer, so nothing depends on wall-clock timing.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

TransferTaskSpec copySpec({
  required FsLocation source,
  required FsLocation destination,
  required List<String> rootPaths,
  required String destinationDir,
  ConflictResolution files = ConflictResolution.skip,
  ConflictResolution folders = ConflictResolution.merge,
  TransferOperation operation = TransferOperation.copy,
}) => TransferTaskSpec(
  source: source,
  destination: destination,
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(files: files, folders: folders),
  operation: operation,
);

void main() {
  late Directory tempDir;
  late Directory localSrc;
  late FakeTreeFileSystem s1;
  late FakeTreeFileSystem s2;
  late FakeQueueConnectionManager connections;
  late TransferQueue queue;
  late List<TransferQueueEvent> events;

  // Every queue the harness creates — several tests replace the setUp
  // queue mid-test; tearDown disposes them all so none leaks its event
  // sink or pause completers.
  final createdQueues = <TransferQueue>[];

  TransferQueue newQueue({
    int? leaseCap,
    int? maxInFlightFiles,
    ServerTransferLimits serverTransferLimits = ServerTransferLimits.none,
    int? pipeBufferBytes,
    int taskRetryLimit = 5,
    bool Function(FsLocation)? isCaseInsensitiveDestination,
    Duration nameProbeCleanupTimeout = const Duration(seconds: 5),
  }) {
    connections.leaseCap = leaseCap;
    final created = TransferQueue(
      connections: connections,
      poolPolicy: PoolPolicy(taskRetryLimit: taskRetryLimit),
      maxInFlightFiles: maxInFlightFiles ?? maxGlobalInFlightTransfers,
      serverTransferLimits: serverTransferLimits,
      pipeBufferBytes: pipeBufferBytes ?? 4 * 1024 * 1024,
      isCaseInsensitiveDestination: isCaseInsensitiveDestination,
      nameProbeCleanupTimeout: nameProbeCleanupTimeout,
    );
    createdQueues.add(created);
    return created;
  }

  TransferTask enqueue(TransferTaskSpec spec) => queue.enqueue(spec);

  setUp(() async {
    // Resolve the fixture root: on macOS, systemTemp lives under /var,
    // a symlink to /private/var — the destination-side safety walk must
    // see the real path or it fails on the rule, not a bug.
    final temp = await Directory.systemTemp.createTemp('poltergeist-tq-');
    tempDir = Directory(temp.resolveSymbolicLinksSync());
    localSrc = Directory('${tempDir.path}/src')..createSync();
    s1 = FakeTreeFileSystem()..addDirectory('/dst');
    s2 = FakeTreeFileSystem()..addDirectory('/dst');
    connections = FakeQueueConnectionManager({'s1': s1, 's2': s2});
    queue = newQueue();
    events = [];
    queue.events.listen(events.add);
  });

  tearDown(() async {
    for (final created in createdQueues) {
      try {
        await created.dispose();
      } catch (_) {
        // A dispose that throws already fails this test; don't let it
        // leak the remaining queues or skip the temp-dir cleanup.
      }
    }
    createdQueues.clear();
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // Best effort: a spawned process may still hold a handle.
    }
  });

  File writeLocal(String relative, List<int> bytes) {
    final file = File('${localSrc.path}/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  group('task model', () {
    test('file-field merge normalizes to ask', () {
      final policy = ResolvedConflictPolicy(files: ConflictResolution.merge);
      expect(policy.files, ConflictResolution.ask);
    });

    test('enqueue dedupes roots and drops nested roots', () async {
      final file = writeLocal('a.txt', [1]);
      final task = enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [
            localSrc.path,
            file.path,
            '${localSrc.path}/',
            localSrc.path,
          ],
          destinationDir: '/dst',
        ),
      );
      // The directory root swallows the nested file root; duplicates and
      // the trailing-slash spelling collapse to one.
      expect(task.rootPaths, [localSrc.path]);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
    });

    test('enqueue rejects an empty root list', () {
      expect(
        () => enqueue(
          copySpec(
            source: const LocalFsLocation(),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [],
            destinationDir: '/dst',
          ),
        ),
        throwsArgumentError,
      );
    });
  });

  group('scan-then-execute', () {
    test('single file local→remote lands bytes and releases leases',
        () async {
      final file = writeLocal('hello.txt', 'payload'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [file.path],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(task.scanComplete, isTrue);
      expect(task.completedFiles, 1);
      expect(task.totalBytes, 'payload'.codeUnits.length);
      expect(task.transferredBytes, 'payload'.codeUnits.length);
      expect(s1.fileBytes['/dst/hello.txt'], 'payload'.codeUnits);
      // Scan lease + dispatch lease, both released.
      expect(connections.leaseCalls, 2);
      expect(connections.activeLeases('s1'), 0);
      expect(connections.totalReleased, 2);
      final states = events
          .whereType<TransferQueueTaskEvent>()
          .map((e) => e.state)
          .toList();
      expect(states.first, TransferTaskState.queued);
      expect(states, contains(TransferTaskState.scanning));
      expect(states.last, TransferTaskState.completed);
    });

    test('directory tree remote→remote: parents-first mkdir, symlink skip',
        () async {
      s1.addDirectory('/src/dir/sub');
      s1.addFile('/src/dir/a.txt', 'aaa'.codeUnits);
      s1.addFile('/src/dir/sub/b.txt', 'bb'.codeUnits);
      s1.addSymlink('/src/dir/link');

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/dir/a.txt'], 'aaa'.codeUnits);
      expect(s2.fileBytes['/dst/dir/sub/b.txt'], 'bb'.codeUnits);
      expect(task.plan!.skippedSymlinks, 1);
      // Parents first: dir before sub, and both before any upload into
      // them (scan order is the append order).
      final mkdirs = s2.calls.where((c) => c.startsWith('mkdir:')).toList();
      expect(mkdirs, containsAllInOrder(['mkdir:/dst/dir', 'mkdir:/dst/dir/sub']));
      final uploads = s2.calls.where((c) => c.startsWith('upload:')).toList();
      expect(
        uploads,
        containsAllInOrder(['upload:/dst/dir/a.txt', 'upload:/dst/dir/sub/b.txt']),
      );
    });

    test('first bytes flow before the scan completes', () async {
      s1.addDirectory('/src');
      s1.addFile('/src/first.txt', 'early'.codeUnits);
      s1.addDirectory('/src/slow');
      s1.addFile('/src/slow/late.txt', 'late'.codeUnits);
      // Hold the slow subtree's listing: the scan is unfinished while the
      // root listing's file already dispatches.
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/slow' ? gate : null;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );

      // The root listing itself carries the pending dir; first.txt can
      // complete while the scan is still parked on /src/slow.
      await pumpUntil(
        () => s2.fileBytes.containsKey('/dst/src/first.txt'),
        reason: 'first file never landed while scan held',
      );
      expect(task.scanComplete, isFalse);
      expect(task.state, isNot(TransferTaskState.completed));

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/src/slow/late.txt'], 'late'.codeUnits);
    });

    test('growing totals: totalBytes is a floor until the scan closes',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/a.bin', List.filled(10, 1));
      s1.addDirectory('/src/more');
      s1.addFile('/src/more/b.bin', List.filled(20, 2));
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/more' ? gate : null;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => (task.totalBytes ?? 0) > 0);
      // Only a.bin is discovered so far: the floor is 10 of a final 30.
      expect(task.totalBytes, 10);
      expect(task.scanComplete, isFalse);

      gate.complete();
      await awaitTaskDone(task);
      expect(task.totalBytes, 30);
      expect(task.transferredBytes, 30);
    });

    test('remote→local tree materializes under the local destination dir',
        () async {
      final localDest = Directory('${tempDir.path}/local-dest')
        ..createSync();
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/a.txt', 'aaa'.codeUnits);
      s1.addFile('/src/dir/deep/b.bin', [1, 2, 3]);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const LocalFsLocation(),
          rootPaths: ['/src/dir'],
          destinationDir: localDest.path,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 2);
      expect(
        File('${localDest.path}/dir/a.txt').readAsBytesSync(),
        'aaa'.codeUnits,
      );
      expect(
        File('${localDest.path}/dir/deep/b.bin').readAsBytesSync(),
        [1, 2, 3],
      );
      // Local endpoints hold no channel lease — only the source did.
      expect(connections.activeLeases('s1'), 0);
      expect(connections.maxActiveLeases('s1'), greaterThan(0));
      expect(connections.filesystems.containsKey('local'), isFalse);
    });

    test('scan-time existing hint is populated but never trusted',
        () async {
      s1.addFile('/src/dup.txt', 'new-bytes'.codeUnits);
      s2.addFile('/dst/dup.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dup.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.plan!.files.single.existing, isNotNull);
      expect(s2.fileBytes['/dst/dup.txt'], 'new-bytes'.codeUnits);
    });
  });

  group('concurrency', () {
    test('global cap: never more than maxInFlightFiles active', () async {
      queue = newQueue(maxInFlightFiles: 3);
      events = [];
      queue.events.listen(events.add);
      for (var i = 0; i < 8; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      // Every download stalls at its first chunk until released.
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => s1.activeDownloads == 3,
        reason: 'expected 3 in-flight downloads',
      );
      // One pump past the cap: nothing else may start.
      await pump();
      expect(s1.activeDownloads, 3);
      expect(
        task.items.where((i) => i.state == TransferItemState.active).length,
        3,
      );

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 8);
      expect(s1.maxActiveDownloads, 3);
    });

    test('per-server lease capacity blocks admission and frees on release',
        () async {
      queue = newQueue(leaseCap: 2);
      for (var i = 0; i < 4; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      // While the scan holds one s1 lease only one dispatch fits; once it
      // finishes, two downloads may hold leases — never three.
      await pumpUntil(
        () => task.scanComplete && s1.activeDownloads == 2,
        reason: 'two dispatches should hold the two free leases',
      );
      await pump();
      expect(s1.activeDownloads, lessThanOrEqualTo(2));
      expect(connections.maxActiveLeases('s1'), lessThanOrEqualTo(2));

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 4);
      expect(connections.activeLeases('s1'), 0);
      expect(connections.activeLeases('s2'), 0);
    });

    test('cancel while a lease call is blocked unwinds without a wedge',
        () async {
      connections.leaseGate = Completer<void>(); // never completed
      final file = writeLocal('x.txt', [1, 2, 3]);
      final task = enqueue(
        copySpec(
          source: const LocalFsLocation(),
          destination: const ServerFsLocation('s1'),
          rootPaths: [file.path],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => connections.leaseCalls > 0);
      queue.cancelTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.cancelled);
      // The pending lease future is released when it eventually lands —
      // here it never does, and nothing waits on it.
      connections.leaseGate!.complete();
      await pump();
    });
  });

  // 00 D37: the user's per-server caps on files in flight.
  group('per-server caps', () {
    TransferTaskSpec download(String server, String root) => copySpec(
      source: ServerFsLocation(server),
      destination: const LocalFsLocation(),
      rootPaths: [root],
      destinationDir: tempDir.path,
    );

    test('a cap bounds that server\'s files in flight', () async {
      queue = newQueue(
        serverTransferLimits: const ServerTransferLimits(
          perServer: TransferConcurrency.fixed(2),
        ),
      );
      for (var i = 0; i < 6; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(download('s1', '/src'));
      await pumpUntil(
        () => task.scanComplete && s1.activeDownloads == 2,
        reason: 'the cap should admit two downloads',
      );
      await pump();
      expect(s1.activeDownloads, 2);

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 6);
      expect(s1.maxActiveDownloads, 2);
    });

    test('a capped server is passed over, not waited on', () async {
      // Two global slots: s1's cap takes one, and the other must go to
      // the next task in line instead of sitting behind s1.
      queue = newQueue(
        maxInFlightFiles: 2,
        serverTransferLimits: const ServerTransferLimits(
          overrides: {'s1': TransferConcurrency.fixed(1)},
        ),
      );
      for (var i = 0; i < 4; i++) {
        s1.addFile('/a/f$i.bin', List.filled(4, i));
        s2.addFile('/b/g$i.bin', List.filled(4, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final first = enqueue(download('s1', '/a'));
      final second = enqueue(download('s2', '/b'));
      await awaitTaskDone(second);
      expect(second.state, TransferTaskState.completed);
      expect(second.completedFiles, 4);
      // The earlier task is still waiting on its one slot at a time.
      expect(first.isTerminal, isFalse);
      expect(s1.activeDownloads, 1);

      gate.complete();
      await awaitTaskDone(first);
      expect(first.state, TransferTaskState.completed);
      expect(s1.maxActiveDownloads, 1);
    });

    test('a server-to-server file counts against both servers', () async {
      queue = newQueue(
        serverTransferLimits: const ServerTransferLimits(
          overrides: {'s2': TransferConcurrency.fixed(1)},
        ),
      );
      for (var i = 0; i < 3; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      // Only the destination is capped; the source side still moves one
      // file at a time because every file lands on s2.
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => task.scanComplete && s1.activeDownloads == 1);
      await pump();
      expect(s1.activeDownloads, 1);

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.maxActiveDownloads, 1);
    });

    test('a copy within one server counts once against its cap', () async {
      queue = newQueue(
        serverTransferLimits: const ServerTransferLimits(
          perServer: TransferConcurrency.fixed(2),
        ),
      );
      for (var i = 0; i < 4; i++) {
        s1.addFile('/src/f$i.bin', List.filled(4, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      // Counted once per side, a cap of 2 would admit only one of these.
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => task.scanComplete && s1.activeDownloads == 2);
      await pump();
      expect(s1.activeDownloads, 2);

      gate.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.maxActiveDownloads, 2);
    });

    test(
      'a raised cap dispatches at once; a lowered one stops nothing',
      () async {
        queue = newQueue(
          serverTransferLimits: const ServerTransferLimits(
            perServer: TransferConcurrency.fixed(1),
          ),
        );
        final gates = <String, Completer<void>>{};
        for (var i = 0; i < 5; i++) {
          s1.addFile('/src/f$i.bin', List.filled(4, i));
          gates['/src/f$i.bin'] = Completer<void>();
        }
        s1.downloadGate = (path) => gates[path];

        final task = enqueue(download('s1', '/src'));
        await pumpUntil(() => task.scanComplete && s1.activeDownloads == 1);

        queue.serverTransferLimits = const ServerTransferLimits(
          perServer: TransferConcurrency.fixed(3),
        );
        await pumpUntil(
          () => s1.activeDownloads == 3,
          reason: 'raising the cap should dispatch the waiting files',
        );

        // Lowering it cancels nothing: the three keep moving, and the next
        // file waits until fewer than one is left.
        queue.serverTransferLimits = const ServerTransferLimits(
          perServer: TransferConcurrency.fixed(1),
        );
        await pump();
        expect(s1.activeDownloads, 3);
        expect(
          task.items.where((i) => i.state == TransferItemState.cancelled),
          isEmpty,
        );
        final active = [
          for (final item in task.items)
            if (item.state == TransferItemState.active) item.sourcePath,
        ];
        expect(active, hasLength(3));
        gates[active[0]]!.complete();
        gates[active[1]]!.complete();
        await pumpUntil(() => s1.activeDownloads == 1);
        await pump();
        expect(s1.activeDownloads, 1, reason: 'one still in flight: no room');

        for (final gate in gates.values) {
          if (!gate.isCompleted) gate.complete();
        }
        await awaitTaskDone(task);
        expect(task.state, TransferTaskState.completed);
        expect(task.completedFiles, 5);
      },
    );

    test('an override wins over the default, automatic included', () {
      const limits = ServerTransferLimits(
        perServer: TransferConcurrency.fixed(2),
        overrides: {
          'fast': TransferConcurrency.automatic(),
          'fussy': TransferConcurrency.fixed(1),
        },
      );
      expect(limits.filesFor('other'), 2);
      expect(limits.filesFor('fast'), isNull);
      expect(limits.filesFor('fussy'), 1);
      expect(ServerTransferLimits.none.filesFor('other'), isNull);
    });

    test('an edit\'s checkout is never held back by the cap', () async {
      queue = newQueue(
        serverTransferLimits: const ServerTransferLimits(
          perServer: TransferConcurrency.fixed(1),
        ),
      );
      s1.addFile('/src/big.bin', List.filled(4, 1));
      s1.addFile('/r/edit.txt', List.filled(16, 3));
      final gate = Completer<void>();
      s1.downloadGate = (path) => path == '/src/big.bin' ? gate : null;

      final transfer = enqueue(download('s1', '/src'));
      await pumpUntil(() => s1.activeDownloads == 1);
      final checkout = queue.enqueueManagedCheckout(
        ManagedCheckoutSpec(
          checkoutId: 'edit-1',
          serverId: 's1',
          remotePath: '/r/edit.txt',
          localPath: '${tempDir.path}/edit.txt',
          direction: ManagedCheckoutDirection.download,
          expectedSize: 16,
        ),
      );
      await awaitTaskDone(checkout);
      expect(checkout.state, TransferTaskState.completed);
      expect(transfer.isTerminal, isFalse);

      gate.complete();
      await awaitTaskDone(transfer);
      expect(transfer.state, TransferTaskState.completed);
    });

    test('a preview\'s download is never held back by the cap', () async {
      queue = newQueue(
        serverTransferLimits: const ServerTransferLimits(
          perServer: TransferConcurrency.fixed(1),
        ),
      );
      s1.addFile('/src/big.bin', List.filled(4, 1));
      s1.addFile('/r/photo.jpg', List.filled(8, 5));
      final gate = Completer<void>();
      s1.downloadGate = (path) => path == '/src/big.bin' ? gate : null;

      final transfer = enqueue(download('s1', '/src'));
      await pumpUntil(() => s1.activeDownloads == 1);
      final entry = await queue.produceLocalCopy(
        const ServerFsLocation('s1'),
        '/r/photo.jpg',
        destinationPath: '${tempDir.path}/photo.jpg',
      );
      expect(entry.size, 8);
      expect(transfer.isTerminal, isFalse);

      gate.complete();
      await awaitTaskDone(transfer);
      expect(transfer.state, TransferTaskState.completed);
    });
  });

  group('pause and cancel', () {
    test('queue pause stops new dispatch; in-flight completes; resume drains',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/f0.bin', List.filled(4, 0));
      s1.addDirectory('/src/rest');
      s1.addFile('/src/rest/f1.bin', List.filled(4, 1));
      s1.addFile('/src/rest/f2.bin', List.filled(4, 2));
      // Hold the subtree listing: f1/f2 get discovered during the pause.
      final listGate = Completer<void>();
      s1.listGate = (path) => path == '/src/rest' ? listGate : null;
      final downloadGates = {
        for (final p in ['/src/f0.bin', '/src/rest/f1.bin', '/src/rest/f2.bin'])
          p: Completer<void>(),
      };
      s1.downloadGate = (path) => downloadGates[path];

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      queue.pauseQueue();

      // The scan keeps discovering while paused; the new files become
      // eligible but cannot dispatch.
      listGate.complete();
      await pumpUntil(() => task.scanComplete);
      expect(task.items.length, greaterThan(3));

      // The in-flight f0 still completes — pause stops admission, not
      // running VFS work (03 §4.4).
      downloadGates['/src/f0.bin']!.complete();
      await pumpUntil(
        () => s2.fileBytes.containsKey('/dst/src/f0.bin'),
        reason: 'in-flight download should complete during queue pause',
      );
      await pump();
      expect(s2.fileBytes.containsKey('/dst/src/rest/f1.bin'), isFalse);
      expect(s1.activeDownloads, 0);

      queue.resumeQueue();
      await pumpUntil(() => s1.activeDownloads == 2);
      downloadGates['/src/rest/f1.bin']!.complete();
      downloadGates['/src/rest/f2.bin']!.complete();
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 3);
      expect(s2.fileBytes['/dst/src/rest/f1.bin'], List.filled(4, 1));
      expect(s2.fileBytes['/dst/src/rest/f2.bin'], List.filled(4, 2));
    });

    test('cancelling a paused managed checkout settles it without an '
        'unhandled error', () async {
      // The hop parks on its per-task pause outside any attempt, so the
      // cancel that ends the wait has already settled the item and the
      // task: the hop must unwind, not throw into the unawaited runner.
      s1.addFile('/r/edit.txt', List.filled(16, 3));
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;
      final task = queue.enqueueManagedCheckout(
        ManagedCheckoutSpec(
          checkoutId: 'edit-1',
          serverId: 's1',
          remotePath: '/r/edit.txt',
          localPath: '${tempDir.path}/edit.txt',
          direction: ManagedCheckoutDirection.download,
          expectedSize: 16,
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      queue.pauseTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.paused);
      // Let the parked fake read return so the dead attempt unwinds and
      // the hop reaches its pause wait.
      gate.complete();
      final item = task.items.single;
      await pumpUntil(() => item.state == TransferItemState.pending);
      queue.cancelTask(task.id);
      await awaitTaskDone(task);
      await pump();
      expect(task.state, TransferTaskState.cancelled);
      expect(item.state, TransferItemState.cancelled);
    });

    test('task pause cancels the attempt; resume restarts the item', () async {
      s1.addFile('/src/big.bin', List.filled(64, 7));
      s1.downloadChunkSize = 8;
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/big.bin'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      queue.pauseTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.paused);
      // Let the parked fake read return so its generator can unwind.
      gate.complete();
      final item = task.items.single;
      await pumpUntil(() => item.state == TransferItemState.pending);
      expect(item.transferredBytes, 0);
      expect(task.transferredBytes, 0);
      expect(s1.downloadCalls, 1);

      queue.resumeTask(task.id);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // The item restarted from byte zero — a second download call.
      expect(s1.downloadCalls, greaterThan(1));
      expect(s2.fileBytes['/dst/big.bin'], List.filled(64, 7));
    });

    test('task cancel stops new work, drains in-flight, releases leases',
        () async {
      for (var i = 0; i < 4; i++) {
        s1.addFile('/src/f$i.bin', List.filled(8, i));
      }
      final gate = Completer<void>();
      s1.downloadGate = (_) => gate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads > 0);
      queue.cancelTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.cancelled);
      expect(
        task.items.every(
          (i) =>
              i.state == TransferItemState.cancelled ||
              i.state == TransferItemState.completed,
        ),
        isTrue,
      );
      // Release the parked fake read so the in-flight attempt unwinds
      // through the cancelled attempt token.
      gate.complete();
      await pumpUntil(
        () =>
            connections.activeLeases('s1') == 0 &&
            connections.activeLeases('s2') == 0,
        reason: 'cancelled task never released its leases',
      );
      // No partial commit landed on the destination.
      expect(s2.fileBytes, isEmpty);
    });

    test('cancel during scan stops the walk without wedging', () async {
      s1.addDirectory('/src');
      s1.addDirectory('/src/held');
      s1.addFile('/src/held/x.txt', [1]);
      final gate = Completer<void>();
      s1.listGate = (path) => path == '/src/held' ? gate : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => task.state == TransferTaskState.scanning);
      queue.cancelTask(task.id);
      await pumpUntil(() => task.state == TransferTaskState.cancelled);
      // The scan is blocked inside listDirectory — the pinned reality is
      // that it unwinds when the call returns; nothing wedges on cancel.
      gate.complete();
      await pumpUntil(
        () => connections.activeLeases('s1') == 0,
        reason: 'cancelled scan never released its leases',
      );
    });
  });

  group('conflict policy', () {
    test('skip leaves the destination untouched', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.skip,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.items.single.state, TransferItemState.skipped);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('replace overwrites through expectedTarget', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
    });

    test('replaceIfNewer replaces only when the source is newer', () async {
      final older = DateTime.fromMillisecondsSinceEpoch(1000000);
      final newer = DateTime.fromMillisecondsSinceEpoch(2000000);
      s1.addFile('/src/new.txt', 'new'.codeUnits, modifiedAt: newer);
      s1.addFile('/src/old.txt', 'oldsrc'.codeUnits, modifiedAt: older);
      s2.addFile('/dst/new.txt', 'x'.codeUnits, modifiedAt: older);
      s2.addFile('/dst/old.txt', 'y'.codeUnits, modifiedAt: newer);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/new.txt', '/src/old.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replaceIfNewer,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/new.txt'], 'new'.codeUnits);
      expect(s2.fileBytes['/dst/old.txt'], 'y'.codeUnits);
      final bySource = {
        for (final i in task.items) i.sourcePath: i,
      };
      expect(bySource['/src/new.txt']!.state, TransferItemState.completed);
      expect(bySource['/src/old.txt']!.state, TransferItemState.skipped);
    });

    test('keepBoth lands the numbered name and preserves the original',
        () async {
      s1.addFile('/src/report.pdf', 'new'.codeUnits);
      s2.addFile('/dst/report.pdf', 'old'.codeUnits);
      s2.addFile('/dst/report (2).pdf', 'older'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/report.pdf'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/report.pdf'], 'old'.codeUnits);
      expect(s2.fileBytes['/dst/report (2).pdf'], 'older'.codeUnits);
      expect(s2.fileBytes['/dst/report (3).pdf'], 'new'.codeUnits);
      expect(task.items.single.destinationPath, '/dst/report (3).pdf');
    });

    test('keepBoth reserves its resolved name against later sources', () async {
      queue = newQueue(maxInFlightFiles: 1);
      final discoveryGate = Completer<void>();
      s1.addFile('/src/report.pdf', 'renamed'.codeUnits);
      s1.addFile('/src/report (2).pdf', 'literal'.codeUnits);
      s1.statGate = (path) =>
          path == '/src/report (2).pdf' ? discoveryGate : null;
      s2.addFile('/dst/report.pdf', 'original'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/report.pdf', '/src/report (2).pdf'],
          destinationDir: '/dst',
          files: ConflictResolution.ask,
          operation: TransferOperation.move,
        ),
      );
      await pumpUntil(
        () => queue.pendingConflicts.any(
          (conflict) => conflict.destinationPath == '/dst/report.pdf',
        ),
        reason: 'the base-name conflict never surfaced',
      );
      final renamed = task.items.singleWhere(
        (item) => item.sourcePath == '/src/report.pdf',
      );
      expect(
        queue.resolveConflict(task.id, renamed.id, ConflictResolution.keepBoth),
        isTrue,
      );
      await pumpUntil(
        () => renamed.state == TransferItemState.completed,
        reason: 'the keep-both commit never landed',
      );
      expect(s2.fileBytes['/dst/report (2).pdf'], 'renamed'.codeUnits);
      discoveryGate.complete();

      // A queue without task-output ownership offers Replace here and
      // lets the literal source erase the completed keep-both output.
      await pumpUntil(
        () =>
            task.isTerminal ||
            queue.pendingConflicts.any(
              (conflict) => conflict.destinationPath == '/dst/report (2).pdf',
            ),
        reason: 'the literal numbered source never settled',
      );
      if (!task.isTerminal) {
        final literal = task.items.singleWhere(
          (item) => item.sourcePath == '/src/report (2).pdf',
        );
        expect(
          queue.resolveConflict(
            task.id,
            literal.id,
            ConflictResolution.replace,
          ),
          isTrue,
        );
      }
      await awaitTaskDone(task);

      final literal = task.items.singleWhere(
        (item) => item.sourcePath == '/src/report (2).pdf',
      );
      expect(task.state, TransferTaskState.failed);
      expect(literal.state, TransferItemState.failed);
      expect(literal.failureKind, RemoteFileErrorKind.conflict);
      expect(queue.canRetryItem(task.id, literal.id), isFalse);
      expect(s2.fileBytes['/dst/report.pdf'], 'original'.codeUnits);
      expect(s2.fileBytes['/dst/report (2).pdf'], 'renamed'.codeUnits);
      expect(s1.fileBytes['/src/report (2).pdf'], 'literal'.codeUnits);
    });

    test('concurrent keepBoth tasks claim distinct resolved names', () async {
      final uploadGate = Completer<void>();
      s1.addFile('/a/report.pdf', 'first'.codeUnits);
      s1.addFile('/b/report (1).pdf', 'second'.codeUnits);
      s2.addFile('/dst/report.pdf', 'occupied'.codeUnits);
      s2.addFile('/dst/report (1).pdf', 'occupied'.codeUnits);
      s2.uploadGate = (_) => uploadGate;

      final first = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/a/report.pdf'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
          operation: TransferOperation.move,
        ),
      );
      final second = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/b/report (1).pdf'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
          operation: TransferOperation.move,
        ),
      );

      await pumpUntil(
        () => s2.uploadCalls == 2,
        reason: 'both keep-both commits did not reach the upload gate',
      );
      final inFlightDestinations = s2.calls
          .where((call) => call.startsWith('upload:'))
          .map((call) => call.substring('upload:'.length))
          .toList();
      uploadGate.complete();
      await Future.wait([awaitTaskDone(first), awaitTaskDone(second)]);

      expect(inFlightDestinations.toSet(), hasLength(2));
    });

    test('mid-scan retry preserves a moved keepBoth output claim', () async {
      queue = newQueue(maxInFlightFiles: 1, taskRetryLimit: 0);
      final discoveryGate = Completer<void>();
      final listGate = Completer<void>();
      s1.addFile('/a/report.pdf', 'first'.codeUnits);
      s1.addFile('/b/report (2).pdf', 'second'.codeUnits);
      s1.addDirectory('/blocked');
      s2.addFile('/dst/report.pdf', 'original'.codeUnits);
      s1.statGate = (path) =>
          path == '/b/report (2).pdf' ? discoveryGate : null;
      s1.downloadFailure = (path) => path == '/b/report (2).pdf'
          ? RemoteFileException(
              kind: RemoteFileErrorKind.other,
              operation: 'download',
              path: path,
              message: 'scripted first-pass failure',
            )
          : null;
      s1.listGate = (path) => path == '/blocked' ? listGate : null;
      s1.listFailure = (path) => path == '/blocked'
          ? RemoteFileException(
              kind: RemoteFileErrorKind.disconnected,
              operation: 'list',
              path: path,
              message: 'scripted mid-scan disconnect',
            )
          : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/a/report.pdf', '/b/report (2).pdf', '/blocked'],
          destinationDir: '/dst',
          files: ConflictResolution.ask,
          operation: TransferOperation.move,
        ),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the first pass did not park A',
      );
      final first = task.items.singleWhere(
        (item) => item.sourcePath == '/a/report.pdf',
      );
      expect(
        queue.resolveConflict(task.id, first.id, ConflictResolution.keepBoth),
        isTrue,
      );
      await pumpUntil(
        () => first.state == TransferItemState.completed,
        reason: 'the first source never moved to its numbered target',
      );
      expect(s1.entryAt('/a/report.pdf'), isNull);
      expect(s2.fileBytes['/dst/report (2).pdf'], 'first'.codeUnits);

      discoveryGate.complete();
      await pumpUntil(
        () => queue.pendingConflicts.any(
          (conflict) => conflict.destinationPath == '/dst/report (2).pdf',
        ),
        reason: 'the task-local collision never reached Ask',
      );
      final secondAttempt = task.items.singleWhere(
        (item) => item.sourcePath == '/b/report (2).pdf',
      );
      expect(
        queue.resolveConflict(
          task.id,
          secondAttempt.id,
          ConflictResolution.keepBoth,
        ),
        isTrue,
      );
      await pumpUntil(
        () => task.items.any(
          (item) =>
              item.sourcePath == '/b/report (2).pdf' &&
              item.state == TransferItemState.failed,
        ),
        reason: 'the later source never reached its scripted failure',
      );
      listGate.complete();
      await awaitTaskDone(task);
      expect(task.scanComplete, isFalse);

      s1.downloadFailure = null;
      s1.listFailure = null;
      s1.listGate = null;
      s1.statGate = null;
      expect(queue.retryTask(task.id), isTrue);
      await pumpUntil(
        () =>
            task.isTerminal ||
            queue.pendingConflicts.any(
              (conflict) => conflict.destinationPath == '/dst/report (2).pdf',
            ),
        reason: 'the retried literal source never settled',
      );
      if (!task.isTerminal) {
        final second = task.items.singleWhere(
          (item) => item.sourcePath == '/b/report (2).pdf',
        );
        expect(
          queue.resolveConflict(task.id, second.id, ConflictResolution.replace),
          isTrue,
        );
      }
      await awaitTaskDone(task);

      final second = task.items.singleWhere(
        (item) => item.sourcePath == '/b/report (2).pdf',
      );
      expect(second.state, TransferItemState.completed);
      expect(second.failureKind, isNull);
      expect(queue.canRetryItem(task.id, second.id), isFalse);
      expect(queue.canRetryTask(task.id), isFalse);
      expect(s2.fileBytes['/dst/report (2).pdf'], 'first'.codeUnits);
      expect(s2.fileBytes['/dst/report (3).pdf'], 'second'.codeUnits);
      expect(s1.entryAt('/b/report (2).pdf'), isNull);
    });

    test(
      'mid-scan Retry Task preserves a terminal destination collision',
      () async {
        queue = newQueue(maxInFlightFiles: 1, taskRetryLimit: 0);
        final discoveryGate = Completer<void>();
        final listGate = Completer<void>();
        s1.addFile('/a/report.pdf', 'first'.codeUnits);
        s1.addFile('/b/report (2).pdf', 'second'.codeUnits);
        s1.addDirectory('/blocked');
        s2.addFile('/dst/report.pdf', 'original'.codeUnits);
        s1.statGate = (path) =>
            path == '/b/report (2).pdf' ? discoveryGate : null;
        s1.listGate = (path) => path == '/blocked' ? listGate : null;
        s1.listFailure = (path) => path == '/blocked'
            ? RemoteFileException(
                kind: RemoteFileErrorKind.disconnected,
                operation: 'list',
                path: path,
                message: 'scripted mid-scan disconnect',
              )
            : null;
        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/a/report.pdf', '/b/report (2).pdf', '/blocked'],
            destinationDir: '/dst',
            files: ConflictResolution.ask,
          ),
        );
        await pumpUntil(
          () => queue.pendingConflicts.isNotEmpty,
          reason: 'the first source did not park on its base name',
        );
        final first = task.items.singleWhere(
          (item) => item.sourcePath == '/a/report.pdf',
        );
        expect(
          queue.resolveConflict(task.id, first.id, ConflictResolution.keepBoth),
          isTrue,
        );
        await pumpUntil(
          () => first.state == TransferItemState.completed,
          reason: 'the first source did not claim its numbered output',
        );

        discoveryGate.complete();
        await pumpUntil(
          () => queue.pendingConflicts.any(
            (conflict) => conflict.destinationPath == '/dst/report (2).pdf',
          ),
          reason: 'the task-local collision never reached Ask',
        );
        final second = task.items.singleWhere(
          (item) => item.sourcePath == '/b/report (2).pdf',
        );
        expect(
          queue.resolveConflict(task.id, second.id, ConflictResolution.replace),
          isTrue,
        );
        await pumpUntil(
          () =>
              second.failureRetryPolicy == TransferFailureRetryPolicy.terminal,
          reason: 'Replace did not refuse the task-owned output',
        );
        listGate.complete();
        await awaitTaskDone(task);
        expect(task.scanComplete, isFalse);

        s1.listFailure = null;
        s1.listGate = null;
        s1.statGate = null;
        final retryStates = <TransferItemState>[];
        final subscription = queue.events.listen((event) {
          if (event is TransferQueueItemEvent && event.itemId == second.id) {
            retryStates.add(event.state);
          }
        });
        expect(queue.retryTask(task.id), isTrue);
        await awaitTaskDone(task);
        await subscription.cancel();

        expect(second.state, TransferItemState.failed);
        expect(second.failureRetryPolicy, TransferFailureRetryPolicy.terminal);
        expect(retryStates, isNot(contains(TransferItemState.pending)));
        expect(retryStates, isNot(contains(TransferItemState.active)));
      },
    );

    test('ask parks the item on the conflict surface — never a silent '
        'overwrite', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.ask,
        ),
      );
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the collision never surfaced',
      );
      final item = task.items.single;
      expect(item.state, TransferItemState.conflictPending);
      expect(task.isTerminal, isFalse);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
      // The full seam lives in transfer_conflict_test.dart — here the
      // answer just proves the parked item resumes and settles.
      expect(
        queue.resolveConflict(task.id, item.id, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(task);
      expect(item.state, TransferItemState.skipped);
      expect(task.state, TransferTaskState.completed);
    });

    test('case-insensitive destination serializes folded duplicates',
        () async {
      queue = newQueue(isCaseInsensitiveDestination: (_) => true);
      events = [];
      queue.events.listen(events.add);
      s2.caseInsensitive = true;
      s1.addFile('/src/A.txt', 'upper'.codeUnits);
      s1.addFile('/src/a.txt', 'lower'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 2);
      // One landed on the scanned name; the folded twin waited, re-stat'd
      // reality, and took the numbered name.
      final landed = s2.fileBytes.keys.toList()..sort();
      expect(landed, ['/dst/src/A.txt', '/dst/src/a (2).txt']);
    });

    test(
      'case-insensitive replace leaves one folded destination entry',
      () async {
        s2.caseInsensitive = true;
        s1.addFile('/src/readme', 'new'.codeUnits);
        s2.addFile('/dst/README', 'old'.codeUnits);
        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/readme'],
            destinationDir: '/dst',
            files: ConflictResolution.replace,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        final foldedEntries = s2.fileBytes.entries
            .where((entry) => entry.key.toLowerCase() == '/dst/readme')
            .toList();
        expect(foldedEntries, hasLength(1));
        expect(foldedEntries.single.value, 'new'.codeUnits);
      },
    );

    test(
      're-probes name traits when an endpoint changes under one id',
      () async {
        s1.addFile('/prime.txt', 'prime'.codeUnits);
        final prime = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/prime.txt'],
            destinationDir: '/dst',
          ),
        );
        await awaitTaskDone(prime);
        expect(prime.state, TransferTaskState.completed);

        // A bookmark edit or remount can keep the server id and root while
        // changing the filesystem's identity rules.
        s2.caseInsensitive = true;
        s1.addFile('/left/README', 'upper'.codeUnits);
        s1.addFile('/right/readme', 'lower'.codeUnits);
        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/left/README', '/right/readme'],
            destinationDir: '/dst',
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.failed);
        final survivingPayloads = <String>{
          for (final bytes in s1.fileBytes.values) String.fromCharCodes(bytes),
          for (final bytes in s2.fileBytes.values) String.fromCharCodes(bytes),
        };
        expect(survivingPayloads, containsAll({'upper', 'lower'}));
      },
    );

    test(
      'fails the task when destination probe cleanup leaves debris',
      () async {
        s1.addFile('/src/a.txt', 'source'.codeUnits);
        s2.nameProbeFailures[FakeNameProbeOperation.delete] =
            RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'delete',
              message: 'scripted probe cleanup failure',
            );

        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/a.txt'],
            destinationDir: '/dst',
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.failed);
        expect(task.error, contains('filename probe may remain'));
        expect(s2.uploadCalls, 0);
        expect(s2.nameProbeCalls, contains(startsWith('delete:')));
      },
    );

    test('cancelling a gated destination probe lets disposal drain', () async {
      s1.addFile('/src/a.txt', 'source'.codeUnits);
      final probeGate = Completer<void>();
      s2.nameProbeGates[FakeNameProbeOperation.upload] = probeGate;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/a.txt'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => s2.nameProbeCalls.any((call) => call.startsWith('upload:')),
        reason: 'the destination probe never started',
      );

      queue.cancelTask(task.id);
      final dispose = queue.dispose();
      try {
        await dispose.timeout(const Duration(milliseconds: 200));
      } finally {
        if (!probeGate.isCompleted) probeGate.complete();
        await dispose;
      }

      expect(task.state, TransferTaskState.cancelled);
      expect(s2.entryAt('/dst/a.txt'), isNull);
    });

    test('a cancelled queued name probe releases its leases', () async {
      s1
        ..addFile('/src/a.txt', 'first'.codeUnits)
        ..addFile('/src/b.txt', 'second'.codeUnits);
      final probeGate = Completer<void>();
      s2.nameProbeGates[FakeNameProbeOperation.upload] = probeGate;
      final holder = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/a.txt'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => s2.nameProbeCalls.any((call) => call.startsWith('upload:')),
        reason: 'the holder probe never started',
      );
      final waiting = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/b.txt'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => connections.activeLeases('s2') == 2,
        reason: 'the second probe never queued behind the holder',
      );

      queue.cancelTask(waiting.id);
      try {
        await pumpUntil(
          () => connections.activeLeases('s2') == 1,
          reason: 'the cancelled probe retained its destination lease',
          maxPumps: 40,
        );
        expect(connections.activeLeases('s1'), 1);
      } finally {
        probeGate.complete();
        await awaitTaskDone(holder);
      }

      expect(waiting.state, TransferTaskState.cancelled);
    });

    test(
      'pausing a nested-container probe releases its attempt leases',
      () async {
        queue = newQueue(maxInFlightFiles: 1);
        s1.addFile('/src/folder/a.txt', 'source'.codeUnits);
        final listingGate = Completer<void>();
        s1.listGate = (path) => path == '/src/folder' ? listingGate : null;
        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/folder'],
            destinationDir: '/dst',
          ),
        );
        await pumpUntil(
          () => s1.calls.contains('list:/src/folder'),
          reason: 'the source listing never reached its gate',
        );

        final nestedProbeGate = Completer<void>();
        s2.nameProbeGates[FakeNameProbeOperation.upload] = nestedProbeGate;
        listingGate.complete();
        await pumpUntil(
          () =>
              s2.nameProbeCalls
                  .where((call) => call.startsWith('upload:'))
                  .length >=
              2,
          reason: 'the nested-container probe never started',
        );

        try {
          queue.pauseTask(task.id);
          await pumpUntil(
            () =>
                connections.activeLeases('s1') == 0 &&
                connections.activeLeases('s2') == 0,
            reason: 'the paused probe never released its leases',
          );
          expect(connections.activeLeases('s1'), 0);
          expect(connections.activeLeases('s2'), 0);
        } finally {
          if (!nestedProbeGate.isCompleted) nestedProbeGate.complete();
        }

        queue.resumeTask(task.id);
        await awaitTaskDone(task);
        expect(task.state, TransferTaskState.completed);
      },
    );

    test('a concurrent source scan excludes a visible name probe', () async {
      s1
        ..addDirectory('/out')
        ..addFile('/src/a.txt', 'source'.codeUnits);
      final probeStatGate = Completer<void>();
      s2.nameProbeGates[FakeNameProbeOperation.stat] = probeStatGate;
      final probing = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/a.txt'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(
        () => s2.nameProbeCalls.any((call) => call.startsWith('stat:')),
        reason: 'the committed probe never reached its first lookup',
      );

      final scanning = enqueue(
        copySpec(
          source: const ServerFsLocation('s2'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const ['/dst'],
          destinationDir: '/out',
        ),
      );
      await awaitTaskDone(scanning);
      probeStatGate.complete();
      await awaitTaskDone(probing);

      expect(scanning.state, TransferTaskState.completed);
      final artifact = scanning.items.singleWhere(
        (item) =>
            isFileSystemNameProbeArtifact(remoteBasename(item.sourcePath)),
      );
      expect(artifact.state, TransferItemState.skipped);
      expect(probing.state, TransferTaskState.completed);
    });

    test(
      'a move waits for a source-directory name probe to clean up',
      () async {
        s1
          ..addDirectory('/out')
          ..addFile('/seed.txt', 'seed'.codeUnits);
        s2.addDirectory('/dst/empty');
        final probeStatGate = Completer<void>();
        s2.nameProbeGates[FakeNameProbeOperation.stat] = probeStatGate;
        final probing = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/seed.txt'],
            destinationDir: '/dst/empty',
          ),
        );
        await pumpUntil(
          () => s2.nameProbeCalls.any((call) => call.startsWith('stat:')),
          reason: 'the source-directory probe never became visible',
        );

        final moving = enqueue(
          copySpec(
            source: const ServerFsLocation('s2'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const ['/dst/empty'],
            destinationDir: '/out',
            operation: TransferOperation.move,
          ),
        );
        await pump();
        expect(moving.isTerminal, isFalse);

        queue.cancelTask(probing.id);
        probeStatGate.complete();
        await awaitTaskDone(probing);
        await awaitTaskDone(moving);
        expect(probing.state, TransferTaskState.cancelled);
        expect(moving.state, TransferTaskState.completed);
        expect(s2.entryAt('/dst/empty'), isNull);
        expect(s1.entryAt('/out/empty'), isNotNull);
      },
    );

    test('a move waits for a name probe started outside the queue', () async {
      s1.addDirectory('/out');
      s2.addDirectory('/dst/empty');
      final probeStatGate = Completer<void>();
      s2.nameProbeGates[FakeNameProbeOperation.stat] = probeStatGate;
      final probe = probeFileSystemNameTraits(s2, '/dst/empty');
      await pumpUntil(
        () => s2.nameProbeCalls.any((call) => call.startsWith('stat:')),
        reason: 'the external probe never became visible',
      );

      final moving = enqueue(
        copySpec(
          source: const ServerFsLocation('s2'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const ['/dst/empty'],
          destinationDir: '/out',
          operation: TransferOperation.move,
        ),
      );
      await pump();
      expect(moving.isTerminal, isFalse);

      probeStatGate.complete();
      await probe;
      await awaitTaskDone(moving);

      expect(moving.state, TransferTaskState.completed);
      expect(s2.entryAt('/dst/empty'), isNull);
      expect(s1.entryAt('/out/empty'), isNotNull);
    });

    test(
      'a cancelled move waiting behind a name probe keeps its source',
      () async {
        s1
          ..addDirectory('/out')
          ..addFile('/seed.txt', 'seed'.codeUnits);
        s2.addDirectory('/dst/empty');
        final probeStatGate = Completer<void>();
        s2.nameProbeGates[FakeNameProbeOperation.stat] = probeStatGate;
        final probing = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/seed.txt'],
            destinationDir: '/dst/empty',
          ),
        );
        await pumpUntil(
          () => s2.nameProbeCalls.any((call) => call.startsWith('stat:')),
          reason: 'the source-directory probe never became visible',
        );

        final moving = enqueue(
          copySpec(
            source: const ServerFsLocation('s2'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const ['/dst/empty'],
            destinationDir: '/out',
            operation: TransferOperation.move,
          ),
        );
        await pump();
        expect(moving.isTerminal, isFalse);

        queue.cancelTask(moving.id);
        queue.cancelTask(probing.id);
        probeStatGate.complete();
        await awaitTaskDone(probing);
        await awaitTaskDone(moving);
        await pumpUntil(
          () => connections.activeLeases('s2') == 0,
          reason: 'the cancelled move did not drain',
        );

        expect(moving.state, TransferTaskState.cancelled);
        expect(s2.entryAt('/dst/empty'), isNotNull);
      },
    );

    test(
      'a stranded name-probe artifact fails a move without deleting',
      () async {
        queue = newQueue(nameProbeCleanupTimeout: Duration.zero);
        s1.addDirectory('/out');
        s2
          ..addDirectory('/dst/empty')
          ..addFile(
            '/dst/empty/.poltergeist-nameprobe-0123456789abcdef-é',
            const [],
          );
        final moving = enqueue(
          copySpec(
            source: const ServerFsLocation('s2'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const ['/dst/empty'],
            destinationDir: '/out',
            operation: TransferOperation.move,
          ),
        );

        await awaitTaskDone(moving).timeout(const Duration(milliseconds: 200));

        expect(moving.state, TransferTaskState.failed);
        expect(moving.error, contains('name probe'));
        expect(s2.entryAt('/dst/empty'), isNotNull);
      },
    );

    test('move refuses same-basename roots instead of replacing one', () async {
      s1.addFile('/left/report.txt', 'left'.codeUnits);
      s1.addFile('/right/report.txt', 'right'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/left/report.txt', '/right/report.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      expect(task.failedItems, 1);
      expect(
        task.items.map((item) => item.state),
        unorderedEquals([
          TransferItemState.completed,
          TransferItemState.failed,
        ]),
      );
      expect(
        task.items
            .singleWhere((item) => item.state == TransferItemState.failed)
            .error,
        contains('two source items map to the same destination name'),
      );

      final survivingPayloads = <String>{
        for (final bytes in s1.fileBytes.values) String.fromCharCodes(bytes),
        for (final bytes in s2.fileBytes.values) String.fromCharCodes(bytes),
      };
      expect(survivingPayloads, {'left', 'right'});
    });

    test(
      'move refuses case twins before replace can delete both sources',
      () async {
        s2.caseInsensitive = true;
        s1.addFile('/src/README', 'upper'.codeUnits);
        s1.addFile('/src/readme', 'lower'.codeUnits);
        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/README', '/src/readme'],
            destinationDir: '/dst',
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.failed);
        expect(task.failedItems, 1);
        expect(
          task.items.map((item) => item.state),
          unorderedEquals([
            TransferItemState.completed,
            TransferItemState.failed,
          ]),
        );
        final survivingPayloads = <String>{
          for (final bytes in s1.fileBytes.values) String.fromCharCodes(bytes),
          for (final bytes in s2.fileBytes.values) String.fromCharCodes(bytes),
        };
        expect(survivingPayloads, {'upper', 'lower'});
      },
    );

    test(
      'move stays safe when a nested destination mount folds names',
      () async {
        queue = newQueue(maxInFlightFiles: 1);
        s1
          ..addFile('/src/folder/README', 'upper'.codeUnits)
          ..addFile('/src/folder/readme', 'lower'.codeUnits);
        s2.addDirectory('/dst/folder');
        s2.nameComparisonsByRoot['/dst/folder'] =
            DestinationNameComparison.normalizedCaseInsensitive;

        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/folder'],
            destinationDir: '/dst',
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        );
        await awaitTaskDone(task);

        final survivingPayloads = <String>{
          for (final bytes in s1.fileBytes.values) String.fromCharCodes(bytes),
          for (final bytes in s2.fileBytes.values) String.fromCharCodes(bytes),
        };
        expect(task.state, TransferTaskState.failed);
        expect(survivingPayloads, {'upper', 'lower'});
      },
    );

    test('move stays safe when destination traits change mid-task', () async {
      queue = newQueue(maxInFlightFiles: 1);
      s1
        ..addFile('/left/README', 'upper'.codeUnits)
        ..addFile('/right/readme', 'lower'.codeUnits);
      final uploadGate = Completer<void>();
      s2.uploadGate = (_) => uploadGate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/left/README', '/right/readme'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
          operation: TransferOperation.move,
        ),
      );
      await pumpUntil(
        () => s2.activeUploads > 0,
        reason: 'the first move never reached its commit',
      );
      s2.caseInsensitive = true;
      uploadGate.complete();
      await awaitTaskDone(task);

      final survivingPayloads = <String>{
        for (final bytes in s1.fileBytes.values) String.fromCharCodes(bytes),
        for (final bytes in s2.fileBytes.values) String.fromCharCodes(bytes),
      };
      expect(task.state, TransferTaskState.failed);
      expect(survivingPayloads, {'upper', 'lower'});
    });

    test(
      'move refreshes parent traits after case-twin directories are admitted',
      () async {
        queue = newQueue(maxInFlightFiles: 1);
        s1
          ..addFile('/src/A/README', 'upper'.codeUnits)
          ..addFile('/src/a/readme', 'lower'.codeUnits);
        final uploadGate = Completer<void>();
        s2.uploadGate = (_) => uploadGate;

        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/A', '/src/a'],
            destinationDir: '/dst',
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        );
        await pumpUntil(
          () =>
              s2.activeUploads == 1 &&
              s2.entryAt('/dst/A') != null &&
              s2.entryAt('/dst/a') != null,
          reason: 'the exact destination never admitted both directories',
        );

        // The same root now resolves to a case-insensitive filesystem.
        // Cached parent identity must not admit both child outputs.
        s2.caseInsensitive = true;
        uploadGate.complete();
        await awaitTaskDone(task);

        final remainingSources = [
          s1.fileBytes['/src/A/README'],
          s1.fileBytes['/src/a/readme'],
        ].whereType<List<int>>().map(String.fromCharCodes).toList();
        final survivingPayloads = <String>{
          ...remainingSources,
          for (final bytes in s2.fileBytes.values) String.fromCharCodes(bytes),
        };
        expect(task.state, TransferTaskState.failed);
        expect(remainingSources, hasLength(1));
        expect(survivingPayloads, {'upper', 'lower'});
      },
    );

    test('exact destination keeps case-twin move outputs distinct', () async {
      s1
        ..addFile('/left/README', 'upper'.codeUnits)
        ..addFile('/right/readme', 'lower'.codeUnits);

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/left/README', '/right/readme'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/README'], 'upper'.codeUnits);
      expect(s2.fileBytes['/dst/readme'], 'lower'.codeUnits);
    });

    test('exact nested destination keeps case-twin copies distinct', () async {
      s1
        ..addFile('/src/folder/README', 'upper'.codeUnits)
        ..addFile('/src/folder/readme', 'lower'.codeUnits);

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/folder'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/folder/README'], 'upper'.codeUnits);
      expect(s2.fileBytes['/dst/folder/readme'], 'lower'.codeUnits);
    });

    test('copy stays safe when destination traits change mid-task', () async {
      queue = newQueue(maxInFlightFiles: 1);
      s1
        ..addFile('/left/README', 'upper'.codeUnits)
        ..addFile('/right/readme', 'lower'.codeUnits);
      final uploadGate = Completer<void>();
      s2.uploadGate = (_) => uploadGate;

      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/left/README', '/right/readme'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await pumpUntil(
        () => s2.activeUploads > 0,
        reason: 'the first copy never reached its commit',
      );
      s2.caseInsensitive = true;
      uploadGate.complete();
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.failed);
      expect(task.completedFiles, 1);
      expect(task.failedItems, 1);
    });

    test('ask can keep both task-local aliases', () async {
      s2.caseInsensitive = true;
      s1
        ..addFile('/src/README', 'upper'.codeUnits)
        ..addFile('/src/readme', 'lower'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/README', '/src/readme'],
          destinationDir: '/dst',
          files: ConflictResolution.ask,
        ),
      );

      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the task-local alias never reached the conflict surface',
      );
      final conflict = queue.pendingConflicts.single;
      expect(
        queue.resolveConflict(
          task.id,
          conflict.itemId,
          ConflictResolution.keepBoth,
        ),
        isTrue,
      );
      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes, hasLength(2));
    });

    test('NFC and NFD twins share one in-flight destination claim', () async {
      s2.normalizationInsensitive = true;
      s1.addFile('/src/caf\u00e9.txt', 'nfc'.codeUnits);
      s1.addFile('/src/cafe\u0301.txt', 'nfd'.codeUnits);
      final uploadGate = Completer<void>();
      s2.uploadGate = (_) => uploadGate;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/caf\u00e9.txt', '/src/cafe\u0301.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
        ),
      );

      await pumpUntil(
        () => s2.activeUploads > 0,
        reason: 'the first normalized twin never started uploading',
      );
      await pump();
      final activeBeforeRelease = s2.activeUploads;
      uploadGate.complete();

      expect(activeBeforeRelease, 1);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.completedFiles, 2);
    });

    test(
      'folder keepBoth rebases the subtree into the numbered directory',
        () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/inside.txt', 'in'.codeUnits);
      s2.addDirectory('/dst/dir');
      s2.addFile('/dst/dir/stale.txt', 'stale'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          folders: ConflictResolution.keepBoth,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/dir (2)/inside.txt'], 'in'.codeUnits);
      expect(s2.fileBytes['/dst/dir/stale.txt'], 'stale'.codeUnits);
      },
    );

    test('folder keepBoth advances after a numbered mkdir race', () async {
      final racing = _RacingMkdirFileSystem('/dst/dir (2)')
        ..addDirectory('/dst')
        ..addDirectory('/dst/dir');
      connections = FakeQueueConnectionManager({'s1': s1, 's2': racing});
      queue = newQueue();
      s1.addFile('/src/dir/inside.txt', 'in'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/src/dir'],
          destinationDir: '/dst',
          folders: ConflictResolution.keepBoth,
        ),
      );

      await awaitTaskDone(task);

      expect(task.state, TransferTaskState.completed);
      expect(racing.fileBytes['/dst/dir (3)/inside.txt'], 'in'.codeUnits);
      expect(racing.entryAt('/dst/dir (2)'), isNotNull);
    });

    test('non-directory occupant + folder skip skips the subtree', () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/inside.txt', 'in'.codeUnits);
      s2.addFile('/dst/dir', 'a-file'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          folders: ConflictResolution.skip,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      final byPath = {for (final i in task.items) i.sourcePath: i};
      expect(byPath['/src/dir']!.state, TransferItemState.skipped);
      expect(byPath['/src/dir/inside.txt']!.state, TransferItemState.skipped);
      expect(s2.fileBytes['/dst/dir'], 'a-file'.codeUnits);
    });
  });

  group('move', () {
    test('move deletes the source file after commit', () async {
      s1.addFile('/src/m.txt', 'mm'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/m.txt'],
          destinationDir: '/dst',
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/m.txt'], 'mm'.codeUnits);
      expect(s1.entryAt('/src/m.txt'), isNull);
    });

    test('move removes source directories deepest-first; skipped children '
        'keep their directory', () async {
      s1.addDirectory('/src/dir/sub');
      s1.addFile('/src/dir/sub/keep.txt', 'k'.codeUnits);
      s1.addFile('/src/dir/gone.txt', 'g'.codeUnits);
      s2.addDirectory('/dst/dir');
      s2.addDirectory('/dst/dir/sub');
      s2.addFile('/dst/dir/sub/keep.txt', 'existing'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          files: ConflictResolution.skip,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // gone.txt moved; keep.txt skipped → sub stays, and so does dir.
      expect(s2.fileBytes['/dst/dir/gone.txt'], 'g'.codeUnits);
      expect(s1.entryAt('/src/dir/gone.txt'), isNull);
      expect(s1.entryAt('/src/dir/sub/keep.txt'), isNotNull);
      expect(s1.entryAt('/src/dir/sub'), isNotNull);
      expect(s1.entryAt('/src/dir'), isNotNull);
    });

    // D26's never-self-overwrite rule on one server: a destination
    // spelling that the server resolves to the source itself (another
    // casing on a case-insensitive server, a symlinked directory) must
    // complete in place. Replace would pipe the file onto its own entry
    // and then unlink the only copy.
    test('a same-server move onto an aliased path completes in place, '
        'even when answered Replace', () async {
      s1.caseInsensitive = true;
      s1.addFile('/site/index.html', 'home'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['/site/index.html'],
          destinationDir: '/SITE',
          files: ConflictResolution.replace,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.items.single.state, TransferItemState.completed);
      expect(s1.uploadCalls, 0);
      expect(s1.deleteCalls, 0);
      expect(s1.fileBytes['/site/index.html'], 'home'.codeUnits);
    });

    test('a same-server folder move onto an aliased path, merged and '
        'replaced, leaves the tree in place', () async {
      s1.caseInsensitive = true;
      s1.addFile('/www/site/index.html', 'home'.codeUnits);
      s1.addFile('/www/site/css/app.css', 'css'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['/www/site'],
          destinationDir: '/WWW',
          files: ConflictResolution.replace,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.uploadCalls, 0);
      expect(s1.deleteCalls, 0);
      expect(s1.fileBytes['/www/site/index.html'], 'home'.codeUnits);
      expect(s1.fileBytes['/www/site/css/app.css'], 'css'.codeUnits);
      expect(s1.entryAt('/www/site'), isNotNull);
    });

    test('a same-server move to another directory still moves', () async {
      s1.addFile('/src/m.txt', 'mm'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['/src/m.txt'],
          destinationDir: '/dst',
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.fileBytes['/dst/m.txt'], 'mm'.codeUnits);
      expect(s1.entryAt('/src/m.txt'), isNull);
    });
  });

  group('failures', () {
    test('disconnected mid-transfer requeues within the retry budget then '
        'fails the task honestly', () async {
      queue = newQueue(taskRetryLimit: 1);
      events = [];
      queue.events.listen(events.add);
      s1.addFile('/src/f.bin', List.filled(8, 9));
      var failOnce = true;
      s1.downloadFailure = (_) {
        if (!failOnce) return null;
        failOnce = false;
        return const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'download',
          message: 'transport dropped',
        );
      };
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      // The retry re-downloaded the file; a landed commit resets the
      // counter — the budget bounds consecutive losses, not lifetime
      // cumulative ones (03 §3.3).
      expect(s1.downloadCalls, 2);
      expect(task.retryCount, 0);
      expect(s2.fileBytes['/dst/f.bin'], List.filled(8, 9));
    });

    test('persistent disconnect beyond the retry budget fails the task',
        () async {
      queue = newQueue(taskRetryLimit: 1);
      events = [];
      queue.events.listen(events.add);
      s1.addFile('/src/f.bin', List.filled(8, 9));
      s1.downloadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'download',
        message: 'transport dropped',
      );
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      expect(task.failureKind, RemoteFileErrorKind.disconnected);
    });

    test('an upload that dies early aborts the download instead of '
        'buffering the whole file', () async {
      // 512 KB source, tiny pipe buffer, upload fails at once.
      queue = newQueue(pipeBufferBytes: 64);
      events = [];
      queue.events.listen(events.add);
      s1.addFile('/src/big.bin', List.filled(512 * 1024, 3));
      s1.downloadChunkSize = 1024;
      s2.uploadFailure = (_) => const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'upload',
        message: 'denied',
      );
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/big.bin'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      // The real upload error must dominate the internal abort-cancel.
      expect(task.failureKind, RemoteFileErrorKind.permissionDenied);
      // The download must not have delivered all 512 KB into a dead pipe.
      expect(task.transferredBytes, lessThan(512 * 1024));
    });

    test('unsafe destination names fail the item, not the task scan',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/good.txt', 'g'.codeUnits);
      // Backslash is rejected by validatePathComponent for every
      // destination (it is a traversal hazard on Windows).
      s1.directories['/src']!.add(
        const RemoteFileEntry(
          path: '/src/evil\\name.txt',
          name: 'evil\\name.txt',
          type: RemoteFileType.file,
          size: 1,
        ),
      );
      s1.fileBytes['/src/evil\\name.txt'] = [0];
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final bySource = {for (final i in task.items) i.sourcePath: i};
      expect(bySource['/src/good.txt']!.state, TransferItemState.completed);
      expect(
        bySource['/src/evil\\name.txt']!.state,
        TransferItemState.failed,
      );
      expect(s2.fileBytes['/dst/src/good.txt'], 'g'.codeUnits);
    });

    test('a missing root fails its item; siblings still transfer', () async {
      s1.addFile('/src/here.txt', 'h'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/here.txt', '/src/gone.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      final bySource = {for (final i in task.items) i.sourcePath: i};
      expect(bySource['/src/here.txt']!.state, TransferItemState.completed);
      expect(bySource['/src/gone.txt']!.state, TransferItemState.failed);
      expect(s2.fileBytes['/dst/here.txt'], 'h'.codeUnits);
    });

    test('a mid-scan listing failure fails that directory; siblings finish',
        () async {
      s1.addDirectory('/src');
      s1.addDirectory('/src/bad');
      s1.addFile('/src/bad/x.txt', [1]);
      s1.addFile('/src/ok.txt', 'ok'.codeUnits);
      s1.listFailure = (path) => path == '/src/bad'
          ? const RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'list',
              message: 'denied',
            )
          : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.failed);
      expect(s2.fileBytes['/dst/src/ok.txt'], 'ok'.codeUnits);
      final dir = task.items.firstWhere((i) => i.sourcePath == '/src/bad');
      expect(dir.state, TransferItemState.failed);
    });
  });

  group('lifecycle', () {
    test('dispose cancels running work, drains, and closes events', () async {
      s1.addFile('/src/f.bin', List.filled(8, 1));
      s1.downloadGate = (_) => Completer<void>(); // never completes
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.bin'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => s1.activeDownloads == 1);
      final closed = Completer<void>();
      queue.events.listen((_) {}, onDone: closed.complete);
      await queue.dispose();
      expect(task.state, TransferTaskState.cancelled);
      expect(connections.activeLeases('s1'), 0);
      await pumpUntil(() => closed.isCompleted,
          reason: 'the event stream never closed');
    });

    test('dispose waits for move directory cleanup to release leases', () async {
      const sourcePath = '/src/folder';
      s1.addDirectory(sourcePath);
      final cleanupStarted = Completer<void>();
      final cleanupGate = Completer<void>();
      var sourceLists = 0;
      s1.listGate = (path) {
        if (path != sourcePath) return null;

        sourceLists++;
        if (sourceLists != 2) return null;
        cleanupStarted.complete();
        return cleanupGate;
      };
      enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const [sourcePath],
          destinationDir: '/dst',
          operation: TransferOperation.move,
        ),
      );

      try {
        await cleanupStarted.future;
        var disposed = false;
        final dispose = queue.dispose().then((_) => disposed = true);
        await pump(20);

        expect(disposed, isFalse);
        expect(connections.activeLeases('s1'), 1);

        cleanupGate.complete();
        await dispose;
        expect(connections.activeLeases('s1'), 0);
      } finally {
        if (!cleanupGate.isCompleted) cleanupGate.complete();
      }
    });

    test('cross-task destination claims serialize commits', () async {
      s1.addFile('/src/shared.txt', 'first'.codeUnits);
      s2.addFile('/src/shared.txt', 'second'.codeUnits);
      final gate = Completer<void>();
      var armed = true;
      s2.uploadGate = (_) => armed ? gate : null;

      final taskA = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/shared.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await pumpUntil(() => s2.activeUploads == 1);
      // While task A holds the claim, task B's identical destination
      // waits — slotless, no upload started.
      final taskB = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/shared.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await pump();
      expect(s2.activeUploads, 1);
      armed = false;
      gate.complete();
      await awaitTaskDone(taskA);
      await awaitTaskDone(taskB);
      expect(taskA.state, TransferTaskState.completed);
      expect(taskB.state, TransferTaskState.completed);
      expect(s2.uploadCalls, 2);
    });

    test('a raced keep-both target waits without holding its slot', () async {
      s2.addFile('/dst/a.txt', 'existing'.codeUnits);
      s1
        ..addFile('/keep/a.txt', 'keep'.codeUnits)
        ..addFile('/literal/a (2).txt', 'literal'.codeUnits);
      final keepBothStatGate = Completer<void>();
      var candidateStats = 0;
      s2.statGate = (path) {
        if (path != '/dst/a (2).txt' || candidateStats++ > 0) return null;
        return keepBothStatGate;
      };
      final literalUploadGate = Completer<void>();
      s2.uploadGate = (path) =>
          path == '/dst/a (2).txt' ? literalUploadGate : null;

      final keepBoth = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/keep/a.txt'],
          destinationDir: '/dst',
          files: ConflictResolution.keepBoth,
        ),
      );
      await pumpUntil(
        () => candidateStats > 0,
        reason: 'keep-both never checked its first numbered target',
      );
      final literal = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/literal/a (2).txt'],
          destinationDir: '/dst',
          files: ConflictResolution.replace,
        ),
      );
      await pumpUntil(
        () => s2.calls.contains('upload:/dst/a (2).txt'),
        reason: 'the literal target never claimed its upload',
      );

      keepBothStatGate.complete();
      await pump();
      expect(s2.calls, isNot(contains('upload:/dst/a (3).txt')));

      literalUploadGate.complete();
      await awaitTaskDone(literal);
      await awaitTaskDone(keepBoth);
      expect(literal.state, TransferTaskState.completed);
      expect(keepBoth.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/a (2).txt'], 'literal'.codeUnits);
      expect(s2.fileBytes['/dst/a (3).txt'], 'keep'.codeUnits);
    });

    test('cross-task directory claims preserve conflict policy', () async {
      s2.addDirectory('/dst/foo');
      s1
        ..addDirectory('/keep/foo')
        ..addDirectory('/literal/foo (2)');
      final firstMkdirGate = Completer<void>();
      var numberedMkdirs = 0;
      s2.createDirectoryGate = (path) {
        if (path != '/dst/foo (2)' || numberedMkdirs++ > 0) return null;
        return firstMkdirGate;
      };

      final keepBoth = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/keep/foo'],
          destinationDir: '/dst',
          folders: ConflictResolution.keepBoth,
        ),
      );
      await pumpUntil(
        () => numberedMkdirs > 0,
        reason: 'keep-both never started its numbered mkdir',
      );
      final literal = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/literal/foo (2)'],
          destinationDir: '/dst',
          folders: ConflictResolution.ask,
        ),
      );
      await pump();
      expect(literal.isTerminal, isFalse);

      firstMkdirGate.complete();
      await pumpUntil(
        () =>
            queue.pendingConflictFor(literal.id, literal.items.single.id) !=
            null,
        reason: 'the literal directory bypassed its Ask policy',
      );
      final item = literal.items.single;
      expect(
        queue.resolveConflict(literal.id, item.id, ConflictResolution.keepBoth),
        isTrue,
      );
      await awaitTaskDone(keepBoth);
      await awaitTaskDone(literal);

      expect(keepBoth.state, TransferTaskState.completed);
      expect(literal.state, TransferTaskState.completed);
      expect(s2.entryAt('/dst/foo (2)'), isNotNull);
      expect(s2.entryAt('/dst/foo (3)'), isNotNull);
    });

    test('a directory claim wait preserves parent-first execution', () async {
      s2.addDirectory('/dst/foo');
      s1
        ..addFile('/keep/foo/a.txt', 'a'.codeUnits)
        ..addFile('/literal/foo (2)/sub/b.txt', 'b'.codeUnits);
      final firstMkdirGate = Completer<void>();
      var numberedMkdirs = 0;
      s2.createDirectoryGate = (path) {
        if (path != '/dst/foo (2)' || numberedMkdirs++ > 0) return null;
        return firstMkdirGate;
      };

      final first = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/keep/foo'],
          destinationDir: '/dst',
          folders: ConflictResolution.keepBoth,
        ),
      );
      await pumpUntil(() => numberedMkdirs > 0);
      final waiting = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: const ['/literal/foo (2)'],
          destinationDir: '/dst',
          folders: ConflictResolution.keepBoth,
        ),
      );
      await pump();

      firstMkdirGate.complete();
      await awaitTaskDone(first);
      await awaitTaskDone(waiting);

      expect(first.state, TransferTaskState.completed);
      expect(waiting.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/foo (3)/sub/b.txt'], 'b'.codeUnits);
      expect(
        waiting.items.where((item) => item.state == TransferItemState.skipped),
        isEmpty,
      );
    });

    test(
      'a paused directory claimant stays parked after the holder exits',
      () async {
        s2.addDirectory('/dst/foo');
        s1
          ..addDirectory('/keep/foo')
          ..addDirectory('/waiting/foo (2)');
        final firstMkdirGate = Completer<void>();
        var numberedMkdirs = 0;
        s2.createDirectoryGate = (path) {
          if (path != '/dst/foo (2)' || numberedMkdirs++ > 0) return null;
          return firstMkdirGate;
        };
        final holder = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/keep/foo'],
            destinationDir: '/dst',
            folders: ConflictResolution.keepBoth,
          ),
        );
        await pumpUntil(() => numberedMkdirs > 0);
        final waiting = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/waiting/foo (2)'],
            destinationDir: '/dst',
            folders: ConflictResolution.keepBoth,
          ),
        );
        await pump();
        queue.pauseTask(waiting.id);

        firstMkdirGate.complete();
        await awaitTaskDone(holder);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(waiting.state, TransferTaskState.paused);
        expect(s2.entryAt('/dst/foo (3)'), isNull);

        queue.resumeTask(waiting.id);
        await awaitTaskDone(waiting);
        expect(waiting.state, TransferTaskState.completed);
        expect(s2.entryAt('/dst/foo (3)'), isNotNull);
      },
    );

    test(
      'a parked parent holds descendants until its conflict resolves',
      () async {
        s1.addFile('/src/parent/child/file.txt', 'x'.codeUnits);
        s2.addDirectory('/dst/parent');
        final task = enqueue(
          copySpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s2'),
            rootPaths: const ['/src/parent'],
            destinationDir: '/dst',
            folders: ConflictResolution.ask,
          ),
        );

        await pumpUntil(
          () => queue.pendingConflicts.any(
            (conflict) => conflict.destinationPath == '/dst/parent',
          ),
          reason: 'the parent conflict never surfaced',
        );
        await pump();
        final parent = task.items.singleWhere(
          (item) => item.sourcePath == '/src/parent',
        );
        expect(
          queue.resolveConflict(
            task.id,
            parent.id,
            ConflictResolution.keepBoth,
          ),
          isTrue,
        );
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        expect(s2.fileBytes['/dst/parent (2)/child/file.txt'], 'x'.codeUnits);
        expect(
          task.items.where((item) => item.state == TransferItemState.skipped),
          isEmpty,
        );
    });
  });

  group('review regressions', () {
    test('a same-server transfer holds one lease and strands none',
        () async {
      // FsLocation has no value equality — source and destination naming
      // one server must still dedupe to a single server id, or the
      // double-lease's overwritten map entry never releases.
      s1.addFile('/src/f.txt', 'x'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.fileBytes['/dst/f.txt'], 'x'.codeUnits);
      // Scan lease + file lease at most — never scan + two file leases.
      expect(connections.maxActiveLeases('s1'), lessThanOrEqualTo(2));
      expect(connections.activeLeases('s1'), 0);
    });

    test('a commit-time conflict retries on a fresh cancellation token',
        () async {
      // The first upload loses the decide→commit race; the retry must not
      // reuse the attempt token _pipe cancelled when its upload died —
      // a dead token would abort the retry instantly and bounce the item
      // through a pointless requeue.
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      var failOnce = true;
      s2.uploadFailure = (path) {
        if (path != '/dst/f.txt' || !failOnce) return null;
        failOnce = false;
        return const RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'upload',
          path: '/dst/f.txt',
          message: 'appeared mid-transfer',
        );
      };
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/f.txt'], 'new'.codeUnits);
      // Exactly two commits: the raced one plus its in-place retry.
      expect(s2.uploadCalls, 2);
    });

    test('a pause landing in the scan disconnect retry parks lease-free',
        () async {
      s1.addDirectory('/src');
      s1.addFile('/src/f.txt', 'x'.codeUnits);
      late TransferTask task;
      var failOnce = true;
      s1.listFailure = (path) {
        if (path != '/src' || !failOnce) return null;
        failOnce = false;
        // Pause inside the failing op: the retry must release the scan
        // leases and park on notPaused rather than re-leasing under a
        // paused task.
        queue.pauseTask(task.id);
        return const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'list',
          message: 'transport dropped',
        );
      };
      task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src'],
          destinationDir: '/dst',
        ),
      );
      await pumpUntil(() => task.state == TransferTaskState.paused);
      await pump(16);
      // Parked: no retry listing ran and no lease is held while paused.
      expect(s1.listCalls, 1);
      expect(connections.activeLeases('s1'), 0);

      queue.resumeTask(task.id);
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s2.fileBytes['/dst/src/f.txt'], 'x'.codeUnits);
    });

    test('a mkdir-conflict on the destination root merges the raced '
        'directory', () async {
      // A concurrent creator wins the stat→mkdir race on /dst: mkdir
      // throws conflict but a re-stat sees a directory — the correct
      // answer is merge, not a scan failure.
      final racing = _RacingMkdirFileSystem('/dst');
      connections = FakeQueueConnectionManager({'s1': s1, 's2': racing});
      queue = newQueue();
      events = [];
      queue.events.listen(events.add);

      s1.addFile('/src/f.txt', 'x'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(racing.fileBytes['/dst/f.txt'], 'x'.codeUnits);
    });

    test('skipped items roll up on the task', () async {
      s1.addFile('/src/f.txt', 'new'.codeUnits);
      s2.addFile('/dst/f.txt', 'old'.codeUnits);
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/f.txt'],
          destinationDir: '/dst',
          // files: skip is the copySpec default.
        ),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(task.skippedItems, 1);
      expect(s2.fileBytes['/dst/f.txt'], 'old'.codeUnits);
    });

    test('a failed source-directory removal reports an item event',
        () async {
      s1.addDirectory('/src/dir');
      s1.addFile('/src/dir/f.txt', 'x'.codeUnits);
      s1.deleteFailure = (entry) => entry.isDirectory
          ? const RemoteFileException(
              kind: RemoteFileErrorKind.permissionDenied,
              operation: 'delete',
              message: 'denied',
            )
          : null;
      final task = enqueue(
        copySpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s2'),
          rootPaths: ['/src/dir'],
          destinationDir: '/dst',
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      // A move that leaves its source behind is not complete — the copy
      // landed but the surviving source directory fails the task.
      expect(task.state, TransferTaskState.failed);
      expect(s2.fileBytes['/dst/dir/f.txt'], 'x'.codeUnits);
      expect(s1.entryAt('/src/dir/f.txt'), isNull);
      expect(s1.entryAt('/src/dir'), isNotNull);
      final dir = task.items.firstWhere((i) => i.sourcePath == '/src/dir');
      expect(dir.error, contains('could not be removed'));
      expect(task.error, isNotNull);
      expect(
        events
            .whereType<TransferQueueItemEvent>()
            .any((e) => e.itemId == dir.id && e.error != null),
        isTrue,
        reason: 'the dir-removal failure must surface as an item event',
      );
    });
  });
}

/// A destination whose `createDirectory` loses the stat→mkdir race on
/// [racePath]: the entry materializes between the queue's absent-stat and
/// its mkdir, so mkdir throws conflict even though a later stat sees the
/// directory a "concurrent creator" made.
final class _RacingMkdirFileSystem extends FakeTreeFileSystem {
  _RacingMkdirFileSystem(this.racePath);

  final String racePath;

  @override
  Future<void> createDirectory(String path) async {
    if (path == racePath) {
      addDirectory(path);
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'mkdir',
        path: path,
        message: 'already exists: $path',
      );
    }
    return super.createDirectory(path);
  }
}
