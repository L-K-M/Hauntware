@TestOn('vm')
library;

// Rail 5's trash purge (05 §8 rail 5): the pure-package half — inspect,
// select, and purge over the one VFS, with journal coverage read from the
// local JSONL journals. The app layer owns the notice chip, the confirm
// dialog, and the sync.purgeTrash command; this suite pins the engine
// behavior those surfaces depend on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

final SyncTrashPathStyle _nativeTrashPathStyle = Platform.isWindows
    ? SyncTrashPathStyle.windows
    : SyncTrashPathStyle.posix;
final SyncTrashPathCase _nativeTrashPathCase = Platform.isWindows
    ? SyncTrashPathCase.insensitive
    : SyncTrashPathCase.sensitive;
final _nativeTrashPathContext = syncTrashPathContext(_nativeTrashPathStyle);
const int _replaceRestoreSchemaVersion = 2;
const int _unsupportedJournalSchemaVersion = 999;
const String _journalFileSuffix = '.jsonl';
const String _testRestoreTransactionId = '0123456789abcdef0123456789abcdef';
const String _testRestoreDigest =
    '0000000000000000000000000000000000000000000000000000000000000000';

String _nativeJoin(String parent, String child) =>
    _nativeTrashPathContext.join(parent, child);

String _nativeBasename(String path) => _nativeTrashPathContext.basename(path);

String _nativeParent(String path) => _nativeTrashPathContext.dirname(path);

extension _NativeTrashPurgeInspection on SyncTrashPurgeService {
  Future<SyncTrashInventory> inspectNative(
    RemoteFileSystem fileSystem,
    String trashRoot,
    String devicePrefix,
    DateTime now, {
    String? trashScope,
    SyncTrashPathStyle? pathStyle,
    SyncTrashPathCase? pathCase,
    bool Function(String runId)? isActiveRun,
    bool Function()? isCancelled,
    void Function(String runId)? onPurgedRun,
  }) => inspect(
    fileSystem,
    trashRoot,
    devicePrefix,
    now,
    trashScope: trashScope,
    pathStyle: pathStyle ?? _nativeTrashPathStyle,
    pathCase: pathCase ?? _nativeTrashPathCase,
    isActiveRun: isActiveRun,
    isCancelled: isCancelled,
    onPurgedRun: onPurgedRun,
  );
}

/// A LocalFileSystem that counts trash-root listings — inspect must
/// perform exactly one non-recursive listing, never a walk.
final class _CountingFs extends LocalFileSystem {
  var listCalls = 0;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    listCalls++;
    return super.listDirectory(path);
  }
}

/// Simulates a case-insensitive root whose listing spelling differs from
/// the journal spelling while keeping the underlying test files unchanged.
final class _CaseVariantRootListingFs extends LocalFileSystem {
  _CaseVariantRootListingFs(this.trashRoot, this.replacements);

  final String trashRoot;
  final Map<String, String> replacements;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    if (_nativeTrashPathContext.normalize(path) !=
        _nativeTrashPathContext.normalize(trashRoot)) {
      return entries;
    }

    return [
      for (final entry in entries)
        if (replacements[entry.name] case final replacement?)
          RemoteFileEntry(
            path: _nativeJoin(path, replacement),
            name: replacement,
            type: entry.type,
            size: entry.size,
            uid: entry.uid,
            gid: entry.gid,
            accessedAt: entry.accessedAt,
            modifiedAt: entry.modifiedAt,
            contentSha256: entry.contentSha256,
            mode: entry.mode,
          )
        else
          entry,
    ];
  }
}

/// A LocalFileSystem that reports scripted mtimes for listed
/// directories — directory mtimes have no pure-Dart setter, so aging
/// tests pin them at the listing seam instead.
final class _AgedDirFs extends LocalFileSystem {
  final Map<String, DateTime> dirMtime = {};

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    return [
      for (final entry in entries)
        if (dirMtime[entry.name] == null)
          entry
        else
          RemoteFileEntry(
            path: entry.path,
            name: entry.name,
            type: entry.type,
            size: entry.size,
            uid: entry.uid,
            gid: entry.gid,
            accessedAt: entry.accessedAt,
            modifiedAt: dirMtime[entry.name],
            contentSha256: entry.contentSha256,
            mode: entry.mode,
          ),
    ];
  }
}

/// A LocalFileSystem that hides mtimes from listings — uncovered dirs
/// with no observable mtime must not age out immediately.
final class _NoMtimeFs extends LocalFileSystem {
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    return [
      for (final entry in entries)
        RemoteFileEntry(
          path: entry.path,
          name: entry.name,
          type: entry.type,
          size: entry.size,
          uid: entry.uid,
          gid: entry.gid,
          mode: entry.mode,
        ),
    ];
  }
}

/// A LocalFileSystem whose listing always fails with a non-notFound
/// error — inspect must propagate it, never swallow it as empty.
final class _FailingListFs extends LocalFileSystem {
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) => Future.error(
    const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'list',
      message: 'denied',
    ),
  );
}

/// Models a local platform whose filesystem cannot express POSIX modes.
final class _UnsupportedModeFs extends LocalFileSystem {
  @override
  Future<void> setMode(String path, int permissions) => Future.error(
    RemoteFileException(
      kind: RemoteFileErrorKind.unsupported,
      operation: 'change permissions for',
      path: path,
      message: 'unsupported for test',
    ),
  );
}

/// A LocalFileSystem that refuses to delete anything under [failName] —
/// one bad run dir must fail in the report while its siblings purge.
final class _FailingDeleteFs extends LocalFileSystem {
  _FailingDeleteFs(this.failName);

  final String failName;

  @override
  Future<void> delete(RemoteFileEntry entry) {
    if (entry.path.contains(failName)) {
      return Future.error(
        RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'delete',
          path: entry.path,
          message: 'denied for test',
        ),
      );
    }
    return super.delete(entry);
  }
}

final class _VanishAfterRootListFs extends LocalFileSystem {
  _VanishAfterRootListFs(this.trashRoot, this.runPath);

  final String trashRoot;
  final String runPath;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    if (path == trashRoot && await Directory(runPath).exists()) {
      await Directory(runPath).delete(recursive: true);
    }
    return entries;
  }
}

final class _PoisonedChildPathFs extends LocalFileSystem {
  _PoisonedChildPathFs(this.runPath, this.outsidePath);

  final String runPath;
  final String outsidePath;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final originalName = _nativeBasename(runPath);
    final listedName = _nativeBasename(path);
    if (listedName != originalName &&
        !listedName.startsWith('$originalName.purging-')) {
      return super.listDirectory(path);
    }
    return [
      RemoteFileEntry(
        path: outsidePath,
        name: 'inside.txt',
        type: RemoteFileType.file,
        size: 3,
      ),
    ];
  }
}

final class _PoisonedStatPathFs extends LocalFileSystem {
  _PoisonedStatPathFs(this.insidePath, this.outsidePath);

  final String insidePath;
  final String outsidePath;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    final entry = await super.stat(path, followLinks: followLinks);
    final originalParent = _nativeBasename(_nativeParent(insidePath));
    final parent = _nativeBasename(_nativeParent(path));
    if (_nativeBasename(path) != _nativeBasename(insidePath) ||
        (parent != originalParent &&
            !parent.startsWith('$originalParent.purging-'))) {
      return entry;
    }

    return RemoteFileEntry(
      path: outsidePath,
      name: entry.name,
      type: entry.type,
      size: entry.size,
      uid: entry.uid,
      gid: entry.gid,
      accessedAt: entry.accessedAt,
      modifiedAt: entry.modifiedAt,
      contentSha256: entry.contentSha256,
      mode: entry.mode,
    );
  }
}

final class _SwapRunForSymlinkFs extends LocalFileSystem {
  _SwapRunForSymlinkFs(this.runPath, this.outsidePath);

  final String runPath;
  final String outsidePath;
  var _swapped = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    final entry = await super.stat(path, followLinks: followLinks);
    if (_swapped || path != runPath || followLinks) return entry;

    _swapped = true;
    await Directory(runPath).delete(recursive: true);
    await Link(runPath).create(outsidePath);
    return entry;
  }
}

final class _SwapNestedForSymlinkFs extends LocalFileSystem {
  _SwapNestedForSymlinkFs(this.nestedName, this.outsidePath);

  final String nestedName;
  final String outsidePath;
  var _swapped = false;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    if (!_swapped && _nativeBasename(path) == nestedName) {
      _swapped = true;
      await Directory(path).delete(recursive: true);
      await Link(path).create(outsidePath);
    }

    return super.listDirectory(path);
  }
}

final class _CancelAfterRunDeleteFs extends LocalFileSystem {
  _CancelAfterRunDeleteFs(this.runId, this.cancellation);

  final String runId;
  final RemoteTransferCancellation cancellation;

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    await super.delete(entry);

    if (entry.isDirectory && entry.name.startsWith('$runId.purging-')) {
      cancellation.cancel();
    }
  }
}

final class _CancelAfterRootListFs extends LocalFileSystem {
  _CancelAfterRootListFs(this.trashRoot, this.cancellation);

  final String trashRoot;
  final RemoteTransferCancellation cancellation;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    if (path == trashRoot) cancellation.cancel();
    return entries;
  }
}

final class _CancelWithRollbackFailureFs extends LocalFileSystem {
  _CancelWithRollbackFailureFs(this.runPath, this.cancellation);

  final String runPath;
  final RemoteTransferCancellation cancellation;

  @override
  Future<void> delete(RemoteFileEntry entry) {
    if (!entry.isDirectory && entry.path.contains('.purging-')) {
      cancellation.cancel();
      throw RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'delete',
        path: entry.path,
        message: 'delete denied for test',
      );
    }

    return super.delete(entry);
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) {
    if (oldPath.contains('.purging-') && newPath == runPath) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'restore',
        path: oldPath,
        message: 'rollback denied for test',
      );
    }

    return super.rename(oldPath, newPath, overwrite: overwrite);
  }
}

String _runId(String prefix, String label) {
  final hex = sha256.convert(utf8.encode(label)).toString();
  return '$prefix-${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '4${hex.substring(13, 16)}-a${hex.substring(17, 20)}-'
      '${hex.substring(20, 32)}';
}

/// Uses the physical path expected by trash-root ownership checks.
/// macOS aliases `/var` to `/private/var`.
Future<Directory> _createCanonicalTempDirectory(String prefix) async {
  final directory = await Directory.systemTemp.createTemp(prefix);
  return Directory(await directory.resolveSymbolicLinks());
}

final class _InspectAfterQuarantineFs extends LocalFileSystem {
  _InspectAfterQuarantineFs({required this.onQuarantined});

