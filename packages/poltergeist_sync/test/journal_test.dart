@TestOn('vm')
library;

import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  late Directory runsDir;

  setUp(() async {
    runsDir = await Directory.systemTemp.createTemp('poltergeist-journal-');
  });

  tearDown(() async {
    if (await runsDir.exists()) await runsDir.delete(recursive: true);
  });

  const rules = SyncRuleSet(
    direction: SyncDirection.leftToRight,
    deletions: DeletionPolicy.trash,
    backups: BackupPolicy.trash,
    maxDelete: 250,
  );

  SyncRunRecord record(String runId, [DateTime? startedAt]) => SyncRunRecord(
    runId: runId,
    pairId: 'pair-1',
    startedAt: startedAt ?? DateTime.now(),
    rules: rules,
    totals: const PlanTotals(
      counts: {SyncActionType.deleteRight: 1},
      bytes: {SyncActionType.deleteRight: 5},
      replacedFiles: 0,
      replacedBytes: 0,
    ),
    warnings: const [
      ScanWarning(
        relativePath: 'locked/',
        side: SyncSide.right,
        message: 'Could not list "locked/"',
        kind: ScanWarningKind.listingFailure,
      ),
    ],
  );

  Future<SyncRunJournal> writeRun(String runId) async {
    final journal = await SyncRunJournal.create(runsDir.path, record(runId));
    await journal.appendItem(
      const SyncJournalItemLine(
        relativePath: 'd.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 5,
        durationMs: 12,
        trashLocation: '/r/.poltergeist-trash/RUN/000001-d.txt',
        trashBytes: 5,
      ),
    );
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'dir',
        relativePath: 'dir/old.txt',
        side: SyncSide.right,
        trashLocation: '/r/.poltergeist-trash/RUN/000002-old.txt',
        bytes: 7,
      ),
    );
    await journal.appendRmdir(
      const SyncJournalRmdirLine(
        relativePath: 'dir',
        side: SyncSide.right,
        parentPath: 'dir',
      ),
    );
    await journal.appendSummary(
      const SyncJournalSummary(
        counts: {SyncItemStatus.done: 1},
        bytesTransferred: 0,
        cancelled: false,
        mtimeUnreliableLeft: false,
        mtimeUnreliableRight: true,
      ),
    );
    return journal;
  }

  test('replay round-trips every line kind', () async {
    final written = await writeRun('run-1');

    final replayed = await SyncRunJournal.open(written.path);

    expect(replayed.record.runId, 'run-1');
    expect(replayed.record.pairId, 'pair-1');
    expect(replayed.record.rules, rules);
    expect(replayed.record.totals.counts[SyncActionType.deleteRight], 1);
    expect(replayed.record.warnings.single.relativePath, 'locked/');
    expect(replayed.items, hasLength(1));
    final line = replayed.items.single;
    expect(line.relativePath, 'd.txt');
    expect(line.action, SyncActionType.deleteRight);
    expect(line.outcome, SyncItemStatus.done);
    expect(line.attempt, 1);
    expect(line.trashLocation, '/r/.poltergeist-trash/RUN/000001-d.txt');
    expect(line.trashBytes, 5);
    expect(replayed.trashLines.single.relativePath, 'dir/old.txt');
    expect(replayed.rmdirLines.single.relativePath, 'dir');
    expect(replayed.summary!.mtimeUnreliableRight, isTrue);
    expect(replayed.purged, isFalse);
    expect(replayed.hasUnpurgedTrash, isTrue);
  });

  test('an unknown or absent warning kind falls back on replay only',
      () async {
    final written = await writeRun('run-kinds');
    // Forward tolerance: a journal from a newer build whose warning
    // vocabulary has grown must still replay — the informational
    // bucket keeps the line without mistaking it for a listing failure.
    var text = await File(written.path).readAsString();
    text = text.replaceFirst(
      '"kind":"listingFailure"',
      '"kind":"fromAFutureBuild"',
    );
    await File(written.path).writeAsString(text);

    var replayed = await SyncRunJournal.open(written.path);
    expect(
      replayed.record.warnings.single.kind,
      ScanWarningKind.malformedName,
    );

    // Older journals carry no kind at all — same fallback.
    text = await File(written.path).readAsString();
    text = text.replaceFirst(',"kind":"fromAFutureBuild"', '');
    await File(written.path).writeAsString(text);
    replayed = await SyncRunJournal.open(written.path);
    expect(
      replayed.record.warnings.single.kind,
      ScanWarningKind.malformedName,
    );
  });

  test('a torn final line is dropped on replay', () async {
    final written = await writeRun('run-2');
    // The crash-mid-write tail: valid prefix, truncated line.
    await File(written.path).writeAsString(
      '{"v":1,"type":"item","path":"half-writ',
      mode: FileMode.append,
    );

    final replayed = await SyncRunJournal.open(written.path);

    expect(replayed.items, hasLength(1));
    expect(replayed.summary, isNotNull);
  });

  test('markPurged releases the journal for pruning', () async {
    final written = await writeRun('run-3');
    expect(written.hasUnpurgedTrash, isTrue);

    await written.markPurged();

    final replayed = await SyncRunJournal.open(written.path);
    expect(replayed.purged, isTrue);
    expect(replayed.hasUnpurgedTrash, isFalse);
  });

  test('root-scoped markers release only their own trash', () async {
    const leftScope = 'left-host:/trash';
    const rightScope = 'right-host:/trash';
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: 'run-scopes',
        pairId: 'pair-1',
        startedAt: DateTime.now(),
        trashScopeLeft: leftScope,
        trashScopeRight: rightScope,
        rules: rules,
        totals: const PlanTotals(
          counts: {},
          bytes: {},
          replacedFiles: 0,
          replacedBytes: 0,
        ),
        warnings: const [],
      ),
    );
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'left.txt',
        relativePath: 'left.txt',
        side: SyncSide.left,
        trashLocation: '/trash/run-scopes/000001-left.txt',
        bytes: 1,
      ),
    );
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'right.txt',
        relativePath: 'right.txt',
        side: SyncSide.right,
        trashLocation: '/trash/run-scopes/000002-right.txt',
        bytes: 1,
      ),
    );

    await journal.markPurged(trashScope: leftScope);
    var replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.record.trashScopeLeft, leftScope);
    expect(replayed.record.trashScopeRight, rightScope);
    expect(replayed.hasPurgeMarker, isTrue);
    expect(replayed.purged, isFalse);
    expect(replayed.hasUnpurgedTrash, isTrue);
    expect(
      replayed.isTrashEntryPurged(
        SyncSide.left,
        '/trash/run-scopes/000001-left.txt',
      ),
      isTrue,
    );
    expect(
      replayed.isTrashEntryPurged(
        SyncSide.right,
        '/trash/run-scopes/000002-right.txt',
      ),
      isFalse,
    );

    await replayed.markPurged(trashScope: rightScope);
    replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.purged, isTrue);
    expect(replayed.hasUnpurgedTrash, isFalse);
  });

  test('legacy run-wide marker remains compatible', () async {
    final journal = await writeRun('run-legacy-purge');
    await File(
      journal.path,
    ).writeAsString('{"v":1,"type":"purged"}\n', mode: FileMode.append);

    final replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.hasPurgeMarker, isTrue);
    expect(replayed.purged, isTrue);
    expect(replayed.hasUnpurgedTrash, isFalse);
  });

  test('legacy Windows trash paths derive their root scope', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-windows-trash'),
    );
    const trashLocation = r'C:\Trash\run-windows-trash\000001-document.txt';
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'document.txt',
        relativePath: 'document.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 1,
      ),
    );

    expect(
      journal.trashScopeForEntry(SyncSide.right, trashLocation),
      r'C:\Trash',
    );

    await journal.markPurged(trashScope: r'C:\Trash');

    expect(journal.purged, isTrue);
    expect(journal.hasUnpurgedTrash, isFalse);
  });

  test('mixed-separator UNC trash paths derive their root scope', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-windows-unc'),
    );
    const trashLocation =
        r'\\server\share\Trash\run-windows-unc/000001-document.txt';
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'document.txt',
        relativePath: 'document.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 1,
      ),
    );

    expect(
      journal.trashScopeForEntry(SyncSide.right, trashLocation),
      r'\\server\share\Trash',
    );
  });

  test('legacy relative trash skips rmdir only on purged side', () async {
    final leftRoot = Directory('${runsDir.path}/left')..createSync();
    final rightRoot = Directory('${runsDir.path}/right')..createSync();
    const runId = 'run-relative-trash';
    final leftTrashRoot = '${leftRoot.path}/trash-left';
    final rightTrashRoot = '${rightRoot.path}/trash-right';
    final leftTrash = '$leftTrashRoot/$runId/000001-left.txt';
    final rightTrash = '$rightTrashRoot/$runId/000002-right.txt';
    File(leftTrash)
      ..createSync(recursive: true)
      ..writeAsStringSync('l');
    File(rightTrash)
      ..createSync(recursive: true)
      ..writeAsStringSync('r');
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-1',
        startedAt: DateTime.now(),
        rules: const SyncRuleSet(
          trashPathLeft: 'trash-left',
          trashPathRight: 'trash-right',
        ),
        totals: const PlanTotals(
          counts: {},
          bytes: {},
          replacedFiles: 0,
          replacedBytes: 0,
        ),
        warnings: const [],
      ),
    );
    await journal.appendTrash(
      SyncJournalTrashLine(
        parentPath: 'left.txt',
        relativePath: 'left.txt',
        side: SyncSide.left,
        trashLocation: leftTrash,
        bytes: 1,
      ),
    );
    await journal.appendTrash(
      SyncJournalTrashLine(
        parentPath: 'right.txt',
        relativePath: 'right.txt',
        side: SyncSide.right,
        trashLocation: rightTrash,
        bytes: 1,
      ),
    );
    await journal.appendRmdir(
      const SyncJournalRmdirLine(
        relativePath: 'left-empty',
        side: SyncSide.left,
        parentPath: 'left-empty',
      ),
    );
    await journal.appendRmdir(
      const SyncJournalRmdirLine(
        relativePath: 'right-empty',
        side: SyncSide.right,
        parentPath: 'right-empty',
      ),
    );
    await journal.markPurged(trashScope: leftTrashRoot);
    await Directory(leftTrashRoot).delete(recursive: true);

    final report = await restoreTrashedFiles(
      journal,
      fsFor: (_) => LocalFileSystem(),
      rootFor: (side) => side == SyncSide.left ? leftRoot.path : rightRoot.path,
    );

    expect(
      report.restored,
      ['right.txt'],
      reason: report.skipped
          .map((entry) => '${entry.relativePath}: ${entry.reason}')
          .join('\n'),
    );
    expect(Directory('${leftRoot.path}/left-empty').existsSync(), isFalse);
    expect(Directory('${rightRoot.path}/right-empty').existsSync(), isTrue);
  });

  test('legacy relative trash restores through its canonical root', () async {
    final previousCurrent = Directory.current;
    final working = Directory('${runsDir.path}/working')..createSync();
    final restoreRoot = Directory('${runsDir.path}/restored')..createSync();
    const runId = 'run-relative-restore';
    const trashLocation =
        'legacy-trash/$runId/000001-old.txt';
    final trashed = File('${working.path}/$trashLocation')
      ..createSync(recursive: true)
      ..writeAsStringSync('legacy');
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-1',
        startedAt: DateTime.now(),
        rules: const SyncRuleSet(trashPathRight: 'legacy-trash'),
        totals: const PlanTotals(
          counts: {},
          bytes: {},
          replacedFiles: 0,
          replacedBytes: 0,
        ),
        warnings: const [],
      ),
    );
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'old.txt',
        relativePath: 'old.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 6,
      ),
    );

    Directory.current = working;
    try {
      final report = await restoreTrashedFiles(
        journal,
        fsFor: (_) => LocalFileSystem(),
        rootFor: (_) => restoreRoot.path,
      );

      expect(report.restored, ['old.txt'], reason: '${report.skipped}');
      expect(
        File('${restoreRoot.path}/old.txt').readAsStringSync(),
        'legacy',
      );
      expect(await trashed.exists(), isFalse);
    } finally {
      Directory.current = previousCurrent;
    }
  });

  test('restore does not verify trash after clearing post-state', () async {
    final style = Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    final context = syncTrashPathContext(style);
    final restoreRoot = Directory(context.join(runsDir.path, 'restore'))
      ..createSync();
    final trashRoot = context.join(runsDir.path, 'trash');
    final localFs = LocalFileSystem();
    final identity = await resolveSyncTrashRoot(
      localFs,
      trashRoot,
      pathStyle: style,
      access: SyncTrashRootAccess.createOrClaim,
    );
    final runId =
        '${syncRunDevicePrefix('restore-order')}-'
        '00000000-0000-4000-8000-000000000000';
    final trashLocation = context.join(
      identity.canonicalRoot,
      runId,
      '000001-document.txt',
    );
    File(trashLocation)
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final origin = File(context.join(restoreRoot.path, 'document.txt'))
      ..writeAsStringSync('new');
    final live = await localFs.stat(origin.path);
    final observedMtime =
        live.modifiedAt!.millisecondsSinceEpoch ~/
        Duration.millisecondsPerSecond;
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-1',
        startedAt: DateTime.now(),
        trashScopeRight: identity.scopeKey,
        rules: rules,
        totals: const PlanTotals(
          counts: {SyncActionType.updateLeftToRight: 1},
          bytes: {SyncActionType.updateLeftToRight: 3},
          replacedFiles: 1,
          replacedBytes: 3,
        ),
        warnings: const [],
      ),
    );
    await journal.appendTrash(
      SyncJournalTrashLine(
        parentPath: 'document.txt',
        relativePath: 'document.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 3,
      ),
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'document.txt',
        side: SyncSide.right,
        action: SyncActionType.updateLeftToRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 3,
        observedMtimeAfterWrite: observedMtime,
      ),
    );
    final fs = _FailCanonicalizeAfterOriginRemovalFileSystem(origin.path);

    final report = await restoreTrashedFiles(
      journal,
      fsFor: (_) => fs,
      rootFor: (_) => restoreRoot.path,
    );

    expect(report.restored, ['document.txt'], reason: '${report.skipped}');
    expect(origin.readAsStringSync(), 'old');
    expect(File(trashLocation).existsSync(), isFalse);
  });

  test('lastAttempt drives attempt numbering', () async {
    final written = await writeRun('run-4');
    expect(
      written.lastAttempt(
        'd.txt',
        SyncSide.right,
        SyncActionType.deleteRight,
      ),
      1,
    );
    expect(
      written.lastAttempt(
        'other.txt',
        SyncSide.right,
        SyncActionType.deleteRight,
      ),
      0,
    );
  });

  test('prune keeps the newest journals but never live trash', () async {
    // 24 journals for one pair: the oldest two with unpurged trash
    // must survive, the rest prune to the retention count — so two
    // unprotected oldest must actually be deleted.
    for (var i = 0; i < 24; i++) {
      final journal = await SyncRunJournal.create(
        runsDir.path,
        record(
          'run-$i',
          DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
        ),
      );
      if (i < 2) {
        await journal.appendItem(
          SyncJournalItemLine(
            relativePath: 'kept-$i.txt',
            side: SyncSide.right,
            action: SyncActionType.deleteRight,
            outcome: SyncItemStatus.done,
            attempt: 1,
            bytes: 1,
            trashLocation: '/r/.poltergeist-trash/run/000001-kept.txt',
          ),
        );
      }
    }
    expect(runsDir.listSync(), hasLength(24));

    await SyncRunJournal.prune(runsDir.path, 'pair-1', keep: 20);

    final remaining = runsDir
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toList();
    // The prune must actually delete: the two unprotected oldest
    // journals are gone, the newest 20 stay, and the 2 live-trash
    // journals are retained no matter their age.
    expect(remaining, isNot(contains('run-2.jsonl')));
    expect(remaining, isNot(contains('run-3.jsonl')));
    expect(remaining, hasLength(22));
    expect(remaining, containsAll(<String>['run-0.jsonl', 'run-1.jsonl']));
    expect(remaining, contains('run-23.jsonl'));
  });

  test('a journal without a header is refused', () async {
    final bogus = File('${runsDir.path}/bogus.jsonl');
    await bogus.writeAsString('{"v":1,"type":"item","path":"x"}\n');

    await expectLater(
      SyncRunJournal.open(bogus.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a torn line mid-file is skipped, not truncated at', () async {
    // A kill leaves a torn write; a resumed run then appends *after*
    // it. Replay must keep every later line — lastAttempt, restore
    // lists, and the retention check all depend on them.
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-torn', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'before.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 1,
      ),
    );
    // The torn line: a partial write appended mid-file.
    await File(journal.path).writeAsString(
      '{"v":1,"type":"item","path":"to',
      mode: FileMode.append,
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'after.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.failed,
        attempt: 2,
        bytes: 1,
      ),
    );

    final replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.items, hasLength(2));
    expect(
      replayed.lastAttempt(
        'after.txt',
        SyncSide.right,
        SyncActionType.deleteRight,
      ),
      2,
    );
  });

  test('invalid UTF-8 in a torn line does not fail replay', () async {
    // A kill can sever a multi-byte character mid-write; strict
    // decoding would throw before the skip-undecodable logic runs.
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-utf8', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'kept.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 1,
      ),
    );
    // Raw invalid bytes mid-file, then a valid record after them —
    // replay must continue past the damage, not just tolerate EOF.
    final file = File(journal.path);
    await file.writeAsBytes([0xFF, 0xFE], mode: FileMode.append);
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'after.txt',
        side: SyncSide.right,
        action: SyncActionType.deleteRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 1,
      ),
    );

    final replayed = await SyncRunJournal.open(journal.path);
    expect(
      replayed.items.map((i) => i.relativePath),
      equals(<String>['kept.txt', 'after.txt']),
    );
  });

  test('a duplicate header line is refused', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-dup', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
    );
    // A second header must not silently discard what replay already
    // gathered. (Blank lines pad the file — find the real header.)
    final lines = await File(journal.path).readAsLines();
    final header = lines.firstWhere((l) => l.trim().isNotEmpty);
    await File(journal.path).writeAsString(
      '$header\n',
      mode: FileMode.append,
    );

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a path-unsafe runId is refused at create', () async {
    await expectLater(
      SyncRunJournal.create(
        runsDir.path,
        record(
          '../escape',
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}

final class _FailCanonicalizeAfterOriginRemovalFileSystem
    extends LocalFileSystem {
  _FailCanonicalizeAfterOriginRemovalFileSystem(this.originPath);

  final String originPath;

  @override
  Future<String> canonicalize(String path) async {
    if (!File(originPath).existsSync()) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'canonicalize',
        path: path,
        message: 'Connection lost after destination removal.',
      );
    }

    return super.canonicalize(path);
  }
}
