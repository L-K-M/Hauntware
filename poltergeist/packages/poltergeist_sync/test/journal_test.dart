@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
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
    canonicalRootLeft: '/canonical/left',
    canonicalRootRight: '/canonical/right',
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

  Future<void> appendRestoreRecord(
    SyncRunJournal journal,
    Map<String, Object?> fields, {
    int version = 2,
  }) => File(journal.path).writeAsString(
    '\n${jsonEncode(<String, Object?>{'v': version, ...fields})}\n',
    mode: FileMode.append,
    flush: true,
  );

  test('create returns a normalized platform journal path', () async {
    const runId = 'run-native-path';
    final journal = await SyncRunJournal.create(
      '${runsDir.path}${p.separator}',
      record(runId),
    );

    expect(journal.path, p.join(runsDir.path, '$runId.jsonl'));
  });

  test('replay round-trips every line kind', () async {
    final written = await writeRun('run-1');

    final replayed = await SyncRunJournal.open(written.path);

    expect(replayed.record.runId, 'run-1');
    expect(replayed.record.pairId, 'pair-1');
    expect(replayed.record.canonicalRootLeft, '/canonical/left');
    expect(replayed.record.canonicalRootRight, '/canonical/right');
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

  test('an unknown or absent warning kind falls back on replay only', () async {
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
    expect(replayed.record.warnings.single.kind, ScanWarningKind.malformedName);

    // Older journals carry no kind at all — same fallback.
    text = await File(written.path).readAsString();
    text = text.replaceFirst(',"kind":"fromAFutureBuild"', '');
    await File(written.path).writeAsString(text);
    replayed = await SyncRunJournal.open(written.path);
    expect(replayed.record.warnings.single.kind, ScanWarningKind.malformedName);
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

  test('Windows purge scopes normalize mixed separators', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-windows-mixed-purge'),
    );
    const trashLocation =
        r'C:\Trash\run-windows-mixed-purge\000001-document.txt';
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'document.txt',
        relativePath: 'document.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 1,
      ),
    );

    await journal.markPurged(trashScope: r'C:/Trash\');
    final replayed = await SyncRunJournal.open(journal.path);

    expect(replayed.isTrashEntryPurged(SyncSide.right, trashLocation), isTrue);
    expect(replayed.purged, isTrue);
    expect(replayed.hasUnpurgedTrash, isFalse);
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

  test(
    'slash-prefixed UNC scopes normalize and compare case-insensitively',
    () async {
      final journal = await SyncRunJournal.create(
        runsDir.path,
        record('run-windows-slash-unc'),
      );
      const trashLocation =
          r'//Server/Share/Trash/run-windows-slash-unc/000001-document.txt';
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
        r'\\Server\Share\Trash',
      );

      await journal.markPurged(trashScope: r'\\server\share\trash');
      final replayed = await SyncRunJournal.open(journal.path);

      expect(
        replayed.isTrashEntryPurged(SyncSide.right, trashLocation),
        isTrue,
      );
      expect(replayed.hasUnpurgedTrash, isFalse);
    },
  );

  test('Windows drive scopes compare case-insensitively', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-windows-case-purge'),
    );
    const trashLocation =
        r'C:\Trash\run-windows-case-purge\000001-document.txt';
    await journal.appendTrash(
      const SyncJournalTrashLine(
        parentPath: 'document.txt',
        relativePath: 'document.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 1,
      ),
    );

    await journal.markPurged(trashScope: r'c:\trash');
    final replayed = await SyncRunJournal.open(journal.path);

    expect(replayed.isTrashEntryPurged(SyncSide.right, trashLocation), isTrue);
    expect(replayed.hasUnpurgedTrash, isFalse);
  });

  test('legacy relative trash skips rmdir only on purged side', () async {
    final leftRoot = Directory('${runsDir.path}/left')..createSync();
    final rightRoot = Directory('${runsDir.path}/right')..createSync();
    final fs = LocalFileSystem();
    final leftRootPath = await fs.canonicalize(leftRoot.path);
    final rightRootPath = await fs.canonicalize(rightRoot.path);
    const runId = 'run-relative-trash';
    final leftTrashRoot = p.join(leftRootPath, 'trash-left');
    final rightTrashRoot = p.join(rightRootPath, 'trash-right');
    final leftTrash = p.join(leftTrashRoot, runId, '000001-left.txt');
    final rightTrash = p.join(rightTrashRoot, runId, '000002-right.txt');
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
      fsFor: (_) => fs,
      rootFor: (side) => side == SyncSide.left ? leftRootPath : rightRootPath,
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
    final fs = LocalFileSystem();
    final restoreRootPath = await fs.canonicalize(restoreRoot.path);
    const runId = 'run-relative-restore';
    const trashLocation = 'legacy-trash/$runId/000001-old.txt';
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
        fsFor: (_) => fs,
        rootFor: (_) => restoreRootPath,
      );

      expect(report.restored, ['old.txt'], reason: '${report.skipped}');
      expect(File('${restoreRoot.path}/old.txt').readAsStringSync(), 'legacy');
      expect(await trashed.exists(), isFalse);
    } finally {
      Directory.current = previousCurrent;
    }
  });

  test('restore reuses each validated filesystem and root binding', () async {
    final style = Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    final context = syncTrashPathContext(style);
    final restoreRoot = Directory(context.join(runsDir.path, 'stable-root'))
      ..createSync();
    final switchedRoot = Directory(context.join(runsDir.path, 'switched-root'))
      ..createSync();
    final fs = LocalFileSystem();
    final restoreRootPath = await fs.canonicalize(restoreRoot.path);
    final switchedRootPath = await fs.canonicalize(switchedRoot.path);
    final identity = await resolveSyncTrashRoot(
      fs,
      context.join(runsDir.path, 'stable-trash'),
      pathStyle: style,
      access: SyncTrashRootAccess.createOrClaim,
    );
    const runId = 'run-stable-bindings';
    final trashLocation = context.join(
      identity.canonicalRoot,
      runId,
      '000001-document.txt',
    );
    File(trashLocation)
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-stable-bindings',
        startedAt: DateTime.now(),
        canonicalRootRight: restoreRootPath,
        trashScopeRight: identity.scopeKey,
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
      SyncJournalTrashLine(
        parentPath: 'document.txt',
        relativePath: 'document.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 3,
      ),
    );
    var fsCalls = 0;
    var rootCalls = 0;

    final report = await restoreTrashedFiles(
      journal,
      fsFor: (_) {
        fsCalls++;
        return fs;
      },
      rootFor: (_) {
        rootCalls++;
        return rootCalls == 1 ? restoreRootPath : switchedRootPath;
      },
    );

    expect(report.restored, ['document.txt'], reason: '${report.skipped}');
    expect(fsCalls, 1);
    expect(rootCalls, 1);
    expect(
      File(context.join(restoreRoot.path, 'document.txt')).readAsStringSync(),
      'old',
    );
    expect(
      File(context.join(switchedRoot.path, 'document.txt')).existsSync(),
      isFalse,
    );
  });

  for (final pathKind in ['parent traversal', 'absolute path']) {
    test('restore rejects a journal $pathKind before mutation', () async {
      final style = Platform.isWindows
          ? SyncTrashPathStyle.windows
          : SyncTrashPathStyle.posix;
      final context = syncTrashPathContext(style);
      final restoreRoot = Directory(
        context.join(runsDir.path, 'unsafe-restore-$pathKind'),
      )..createSync();
      final unsafePath = pathKind == 'parent traversal'
          ? '../escaped.txt'
          : context.join(runsDir.path, 'absolute-escaped.txt');
      final trashRoot = context.join(runsDir.path, 'unsafe-trash-$pathKind');
      final fs = _CountingLocalFileSystem();
      final identity = await resolveSyncTrashRoot(
        fs,
        trashRoot,
        pathStyle: style,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final runId = pathKind == 'parent traversal'
          ? 'run-parent-traversal'
          : 'run-absolute-path';
      final trashLocation = context.join(
        identity.canonicalRoot,
        runId,
        '000001-old.txt',
      );
      final trashed = File(trashLocation)
        ..createSync(recursive: true)
        ..writeAsStringSync('old');
      final journal = await SyncRunJournal.create(
        runsDir.path,
        SyncRunRecord(
          runId: runId,
          pairId: 'pair-unsafe-path',
          startedAt: DateTime.now(),
          canonicalRootRight: restoreRoot.path,
          trashScopeRight: identity.scopeKey,
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
        SyncJournalTrashLine(
          parentPath: unsafePath,
          relativePath: unsafePath,
          side: SyncSide.right,
          trashLocation: trashLocation,
          bytes: 3,
        ),
      );
      fs.reset();

      await expectLater(
        restoreTrashedFiles(
          journal,
          fsFor: (_) => fs,
          rootFor: (_) => restoreRoot.path,
        ),
        throwsA(
          isA<RemoteFileException>()
              .having(
                (error) => error.kind,
                'kind',
                RemoteFileErrorKind.conflict,
              )
              .having((error) => error.path, 'path', unsafePath),
        ),
      );

      expect(fs.accessCount, 0);
      expect(trashed.existsSync(), isTrue);
      expect(
        File(context.join(runsDir.path, 'escaped.txt')).existsSync(),
        isFalse,
      );
    });
  }

  test('restore rejects a swapped symlink sync root before mutation', () async {
    final style = Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    final context = syncTrashPathContext(style);
    final restoreRoot = Directory(context.join(runsDir.path, 'restore-root'))
      ..createSync();
    final recordedRoot = restoreRoot.path;
    final originalRoot = context.join(runsDir.path, 'original-root');
    final outsideRoot = Directory(context.join(runsDir.path, 'outside-root'))
      ..createSync();
    await restoreRoot.rename(originalRoot);
    await Link(recordedRoot).create(outsideRoot.path);

    final fs = LocalFileSystem();
    final identity = await resolveSyncTrashRoot(
      fs,
      context.join(runsDir.path, 'symlink-trash'),
      pathStyle: style,
      access: SyncTrashRootAccess.createOrClaim,
    );
    const runId = 'run-symlink-root';
    final trashLocation = context.join(
      identity.canonicalRoot,
      runId,
      '000001-old.txt',
    );
    final trashed = File(trashLocation)
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-symlink-root',
        startedAt: DateTime.now(),
        canonicalRootRight: recordedRoot,
        trashScopeRight: identity.scopeKey,
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
      SyncJournalTrashLine(
        parentPath: 'victim.txt',
        relativePath: 'victim.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 3,
      ),
    );

    await expectLater(
      restoreTrashedFiles(
        journal,
        fsFor: (_) => fs,
        rootFor: (_) => recordedRoot,
      ),
      throwsA(
        isA<RemoteFileException>()
            .having((error) => error.kind, 'kind', RemoteFileErrorKind.conflict)
            .having((error) => error.path, 'path', recordedRoot),
      ),
    );

    expect(trashed.existsSync(), isTrue);
    expect(
      File(context.join(outsideRoot.path, 'victim.txt')).existsSync(),
      isFalse,
    );
  }, skip: Platform.isWindows);

  test('restore rejects a different root than the journal recorded', () async {
    final style = Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    final context = syncTrashPathContext(style);
    final recordedRoot = Directory(context.join(runsDir.path, 'recorded-root'))
      ..createSync();
    final suppliedRoot = Directory(context.join(runsDir.path, 'supplied-root'))
      ..createSync();
    final fs = _CountingLocalFileSystem();
    final identity = await resolveSyncTrashRoot(
      fs,
      context.join(runsDir.path, 'different-root-trash'),
      pathStyle: style,
      access: SyncTrashRootAccess.createOrClaim,
    );
    const runId = 'run-different-root';
    final trashLocation = context.join(
      identity.canonicalRoot,
      runId,
      '000001-old.txt',
    );
    final trashed = File(trashLocation)
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-different-root',
        startedAt: DateTime.now(),
        canonicalRootRight: recordedRoot.path,
        trashScopeRight: identity.scopeKey,
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
      SyncJournalTrashLine(
        parentPath: 'victim.txt',
        relativePath: 'victim.txt',
        side: SyncSide.right,
        trashLocation: trashLocation,
        bytes: 3,
      ),
    );
    fs.reset();

    await expectLater(
      restoreTrashedFiles(
        journal,
        fsFor: (_) => fs,
        rootFor: (_) => suppliedRoot.path,
      ),
      throwsA(
        isA<RemoteFileException>()
            .having((error) => error.kind, 'kind', RemoteFileErrorKind.conflict)
            .having((error) => error.path, 'path', suppliedRoot.path),
      ),
    );

    expect(fs.accessCount, 0);
    expect(trashed.existsSync(), isTrue);
    expect(
      File(context.join(suppliedRoot.path, 'victim.txt')).existsSync(),
      isFalse,
    );
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
    final restoreRootPath = await localFs.canonicalize(restoreRoot.path);
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
      rootFor: (_) => restoreRootPath,
    );

    expect(report.restored, ['document.txt'], reason: '${report.skipped}');
    expect(origin.readAsStringSync(), 'old');
    expect(File(trashLocation).existsSync(), isFalse);
  });

  test('lastAttempt drives attempt numbering', () async {
    final written = await writeRun('run-4');
    expect(
      written.lastAttempt('d.txt', SyncSide.right, SyncActionType.deleteRight),
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

  test('rmdir-only replace stays restorable until completion', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-empty-replace'),
    );
    await journal.appendItem(
      const SyncJournalItemLine(
        relativePath: 'entry',
        side: SyncSide.right,
        action: SyncActionType.copyLeftToRight,
        outcome: SyncItemStatus.done,
        attempt: 1,
        bytes: 8,
      ),
    );
    await journal.appendRmdir(
      const SyncJournalRmdirLine(
        relativePath: 'entry',
        side: SyncSide.right,
        parentPath: 'entry',
      ),
    );

    expect(journal.hasUnpurgedTrash, isFalse);
    expect(journal.hasRestorableChanges, isTrue);
    expect(journal.restoreImpact.restoredItemCount, 1);
    expect(journal.restoreImpact.removedCreatedFileCount, 1);

    const transactionId = '0123456789abcdef0123456789abcdef';
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': transactionId,
      'side': 'right',
      'parent': 'entry',
    });
    var replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.hasIncompleteRestore, isTrue);
    expect(replayed.hasRestorableChanges, isTrue);
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.incomplete,
    );

    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStaged',
      'transactionId': transactionId,
    });
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreChildren',
      'transactionId': transactionId,
    });
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreComplete',
      'transactionId': transactionId,
    });
    replayed = await SyncRunJournal.open(journal.path);
    expect(replayed.hasIncompleteRestore, isFalse);
    expect(replayed.hasRestorableChanges, isFalse);
    expect(replayed.restoreImpact.restoredItemCount, 0);
    expect(replayed.restoreImpact.removedCreatedFileCount, 0);
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.none,
    );
  });

  test('invalid replace restore transitions fail closed', () async {
    const transactionId = '0123456789abcdef0123456789abcdef';
    const trashLocation = '/trash/run-invalid/000001-entry.txt';
    const digest =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final invalidSequences = <String, List<Map<String, Object?>>>{
      'orphan-staged': [
        const {'type': 'replaceRestoreStaged', 'transactionId': transactionId},
      ],
      'entry-before-staged': [
        const {
          'type': 'replaceRestorePrepared',
          'transactionId': transactionId,
          'side': 'right',
          'parent': 'entry',
          'path': 'entry/old.txt',
          'trashLocation': trashLocation,
          'bytes': 3,
          'sha256': digest,
        },
        const {
          'type': 'replaceRestoreStarted',
          'transactionId': transactionId,
          'side': 'right',
          'parent': 'entry',
        },
        const {
          'type': 'replaceRestoreEntry',
          'transactionId': transactionId,
          'path': 'entry/old.txt',
          'trashLocation': trashLocation,
        },
      ],
      'children-before-staged': [
        const {
          'type': 'replaceRestoreStarted',
          'transactionId': transactionId,
          'side': 'right',
          'parent': 'entry',
        },
        const {
          'type': 'replaceRestoreChildren',
          'transactionId': transactionId,
        },
      ],
      'complete-before-children': [
        const {
          'type': 'replaceRestoreStarted',
          'transactionId': transactionId,
          'side': 'right',
          'parent': 'entry',
        },
        const {'type': 'replaceRestoreStaged', 'transactionId': transactionId},
        const {
          'type': 'replaceRestoreComplete',
          'transactionId': transactionId,
        },
      ],
    };

    for (final sequence in invalidSequences.entries) {
      final journal = await SyncRunJournal.create(
        runsDir.path,
        record('run-${sequence.key}'),
      );
      for (final restoreRecord in sequence.value) {
        await appendRestoreRecord(journal, restoreRecord);
      }

      await expectLater(
        SyncRunJournal.open(journal.path),
        throwsA(isA<FormatException>()),
        reason: sequence.key,
      );
      expect(
        await SyncRunJournal.inspectRestoreRecovery(journal.path),
        SyncRestoreJournalState.unreadableRecovery,
        reason: sequence.key,
      );
      final overlap = await SyncRunJournal.findIncompleteRestoreOverlap(
        runsDir.path,
        pairId: 'unrelated-pair',
        trashScopes: const [],
      );
      expect(
        overlap?.journalState,
        SyncRestoreJournalState.unreadableRecovery,
        reason: sequence.key,
      );

      await File(journal.path).delete();
    }
  });

  test('v1 recovery records are unreadable', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-v1-recovery'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': '0123456789abcdef0123456789abcdef',
      'side': 'right',
      'parent': 'entry',
    }, version: 1);

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.unreadableRecovery,
    );
  });

  test('unsupported-version recovery records are unreadable', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-unsupported-recovery'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': '0123456789abcdef0123456789abcdef',
      'side': 'right',
      'parent': 'entry',
    }, version: 3);

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.unreadableRecovery,
    );
  });

  test('v2 recovery records before the header are unreadable', () async {
    const transactionId = '0123456789abcdef0123456789abcdef';
    const trashLocation = '/trash/run-before-header/000001-entry.txt';
    const records = <Map<String, Object?>>[
      {
        'type': 'replaceRestorePrepared',
        'transactionId': transactionId,
        'side': 'right',
        'parent': 'entry',
        'path': 'entry/old.txt',
        'trashLocation': trashLocation,
        'bytes': 3,
        'sha256':
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      },
      {
        'type': 'replaceRestoreStarted',
        'transactionId': transactionId,
        'side': 'right',
        'parent': 'entry',
      },
      {'type': 'replaceRestoreStaged', 'transactionId': transactionId},
      {
        'type': 'replaceRestoreEntry',
        'transactionId': transactionId,
        'path': 'entry/old.txt',
        'trashLocation': trashLocation,
      },
      {'type': 'replaceRestoreChildren', 'transactionId': transactionId},
      {'type': 'replaceRestoreComplete', 'transactionId': transactionId},
    ];

    for (final recoveryRecord in records) {
      final type = recoveryRecord['type']! as String;
      final journal = await SyncRunJournal.create(
        runsDir.path,
        record('run-before-header-$type'),
      );
      final file = File(journal.path);
      final header = await file.readAsString();
      await file.writeAsString(
        '${jsonEncode(<String, Object?>{'v': 2, ...recoveryRecord})}\n$header',
        flush: true,
      );

      await expectLater(
        SyncRunJournal.open(journal.path),
        throwsA(isA<FormatException>()),
        reason: type,
      );
      expect(
        await SyncRunJournal.inspectRestoreRecovery(journal.path),
        SyncRestoreJournalState.unreadableRecovery,
        reason: type,
      );
    }
  });

  test('prune retains an incomplete restore outside the cap', () async {
    for (var i = 0; i < 3; i++) {
      final journal = await SyncRunJournal.create(
        runsDir.path,
        record(
          'run-incomplete-$i',
          DateTime.fromMillisecondsSinceEpoch(1700000000000 + i * 1000),
        ),
      );
      if (i != 0) continue;

      await appendRestoreRecord(journal, const {
        'type': 'replaceRestoreStarted',
        'transactionId': '0123456789abcdef0123456789abcdef',
        'side': 'right',
        'parent': 'entry',
      });
    }

    await SyncRunJournal.prune(runsDir.path, 'pair-1', keep: 1);

    final remaining = runsDir
        .listSync()
        .map((entry) => entry.uri.pathSegments.last)
        .toSet();
    expect(remaining, {'run-incomplete-0.jsonl', 'run-incomplete-2.jsonl'});
  });

  test('unreadable recovery records block admission fail-closed', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-unreadable-recovery'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': '0123456789abcdef0123456789abcdef',
      'side': 'right',
      'parent': 'entry',
    });
    final file = File(journal.path);
    final text = await file.readAsString();
    await file.writeAsString(text.replaceFirst('"v":1', '"v":99'));

    final overlap = await SyncRunJournal.findIncompleteRestoreOverlap(
      runsDir.path,
      pairId: 'unrelated-pair',
      trashScopes: const ['/unrelated-trash'],
    );

    expect(overlap, isNotNull);
    expect(overlap!.runId, 'run-unreadable-recovery');
    expect(overlap.pairId, isNull);
    expect(overlap.journalState, SyncRestoreJournalState.unreadableRecovery);
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.unreadableRecovery,
    );
  });

  test('pair recovery lookup returns the open incomplete journal', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-pair-recovery'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': '0123456789abcdef0123456789abcdef',
      'side': 'right',
      'parent': 'entry',
    });

    final found = await SyncRunJournal.findIncompleteRestoresForPair(
      runsDir.path,
      'pair-1',
    );

    expect(found, hasLength(1));
    expect(found.single.record.runId, 'run-pair-recovery');
    expect(found.single.hasIncompleteRestore, isTrue);
    expect(
      await SyncRunJournal.findIncompleteRestoresForPair(
        runsDir.path,
        'other-pair',
      ),
      isEmpty,
    );

    final lookup = await SyncRunJournal.findIncompleteRestoreForPairs(
      runsDir.path,
      {'legacy-pair-id', 'pair-1'},
    );
    expect(lookup, isA<SyncIncompleteRestoreFound>());
    expect(
      (lookup as SyncIncompleteRestoreFound).journals.map(
        (journal) => journal.record.runId,
      ),
      ['run-pair-recovery'],
    );
    expect(
      await SyncRunJournal.findIncompleteRestoreForPairs(runsDir.path, {
        'other-pair',
      }),
      isA<SyncIncompleteRestoreAbsent>(),
    );
  });

  test(
    'recovery lookup ignores symlinked journals outside sync_runs',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'poltergeist-journal-outside-',
      );
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final journal = await SyncRunJournal.create(
        outside.path,
        record('run-outside-recovery'),
      );
      await appendRestoreRecord(journal, const {
        'type': 'replaceRestoreStarted',
        'transactionId': '0123456789abcdef0123456789abcdef',
        'side': 'right',
        'parent': 'entry',
      });
      await Link('${runsDir.path}/linked.jsonl').create(journal.path);

      expect(
        await SyncRunJournal.findIncompleteRestoreForPairs(runsDir.path, {
          'pair-1',
        }),
        isA<SyncIncompleteRestoreAbsent>(),
      );
      expect(
        await SyncRunJournal.findIncompleteRestoreOverlap(
          runsDir.path,
          pairId: 'pair-1',
          trashScopes: const [],
        ),
        isNull,
      );
    },
  );

  test('pair recovery lookup fails closed on unreadable recovery', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-pair-unreadable'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': '0123456789abcdef0123456789abcdef',
      'side': 'right',
      'parent': 'entry',
    });
    await File(journal.path).writeAsString(
      '\n${jsonEncode(const <String, Object?>{'v': 999, 'type': 'futureRecovery'})}\n',
      mode: FileMode.append,
      flush: true,
    );

    await expectLater(
      SyncRunJournal.findIncompleteRestoresForPair(runsDir.path, 'pair-1'),
      throwsA(
        isA<SyncRestoreJournalUnreadableException>().having(
          (error) => error.path,
          'path',
          journal.path,
        ),
      ),
    );

    final relevant = await SyncRunJournal.findIncompleteRestoreForPairs(
      runsDir.path,
      {'pair-1'},
    );
    expect(relevant, isA<SyncIncompleteRestoreBlocked>());
    expect(
      (relevant as SyncIncompleteRestoreBlocked).journalPath,
      journal.path,
    );
    expect(relevant.pairId, 'pair-1');

    expect(
      await SyncRunJournal.findIncompleteRestoreForPairs(runsDir.path, {
        'other-pair',
      }),
      isA<SyncIncompleteRestoreAbsent>(),
    );
  });

  test('malformed started recovery blocks admission fail-closed', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-malformed-started-recovery'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': '0123456789abcdef0123456789abcdef',
      'side': 'right',
    });

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      SyncRunJournal.findIncompleteRestoresForPair(runsDir.path, 'pair-1'),
      throwsA(
        isA<SyncRestoreJournalUnreadableException>().having(
          (error) => error.path,
          'path',
          journal.path,
        ),
      ),
    );
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.unreadableRecovery,
    );
    expect(
      await SyncRunJournal.findIncompleteRestoreForPairs(runsDir.path, {
        'other-pair',
      }),
      isA<SyncIncompleteRestoreAbsent>(),
    );
  });

  test('malformed recovery transaction id is unreadable', () async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      record('run-malformed-transaction-id'),
    );
    await appendRestoreRecord(journal, const {
      'type': 'replaceRestoreStarted',
      'transactionId': 'not-a-transaction-id',
      'side': 'right',
      'parent': 'entry',
    });

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
    expect(
      await SyncRunJournal.inspectRestoreRecovery(journal.path),
      SyncRestoreJournalState.unreadableRecovery,
    );
    expect(
      await SyncRunJournal.findIncompleteRestoreForPairs(runsDir.path, {
        'pair-1',
      }),
      isA<SyncIncompleteRestoreBlocked>(),
    );
  });

  test('pair recovery lookup returns every journal newest first', () async {
    final older = await SyncRunJournal.create(
      runsDir.path,
      record('run-pair-older', DateTime.utc(2026, 1, 1)),
    );
    final newer = await SyncRunJournal.create(
      runsDir.path,
      record('run-pair-newer', DateTime.utc(2026, 1, 2)),
    );
    for (final journal in [older, newer]) {
      await appendRestoreRecord(journal, const {
        'type': 'replaceRestoreStarted',
        'transactionId': '0123456789abcdef0123456789abcdef',
        'side': 'right',
        'parent': 'entry',
      });
    }

    final lookup = await SyncRunJournal.findIncompleteRestoreForPairs(
      runsDir.path,
      {'pair-1'},
    );

    expect(lookup, isA<SyncIncompleteRestoreFound>());
    expect(
      (lookup as SyncIncompleteRestoreFound).journals.map(
        (journal) => journal.record.runId,
      ),
      ['run-pair-newer', 'run-pair-older'],
    );
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
    await File(
      journal.path,
    ).writeAsString('{"v":1,"type":"item","path":"to', mode: FileMode.append);
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
    await File(journal.path).writeAsString('$header\n', mode: FileMode.append);

    await expectLater(
      SyncRunJournal.open(journal.path),
      throwsA(isA<FormatException>()),
    );
  });

  test('a path-unsafe runId is refused at create', () async {
    await expectLater(
      SyncRunJournal.create(
        runsDir.path,
        record('../escape', DateTime.fromMillisecondsSinceEpoch(1700000000000)),
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

final class _CountingLocalFileSystem extends LocalFileSystem {
  var accessCount = 0;

  void reset() => accessCount = 0;

  @override
  Future<String> canonicalize(String path) {
    accessCount++;
    return super.canonicalize(path);
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    accessCount++;
    return super.stat(path, followLinks: followLinks);
  }
}