  final Future<void> Function() onQuarantined;
  var _inspected = false;

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    await super.rename(oldPath, newPath, overwrite: overwrite);
    if (_inspected || !newPath.contains('.purging-')) return;

    _inspected = true;
    await onQuarantined();
  }
}

final class _SwapTrashRootForSymlinkFs extends LocalFileSystem {
  _SwapTrashRootForSymlinkFs({
    required this.trashRoot,
    required this.movedRoot,
    required this.outsideRoot,
  });

  final String trashRoot;
  final String movedRoot;
  final String outsideRoot;
  var _swapped = false;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    if (_swapped || path != trashRoot) return entries;

    _swapped = true;
    await Directory(trashRoot).rename(movedRoot);
    await Link(trashRoot).create(outsideRoot);
    return entries;
  }
}

final class _SwapBeforeTrashListFs extends LocalFileSystem {
  _SwapBeforeTrashListFs({
    required this.trashRoot,
    required this.movedRoot,
    required this.outsideRoot,
  });

  final String trashRoot;
  final String movedRoot;
  final String outsideRoot;
  var _swapped = false;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    if (!_swapped && path == trashRoot) {
      _swapped = true;
      await Directory(trashRoot).rename(movedRoot);
      await Link(trashRoot).create(outsideRoot);
    }

    return super.listDirectory(path);
  }
}

final class _RestoreRootAfterMissingProbeFs extends LocalFileSystem {
  _RestoreRootAfterMissingProbeFs({
    required this.trashRoot,
    required this.movedRoot,
  });

  final String trashRoot;
  final String movedRoot;
  var _restored = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (!_restored && path == trashRoot && !followLinks) {
      _restored = true;
      await Directory(movedRoot).rename(trashRoot);
      throw RemoteFileException(
        kind: RemoteFileErrorKind.notFound,
        operation: 'stat',
        path: path,
        message: 'missing for test',
      );
    }

    return super.stat(path, followLinks: followLinks);
  }
}

final class _SwapRecoverySourceForSymlinkFs extends LocalFileSystem {
  _SwapRecoverySourceForSymlinkFs({
    required this.quarantinePath,
    required this.outsidePath,
  });

  final String quarantinePath;
  final String outsidePath;
  var _swapped = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    final entry = await super.stat(path, followLinks: followLinks);
    if (_swapped || path != quarantinePath || followLinks) return entry;

    _swapped = true;
    await Directory(quarantinePath).delete(recursive: true);
    await Link(quarantinePath).create(outsidePath);
    return entry;
  }
}

final class _ReplaceRootBeforeRecoveryFs extends LocalFileSystem {
  _ReplaceRootBeforeRecoveryFs({
    required this.trashRoot,
    required this.movedRoot,
    required this.replacementRoot,
    required this.quarantinePath,
  });

  final String trashRoot;
  final String movedRoot;
  final String replacementRoot;
  final String quarantinePath;
  var _swapped = false;

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    if (!_swapped && oldPath == quarantinePath) {
      _swapped = true;
      await Directory(trashRoot).rename(movedRoot);
      await Directory(replacementRoot).rename(trashRoot);
    }

    await super.rename(oldPath, newPath, overwrite: overwrite);
  }
}

final class _ReplaceRootAfterRecoveryFs extends LocalFileSystem {
  _ReplaceRootAfterRecoveryFs({
    required this.trashRoot,
    required this.movedRoot,
    required this.replacementRoot,
    required this.quarantinePath,
    required this.originalPath,
  });

  final String trashRoot;
  final String movedRoot;
  final String replacementRoot;
  final String quarantinePath;
  final String originalPath;
  var _swapped = false;

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    await super.rename(oldPath, newPath, overwrite: overwrite);
    if (_swapped || oldPath != quarantinePath || newPath != originalPath) {
      return;
    }

    _swapped = true;
    await Directory(trashRoot).rename(movedRoot);
    await Directory(replacementRoot).rename(trashRoot);
  }
}

final class _ReplaceRootWithEmptyOwnedRootFs extends LocalFileSystem {
  _ReplaceRootWithEmptyOwnedRootFs({
    required this.trashRoot,
    required this.movedRoot,
  });

  final String trashRoot;
  final String movedRoot;
  var _swapped = false;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    if (_swapped || path != trashRoot) return super.listDirectory(path);

    _swapped = true;
    await Directory(trashRoot).rename(movedRoot);
    await resolveSyncTrashRoot(
      this,
      trashRoot,
      pathStyle: _nativeTrashPathStyle,
      access: SyncTrashRootAccess.createOrClaim,
    );
    return const [];
  }
}

final class _ReplaceRootBeforeRunQuarantineFs extends LocalFileSystem {
  _ReplaceRootBeforeRunQuarantineFs({
    required this.trashRoot,
    required this.movedRoot,
    required this.replacementRoot,
    required this.runPath,
  });

  final String trashRoot;
  final String movedRoot;
  final String replacementRoot;
  final String runPath;
  var _swapped = false;

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    if (!_swapped && oldPath == runPath && newPath.contains('.purging-')) {
      _swapped = true;
      await Directory(trashRoot).rename(movedRoot);
      await Directory(replacementRoot).rename(trashRoot);
    }

    await super.rename(oldPath, newPath, overwrite: overwrite);
  }
}

final class _ReplaceRootAfterRunQuarantineFs extends LocalFileSystem {
  _ReplaceRootAfterRunQuarantineFs({
    required this.trashRoot,
    required this.movedRoot,
    required this.replacementRoot,
    required this.runPath,
  });

  final String trashRoot;
  final String movedRoot;
  final String replacementRoot;
  final String runPath;
  String? quarantineName;

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    await super.rename(oldPath, newPath, overwrite: overwrite);
    if (quarantineName != null ||
        oldPath != runPath ||
        !newPath.contains('.purging-')) {
      return;
    }

    quarantineName = _nativeBasename(newPath);
    await Directory(trashRoot).rename(movedRoot);
    await Directory(replacementRoot).rename(trashRoot);
    final replacementQuarantine = Directory(
      _nativeJoin(trashRoot, quarantineName!),
    )..createSync();
    File(
      _nativeJoin(replacementQuarantine.path, 'precious.txt'),
    ).writeAsStringSync('precious');
  }
}

final class _RenameBeforeTrashListFs extends LocalFileSystem {
  _RenameBeforeTrashListFs({
    required this.trashRoot,
    required this.oldPath,
    required this.newPath,
  });

  final String trashRoot;
  final String oldPath;
  final String newPath;
  var _renamed = false;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    if (!_renamed && path == trashRoot) {
      _renamed = true;
      await rename(oldPath, newPath);
    }

    return super.listDirectory(path);
  }
}

final class _RecoverBeforeReservationFs extends LocalFileSystem {
  _RecoverBeforeReservationFs({
    required this.quarantinePath,
    required this.runPath,
  });

  final String quarantinePath;
  final String runPath;
  var _recovered = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (!_recovered && path == quarantinePath && !followLinks) {
      _recovered = true;
      await rename(quarantinePath, runPath);
    }

    return super.stat(path, followLinks: followLinks);
  }
}

final class _VirtualWindowsTrashFs extends LocalFileSystem {
  _VirtualWindowsTrashFs({
    required this.root,
    required this.runId,
    required this.rootId,
  });

  final String root;
  final String runId;
  final String rootId;

  String get _marker => '$root\\$syncTrashRootMarkerName';
  String get _identity => '$_marker\\identity';

  @override
  Future<String> canonicalize(String path) async => root;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (path == root || path == _marker) {
      return RemoteFileEntry(
        path: path,
        name: path == root ? 'trash' : syncTrashRootMarkerName,
        type: RemoteFileType.directory,
      );
    }
    if (path == _identity) {
      return RemoteFileEntry(
        path: path,
        name: 'identity',
        type: RemoteFileType.file,
        size: 'poltergeist-sync-trash-v1:$rootId\n'.length,
      );
    }
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      path: path,
      message: 'missing',
    );
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => [
    RemoteFileEntry(
      path: '$root\\$syncTrashRootMarkerName',
      name: syncTrashRootMarkerName,
      type: RemoteFileType.directory,
    ),
    RemoteFileEntry(
      path: '$root\\$runId',
      name: runId,
      type: RemoteFileType.directory,
      modifiedAt: DateTime.now(),
    ),
  ];

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    final bytes = utf8.encode('poltergeist-sync-trash-v1:$rootId\n');
    destination.add(bytes);
    await destination.close();
    return RemoteFileEntry(
      path: path,
      name: 'identity',
      type: RemoteFileType.file,
      size: bytes.length,
    );
  }
}

