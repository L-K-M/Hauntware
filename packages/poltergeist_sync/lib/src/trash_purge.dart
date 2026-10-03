// The trash purge (05 §8 rail 5): the pure-package half of the purge
// story. `inspect` reads the bounded ownership marker, one non-recursive
// trash-root listing, and local JSONL journals; `select` is a pure
// aging/scope filter; `purge` deletes exactly the selected run directories.
// The app layer owns the notice chip, the confirm dialog, and the
// `sync.purgeTrash` command; this file is the engine behavior those
// surfaces depend on.
//
// Safety shape, per the rail: trash is never reclaimed as a side effect
// (only these entry points remove it), a purge acts on a live listing
// never a cache, journal-backed trash ages by its run's `startedAt`,
// journal-less trash ages by its directory mtime, foreign-prefix runs
// are invisible to the aged notice, and in-flight runs are always
// excluded. Every remote read or removal flows through the injected
// `RemoteFileSystem` (D3); the journals under app-support are read
// through core's `LocalFileSystem` — the same VFS family, never a
// second abstraction, and never `dart:io` directly (05 §11 reserves
// that import to `journal.dart`).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

import 'journal.dart';
import 'plan.dart';
import 'sync_state.dart';
import 'trash_root.dart';

/// How long trashed runs rest before the aged notice may offer them
/// (05 §8 rail 5): thirty days from the run's `startedAt` for
/// journal-backed runs, from the directory mtime for journal-less ones.
const Duration syncTrashRetention = Duration(days: 30);

/// Trash directories written by an exported rsync command (§2.1's
/// `rsync-<ts>` backup dirs) carry this literal prefix instead of a
/// device prefix — it is what classifies them on every machine.
const String syncTrashRsyncDirPrefix = 'rsync-';

const int _purgeQuarantineNameAttempts = 3;
const String _purgeQuarantineSeparator = '.purging-';
const String _nestedPurgeQuarantinePrefix = '.poltergeist-purge-';
const int _purgeQuarantineRandomBytes = 12;
final RegExp _purgeQuarantinePattern = RegExp(
  '${RegExp.escape(_purgeQuarantineSeparator)}'
  '([0-9a-f]{8})-'
  '[0-9a-f]{${_purgeQuarantineRandomBytes * 2}}\$',
);

/// Which purge the caller is performing: the notice chip's aged offer,
/// or the explicit `sync.purgeTrash` escape hatch that empties the
/// whole root on demand — foreign-prefix runs included.
enum SyncTrashPurgeScope {
  /// Old journaled, local-orphan, and rsync runs — never foreign runs,
  /// never active ones.
  aged,

  /// Every observed run directory except active ones.
  all,
}

enum _QuarantineNameKind { run, nested }

/// Who a trash-root directory belongs to (05 §8 rail 5). The prefix
/// keeps co-located machines' purges apart without remote journal
/// access: each machine sees only its own journals.
enum SyncTrashOwnership {
  /// A local journal records trash entries under this run directory —
  /// this machine's run history, aged by its `startedAt`.
  journaled,

  /// No local journal covers it, but it carries this device's prefix:
  /// a crash orphan (a crash between the trash rename and the journal
  /// write). Aged by the directory mtime, purged like journaled trash.
  localOrphan,

  /// An exported rsync command's backup dir (`rsync-<ts>`): journal-less
  /// on every machine, aged by mtime like a crash orphan.
  rsyncExport,

  /// Another device's prefix: a sibling machine's run history. The aged
  /// notice never counts or purges it — the owning machine's own notice
  /// ages it out. Only the explicit `all` purge may touch it.
  foreign,
}

/// `<first 8 hex of sha256(deviceId)>` (05 §6): the run-id prefix that
/// lets a remote listing tell this machine's trash directories from a
/// sibling machine's. Hashed so remote-visible trash names carry no
/// slice of the raw device id, yet deterministic per device — which is
/// all the classification needs.
String syncRunDevicePrefix(String deviceId) =>
    sha256.convert(utf8.encode(deviceId)).toString().substring(0, 8);

/// One observed `<runId>` trash directory: its ownership, what ages it,
/// and what the local journals know about it.
final class SyncTrashRun {
  const SyncTrashRun({
    required this.runId,
    String? directoryName,
    required this.ownership,
    required this.ageBasis,
    required this.fileCount,
    required this.pairIds,
  }) : directoryName = directoryName ?? runId;

  /// The logical run id used by journals and activity locks.
  final String runId;

  /// The directory name under the trash root. It differs only for a
  /// foreign owner's abandoned purge quarantine.
  final String directoryName;
  final SyncTrashOwnership ownership;

  /// What aging reads: the run's `startedAt` when a journal covers it,
  /// the directory's mtime otherwise (`now` when the listing carries no
  /// mtime — a missing mtime must never read as immediately old).
  final DateTime ageBasis;

  /// Journal-derived file count — null for journal-less directories,
  /// whose counts the notice never invents (05 §8 rail 5).
  final int? fileCount;

  /// Every pair id whose journal recorded trash under this directory —
  /// empty for journal-less directories.
  final Set<String> pairIds;
}

/// One live trash-root reading: every observed run directory, plus the
/// pure `select` filter that turns it into a purge.
final class SyncTrashInventory {
  const SyncTrashInventory({
    required this.trashRoot,
    required this.canonicalRoot,
    required this.rootId,
    required this.trashScope,
    required this.devicePrefix,
    required this.pathStyle,
    required this.pathCase,
    required this.listedAt,
    required this.runs,
  });

  /// The trash root that was listed — selections and purges carry it so
  /// a purge can never act on a listing from another root.
  final String trashRoot;
  final String canonicalRoot;
  final String rootId;

  /// Stable marker-derived identity used by journals and activity locks.
  final String trashScope;

  /// The inspecting device's prefix — what classified local orphans.
  final String devicePrefix;
  final SyncTrashPathStyle pathStyle;
  final SyncTrashPathCase pathCase;

  /// When the root was listed — the cache's staleness label.
  final DateTime listedAt;

  /// Every observed run directory, sorted by run id. Non-directory
  /// children of the root are never inventoried and never purged.
  final List<SyncTrashRun> runs;

  /// The §9 `trashCache` shape: one entry per observed directory, with
  /// null counts for journal-less runs (counts come from journals only).
  TrashCacheEntry toCache({String? locationKey}) => TrashCacheEntry(
    lastListedAt: listedAt,
    trashScope: trashScope.isEmpty ? null : trashScope,
    locationKey: locationKey,
    runs: [
      for (final run in runs)
        TrashCacheRun(
          runId: run.runId,
          ageBasis: run.ageBasis,
          fileCount: run.fileCount,
        ),
    ],
  );

