// Contract tests for the transfer persistence layer (03 §4.6, D16):
// the write-ahead journal, crash/torn-tail/quarantine recovery,
// compaction, the capped history store, and the queue's restore path.
//
// Store tests run FileTransferPersistence directly over a real temp dir.
// Queue tests reuse the deterministic fake-VFS harness — the local side
// is the production LocalFileSystem over real files, the remote side a
// FakeTreeFileSystem.

@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

import 'transfer_fakes.dart';

TransferTaskSpec localToRemoteSpec({
  required List<String> rootPaths,
  String destinationDir = '/dest',
  String serverId = 's1',
  ConflictResolution files = ConflictResolution.skip,
  TransferOperation operation = TransferOperation.copy,
}) => TransferTaskSpec(
  source: const LocalFsLocation(),
  destination: ServerFsLocation(serverId),
  rootPaths: rootPaths,
  destinationDir: destinationDir,
  policy: ResolvedConflictPolicy(files: files),
  operation: operation,
);

/// A `TransferJournalIo` that counts calls and can gate/fsync-fail on
/// demand — the fault-injection seam the ordering and exclusivity tests
/// drive.
class ScriptedIo extends TransferJournalIo {
  int appendCalls = 0;
  int fsyncCalls = 0;
  int rewriteCalls = 0;
  int dirFsyncCalls = 0;

  /// UTF-8 bytes appended to, and rewritten into, the journal. The
  /// compaction-amortization tests compare the two.
  int journalAppendBytes = 0;
  int journalRewriteBytes = 0;
  final List<String> journalRewriteContents = [];

  /// Ordered operation log ('append:journal', 'fsync:history', …) — the
  /// ordering tests assert interleavings, not just counts.
  final List<String> ops = [];

  /// Completes while a rewrite is in flight (for exclusivity tests).
  final Completer<void> rewriteStarted = Completer();
  Completer<void>? rewriteGate;

  /// Throw on the Nth appendLine (1-based) to script write failures.
  int? failOnAppend;

  /// Throw on the Nth appendLine after its record-type gate opens.
  int? failAfterGateOnAppend;

  /// Throw on the Nth fsyncFile (1-based) to script durability failures.
  int? failOnFsync;

  /// Optional record-type gates used to freeze precise crash windows.
  final Map<String, Completer<void>> journalAppendGates = {};
  final List<String> journalAppendTypesStarted = [];

  static String _tag(File file) =>
      file.path.endsWith(transferJournalFileName) ? 'journal' : 'history';

  @override
  Future<void> appendLine(File file, String line) async {
    appendCalls++;
    ops.add('append:${_tag(file)}');
    if (appendCalls == failOnAppend) {
      throw const FileSystemException('scripted append failure');
    }
    if (_tag(file) == 'journal') {
      final json = jsonDecode(line) as Map<String, Object?>;
      final type = json['type']! as String;
      journalAppendTypesStarted.add(type);
      await journalAppendGates[type]?.future;
      if (appendCalls == failAfterGateOnAppend) {
        throw const FileSystemException('scripted gated append failure');
      }
      journalAppendBytes += utf8.encode(line).length + 1;
    }
    return super.appendLine(file, line);
  }

  @override
  Future<void> fsyncFile(File file) async {
    fsyncCalls++;
    ops.add('fsync:${_tag(file)}');
    if (fsyncCalls == failOnFsync) {
      throw const FileSystemException('scripted fsync failure');
    }
    return super.fsyncFile(file);
  }

  @override
  Future<void> fsyncDirectory(Directory directory) async {
    dirFsyncCalls++;
    ops.add('dirfsync');
    return super.fsyncDirectory(directory);
  }

  @override
  Future<void> atomicRewrite(
    File file,
    String contents, {
    bool restrictToOwner = false,
  }) async {
    rewriteCalls++;
    ops.add('rewrite:${_tag(file)}');
    if (_tag(file) == 'journal') {
      journalRewriteBytes += utf8.encode(contents).length;
      journalRewriteContents.add(contents);
    }
    if (!rewriteStarted.isCompleted) rewriteStarted.complete();
    await rewriteGate?.future;
    return super.atomicRewrite(
      file,
      contents,
      restrictToOwner: restrictToOwner,
    );
  }
}

/// A persistence seam whose shutdown fails — the dispose-path test
/// asserts the queue still closes its event stream.
class ThrowingShutdownPersistence implements TransferPersistence {
  @override
  TransferJournalReplay get replay => TransferJournalReplay(tasks: []);

  @override
  void appendJournal(TransferJournalRecord record) {}

  @override
  Future<void> appendJournalDurably(TransferJournalRecord record) async {}

  @override
  void appendHistory(TransferHistoryEntry entry) {}

  @override
  List<TransferHistoryEntry> get history => const [];

  @override
  Future<void> clearHistory() async {}

  @override
  Future<void> shutdown() => Future.error(StateError('disk gone'));
}

TransferJournalRecord enqueued(String taskId, TransferTaskSpec spec) =>
    TaskEnqueuedRecord(
      taskId: taskId,
      spec: spec,
      enqueuedAt: DateTime.utc(2026, 1, 1),
    );

PlanEntryRecord fileEntry(
  String taskId,
  String itemId,
  String sourcePath,
  String destinationPath, {
  int size = 5,
}) => PlanEntryRecord(
  taskId: taskId,
  itemId: itemId,
  isDirectory: false,
  sourcePath: sourcePath,
  destinationPath: destinationPath,
  sourceType: RemoteFileType.file,
  sourceSize: size,
);

TransferHistoryEntry historyEntry(String taskId) => TransferHistoryEntry(
  taskId: taskId,
  source: const LocalFsLocation(),
  destination: const ServerFsLocation('s1'),
  rootPaths: const ['/r'],
  destinationDir: '/dest',
  operation: TransferOperation.copy,
  outcome: TransferTaskState.completed,
  startedAt: DateTime.utc(2026, 1, 1),
  finishedAt: DateTime.utc(2026, 1, 1, 0, 1),
  completedFiles: 1,
  failedItems: 0,
  skippedItems: 0,
  transferredBytes: 5,
  totalBytes: 5,
);