void main() {
  late Directory scratch;
  late Directory runsDir;
  late Directory trashRootDir;
  late String trashRoot;
  late LocalFileSystem fs;
  late String devicePrefix;
  late DateTime now;

  const rules = SyncRuleSet(
    direction: SyncDirection.leftToRight,
    deletions: DeletionPolicy.trash,
    backups: BackupPolicy.trash,
    maxDelete: 250,
  );

  SyncRunRecord record(String runId, {DateTime? startedAt}) => SyncRunRecord(
    runId: runId,
    pairId: 'pair-1',
    startedAt: startedAt ?? now,
    rules: rules,
    totals: const PlanTotals(
      counts: {},
      bytes: {},
      replacedFiles: 0,
      replacedBytes: 0,
    ),
    warnings: const [],
  );

  /// Writes a journal whose trash entries land under [runId] inside the
  /// test trash root — one item line plus one trash line sharing a
  /// location (dedup coverage) plus a second distinct location.
  Future<SyncRunJournal> writeJournal(
    String runId, {
    DateTime? startedAt,
    String pairId = 'pair-1',
    String? trashScopeLeft,
    String? trashRootOverride,
  }) async {
    final journal = await SyncRunJournal.create(
      runsDir.path,
      SyncRunRecord(
        runId: runId,
        pairId: pairId,
        startedAt: startedAt ?? now,
        trashScopeLeft: trashScopeLeft,
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
    final journalTrashRoot = trashRootOverride ?? trashRoot;
    final first = _nativeJoin(
      _nativeJoin(journalTrashRoot, runId),
      '000001-a.txt',
    );
    await journal.appendItem(
      SyncJournalItemLine(
        relativePath: 'a.txt',
        side: SyncSide.left,
        action: SyncActionType.deleteLeft,
        outcome: SyncItemStatus.done,
        attempt: 1,
        trashLocation: first,
        trashBytes: 3,
      ),
    );
    await journal.appendTrash(
      SyncJournalTrashLine(
        parentPath: 'b.txt',
        relativePath: 'b.txt',
        side: SyncSide.left,
        trashLocation: first,
        bytes: 3,
      ),
    );
    await journal.appendTrash(
      SyncJournalTrashLine(
        parentPath: 'c.txt',
        relativePath: 'c.txt',
        side: SyncSide.left,
        trashLocation: _nativeJoin(
          _nativeJoin(journalTrashRoot, runId),
          '000002-c.txt',
        ),
        bytes: 5,
      ),
    );
    return journal;
  }

  Future<void> appendIncompleteRestore(SyncRunJournal journal) async {
    final trash = journal.trashLines.first;
    final records = [
      <String, Object?>{
        'v': _replaceRestoreSchemaVersion,
        'type': 'replaceRestorePrepared',
        'transactionId': _testRestoreTransactionId,
        'side': trash.side.name,
        'parent': trash.parentPath,
        'path': trash.relativePath,
        'trashLocation': trash.trashLocation,
        'bytes': trash.bytes,
        'sha256': _testRestoreDigest,
      },
      <String, Object?>{
        'v': _replaceRestoreSchemaVersion,
        'type': 'replaceRestoreStarted',
        'transactionId': _testRestoreTransactionId,
        'side': trash.side.name,
        'parent': trash.parentPath,
      },
    ];
    await File(journal.path).writeAsString(
      '${records.map(jsonEncode).join('\n')}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> makeIncompleteRestoreJournalUnreadable(
    SyncRunJournal journal,
  ) async {
    await appendIncompleteRestore(journal);
    await File(journal.path).writeAsString(
      '${jsonEncode(<String, Object?>{'v': _unsupportedJournalSchemaVersion, 'type': 'unsupported'})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<String> makeRunDir(String name) async {
    final dir = Directory(_nativeJoin(trashRoot, name));
    await dir.create(recursive: true);
    await File(_nativeJoin(dir.path, '000001-a.txt')).writeAsString('old');
    return dir.path;
  }

  Future<String> currentTrashScope() async => (await resolveSyncTrashRoot(
    fs,
    trashRoot,
    pathStyle: _nativeTrashPathStyle,
    access: SyncTrashRootAccess.openExisting,
  )).scopeKey;

  setUp(() async {
    scratch = await _createCanonicalTempDirectory('poltergeist-purge-');
    runsDir = Directory(_nativeJoin(scratch.path, 'runs'));
    await runsDir.create();
    trashRootDir = Directory(_nativeJoin(scratch.path, 'trash'));
    await trashRootDir.create();
    trashRoot = trashRootDir.path;
    fs = LocalFileSystem();
    devicePrefix = syncRunDevicePrefix('test-device');
    now = DateTime.now();
    await resolveSyncTrashRoot(
      fs,
      trashRoot,
      pathStyle: _nativeTrashPathStyle,
      access: SyncTrashRootAccess.createOrClaim,
    );
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  group('retention and device prefix', () {
    test('retention is a 30-day constant', () {
      expect(syncTrashRetention, const Duration(days: 30));
    });

    test('mintRunId carries the exposed device prefix', () {
      final executor = SyncExecutor(
        leftFileSystem: LocalFileSystem(),
        rightFileSystem: LocalFileSystem(),
        leftRoot: scratch.path,
        rightRoot: scratch.path,
        syncRunsDirectory: runsDir.path,
        deviceId: 'test-device',
      );
      expect(executor.mintRunId(), startsWith('$devicePrefix-'));
      expect(syncRunDevicePrefix('test-device'), devicePrefix);
      expect(syncRunDevicePrefix('other-device'), isNot(devicePrefix));
    });

    test(
      'run accepts a valid reserved runId and still mints by default',
      () async {
        SyncPlan emptyPlan() => SyncPlan(
          pair: SyncPair(
            id: 'pair-id',
            name: 'pair',
            left: LocalEndpoint(scratch.path),
            right: LocalEndpoint(scratch.path),
            rules: rules,
          ),
          scannedAt: now,
          items: const [],
          warnings: const [],
          totals: const PlanTotals(
            counts: {},
            bytes: {},
            replacedFiles: 0,
            replacedBytes: 0,
          ),
        );
        SyncExecutor executor() => SyncExecutor(
          leftFileSystem: LocalFileSystem(),
          rightFileSystem: LocalFileSystem(),
          leftRoot: scratch.path,
          rightRoot: scratch.path,
          syncRunsDirectory: runsDir.path,
          deviceId: 'test-device',
        );
        final reservedRunId = _runId(devicePrefix, 'reserved');
        final reserved = await executor().run(
          emptyPlan(),
          pairId: 'pair-1',
          runId: reservedRunId,
        );
        expect(reserved.runId, reservedRunId);
        final minted = await executor().run(emptyPlan(), pairId: 'pair-1');
        expect(minted.runId, startsWith('$devicePrefix-'));
      },
    );

    test('run rejects a reserved id outside this device namespace', () async {
      final executor = SyncExecutor(
        leftFileSystem: LocalFileSystem(),
        rightFileSystem: LocalFileSystem(),
        leftRoot: scratch.path,
        rightRoot: scratch.path,
        syncRunsDirectory: runsDir.path,
        deviceId: 'test-device',
      );
      final plan = SyncPlan(
        pair: SyncPair(
          id: 'pair-id',
          name: 'pair',
          left: LocalEndpoint(scratch.path),
          right: LocalEndpoint(scratch.path),
          rules: rules,
        ),
        scannedAt: now,
        items: const [],
        warnings: const [],
        totals: const PlanTotals(
          counts: {},
          bytes: {},
          replacedFiles: 0,
          replacedBytes: 0,
        ),
      );

      await expectLater(
        executor.run(plan, pairId: 'pair-1', runId: 'reserved-run-id'),
        throwsArgumentError,
      );
      expect(
        File(_nativeJoin(runsDir.path, 'reserved-run-id.jsonl')).existsSync(),
        isFalse,
      );
    });
  });

  group('inspect', () {
    test('local roots tolerate unsupported POSIX modes', () async {
      final root = _nativeJoin(scratch.path, 'unsupported-mode-trash');

      final identity = await resolveSyncTrashRoot(
        _UnsupportedModeFs(),
        root,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );

      expect(isSyncTrashIdentityKey(identity.scopeKey), isTrue);
    });

    test('missing-scope release rejects path-shaped identities', () async {
      await expectLater(
        SyncTrashPurgeService(
          runsDir.path,
        ).markMissingScopePurged(trashRoot, '../outside'),
        throwsArgumentError,
      );
    });

    test('concurrent first claims converge on one root identity', () async {
      final root = Directory(_nativeJoin(scratch.path, 'concurrent-trash'));
      await root.create();

      final identities = await Future.wait([
        for (var i = 0; i < 8; i++)
          resolveSyncTrashRoot(
            LocalFileSystem(),
            root.path,
            pathStyle: _nativeTrashPathStyle,
            access: SyncTrashRootAccess.createOrClaim,
          ),
      ]);

      expect(
        identities.map((identity) => identity.rootId).toSet(),
        hasLength(1),
      );
    });

    test('performs exactly one listing; a missing root fails closed', () async {
      final counting = _CountingFs();
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(counting, trashRoot, devicePrefix, now);
      expect(counting.listCalls, 1);
      expect(inventory.runs, isEmpty);

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          fs,
          _nativeJoin(trashRoot, 'no-such-root'),
          devicePrefix,
          now,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.notFound,
          ),
        ),
      );
    });

    test('non-notFound listing errors propagate', () async {
      await expectLater(
        SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(_FailingListFs(), trashRoot, devicePrefix, now),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.permissionDenied,
          ),
        ),
      );
    });

    test(
      'journaled dirs carry startedAt, deduped counts, and pair ids',
      () async {
        final runId = _runId(devicePrefix, 'run-1');
        final startedAt = now.subtract(const Duration(days: 31));
        await makeRunDir(runId);
        await writeJournal(runId, startedAt: startedAt);

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);

        expect(inventory.runs, hasLength(1));
        final run = inventory.runs.single;
        expect(run.runId, runId);
        expect(run.ownership, SyncTrashOwnership.journaled);
        expect(run.ageBasis, startedAt);
        // Two distinct locations — the shared item/trash location counts once.
        expect(run.fileCount, 2);
        expect(run.pairIds, {'pair-1'});
      },
    );

    test('case-insensitive run names keep journal coverage', () async {
      final runId = _runId(devicePrefix, 'case-variant-run');
      final listedName = runId.toUpperCase();
      await makeRunDir(runId);
      final journal = await writeJournal(
        runId,
        trashScopeLeft: await currentTrashScope(),
      );

      final inventory = await SyncTrashPurgeService(runsDir.path).inspectNative(
        _CaseVariantRootListingFs(trashRoot, {runId: listedName}),
        trashRoot,
        devicePrefix,
        now,
        pathCase: SyncTrashPathCase.insensitive,
      );

      expect(inventory.runs, hasLength(1));
      expect(inventory.runs.single.runId, runId);
      expect(inventory.runs.single.directoryName, listedName);
      expect(inventory.runs.single.ownership, SyncTrashOwnership.journaled);
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test('case-insensitive quarantine names keep journal coverage', () async {
      final runId = _runId(devicePrefix, 'case-variant-quarantine');
      final runPath = await makeRunDir(runId);
      final foreignPrefix = syncRunDevicePrefix('other-device');
      const suffix = '0123456789abcdef01234567';
      final quarantineName = '$runId.purging-$foreignPrefix-$suffix';
      await fs.rename(runPath, _nativeJoin(trashRoot, quarantineName));
      final listedName = quarantineName.toUpperCase();
      final journal = await writeJournal(
        runId,
        trashScopeLeft: await currentTrashScope(),
      );

      final inventory = await SyncTrashPurgeService(runsDir.path).inspectNative(
        _CaseVariantRootListingFs(trashRoot, {quarantineName: listedName}),
        trashRoot,
        devicePrefix,
        now,
        pathCase: SyncTrashPathCase.insensitive,
      );

      expect(inventory.runs, hasLength(1));
      expect(inventory.runs.single.runId, runId);
      expect(inventory.runs.single.directoryName, listedName);
      expect(inventory.runs.single.ownership, SyncTrashOwnership.foreign);
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test(
      'trash locations outside the root or run dir are not coverage',
      () async {
        final runId = _runId(devicePrefix, 'run-2');
        await makeRunDir(runId);
        final journal = await SyncRunJournal.create(
          runsDir.path,
          record(runId),
        );
        // Same run id, but a foreign trash root — must not cover.
        await journal.appendTrash(
          const SyncJournalTrashLine(
            parentPath: 'x.txt',
            relativePath: 'x.txt',
            side: SyncSide.left,
            trashLocation: '/elsewhere/.poltergeist-trash/whatever/1-x.txt',
            bytes: 1,
          ),
        );
        // Same root, but the parent dir is another run's — must not cover.
        await journal.appendTrash(
          SyncJournalTrashLine(
            parentPath: 'y.txt',
            relativePath: 'y.txt',
            side: SyncSide.left,
            trashLocation: _nativeJoin(
              _nativeJoin(trashRoot, 'some-other-run'),
              '000001-y.txt',
            ),
            bytes: 1,
          ),
        );

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);

        expect(inventory.runs, hasLength(1));
        expect(inventory.runs.single.ownership, SyncTrashOwnership.localOrphan);
        expect(inventory.runs.single.fileCount, isNull);
      },
    );

    test('lexical trash-root aliases still match journal coverage', () async {
      final runId = _runId(devicePrefix, 'aliased');
      await makeRunDir(runId);
      await Directory(_nativeJoin(scratch.path, 'alias')).create();
      final aliasedRoot = _nativeJoin(
        _nativeJoin(scratch.path, 'alias'),
        '../trash',
      );
      final journal = await SyncRunJournal.create(runsDir.path, record(runId));
      await journal.appendItem(
        SyncJournalItemLine(
          relativePath: 'a.txt',
          side: SyncSide.left,
          action: SyncActionType.deleteLeft,
          outcome: SyncItemStatus.done,
          attempt: 1,
          trashLocation: _nativeJoin(
            _nativeJoin(aliasedRoot, runId),
            '000001-a.txt',
          ),
          trashBytes: 3,
        ),
      );

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      expect(inventory.runs.single.ownership, SyncTrashOwnership.journaled);
      expect(inventory.runs.single.fileCount, 1);
    });

    test('uncovered dirs classify by prefix and age by mtime', () async {
      final orphan = _runId(devicePrefix, 'orphan');
      final exported = 'rsync-20240101-120000';
      final foreign = _runId('ffffffff', 'foreign-run');
      final old = now.subtract(const Duration(days: 31));
      await makeRunDir(orphan);
      await makeRunDir(exported);
      await makeRunDir(foreign);
      final fresh = _runId(devicePrefix, 'fresh');
      await makeRunDir(fresh);
      final agedFs = _AgedDirFs()
        ..dirMtime[orphan] = old
        ..dirMtime[exported] = old
        ..dirMtime[foreign] = old;

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(agedFs, trashRoot, devicePrefix, now);

      final byId = {for (final run in inventory.runs) run.runId: run};
      expect(byId[orphan]!.ownership, SyncTrashOwnership.localOrphan);
      expect(byId[exported]!.ownership, SyncTrashOwnership.rsyncExport);
      expect(byId[foreign]!.ownership, SyncTrashOwnership.foreign);
      expect(byId[orphan]!.fileCount, isNull);
      expect(byId[orphan]!.pairIds, isEmpty);
      // mtime survives as the orphan age basis.
      expect(
        byId[orphan]!.ageBasis.millisecondsSinceEpoch ~/ 1000,
        old.millisecondsSinceEpoch ~/ 1000,
      );
      expect(byId[fresh]!.ownership, SyncTrashOwnership.localOrphan);
    });

    test('missing mtime never reads as immediately old', () async {
      final orphan = _runId('12345678', 'no-mtime');
      await makeRunDir(orphan);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(_NoMtimeFs(), trashRoot, devicePrefix, now);
      final run = inventory.runs.singleWhere((r) => r.runId == orphan);
      expect(run.ownership, SyncTrashOwnership.foreign);
      final selection = inventory.select(
        SyncTrashPurgeScope.aged,
        now,
        const {},
      );
      expect(selection.runIds, isNot(contains(orphan)));
    });

    test('non-directory children are ignored, never inventoried', () async {
      await File(_nativeJoin(trashRoot, 'stray.txt')).writeAsString('stray');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      expect(inventory.runs, isEmpty);
    });

    test('a non-directory run occupant keeps its journal protected', () async {
      final runId = _runId(devicePrefix, 'blocked-by-file');
      final journal = await writeJournal(runId);
      final occupant = File(_nativeJoin(trashRoot, runId));
      await occupant.writeAsString('not a run directory');

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      expect(inventory.runs, isEmpty);
      expect(await occupant.readAsString(), 'not a run directory');
      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasUnpurgedTrash, isTrue);
      expect(reopened.hasPurgeMarker, isFalse);
    });

    test('an unrelated directory cannot become a purge root', () async {
      final unrelatedRoot = Directory(_nativeJoin(scratch.path, 'unrelated'));
      await unrelatedRoot.create();
      final unrelated = Directory(_nativeJoin(unrelatedRoot.path, 'etc'));
      await unrelated.create();
      await File(
        _nativeJoin(unrelated.path, 'precious.txt'),
      ).writeAsString('precious');

      await expectLater(
        SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, unrelatedRoot.path, devicePrefix, now),
        throwsA(isA<RemoteFileException>()),
      );

      expect(
        File(_nativeJoin(unrelated.path, 'precious.txt')).readAsStringSync(),
        'precious',
      );
    });

    test(
      'an unrelated file-only directory is not claimed or chmodded',
      () async {
        final unrelatedRoot = Directory(_nativeJoin(scratch.path, 'file-only'));
        await unrelatedRoot.create();
        await File(
          _nativeJoin(unrelatedRoot.path, 'precious.txt'),
        ).writeAsString('precious');
        RemoteFileEntry? before;
        if (!Platform.isWindows) {
          await fs.setMode(unrelatedRoot.path, 0x1ED); // 0755
          before = await fs.stat(unrelatedRoot.path, followLinks: false);
        }

        await expectLater(
          resolveSyncTrashRoot(
            fs,
            unrelatedRoot.path,
            pathStyle: _nativeTrashPathStyle,
            access: SyncTrashRootAccess.createOrClaim,
          ),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.conflict,
            ),
          ),
        );

        if (before != null) {
          final after = await fs.stat(unrelatedRoot.path, followLinks: false);
          expect(after.mode, before.mode);
        }
        expect(
          File(
            _nativeJoin(unrelatedRoot.path, 'precious.txt'),
          ).readAsStringSync(),
          'precious',
        );
      },
    );

    test(
      'unknown directories in an owned root are never inventoried',
      () async {
        final unrelated = Directory(_nativeJoin(trashRoot, 'etc'));
        await unrelated.create();
        final precious = File(_nativeJoin(unrelated.path, 'precious.txt'));
        await precious.writeAsString('precious');

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);

        expect(inventory.runs, isEmpty);
        expect(
          inventory.select(SyncTrashPurgeScope.all, now, const {}).runIds,
          isEmpty,
        );
        expect(precious.readAsStringSync(), 'precious');
      },
    );

    test('a malformed ownership marker fails closed', () async {
      final identity = File(
        _nativeJoin(
          _nativeJoin(trashRoot, syncTrashRootMarkerName),
          'identity',
        ),
      );
      await identity.writeAsString('not-a-marker');

      await expectLater(
        SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    });

    test('malformed marker bytes fail as a typed conflict', () async {
      final identity = File(
        _nativeJoin(
          _nativeJoin(trashRoot, syncTrashRootMarkerName),
          'identity',
        ),
      );
      await identity.writeAsBytes([0xFF], flush: true);

      await expectLater(
        SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    });

    test('a root swap during inspection cannot release journals', () async {
      final runId = _runId(devicePrefix, 'inspect-root-race');
      await makeRunDir(runId);
      final journal = await writeJournal(runId);
      final movedRoot = _nativeJoin(scratch.path, 'moved-inspect-trash');
      final outsideRoot = Directory(_nativeJoin(scratch.path, 'empty-outside'));
      await outsideRoot.create();

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          _SwapBeforeTrashListFs(
            trashRoot: trashRoot,
            movedRoot: movedRoot,
            outsideRoot: outsideRoot.path,
          ),
          trashRoot,
          devicePrefix,
          now,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );

      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasUnpurgedTrash, isTrue);
      expect(reopened.hasPurgeMarker, isFalse);
    });

    test('absent run dirs mark their journals purged on the spot', () async {
      final scope = (await resolveSyncTrashRoot(
        fs,
        trashRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.openExisting,
      )).scopeKey;
      final runId = _runId(devicePrefix, 'vanished');
      final journal = await writeJournal(runId, trashScopeLeft: scope);
      expect(journal.hasUnpurgedTrash, isTrue);

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now, trashScope: scope);
      expect(inventory.runs.where((r) => r.runId == runId), isEmpty);

      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.purged, isTrue);
      expect(reopened.hasUnpurgedTrash, isFalse);
    });

    test('absent runs with incomplete restore stay recoverable', () async {
      final scope = await currentTrashScope();
      final runId = _runId(devicePrefix, 'absent-incomplete-restore');
      final journal = await writeJournal(runId, trashScopeLeft: scope);
      await appendIncompleteRestore(journal);

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now, trashScope: scope);

      expect(inventory.runs, isEmpty);
      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasUnpurgedTrash, isTrue);
      expect(reopened.hasPurgeMarker, isFalse);
    });

    test('absent unreadable restore journal is left untouched', () async {
      final scope = await currentTrashScope();
      final runId = _runId(devicePrefix, 'absent-unreadable-restore');
      final journal = await writeJournal(runId, trashScopeLeft: scope);
      await makeIncompleteRestoreJournalUnreadable(journal);
      final before = await File(journal.path).readAsString();
      final marked = <String>[];

      final inventory = await SyncTrashPurgeService(runsDir.path).inspectNative(
        fs,
        trashRoot,
        devicePrefix,
        now,
        trashScope: scope,
        onPurgedRun: marked.add,
      );

      expect(inventory.runs, isEmpty);
      expect(marked, isEmpty);
      expect(await File(journal.path).readAsString(), before);
    });

    test('cancellation stops absent-journal marking between runs', () async {
      final scope = await currentTrashScope();
      final journals = [
        await writeJournal(
          _runId(devicePrefix, 'cancel-absent-first'),
          trashScopeLeft: scope,
        ),
        await writeJournal(
          _runId(devicePrefix, 'cancel-absent-second'),
          trashScopeLeft: scope,
        ),
      ];
      bool hasMarkedJournal() => journals.any(
        (journal) => File(
          journal.path,
        ).readAsStringSync().contains('"trashScopePurged"'),
      );

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          fs,
          trashRoot,
          devicePrefix,
          now,
          trashScope: scope,
          isCancelled: hasMarkedJournal,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.cancelled,
          ),
        ),
      );

      final replayed = [
        for (final journal in journals) await SyncRunJournal.open(journal.path),
      ];
      expect(replayed.where((journal) => journal.purged), hasLength(1));
      expect(
        replayed.where((journal) => journal.hasUnpurgedTrash),
        hasLength(1),
      );
    });

    test('absent legacy lexical coverage stays retained', () async {
      final runId = _runId(devicePrefix, 'legacy-other-host');
      final journal = await writeJournal(runId);

      await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      var reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasPurgeMarker, isFalse);
      expect(reopened.hasUnpurgedTrash, isTrue);
      await SyncRunJournal.prune(runsDir.path, 'pair-1', keep: 0);
      expect(await File(journal.path).exists(), isTrue);
      reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasUnpurgedTrash, isTrue);
    });

    test('a missing trash root keeps its scoped journals', () async {
      final identity = await resolveSyncTrashRoot(
        fs,
        trashRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.openExisting,
      );
      final runId = _runId(devicePrefix, 'deleted-root');
      final journal = await writeJournal(
        runId,
        trashScopeLeft: identity.scopeKey,
      );
      await trashRootDir.delete(recursive: true);

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          fs,
          trashRoot,
          devicePrefix,
          now,
          trashScope: identity.scopeKey,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.notFound,
          ),
        ),
      );

      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.isTrashScopePurged(identity.scopeKey), isFalse);
      expect(reopened.hasUnpurgedTrash, isTrue);
    });

    test('a root restored after a missing probe keeps its journals', () async {
      final identity = await resolveSyncTrashRoot(
        fs,
        trashRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.openExisting,
      );
      final runId = _runId(devicePrefix, 'restored-root');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(
        runId,
        trashScopeLeft: identity.scopeKey,
      );
      final movedRoot = _nativeJoin(scratch.path, 'temporarily-missing-trash');
      await trashRootDir.rename(movedRoot);

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          _RestoreRootAfterMissingProbeFs(
            trashRoot: trashRoot,
            movedRoot: movedRoot,
          ),
          trashRoot,
          devicePrefix,
          now,
          trashScope: identity.scopeKey,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.notFound,
          ),
        ),
      );

      expect(Directory(runPath).existsSync(), isTrue);
      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasUnpurgedTrash, isTrue);
      expect(reopened.hasPurgeMarker, isFalse);
    });

    test('journal symlinks are ignored and never appended', () async {
      final runId = _runId(devicePrefix, 'linked-journal');
      final outsideRuns = Directory(_nativeJoin(scratch.path, 'outside-runs'));
      await outsideRuns.create();
      final journal = await SyncRunJournal.create(
        outsideRuns.path,
        record(runId),
      );
      await journal.appendTrash(
        SyncJournalTrashLine(
          parentPath: 'a.txt',
          relativePath: 'a.txt',
          side: SyncSide.left,
          trashLocation: _nativeJoin(
            _nativeJoin(trashRoot, runId),
            '000001-a.txt',
          ),
          bytes: 3,
        ),
      );
      final before = await File(journal.path).readAsString();
      await Link(
        _nativeJoin(runsDir.path, _nativeBasename(journal.path)),
      ).create(journal.path);

      await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      expect(await File(journal.path).readAsString(), before);
      expect((await SyncRunJournal.open(journal.path)).hasPurgeMarker, isFalse);
    }, skip: Platform.isWindows);

    test('an active journal is not released before its dir appears', () async {
      final runId = _runId(devicePrefix, 'active');
      final journal = await writeJournal(runId);

      await SyncTrashPurgeService(runsDir.path).inspectNative(
        fs,
        trashRoot,
        devicePrefix,
        now,
        isActiveRun: (candidate) => candidate == runId,
      );

      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.purged, isFalse);
      expect(reopened.hasUnpurgedTrash, isTrue);
    });

    test(
      'scope identity separates journals at the same textual root',
      () async {
        final firstScope = (await resolveSyncTrashRoot(
          fs,
          trashRoot,
          pathStyle: _nativeTrashPathStyle,
          access: SyncTrashRootAccess.openExisting,
        )).scopeKey;
        const secondScope = 'host-b:/trash';
        final first = await writeJournal(
          _runId(devicePrefix, 'first-host'),
          trashScopeLeft: firstScope,
        );
        final second = await writeJournal(
          _runId(devicePrefix, 'second-host'),
          trashScopeLeft: secondScope,
        );

        await SyncTrashPurgeService(runsDir.path).inspectNative(
          fs,
          trashRoot,
          devicePrefix,
          now,
          trashScope: firstScope,
        );

        expect((await SyncRunJournal.open(first.path)).purged, isTrue);
        final untouched = await SyncRunJournal.open(second.path);
        expect(untouched.hasPurgeMarker, isFalse);
        expect(untouched.hasUnpurgedTrash, isTrue);
      },
    );

    test('stable scope overrides textual root spelling', () async {
      final scope = (await resolveSyncTrashRoot(
        fs,
        trashRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.openExisting,
      )).scopeKey;
      final runId = _runId(devicePrefix, 'case-alias');
      await makeRunDir(runId);
      await writeJournal(
        runId,
        trashScopeLeft: scope,
        trashRootOverride: trashRoot.toUpperCase(),
      );

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now, trashScope: scope);

      expect(inventory.runs.single.ownership, SyncTrashOwnership.journaled);
      expect(inventory.runs.single.fileCount, 2);
    });

    test('legacy Windows paths match mixed separators and case', () async {
      const virtualRoot = r'C:\Trash';
      const rootId = '0123456789abcdef0123456789abcdef';
      final scope = const SyncTrashRootIdentity(
        canonicalRoot: virtualRoot,
        rootId: rootId,
      ).scopeKey;
      final runId = _runId(devicePrefix, 'windows-legacy');
      final journal = await SyncRunJournal.create(runsDir.path, record(runId));
      await journal.appendTrash(
        SyncJournalTrashLine(
          parentPath: 'a.txt',
          relativePath: 'a.txt',
          side: SyncSide.left,
          trashLocation: 'c:/TRASH/$runId/000001-a.txt',
          bytes: 3,
        ),
      );

      final inventory = await SyncTrashPurgeService(runsDir.path).inspectNative(
        _VirtualWindowsTrashFs(root: virtualRoot, runId: runId, rootId: rootId),
        virtualRoot,
        devicePrefix,
        now,
        trashScope: scope,
        pathStyle: SyncTrashPathStyle.windows,
        pathCase: SyncTrashPathCase.insensitive,
      );

      expect(inventory.runs.single.ownership, SyncTrashOwnership.journaled);
      expect(inventory.runs.single.fileCount, 1);
    });

    test(
      'service releases one scope at a time in a two-root journal',
      () async {
        final leftScope = (await resolveSyncTrashRoot(
          fs,
          trashRoot,
          pathStyle: _nativeTrashPathStyle,
          access: SyncTrashRootAccess.openExisting,
        )).scopeKey;
        final rightRoot = _nativeJoin(scratch.path, 'right-trash');
        final rightScope = (await resolveSyncTrashRoot(
          fs,
          rightRoot,
          pathStyle: _nativeTrashPathStyle,
          access: SyncTrashRootAccess.createOrClaim,
        )).scopeKey;
        final runId = _runId(devicePrefix, 'two-roots');
        final journal = await SyncRunJournal.create(
          runsDir.path,
          SyncRunRecord(
            runId: runId,
            pairId: 'pair-1',
            startedAt: now,
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
          SyncJournalTrashLine(
            parentPath: 'left.txt',
            relativePath: 'left.txt',
            side: SyncSide.left,
            trashLocation: _nativeJoin(
              _nativeJoin(trashRoot, runId),
              '000001-left.txt',
            ),
            bytes: 1,
          ),
        );
        await journal.appendTrash(
          SyncJournalTrashLine(
            parentPath: 'right.txt',
            relativePath: 'right.txt',
            side: SyncSide.right,
            trashLocation: _nativeJoin(
              _nativeJoin(rightRoot, runId),
              '000002-right.txt',
            ),
            bytes: 1,
          ),
        );
        final service = SyncTrashPurgeService(runsDir.path);

        await service.inspectNative(
          fs,
          trashRoot,
          devicePrefix,
          now,
          trashScope: leftScope,
        );

        var reopened = await SyncRunJournal.open(journal.path);
        expect(reopened.isTrashScopePurged(leftScope), isTrue);
        expect(reopened.isTrashScopePurged(rightScope), isFalse);
        expect(reopened.purged, isFalse);
        expect(reopened.hasUnpurgedTrash, isTrue);

        await service.inspectNative(
          fs,
          rightRoot,
          devicePrefix,
          now,
          trashScope: rightScope,
        );

        reopened = await SyncRunJournal.open(journal.path);
        expect(reopened.purged, isTrue);
        expect(reopened.hasUnpurgedTrash, isFalse);
      },
    );
  });

  group('select and cache', () {
    test('exactly 30 days old is not older than retention', () async {
      final runId = _runId(devicePrefix, 'retention-boundary');
      await makeRunDir(runId);
      final agedFs = _AgedDirFs()
        ..dirMtime[runId] = now.subtract(syncTrashRetention);

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(agedFs, trashRoot, devicePrefix, now);

      expect(
        inventory.select(SyncTrashPurgeScope.aged, now, const {}).runIds,
        isEmpty,
      );
    });

    test('incomplete restore is not selectable for either purge', () async {
      final runId = _runId(devicePrefix, 'incomplete-restore-selection');
      await makeRunDir(runId);
      final journal = await writeJournal(
        runId,
        startedAt: now.subtract(const Duration(days: 31)),
        trashScopeLeft: await currentTrashScope(),
      );
      await appendIncompleteRestore(journal);

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      expect(
        inventory.select(SyncTrashPurgeScope.aged, now, const {}).runIds,
        isEmpty,
      );
      expect(
        inventory.select(SyncTrashPurgeScope.all, now, const {}).runIds,
        isEmpty,
      );
    });

    test(
      'unreadable restore journal protects its run but corruption does not',
      () async {
        final old = now.subtract(const Duration(days: 31));
        final protectedRun = _runId(devicePrefix, 'unreadable-selection');
        final corruptRun = _runId(devicePrefix, 'ordinary-corruption');
        await makeRunDir(protectedRun);
        await makeRunDir(corruptRun);
        final protectedJournal = await writeJournal(
          protectedRun,
          trashScopeLeft: await currentTrashScope(),
        );
        await makeIncompleteRestoreJournalUnreadable(protectedJournal);
        await File(
          _nativeJoin(runsDir.path, '$corruptRun$_journalFileSuffix'),
        ).writeAsString('ordinary corruption');
        final agedFs = _AgedDirFs()
          ..dirMtime[protectedRun] = old
          ..dirMtime[corruptRun] = old;

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(agedFs, trashRoot, devicePrefix, now);

        expect(
          inventory.select(SyncTrashPurgeScope.aged, now, const {}).runIds,
          [corruptRun],
        );
        expect(
          inventory.select(SyncTrashPurgeScope.all, now, const {}).runIds,
          [corruptRun],
        );
      },
    );

    test(
      'aged takes old journaled/orphan/rsync, never foreign/active',
      () async {
        final old = now.subtract(const Duration(days: 31));
        final journaledId = _runId(devicePrefix, 'old-journaled');
        await makeRunDir(journaledId);
        await writeJournal(journaledId, startedAt: old);
        final orphanId = _runId(devicePrefix, 'old-orphan');
        await makeRunDir(orphanId);
        await makeRunDir('rsync-20240101-120000');
        final foreignId = _runId('ffffffff', 'old-foreign');
        await makeRunDir(foreignId);
        final activeId = _runId(devicePrefix, 'old-active');
        await makeRunDir(activeId);
        final youngId = _runId(devicePrefix, 'young');
        await makeRunDir(youngId);
        final agedFs = _AgedDirFs()
          ..dirMtime[orphanId] = old
          ..dirMtime['rsync-20240101-120000'] = old
          ..dirMtime[foreignId] = old
          ..dirMtime[activeId] = old;

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(agedFs, trashRoot, devicePrefix, now);
        final aged = inventory.select(SyncTrashPurgeScope.aged, now, {
          activeId,
        });

        expect(
          aged.runIds,
          unorderedEquals([journaledId, orphanId, 'rsync-20240101-120000']),
        );
        expect(aged.runIds, isNot(contains(foreignId)));
        expect(aged.runIds, isNot(contains(activeId)));
        expect(aged.runIds, isNot(contains(youngId)));
        // The journaled run contributes its two deduped files; the two
        // journal-less runs contribute unjournaled count only.
        expect(aged.knownFileCount, 2);
        expect(aged.unjournaledRunCount, 2);
        expect(aged.pairIds, {'pair-1'});
        expect(aged.foreignRunCount, 0);
      },
    );

    test(
      'all takes every run dir except active ids, foreign included',
      () async {
        final old = now.subtract(const Duration(days: 31));
        final first = _runId(devicePrefix, 'all-a');
        final foreign = _runId('ffffffff', 'all-b');
        final young = _runId(devicePrefix, 'all-young');
        await makeRunDir(first);
        await makeRunDir(foreign);
        await makeRunDir(young);
        final activeId = _runId(devicePrefix, 'all-active');
        await makeRunDir(activeId);
        final agedFs = _AgedDirFs()
          ..dirMtime[first] = old
          ..dirMtime[foreign] = old
          ..dirMtime[activeId] = old;

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(agedFs, trashRoot, devicePrefix, now);
        final all = inventory.select(SyncTrashPurgeScope.all, now, {activeId});
        expect(all.runIds, unorderedEquals([first, foreign, young]));
        expect(all.foreignRunCount, 1);
        expect(all.unjournaledRunCount, 3);
        expect(all.knownFileCount, 0);
      },
    );

    test(
      'cache holds every observed directory; journal-less counts null',
      () async {
        final runId = _runId(devicePrefix, 'cached');
        await makeRunDir(runId);
        await writeJournal(runId);
        final foreign = _runId('ffffffff', 'cached-foreign');
        await makeRunDir(foreign);

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);
        final cache = inventory.toCache();

        expect(
          cache.runs.map((r) => r.runId),
          unorderedEquals([runId, foreign]),
        );
        expect(cache.runs.singleWhere((r) => r.runId == runId).fileCount, 2);
        expect(
          cache.runs.singleWhere((r) => r.runId == foreign).fileCount,
          isNull,
        );
      },
    );
  });

  group('purge', () {
    test(
      'inspect recovers a purge quarantine before marking journals',
      () async {
        final runId = _runId(devicePrefix, 'crash-recovery');
        final runPath = await makeRunDir(runId);
        final journal = await writeJournal(runId);
        const suffix = '0123456789abcdef01234567';
        final quarantinedPath = '$runPath.purging-$devicePrefix-$suffix';
        await fs.rename(runPath, quarantinedPath);

        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);

        expect(inventory.runs.single.runId, runId);
        expect(Directory(runPath).existsSync(), isTrue);
        expect(Directory(quarantinedPath).existsSync(), isFalse);
        expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
      },
    );

    test('inspect refuses a quarantine replaced by a symlink', () async {
      final runId = _runId(devicePrefix, 'recovery-link-race');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      const suffix = '0123456789abcdef01234567';
      final quarantinePath = '$runPath.purging-$devicePrefix-$suffix';
      await fs.rename(runPath, quarantinePath);
      final outside = Directory(_nativeJoin(scratch.path, 'recovery-outside'))
        ..createSync();
      final precious = File(_nativeJoin(outside.path, 'precious.txt'))
        ..writeAsStringSync('precious');

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          _SwapRecoverySourceForSymlinkFs(
            quarantinePath: quarantinePath,
            outsidePath: outside.path,
          ),
          trashRoot,
          devicePrefix,
          now,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );

      expect(precious.readAsStringSync(), 'precious');
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    }, skip: Platform.isWindows);

    test('inspect stops recovery after a root replacement', () async {
      final runId = _runId(devicePrefix, 'recovery-root-race');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      const suffix = '0123456789abcdef01234567';
      final quarantineName = '$runId.purging-$devicePrefix-$suffix';
      final quarantinePath = _nativeJoin(trashRoot, quarantineName);
      await fs.rename(runPath, quarantinePath);
      final movedRoot = _nativeJoin(scratch.path, 'moved-recovery-trash');
      final replacementRoot = _nativeJoin(
        scratch.path,
        'replacement-recovery-trash',
      );
      await resolveSyncTrashRoot(
        fs,
        replacementRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final replacementQuarantine = Directory(
        _nativeJoin(replacementRoot, quarantineName),
      )..createSync();
      File(
        _nativeJoin(replacementQuarantine.path, 'precious.txt'),
      ).writeAsStringSync('precious');

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          _ReplaceRootBeforeRecoveryFs(
            trashRoot: trashRoot,
            movedRoot: movedRoot,
            replacementRoot: replacementRoot,
            quarantinePath: quarantinePath,
          ),
          trashRoot,
          devicePrefix,
          now,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );

      expect(
        File(_nativeJoin(runPath, 'precious.txt')).readAsStringSync(),
        'precious',
      );
      expect(Directory(quarantinePath).existsSync(), isFalse);
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test('recovery never rolls back through a replacement root', () async {
      final runId = _runId(devicePrefix, 'recovery-post-rename-race');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      const suffix = '0123456789abcdef01234567';
      final quarantineName = '$runId.purging-$devicePrefix-$suffix';
      final quarantinePath = _nativeJoin(trashRoot, quarantineName);
      final originalPath = _nativeJoin(trashRoot, runId);
      await fs.rename(runPath, quarantinePath);
      final movedRoot = _nativeJoin(scratch.path, 'moved-post-recovery-trash');
      final replacementRoot = _nativeJoin(
        scratch.path,
        'replacement-post-recovery-trash',
      );
      await resolveSyncTrashRoot(
        fs,
        replacementRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final replacementOriginal = Directory(_nativeJoin(replacementRoot, runId))
        ..createSync();
      File(
        _nativeJoin(replacementOriginal.path, 'precious.txt'),
      ).writeAsStringSync('precious');

      await expectLater(
        SyncTrashPurgeService(runsDir.path).inspectNative(
          _ReplaceRootAfterRecoveryFs(
            trashRoot: trashRoot,
            movedRoot: movedRoot,
            replacementRoot: replacementRoot,
            quarantinePath: quarantinePath,
            originalPath: originalPath,
          ),
          trashRoot,
          devicePrefix,
          now,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );

      expect(
        File(_nativeJoin(originalPath, 'precious.txt')).readAsStringSync(),
        'precious',
      );
      expect(Directory(originalPath).existsSync(), isTrue);
      expect(
        Directory(_nativeJoin(trashRoot, quarantineName)).existsSync(),
        isFalse,
      );
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test('another device cannot recover an in-flight quarantine', () async {
      final runId = _runId(devicePrefix, 'owned-quarantine');
      final runPath = await makeRunDir(runId);
      final service = SyncTrashPurgeService(runsDir.path);
      final inventory = await service.inspectNative(
        fs,
        trashRoot,
        devicePrefix,
        now,
      );
      final interleaved = _InspectAfterQuarantineFs(
        onQuarantined: () => service.inspectNative(
          fs,
          trashRoot,
          syncRunDevicePrefix('other-device'),
          now,
        ),
      );

      final report = await service.purge(
        interleaved,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [runId]);
      expect(Directory(runPath).existsSync(), isFalse);
    });

    test('explicit purge removes a dead foreign quarantine', () async {
      final runId = _runId(devicePrefix, 'foreign-quarantine');
      final runPath = await makeRunDir(runId);
      final foreignPrefix = syncRunDevicePrefix('other-device');
      const suffix = '0123456789abcdef01234567';
      final quarantinedPath = '$runPath.purging-$foreignPrefix-$suffix';
      await fs.rename(runPath, quarantinedPath);

      final service = SyncTrashPurgeService(runsDir.path);
      final inventory = await service.inspectNative(
        fs,
        trashRoot,
        devicePrefix,
        now,
      );
      expect(
        inventory.select(SyncTrashPurgeScope.aged, now, const {}).runIds,
        isEmpty,
      );
      final selection = inventory.select(
        SyncTrashPurgeScope.all,
        now,
        const {},
      );
      expect(selection.runIds, [runId]);

      final report = await service.purge(fs, selection, const {});

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [runId]);
      expect(Directory(quarantinedPath).existsSync(), isFalse);
    });

    test('deletes only selected dirs, recursively, keeping the rest', () async {
      final doomed = _runId(devicePrefix, 'doomed');
      final doomedPath = await makeRunDir(doomed);
      await Directory(
        _nativeJoin(doomedPath, 'nested/deep'),
      ).create(recursive: true);
      await File(
        _nativeJoin(doomedPath, 'nested/deep/file.txt'),
      ).writeAsString('deep');
      final kept = _runId(devicePrefix, 'kept');
      await makeRunDir(kept);
      await File(_nativeJoin(trashRoot, 'stray.txt')).writeAsString('stray');

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final selection = inventory.select(
        SyncTrashPurgeScope.all,
        now,
        const {},
      );
      final doomedOnly = SyncTrashSelection(
        trashRoot: selection.trashRoot,
        canonicalRoot: selection.canonicalRoot,
        rootId: selection.rootId,
        trashScope: selection.trashScope,
        devicePrefix: selection.devicePrefix,
        pathStyle: selection.pathStyle,
        pathCase: selection.pathCase,
        runIds: [doomed],
        knownFileCount: selection.knownFileCount,
        unjournaledRunCount: 1,
        pairIds: const {},
        foreignRunCount: 0,
      );
      final report = await SyncTrashPurgeService(
        runsDir.path,
      ).purge(fs, doomedOnly, const {});

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [doomed]);
      expect(Directory(doomedPath).existsSync(), isFalse);
      expect(Directory(_nativeJoin(trashRoot, kept)).existsSync(), isTrue);
      expect(trashRootDir.existsSync(), isTrue);
      expect(File(_nativeJoin(trashRoot, 'stray.txt')).existsSync(), isTrue);
      expect(
        Directory(_nativeJoin(trashRoot, syncTrashRootMarkerName)).existsSync(),
        isTrue,
      );
    });

    test('a changed ownership marker invalidates a selection', () async {
      final runId = _runId(devicePrefix, 'changed-marker');
      final runPath = await makeRunDir(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final replacementRoot = _nativeJoin(scratch.path, 'replacement-marker');
      await resolveSyncTrashRoot(
        fs,
        replacementRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      await File(
        _nativeJoin(replacementRoot, '$syncTrashRootMarkerName/identity'),
      ).copy(_nativeJoin(trashRoot, '$syncTrashRootMarkerName/identity'));

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures, isNotEmpty);
      expect(Directory(runPath).existsSync(), isTrue);
    });

    test('a root replacement during quarantine is never purged', () async {
      final runId = _runId(devicePrefix, 'root-swap-at-quarantine');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final movedRoot = _nativeJoin(scratch.path, 'moved-trash');
      final replacementRoot = _nativeJoin(scratch.path, 'replacement-trash');
      await resolveSyncTrashRoot(
        fs,
        replacementRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final replacementRun = Directory(_nativeJoin(replacementRoot, runId));
      await replacementRun.create();
      await File(
        _nativeJoin(replacementRun.path, 'precious.txt'),
      ).writeAsString('precious');

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _ReplaceRootBeforeRunQuarantineFs(
          trashRoot: trashRoot,
          movedRoot: movedRoot,
          replacementRoot: replacementRoot,
          runPath: runPath,
        ),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.runId, runId);
      final replacementQuarantines = Directory(trashRoot)
          .listSync()
          .whereType<Directory>()
          .where(
            (entry) =>
                _nativeBasename(entry.path).startsWith('$runId.purging-'),
          )
          .toList();
      expect(replacementQuarantines, hasLength(1));
      expect(
        File(
          _nativeJoin(replacementQuarantines.single.path, 'precious.txt'),
        ).readAsStringSync(),
        'precious',
      );
      expect(Directory(runPath).existsSync(), isFalse);
      expect(Directory(_nativeJoin(movedRoot, runId)).existsSync(), isTrue);
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test('rollback never renames through a replacement root', () async {
      final runId = _runId(devicePrefix, 'root-swap-before-rollback');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final movedRoot = _nativeJoin(scratch.path, 'moved-rollback-trash');
      final replacementRoot = _nativeJoin(
        scratch.path,
        'replacement-rollback-trash',
      );
      await resolveSyncTrashRoot(
        fs,
        replacementRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final replacing = _ReplaceRootAfterRunQuarantineFs(
        trashRoot: trashRoot,
        movedRoot: movedRoot,
        replacementRoot: replacementRoot,
        runPath: runPath,
      );

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        replacing,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      final quarantineName = replacing.quarantineName!;
      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.runId, runId);
      expect(
        File(
          _nativeJoin(trashRoot, '$quarantineName/precious.txt'),
        ).readAsStringSync(),
        'precious',
      );
      expect(Directory(_nativeJoin(trashRoot, runId)).existsSync(), isFalse);
      expect(
        Directory(_nativeJoin(movedRoot, quarantineName)).existsSync(),
        isTrue,
      );
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test('skips active ids and never touches newly appeared dirs', () async {
      final activeId = _runId(devicePrefix, 'live');
      await makeRunDir(activeId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      // Appears after the inspection — purge must not learn about it
      // through its own re-listing.
      final newcomer = _runId(devicePrefix, 'newcomer');
      await makeRunDir(newcomer);

      final selection = inventory.select(
        SyncTrashPurgeScope.all,
        now,
        const {},
      );
      expect(selection.runIds, contains(activeId));
      final report = await SyncTrashPurgeService(
        runsDir.path,
      ).purge(fs, selection, {activeId});

      expect(Directory(_nativeJoin(trashRoot, activeId)).existsSync(), isTrue);
      expect(Directory(_nativeJoin(trashRoot, newcomer)).existsSync(), isTrue);
      expect(report.purgedRunIds, isNot(contains(activeId)));
      expect(report.failures, isEmpty);
    });

    test('marks journals only after their run dir is gone', () async {
      final runId = _runId(devicePrefix, 'mark-me');
      await makeRunDir(runId);
      final journal = await writeJournal(
        runId,
        trashScopeLeft: await currentTrashScope(),
      );

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, contains(runId));
      expect(await SyncRunJournal.open(journal.path), isA<SyncRunJournal>());
      expect((await SyncRunJournal.open(journal.path)).purged, isTrue);
    });

    test('stale selection refuses newly incomplete restore only', () async {
      final scope = await currentTrashScope();
      final protectedRun = _runId(devicePrefix, 'stale-restore-protected');
      final purgeableRun = _runId(devicePrefix, 'stale-restore-purgeable');
      final protectedPath = await makeRunDir(protectedRun);
      final purgeablePath = await makeRunDir(purgeableRun);
      final protectedJournal = await writeJournal(
        protectedRun,
        trashScopeLeft: scope,
      );
      final purgeableJournal = await writeJournal(
        purgeableRun,
        trashScopeLeft: scope,
      );
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now, trashScope: scope);
      final selection = inventory.select(
        SyncTrashPurgeScope.all,
        now,
        const {},
      );
      await appendIncompleteRestore(protectedJournal);

      final report = await SyncTrashPurgeService(
        runsDir.path,
      ).purge(fs, selection, const {});

      expect(report.purgedRunIds, [purgeableRun]);
      expect(
        report.failures,
        contains(
          isA<SyncTrashPurgeFailure>()
              .having((failure) => failure.runId, 'runId', protectedRun)
              .having(
                (failure) => failure.message,
                'message',
                contains('restore recovery is pending'),
              ),
        ),
      );
      expect(Directory(protectedPath).existsSync(), isTrue);
      expect(Directory(purgeablePath).existsSync(), isFalse);
      expect(
        (await SyncRunJournal.open(protectedJournal.path)).hasPurgeMarker,
        isFalse,
      );
      expect((await SyncRunJournal.open(purgeableJournal.path)).purged, isTrue);
    });

    test('stale selection refuses unreadable restore journal only', () async {
      final scope = await currentTrashScope();
      final protectedRun = _runId(devicePrefix, 'stale-unreadable-protected');
      final purgeableRun = _runId(devicePrefix, 'stale-unreadable-purgeable');
      final protectedPath = await makeRunDir(protectedRun);
      final purgeablePath = await makeRunDir(purgeableRun);
      final protectedJournal = await writeJournal(
        protectedRun,
        trashScopeLeft: scope,
      );
      final purgeableJournal = await writeJournal(
        purgeableRun,
        trashScopeLeft: scope,
      );
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now, trashScope: scope);
      final selection = inventory.select(
        SyncTrashPurgeScope.all,
        now,
        const {},
      );
      await makeIncompleteRestoreJournalUnreadable(protectedJournal);

      final report = await SyncTrashPurgeService(
        runsDir.path,
      ).purge(fs, selection, const {});

      expect(report.purgedRunIds, [purgeableRun]);
      expect(
        report.failures,
        contains(
          isA<SyncTrashPurgeFailure>()
              .having((failure) => failure.runId, 'runId', protectedRun)
              .having(
                (failure) => failure.message,
                'message',
                contains('restore recovery is pending'),
              ),
        ),
      );
      expect(Directory(protectedPath).existsSync(), isTrue);
      expect(Directory(purgeablePath).existsSync(), isFalse);
      expect(
        await File(protectedJournal.path).readAsString(),
        isNot(contains('"trashScopePurged"')),
      );
      expect((await SyncRunJournal.open(purgeableJournal.path)).purged, isTrue);
    });

    test(
      'legacy explicit purge removes files but retains its journal',
      () async {
        final runId = _runId(devicePrefix, 'legacy-explicit-purge');
        final runPath = await makeRunDir(runId);
        final journal = await writeJournal(runId);
        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);

        final report = await SyncTrashPurgeService(runsDir.path).purge(
          fs,
          inventory.select(SyncTrashPurgeScope.all, now, const {}),
          const {},
        );

        expect(report.purgedRunIds, [runId]);
        expect(Directory(runPath).existsSync(), isFalse);
        final reopened = await SyncRunJournal.open(journal.path);
        expect(reopened.hasPurgeMarker, isFalse);
        expect(reopened.hasUnpurgedTrash, isTrue);
      },
    );

    test('reports a selected run id replaced by a non-directory', () async {
      final runId = _runId(devicePrefix, 'replaced');
      final runPath = await makeRunDir(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      await Directory(runPath).delete(recursive: true);
      await File(runPath).writeAsString('replacement');

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.runId, runId);
      expect(File(runPath).existsSync(), isTrue);
    });

    test('a run vanishing after the live listing is already purged', () async {
      final runId = _runId(devicePrefix, 'vanishing');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(
        runId,
        trashScopeLeft: await currentTrashScope(),
      );
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final vanishing = _VanishAfterRootListFs(trashRoot, runPath);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        vanishing,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [runId]);
      expect((await SyncRunJournal.open(journal.path)).purged, isTrue);
    });

    test('derives child paths instead of trusting listing metadata', () async {
      final runId = _runId(devicePrefix, 'poisoned');
      final runPath = await makeRunDir(runId);
      await File(_nativeJoin(runPath, '000001-a.txt')).delete();
      final inside = File(_nativeJoin(runPath, 'inside.txt'));
      await inside.writeAsString('old');
      final outside = File(_nativeJoin(scratch.path, 'outside.txt'));
      await outside.writeAsString('precious');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _PoisonedChildPathFs(runPath, outside.path),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(Directory(runPath).existsSync(), isFalse);
      expect(outside.readAsStringSync(), 'precious');
    });

    test('derives delete paths instead of trusting stat metadata', () async {
      final runId = _runId(devicePrefix, 'poisoned-stat');
      final runPath = await makeRunDir(runId);
      final inside = File(_nativeJoin(runPath, '000001-a.txt'));
      final outside = File(_nativeJoin(scratch.path, 'outside.txt'));
      await outside.writeAsString('precious');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _PoisonedStatPathFs(inside.path, outside.path),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(Directory(runPath).existsSync(), isFalse);
      expect(outside.readAsStringSync(), 'precious');
    });

    test(
      'records per-run failures and keeps the failed journal unmarked',
      () async {
        final badRun = _runId(devicePrefix, 'bad');
        final badPath = await makeRunDir(badRun);
        // The failure trigger lives inside the bad run only.
        await File(_nativeJoin(badPath, 'poison.txt')).writeAsString('poison');
        final goodRun = _runId(devicePrefix, 'good');
        await makeRunDir(goodRun);
        final badJournal = await writeJournal(badRun);
        await writeJournal(goodRun);

        final failingFs = _FailingDeleteFs('poison.txt');
        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(failingFs, trashRoot, devicePrefix, now);
        final report = await SyncTrashPurgeService(runsDir.path).purge(
          failingFs,
          inventory.select(SyncTrashPurgeScope.all, now, const {}),
          const {},
        );

        expect(report.purgedRunIds, contains(goodRun));
        expect(report.purgedRunIds, isNot(contains(badRun)));
        expect(report.failures, hasLength(1));
        expect(report.failures.single.runId, badRun);
        expect(report.failures.single.message, isNotEmpty);
        // The failed run's undo source survives; the good one releases.
        expect((await SyncRunJournal.open(badJournal.path)).purged, isFalse);
        expect(Directory(badPath).existsSync(), isTrue);
        expect(
          Directory(_nativeJoin(trashRoot, goodRun)).existsSync(),
          isFalse,
        );
      },
    );

    test('never follows symlinks out of the run dir', () async {
      final runId = _runId(devicePrefix, 'links');
      final runPath = await makeRunDir(runId);
      final outside = File(_nativeJoin(scratch.path, 'outside.txt'));
      await outside.writeAsString('precious');
      await Link(_nativeJoin(runPath, 'evil')).create(outside.path);

      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(Directory(runPath).existsSync(), isFalse);
      expect(outside.existsSync(), isTrue);
      expect(await outside.readAsString(), 'precious');
    });

    test('POSIX backslashes are valid entry names', () async {
      final runId = _runId(devicePrefix, 'backslash');
      final runPath = await makeRunDir(runId);
      await File(_nativeJoin(runPath, r'a\b')).writeAsString('inside');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [runId]);
      expect(Directory(runPath).existsSync(), isFalse);
    }, skip: Platform.isWindows);

    test('purges a maximum-length nested directory name', () async {
      final runId = _runId(devicePrefix, 'max-name');
      final runPath = await makeRunDir(runId);
      final nestedName = 'n' * 255;
      final nested = Directory(_nativeJoin(runPath, nestedName));
      await nested.create();
      await File(
        _nativeJoin(nested.path, 'inside.txt'),
      ).writeAsString('inside');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [runId]);
      expect(Directory(runPath).existsSync(), isFalse);
    });

    test('a swapped trash root cannot redirect a purge', () async {
      final runId = _runId(devicePrefix, 'root-race');
      await makeRunDir(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final movedRoot = _nativeJoin(scratch.path, 'moved-trash');
      final outsideRoot = Directory(_nativeJoin(scratch.path, 'outside-root'));
      final outsideRun = Directory(_nativeJoin(outsideRoot.path, runId));
      await outsideRun.create(recursive: true);
      final precious = File(_nativeJoin(outsideRun.path, 'precious.txt'));
      await precious.writeAsString('precious');

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _SwapTrashRootForSymlinkFs(
          trashRoot: trashRoot,
          movedRoot: movedRoot,
          outsideRoot: outsideRoot.path,
        ),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures, isNotEmpty);
      expect(precious.readAsStringSync(), 'precious');
    });

    test(
      'an empty replacement root cannot release selected journals',
      () async {
        final runId = _runId(devicePrefix, 'empty-root-race');
        final runPath = await makeRunDir(runId);
        final journal = await writeJournal(runId);
        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);
        final movedRoot = _nativeJoin(scratch.path, 'moved-empty-race');

        final report = await SyncTrashPurgeService(runsDir.path).purge(
          _ReplaceRootWithEmptyOwnedRootFs(
            trashRoot: trashRoot,
            movedRoot: movedRoot,
          ),
          inventory.select(SyncTrashPurgeScope.all, now, const {}),
          const {},
        );

        expect(report.purgedRunIds, isEmpty);
        expect(report.failures.single.runId, runId);
        expect(Directory(_nativeJoin(movedRoot, runId)).existsSync(), isTrue);
        expect(Directory(runPath).existsSync(), isFalse);
        expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
      },
    );

    test('a newly quarantined run is not treated as absent', () async {
      final runId = _runId(devicePrefix, 'quarantine-race');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final otherPrefix = syncRunDevicePrefix('other-device');
      final quarantine =
          '$runPath.purging-$otherPrefix-'
          '0123456789abcdef01234567';

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _RenameBeforeTrashListFs(
          trashRoot: trashRoot,
          oldPath: runPath,
          newPath: quarantine,
        ),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.runId, runId);
      expect(Directory(quarantine).existsSync(), isTrue);
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test('a recovered foreign quarantine is not treated as absent', () async {
      final runId = _runId(devicePrefix, 'foreign-recovery-race');
      final runPath = await makeRunDir(runId);
      final journal = await writeJournal(runId);
      final foreignPrefix = syncRunDevicePrefix('other-device');
      final quarantine =
          '$runPath.purging-$foreignPrefix-'
          '0123456789abcdef01234567';
      await fs.rename(runPath, quarantine);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _RenameBeforeTrashListFs(
          trashRoot: trashRoot,
          oldPath: quarantine,
          newPath: runPath,
        ),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.runId, runId);
      expect(Directory(runPath).existsSync(), isTrue);
      expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
    });

    test(
      'a quarantine recovered before reservation stays restorable',
      () async {
        final runId = _runId(devicePrefix, 'late-foreign-recovery');
        final runPath = await makeRunDir(runId);
        final journal = await writeJournal(runId);
        final foreignPrefix = syncRunDevicePrefix('other-device');
        final quarantine =
            '$runPath.purging-$foreignPrefix-'
            '0123456789abcdef01234567';
        await fs.rename(runPath, quarantine);
        final inventory = await SyncTrashPurgeService(
          runsDir.path,
        ).inspectNative(fs, trashRoot, devicePrefix, now);

        final report = await SyncTrashPurgeService(runsDir.path).purge(
          _RecoverBeforeReservationFs(
            quarantinePath: quarantine,
            runPath: runPath,
          ),
          inventory.select(SyncTrashPurgeScope.all, now, const {}),
          const {},
        );

        expect(report.purgedRunIds, isEmpty);
        expect(report.failures.single.runId, runId);
        expect(Directory(runPath).existsSync(), isTrue);
        expect((await SyncRunJournal.open(journal.path)).purged, isFalse);
      },
    );

    test('a run swapped to a symlink before traversal cannot escape', () async {
      final runId = _runId(devicePrefix, 'raced-link');
      final runPath = await makeRunDir(runId);
      final outside = Directory(_nativeJoin(scratch.path, 'outside'))
        ..createSync();
      final precious = File(_nativeJoin(outside.path, 'precious.txt'))
        ..writeAsStringSync('precious');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _SwapRunForSymlinkFs(runPath, outside.path),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.runId, runId);
      expect(precious.readAsStringSync(), 'precious');
    });

    test('a nested directory swapped before listing cannot escape', () async {
      final runId = _runId(devicePrefix, 'raced-nested-link');
      final runPath = await makeRunDir(runId);
      const nestedName = 'nested';
      final nested = Directory(_nativeJoin(runPath, nestedName));
      await nested.create();
      await File(
        _nativeJoin(nested.path, 'inside.txt'),
      ).writeAsString('inside');
      final outside = Directory(_nativeJoin(scratch.path, 'outside-nested'))
        ..createSync();
      final precious = File(_nativeJoin(outside.path, 'precious.txt'))
        ..writeAsStringSync('precious');
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _SwapNestedForSymlinkFs(nestedName, outside.path),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
      );

      expect(report.failures, isEmpty);
      expect(report.purgedRunIds, [runId]);
      expect(precious.readAsStringSync(), 'precious');
    });

    test('cancelled purge reports the public cancelled error', () async {
      final runId = _runId(devicePrefix, 'cancelled');
      await makeRunDir(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final cancellation = RemoteTransferCancellation()..cancel();

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        fs,
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
        cancellation,
      );
      expect(report.purgedRunIds, isEmpty);
      expect(Directory(_nativeJoin(trashRoot, runId)).existsSync(), isTrue);
    });

    test('cancellation stops before journal coverage is read', () async {
      final runId = _runId(devicePrefix, 'cancel-before-coverage');
      await makeRunDir(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final invalidRunsPath = _nativeJoin(scratch.path, 'runs-file');
      await File(invalidRunsPath).writeAsString('not a directory');
      final cancellation = RemoteTransferCancellation();

      final report = await SyncTrashPurgeService(invalidRunsPath).purge(
        _CancelAfterRootListFs(trashRoot, cancellation),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
        cancellation,
      );

      expect(report.cancelled, isTrue);
      expect(report.purgedRunIds, isEmpty);
      expect(Directory(_nativeJoin(trashRoot, runId)).existsSync(), isTrue);
    });

    test('cancellation reports a failed quarantine rollback', () async {
      final runId = _runId(devicePrefix, 'cancelled-rollback');
      final runPath = await makeRunDir(runId);
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final cancellation = RemoteTransferCancellation();

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _CancelWithRollbackFailureFs(runPath, cancellation),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
        cancellation,
      );

      expect(report.cancelled, isTrue);
      expect(report.purgedRunIds, isEmpty);
      expect(report.failures.single.message, contains('rollback denied'));
    });

    test('cancellation after one run keeps completed purge markers', () async {
      final firstRun = _runId(devicePrefix, 'a-cancel-after');
      final secondRun = _runId(devicePrefix, 'b-cancel-after');
      await makeRunDir(firstRun);
      await makeRunDir(secondRun);
      final scope = await currentTrashScope();
      final firstJournal = await writeJournal(firstRun, trashScopeLeft: scope);
      final secondJournal = await writeJournal(
        secondRun,
        trashScopeLeft: scope,
      );
      final inventory = await SyncTrashPurgeService(
        runsDir.path,
      ).inspectNative(fs, trashRoot, devicePrefix, now);
      final cancellation = RemoteTransferCancellation();

      final report = await SyncTrashPurgeService(runsDir.path).purge(
        _CancelAfterRunDeleteFs(firstRun, cancellation),
        inventory.select(SyncTrashPurgeScope.all, now, const {}),
        const {},
        cancellation,
      );

      expect(report.purgedRunIds, [firstRun]);
      expect(Directory(_nativeJoin(trashRoot, firstRun)).existsSync(), isFalse);
      expect((await SyncRunJournal.open(firstJournal.path)).purged, isTrue);
      expect(Directory(_nativeJoin(trashRoot, secondRun)).existsSync(), isTrue);
      expect((await SyncRunJournal.open(secondJournal.path)).purged, isFalse);
    });
  });
}