  /// Pure filter over the observed runs — no I/O. Aged takes old
  /// journaled, local-orphan, and rsync runs; `all` takes every run
  /// directory. Both skip active run ids: purging a live run's trash
  /// would strand journal lines whose `trashLocation` no longer exists
  /// and silently void that run's undo.
  SyncTrashSelection select(
    SyncTrashPurgeScope scope,
    DateTime now,
    Set<String> activeRunIds,
  ) {
    final selected = <SyncTrashRun>[];
    for (final run in runs) {
      if (activeRunIds.contains(run.runId)) continue;
      if (scope == SyncTrashPurgeScope.aged) {
        // Foreign runs belong to their owning machine's notice.
        if (run.ownership == SyncTrashOwnership.foreign) continue;
        if (now.difference(run.ageBasis) <= syncTrashRetention) continue;
      }
      selected.add(run);
    }
    selected.sort((a, b) => a.runId.compareTo(b.runId));
    var knownFileCount = 0;
    var unjournaledRunCount = 0;
    final pairIds = <String>{};
    var foreignRunCount = 0;
    for (final run in selected) {
      final count = run.fileCount;
      if (count == null) {
        unjournaledRunCount++;
      } else {
        knownFileCount += count;
      }
      pairIds.addAll(run.pairIds);
      if (run.ownership == SyncTrashOwnership.foreign) foreignRunCount++;
    }
    return SyncTrashSelection(
      trashRoot: trashRoot,
      canonicalRoot: canonicalRoot,
      rootId: rootId,
      trashScope: trashScope,
      devicePrefix: devicePrefix,
      pathStyle: pathStyle,
      pathCase: pathCase,
      runIds: [for (final run in selected) run.runId],
      directoryNames: Map.unmodifiable({
        for (final run in selected) run.runId: run.directoryName,
      }),
      knownFileCount: knownFileCount,
      unjournaledRunCount: unjournaledRunCount,
      pairIds: pairIds,
      foreignRunCount: foreignRunCount,
    );
  }
}

/// What a purge would remove: the selected run ids plus the summary the
/// confirm dialog renders (known file counts from journals only —
/// journal-less runs count as runs, never as invented files).
final class SyncTrashSelection {
  const SyncTrashSelection({
    required this.trashRoot,
    required this.canonicalRoot,
    required this.rootId,
    required this.trashScope,
    required this.devicePrefix,
    required this.pathStyle,
    required this.pathCase,
    required this.runIds,
    this.directoryNames = const {},
    required this.knownFileCount,
    required this.unjournaledRunCount,
    required this.pairIds,
    required this.foreignRunCount,
  });

  /// The trash root the ids were selected from — purge resolves every
  /// removal under it.
  final String trashRoot;
  final String canonicalRoot;
  final String rootId;
  final String trashScope;
  final String devicePrefix;
  final SyncTrashPathStyle pathStyle;
  final SyncTrashPathCase pathCase;

  /// Selected logical run ids, sorted.
  final List<String> runIds;

  /// Actual root children for selected runs. Normal runs map to
  /// themselves; foreign abandoned quarantines map to their owner-tagged
  /// directory so explicit purge can reclaim them.
  final Map<String, String> directoryNames;

  /// Summed journal-derived file counts of the selected runs.
  final int knownFileCount;

  /// Selected runs no journal covers — the notice's `plus N
  /// unjournaled runs` tail.
  final int unjournaledRunCount;

  /// Every pair id with journaled trash in the selection — the dialog's
  /// scope line ("also removes trashed files belonging to other sync
  /// pairs that use the same root") reads this.
  final Set<String> pairIds;

  /// Selected runs carrying a foreign prefix — nonzero only for the
  /// explicit `all` purge, whose dialog names them as another
  /// machine's.
  final int foreignRunCount;
}

/// One run directory the purge could not remove — recorded, never
/// thrown: a single stubborn run must not strand its siblings, and its
/// journals stay unmarked so the undo source survives.
final class SyncTrashPurgeFailure {
  const SyncTrashPurgeFailure({required this.runId, required this.message});

  final String runId;
  final String message;
}

/// What a purge did: the removed run ids and the per-run failures.
final class SyncTrashPurgeReport {
  const SyncTrashPurgeReport({
    required this.purgedRunIds,
    required this.failures,
    required this.cancelled,
  });

  /// Run ids whose directory is gone (deleted, or already absent).
  /// Identity-backed matching journals are also marked purged; ambiguous
  /// legacy path-only journals stay retained.
  final List<String> purgedRunIds;

  /// One entry per run directory that resisted removal.
  final List<SyncTrashPurgeFailure> failures;
  final bool cancelled;
}

/// Journal coverage of one run id under one trash root: the
/// de-duplicated trash locations that prove the journal belongs to this
/// root, the pairs that wrote them, and the journals to mark purged.
final class _RunCoverage {
  final Set<String> locations = <String>{};
  final Set<String> pairIds = <String>{};
  DateTime? startedAt;
  final Map<SyncRunJournal, String> journalScopes = {};
}

/// The rail-5 purge service: local journals live under
/// [syncRunsDirectory] (`<app-support>/sync_runs`), trash lives under
/// whatever root the caller passes per side. One service covers every
/// root — coverage is derived per call, never cached across roots.
final class SyncTrashPurgeService {
  SyncTrashPurgeService(this.syncRunsDirectory);

  /// Where the local JSONL journals live.
  final String syncRunsDirectory;

  /// Releases journals for a root identity the caller proved no longer
  /// exists. The caller must hold that scope's activity gate while this runs.
  Future<List<String>> markMissingScopePurged(
    String trashRoot,
    String trashScope, {
    SyncTrashPathStyle pathStyle = SyncTrashPathStyle.posix,
    SyncTrashPathCase pathCase = SyncTrashPathCase.sensitive,
    Set<String> activeRunIds = const {},
  }) async {
    if (!isSyncTrashIdentityKey(trashScope)) {
      throw ArgumentError.value(trashScope, 'trashScope', 'is invalid');
    }

    final coverage = await _loadCoverage(
      trashRoot,
      trashScope,
      pathStyle,
      pathCase,
    );
    final purgedRunIds = <String>[];
    for (final covered in coverage.entries) {
      if (activeRunIds.contains(covered.key)) continue;
      if (await _markPurged(covered.value)) {
        purgedRunIds.add(covered.key);
      }
    }

    return purgedRunIds;
  }

  /// Returns every marker generation journaled for one endpoint/path slot.
  Future<Set<String>> trashScopesForLocationKey(String locationKey) async {
    if (!isSyncTrashIdentityKey(locationKey)) {
      throw ArgumentError.value(locationKey, 'locationKey', 'is invalid');
    }
    final scopes = <String>{};
    for (final journal in await _openLocalJournals()) {
      for (final side in SyncSide.values) {
        if (_locationKeyForSide(journal.record, side) != locationKey) continue;
        final scope = journal.trashScopeForSide(side);
        if (scope != null && isSyncTrashIdentityKey(scope)) scopes.add(scope);
      }
    }

    return scopes;
  }