void main() {
  late Directory tempDir;
  late Directory storeDir;
  late List<String> notices;
  // Every store this test opened — including ones deliberately
  // abandoned mid-test to simulate a crash. TearDown shuts them all
  // down so no writer-chain op or fsync timer can still hold a file
  // handle when the fixture directory is deleted (errno 32 on Windows).
  final openedStores = <FileTransferPersistence>[];

  Future<FileTransferPersistence> openStore({
    ScriptedIo? io,
    int historyLimit = transferHistoryLimit,
    int compactFinishedTasks = journalCompactFinishedTasks,
    int compactBytes = journalCompactBytes,
    int fsyncEveryRecords = journalFsyncEveryRecords,
    Duration fsyncInterval = journalFsyncInterval,
  }) async {
    final store = await FileTransferPersistence.open(
      storeDir,
      io: io ?? const TransferJournalIo(),
      onNotice: notices.add,
      historyLimit: historyLimit,
      compactFinishedTasks: compactFinishedTasks,
      compactBytes: compactBytes,
      fsyncEveryRecords: fsyncEveryRecords,
      fsyncInterval: fsyncInterval,
    );
    openedStores.add(store);
    return store;
  }

  List<String> journalLines(File file) => file
      .readAsStringSync()
      .split('\n')
      .where((line) => line.trim().isNotEmpty)
      .toList();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('poltergeist-tp-');
    tempDir = Directory(tempDir.resolveSymbolicLinksSync());
    storeDir = Directory('${tempDir.path}/store');
    notices = [];
  });

  tearDown(() async {
    for (final store in openedStores) {
      await store.shutdown();
    }
    openedStores.clear();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('store recovery', () {
    test('empty directory opens clean with no replay', () async {
      final store = await openStore();
      expect(store.replay.tasks, isEmpty);
      expect(store.replay.tornJournalBytes, 0);
      expect(store.replay.quarantinedJournalPath, isNull);
      await store.shutdown();
    });

    test('replays a pending task with its spec and item set', () async {
      final store = await openStore();
      final spec = localToRemoteSpec(rootPaths: ['/src/a.txt']);
      store.appendJournal(enqueued('t1', spec));
      store.appendJournal(
        fileEntry('t1', 'i1', '/src/a.txt', '/dest/a.txt'),
      );
      store.appendJournal(
        ScanCompleteRecord(taskId: 't1', totalBytes: 5, skippedSymlinks: 0),
      );
      await store.flush();

      final reopened = await openStore();
      expect(reopened.replay.tasks, hasLength(1));
      final restored = reopened.replay.tasks.single;
      expect(restored.taskId, 't1');
      expect(restored.scanComplete, isTrue);
      expect(restored.totalBytes, 5);
      expect(restored.items, hasLength(1));
      expect(restored.items.single.itemId, 'i1');
      expect(restored.items.single.outcome, isNull);
      expect(restored.spec.destinationDir, '/dest');
      await reopened.shutdown();
    });

    test('a paused task replays as wasPaused', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      store.appendJournal(
        TaskStateRecord(taskId: 't1', state: TransferTaskState.paused),
      );
      await store.flush();

      final reopened = await openStore();
      expect(reopened.replay.tasks.single.wasPaused, isTrue);
      await reopened.shutdown();
    });

    test('terminal and removed tasks do not replay', () async {
      final store = await openStore();
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      store.appendJournal(enqueued('gone', localToRemoteSpec(rootPaths: ['/b'])));
      store.appendJournal(TaskRemovedRecord(taskId: 'gone'));
      await store.flush();

      final reopened = await openStore();
      expect(reopened.replay.tasks, isEmpty);
      await reopened.shutdown();
    });

    test('item outcomes survive: completed and removed never resurrect',
        () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/s'])));
      store.appendJournal(fileEntry('t1', 'done', '/s/a', '/dest/a'));
      store.appendJournal(fileEntry('t1', 'cut', '/s/b', '/dest/b'));
      store.appendJournal(fileEntry('t1', 'live', '/s/c', '/dest/c'));
      store.appendJournal(
        FileCompletedRecord(taskId: 't1', itemId: 'done'),
      );
      store.appendJournal(ItemRemovedRecord(taskId: 't1', itemId: 'cut'));
      await store.flush();

      final reopened = await openStore();
      final items = {
        for (final item in reopened.replay.tasks.single.items)
          item.itemId: item.outcome,
      };
      expect(items['done'], RestoredItemOutcome.completed);
      expect(items['cut'], RestoredItemOutcome.removed);
      expect(items['live'], isNull);
      await reopened.shutdown();
    });

    test('a torn trailing line truncates and reports the dropped bytes',
        () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      // A crash mid-append leaves bytes without the newline terminator.
      // No shutdown — the crash simulation abandons the store (a clean
      // shutdown's compaction rewrite would consume the tail).
      await store.journalFile.writeAsString(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paus',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tornJournalBytes, greaterThan(0));
      expect(reopened.replay.tasks, hasLength(1));
      // The file was truncated before reopen — no malformed tail remains.
      expect(
        store.journalFile.readAsStringSync().endsWith('\n'),
        isTrue,
      );
      await reopened.shutdown();
    });

    test('a torn tail after non-ASCII records truncates at the byte '
        'offset — String.length is UTF-16 units, not bytes', () async {
      final store = await openStore();
      // Multi-byte paths desynchronize the two measures.
      store.appendJournal(
        enqueued('t1', localToRemoteSpec(rootPaths: ['/étage/файл.txt'])),
      );
      await store.flush();
      final intactBytes = store.journalFile.lengthSync();
      await store.journalFile.writeAsString(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paus',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tornJournalBytes, greaterThan(0));
      expect(reopened.replay.tasks.single.taskId, 't1');
      // A UTF-16-length truncate would have cut inside the live record.
      expect(store.journalFile.lengthSync(), intactBytes);
      expect(journalLines(store.journalFile), hasLength(1));
      await reopened.shutdown();
    });

    test('a tail torn mid-UTF-8-sequence truncates instead of '
        'quarantining the file', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      // 'é' is two UTF-8 bytes — drop the last so the tail is
      // undecodable. The intact prefix must still survive.
      final tail = utf8.encode(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paused",'
        '"at":"2026-01-01T00:00:00Z","note":"é',
      );
      final raf = await store.journalFile.open(mode: FileMode.append);
      await raf.writeFrom(tail.sublist(0, tail.length - 1));
      await raf.close();

      final reopened = await openStore();
      expect(reopened.replay.tornJournalBytes, greaterThan(0));
      expect(reopened.replay.quarantinedJournalPath, isNull);
      expect(reopened.replay.tasks.single.taskId, 't1');
      await reopened.shutdown();
    });

    test('a record missing its at timestamp quarantines', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      await store.journalFile.writeAsString(
        '{"v":1,"type":"taskState","taskId":"t1","state":"paused"}\n',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      // The intact prefix replays; the timestamp-less line quarantines.
      expect(reopened.replay.quarantinedJournalPath, isNotNull);
      expect(reopened.replay.quarantinedJournalRecords, 1);
      expect(reopened.replay.tasks.single.taskId, 't1');
      await reopened.shutdown();
    });

    test('a complete-but-unparseable line quarantines and replays the '
        'prefix', () async {
      final store = await openStore();
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      await store.shutdown();

      await store.journalFile.writeAsString(
        '{"v":1,"type":"bogus"}\n{"v":1,"type":"taskState","taskId":"t2","state":"paused","at":"2026-01-01T00:00:00Z"}\n',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tasks, hasLength(1));
      expect(reopened.replay.quarantinedJournalPath, isNotNull);
      expect(reopened.replay.quarantinedJournalRecords, 2);
      expect(
        File(reopened.replay.quarantinedJournalPath!).existsSync(),
        isTrue,
      );
      // The live file was rewritten to the intact prefix — later appends
      // never land behind the malformed line.
      expect(journalLines(store.journalFile), hasLength(1));
      await reopened.shutdown();
    });

    test('an unknown schema version quarantines the journal', () async {
      await openStore().then((s) => s.shutdown());
      await storeDir.create(recursive: true);
      final futureVersion = transferJournalSchemaVersion + 1;
      final futureLine =
          '{"v":$futureVersion,"type":"taskEnqueued","taskId":"t1",'
          '"at":"2026-01-01T00:00:00Z",'
          '"enqueuedAt":"2026-01-01T00:00:00Z","spec":{}}';
      final journal = File('${storeDir.path}/$transferJournalFileName');
      journal.writeAsStringSync('$futureLine\n');

      final reopened = await openStore();
      expect(reopened.replay.tasks, isEmpty);
      expect(reopened.replay.quarantinedJournalPath, isNotNull);
      expect(
        File(reopened.replay.quarantinedJournalPath!).readAsStringSync(),
        '$futureLine\n',
      );
      expect(journal.readAsStringSync(), isEmpty);
      await reopened.shutdown();
    });

    test('a v1 journal upgrades before any v2 claim is appended', () async {
      await storeDir.create(recursive: true);
      final records = <TransferJournalRecord>[
        enqueued('t1', localToRemoteSpec(rootPaths: ['/src/a.txt'])),
        fileEntry('t1', 'i1', '/src/a.txt', '/dest/a.txt'),
        ScanCompleteRecord(taskId: 't1', totalBytes: 5, skippedSymlinks: 0),
      ];
      var recordIndex = 0;
      final legacy = records
          .map((record) {
            final json = record.toJson()..['v'] = 1;
            if (recordIndex++ == 0) {
              json['futureField'] = {'retained': true};
            }
            return jsonEncode(json);
          })
          .join('\n');
      final journal = File('${storeDir.path}/$transferJournalFileName');
      journal.writeAsStringSync('$legacy\n');

      final store = await openStore();
      await store.appendJournalDurably(
        DestinationClaimedRecord(
          taskId: 't1',
          itemId: 'i1',
          destinationPath: '/dest/a (2).txt',
        ),
      );

      final decoded = journalLines(
        journal,
      ).map((line) => jsonDecode(line) as Map<String, Object?>).toList();
      // A v1 reader must fail at line one, never replay an unsafe prefix.
      expect(decoded.every((record) => record['v'] == 2), isTrue);
      expect(decoded.first['type'], TaskEnqueuedRecord.wireType);
      expect(decoded.first['futureField'], {'retained': true});
      expect(decoded.last['type'], DestinationClaimedRecord.wireType);
    });

    test('a v1 journal upgrades before finished tasks migrate', () async {
      await storeDir.create(recursive: true);
      final records = <TransferJournalRecord>[
        enqueued('done', localToRemoteSpec(rootPaths: ['/done'])),
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
        enqueued('live', localToRemoteSpec(rootPaths: ['/live'])),
      ];
      final legacy = records
          .map((record) {
            final json = record.toJson()..['v'] = 1;
            return jsonEncode(json);
          })
          .join('\n');
      File(
        '${storeDir.path}/$transferJournalFileName',
      ).writeAsStringSync('$legacy\n');

      final io = ScriptedIo();
      final store = await openStore(io: io);

      final journalRewrite = io.ops.indexOf('rewrite:journal');
      final historyAppend = io.ops.indexOf('append:history');
      expect(journalRewrite, isNonNegative);
      expect(historyAppend, isNonNegative);
      expect(journalRewrite, lessThan(historyAppend));

      final firstRewrite = const LineSplitter()
          .convert(io.journalRewriteContents.first)
          .map((line) => jsonDecode(line) as Map<String, Object?>)
          .toList();
      expect(firstRewrite.map((record) => record['taskId']), [
        'done',
        'done',
        'live',
      ]);
      expect(
        firstRewrite.every(
          (record) => record['v'] == transferJournalSchemaVersion,
        ),
        isTrue,
      );
      await store.shutdown();
    });

    test('a torn history tail truncates and reports', () async {
      final store = await openStore();
      store.appendHistory(historyEntry('h1'));
      await store.flush();
      // A crash mid-append — no shutdown (a clean shutdown's compaction
      // would append behind the torn tail, burying it mid-file).
      await store.historyFile.writeAsString(
        '{"v":1,"type":"transferHis',
        mode: FileMode.append,
        flush: true,
      );

      final reopened = await openStore();
      expect(reopened.replay.tornHistoryBytes, greaterThan(0));
      expect(reopened.history, hasLength(1));
      await reopened.shutdown();
    });

    test('abandoned rewrite temps are swept at open', () async {
      await openStore().then((s) => s.shutdown());
      final temp = File(
        '${storeDir.path}/$transferJournalFileName.tmp-deadbeef',
      );
      await temp.writeAsString('partial');
      await temp.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      await openStore().then((s) => s.shutdown());
      expect(temp.existsSync(), isFalse);
    });
  });

  group('compaction', () {
    test('finished tasks migrate to history; the journal keeps only '
        'pending record sets', () async {
      final store = await openStore();
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(fileEntry('done', 'i1', '/a/f', '/dest/f'));
      store.appendJournal(
        ScanCompleteRecord(taskId: 'done', totalBytes: 5, skippedSymlinks: 0),
      );
      store.appendJournal(
        FileCompletedRecord(taskId: 'done', itemId: 'i1'),
      );
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      store.appendJournal(enqueued('live', localToRemoteSpec(rootPaths: ['/b'])));
      store.appendJournal(fileEntry('live', 'i2', '/b/g', '/dest/g'));
      await store.flush();

      // Startup compaction migrates the finished task.
      final reopened = await openStore();
      expect(reopened.replay.tasks.single.taskId, 'live');
      expect(reopened.history, hasLength(1));
      expect(reopened.history.single.taskId, 'done');

      final lines = journalLines(store.journalFile);
      final records = lines.map(TransferJournalRecord.parse).toList();
      expect(records.every((r) => r.taskId == 'live'), isTrue);
      // The pending task's full record set survived — taskEnqueued plus
      // the planEntry.
      expect(
        records.whereType<TaskEnqueuedRecord>(),
        hasLength(1),
      );
      expect(records.whereType<PlanEntryRecord>(), hasLength(1));
      await reopened.shutdown();
    });

    test('history ids are idempotent — a pre-recorded task is not '
        'appended twice', () async {
      final store = await openStore();
      store.appendHistory(historyEntry('done'));
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      await store.flush();

      final reopened = await openStore();
      expect(reopened.history, hasLength(1));
      await reopened.shutdown();
    });

    test('an append issued during a gated rewrite lands on the new '
        'journal — the single-writer chain makes stale-handle loss '
        'impossible', () async {
      final io = ScriptedIo();
      // Compact on every finished task.
      final store = await openStore(io: io, compactFinishedTasks: 1);
      final openRewrites = io.rewriteCalls;
      // Arm the gate AFTER open — the startup compaction rewrites too.
      io.rewriteGate = Completer();
      store.appendJournal(enqueued('done', localToRemoteSpec(rootPaths: ['/a'])));
      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      // The compaction rewrite is now gated in flight.
      await pumpUntil(
        () => io.rewriteCalls > openRewrites,
        reason: 'no mid-session rewrite',
      );
      // Queue an append behind it — it must land on the rewritten file.
      store.appendJournal(enqueued('late', localToRemoteSpec(rootPaths: ['/z'])));
      io.rewriteGate!.complete();
      await store.flush();

      final records = journalLines(store.journalFile)
          .map(TransferJournalRecord.parse)
          .toList();
      expect(records.single.taskId, 'late');
      await store.shutdown();
    });

    int journalRewrites(ScriptedIo io) =>
        io.ops.where((op) => op == 'rewrite:journal').length;

    test('a pending task past the byte threshold never rewrites the '
        'journal mid-session, where every append used to', () async {
      final io = ScriptedIo();
      // The byte trigger scaled down 64x: 2 000 planEntry records are
      // several times this, as a ~5 000-file task is at the real 4 MiB.
      const compactBytes = 64 * 1024;
      final store = await openStore(io: io, compactBytes: compactBytes);
      final openRewrites = journalRewrites(io);
      store.appendJournal(
        enqueued('big', localToRemoteSpec(rootPaths: ['/src'])),
      );
      for (var i = 0; i < 2000; i++) {
        store.appendJournal(
          fileEntry('big', 'i$i', '/src/IMG_$i.jpg', '/dest/IMG_$i.jpg'),
        );
      }
      await store.flush();

      expect(store.journalFile.lengthSync(), greaterThan(compactBytes));
      // Nothing is finished, so a rewrite would reproduce the file.
      expect(journalRewrites(io) - openRewrites, 0);
      // Restore is unchanged: a crash here replays every item.
      final reopened = await openStore();
      expect(reopened.replay.tasks.single.items, hasLength(2000));
    });

    test('finished tasks beside a large pending task compact once '
        'dropping them reclaims what the rewrite writes', () async {
      final io = ScriptedIo();
      // The finished-task trigger at its most eager.
      final store = await openStore(io: io, compactFinishedTasks: 1);
      store.appendJournal(
        enqueued('big', localToRemoteSpec(rootPaths: ['/src'])),
      );
      for (var i = 0; i < 200; i++) {
        store.appendJournal(
          fileEntry('big', 'i$i', '/src/IMG_$i.jpg', '/dest/IMG_$i.jpg'),
        );
      }
      await store.flush();
      final rewritesBefore = journalRewrites(io);
      final appendedBefore = io.journalAppendBytes;
      final rewrittenBefore = io.journalRewriteBytes;

      for (var t = 0; t < 200; t++) {
        store.appendJournal(
          enqueued('t$t', localToRemoteSpec(rootPaths: ['/r$t'])),
        );
        store.appendJournal(
          TaskStateRecord(taskId: 't$t', state: TransferTaskState.completed),
        );
      }
      await store.flush();

      // The finished tasks still leave the journal, but no rewrite writes
      // more than the finished records it drops. One rewrite per finished
      // task used to copy the pending task 200 times.
      expect(journalRewrites(io) - rewritesBefore, greaterThan(0));
      expect(
        io.journalRewriteBytes - rewrittenBefore,
        lessThanOrEqualTo(io.journalAppendBytes - appendedBefore),
      );
      final reopened = await openStore();
      expect(reopened.replay.tasks.single.taskId, 'big');
      expect(reopened.replay.tasks.single.items, hasLength(200));
    });

    test('a finished task past the byte threshold still compacts '
        'mid-session beside a pending one', () async {
      final io = ScriptedIo();
      final store = await openStore(io: io, compactBytes: 16 * 1024);
      store.appendJournal(
        enqueued('live', localToRemoteSpec(rootPaths: ['/b'])),
      );
      store.appendJournal(fileEntry('live', 'l1', '/b/g', '/dest/g'));
      store.appendJournal(
        enqueued('done', localToRemoteSpec(rootPaths: ['/a'])),
      );
      for (var i = 0; i < 200; i++) {
        store.appendJournal(
          fileEntry('done', 'i$i', '/a/IMG_$i.jpg', '/dest/IMG_$i.jpg'),
        );
      }
      await store.flush();
      final rewritesBefore = journalRewrites(io);

      store.appendJournal(
        TaskStateRecord(taskId: 'done', state: TransferTaskState.completed),
      );
      await store.flush();

      expect(journalRewrites(io) - rewritesBefore, 1);
      expect(store.history.single.taskId, 'done');
      final records = journalLines(store.journalFile)
          .map(TransferJournalRecord.parse)
          .toList();
      expect(records.every((r) => r.taskId == 'live'), isTrue);
      expect(records, hasLength(2));
    });

    test('a retried task counts as pending until it finishes again', () async {
      final io = ScriptedIo();
      final store = await openStore(io: io, compactFinishedTasks: 2);
      final openRewrites = journalRewrites(io);
      void task(String id, int files) {
        store.appendJournal(
          enqueued(id, localToRemoteSpec(rootPaths: ['/$id'])),
        );
        for (var i = 0; i < files; i++) {
          store.appendJournal(fileEntry(id, 'i$i', '/$id/f$i', '/dest/f$i'));
        }
      }

      void state(String id, TransferTaskState state) =>
          store.appendJournal(TaskStateRecord(taskId: id, state: state));

      task('a', 60);
      task('b', 50);
      state('a', TransferTaskState.failed);
      state('a', TransferTaskState.queued);
      state('b', TransferTaskState.completed);
      await store.flush();
      // Two tasks finished, but dropping 'b' would rewrite the larger
      // retried 'a'.
      expect(journalRewrites(io) - openRewrites, 0);

      state('a', TransferTaskState.completed);
      await store.flush();
      expect(journalRewrites(io) - openRewrites, 1);
      expect(journalLines(store.journalFile), isEmpty);
      expect(store.history.map((entry) => entry.taskId), ['a', 'b']);
    });
  });

  group('journal codec', () {
    /// A valid managed-checkout taskEnqueued record as mutable JSON —
    /// the tamper surface for the strict-decode tests.
    Map<String, Object?> managedEnqueuedJson() {
      final spec = TransferTaskSpec(
        source: const LocalFsLocation(),
        destination: const ServerFsLocation('s1'),
        rootPaths: const ['/src/a.txt'],
        destinationDir: '/dest',
        policy: ResolvedConflictPolicy(files: ConflictResolution.skip),
        managedCheckout: const ManagedCheckoutSpec(
          checkoutId: 'edit-1',
          serverId: 's1',
          remotePath: '/r/a.txt',
          localPath: '/l/a.txt',
          direction: ManagedCheckoutDirection.upload,
        ),
      );
      final record = enqueued('t1', spec);
      return (jsonDecode(jsonEncode(record.toJson())) as Map)
          .cast<String, Object?>();
    }

    String lineOf(Map<String, Object?> json) => jsonEncode(json);

    test('a managed-checkout spec round-trips through the journal',
        () {
      final parsed = TransferJournalRecord.parse(
        lineOf(managedEnqueuedJson()),
      );
      final spec = (parsed as TaskEnqueuedRecord).spec;
      expect(spec.managedCheckout, isNotNull);
      expect(spec.managedCheckout!.checkoutId, 'edit-1');
      expect(
        spec.managedCheckout!.direction,
        ManagedCheckoutDirection.upload,
      );
    });

    test('terminal failure retry policy round-trips and defaults safely', () {
      final defaulted = FileFailedRecord(taskId: 't1', itemId: 'i1');
      expect(
        defaulted.retryPolicy,
        TransferFailureRetryPolicy.terminal,
      );

      final retryable = FileFailedRecord(
        taskId: 't1',
        itemId: 'i1',
        retryPolicy: TransferFailureRetryPolicy.retryable,
      );
      final parsedRetryable =
          TransferJournalRecord.parse(jsonEncode(retryable.toJson()))
              as FileFailedRecord;
      expect(parsedRetryable.retryPolicy, TransferFailureRetryPolicy.retryable);

      final record = FileFailedRecord(
        taskId: 't1',
        itemId: 'i1',
        retryPolicy: TransferFailureRetryPolicy.terminal,
      );
      final parsed =
          TransferJournalRecord.parse(jsonEncode(record.toJson()))
              as FileFailedRecord;
      expect(parsed.retryPolicy, TransferFailureRetryPolicy.terminal);

      final legacy = record.toJson()..remove('retryPolicy');
      final parsedLegacy =
          TransferJournalRecord.parse(jsonEncode(legacy)) as FileFailedRecord;
      expect(parsedLegacy.retryPolicy, TransferFailureRetryPolicy.terminal);
    });

    test('schema v2 reads v1 records and gates durable claims', () {
      final legacyTask = managedEnqueuedJson()..['v'] = 1;
      expect(
        TransferJournalRecord.parse(lineOf(legacyTask)),
        isA<TaskEnqueuedRecord>(),
      );

      final claim = DestinationClaimedRecord(
        taskId: 't1',
        itemId: 'i1',
        destinationPath: '/dest/a (2).txt',
      );
      final parsed =
          TransferJournalRecord.parse(jsonEncode(claim.toJson()))
              as DestinationClaimedRecord;
      expect(parsed.destinationPath, '/dest/a (2).txt');

      final mislabeledLegacyClaim = claim.toJson()..['v'] = 1;
      expect(
        () => TransferJournalRecord.parse(jsonEncode(mislabeledLegacyClaim)),
        throwsA(isA<FormatException>()),
      );
    });

    test('destination comparison round-trips with scan completion', () {
      final record = ScanCompleteRecord(
        taskId: 't1',
        totalBytes: 5,
        skippedSymlinks: 0,
        destinationNameComparison: DestinationNameComparison.normalized,
      );

      final parsed =
          TransferJournalRecord.parse(jsonEncode(record.toJson()))
              as ScanCompleteRecord;

      expect(
        parsed.destinationNameComparison,
        DestinationNameComparison.normalized,
      );
    });

    test('a non-object managedCheckout field is refused', () {
      final json = managedEnqueuedJson();
      (json['spec'] as Map<String, Object?>)['managedCheckout'] = 'junk';
      expect(
        () => TransferJournalRecord.parse(lineOf(json)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a managedCheckout payload on a non-copy spec is refused', () {
      final json = managedEnqueuedJson();
      final spec = json['spec'] as Map<String, Object?>;
      spec['operation'] = 'delete';
      spec['disposition'] = 'trash';
      expect(
        () => TransferJournalRecord.parse(lineOf(json)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-object expectedTarget inside the spec is refused', () {
      final json = managedEnqueuedJson();
      final spec = json['spec'] as Map<String, Object?>;
      (spec['managedCheckout'] as Map<String, Object?>)['expectedTarget'] =
          'junk';
      expect(
        () => TransferJournalRecord.parse(lineOf(json)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('history', () {
    test('records survive a restart', () async {
      final store = await openStore();
      store.appendHistory(historyEntry('h1'));
      store.appendHistory(historyEntry('h2'));
      await store.flush();
      await store.shutdown();

      final reopened = await openStore();
      expect(
        reopened.history.map((e) => e.taskId),
        ['h1', 'h2'],
      );
      await reopened.shutdown();
    });

    test('the cap trims only after the 10% slack and keeps the newest',
        () async {
      final store = await openStore(historyLimit: 10);
      for (var i = 0; i < 11; i++) {
        store.appendHistory(historyEntry('h$i'));
      }
      await store.flush();
      // 11 records = cap + slack: not yet trimmed.
      expect(journalLines(store.historyFile), hasLength(11));

      store.appendHistory(historyEntry('h11'));
      await store.flush();
      final lines = journalLines(store.historyFile);
      expect(lines, hasLength(10));
      final kept = lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .map((j) => j['taskId'])
          .toList();
      expect(kept.first, 'h2');
      expect(kept.last, 'h11');
      await store.shutdown();
    });

    test('trim preserves unknown fields from upgraded history', () async {
      await storeDir.create(recursive: true);
      final old = historyEntry('h0').toJson()..['v'] = 1;
      final retained = historyEntry('h1').toJson()
        ..['v'] = 1
        ..['futureField'] = {'retained': true};
      File(
        '${storeDir.path}/$transferHistoryFileName',
      ).writeAsStringSync('${jsonEncode(old)}\n${jsonEncode(retained)}\n');

      final store = await openStore(historyLimit: 2);
      store.appendHistory(historyEntry('h2'));
      await store.flush();

      final records = journalLines(
        store.historyFile,
      ).map((line) => jsonDecode(line) as Map<String, Object?>).toList();
      expect(records.map((record) => record['taskId']), ['h1', 'h2']);
      expect(records.first['v'], transferJournalSchemaVersion);
      expect(records.first['futureField'], {'retained': true});
      await store.shutdown();
    });
  });

  group('fsync policy', () {
    test('journal fsyncs at the record boundary and before history',
        () async {
      final io = ScriptedIo();
      final store = await openStore(io: io, fsyncEveryRecords: 2);
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      io.ops.clear();

      // The second record's boundary fsync fires inside the writer
      // chain — no explicit flush needed.
      store.appendJournal(
        TaskStateRecord(taskId: 't1', state: TransferTaskState.paused),
      );
      await pumpUntil(
        () => io.ops.contains('fsync:journal'),
        reason: 'record-boundary fsync never fired',
      );

      // 03 §4.6 ordering: a task's history row is never durable before
      // the journal describing it — the journal fsync precedes the
      // history append inside the serialized chain.
      io.ops.clear();
      store.appendHistory(historyEntry('t1'));
      await store.flush();
      final historyAppend = io.ops.indexOf('append:history');
      expect(historyAppend, greaterThan(0));
      expect(io.ops[historyAppend - 1], 'fsync:journal');
      await store.shutdown();
    });

    test('flush after shutdown performs no I/O', () async {
      final io = ScriptedIo();
      final store = await openStore(io: io);
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await store.flush();
      await store.shutdown();
      final opsAfterShutdown = io.ops.length;
      await store.flush();
      // Post-shutdown a flush must not resurrect the write chain —
      // Windows temp-dir teardown is where a stray handle bites.
      expect(io.ops, hasLength(opsAfterShutdown));
    });

    test('flush reports an earlier journal append failure', () async {
      final io = ScriptedIo()..failOnAppend = 1;
      final store = await openStore(io: io);
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));

      await expectLater(store.flush(), throwsA(isA<FileSystemException>()));
    });

    test('append failure cancels an armed fsync timer', () async {
      const fsyncInterval = Duration(milliseconds: 100);
      final io = ScriptedIo();
      final store = await openStore(
        io: io,
        fsyncEveryRecords: 100,
        fsyncInterval: fsyncInterval,
      );
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await pumpUntil(
        () => io.appendCalls == 1,
        reason: 'the first journal append never armed its fsync timer',
      );
      io.failOnAppend = 2;

      await expectLater(
        store.appendJournalDurably(
          TaskStateRecord(taskId: 't1', state: TransferTaskState.paused),
        ),
        throwsA(isA<FileSystemException>()),
      );
      await Future<void>.delayed(fsyncInterval * 2);

      expect(io.fsyncCalls, 0);
    });

    test('fired fsync timer stops behind a failing append', () async {
      const fsyncInterval = Duration(milliseconds: 100);
      final appendGate = Completer<void>();
      final io = ScriptedIo()
        ..failAfterGateOnAppend = 2
        ..journalAppendGates[TaskStateRecord.wireType] = appendGate;
      final store = await openStore(
        io: io,
        fsyncEveryRecords: 100,
        fsyncInterval: fsyncInterval,
      );
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await pumpUntil(
        () => io.appendCalls == 1,
        reason: 'the first journal append never armed its fsync timer',
      );
      final failingAppend = store.appendJournalDurably(
        TaskStateRecord(taskId: 't1', state: TransferTaskState.paused),
      );
      await pumpUntil(
        () => io.journalAppendTypesStarted.contains(TaskStateRecord.wireType),
        reason: 'the failing append never reached its gate',
      );

      await Future<void>.delayed(fsyncInterval * 2);
      appendGate.complete();
      await expectLater(
        failingAppend,
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(store.flush(), throwsA(isA<FileSystemException>()));

      expect(io.fsyncCalls, 0);
    });

    test('flush reports an earlier timer fsync failure', () async {
      final io = ScriptedIo()..failOnFsync = 1;
      final store = await openStore(
        io: io,
        fsyncEveryRecords: 100,
        fsyncInterval: const Duration(milliseconds: 1),
      );
      store.appendJournal(enqueued('t1', localToRemoteSpec(rootPaths: ['/r'])));
      await pumpUntil(
        () => io.fsyncCalls == 1,
        reason: 'the timer fsync never ran',
      );

      await expectLater(store.flush(), throwsA(isA<FileSystemException>()));
    });
  });

  group('queue integration', () {
    late FakeTreeFileSystem s1;
    late FakeQueueConnectionManager connections;
    late Directory localSrc;
    final createdQueues = <TransferQueue>[];

    TransferQueue newQueue({TransferPersistence? persistence}) {
      final created = TransferQueue(
        connections: connections,
        persistence: persistence,
      );
      createdQueues.add(created);
      return created;
    }

    setUp(() async {
      s1 = FakeTreeFileSystem();
      s1.addDirectory('/dest');
      connections = FakeQueueConnectionManager({'s1': s1});
      localSrc = Directory('${tempDir.path}/src')..createSync();
    });

    tearDown(() async {
      for (final queue in createdQueues) {
        await queue.dispose();
      }
      createdQueues.clear();
    });

    test('journal calls precede the state transitions they describe',
        () async {
      final recording = RecordingPersistence();
      final queue = newQueue(persistence: recording);
      final seenAtAppend = <String>[];
      queue.events.listen((_) {});

      File('${localSrc.path}/a.txt').writeAsStringSync('hello');
      recording.onAppend = (record) {
        final task = queue.tasks
            .where((t) => t.id == record.taskId)
            .firstOrNull;
        seenAtAppend.add(
          task == null ? 'absent' : task.state.name,
        );
      };
      // Gate the upload so the task is provably mid-flight at pause.
      final uploadGate = Completer<void>();
      s1.uploadGate = (_) => uploadGate;
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      // taskEnqueued was journaled before the task became visible.
      expect(recording.journal.first, isA<TaskEnqueuedRecord>());
      expect(seenAtAppend.first, 'absent');

      await pumpUntil(() => s1.uploadCalls > 0, reason: 'upload not armed');
      recording.onAppend = (record) {
        if (record is TaskStateRecord) {
          seenAtAppend.add('saw:${task.state.name}');
        }
      };
      queue.pauseTask(task.id);
      final paused = recording.journal.whereType<TaskStateRecord>().last;
      expect(paused.state, TransferTaskState.paused);
      // The record reached the seam before task.state mutated.
      expect(seenAtAppend.last, isNot('saw:paused'));
      uploadGate.complete();
      queue.resumeTask(task.id);
      await awaitTaskDone(task);
    });

    test('a completed transfer journals lifecycle + writes history',
        () async {
      final store = await openStore();
      final queue = newQueue(persistence: store);
      File('${localSrc.path}/a.txt').writeAsStringSync('hello');
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      await store.flush();

      final types = journalLines(store.journalFile)
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .map((j) => j['type'])
          .toList();
      expect(types.first, 'taskEnqueued');
      expect(types, contains('planEntry'));
      expect(types, contains('scanComplete'));
      expect(types, contains('fileCompleted'));
      expect(types.last, 'taskState');
      expect(store.history.single.taskId, task.id);
      expect(store.history.single.outcome, TransferTaskState.completed);
    });

    test('restore maps a crashed running task to queued under the '
        'forced queue pause; resume finishes it without re-transferring '
        'completed items', () async {
      // Craft a crashed session's journal: one file done, one pending.
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/done.txt')..writeAsStringSync('done!');
      final f2 = File('${localSrc.path}/todo.txt')
        ..writeAsStringSync('todo?');
      final spec = localToRemoteSpec(
        rootPaths: [f1.path, f2.path],
      );
      crashed.appendJournal(enqueued('task-1', spec));
      crashed.appendJournal(
        fileEntry('task-1', 'item-done', f1.path, '/dest/done.txt', size: 5),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'item-todo',
          f2.path,
          '/dest/todo.txt',
          size: 5,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'task-1',
          totalBytes: 10,
          skippedSymlinks: 0,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'item-done'),
      );
      await crashed.flush();
      // Simulate the crash: no shutdown — abandon the store with its
      // writes already flushed.
      final uploadsBefore = s1.uploadCalls;

      final store = await openStore();
      expect(store.replay.tasks, hasLength(1));

      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      expect(restored.id, 'task-1');
      // §4.6: running/scanning map to queued; the runtime queue-level
      // pause flag (never journaled) holds admission until Resume.
      expect(restored.state, TransferTaskState.queued);
      expect(queue.isPaused, isTrue);
      expect(restored.scanComplete, isTrue);
      expect(
        restored.items.where((i) => i.id == 'item-done').single.state,
        TransferItemState.completed,
      );

      queue.resumeQueue();
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      // Only the pending item transferred — the completed one did not
      // resurrect.
      expect(s1.uploadCalls - uploadsBefore, 1);
      expect(s1.entryAt('/dest/todo.txt'), isNotNull);
      await store.flush();
      expect(store.history.single.taskId, 'task-1');
    });

    test('a mid-scan crash re-scans on resume and merges journaled '
        'outcomes by destination path', () async {
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/done.txt')..writeAsStringSync('done!');
      File('${localSrc.path}/todo.txt').writeAsStringSync('todo?');
      // The root is a directory, so children land under its leaf name:
      // the journaled destinationPath must match the re-scan's join.
      final spec = localToRemoteSpec(rootPaths: [localSrc.path]);
      crashed.appendJournal(enqueued('task-1', spec));
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'task-1',
          itemId: 'item-done',
          isDirectory: false,
          sourcePath: f1.path,
          destinationPath: '/dest/src/done.txt',
          sourceType: RemoteFileType.file,
          sourceSize: 5,
          containerKey: null,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'item-done'),
      );
      // No scanComplete — the crash hit mid-scan.
      await crashed.flush();
      final uploadsBefore = s1.uploadCalls;

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      // §4.6: not journaled-paused → queued under the forced queue-level
      // pause; the re-scan waits for Resume too, so the task visibly
      // stays queued and acquires no leases while restored-parked.
      expect(queue.isPaused, isTrue);
      expect(restored.state, TransferTaskState.queued);
      expect(restored.scanComplete, isFalse);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(restored.state, TransferTaskState.queued);
      expect(restored.scanComplete, isFalse);
      expect(s1.uploadCalls - uploadsBefore, 0);

      queue.resumeQueue();
      await pumpUntil(
        () => restored.scanComplete,
        reason: 're-scan never completed after resumeQueue',
      );
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      // The re-scan rediscovered both files; only the journaled-pending
      // one transferred (the done item merged and stayed completed).
      expect(s1.uploadCalls - uploadsBefore, 1);
      expect(s1.entryAt('/dest/src/todo.txt'), isNotNull);
      expect(s1.entryAt('/dest/src/done.txt'), isNull);
      expect(
        restored.items
            .where((i) => i.destinationPath == '/dest/src/done.txt')
            .single
            .state,
        TransferItemState.completed,
      );
    });

    test('a task journaled paused stays paused through resumeQueue '
        'until its own resumeTask', () async {
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/a.txt')..writeAsStringSync('hi!');
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: [f1.path])),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'item-a', f1.path, '/dest/a.txt', size: 3),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'task-1',
          totalBytes: 3,
          skippedSymlinks: 0,
        ),
      );
      crashed.appendJournal(
        TaskStateRecord(
          taskId: 'task-1',
          state: TransferTaskState.paused,
        ),
      );
      await crashed.flush();
      final uploadsBefore = s1.uploadCalls;

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      // §4.6: a per-task journaled pause survives restart on top of the
      // forced queue-level pause.
      expect(restored.state, TransferTaskState.paused);
      expect(queue.isPaused, isTrue);
      final probesBefore = s1.nameProbeCalls.length;

      queue.resumeQueue();
      for (var i = 0; i < 50 && s1.uploadCalls == uploadsBefore; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(restored.state, TransferTaskState.paused);
      expect(s1.uploadCalls - uploadsBefore, 0);
      expect(s1.nameProbeCalls, hasLength(probesBefore));

      queue.resumeTask(restored.id);
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      expect(s1.uploadCalls - uploadsBefore, 1);
      expect(s1.entryAt('/dest/a.txt'), isNotNull);
    });

    test('a still-pending conflict re-prompts fresh after restart — '
        'session prompt state is never journaled (03 §4.6)', () async {
      // A crashed session mid-prompt: the journaled record set is just
      // the still-pending item — the prompt itself was runtime state.
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/a.txt')..writeAsStringSync('new');
      s1.addFile('/dest/a.txt', 'old'.codeUnits);
      crashed.appendJournal(
        enqueued(
          'task-1',
          localToRemoteSpec(
            rootPaths: [f1.path],
            files: ConflictResolution.ask,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'i1', f1.path, '/dest/a.txt', size: 3),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 3, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      // The journaled-pending item re-dispatched, re-stat'd the occupant,
      // and parked on a fresh prompt — not a remembered answer.
      await pumpUntil(
        () => queue.pendingConflicts.isNotEmpty,
        reason: 'the restored conflict never re-surfaced',
      );
      final item = restored.items.single;
      expect(item.state, TransferItemState.conflictPending);
      expect(
        queue.resolveConflict(restored.id, item.id, ConflictResolution.skip),
        isTrue,
      );
      await awaitTaskDone(restored);
      expect(item.state, TransferItemState.skipped);
      expect(s1.fileBytes['/dest/a.txt'], 'old'.codeUnits);
    });

    test('a cancelled task does not restore', () async {
      final crashed = await openStore();
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: ['/r'])),
      );
      crashed.appendJournal(
        TaskStateRecord(
          taskId: 'task-1',
          state: TransferTaskState.cancelled,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      expect(store.replay.tasks, isEmpty);
      final queue = newQueue(persistence: store);
      await queue.restore();
      expect(queue.tasks, isEmpty);
      await queue.dispose();
    });

    test('removeTask journals the removal and the task does not restore',
        () async {
      // Drive the production API: a completed task removed from the
      // listing, not a hand-appended record.
      final store = await openStore();
      final queue = newQueue(persistence: store);
      File('${localSrc.path}/a.txt').writeAsStringSync('bye!');
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      await awaitTaskDone(task);
      queue.removeTask(task.id);
      await store.flush();
      expect(
        journalLines(store.journalFile)
            .map(TransferJournalRecord.parse)
            .whereType<TaskRemovedRecord>(),
        hasLength(1),
      );
      // Clean-shutdown compaction writes the history row.
      await store.shutdown();

      final reopened = await openStore();
      expect(reopened.replay.tasks, isEmpty);
      expect(reopened.history.single.taskId, task.id);
      expect(reopened.history.single.outcome, TransferTaskState.completed);
    });

    test('restore sweeps orphaned upload temps in journaled directories '
        'only', () async {
      // Plant a dead temp plus a look-alike that is NOT ours.
      s1.addFile('/dest/.seance-upload-deadbeef.tmp', [1]);
      s1.addFile('/dest/.poltergeist-12345678.tmp', [2]);
      s1.addFile('/dest/keep.txt', [3]);
      s1.addFile('/elsewhere/.seance-upload-99999999.tmp', [4]);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: ['/r'])),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'i1', '/r/f', '/dest/f'),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 5, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();

      // Sweeps are fire-and-forget — they land shortly after restore,
      // not inside it.
      await pumpUntil(
        () => s1.entryAt('/dest/.seance-upload-deadbeef.tmp') == null,
        reason: 'orphaned temp never swept',
      );
      expect(s1.entryAt('/dest/.poltergeist-12345678.tmp'), isNull);
      expect(s1.entryAt('/dest/keep.txt'), isNotNull);
      expect(
        s1.entryAt('/elsewhere/.seance-upload-99999999.tmp'),
        isNotNull,
      );
    });

    test('restore sweeps temps below a keep-both-renamed directory', () async {
      const resolvedDirectory = '/dest/folder (2)';
      const orphan = '$resolvedDirectory/.poltergeist-deadbeef.tmp';
      s1
        ..addDirectory(resolvedDirectory)
        ..addFile(orphan, [1]);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: const ['/folder'])),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'task-1',
          itemId: 'directory',
          isDirectory: true,
          sourcePath: '/folder',
          destinationPath: '/dest/folder',
          sourceType: RemoteFileType.directory,
        ),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'task-1',
          itemId: 'directory',
          destinationPath: resolvedDirectory,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: 'task-1',
          itemId: 'directory',
          resolvedPath: resolvedDirectory,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();

      await pumpUntil(
        () => s1.entryAt(orphan) == null,
        reason: 'renamed-directory temp never swept',
      );
    });

    test('a queued restore whose items all ended terminal drains to '
        'completed without a resume', () async {
      // The task's terminal record was the torn tail — every journaled
      // item already finished, so restore drains the task to its honest
      // terminal state instead of stranding it queued forever.
      final crashed = await openStore();
      final f1 = File('${localSrc.path}/a.txt')..writeAsStringSync('done');
      crashed.appendJournal(
        enqueued('task-1', localToRemoteSpec(rootPaths: [f1.path])),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'item-a', f1.path, '/dest/a.txt', size: 4),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 4, skippedSymlinks: 0),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'item-a'),
      );
      // No taskState:completed — that record died with the crash.
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      await pumpUntil(
        () => store.history.isNotEmpty,
        reason: 'history row never written',
      );
      expect(store.history.single.taskId, 'task-1');
      // Set before the rebuild — the row carries the real totals.
      expect(store.history.single.totalBytes, 4);
      // Nothing re-transferred — every journaled item was already done.
      expect(s1.uploadCalls, 0);
    });

    test('a mid-scan merge matches sources before refusing a restored '
        'destination collision', () async {
      // Two roots with the same leaf name both plan to /dest/f.txt.
      final dirA = Directory('${tempDir.path}/dirA')..createSync();
      final dirB = Directory('${tempDir.path}/dirB')..createSync();
      File('${dirA.path}/f.txt').writeAsStringSync('AAA');
      File('${dirB.path}/f.txt').writeAsStringSync('BBBB');
      final spec = localToRemoteSpec(
        rootPaths: ['${dirA.path}/f.txt', '${dirB.path}/f.txt'],
      );
      final crashed = await openStore();
      crashed.appendJournal(enqueued('task-1', spec));
      // Journal order opposes scan order: pending i2 first, completed
      // i1 second — a destination-only merge would pop i2 for A's file.
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'i2',
          '${dirB.path}/f.txt',
          '/dest/f.txt',
          size: 4,
        ),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'i1',
          '${dirA.path}/f.txt',
          '/dest/f.txt',
          size: 3,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(taskId: 'task-1', itemId: 'i1'),
      );
      // Mid-scan: no scanComplete.
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);
      expect(restored.state, TransferTaskState.completed);
      // i1 kept its completed outcome under its source. The colliding i2
      // row honored Skip before upload instead of replacing that output.
      expect(s1.uploadCalls, 0);
      expect(
        restored.items.where((i) => i.id == 'i1').single.state,
        TransferItemState.completed,
      );
      expect(
        restored.items.where((i) => i.id == 'i2').single.state,
        TransferItemState.skipped,
      );
    });

    test('a fully-scanned legacy restore refuses a duplicate '
        'destination under replace', () async {
      final dirA = Directory('${tempDir.path}/legacyA')..createSync();
      final dirB = Directory('${tempDir.path}/legacyB')..createSync();
      final fileA = File('${dirA.path}/f.txt')..writeAsStringSync('AAA');
      final fileB = File('${dirB.path}/f.txt')..writeAsStringSync('BBBB');
      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          localToRemoteSpec(
            rootPaths: [fileA.path, fileB.path],
            files: ConflictResolution.replace,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'i1', fileA.path, '/dest/f.txt', size: 3),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'i2', fileB.path, '/dest/f.txt', size: 4),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 7, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.failed);
      expect(s1.uploadCalls, 1);
      expect(s1.fileBytes['/dest/f.txt'], 'AAA'.codeUnits);
      expect(
        restored.items.where((i) => i.id == 'i1').single.state,
        TransferItemState.completed,
      );
      expect(
        restored.items.where((i) => i.id == 'i2').single.state,
        TransferItemState.failed,
      );
      expect(
        restored.items.where((i) => i.id == 'i2').single.failureKind,
        RemoteFileErrorKind.conflict,
      );
    });

    test(
      'a fully-scanned restore keeps the probed exact-name identity',
      () async {
        final fileA = File('${localSrc.path}/upper/A.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('upper');
        final fileB = File('${localSrc.path}/lower/a.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('lower');
        final crashed = await openStore();
        crashed.appendJournal(
          enqueued(
            'task-1',
            localToRemoteSpec(
              rootPaths: [fileA.path, fileB.path],
              files: ConflictResolution.replace,
            ),
          ),
        );
        crashed.appendJournal(
          fileEntry('task-1', 'upper', fileA.path, '/dest/A.txt', size: 5),
        );
        crashed.appendJournal(
          fileEntry('task-1', 'lower', fileB.path, '/dest/a.txt', size: 5),
        );
        crashed.appendJournal(
          ScanCompleteRecord(
            taskId: 'task-1',
            totalBytes: 10,
            skippedSymlinks: 0,
            destinationNameComparison: DestinationNameComparison.exact,
          ),
        );
        await crashed.flush();

        final store = await openStore();
        final queue = newQueue(persistence: store);
        await queue.restore();
        queue.resumeQueue();
        final restored = queue.tasks.single;
        await awaitTaskDone(restored);

        expect(restored.state, TransferTaskState.completed);
        expect(s1.uploadCalls, 2);
        expect(s1.fileBytes['/dest/A.txt'], 'upper'.codeUnits);
        expect(s1.fileBytes['/dest/a.txt'], 'lower'.codeUnits);
      },
    );

    test(
      'fully-scanned restore revalidates an exact destination retarget',
      () async {
        final fileA = File('${localSrc.path}/upper/A.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('upper');
        final fileB = File('${localSrc.path}/lower/a.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('lower');
        final crashed = await openStore();
        crashed.appendJournal(
          enqueued(
            'task-1',
            localToRemoteSpec(
              rootPaths: [fileA.path, fileB.path],
              files: ConflictResolution.replace,
              operation: TransferOperation.move,
            ),
          ),
        );
        crashed.appendJournal(
          fileEntry('task-1', 'upper', fileA.path, '/dest/A.txt', size: 5),
        );
        crashed.appendJournal(
          fileEntry('task-1', 'lower', fileB.path, '/dest/a.txt', size: 5),
        );
        crashed.appendJournal(
          ScanCompleteRecord(
            taskId: 'task-1',
            totalBytes: 10,
            skippedSymlinks: 0,
            destinationNameComparison: DestinationNameComparison.exact,
          ),
        );
        await crashed.flush();

        // The bookmark or mount now resolves to a case-insensitive volume.
        s1.caseInsensitive = true;
        final store = await openStore();
        final queue = newQueue(persistence: store);
        await queue.restore();
        queue.resumeQueue();
        final restored = queue.tasks.single;
        await awaitTaskDone(restored);

        expect(restored.state, TransferTaskState.failed);
        expect(s1.fileBytes, hasLength(1));
        final survivingPayloads = <String>{
          for (final bytes in s1.fileBytes.values) String.fromCharCodes(bytes),
          if (fileA.existsSync()) fileA.readAsStringSync(),
          if (fileB.existsSync()) fileB.readAsStringSync(),
        };
        expect(survivingPayloads, {'upper', 'lower'});
      },
    );

    test('mid-scan exact replay rekeys every raw output claim', () async {
      const completedSource = '/completed/report.pdf';
      const claimedSource = '/claimed/Report.pdf';
      const pendingSource = '/pending/Report (2).pdf';
      const completedOutput = '/dest/report (2).pdf';
      const claimedOutput = '/dest/Report (2).pdf';
      final source = FakeTreeFileSystem()
        ..addFile(pendingSource, 'literal'.codeUnits);
      connections.filesystems['source'] = source;
      s1.addFile(completedOutput, 'completed'.codeUnits);
      s1.addFile(claimedOutput, 'claimed'.codeUnits);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [completedSource, claimedSource, pendingSource],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(files: ConflictResolution.replace),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'completed', completedSource, '/dest/report.pdf'),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: 'task-1',
          itemId: 'completed',
          resolvedPath: completedOutput,
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'claimed', claimedSource, '/dest/Report.pdf'),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'task-1',
          itemId: 'claimed',
          destinationPath: claimedOutput,
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'pending', pendingSource, claimedOutput, size: 7),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      final pending = restored.items.singleWhere(
        (item) => item.id == 'pending',
      );
      expect(pending.state, TransferItemState.failed);
      expect(pending.failureKind, RemoteFileErrorKind.conflict);
      expect(pending.failureRetryPolicy, TransferFailureRetryPolicy.terminal);
      expect(s1.fileBytes[completedOutput], 'completed'.codeUnits);
      expect(s1.fileBytes[claimedOutput], 'claimed'.codeUnits);
      expect(source.fileBytes[pendingSource], 'literal'.codeUnits);
    });

    test('fully-scanned replay gives completed output priority over an '
        'earlier pending plan', () async {
      final dirA = Directory('${tempDir.path}/completed')..createSync();
      final dirB = Directory('${tempDir.path}/pending')..createSync();
      final fileA = File('${dirA.path}/report.pdf');
      final fileB = File('${dirB.path}/report (2).pdf')
        ..writeAsStringSync('second');
      s1.addFile('/dest/report (2).pdf', 'first'.codeUnits);
      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          localToRemoteSpec(
            rootPaths: [fileA.path, fileB.path],
            files: ConflictResolution.replace,
            operation: TransferOperation.move,
          ),
        ),
      );
      // Legacy journal order must not let a plan outrank committed output.
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'pending',
          fileB.path,
          '/dest/report (2).pdf',
          size: 6,
        ),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'completed',
          fileA.path,
          '/dest/report.pdf',
          size: 5,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: 'task-1',
          itemId: 'completed',
          resolvedPath: '/dest/report (2).pdf',
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'task-1',
          totalBytes: 11,
          skippedSymlinks: 0,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      final pending = restored.items.singleWhere(
        (item) => item.id == 'pending',
      );
      expect(restored.state, TransferTaskState.failed);
      expect(pending.state, TransferItemState.failed);
      expect(pending.failureKind, RemoteFileErrorKind.conflict);
      expect(queue.canRetryItem(restored.id, pending.id), isFalse);
      expect(queue.canRetryTask(restored.id), isFalse);
      expect(s1.uploadCalls, 0);
      expect(s1.fileBytes['/dest/report (2).pdf'], 'first'.codeUnits);
      expect(fileB.readAsStringSync(), 'second');
    });

    test('mid-scan replay keeps completed output when its moved source '
        'vanished', () async {
      final dirA = Directory('${tempDir.path}/completed')..createSync();
      final dirB = Directory('${tempDir.path}/pending')..createSync();
      final fileA = File('${dirA.path}/report.pdf');
      final fileB = File('${dirB.path}/report (2).pdf')
        ..writeAsStringSync('second');
      s1.addFile('/dest/report (2).pdf', 'first'.codeUnits);
      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          localToRemoteSpec(
            rootPaths: [fileA.path, fileB.path],
            files: ConflictResolution.ask,
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'completed',
          fileA.path,
          '/dest/report.pdf',
          size: 5,
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: 'task-1',
          itemId: 'completed',
          resolvedPath: '/dest/report (2).pdf',
        ),
      );
      crashed.appendJournal(
        fileEntry(
          'task-1',
          'pending',
          fileB.path,
          '/dest/report (2).pdf',
          size: 6,
        ),
      );
      // No scanComplete: recovery must re-scan after move removed A.
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await pumpUntil(
        () =>
            restored.isTerminal ||
            queue.pendingConflicts.any(
              (conflict) => conflict.destinationPath == '/dest/report (2).pdf',
            ),
        reason: 'the restored numbered source never settled',
      );
      if (!restored.isTerminal) {
        final pending = restored.items.singleWhere(
          (item) => item.sourcePath == fileB.path,
        );
        expect(
          queue.resolveConflict(
            restored.id,
            pending.id,
            ConflictResolution.replace,
          ),
          isTrue,
        );
      }
      await awaitTaskDone(restored);

      final pending = restored.items.singleWhere(
        (item) => item.sourcePath == fileB.path,
      );
      expect(pending.state, TransferItemState.failed);
      expect(pending.failureKind, RemoteFileErrorKind.conflict);
      expect(queue.canRetryItem(restored.id, pending.id), isFalse);
      expect(queue.canRetryTask(restored.id), isFalse);
      expect(s1.fileBytes['/dest/report (2).pdf'], 'first'.codeUnits);
      expect(fileB.readAsStringSync(), 'second');
    });

    test(
      'a second mid-scan replay keeps a vanished completed output',
      () async {
        const completedSource = '/completed/report.pdf';
        const pendingSource = '/pending/report (2).pdf';
        const completedOutput = '/dest/report (2).pdf';
        s1.addFile(pendingSource, 'second'.codeUnits);
        s1.addFile(completedOutput, 'first'.codeUnits);
        final spec = TransferTaskSpec(
          source: const ServerFsLocation('s1'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const [completedSource, pendingSource],
          destinationDir: '/dest',
          policy: ResolvedConflictPolicy(files: ConflictResolution.ask),
          operation: TransferOperation.move,
        );
        final crashed = await openStore();
        crashed.appendJournal(enqueued('task-1', spec));
        crashed.appendJournal(
          fileEntry('task-1', 'completed', completedSource, '/dest/report.pdf'),
        );
        crashed.appendJournal(
          FileCompletedRecord(
            taskId: 'task-1',
            itemId: 'completed',
            resolvedPath: completedOutput,
          ),
        );
        crashed.appendJournal(
          fileEntry(
            'task-1',
            'pending',
            pendingSource,
            completedOutput,
            size: 6,
          ),
        );
        await crashed.flush();

        // First recovery loses the moved source, then crashes while the
        // later source is still undiscovered.
        final discoveryGate = Completer<void>();
        s1.statGate = (path) => path == pendingSource ? discoveryGate : null;
        final firstStore = await openStore();
        final firstQueue = newQueue(persistence: firstStore);
        await firstQueue.restore();
        firstQueue.resumeQueue();
        final firstRecovery = firstQueue.tasks.single;
        await pumpUntil(
          () => firstRecovery.items.any((item) => item.id == 'completed'),
          reason: 'the vanished completed source was not restored',
        );
        await firstStore.flush();

        // A new process must still treat the completed output as owned.
        s1.statGate = null;
        final secondStore = await openStore();
        final secondQueue = newQueue(persistence: secondStore);
        await secondQueue.restore();
        secondQueue.resumeQueue();
        final secondRecovery = secondQueue.tasks.single;
        await pumpUntil(
          () =>
              secondRecovery.isTerminal ||
              secondQueue.pendingConflicts.any(
                (conflict) => conflict.destinationPath == completedOutput,
              ),
          reason: 'the pending source never settled',
        );
        if (!secondRecovery.isTerminal) {
          final pending = secondRecovery.items.singleWhere(
            (item) => item.id == 'pending',
          );
          expect(
            secondQueue.resolveConflict(
              secondRecovery.id,
              pending.id,
              ConflictResolution.replace,
            ),
            isTrue,
          );
        }
        await awaitTaskDone(secondRecovery);

        // The first process crashed while an Ask was still unresolved.
        firstQueue.cancelTask(firstRecovery.id);
        discoveryGate.complete();
        await firstQueue.dispose();
        createdQueues.remove(firstQueue);

        final pending = secondRecovery.items.singleWhere(
          (item) => item.id == 'pending',
        );
        expect(pending.state, TransferItemState.failed);
        expect(pending.failureKind, RemoteFileErrorKind.conflict);
        expect(
          secondQueue.canRetryItem(secondRecovery.id, pending.id),
          isFalse,
        );
        expect(s1.fileBytes[completedOutput], 'first'.codeUnits);
        expect(s1.fileBytes[pendingSource], 'second'.codeUnits);
      },
    );

    test(
      'a crash before keep-both completion keeps its output claimed',
      () async {
        final source = FakeTreeFileSystem()
          ..addFile('/a/report.pdf', 'first'.codeUnits)
          ..addFile('/b/report (2).pdf', 'second'.codeUnits);
        connections.filesystems['source'] = source;
        s1.addFile('/dest/report.pdf', 'original'.codeUnits);

        final discoveryGate = Completer<void>();
        final commitGate = Completer<void>();
        source.statGate = (path) =>
            path == '/b/report (2).pdf' ? discoveryGate : null;
        s1.uploadGate = (path) =>
            path == '/dest/report (2).pdf' ? commitGate : null;

        final recording = RecordingPersistence();
        final firstQueue = TransferQueue(
          connections: connections,
          persistence: recording,
          maxInFlightFiles: 1,
        );
        createdQueues.add(firstQueue);
        final firstTask = firstQueue.enqueue(
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const ['/a/report.pdf', '/b/report (2).pdf'],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(files: ConflictResolution.ask),
            operation: TransferOperation.move,
          ),
        );

        await pumpUntil(
          () => firstQueue.pendingConflicts.any(
            (conflict) => conflict.destinationPath == '/dest/report.pdf',
          ),
          reason: 'the first conflict never surfaced',
        );
        final first = firstTask.items.singleWhere(
          (item) => item.sourcePath == '/a/report.pdf',
        );
        expect(
          firstQueue.resolveConflict(
            firstTask.id,
            first.id,
            ConflictResolution.keepBoth,
          ),
          isTrue,
        );
        await pumpUntil(
          () => s1.calls.contains('upload:/dest/report (2).pdf'),
          reason: 'the keep-both commit never started',
        );

        discoveryGate.complete();
        await pumpUntil(
          () => firstTask.scanComplete,
          reason: 'the scan did not finish behind the gated commit',
        );
        commitGate.complete();
        await pumpUntil(
          () => recording.journal.any(
            (record) =>
                record is FileCompletedRecord && record.itemId == first.id,
          ),
          reason: 'the first completion was never journaled',
        );
        expect(source.entryAt('/a/report.pdf'), isNull);
        expect(s1.fileBytes['/dest/report (2).pdf'], 'first'.codeUnits);

        final completionIndex = recording.journal.indexWhere(
          (record) =>
              record is FileCompletedRecord && record.itemId == first.id,
        );
        final crashPrefix = recording.journal.take(completionIndex).toList();
        firstQueue.cancelTask(firstTask.id);
        await firstQueue.dispose();
        createdQueues.remove(firstQueue);

        final crashed = await openStore();
        for (final record in crashPrefix) {
          crashed.appendJournal(record);
        }
        await crashed.flush();

        final store = await openStore();
        final restoredQueue = newQueue(persistence: store);
        await restoredQueue.restore();
        restoredQueue.resumeQueue();
        final restored = restoredQueue.tasks.single;
        final literal = restored.items.singleWhere(
          (item) => item.sourcePath == '/b/report (2).pdf',
        );
        await pumpUntil(
          () =>
              literal.isTerminal ||
              restoredQueue.pendingConflictFor(restored.id, literal.id) != null,
          reason: 'the literal source never settled',
        );
        final conflict = restoredQueue.pendingConflictFor(
          restored.id,
          literal.id,
        );
        if (conflict != null) {
          expect(
            restoredQueue.resolveConflict(
              restored.id,
              literal.id,
              ConflictResolution.replace,
            ),
            isTrue,
          );
          await pumpUntil(
            () => literal.isTerminal,
            reason: 'the replacement never settled',
          );
        }

        expect(literal.state, TransferItemState.failed);
        expect(s1.fileBytes['/dest/report (2).pdf'], 'first'.codeUnits);
        expect(source.fileBytes['/b/report (2).pdf'], 'second'.codeUnits);
      },
    );

    test('a planned move target is durable before commit and replay', () async {
      const firstSource = '/left/report.pdf';
      const secondSource = '/right/report.pdf';
      const destination = '/dest/report.pdf';
      final source = FakeTreeFileSystem()
        ..addFile(firstSource, 'first'.codeUnits)
        ..addFile(secondSource, 'second'.codeUnits);
      connections.filesystems['source'] = source;
      final discoveryGate = Completer<void>();
      source.statGate = (path) => path == secondSource ? discoveryGate : null;

      final planGate = Completer<void>();
      final completionGate = Completer<void>();
      final io = ScriptedIo()
        ..journalAppendGates[PlanEntryRecord.wireType] = planGate
        ..journalAppendGates[FileCompletedRecord.wireType] = completionGate;
      final firstStore = await openStore(io: io, fsyncEveryRecords: 1);
      final firstQueue = TransferQueue(
        connections: connections,
        persistence: firstStore,
        maxInFlightFiles: 1,
      );
      createdQueues.add(firstQueue);
      final firstTask = firstQueue.enqueue(
        TransferTaskSpec(
          source: const ServerFsLocation('source'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const [firstSource, secondSource],
          destinationDir: '/dest',
          policy: ResolvedConflictPolicy(files: ConflictResolution.replace),
          operation: TransferOperation.move,
        ),
      );

      try {
        await pumpUntil(
          () => io.journalAppendTypesStarted.contains(PlanEntryRecord.wireType),
          reason: 'the first plan entry never reached persistence',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(source.entryAt(firstSource), isNotNull);
        expect(s1.entryAt(destination), isNull);

        planGate.complete();
        await pumpUntil(
          () => io.journalAppendTypesStarted.contains(
            DestinationClaimedRecord.wireType,
          ),
          reason: 'the planned move target was never durably claimed',
        );
        await pumpUntil(
          () => io.journalAppendTypesStarted.contains(
            FileCompletedRecord.wireType,
          ),
          reason: 'the commit never reached its completion record',
        );
        expect(source.entryAt(firstSource), isNull);
        expect(s1.fileBytes[destination], 'first'.codeUnits);

        final crashPrefix = firstStore.journalFile.readAsStringSync();
        final crashRecords = const LineSplitter()
            .convert(crashPrefix)
            .where((line) => line.isNotEmpty)
            .map(TransferJournalRecord.parse)
            .toList();
        expect(
          crashRecords.whereType<DestinationClaimedRecord>(),
          hasLength(1),
        );

        firstQueue.cancelTask(firstTask.id);
        discoveryGate.complete();
        completionGate.complete();
        await firstQueue.dispose();

        final replayDir = Directory('${tempDir.path}/planned-move-replay')
          ..createSync();
        File(
          '${replayDir.path}/$transferJournalFileName',
        ).writeAsStringSync(crashPrefix);
        final replayStore = await FileTransferPersistence.open(replayDir);
        openedStores.add(replayStore);
        final replayQueue = TransferQueue(
          connections: connections,
          persistence: replayStore,
          maxInFlightFiles: 1,
        );
        createdQueues.add(replayQueue);
        await replayQueue.restore();
        replayQueue.resumeQueue();
        final restored = replayQueue.tasks.single;
        await awaitTaskDone(restored);

        expect(restored.state, TransferTaskState.failed);
        expect(s1.fileBytes[destination], 'first'.codeUnits);
        expect(source.fileBytes[secondSource], 'second'.codeUnits);
      } finally {
        if (!planGate.isCompleted) planGate.complete();
        if (!discoveryGate.isCompleted) discoveryGate.complete();
        if (!completionGate.isCompleted) completionGate.complete();
      }
    });

    test('an empty moved directory is claimed before source removal', () async {
      const sourcePath = '/source/folder';
      final source = FakeTreeFileSystem()..addDirectory(sourcePath);
      connections.filesystems['source'] = source;
      s1.addDirectory('/dest/folder');

      final claimGate = Completer<void>();
      final io = ScriptedIo()
        ..journalAppendGates[DestinationClaimedRecord.wireType] = claimGate;
      final store = await openStore(io: io, fsyncEveryRecords: 1);
      final queue = TransferQueue(
        connections: connections,
        persistence: store,
        maxInFlightFiles: 1,
      );
      createdQueues.add(queue);
      final task = queue.enqueue(
        TransferTaskSpec(
          source: const ServerFsLocation('source'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const [sourcePath],
          destinationDir: '/dest',
          policy: ResolvedConflictPolicy(folders: ConflictResolution.keepBoth),
          operation: TransferOperation.move,
        ),
      );

      try {
        await pumpUntil(
          () => io.journalAppendTypesStarted.contains(
            DestinationClaimedRecord.wireType,
          ),
          reason: 'the moved directory was never durably claimed',
        );
        expect(source.entryAt(sourcePath), isNotNull);
        expect(s1.entryAt('/dest/folder (2)'), isNull);

        claimGate.complete();
        await awaitTaskDone(task);

        expect(task.state, TransferTaskState.completed);
        expect(source.entryAt(sourcePath), isNull);
        expect(s1.entryAt('/dest/folder (2)'), isNotNull);
      } finally {
        if (!claimGate.isCompleted) claimGate.complete();
      }
    });

    test('restore reuses a claimed keep-both directory', () async {
      const sourcePath = '/source/folder';
      const claimedPath = '/dest/folder (2)';
      connections.filesystems['source'] = FakeTreeFileSystem()
        ..addDirectory(sourcePath);
      s1.addDirectory('/dest/folder');

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(
              folders: ConflictResolution.keepBoth,
            ),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'task-1',
          itemId: 'directory',
          isDirectory: true,
          sourcePath: sourcePath,
          destinationPath: '/dest/folder',
          sourceType: RemoteFileType.directory,
        ),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'task-1',
          itemId: 'directory',
          destinationPath: claimedPath,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 0, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(restored.items.single.destinationPath, claimedPath);
      expect(s1.entryAt('/dest/folder (3)'), isNull);
    });

    test('restore ignores cleaned probe rows during move cleanup', () async {
      const taskId = 'task-1';
      const directoryId = 'directory';
      const artifactId = 'artifact';
      const sourcePath = '/source/folder';
      const destinationPath = '/dest/folder';
      const artifactName =
          '.poltergeist-nameprobe-0123456789abcdef-e\u0301';
      final source = FakeTreeFileSystem()..addDirectory(sourcePath);
      connections.filesystems['source'] = source;
      s1.addDirectory(destinationPath);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          taskId,
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: taskId,
          itemId: directoryId,
          isDirectory: true,
          sourcePath: sourcePath,
          destinationPath: destinationPath,
          sourceType: RemoteFileType.directory,
          name: 'folder',
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: taskId,
          itemId: directoryId,
          resolvedPath: destinationPath,
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: taskId,
          itemId: artifactId,
          isDirectory: false,
          sourcePath: '$sourcePath/$artifactName',
          destinationPath: '$destinationPath/$artifactName',
          sourceType: RemoteFileType.file,
          sourceSize: 0,
        ),
      );
      crashed.appendJournal(
        ItemRemovedRecord(
          taskId: taskId,
          itemId: artifactId,
          error: 'reserved filesystem-name probe artifact',
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: taskId, totalBytes: 0, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(source.entryAt(sourcePath), isNull);
    });

    test('restored move waits for Resume before source cleanup', () async {
      const taskId = 'task-1';
      const sourcePath = '/source/folder';
      const destinationPath = '/dest/folder';
      s1
        ..addDirectory(sourcePath)
        ..addDirectory(destinationPath);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          taskId,
          TransferTaskSpec(
            source: const ServerFsLocation('s1'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: taskId,
          itemId: 'directory',
          isDirectory: true,
          sourcePath: sourcePath,
          destinationPath: destinationPath,
          sourceType: RemoteFileType.directory,
          name: 'folder',
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: taskId,
          itemId: 'directory',
          resolvedPath: destinationPath,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: taskId,
          totalBytes: 0,
          skippedSymlinks: 0,
          destinationNameComparison: DestinationNameComparison.exact,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      await pump(20);

      expect(queue.isPaused, isTrue);
      expect(s1.entryAt(sourcePath), isNotNull);

      queue.resumeQueue();
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(s1.entryAt(sourcePath), isNull);
      expect(s1.entryAt(destinationPath), isNotNull);
    });

    for (final scanComplete in [true, false]) {
      test(
        '${scanComplete ? 'fully-scanned' : 'mid-scan'} restore preserves '
        'a completed canonical directory self-move',
        () async {
          const taskId = 'task-1';
          const directoryId = 'directory';
          const sourcePath = '/dest/Folder';
          const claimedPath = '/dest/folder';
          s1
            ..caseInsensitive = true
            ..addDirectory(sourcePath);

          final crashed = await openStore();
          crashed.appendJournal(
            enqueued(
              taskId,
              TransferTaskSpec(
                source: const ServerFsLocation('s1'),
                destination: const ServerFsLocation('s1'),
                rootPaths: const [sourcePath],
                destinationDir: '/dest',
                policy: ResolvedConflictPolicy(),
                operation: TransferOperation.move,
              ),
            ),
          );
          crashed.appendJournal(
            PlanEntryRecord(
              taskId: taskId,
              itemId: directoryId,
              isDirectory: true,
              sourcePath: sourcePath,
              destinationPath: sourcePath,
              sourceType: RemoteFileType.directory,
              name: 'Folder',
            ),
          );
          crashed.appendJournal(
            DestinationClaimedRecord(
              taskId: taskId,
              itemId: directoryId,
              destinationPath: claimedPath,
            ),
          );
          crashed.appendJournal(
            FileCompletedRecord(
              taskId: taskId,
              itemId: directoryId,
              resolvedPath: claimedPath,
            ),
          );
          if (scanComplete) {
            crashed.appendJournal(
              ScanCompleteRecord(
                taskId: taskId,
                totalBytes: 0,
                skippedSymlinks: 0,
                destinationNameComparison:
                    DestinationNameComparison.normalizedCaseInsensitive,
              ),
            );
          }
          await crashed.flush();

          final store = await openStore();
          final queue = newQueue(persistence: store);
          await queue.restore();
          final restored = queue.tasks.single;
          if (scanComplete) {
            await pump(20);
            expect(s1.entryAt(sourcePath), isNotNull);
          }

          queue.resumeQueue();
          await awaitTaskDone(restored);

          expect(restored.state, TransferTaskState.completed);
          expect(s1.entryAt(sourcePath), isNotNull);
          expect(s1.deleteCalls, 0);
        },
      );
    }

    test('cancel and dispose wait for restored trait validation', () async {
      final source = File('${localSrc.path}/a.txt')..writeAsStringSync('a');
      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          localToRemoteSpec(rootPaths: [source.path]),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'file', source.path, '/dest/a.txt', size: 1),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'task-1',
          totalBytes: 1,
          skippedSymlinks: 0,
          destinationNameComparison: DestinationNameComparison.exact,
        ),
      );
      await crashed.flush();

      final cleanupGate = Completer<void>();
      s1.nameProbeGates[FakeNameProbeOperation.delete] = cleanupGate;
      connections.leaseCap = 1;
      final reopened = await openStore();
      final recording = RecordingPersistence()..replayValue = reopened.replay;
      final queue = newQueue(persistence: recording);
      await queue.restore();
      final restored = queue.tasks.single;
      queue.resumeQueue();
      await pumpUntil(
        () => s1.nameProbeCalls.any((call) => call.startsWith('delete:')),
        reason: 'restored destination validation never reached cleanup',
      );

      queue.cancelTask(restored.id);
      var disposed = false;
      final disposal = queue.dispose().then((_) => disposed = true);
      createdQueues.remove(queue);
      try {
        await pump(20);

        expect(disposed, isFalse);
        expect(connections.activeLeases('s1'), 1);
      } finally {
        cleanupGate.complete();
        await disposal;
      }

      expect(connections.activeLeases('s1'), 0);
    });

    test('restored listing failure cannot retry an unlisted subtree', () async {
      const sourcePath = '/source/folder';
      final source = FakeTreeFileSystem()
        ..addFile('$sourcePath/child.txt', 'child'.codeUnits)
        ..listFailure = (path) => path == sourcePath
            ? const RemoteFileException(
                kind: RemoteFileErrorKind.permissionDenied,
                operation: 'list',
                message: 'denied',
              )
            : null;
      connections.filesystems['source'] = source;

      final firstStore = await openStore();
      final firstQueue = newQueue(persistence: firstStore);
      final firstTask = firstQueue.enqueue(
        TransferTaskSpec(
          source: const ServerFsLocation('source'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const [sourcePath],
          destinationDir: '/dest',
          policy: ResolvedConflictPolicy(),
        ),
      );
      await awaitTaskDone(firstTask);
      await firstStore.flush();
      expect(firstTask.state, TransferTaskState.failed);

      final crashPrefix = journalLines(firstStore.journalFile)
          .map((line) {
            final record = TransferJournalRecord.parse(line);
            if (record is TaskStateRecord &&
                record.state == TransferTaskState.failed) {
              return null;
            }
            if (record is FileFailedRecord) {
              final legacy =
                  (jsonDecode(line) as Map).cast<String, Object?>()
                    ..remove('retryPolicy');
              return jsonEncode(legacy);
            }

            return line;
          })
          .whereType<String>()
          .map((line) => '$line\n')
          .join();
      final replayDir = Directory('${tempDir.path}/listing-failure-replay')
        ..createSync();
      File(
        '${replayDir.path}/$transferJournalFileName',
      ).writeAsStringSync(crashPrefix);
      source.listFailure = null;

      final replayStore = await FileTransferPersistence.open(replayDir);
      openedStores.add(replayStore);
      final replayQueue = newQueue(persistence: replayStore);
      await replayQueue.restore();
      replayQueue.resumeQueue();
      final restored = replayQueue.tasks.single;
      await awaitTaskDone(restored);
      final directory = restored.items.single;

      expect(restored.state, TransferTaskState.failed);
      expect(replayQueue.canRetryItem(restored.id, directory.id), isFalse);
      expect(replayQueue.retryItem(restored.id, directory.id), isFalse);
      expect(s1.entryAt('/dest/folder'), isNull);
      expect(source.entryAt('$sourcePath/child.txt'), isNotNull);
    });

    test('restore rekeys directory claims on an exact nested mount', () async {
      const taskId = 'task-1';
      const parentItemId = 'parent';
      const upperItemId = 'upper';
      const lowerItemId = 'lower';
      const sourceParent = '/source/mount';
      const destinationParent = '/dest/mount';
      final source = FakeTreeFileSystem()
        ..addDirectory('$sourceParent/A')
        ..addDirectory('$sourceParent/a');
      connections.filesystems['source'] = source;
      s1
        ..caseInsensitive = true
        ..nameComparisonsByRoot[destinationParent] =
            DestinationNameComparison.exact
        ..addDirectory(destinationParent);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          taskId,
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourceParent],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: taskId,
          itemId: parentItemId,
          isDirectory: true,
          sourcePath: sourceParent,
          destinationPath: destinationParent,
          sourceType: RemoteFileType.directory,
          name: 'mount',
        ),
      );
      crashed.appendJournal(
        FileCompletedRecord(
          taskId: taskId,
          itemId: parentItemId,
          resolvedPath: destinationParent,
        ),
      );
      for (final (itemId, name) in [(upperItemId, 'A'), (lowerItemId, 'a')]) {
        final sourcePath = '$sourceParent/$name';
        final destinationPath = '$destinationParent/$name';
        crashed.appendJournal(
          PlanEntryRecord(
            taskId: taskId,
            itemId: itemId,
            isDirectory: true,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            sourceType: RemoteFileType.directory,
            name: name,
            containerKey: parentItemId,
          ),
        );
        crashed.appendJournal(
          DestinationClaimedRecord(
            taskId: taskId,
            itemId: itemId,
            destinationPath: destinationPath,
          ),
        );
      }
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: taskId,
          totalBytes: 0,
          skippedSymlinks: 0,
          destinationNameComparison:
              DestinationNameComparison.normalizedCaseInsensitive,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(s1.entryAt('$destinationParent/A'), isNotNull);
      expect(s1.entryAt('$destinationParent/a'), isNotNull);
    });

    test('restore probes completed ancestors before file ownership', () async {
      const taskId = 'task-1';
      const parentItemId = 'parent';
      const upperItemId = 'upper';
      const lowerItemId = 'lower';
      const sourceParent = '/source/mount';
      const destinationParent = '/dest/mount';
      final source = FakeTreeFileSystem()
        ..addFile('$sourceParent/A/x.txt', 'upper'.codeUnits)
        ..addFile('$sourceParent/a/x.txt', 'lower'.codeUnits);
      connections.filesystems['source'] = source;
      s1
        ..caseInsensitive = true
        ..nameComparisonsByRoot[destinationParent] =
            DestinationNameComparison.exact
        ..addDirectory(destinationParent)
        ..addDirectory('$destinationParent/A')
        ..addDirectory('$destinationParent/a');

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          taskId,
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourceParent],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(
              files: ConflictResolution.replace,
              folders: ConflictResolution.replace,
            ),
            operation: TransferOperation.move,
          ),
        ),
      );
      for (final (itemId, sourcePath, destinationPath, name, containerKey) in [
        (
          parentItemId,
          sourceParent,
          destinationParent,
          'mount',
          null,
        ),
        (
          upperItemId,
          '$sourceParent/A',
          '$destinationParent/A',
          'A',
          parentItemId,
        ),
        (
          lowerItemId,
          '$sourceParent/a',
          '$destinationParent/a',
          'a',
          parentItemId,
        ),
      ]) {
        crashed.appendJournal(
          PlanEntryRecord(
            taskId: taskId,
            itemId: itemId,
            isDirectory: true,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            sourceType: RemoteFileType.directory,
            name: name,
            containerKey: containerKey,
          ),
        );
        crashed.appendJournal(
          FileCompletedRecord(
            taskId: taskId,
            itemId: itemId,
            resolvedPath: destinationPath,
          ),
        );
      }
      for (final (itemId, containerId, sourcePath, destinationPath) in [
        (
          'upper-file',
          upperItemId,
          '$sourceParent/A/x.txt',
          '$destinationParent/A/x.txt',
        ),
        (
          'lower-file',
          lowerItemId,
          '$sourceParent/a/x.txt',
          '$destinationParent/a/x.txt',
        ),
      ]) {
        crashed.appendJournal(
          PlanEntryRecord(
            taskId: taskId,
            itemId: itemId,
            isDirectory: false,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            sourceType: RemoteFileType.file,
            sourceSize: 5,
            name: 'x.txt',
            containerKey: containerId,
          ),
        );
      }
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: taskId,
          totalBytes: 10,
          skippedSymlinks: 0,
          destinationNameComparison:
              DestinationNameComparison.normalizedCaseInsensitive,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(s1.fileBytes['$destinationParent/A/x.txt'], 'upper'.codeUnits);
      expect(s1.fileBytes['$destinationParent/a/x.txt'], 'lower'.codeUnits);
      expect(source.entryAt('$sourceParent/A/x.txt'), isNull);
      expect(source.entryAt('$sourceParent/a/x.txt'), isNull);
    });

    test('restore collapses aliased destination containers', () async {
      const taskId = 'task-1';
      const upperDirectoryId = 'upper-directory';
      const lowerDirectoryId = 'lower-directory';
      const upperSource = '/source/A';
      const lowerSource = '/source/a';
      const upperDestination = '/dest/A';
      const lowerDestination = '/dest/a';
      final source = FakeTreeFileSystem()
        ..addFile('$upperSource/x', 'upper'.codeUnits)
        ..addFile('$lowerSource/x', 'lower'.codeUnits);
      connections.filesystems['source'] = source;
      s1
        ..caseInsensitive = true
        ..addDirectory(upperDestination);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          taskId,
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [upperSource, lowerSource],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(
              files: ConflictResolution.replace,
              folders: ConflictResolution.replace,
            ),
            operation: TransferOperation.move,
          ),
        ),
      );
      for (final (itemId, sourcePath, destinationPath, name) in [
        (upperDirectoryId, upperSource, upperDestination, 'A'),
        (lowerDirectoryId, lowerSource, lowerDestination, 'a'),
      ]) {
        crashed.appendJournal(
          PlanEntryRecord(
            taskId: taskId,
            itemId: itemId,
            isDirectory: true,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            sourceType: RemoteFileType.directory,
            name: name,
          ),
        );
        crashed.appendJournal(
          FileCompletedRecord(
            taskId: taskId,
            itemId: itemId,
            resolvedPath: destinationPath,
          ),
        );
      }
      for (final (itemId, containerId, sourcePath, destinationPath) in [
        (
          'upper-file',
          upperDirectoryId,
          '$upperSource/x',
          '$upperDestination/x',
        ),
        (
          'lower-file',
          lowerDirectoryId,
          '$lowerSource/x',
          '$lowerDestination/x',
        ),
      ]) {
        crashed.appendJournal(
          PlanEntryRecord(
            taskId: taskId,
            itemId: itemId,
            isDirectory: false,
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            sourceType: RemoteFileType.file,
            sourceSize: 5,
            name: 'x',
            containerKey: containerId,
          ),
        );
      }
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: taskId,
          totalBytes: 10,
          skippedSymlinks: 0,
          destinationNameComparison: DestinationNameComparison.exact,
        ),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.failed);
      final remainingSources = [
        source.fileBytes['$upperSource/x'],
        source.fileBytes['$lowerSource/x'],
      ].whereType<List<int>>().map(String.fromCharCodes).toList();
      expect(remainingSources, hasLength(1));
      expect(
        {
          ...remainingSources,
          String.fromCharCodes(s1.fileBytes['$upperDestination/x']!),
        },
        {'upper', 'lower'},
      );
    });

    test('restore refuses an occupied keep-both directory claim', () async {
      const sourcePath = '/source/folder';
      const claimedPath = '/dest/folder (2)';
      const nextPath = '/dest/folder (3)';
      const foreignPath = '$claimedPath/foreign.txt';
      final source = FakeTreeFileSystem()..addDirectory(sourcePath);
      connections.filesystems['source'] = source;
      s1
        ..addDirectory('/dest/folder')
        ..addDirectory(claimedPath)
        ..addFile(foreignPath, 'foreign'.codeUnits);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(
              folders: ConflictResolution.keepBoth,
            ),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'task-1',
          itemId: 'directory',
          isDirectory: true,
          sourcePath: sourcePath,
          destinationPath: '/dest/folder',
          sourceType: RemoteFileType.directory,
        ),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'task-1',
          itemId: 'directory',
          destinationPath: claimedPath,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 0, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.failed);
      expect(restored.items.single.failureKind, RemoteFileErrorKind.conflict);
      expect(
        restored.items.single.failureRetryPolicy,
        TransferFailureRetryPolicy.terminal,
      );
      expect(s1.fileBytes[foreignPath], 'foreign'.codeUnits);
      expect(s1.entryAt(nextPath), isNull);
      expect(source.entryAt(sourcePath), isNotNull);
    });

    test('restored directory claims serialize their durable path', () async {
      const restoredRoot = '/source/restored/folder';
      const freshRoot = '/source/fresh/folder (2)';
      const claimedPath = '/dest/folder (2)';
      const freshPath = '/dest/folder (3)';
      final source = FakeTreeFileSystem()
        ..addFile('$restoredRoot/old.txt', 'old'.codeUnits)
        ..addFile('$freshRoot/new.txt', 'new'.codeUnits);
      connections.filesystems['source'] = source;
      s1.addDirectory('/dest/folder');

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'restored-task',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [restoredRoot],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(
              folders: ConflictResolution.keepBoth,
            ),
          ),
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'restored-task',
          itemId: 'restored-directory',
          isDirectory: true,
          sourcePath: restoredRoot,
          destinationPath: '/dest/folder',
          sourceType: RemoteFileType.directory,
        ),
      );
      crashed.appendJournal(
        PlanEntryRecord(
          taskId: 'restored-task',
          itemId: 'restored-file',
          isDirectory: false,
          sourcePath: '$restoredRoot/old.txt',
          destinationPath: '/dest/folder/old.txt',
          sourceType: RemoteFileType.file,
          sourceSize: 3,
          name: 'old.txt',
          containerKey: 'restored-directory',
        ),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'restored-task',
          itemId: 'restored-directory',
          destinationPath: claimedPath,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(
          taskId: 'restored-task',
          totalBytes: 3,
          skippedSymlinks: 0,
        ),
      );
      await crashed.flush();

      final mkdirGate = Completer<void>();
      var claimedMkdirs = 0;
      s1.createDirectoryGate = (path) {
        if (path != claimedPath) return null;

        claimedMkdirs++;
        return mkdirGate;
      };

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      final restored = queue.tasks.single;
      final fresh = queue.enqueue(
        TransferTaskSpec(
          source: const ServerFsLocation('source'),
          destination: const ServerFsLocation('s1'),
          rootPaths: const [freshRoot],
          destinationDir: '/dest',
          policy: ResolvedConflictPolicy(
            folders: ConflictResolution.keepBoth,
          ),
        ),
      );

      try {
        queue.resumeQueue();
        await pumpUntil(() => claimedMkdirs > 0);
        await pumpUntil(() => fresh.scanComplete);
        await pump(20);

        expect(claimedMkdirs, 1);

        mkdirGate.complete();
        await awaitTaskDone(restored);
        await awaitTaskDone(fresh);

        expect(restored.state, TransferTaskState.completed);
        expect(fresh.state, TransferTaskState.completed);
        expect(s1.fileBytes['$claimedPath/old.txt'], 'old'.codeUnits);
        expect(s1.fileBytes['$freshPath/new.txt'], 'new'.codeUnits);
      } finally {
        if (!mkdirGate.isCompleted) mkdirGate.complete();
      }
    });

    test('restored directory registry admission claims atomically', () async {
      const firstSource = '/source/first/foo';
      const secondSource = '/source/second/foo';
      final source = FakeTreeFileSystem()
        ..addDirectory(firstSource)
        ..addDirectory(secondSource);
      connections.filesystems['source'] = source;

      final crashed = await openStore();
      for (final (taskId, sourcePath) in [
        ('first-task', firstSource),
        ('second-task', secondSource),
      ]) {
        crashed.appendJournal(
          enqueued(
            taskId,
            TransferTaskSpec(
              source: const ServerFsLocation('source'),
              destination: const ServerFsLocation('s1'),
              rootPaths: [sourcePath],
              destinationDir: '/dest',
              policy: ResolvedConflictPolicy(
                folders: ConflictResolution.keepBoth,
              ),
            ),
          ),
        );
        crashed.appendJournal(
          PlanEntryRecord(
            taskId: taskId,
            itemId: 'directory',
            isDirectory: true,
            sourcePath: sourcePath,
            destinationPath: '/dest/foo',
            sourceType: RemoteFileType.directory,
            name: 'foo',
          ),
        );
        crashed.appendJournal(
          ScanCompleteRecord(
            taskId: taskId,
            totalBytes: 0,
            skippedSymlinks: 0,
          ),
        );
      }
      await crashed.flush();

      final mkdirGate = Completer<void>();
      var baseMkdirs = 0;
      s1.createDirectoryGate = (path) {
        if (path != '/dest/foo') return null;

        baseMkdirs++;
        return mkdirGate;
      };

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      queue.pauseQueue();
      await pumpUntil(
        () =>
            s1.nameProbeCalls
                .where((call) => call.startsWith('delete:'))
                .length >=
            2,
      );

      try {
        queue.resumeQueue();
        scheduleMicrotask(queue.pauseQueue);
        await pumpUntil(() => baseMkdirs > 0);
        await pump(20);

        expect(baseMkdirs, 1);

        mkdirGate.complete();
        queue.resumeQueue();
        for (final task in queue.tasks) {
          await awaitTaskDone(task);
          expect(task.state, TransferTaskState.completed);
        }
        expect(s1.entryAt('/dest/foo'), isNotNull);
        expect(s1.entryAt('/dest/foo (2)'), isNotNull);
      } finally {
        if (!mkdirGate.isCompleted) mkdirGate.complete();
      }
    });

    test('restore resumes a pending file at its durable target', () async {
      const sourcePath = '/source/report.pdf';
      const plannedPath = '/dest/report.pdf';
      const claimedPath = '/dest/report (2).pdf';
      final source = FakeTreeFileSystem()
        ..addFile(sourcePath, 'source'.codeUnits);
      connections.filesystems['source'] = source;

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(files: ConflictResolution.keepBoth),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'file', sourcePath, plannedPath, size: 6),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'task-1',
          itemId: 'file',
          destinationPath: claimedPath,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 6, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(restored.items.single.destinationPath, claimedPath);
      expect(s1.fileBytes[claimedPath], 'source'.codeUnits);
      expect(s1.entryAt(plannedPath), isNull);
      expect(source.entryAt(sourcePath), isNull);
    });

    test('restore honors the latest repeated destination claim', () async {
      const sourcePath = '/source/report.pdf';
      const plannedPath = '/dest/report.pdf';
      const repeatedPath = '/dest/report (2).pdf';
      const interveningPath = '/dest/report (3).pdf';
      final source = FakeTreeFileSystem()
        ..addFile(sourcePath, 'source'.codeUnits);
      connections.filesystems['source'] = source;

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(files: ConflictResolution.keepBoth),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'file', sourcePath, plannedPath, size: 6),
      );
      for (final claim in [repeatedPath, interveningPath, repeatedPath]) {
        crashed.appendJournal(
          DestinationClaimedRecord(
            taskId: 'task-1',
            itemId: 'file',
            destinationPath: claim,
          ),
        );
      }
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 6, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.completed);
      expect(restored.items.single.destinationPath, repeatedPath);
      expect(s1.fileBytes[repeatedPath], 'source'.codeUnits);
      expect(s1.entryAt(interveningPath), isNull);
    });

    test('restore refuses an occupied durable file target', () async {
      const sourcePath = '/source/report.pdf';
      const plannedPath = '/dest/report.pdf';
      const claimedPath = '/dest/report (2).pdf';
      final source = FakeTreeFileSystem()
        ..addFile(sourcePath, 'source'.codeUnits);
      connections.filesystems['source'] = source;
      s1.addFile(claimedPath, 'foreign'.codeUnits);

      final crashed = await openStore();
      crashed.appendJournal(
        enqueued(
          'task-1',
          TransferTaskSpec(
            source: const ServerFsLocation('source'),
            destination: const ServerFsLocation('s1'),
            rootPaths: const [sourcePath],
            destinationDir: '/dest',
            policy: ResolvedConflictPolicy(files: ConflictResolution.replace),
            operation: TransferOperation.move,
          ),
        ),
      );
      crashed.appendJournal(
        fileEntry('task-1', 'file', sourcePath, plannedPath, size: 6),
      );
      crashed.appendJournal(
        DestinationClaimedRecord(
          taskId: 'task-1',
          itemId: 'file',
          destinationPath: claimedPath,
        ),
      );
      crashed.appendJournal(
        ScanCompleteRecord(taskId: 'task-1', totalBytes: 6, skippedSymlinks: 0),
      );
      await crashed.flush();

      final store = await openStore();
      final queue = newQueue(persistence: store);
      await queue.restore();
      queue.resumeQueue();
      final restored = queue.tasks.single;
      await awaitTaskDone(restored);

      expect(restored.state, TransferTaskState.failed);
      expect(restored.items.single.failureKind, RemoteFileErrorKind.conflict);
      expect(s1.fileBytes[claimedPath], 'foreign'.codeUnits);
      expect(s1.entryAt(plannedPath), isNull);
      expect(source.fileBytes[sourcePath], 'source'.codeUnits);
    });

    test('a failed task prefix blocks a durable keep-both commit', () async {
      final io = ScriptedIo()..failOnAppend = 1;
      final store = await openStore(io: io);
      final queue = newQueue(persistence: store);
      final source = File('${localSrc.path}/a.txt')..writeAsStringSync('new');
      s1.addFile('/dest/a.txt', 'old'.codeUnits);

      final task = queue.enqueue(
        localToRemoteSpec(
          rootPaths: [source.path],
          files: ConflictResolution.keepBoth,
          operation: TransferOperation.move,
        ),
      );
      await awaitTaskDone(task);
      await expectLater(store.flush(), throwsA(isA<FileSystemException>()));

      expect(task.state, TransferTaskState.failed);
      expect(source.existsSync(), isTrue);
      expect(s1.fileBytes['/dest/a.txt'], 'old'.codeUnits);
      expect(s1.entryAt('/dest/a (2).txt'), isNull);
      expect(
        notices.where((notice) => notice.contains('scripted append failure')),
        isNotEmpty,
      );
      expect(io.ops.where((op) => op == 'append:history'), isEmpty);
      expect(store.history, isEmpty);
    });

    test('dispose still closes the event stream when persistence '
        'shutdown throws', () async {
      final queue = newQueue(persistence: ThrowingShutdownPersistence());
      var streamClosed = false;
      queue.events.listen((_) {}, onDone: () => streamClosed = true);
      await expectLater(queue.dispose(), throwsStateError);
      await pumpUntil(() => streamClosed, reason: 'events never closed');
    });

    test('with no persistence the queue runs exactly the in-memory '
        'behavior and writes nothing', () async {
      final queue = newQueue();
      File('${localSrc.path}/a.txt').writeAsStringSync('hello');
      final task = queue.enqueue(
        localToRemoteSpec(rootPaths: ['${localSrc.path}/a.txt']),
      );
      await awaitTaskDone(task);
      expect(task.state, TransferTaskState.completed);
      expect(s1.entryAt('/dest/a.txt'), isNotNull);
      expect(storeDir.existsSync(), isFalse);
    });
  });
}