  /// Unpurged logical run ids grouped by marker generation for one slot.
  Future<Map<String, Set<String>>> trashRunIdsByLocationScope(
    String locationKey,
  ) async {
    if (!isSyncTrashIdentityKey(locationKey)) {
      throw ArgumentError.value(locationKey, 'locationKey', 'is invalid');
    }
    final runIdsByScope = <String, Set<String>>{};
    for (final journal in await _openLocalJournals()) {
      for (final side in SyncSide.values) {
        if (_locationKeyForSide(journal.record, side) != locationKey) continue;
        final scope = journal.trashScopeForSide(side);
        if (scope == null ||
            !isSyncTrashIdentityKey(scope) ||
            !_journalHasUnpurgedScope(journal, scope)) {
          continue;
        }
        runIdsByScope
            .putIfAbsent(scope, () => <String>{})
            .add(journal.record.runId);
      }
    }

    return {
      for (final entry in runIdsByScope.entries)
        entry.key: Set.unmodifiable(entry.value),
    };
  }

  /// Marks every old marker generation for [locationKey] after the caller
  /// proves that slot absent and holds its transition and scope gates.
  Future<Map<String, List<String>>> markSupersededLocationScopes(
    String locationKey, {
    String? keepScope,
  }) async {
    if (!isSyncTrashIdentityKey(locationKey)) {
      throw ArgumentError.value(locationKey, 'locationKey', 'is invalid');
    }
    if (keepScope != null && !isSyncTrashIdentityKey(keepScope)) {
      throw ArgumentError.value(keepScope, 'keepScope', 'is invalid');
    }
    final purgedByScope = <String, List<String>>{};
    for (final journal in await _openLocalJournals()) {
      final journalScopes = <String>{};
      for (final side in SyncSide.values) {
        if (_locationKeyForSide(journal.record, side) != locationKey) continue;
        final scope = journal.trashScopeForSide(side);
        if (scope == null ||
            !isSyncTrashIdentityKey(scope) ||
            scope == keepScope) {
          continue;
        }
        if (!_journalHasUnpurgedScope(journal, scope)) continue;
        journalScopes.add(scope);
      }
      for (final scope in journalScopes) {
        await journal.markPurged(trashScope: scope);
        purgedByScope
            .putIfAbsent(scope, () => <String>[])
            .add(journal.record.runId);
      }
    }

    return {
      for (final entry in purgedByScope.entries)
        entry.key: List.unmodifiable(entry.value),
    };
  }

  /// Reads one trash root: exactly one non-recursive listing, then the
  /// local journals. A missing root fails closed until its caller owns a
  /// replacement generation; every listing error propagates. Under an
  /// opened root, journals whose run directory is absent from the listing
  /// are marked `purged` on the spot.
  Future<SyncTrashInventory> inspect(
    RemoteFileSystem fileSystem,
    String trashRoot,
    String devicePrefix,
    DateTime now, {
    String? trashScope,
    SyncTrashPathStyle pathStyle = SyncTrashPathStyle.posix,
    SyncTrashPathCase pathCase = SyncTrashPathCase.sensitive,
    bool Function(String runId)? isActiveRun,
    bool Function()? isCancelled,
    void Function(String runId)? onPurgedRun,
  }) async {
    final rootIdentity = await resolveSyncTrashRoot(
      fileSystem,
      trashRoot,
      pathStyle: pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    if (trashScope != null && trashScope != rootIdentity.scopeKey) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'inspect sync trash',
        path: trashRoot,
        message: 'The sync-trash root changed after planning.',
      );
    }
    final operationalRoot = rootIdentity.canonicalRoot;
    List<RemoteFileEntry> listing;
    var rootMissing = false;
    try {
      listing = await fileSystem.listDirectory(operationalRoot);
    } on RemoteFileException catch (error) {
      // Absence is reported below as a root change. Other failures propagate
      // unchanged, never masquerading as "no trash".
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
      rootMissing = true;
      listing = const <RemoteFileEntry>[];
    }
    if (rootMissing) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'inspect sync trash',
        path: trashRoot,
        message: 'The sync-trash root changed during inspection.',
      );
    }
    await _verifyRootIdentity(
      fileSystem,
      operationalRoot,
      rootIdentity,
      pathStyle,
      pathCase,
    );
    final effectiveTrashScope = rootIdentity.scopeKey;
    final listedNames = {
      for (final entry in listing) _trashNameKey(entry.name, pathCase),
    };
    final protectedRunIds = <String>{};
    final foreignQuarantines = <String, String>{};
    final recoveredListing = <RemoteFileEntry>[];
    for (final entry in listing) {
      final entryNameKey = _trashNameKey(entry.name, pathCase);
      final quarantine = _quarantinedRun(entry.name, pathStyle, pathCase);
      final originalName = quarantine?.runId;
      if (originalName == null) {
        recoveredListing.add(entry);
        continue;
      }
      if (listedNames.contains(originalName)) {
        protectedRunIds.add(originalName);
        recoveredListing.add(entry);
        continue;
      }
      if (quarantine!.ownerPrefix != devicePrefix) {
        protectedRunIds.add(originalName);
        foreignQuarantines[entryNameKey] = originalName;
        recoveredListing.add(entry);
        continue;
      }

      final originalPath = _joinPath(pathStyle, operationalRoot, originalName);
      final quarantinePath = _joinPath(pathStyle, operationalRoot, entry.name);
      try {
        // A prior purge died after its atomic rename. Put the surviving
        // tree back only while it remains under the owned root.
        final recovered = await _recoverQuarantinedRun(
          fileSystem,
          quarantinePath,
          originalPath,
          originalName,
          rootIdentity,
          pathStyle,
          pathCase,
        );
        recoveredListing.add(recovered);
      } on RemoteFileException catch (error) {
        // Never release the journal while a quarantine still guards it.
        protectedRunIds.add(originalName);
        if (error.kind == RemoteFileErrorKind.conflict) rethrow;
        recoveredListing.add(entry);
      }
    }
    final coverage = await _loadCoverage(
      trashRoot,
      effectiveTrashScope,
      pathStyle,
      pathCase,
      isCancelled: isCancelled,
    );
    final runs = <SyncTrashRun>[];
    final observed = <String>{};
    for (final entry in recoveredListing) {
      final entryNameKey = _trashNameKey(entry.name, pathCase);
      // Non-directory children are never inventoried or purged. A valid
      // run-name occupant still protects its journal: it is present but
      // unsafe, not evidence that the trash disappeared.
      if (!entry.isDirectory) {
        if (isSyncTrashRunDirectoryName(entryNameKey)) {
          protectedRunIds.add(entryNameKey);
        }
        continue;
      }
      final foreignRunId = foreignQuarantines[entryNameKey];
      if (foreignRunId == null && !isSyncTrashRunDirectoryName(entryNameKey)) {
        continue;
      }
      final runId = foreignRunId ?? entryNameKey;
      if (!observed.add(runId)) continue;
      final cover = coverage[runId];
      if (foreignRunId != null) {
        runs.add(
          SyncTrashRun(
            runId: runId,
            directoryName: entry.name,
            ownership: SyncTrashOwnership.foreign,
            ageBasis: entry.modifiedAt ?? now,
            fileCount: cover?.locations.length,
            pairIds: Set<String>.unmodifiable(
              cover?.pairIds ?? const <String>{},
            ),
          ),
        );
        continue;
      }
      if (cover != null && cover.startedAt != null) {
        runs.add(
          SyncTrashRun(
            runId: runId,
            directoryName: entry.name,
            ownership: SyncTrashOwnership.journaled,
            ageBasis: cover.startedAt!,
            fileCount: cover.locations.length,
            pairIds: Set<String>.unmodifiable(cover.pairIds),
          ),
        );
        continue;
      }
      runs.add(
        SyncTrashRun(
          runId: runId,
          directoryName: entry.name,
          ownership: _classify(runId, devicePrefix),
          // A missing mtime falls back to now so the directory can
          // never read as immediately old.
          ageBasis: entry.modifiedAt ?? now,
          fileCount: null,
          pairIds: const <String>{},
        ),
      );
    }
    runs.sort((a, b) => a.runId.compareTo(b.runId));
    // Close the loop: journals guarding trash that is no longer there
    // release on the spot.
    for (final covered in coverage.entries) {
      if (observed.contains(covered.key)) continue;
      if (protectedRunIds.contains(covered.key)) continue;
      if (isActiveRun?.call(covered.key) == true) continue;
      if (await _markPurged(covered.value)) {
        onPurgedRun?.call(covered.key);
      }
    }
    return SyncTrashInventory(
      trashRoot: trashRoot,
      canonicalRoot: rootIdentity.canonicalRoot,
      rootId: rootIdentity.rootId,
      trashScope: effectiveTrashScope,
      devicePrefix: devicePrefix,
      pathStyle: pathStyle,
      pathCase: pathCase,
      listedAt: now,
      runs: runs,
    );
  }

  /// Removes [selection]'s run directories: re-lists the root live (a
  /// purge acts on a live listing, never on the inspection-time
  /// snapshot), deletes only selected ids the fresh listing confirms
  /// as directories — never newly appeared dirs, never the trash root,
  /// never non-directory children — skips active ids, and marks every
  /// matching journal only after its run directory is gone or absent.
  /// Per-run failures are recorded in the report; listing errors other
  /// than absence propagate. Cancellation returns the completed prefix
  /// so callers can report and mirror journal invalidation accurately.
  Future<SyncTrashPurgeReport> purge(
    RemoteFileSystem fileSystem,
    SyncTrashSelection selection,
    Set<String> activeRunIds, [
    RemoteTransferCancellation? cancellation,
  ]) async {
    final purged = <String>[];
    final failures = <SyncTrashPurgeFailure>[];
    if (selection.runIds.isEmpty) {
      return SyncTrashPurgeReport(
        purgedRunIds: purged,
        failures: failures,
        cancelled: false,
      );
    }
    try {
      _throwIfPurgeCancelled(cancellation, selection.trashRoot);

      SyncTrashRootIdentity? initialRoot;
      var rootMissing = false;
      try {
        initialRoot = await _openSelectionRoot(fileSystem, selection);
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.conflict) {
          return _rootFailureReport(selection, error.message);
        }
        if (error.kind != RemoteFileErrorKind.notFound) rethrow;
        rootMissing = true;
      }

      // A purge acts on this fresh listing, never the dialog snapshot.
      Map<String, RemoteFileEntry> live;
      var listingMissing = rootMissing;
      if (initialRoot == null) {
        live = const <String, RemoteFileEntry>{};
      } else {
        try {
          final listing = await fileSystem.listDirectory(
            initialRoot.canonicalRoot,
          );
          live = {for (final entry in listing) entry.name: entry};
        } on RemoteFileException catch (error) {
          if (error.kind != RemoteFileErrorKind.notFound) rethrow;
          listingMissing = true;
          live = const <String, RemoteFileEntry>{};
        }
      }

      var operationalRoot =
          initialRoot?.canonicalRoot ?? selection.canonicalRoot;
      try {
        final verified = await _openSelectionRoot(fileSystem, selection);
        if (initialRoot == null || listingMissing) {
          return _rootFailureReport(
            selection,
            'The sync-trash root changed after confirmation.',
          );
        }
        operationalRoot = verified.canonicalRoot;
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.conflict) {
          return _rootFailureReport(selection, error.message);
        }
        if (error.kind != RemoteFileErrorKind.notFound) rethrow;
        if (!listingMissing) {
          return _rootFailureReport(
            selection,
            'The sync-trash root changed after confirmation.',
          );
        }
      }

      final coverage = await _loadCoverage(
        selection.trashRoot,
        selection.trashScope,
        selection.pathStyle,
        selection.pathCase,
        isCancelled: () => cancellation?.isCancelled ?? false,
      );
      for (final runId in selection.runIds) {
        if (activeRunIds.contains(runId)) continue;
        _throwIfPurgeCancelled(cancellation, selection.trashRoot);
        final directoryName = selection.directoryNames[runId] ?? runId;
        final runIdKey = _trashNameKey(runId, selection.pathCase);
        final directoryNameKey = _trashNameKey(
          directoryName,
          selection.pathCase,
        );
        final quarantine = _quarantinedRun(
          directoryName,
          selection.pathStyle,
          selection.pathCase,
        );
        final validQuarantine =
            quarantine != null &&
            quarantine.runId == runIdKey &&
            quarantine.ownerPrefix != selection.devicePrefix;
        if (!isSyncTrashRunDirectoryName(runId) ||
            !_isPlainDirectoryName(runId, selection.pathStyle) ||
            (directoryNameKey != runIdKey && !validQuarantine)) {
          failures.add(
            SyncTrashPurgeFailure(
              runId: runId,
              message: 'refusing to purge "$runId": invalid run id',
            ),
          );
          continue;
        }

        final representations = <RemoteFileEntry>[];
        for (final candidate in live.values) {
          final candidateQuarantine = _quarantinedRun(
            candidate.name,
            selection.pathStyle,
            selection.pathCase,
          );
          final candidateNameKey = _trashNameKey(
            candidate.name,
            selection.pathCase,
          );
          if (candidateNameKey == runIdKey ||
              candidateQuarantine?.runId == runIdKey) {
            representations.add(candidate);
          }
        }
        if (representations.isEmpty) {
          try {
            if (!await _confirmLogicalRunAbsent(
              fileSystem,
              selection,
              operationalRoot,
              runId,
            )) {
              failures.add(_changedRunFailure(runId));
              continue;
            }
            await _markPurged(coverage[runId]);
            purged.add(runId);
          } on Object catch (error) {
            _throwIfPurgeCancelled(cancellation, selection.trashRoot);
            failures.add(
              SyncTrashPurgeFailure(runId: runId, message: '$error'),
            );
          }
          continue;
        }
        if (representations.length != 1 ||
            _trashNameKey(representations.single.name, selection.pathCase) !=
                directoryNameKey) {
          failures.add(
            SyncTrashPurgeFailure(
              runId: runId,
              message: 'refusing to purge "$runId": changed after confirmation',
            ),
          );
          continue;
        }
        final entry = representations.single;
        if (!entry.isDirectory) {
          failures.add(
            SyncTrashPurgeFailure(
              runId: runId,
              message: 'refusing to purge "$runId": no longer a directory',
            ),
          );
          continue;
        }

        final runPath = _joinPath(
          selection.pathStyle,
          operationalRoot,
          entry.name,
        );
        try {
          _throwIfPurgeCancelled(cancellation, runPath);
          final quarantined = await _quarantineDirectory(
            fileSystem,
            runPath,
            runId,
            selection.devicePrefix,
            operationalRoot,
            selection.pathStyle,
            selection.pathCase,
            _QuarantineNameKind.run,
            () async {
              await _openSelectionRoot(fileSystem, selection);
            },
          );
          if (quarantined == null) {
            if (!await _confirmLogicalRunAbsent(
              fileSystem,
              selection,
              operationalRoot,
              runId,
            )) {
              failures.add(_changedRunFailure(runId));
              continue;
            }
            await _markPurged(coverage[runId]);
            purged.add(runId);
            continue;
          }
          try {
            // The root path may be replaced between its pre-rename check and
            // reservation. Revalidate ownership before traversing the move.
            await _openSelectionRoot(fileSystem, selection);
            await _deleteDirectoryRecursively(
              fileSystem,
              quarantined.path,
              quarantined.canonicalPath,
              selection.devicePrefix,
              selection.pathStyle,
              selection.pathCase,
              cancellation,
              () async {
                await _openSelectionRoot(fileSystem, selection);
              },
            );
            await _markPurged(coverage[runId]);
            purged.add(runId);
          } on Object {
            await _restoreQuarantinedDirectory(
              fileSystem,
              quarantined.path,
              runPath,
              expectedParentCanonical: operationalRoot,
              pathStyle: selection.pathStyle,
              pathCase: selection.pathCase,
              verifyRoot: () async {
                await _openSelectionRoot(fileSystem, selection);
              },
            );
            rethrow;
          }
        } on Object catch (error) {
          final cancelledError =
              error is RemoteFileException &&
              error.kind == RemoteFileErrorKind.cancelled;
          if (!cancelledError) {
            failures.add(
              SyncTrashPurgeFailure(runId: runId, message: '$error'),
            );
          }
          _throwIfPurgeCancelled(cancellation, selection.trashRoot);
          if (cancelledError) rethrow;
        }
      }
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.cancelled) rethrow;
      return SyncTrashPurgeReport(
        purgedRunIds: purged,
        failures: failures,
        cancelled: true,
      );
    }
    return SyncTrashPurgeReport(
      purgedRunIds: purged,
      failures: failures,
      cancelled: false,
    );
  }

  SyncTrashPurgeFailure _changedRunFailure(String runId) =>
      SyncTrashPurgeFailure(
        runId: runId,
        message: 'refusing to purge "$runId": changed after confirmation',
      );

  Future<bool> _confirmLogicalRunAbsent(
    RemoteFileSystem fileSystem,
    SyncTrashSelection selection,
    String operationalRoot,
    String runId,
  ) async {
    final listing = await fileSystem.listDirectory(operationalRoot);
    final runIdKey = _trashNameKey(runId, selection.pathCase);
    for (final entry in listing) {
      final quarantine = _quarantinedRun(
        entry.name,
        selection.pathStyle,
        selection.pathCase,
      );
      if (_trashNameKey(entry.name, selection.pathCase) == runIdKey ||
          quarantine?.runId == runIdKey) {
        return false;
      }
    }

    await _openSelectionRoot(fileSystem, selection);
    return true;
  }

  Future<SyncTrashRootIdentity> _openSelectionRoot(
    RemoteFileSystem fileSystem,
    SyncTrashSelection selection,
  ) async {
    final root = await resolveSyncTrashRoot(
      fileSystem,
      selection.trashRoot,
      pathStyle: selection.pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    final expectedCanonical = normalizeSyncTrashPath(
      selection.canonicalRoot,
      selection.pathStyle,
      selection.pathCase,
    );
    final actualCanonical = normalizeSyncTrashPath(
      root.canonicalRoot,
      selection.pathStyle,
      selection.pathCase,
    );
    if (root.rootId == selection.rootId &&
        actualCanonical == expectedCanonical) {
      return root;
    }

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'purge',
      path: selection.trashRoot,
      message: 'The sync-trash root changed after confirmation.',
    );
  }

  Future<void> _verifyRootIdentity(
    RemoteFileSystem fileSystem,
    String trashRoot,
    SyncTrashRootIdentity expected,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase,
  ) async {
    final actual = await resolveSyncTrashRoot(
      fileSystem,
      trashRoot,
      pathStyle: pathStyle,
      access: SyncTrashRootAccess.openExisting,
    );
    if (actual.rootId == expected.rootId &&
        _pathsEqual(
          actual.canonicalRoot,
          expected.canonicalRoot,
          pathStyle,
          pathCase,
        )) {
      return;
    }

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'inspect sync trash',
      path: trashRoot,
      message: 'The sync-trash root changed during inspection.',
    );
  }

  Future<RemoteFileEntry> _recoverQuarantinedRun(
    RemoteFileSystem fileSystem,
    String quarantinePath,
    String originalPath,
    String originalName,
    SyncTrashRootIdentity rootIdentity,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase,
  ) async {
    await _verifyRootIdentity(
      fileSystem,
      rootIdentity.canonicalRoot,
      rootIdentity,
      pathStyle,
      pathCase,
    );
    await _verifyRecoveryDirectory(
      fileSystem,
      quarantinePath,
      rootIdentity.canonicalRoot,
      pathStyle,
      pathCase,
    );
    await _verifyRootIdentity(
      fileSystem,
      rootIdentity.canonicalRoot,
      rootIdentity,
      pathStyle,
      pathCase,
    );

    await fileSystem.rename(quarantinePath, originalPath);
    try {
      await _verifyRootIdentity(
        fileSystem,
        rootIdentity.canonicalRoot,
        rootIdentity,
        pathStyle,
        pathCase,
      );
      final recovered = await _verifyRecoveryDirectory(
        fileSystem,
        originalPath,
        rootIdentity.canonicalRoot,
        pathStyle,
        pathCase,
      );
      return _entryAtPath(recovered, originalPath, originalName);
    } on Object {
      // Keep a failed recovery recognizable and restorable on the next scan.
      try {
        await _verifyRootIdentity(
          fileSystem,
          rootIdentity.canonicalRoot,
          rootIdentity,
          pathStyle,
          pathCase,
        );
        await _verifyRecoveryDirectory(
          fileSystem,
          originalPath,
          rootIdentity.canonicalRoot,
          pathStyle,
          pathCase,
        );
        await fileSystem.rename(originalPath, quarantinePath);
      } on Object {
        // The original validation error remains the actionable failure.
      }
      rethrow;
    }
  }

  Future<RemoteFileEntry> _verifyRecoveryDirectory(
    RemoteFileSystem fileSystem,
    String path,
    String expectedParent,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase,
  ) async {
    final entry = await fileSystem.stat(path, followLinks: false);
    final context = syncTrashPathContext(pathStyle);
    final canonical = await fileSystem.canonicalize(path);
    if (entry.isDirectory &&
        _pathsEqual(
          context.dirname(canonical),
          expectedParent,
          pathStyle,
          pathCase,
        )) {
      return entry;
    }

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'recover sync trash',
      path: path,
      message: 'The quarantined sync-trash run changed during recovery.',
    );
  }

  SyncTrashPurgeReport _rootFailureReport(
    SyncTrashSelection selection,
    String message,
  ) => SyncTrashPurgeReport(
    purgedRunIds: const [],
    failures: [
      for (final runId in selection.runIds)
        SyncTrashPurgeFailure(runId: runId, message: message),
    ],
    cancelled: false,
  );

  /// Journal coverage for [trashRoot]: every valid local journal's
  /// trash locations whose parent directory basename equals the
  /// journal's own run id and whose normalized grandparent equals the
  /// root. Locations de-duplicate (update backups and pre-delete lines
  /// can name the same file). Journals that fail to open are skipped —
  /// a corrupt journal must not wedge the purge — and locations
  /// pointing at other roots never count as coverage here.
  Future<Map<String, _RunCoverage>> _loadCoverage(
    String trashRoot,
    String trashScope,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase, {
    bool Function()? isCancelled,
  }) async {
    _throwIfCoverageCancelled(isCancelled, trashRoot);
    final coverage = <String, _RunCoverage>{};
    final context = syncTrashPathContext(pathStyle);
    final normalizedRoot = normalizeSyncTrashPath(
      trashRoot,
      pathStyle,
      pathCase,
    );
    for (final journal in await _openLocalJournals(
      isCancelled: isCancelled,
      cancellationPath: trashRoot,
    )) {
      _throwIfCoverageCancelled(isCancelled, trashRoot);
      if (!isSyncTrashRunDirectoryName(journal.record.runId)) continue;
      final entries = <({SyncSide side, String location})>{
        for (final line in journal.items)
          if (line.trashLocation != null &&
              !journal.isTrashEntryPurged(line.side, line.trashLocation!))
            (side: line.side, location: line.trashLocation!),
        for (final line in journal.trashLines)
          if (!journal.isTrashEntryPurged(line.side, line.trashLocation))
            (side: line.side, location: line.trashLocation),
      };
      for (final entry in entries) {
        final location = entry.location;
        final parent = context.dirname(location);
        final parentName = context.basename(parent);
        final expectedRunId = journal.record.runId;
        final namesMatch = pathCase == SyncTrashPathCase.sensitive
            ? parentName == expectedRunId
            : parentName.toLowerCase() == expectedRunId.toLowerCase();
        if (!namesMatch) continue;
        final journalScope = journal.trashScopeForSide(entry.side);
        if (journalScope != null && journalScope != trashScope) continue;
        if (journalScope == null &&
            normalizeSyncTrashPath(
                  context.dirname(parent),
                  pathStyle,
                  pathCase,
                ) !=
                normalizedRoot) {
          continue;
        }
        final cover = coverage.putIfAbsent(
          journal.record.runId,
          _RunCoverage.new,
        );
        cover.locations.add(location);
        cover.pairIds.add(journal.record.pairId);
        if (journalScope != null) {
          cover.journalScopes[journal] = journalScope;
        }
        final startedAt = journal.record.startedAt;
        if (cover.startedAt == null || startedAt.isBefore(cover.startedAt!)) {
          cover.startedAt = startedAt;
        }
      }
    }
    return coverage;
  }

  /// Opens only derived, regular `.jsonl` children of the journal directory.
  /// Symlinks and listing-supplied paths never reach the append-capable
  /// journal API.
  Future<List<SyncRunJournal>> _openLocalJournals({
    bool Function()? isCancelled,
    String? cancellationPath,
  }) async {
    _throwIfCoverageCancelled(
      isCancelled,
      cancellationPath ?? syncRunsDirectory,
    );
    final journals = <SyncRunJournal>[];
    final localFileSystem = LocalFileSystem();
    final List<RemoteFileEntry> listing;
    try {
      listing = await localFileSystem.listDirectory(syncRunsDirectory);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
      return journals;
    }

    final normalizedDirectory = p.normalize(syncRunsDirectory);
    for (final entity in listing) {
      _throwIfCoverageCancelled(
        isCancelled,
        cancellationPath ?? syncRunsDirectory,
      );
      if (entity.type != RemoteFileType.file ||
          !entity.name.endsWith('.jsonl') ||
          p.basename(entity.name) != entity.name) {
        continue;
      }
      final journalPath = p.join(normalizedDirectory, entity.name);
      if (!p.equals(p.dirname(journalPath), normalizedDirectory)) continue;

      try {
        final live = await localFileSystem.stat(
          journalPath,
          followLinks: false,
        );
        if (live.type != RemoteFileType.file) continue;
        journals.add(await SyncRunJournal.open(journalPath));
        _throwIfCoverageCancelled(
          isCancelled,
          cancellationPath ?? syncRunsDirectory,
        );
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.cancelled) rethrow;
        // Corrupt or concurrently removed journals do not wedge inspection.
      } on Object {
        // Corrupt or concurrently removed journals do not wedge inspection.
      }
    }

    return journals;
  }

  void _throwIfCoverageCancelled(bool Function()? isCancelled, String path) {
    if (isCancelled?.call() != true) return;

    throw RemoteFileException(
      kind: RemoteFileErrorKind.cancelled,
      operation: 'inspect sync-trash journals',
      path: path,
      message: 'Sync-trash journal inspection cancelled.',
    );
  }

  String? _locationKeyForSide(SyncRunRecord record, SyncSide side) =>
      switch (side) {
        SyncSide.left => record.trashLocationKeyLeft,
        SyncSide.right => record.trashLocationKeyRight,
      };

  bool _journalHasUnpurgedScope(SyncRunJournal journal, String scope) {
    for (final line in journal.items) {
      final location = line.trashLocation;
      if (location == null || journal.isTrashEntryPurged(line.side, location)) {
        continue;
      }
      if (journal.trashScopeForEntry(line.side, location) == scope) return true;
    }
    for (final line in journal.trashLines) {
      if (journal.isTrashEntryPurged(line.side, line.trashLocation)) continue;
      if (journal.trashScopeForEntry(line.side, line.trashLocation) == scope) {
        return true;
      }
    }

    return false;
  }

  /// Stamps `purged` into every unpurged journal guarding [cover]'s run
  /// — the marker rail 9's retention reads. Callers invoke this only
  /// after the run directory is gone or confirmed absent.
  Future<bool> _markPurged(_RunCoverage? cover) async {
    if (cover == null || cover.journalScopes.isEmpty) return false;
    for (final entry in cover.journalScopes.entries) {
      if (!entry.key.isTrashScopePurged(entry.value)) {
        await entry.key.markPurged(trashScope: entry.value);
      }
    }
    return true;
  }

  /// Atomically moves a directory away from its listed name before
  /// traversal. The caller repeats this reservation for nested dirs so
  /// replacing any listed path cannot redirect the walk.
  Future<({String path, String canonicalPath})?> _quarantineDirectory(
    RemoteFileSystem fileSystem,
    String directoryPath,
    String directoryName,
    String devicePrefix,
    String expectedParentCanonical,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase,
    _QuarantineNameKind nameKind,
    Future<void> Function() verifyRoot,
  ) async {
    final context = syncTrashPathContext(pathStyle);
    final RemoteFileEntry entry;
    try {
      entry = await fileSystem.stat(directoryPath, followLinks: false);
    } on RemoteFileException catch (error) {
      if (error.kind == RemoteFileErrorKind.notFound) return null;
      rethrow;
    }
    if (!entry.isDirectory) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'purge',
        path: directoryPath,
        message: 'refusing to purge "$directoryName": no longer a directory',
      );
    }
    await _verifyCanonicalPath(
      fileSystem,
      context.dirname(directoryPath),
      expectedParentCanonical,
      pathStyle,
      pathCase,
    );

    for (var attempt = 0; attempt < _purgeQuarantineNameAttempts; attempt++) {
      final quarantineName = switch (nameKind) {
        _QuarantineNameKind.run =>
          '$directoryName$_purgeQuarantineSeparator'
              '$devicePrefix-${_purgeQuarantineSuffix()}',
        _QuarantineNameKind.nested =>
          '$_nestedPurgeQuarantinePrefix${_purgeQuarantineSuffix()}',
      };
      final quarantinePath = context.join(
        context.dirname(directoryPath),
        quarantineName,
      );
      try {
        await fileSystem.rename(directoryPath, quarantinePath);
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.notFound) return null;
        if (error.kind == RemoteFileErrorKind.conflict) continue;
        rethrow;
      }

      final moved = await fileSystem.stat(quarantinePath, followLinks: false);
      if (moved.isDirectory) {
        final canonicalPath = await fileSystem.canonicalize(quarantinePath);
        final canonicalParent = context.dirname(canonicalPath);
        if (_pathsEqual(
          canonicalParent,
          expectedParentCanonical,
          pathStyle,
          pathCase,
        )) {
          return (path: quarantinePath, canonicalPath: canonicalPath);
        }
      }

      await _restoreQuarantinedDirectory(
        fileSystem,
        quarantinePath,
        directoryPath,
        expectedParentCanonical: expectedParentCanonical,
        pathStyle: pathStyle,
        pathCase: pathCase,
        verifyRoot: verifyRoot,
      );
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'purge',
        path: directoryPath,
        message: 'refusing to purge "$directoryName": no longer a directory',
      );
    }

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'purge',
      path: directoryPath,
      message: 'could not reserve a private purge name for "$directoryName"',
    );
  }

  /// A failed or cancelled recursive removal keeps the surviving tree
  /// at its journaled run path whenever no concurrent writer took it.
  Future<void> _restoreQuarantinedDirectory(
    RemoteFileSystem fileSystem,
    String quarantinePath,
    String runPath, {
    required String expectedParentCanonical,
    required SyncTrashPathStyle pathStyle,
    required SyncTrashPathCase pathCase,
    required Future<void> Function() verifyRoot,
  }) async {
    final context = syncTrashPathContext(pathStyle);
    final quarantineParent = context.dirname(quarantinePath);
    final runParent = context.dirname(runPath);
    if (!_pathsEqual(quarantineParent, runParent, pathStyle, pathCase)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'purge rollback',
        path: quarantinePath,
        message: 'The sync-trash directory changed during rollback.',
      );
    }

    await verifyRoot();
    await _verifyCanonicalPath(
      fileSystem,
      quarantineParent,
      expectedParentCanonical,
      pathStyle,
      pathCase,
    );
    final source = await fileSystem.stat(quarantinePath, followLinks: false);
    if (!source.isDirectory) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'purge rollback',
        path: quarantinePath,
        message: 'The quarantined directory changed during rollback.',
      );
    }
    final canonicalSource = await fileSystem.canonicalize(quarantinePath);
    if (!_pathsEqual(
      context.dirname(canonicalSource),
      expectedParentCanonical,
      pathStyle,
      pathCase,
    )) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'purge rollback',
        path: quarantinePath,
        message: 'The quarantined directory moved during rollback.',
      );
    }

    // Validation yields. Repeat ownership immediately before the rename.
    await verifyRoot();
    await _verifyCanonicalPath(
      fileSystem,
      quarantineParent,
      expectedParentCanonical,
      pathStyle,
      pathCase,
    );
    try {
      await fileSystem.rename(quarantinePath, runPath);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
    }
  }

  /// Removes one quarantined directory and everything under it. Symlinks
  /// and non-directories die as single entries. Each child directory is
  /// moved to a fresh sibling name before descent, so replacing its
  /// listed name cannot redirect the walk. Vanished entries are already
  /// gone; anything else propagates to the run's report entry.
  Future<void> _deleteDirectoryRecursively(
    RemoteFileSystem fileSystem,
    String directory,
    String expectedCanonical,
    String devicePrefix,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase,
    RemoteTransferCancellation? cancellation,
    Future<void> Function() verifyRoot,
  ) async {
    final context = syncTrashPathContext(pathStyle);
    try {
      final entry = await fileSystem.stat(directory, followLinks: false);
      if (!entry.isDirectory) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'purge',
          path: directory,
          message: 'refusing to purge "$directory": no longer a directory',
        );
      }
      await _verifyCanonicalPath(
        fileSystem,
        directory,
        expectedCanonical,
        pathStyle,
        pathCase,
      );
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
      return;
    }

    final List<RemoteFileEntry> children;
    try {
      children = await fileSystem.listDirectory(directory);
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
      return;
    }
    for (final child in children) {
      _throwIfPurgeCancelled(cancellation, directory);
      await _verifyCanonicalPath(
        fileSystem,
        directory,
        expectedCanonical,
        pathStyle,
        pathCase,
      );
      if (!_isPlainDirectoryName(child.name, pathStyle)) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'purge',
          path: directory,
          message: 'refusing unsafe child name "${child.name}"',
        );
      }
      // Listing paths are untrusted adapter metadata. Resolve each
      // validated child below the directory we are already purging.
      final childPath = context.join(directory, child.name);
      final RemoteFileEntry live;
      try {
        live = await fileSystem.stat(childPath, followLinks: false);
      } on RemoteFileException catch (error) {
        if (error.kind != RemoteFileErrorKind.notFound) rethrow;
        continue;
      }
      if (live.isDirectory) {
        final quarantinedChild = await _quarantineDirectory(
          fileSystem,
          childPath,
          child.name,
          devicePrefix,
          expectedCanonical,
          pathStyle,
          pathCase,
          _QuarantineNameKind.nested,
          verifyRoot,
        );
        if (quarantinedChild == null) continue;

        try {
          await _deleteDirectoryRecursively(
            fileSystem,
            quarantinedChild.path,
            quarantinedChild.canonicalPath,
            devicePrefix,
            pathStyle,
            pathCase,
            cancellation,
            verifyRoot,
          );
        } on Object {
          await _restoreQuarantinedDirectory(
            fileSystem,
            quarantinedChild.path,
            childPath,
            expectedParentCanonical: expectedCanonical,
            pathStyle: pathStyle,
            pathCase: pathCase,
            verifyRoot: verifyRoot,
          );
          rethrow;
        }
      } else {
        try {
          await _verifyCanonicalPath(
            fileSystem,
            directory,
            expectedCanonical,
            pathStyle,
            pathCase,
          );
          await fileSystem.delete(_entryAtPath(live, childPath, child.name));
        } on RemoteFileException catch (error) {
          if (error.kind != RemoteFileErrorKind.notFound) rethrow;
        }
      }
    }
    _throwIfPurgeCancelled(cancellation, directory);
    try {
      final self = await fileSystem.stat(directory, followLinks: false);
      // A run directory replaced by a file or link since the listing
      // is refused exactly like a non-directory child: never deleted.
      if (!self.isDirectory) {
        throw RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'purge',
          path: directory,
          message: 'refusing to purge "$directory": no longer a directory',
        );
      }
      await _verifyCanonicalPath(
        fileSystem,
        directory,
        expectedCanonical,
        pathStyle,
        pathCase,
      );
      await fileSystem.delete(
        _entryAtPath(self, directory, context.basename(directory)),
      );
    } on RemoteFileException catch (error) {
      if (error.kind != RemoteFileErrorKind.notFound) rethrow;
    }
  }

  Future<void> _verifyCanonicalPath(
    RemoteFileSystem fileSystem,
    String path,
    String expectedCanonical,
    SyncTrashPathStyle pathStyle,
    SyncTrashPathCase pathCase,
  ) async {
    final actual = await fileSystem.canonicalize(path);
    if (_pathsEqual(actual, expectedCanonical, pathStyle, pathCase)) return;

    throw RemoteFileException(
      kind: RemoteFileErrorKind.conflict,
      operation: 'purge',
      path: path,
      message: 'The purge path changed during removal.',
    );
  }
}

void _throwIfPurgeCancelled(
  RemoteTransferCancellation? cancellation,
  String path,
) {
  if (cancellation?.isCancelled != true) return;

  throw RemoteFileException(
    kind: RemoteFileErrorKind.cancelled,
    operation: 'purge',
    path: path,
    message: 'Trash purge cancelled',
  );
}

String _purgeQuarantineSuffix() => secureRandomBytes(
  _purgeQuarantineRandomBytes,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

({String runId, String ownerPrefix})? _quarantinedRun(
  String name,
  SyncTrashPathStyle pathStyle,
  SyncTrashPathCase pathCase,
) {
  final nameKey = _trashNameKey(name, pathCase);
  final match = _purgeQuarantinePattern.firstMatch(nameKey);
  if (match == null) return null;
  final runId = nameKey.substring(0, match.start);
  if (!isSyncTrashRunDirectoryName(runId) ||
      !_isPlainDirectoryName(runId, pathStyle)) {
    return null;
  }
  return (runId: runId, ownerPrefix: match.group(1)!);
}

String _trashNameKey(String name, SyncTrashPathCase pathCase) =>
    pathCase == SyncTrashPathCase.sensitive ? name : name.toLowerCase();

RemoteFileEntry _entryAtPath(RemoteFileEntry entry, String path, String name) =>
    RemoteFileEntry(
      path: path,
      name: name,
      type: entry.type,
      size: entry.size,
      uid: entry.uid,
      gid: entry.gid,
      accessedAt: entry.accessedAt,
      modifiedAt: entry.modifiedAt,
      contentSha256: entry.contentSha256,
      mode: entry.mode,
    );

/// Classifies a journal-less run directory: this device's prefix reads
/// as a crash orphan, the rsync literal as an export, anything else as
/// a sibling machine's history.
SyncTrashOwnership _classify(String runId, String devicePrefix) {
  if (runId.startsWith(syncTrashRsyncDirPrefix)) {
    return SyncTrashOwnership.rsyncExport;
  }
  if (devicePrefix.isNotEmpty && runId.startsWith('$devicePrefix-')) {
    return SyncTrashOwnership.localOrphan;
  }
  return SyncTrashOwnership.foreign;
}

/// Plain single-segment names only — the purge joins these onto the
/// trash root, so anything that could escape it is refused.
bool _isPlainDirectoryName(String runId, SyncTrashPathStyle pathStyle) =>
    runId.isNotEmpty &&
    runId != '.' &&
    runId != '..' &&
    !runId.contains('/') &&
    (pathStyle == SyncTrashPathStyle.posix || !runId.contains('\\'));

String _joinPath(SyncTrashPathStyle style, String parent, String child) =>
    syncTrashPathContext(style).join(parent, child);

bool _pathsEqual(
  String first,
  String second,
  SyncTrashPathStyle style,
  SyncTrashPathCase pathCase,
) =>
    normalizeSyncTrashPath(first, style, pathCase) ==
    normalizeSyncTrashPath(second, style, pathCase);
