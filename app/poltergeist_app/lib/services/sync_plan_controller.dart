// The plan-view controller (05 §6–§8): owns one sync session's whole
// lifecycle — scan → diff → overrides → rails → run → retry/restore —
// and every figure the view renders. It is deliberately engine-faced:
// the widget layer never touches TreeScanner/SyncExecutor/journal, and
// tests drive the full flow against in-memory filesystems through the
// [SyncPairScanner]/[SyncPlanDiffer] seams.
//
// State machine:
//   scanning → ready ⇄ running → completed|failed|cancelled
//      ↑ rescan() rebuilds from scratch (rules edits included)
//   error — scan/environment failures, dead end until rescan()
import 'dart:async';
import 'dart:io' show FileSystemException;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import 'rsync_endpoints.dart';
import 'sync_compare_controller.dart';
import 'sync_environment.dart';
import 'sync_queue_facade.dart';
import 'sync_state_store.dart';
import 'sync_trash_activity.dart';

/// Lifecycle phases the plan view renders.
enum SyncPlanPhase {
  scanning,
  ready,
  running,
  completed,
  failed,
  cancelled,
  error,
}

enum _SyncPlanOperation { run, retry, restore, purge }

/// The header's exact figures — §7's sentence is built from these and
/// only these; the view never re-derives counts from raw items. Kept
/// override-aware: every effective-action mutation recomputes (the
/// plan's own [PlanTotals] describe the *suggested* plan).
final class SyncEffectiveStats {
  const SyncEffectiveStats({
    required this.counts,
    required this.bytes,
    required this.replacedFiles,
    required this.replacedBytes,
    required this.replacedBySide,
    required this.replacedRowsBySide,
    required this.fileDeletesBySide,
    required this.dirDeletesBySide,
  });

  /// Items per effective action class.
  final Map<SyncActionType, int> counts;

  /// Payload bytes per effective action class (the copy/update source
  /// sizes — creates and deletes carry none).
  final Map<SyncActionType, int> bytes;

  /// §6 rule 4 pre-delete removals by destination side — the rails and
  /// the Deletes chip count these per removed FILE.
  final Map<SyncSide, int> replacedBySide;

  /// §7's replace clause counts ROWS — one per replaced path — where
  /// [replacedBySide] keeps the per-file toll.
  final Map<SyncSide, int> replacedRowsBySide;
  final int replacedFiles;
  final int replacedBytes;

  /// File deletions per side — delete rows whose destination is not a
  /// directory (the §8 rail weight). Empty-directory cleanup rows stay
  /// visible under [emptyDirsOn] but count as zero file deletions.
  final Map<SyncSide, int> fileDeletesBySide;
  final Map<SyncSide, int> dirDeletesBySide;

  int countOf(SyncActionType action) => counts[action] ?? 0;
  int bytesOf(SyncActionType action) => bytes[action] ?? 0;

  /// Buckets §7's first clause enumerates, per destination side.
  int newFilesTo(SyncSide side) => switch (side) {
    SyncSide.right => countOf(SyncActionType.copyLeftToRight),
    SyncSide.left => countOf(SyncActionType.copyRightToLeft),
  };

  int updatesTo(SyncSide side) => switch (side) {
    SyncSide.right => countOf(SyncActionType.updateLeftToRight),
    SyncSide.left => countOf(SyncActionType.updateRightToLeft),
  };

  int newBytesTo(SyncSide side) => switch (side) {
    SyncSide.right => bytesOf(SyncActionType.copyLeftToRight),
    SyncSide.left => bytesOf(SyncActionType.copyRightToLeft),
  };

  int foldersTo(SyncSide side) => switch (side) {
    SyncSide.right => countOf(SyncActionType.makeDirRight),
    SyncSide.left => countOf(SyncActionType.makeDirLeft),
  };

  int deletesOn(SyncSide side) => fileDeletesBySide[side] ?? 0;

  /// Zero-file-deletion cleanup rows (05 §8: empty-directory removals
  /// are visible but count as zero file deletions on every rail).
  int emptyDirsOn(SyncSide side) => dirDeletesBySide[side] ?? 0;

  int get conflicts =>
      countOf(SyncActionType.conflict);

  /// "Both sides match. Nothing to do." — no actionable work and no
  /// pending conflict rows.
  bool get hasWork =>
      counts.entries.any(
        (entry) =>
            entry.key != SyncActionType.skip &&
            entry.key != SyncActionType.conflict &&
            entry.value > 0,
      ) ||
      conflicts > 0;
}

/// A §9 heavy-directory suggestion: on a first-run pair, when one of
/// the known noise names covers more than half the actionable items.
final class SyncHeavyDirectorySuggestion {
  const SyncHeavyDirectorySuggestion({
    required this.name,
    required this.itemCount,
  });
  final String name;
  final int itemCount;
}

/// One aged-trash notice for a physical side root. Two pane sides that
/// resolve to the same host/root collapse into one notice and one purge.
final class SyncTrashNotice {
  const SyncTrashNotice._({
    required this._location,
    required this.sides,
    required this.knownFileCount,
    required this.runCount,
    required this.unjournaledRunCount,
    required this.listedAt,
    required this.isStale,
    required this.canPurge,
  });

  final SyncTrashLocation _location;
  final Set<SyncSide> sides;
  final int knownFileCount;
  final int runCount;
  final int unjournaledRunCount;
  final DateTime listedAt;
  final bool isStale;
  final bool canPurge;
}

/// The immutable selection a confirmation dialog describes and then
/// hands back to the controller. The engine re-lists before deletion.
final class SyncTrashPurgeRequest {
  const SyncTrashPurgeRequest._({
    required this._targets,
    required this._admission,
    required this.knownFileCount,
    required this.runCount,
    required this.unjournaledRunCount,
    required this.foreignRunCount,
    required this.spansOtherPairs,
  });

  final List<_SyncTrashPurgeTarget> _targets;
  final SyncTrashPurgeAdmission _admission;
  final int knownFileCount;
  final int runCount;
  final int unjournaledRunCount;
  final int foreignRunCount;
  final bool spansOtherPairs;

  int get rootCount => _targets.length;
}

/// Aggregate result across every physical root in one confirmed purge.
final class SyncTrashPurgeOutcome {
  const SyncTrashPurgeOutcome({
    required this.purgedRunCount,
    required this.failures,
    required this.cancelled,
  });

  final int purgedRunCount;
  final List<SyncTrashPurgeFailure> failures;
  final bool cancelled;
}

/// The activity registry changed after confirmation, so the purge did
/// not start. The caller should tell the user to retry after sync settles.
final class SyncTrashActiveRunException implements Exception {
  const SyncTrashActiveRunException();
}

final class _SyncTrashTargetState {
  _SyncTrashTargetState({required this.location});

  final SyncTrashLocation location;
  final Set<SyncSide> sides = <SyncSide>{};
  Set<String> activeRunIds = const <String>{};
  SyncEndpoint? endpoint;
  RemoteFileSystem? fileSystem;
  SyncTrashInventory? live;
  TrashCacheEntry? cache;
}

final class _SyncTrashPurgeTarget {
  const _SyncTrashPurgeTarget({
    required this.location,
    required this.endpoint,
    required this.selection,
  });

  final SyncTrashLocation location;
  final SyncEndpoint endpoint;
  final SyncTrashSelection selection;
}

final class _CachedTrashSelection {
  const _CachedTrashSelection({
    required this.knownFileCount,
    required this.runCount,
    required this.unjournaledRunCount,
  });

  final int knownFileCount;
  final int runCount;
  final int unjournaledRunCount;
}

/// The bulk-conflict bar's four decisions (§7).
enum SyncConflictChoice { newerWins, keepLeft, keepRight, skip }

/// The pair editor's per-side case-sensitivity overrides (05 §3/§9 —
/// the remote side's only sensitivity input). A null side means "auto":
/// local sides probe, remote sides assume case-sensitive.
final class SyncCaseOverrides {
  const SyncCaseOverrides({this.left, this.right});
  final bool? left;
  final bool? right;
}

/// What a plan tab does once its first scan settles (D32 §7).
enum SyncPlanIntent {
  /// Simulate, a sidebar reopen, every pre-D32 entry: land on the
  /// review and wait for Run.
  review,

  /// Synchronize: run straight away when the plan deletes nothing,
  /// replaces nothing, and has no conflicts (D32's one exception to 05
  /// §8 rail 1); any other plan holds on the review with a banner
  /// naming why. Only the first scan honors it — a later rescan is a
  /// review like any other.
  synchronize,
}

/// Why Synchronize stopped on the review instead of running — the
/// banner's figures. Built from the EFFECTIVE stats, so unchecking the
/// deletions in the review shrinks (and finally clears) the banner.
final class SyncReviewHold {
  const SyncReviewHold({
    required this.deletes,
    required this.emptyFolders,
    required this.replaces,
    required this.conflicts,
  });

  /// File deletions on either side (05 §8's per-file unit).
  final int deletes;

  /// Empty-directory cleanup rows — zero-weight on the rails, but still
  /// a removal the auto-run must not perform unseen.
  final int emptyFolders;

  /// Overwrites: update rows plus §6 rule-4 kind-change replacements.
  final int replaces;
  final int conflicts;
}

/// Whether [stats] may run without review: null when the plan only
/// creates (new files and folders), otherwise the reasons it may not.
/// Pure so the rule is testable without a controller.
SyncReviewHold? syncAutoRunHold(SyncEffectiveStats stats) {
  var deletes = 0;
  var emptyFolders = 0;
  var replaces = 0;
  for (final side in SyncSide.values) {
    deletes += stats.deletesOn(side);
    emptyFolders += stats.emptyDirsOn(side);
    replaces += stats.updatesTo(side) + (stats.replacedRowsBySide[side] ?? 0);
  }
  final conflicts = stats.conflicts;
  if (deletes == 0 && emptyFolders == 0 && replaces == 0 && conflicts == 0) {
    return null;
  }
  return SyncReviewHold(
    deletes: deletes,
    emptyFolders: emptyFolders,
    replaces: replaces,
    conflicts: conflicts,
  );
}

/// A best-effort read of [pair]'s stored state BEFORE any scan — the
/// Sync sheet's plan sentence wants §4's untrusted-clock flags, but the
/// canonical pairId folds each side's case-sensitivity, which only a
/// scan settles. The four case-fold spellings are tried in turn and the
/// first record that has ever been touched wins; null when the pair has
/// no history (or its id folds Unicode form, which only the scan's
/// cached probe knows — the sentence then simply omits the fallback).
Future<SyncPairState?> loadStoredSyncPairState(
  SyncStateStore states,
  SyncPair pair,
) async {
  const folds = [(false, false), (true, true), (true, false), (false, true)];
  for (final (left, right) in folds) {
    final state = await states.load(
      syncPairId(pair, leftCaseInsensitive: left, rightCaseInsensitive: right),
    );
    if (state.touchedAt != null || state.lastRunAt != null) return state;
  }
  return null;
}

/// A rendered rsync export (05 §2.1) and whether it carries the
/// paste-time permanent-deletion warning.
typedef SyncRsyncExport = ({String text, bool permanentDeletions});

/// §2.1's body for [pair], shared by the plan view (which passes its
/// settled [plan]: manual overrides and scan-derived skip paths) and
/// the Sync sheet (no scan yet: the ruleset alone). [mtimesUntrusted]
/// is §4's sync_state downgrade — it lives outside the ruleset, so the
/// caller resolves it. Null when a remote side does not resolve to a
/// dialable identity; the caller disables the affordance rather than
/// emit a silently wrong command.
SyncRsyncExport? syncRsyncExport(
  SyncPair pair,
  RsyncEndpointResolver resolver, {
  SyncPlan? plan,
  bool mtimesUntrusted = false,
  required DateTime now,
}) {
  final endpoints = resolver(pair);
  if (endpoints == null) return null;
  final downgraded =
      mtimesUntrusted && pair.rules.comparison == ComparisonMode.sizeAndMtime;
  final rules = downgraded
      ? pair.rules.copyWith(comparison: ComparisonMode.sizeOnly)
      : pair.rules;
  return (
    text: buildRsyncCommand(
      endpoints,
      rules,
      manualOverrides:
          plan?.items.where((item) => item.userOverridden).length ?? 0,
      mtimesUntrusted: downgraded,
      engineSkipPaths: plan == null ? const [] : rsyncEngineSkipPaths(plan),
      now: now,
    ),
    permanentDeletions:
        rules.deletions == DeletionPolicy.permanent &&
        rules.backups == BackupPolicy.none,
  );
}

/// The scan seam — production walks through [TreeScanner]; tests feed
/// canned [ScanResult]s. Per-side overrides arrive as arguments: the
/// pair-state rescan path re-probes with them.
abstract interface class SyncPairScanner {
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  });
}

/// The differ seam — production calls the engine's `diffScans`; tests
/// build plans directly.
abstract interface class SyncPlanDiffer {
  Future<SyncPlan> diff(
    ScanResult left,
    ScanResult right,
    SyncPair pair, {
    bool mtimeUnreliableLeft,
    bool mtimeUnreliableRight,
  });
}

/// The controller behind `SyncPlanView`. One instance per open sync
/// tab; the tab owns and disposes it.
final class SyncPlanController extends ChangeNotifier {
  SyncPlanController({
    required SyncPair pair,
    required SyncEnvironment environment,
    required this.syncTasks,
    SyncPairScanner? scanner,
    SyncPlanDiffer? differ,
    this.deviceId = 'local',
    SyncCaseOverrides? caseOverrides,
    SyncPlanIntent intent = SyncPlanIntent.review,
    PreviewCache? previewCache,
    PreviewProducer? previewProducer,
    int Function()? largeDownloadThresholdBytes,
    DateTime Function()? now,
    // Required rather than defaulted to `resolveRsyncEndpoints`: the
    // plain resolver cannot see the shared-mode server catalog, so a
    // construction site that forgot to bind one would silently disable
    // rsync export for every serverConfigId pair. Forcing the argument
    // makes the choice visible (tests pass the plain resolver or a
    // stub; the shell binds the catalog lookup).
    required RsyncEndpointResolver rsyncEndpoints,
  // `_pair`/`_rsyncEndpoints` stay private: initializing formals would
  // make the named parameters unusable outside this library (ui/
  // constructs sessions by `pair:`/`rsyncEndpoints:`).
  // ignore: prefer_initializing_formals
  }) : _pair = pair,
       _environment = environment,
       _pendingCaseOverrides = caseOverrides,
       _autoRunPending = intent == SyncPlanIntent.synchronize,
       // ignore: prefer_initializing_formals
       _previewCache = previewCache,
       // ignore: prefer_initializing_formals
       _previewProducer = previewProducer,
       _largeDownloadThresholdBytes =
           largeDownloadThresholdBytes ??
           (() => defaultLargeDownloadThresholdBytes),
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _rsyncEndpoints = rsyncEndpoints,
       _scanner = scanner ?? _TreeScannerAdapter(environment),
       _differ = differ ?? _EngineDiffer(environment) {
    _environment.trashActivity.addListener(_onTrashActivityChanged);
  }

  SyncPair _pair;
  final SyncEnvironment _environment;

  /// The activity-panel registry this controller reports runs into.
  final SyncQueueTasks syncTasks;
  final SyncPairScanner _scanner;
  final SyncPlanDiffer _differ;
  final PreviewCache? _previewCache;
  final PreviewProducer? _previewProducer;
  final int Function() _largeDownloadThresholdBytes;
  final DateTime Function() _now;

  /// Resolves the pair's server refs to the rsync exporter's
  /// connection-shaped endpoints (rsync_endpoints.dart); the shell
  /// binds the shared-mode catalog lookup, tests inject their own.
  final RsyncEndpointResolver _rsyncEndpoints;

  /// 04 §3.1's device identity — the runId prefix source (05 §6).
  final String deviceId;

  /// Case-sensitivity overrides awaiting application — set by the
  /// constructor (session open) and by [updatePairDefinition] (the
  /// editor's save). Applied onto each freshly loaded pair state so
  /// an override-mismatch rescan's reload cannot drop them, and
  /// persisted under the FINAL pairId — never saved under the
  /// pre-edit one. Null leaves the stored state authoritative.
  SyncCaseOverrides? _pendingCaseOverrides;

  /// [SyncPlanIntent.synchronize] awaiting the first scan — taken by
  /// that scan when it starts, whatever its outcome (a failure, or a
  /// rescan or rules edit superseding it mid-scan), so no other scan's
  /// plan runs unreviewed.
  bool _autoRunPending;

  /// Synchronize stopped on the review — [reviewHold] reads the live
  /// reasons while this holds; a rescan, a run, or a dismissal clears
  /// it.
  bool _holdingForReview = false;

  // -- Session state -----------------------------------------------------

  SyncPlanPhase _phase = SyncPlanPhase.scanning;
  String? _errorMessage;
  RemoteFileErrorKind? _errorKind;
  SyncPlan? _plan;
  SyncEffectiveStats? _stats;
  SyncDeleteAssessment? _assessment;
  String? _pairId;
  SyncPairState _pairState = SyncPairState();
  SyncHeavyDirectorySuggestion? _heavySuggestion;
  int _scanGeneration = 0;
  ScanCancellation? _scanCancellation;
  int _leftScanned = 0;
  int _rightScanned = 0;

  /// The canonicalized roots the last scan produced — the executor and
  /// restore path run under these, never the raw endpoint spellings.
  String? _leftRoot;
  String? _rightRoot;
  bool _leftCaseSensitive = true;
  bool _rightCaseSensitive = true;
  Map<SyncSide, SyncEndpointBinding> _endpointBindings = {};

  /// Actual scan keys for pairs whose case or Unicode form differs by side.
  Map<SyncItem, ({String left, String right})> _comparisonPaths =
      Map.identity();

  /// The plan row D21's contextual compare command resolves at run time.
  SyncItem? _comparisonTarget;

  // -- Run state -----------------------------------------------------------

  SyncExecutor? _executor;
  SyncRun? _lastRun;
  SyncRunPause? _pause;
  RemoteTransferCancellation? _runCancellation;
  SyncTaskBinding? _binding;

  // -- Trash purge state -------------------------------------------------

  Map<SyncSide, SyncTrashLocation> _trashLocations = {};
  Map<SyncTrashLocation, _SyncTrashTargetState> _trashTargets = {};
  Map<SyncSide, RemoteFileException> _trashLocationFailures = {};
  bool _trashLocationResolutionFailed = false;
  Future<void>? _trashInventoryRefresh;
  RemoteTransferCancellation? _trashPurgeCancellation;
  bool _isPurgingTrash = false;
  _SyncPlanOperation? _activeOperation;

  bool _disposed = false;

  // -- Reads the view binds on -------------------------------------------

  SyncPair get pair => _pair;
  SyncPlanPhase get phase => _phase;
  String? get errorMessage => _errorMessage;
  RemoteFileErrorKind? get errorKind => _errorKind;
  SyncPlan? get plan => _plan;
  SyncEffectiveStats? get stats => _stats;
  String? get pairId => _pairId;
  SyncPairState get pairState => _pairState;
  SyncHeavyDirectorySuggestion? get heavySuggestion => _heavySuggestion;
  SyncRun? get lastRun => _lastRun;
  int get leftScanned => _leftScanned;
  int get rightScanned => _rightScanned;
  bool get isRunning => _phase == SyncPlanPhase.running;
  bool get isPaused => _pause?.isPaused ?? false;
  bool get isPurgingTrash => _isPurgingTrash;

  /// Whether an operation currently owns the reviewed pair and plan.
  bool get planMutationsBlocked =>
      _disposed || _activeOperation != null || isRunning || _isPurgingTrash;
  bool get trashPurgeBlocksActions =>
      planMutationsBlocked || _trashRootsPurging;

  /// Plan-time aged-trash notices. Live listings are actionable; cache
  /// fallbacks retain their age label but never authorize deletion.
  List<SyncTrashNotice> get trashNotices {
    final notices = <SyncTrashNotice>[];
    final now = _now();
    for (final target in _trashTargets.values) {
      final active = _activeTrashRunIds(target);
      final live = target.live;
      if (live != null) {
        final selection = live.select(SyncTrashPurgeScope.aged, now, active);
        if (selection.runIds.isEmpty) continue;
        notices.add(
          SyncTrashNotice._(
            location: target.location,
            sides: Set.unmodifiable(target.sides),
            knownFileCount: selection.knownFileCount,
            runCount: selection.runIds.length,
            unjournaledRunCount: selection.unjournaledRunCount,
            listedAt: live.listedAt,
            isStale: false,
            canPurge:
                !_isPurgingTrash &&
                _activeOperation == null &&
                !isRunning &&
                !_environment.trashActivity.hasPurge(target.location),
          ),
        );
        continue;
      }

      final cache = target.cache;
      if (cache == null) continue;
      final selection = _selectCachedTrash(
        cache,
        now,
        active,
        syncRunDevicePrefix(deviceId),
      );
      if (selection.runCount == 0) continue;
      notices.add(
        SyncTrashNotice._(
          location: target.location,
          sides: Set.unmodifiable(target.sides),
          knownFileCount: selection.knownFileCount,
          runCount: selection.runCount,
          unjournaledRunCount: selection.unjournaledRunCount,
          listedAt: cache.lastListedAt,
          isStale: true,
          canPurge: false,
        ),
      );
    }
    return List.unmodifiable(notices);
  }

  /// The explicit command is available only with live trash to remove,
  /// and refuses the whole request if any target root has a local run.
  bool get canPurgeTrash => prepareFullTrashPurge() != null;

  /// Whether the focused plan row can open 06 §6's paired-file view.
  bool get canCompareSelection {
    final target = _comparisonTarget;
    return target != null && comparisonAvailableFor(target);
  }

  /// Why Synchronize did not run this plan on its own (D32 §7's
  /// banner) — live over the effective actions, null once nothing that
  /// needs review remains or the banner was dismissed.
  SyncReviewHold? get reviewHold {
    final stats = _stats;
    if (!_holdingForReview || stats == null || isRunning) return null;
    return syncAutoRunHold(stats);
  }

  void dismissReviewHold() {
    if (!_holdingForReview) return;
    _holdingForReview = false;
    notifyListeners();
  }

  /// The run's rail outcome — reassessed on every effective-action
  /// change so the Run button always describes what would happen NOW.
  SyncRunGate? get gate => _assessment?.gate;

  /// Rail 3's typed `DELETE` is owed before [run] can proceed.
  bool get needsTypedConfirmation =>
      _assessment?.gate is SyncRunNeedsConfirmation;

  /// Rail 4 refuses the plan outright — Run stays disabled and the
  /// banner explains; the plan is never silently stripped.
  SyncRunRefused? get refusal =>
      _assessment?.gate is SyncRunRefused
          ? _assessment!.gate as SyncRunRefused
          : null;

  /// Whether the last run left failed work [retryFailed] can drive.
  bool get canRetryFailed =>
      _lastRun != null &&
      _activeOperation == null &&
      !isRunning &&
      !_trashLocationResolutionFailed &&
      !_trashRootsPurging &&
      !_lastRun!.journal.hasPurgeMarker &&
      _lastRun!.plan.items.any(
        (item) => item.status == SyncItemStatus.failed,
      );

  /// Restore affordance — only while the last run's journal still
  /// holds unrestored trash entries (05 §8 rail 9).
  bool get canRestore =>
      _lastRun != null &&
      _activeOperation == null &&
      !_trashLocationResolutionFailed &&
      !_trashRootsPurging &&
      _lastRun!.journal.hasUnpurgedTrash;

  /// Builds the notice chip's aged selection. A stale notice or an
  /// active run returns null: cached state never becomes deletion input.
  SyncTrashPurgeRequest? prepareTrashPurge(SyncTrashNotice notice) {
    if (_activeOperation != null ||
        _isPurgingTrash ||
        isRunning ||
        !notice.canPurge) {
      return null;
    }
    final target = _trashTargets[notice._location];
    final live = target?.live;
    final endpoint = target?.endpoint;
    final fileSystem = target?.fileSystem;
    if (target == null ||
        live == null ||
        endpoint == null ||
        fileSystem == null) {
      return null;
    }
    final active = _activeTrashRunIds(target);
    final selection = live.select(SyncTrashPurgeScope.aged, _now(), active);
    if (selection.runIds.isEmpty) return null;
    return _trashPurgeRequest([
      _SyncTrashPurgeTarget(
        location: target.location,
        endpoint: endpoint,
        selection: selection,
      ),
    ], SyncTrashPurgeAdmission.excludeActiveRuns);
  }

  /// Builds the explicit command's whole-trash selection. It includes
  /// foreign-prefix runs, but no target may have a local run in flight.
  SyncTrashPurgeRequest? prepareFullTrashPurge() {
    if (_activeOperation != null || _isPurgingTrash || isRunning) return null;
    final targets = <_SyncTrashPurgeTarget>[];
    for (final target in _trashTargets.values) {
      final live = target.live;
      final endpoint = target.endpoint;
      final fileSystem = target.fileSystem;
      if (live == null || endpoint == null || fileSystem == null) continue;
      if (_environment.trashActivity.hasPurge(target.location)) return null;
      final active = _activeTrashRunIds(target);
      if (active.isNotEmpty) return null;
      final selection = live.select(SyncTrashPurgeScope.all, _now(), active);
      if (selection.runIds.isEmpty) continue;
      targets.add(
        _SyncTrashPurgeTarget(
          location: target.location,
          endpoint: endpoint,
          selection: selection,
        ),
      );
    }
    if (targets.isEmpty) return null;
    return _trashPurgeRequest(targets, SyncTrashPurgeAdmission.requireIdle);
  }

  /// Refreshes the command's live scope before the confirmation is
  /// built. The returned selection stays immutable after confirmation.
  Future<SyncTrashPurgeRequest?> prepareFullTrashPurgeLive() async {
    if (_disposed || _activeOperation != null || isRunning || _isPurgingTrash) {
      return null;
    }
    final generation = _scanGeneration;
    await _refreshTrashInventories(generation);
    if (_disposed || generation != _scanGeneration) return null;

    return prepareFullTrashPurge();
  }

  SyncTrashPurgeRequest _trashPurgeRequest(
    List<_SyncTrashPurgeTarget> targets,
    SyncTrashPurgeAdmission admission,
  ) {
    var knownFileCount = 0;
    var runCount = 0;
    var unjournaledRunCount = 0;
    var foreignRunCount = 0;
    var spansOtherPairs = false;
    for (final target in targets) {
      final selection = target.selection;
      knownFileCount += selection.knownFileCount;
      runCount += selection.runIds.length;
      unjournaledRunCount += selection.unjournaledRunCount;
      foreignRunCount += selection.foreignRunCount;
      if (selection.pairIds.any((id) => id != _pairId)) {
        spansOtherPairs = true;
      }
    }
    return SyncTrashPurgeRequest._(
      targets: List.unmodifiable(targets),
      admission: admission,
      knownFileCount: knownFileCount,
      runCount: runCount,
      unjournaledRunCount: unjournaledRunCount,
      foreignRunCount: foreignRunCount,
      spansOtherPairs: spansOtherPairs,
    );
  }

  /// Executes one confirmed selection. Every target re-lists in the
  /// package service; activity is checked again after the dialog race.
  Future<SyncTrashPurgeOutcome> purgeTrash(
    SyncTrashPurgeRequest request,
  ) async {
    if (!_beginOperation(_SyncPlanOperation.purge)) {
      throw const SyncTrashActiveRunException();
    }

    try {
      return await _purgeTrash(request);
    } finally {
      _endOperation(_SyncPlanOperation.purge);
    }
  }

  Future<SyncTrashPurgeOutcome> _purgeTrash(
    SyncTrashPurgeRequest request,
  ) async {
    if (_isPurgingTrash || isRunning || _disposed) {
      throw const SyncTrashActiveRunException();
    }
    final purgeLease = await _environment.trashActivity.tryBeginPurge(
      request._targets.map((target) => target.location),
      request._admission,
    );
    if (purgeLease == null) throw const SyncTrashActiveRunException();
    if (_disposed || isRunning) {
      await purgeLease.close();
      throw const SyncTrashActiveRunException();
    }

    _isPurgingTrash = true;
    _trashPurgeCancellation = RemoteTransferCancellation();
    notifyListeners();
    final purged = <String>[];
    final failures = <SyncTrashPurgeFailure>[];
    var cancelled = false;
    try {
      final service = SyncTrashPurgeService(_environment.syncRunsDirectory);
      for (final target in request._targets) {
        final SyncTrashPurgeReport report;
        try {
          report = await _environment.withVerifiedTrashLocation(
            target.endpoint,
            target.location,
            (fileSystem) => service.purge(
              fileSystem,
              target.selection,
              purgeLease.activeRunIds(target.location),
              _trashPurgeCancellation,
            ),
          );
        } on RemoteFileException catch (error) {
          failures.addAll([
            for (final runId in target.selection.runIds)
              SyncTrashPurgeFailure(runId: runId, message: error.message),
          ]);
          continue;
        } on FileSystemException catch (error) {
          failures.addAll([
            for (final runId in target.selection.runIds)
              SyncTrashPurgeFailure(runId: runId, message: '$error'),
          ]);
          continue;
        }
        purged.addAll(report.purgedRunIds);
        failures.addAll(report.failures);
        _environment.trashActivity.recordPurged(
          report.purgedRunIds,
          target.location.scopeKey,
        );
        if (report.cancelled) {
          cancelled = true;
          break;
        }
      }
      return SyncTrashPurgeOutcome(
        purgedRunCount: purged.length,
        failures: List.unmodifiable(failures),
        cancelled: cancelled,
      );
    } finally {
      _trashPurgeCancellation = null;
      _isPurgingTrash = false;
      try {
        await purgeLease.close();
      } finally {
        unawaited(_environment.releaseRemoteLeases());
        if (!_disposed) notifyListeners();
        if (!_disposed) await _refreshTrashInventories(_scanGeneration);
      }
    }
  }

  void cancelTrashPurge() => _trashPurgeCancellation?.cancel();

  /// Updates the row resolved by the contextual compare command.
  void setComparisonTarget(SyncItem? item) {
    if (identical(_comparisonTarget, item)) return;
    _comparisonTarget = item;
    notifyListeners();
  }

  /// Whether [item] has regular files on both reviewed sides.
  bool comparisonAvailableFor(SyncItem item) {
    final stablePlan = switch (_phase) {
      SyncPlanPhase.ready ||
      SyncPlanPhase.completed ||
      SyncPlanPhase.failed ||
      SyncPlanPhase.cancelled => true,
      SyncPlanPhase.scanning ||
      SyncPlanPhase.running ||
      SyncPlanPhase.error => false,
    };
    return stablePlan &&
        _plan != null &&
        _leftRoot != null &&
        _rightRoot != null &&
        _comparisonPaths.containsKey(item);
  }

  /// Builds the focused row's comparison at command invocation time.
  SyncCompareController? comparisonForSelection() {
    final target = _comparisonTarget;
    return target == null ? null : comparisonFor(target);
  }

  /// Builds 06 §6's comparison from the roots the current scan reviewed.
  /// Configured roots may contain `~` or symlinks and are not authoritative.
  SyncCompareController? comparisonFor(SyncItem item) {
    if (!comparisonAvailableFor(item)) return null;
    final leftRoot = _leftRoot!;
    final rightRoot = _rightRoot!;

    SyncCompareSource source(
      SyncSide side,
      SyncEndpoint endpoint,
      String root,
      String relativePath,
      EntrySnapshot snapshot,
    ) => switch (endpoint) {
      LocalEndpoint() => LocalSyncCompareSource(
        side: side,
        fullPath: p.joinAll([root, ...relativePath.split('/')]),
        snapshot: snapshot,
      ),
      final RemoteEndpoint remote => RemoteSyncCompareSource(
        side: side,
        fullPath: remoteJoin(root, relativePath),
        snapshot: snapshot,
        serverId: _environment.serverIdFor(remote),
      ),
    };

    final paths = _comparisonPaths[item];

    return SyncCompareController(
      request: SyncCompareRequest(
        relativePath: item.relativePath,
        left: source(
          SyncSide.left,
          _pair.left,
          leftRoot,
          paths?.left ?? item.relativePath,
          item.left!,
        ),
        right: source(
          SyncSide.right,
          _pair.right,
          rightRoot,
          paths?.right ?? item.relativePath,
          item.right!,
        ),
      ),
      previewCache: _previewCache,
      previewProducer: _previewProducer,
      largeDownloadThresholdBytes: _largeDownloadThresholdBytes,
    );
  }

  /// The configured per-side trash path, or null (in-root
  /// `.poltergeist-trash` — §8 rail 5's default location text).
  String? trashPathFor(SyncSide side) => switch (side) {
    SyncSide.left => _pair.rules.trashPathLeft,
    SyncSide.right => _pair.rules.trashPathRight,
  };

  /// Whether deletions on [side] land in trash (vs permanently).
  bool deletesToTrash(SyncSide side) =>
      _pair.rules.deletions == DeletionPolicy.trash;

  // -- Lifecycle ---------------------------------------------------------

  /// Kicks off the first scan. Called once by the tab that owns this
  /// controller; idempotent while a scan is already in flight.
  void start() {
    if (_phase != SyncPlanPhase.scanning || _scanCancellation != null) {
      return;
    }
    unawaited(_scanAndDiff());
  }

  /// Full rescan — refresh affordance and every rules edit (excludes,
  /// hidden, trash paths, direction): a fresh walk is the only honest
  /// answer to "the rules changed".
  Future<void> rescan() async {
    if (planMutationsBlocked) return;
    _scanCancellation?.cancel();
    await _scanAndDiff();
  }

  /// Mode-picker changes — direction/deletion policy are rule fields,
  /// so this is the same rescan path [rescan] runs; kept as its own
  /// verb so the view's intent stays legible.
  Future<void> setMode({
    SyncDirection? direction,
    DeletionPolicy? deletions,
  }) async {
    if (planMutationsBlocked) return;
    _pair = _pairWithRules(
      _rulesWith(
        direction: direction,
        deletions: deletions,
      ),
    );
    await rescan();
  }

  /// Options edits that change the walk (excludes, hidden files,
  /// comparison mode, conflict default, trash paths).
  Future<void> updateRules(SyncRuleSet rules) async {
    if (planMutationsBlocked) return;
    _pair = _pairWithRules(rules);
    await rescan();
  }

  /// The pair editor's save (05 §9): swaps the whole definition —
  /// name, endpoints, rules — plus the per-side case-sensitivity
  /// overrides that live in pair state rather than the ruleset, then
  /// rescans. An endpoint edit re-keys `sync_state` by construction
  /// (the canonical pairId is endpoint-derived). Returns false when
  /// an operation already owns the reviewed pair and plan.
  Future<bool> updatePairDefinition(
    SyncPair pair, {
    SyncCaseOverrides? caseOverrides,
  }) async {
    if (planMutationsBlocked) return false;
    _pair = pair;
    // The overrides land on the state the rescan loads — saving under
    // the pre-edit pairId here would write a record the post-edit
    // pairId never sees, and the rescan's load() would discard it.
    _pendingCaseOverrides = caseOverrides;
    await rescan();
    return true;
  }

  /// The heavy-dir suggestion's accept affordance: add `**/{name}/` to
  /// the pair's excludes and rescan (05 §6).
  Future<void> acceptHeavySuggestion() async {
    if (planMutationsBlocked) return;
    final name = _heavySuggestion?.name;
    if (name == null) return;
    _heavySuggestion = null;
    await updateRules(
      _rulesWith(excludeGlobs: [
        ..._pair.rules.excludeGlobs,
        '**/$name/',
      ]),
    );
  }

  void dismissHeavySuggestion() {
    _heavySuggestion = null;
    notifyListeners();
  }

  // -- Overrides ---------------------------------------------------------

  /// The actions a row's glyph/menu may offer (§7): suggested, every
  /// copy direction the item's sides permit, skip, and — for the rows
  /// §7 calls out — delete. Conflicted rows admit both copy directions
  /// regardless of pair direction: the conflict IS the direction
  /// question.
  List<SyncActionType> availableOverrides(SyncItem item) {
    final actions = <SyncActionType>{item.suggested, SyncActionType.skip};
    final leftExists = item.left != null;
    final rightExists = item.right != null;
    final isConflict =
        item.suggested == SyncActionType.conflict ||
        item.effective == SyncActionType.conflict;
    final canLeftToRight =
        leftExists &&
        (isConflict ||
            _pair.rules.direction != SyncDirection.rightToLeft);
    final canRightToLeft =
        rightExists &&
        (isConflict ||
            _pair.rules.direction != SyncDirection.leftToRight);
    if (canLeftToRight) {
      // The destination-kind test picks the action — file-into-dir is
      // §6 rule 4's pre-delete carrier and only valid per-row.
      final dest = item.right;
      actions.add(
        dest == null
            ? SyncActionType.copyLeftToRight
            : dest.kind == EntryKind.directory
            ? SyncActionType.makeDirRight
            : SyncActionType.updateLeftToRight,
      );
    }
    if (canRightToLeft) {
      final dest = item.left;
      actions.add(
        dest == null
            ? SyncActionType.copyRightToLeft
            : dest.kind == EntryKind.directory
            ? SyncActionType.makeDirLeft
            : SyncActionType.updateRightToLeft,
      );
    }
    // Delete offers: Mirror only (§7 — no-delete modes authorize a
    // pre-delete only through the explicit per-row type-change action,
    // which the copy/update offers above already express).
    if (_pair.rules.deletions != DeletionPolicy.none) {
      if (rightExists) actions.add(SyncActionType.deleteRight);
      if (leftExists) actions.add(SyncActionType.deleteLeft);
    }
    return List.unmodifiable(actions);
  }

  /// Applies an effective-action override. Out-of-set actions are
  /// ignored — the menu builds from [availableOverrides], but a stale
  /// menu must never smuggle an invalid action in. No-delete modes
  /// additionally refuse any action whose destination kind differs —
  /// §6 rule 4's pre-delete is only reachable through the type-change
  /// row's own copy/update offer.
  void applyOverride(SyncItem item, SyncActionType action) {
    if (_plan == null || planMutationsBlocked) return;
    if (action == item.suggested) {
      resetOverride(item);
      return;
    }
    if (!availableOverrides(item).contains(action)) return;
    if (_pair.rules.deletions == DeletionPolicy.none &&
        _isTypeChangePreDelete(item, action) &&
        item.reason != SyncReason.typeDiffers) {
      return;
    }
    item.effective = action;
    item.userOverridden = true;
    _reassess();
  }

  /// Back to the differ's proposal.
  void resetOverride(SyncItem item) {
    if (_plan == null || planMutationsBlocked) return;
    item.effective = item.suggested;
    item.userOverridden = false;
    _reassess();
  }

  /// Back to the differ's proposal for every row in [items] — the
  /// review's re-check of a row or a whole section — with one
  /// reassessment.
  void resetOverrides(Iterable<SyncItem> items) {
    if (_plan == null || planMutationsBlocked) return;
    var changed = false;
    for (final item in items) {
      if (!item.userOverridden && item.effective == item.suggested) continue;
      item.effective = item.suggested;
      item.userOverridden = false;
      changed = true;
    }
    if (changed) _reassess();
  }

  /// Bulk conflict decisions (§7's bar). Returns the resolved count —
  /// `newerWins` silently resolves nothing on untrusted clocks (the
  /// bar hides it then), `keepLeft`/`keepRight` skip rows whose source
  /// side is absent.
  int resolveConflicts(SyncConflictChoice choice) {
    if (_plan == null || planMutationsBlocked) return 0;
    var resolved = 0;
    for (final item in _plan!.items) {
      if (item.suggested != SyncActionType.conflict &&
          item.effective != SyncActionType.conflict) {
        continue;
      }
      final action = switch (choice) {
        SyncConflictChoice.skip => SyncActionType.skip,
        SyncConflictChoice.keepLeft =>
          item.left != null ? _keepResolution(item, SyncSide.left) : null,
        SyncConflictChoice.keepRight =>
          item.right != null ? _keepResolution(item, SyncSide.right) : null,
        SyncConflictChoice.newerWins => _newerWinsAction(item),
      };
      if (action == null) continue;
      // The bulk bar follows the bulk-override rules (§7): only the
      // row's offered actions, and in a no-delete mode a rule-4
      // pre-delete stays per-item-only — a typeDiffers row keeps its
      // conflict until the user picks it per-row.
      if (!availableOverrides(item).contains(action)) continue;
      if (_pair.rules.deletions == DeletionPolicy.none &&
          _isTypeChangePreDelete(item, action)) {
        continue;
      }
      item.effective = action;
      item.userOverridden = true;
      resolved++;
    }
    if (resolved > 0) _reassess();
    return resolved;
  }

  /// What the differ's `_keepSide` decides (diff.dart): a one-way pair
  /// never writes its destination side, so keeping that side resolves
  /// to a deliberate skip — never a counter-direction write.
  SyncActionType _keepResolution(SyncItem item, SyncSide keep) {
    final writesRight = keep == SyncSide.left;
    final permitted = switch (_pair.rules.direction) {
      SyncDirection.bidirectional => true,
      SyncDirection.leftToRight => writesRight,
      SyncDirection.rightToLeft => !writesRight,
    };
    if (!permitted) return SyncActionType.skip;
    return _copyAction(
      item,
      keep == SyncSide.left ? SyncSide.right : SyncSide.left,
    );
  }

  SyncActionType _copyAction(SyncItem item, SyncSide destination) {
    final dest = destination == SyncSide.left ? item.left : item.right;
    return switch ((destination, dest)) {
      (SyncSide.right, null) => SyncActionType.copyLeftToRight,
      (SyncSide.left, null) => SyncActionType.copyRightToLeft,
      (SyncSide.right, EntrySnapshot(kind: EntryKind.directory)) =>
        SyncActionType.makeDirRight,
      (SyncSide.left, EntrySnapshot(kind: EntryKind.directory)) =>
        SyncActionType.makeDirLeft,
      (SyncSide.right, _) => SyncActionType.updateLeftToRight,
      (SyncSide.left, _) => SyncActionType.updateRightToLeft,
    };
  }

  SyncActionType? _newerWinsAction(SyncItem item) {
    // §7 hides the button on untrusted clocks — the verb honors the
    // same guard so a direct call can't trust a clock the engine
    // itself flagged.
    if (!offersNewerWins) return null;
    final left = item.left?.mtimeSecs;
    final right = item.right?.mtimeSecs;
    if (left == null || right == null) return null;
    // EntryComparator semantics: out-of-range originals compare
    // clamped, and a delta inside mtimeToleranceSecs (or within
    // tolerance of an accepted shift) is equal — not "newer".
    final (l, r) = sftpMtimeInRange(left) && sftpMtimeInRange(right)
        ? (left, right)
        : (clampSftpMtimeSecs(left), clampSftpMtimeSecs(right));
    final delta = (l - r).abs();
    final tolerance = _pair.rules.mtimeToleranceSecs;
    final equal = delta <= tolerance ||
        _pair.rules.acceptedTimeShifts.any(
          (shift) => (delta - shift).abs() <= tolerance,
        );
    if (equal) return null;
    return _keepResolution(item, l > r ? SyncSide.left : SyncSide.right);
  }

  /// Whether `newerWins` may be offered — §7 hides it when mtimes are
  /// untrusted or `preserveMtime` is off.
  bool get offersNewerWins =>
      _pair.rules.preserveMtime &&
      !_pairState.mtimeUnreliableLeft &&
      !_pairState.mtimeUnreliableRight;

  /// §4's automatic fallback: a `sizeAndMtime` pair with either
  /// `mtimeUnreliable` flag recorded compares `sizeOnly` from then on.
  /// `contentHash` is never downgraded — hashes do not depend on
  /// mtimes — and an explicit `sizeOnly` pair needs no rewrite.
  bool get _downgradesToSizeOnly =>
      _pair.rules.comparison == ComparisonMode.sizeAndMtime &&
      (_pairState.mtimeUnreliableLeft || _pairState.mtimeUnreliableRight);

  /// The `sync.copyRsyncCommand` enablement probe (05 §2.1): true when
  /// [rsyncExport] would produce text — a settled plan exists and every
  /// remote side resolves. Cheap: no string is built.
  bool get canExportRsync =>
      _exportablePlan != null && _rsyncEndpoints(_pair) != null;

  /// The plan export may quote: settled only. During `scanning`/`error`
  /// `_plan` can hold a PREVIOUS scan's result while `_pair.rules` have
  /// already moved on — exporting the mix would render new rules against
  /// a stale plan's skip paths.
  SyncPlan? get _exportablePlan => switch (_phase) {
    SyncPlanPhase.scanning || SyncPlanPhase.error => null,
    _ => _plan,
  };

  /// §2.1's "Copy as rsync command" body: the EFFECTIVE ruleset
  /// rendered as the commented rsync block — §4's `mtimeUnreliable`
  /// downgrade resolved here because it lives in sync_state, outside
  /// the ruleset. Null when there is no plan yet or a remote side's
  /// `serverConfigId` resolves to nothing (shared-mode catalog not
  /// pulled) — the caller hides the affordance rather than emit a
  /// silently wrong command. [now] is a seam so the timestamped
  /// backup-dir stays deterministic under test.
  SyncRsyncExport? rsyncExport({DateTime? now}) {
    final plan = _exportablePlan;
    if (plan == null) return null;
    return syncRsyncExport(
      _pair,
      _rsyncEndpoints,
      plan: plan,
      mtimesUntrusted: _downgradesToSizeOnly,
      now: now ?? DateTime.now(),
    );
  }

  /// Bulk override on a multi-selection (§7: same menu). Returns the
  /// rows the action could not apply to — Update/Additive bulk copies
  /// skip type-different rows rather than authorizing a pre-delete the
  /// user never saw per-row.
  List<SyncItem> applyOverrideTo(
    Iterable<SyncItem> items,
    SyncActionType action,
  ) {
    if (_plan == null || planMutationsBlocked) return const [];
    final skipped = <SyncItem>[];
    var changed = false;
    for (final item in items) {
      if (action == item.suggested) {
        if (item.userOverridden) {
          item.effective = item.suggested;
          item.userOverridden = false;
          changed = true;
        }
        continue;
      }
      if (!availableOverrides(item).contains(action) ||
          (_pair.rules.deletions == DeletionPolicy.none &&
              _isTypeChangePreDelete(item, action))) {
        skipped.add(item);
        continue;
      }
      item.effective = action;
      item.userOverridden = true;
      changed = true;
    }
    if (changed) _reassess();
    return List.unmodifiable(skipped);
  }

  /// Whether the item's EFFECTIVE action carries a §6 rule-4
  /// pre-delete — the Deletes filter bucket and chip count these rows
  /// with their removed-file toll (§7's badge bookkeeping).
  bool itemCarriesPreDelete(SyncItem item) =>
      _isTypeChangePreDelete(item, item.effective);

  /// §6 rule 4's test: the effective action creates/copies over a
  /// destination of a different kind, which the executor will
  /// pre-delete.
  bool _isTypeChangePreDelete(SyncItem item, SyncActionType action) {
    final dest = switch (action) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.right,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.left,
      _ => null,
    };
    final src = switch (action) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.left,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.right,
      _ => null,
    };
    if (dest == null || src == null) return false;
    final createsDir = src.kind == EntryKind.directory;
    return createsDir
        ? dest.kind != EntryKind.directory
        : dest.kind != EntryKind.file;
  }

  /// Every override-backed mutation lands here: recompute the
  /// override-aware figures and the rails the run button reads.
  void _reassess() {
    final plan = _plan;
    if (plan == null) return;
    _stats = computeSyncEffectiveStats(plan);
    _assessment = assessDeletions(plan);
    notifyListeners();
  }

  /// Refreshes one live, non-recursive inventory per physical root.
  /// Listing failures retain the newest per-side cache and never fail
  /// the plan; a live result replaces both sides' cache when they share.
  Future<void> _refreshTrashInventories(int generation) {
    late final Future<void> tracked;
    tracked = _refreshTrashInventoriesImpl(generation).whenComplete(() {
      if (identical(_trashInventoryRefresh, tracked)) {
        _trashInventoryRefresh = null;
      }
    });
    _trashInventoryRefresh = tracked;
    return tracked;
  }

  Future<void> _refreshTrashInventoriesImpl(int generation) async {
    final targets = <SyncTrashLocation, _SyncTrashTargetState>{};
    for (final side in SyncSide.values) {
      final endpoint = side == SyncSide.left ? _pair.left : _pair.right;
      final location = _trashLocations[side];
      if (location == null) continue;
      final target = targets.putIfAbsent(
        location,
        () => _SyncTrashTargetState(location: location),
      );
      target.sides.add(side);
      if (location.isResolved) {
        try {
          if (target.fileSystem == null) {
            target.fileSystem = _environment.fileSystemFor(endpoint);
            target.endpoint = endpoint;
          }
        } on RemoteFileException {
          // The stale cache below remains visible for an unavailable side.
        }
      }
      final cache = switch (side) {
        SyncSide.left => _pairState.trashCacheLeft,
        SyncSide.right => _pairState.trashCacheRight,
      };
      if (cache != null &&
          (cache.locationKey == null ||
              cache.locationKey == location.locationKey) &&
          (target.cache == null ||
              cache.lastListedAt.isAfter(target.cache!.lastListedAt))) {
        target.cache = cache;
      }
    }
    if (_disposed || generation != _scanGeneration) return;
    _trashTargets = targets;
    notifyListeners();

    final now = _now();
    final prefix = syncRunDevicePrefix(deviceId);
    var leftCacheChanged = false;
    var rightCacheChanged = false;
    final service = SyncTrashPurgeService(_environment.syncRunsDirectory);
    for (final target in targets.values) {
      final fileSystem = target.fileSystem;
      final endpoint = target.endpoint;
      if (fileSystem == null || endpoint == null) continue;
      SyncTrashPurgeLease? inventoryLease;
      try {
        // Inspection can release absent journals, so it shares the purge
        // gate and sees active markers held by other app processes.
        inventoryLease = await _environment.trashActivity.tryBeginPurge([
          target.location,
        ], SyncTrashPurgeAdmission.excludeActiveRuns);
        if (_disposed || generation != _scanGeneration) return;
        if (inventoryLease == null) continue;
        final activeRunIds = inventoryLease.activeRunIds(target.location);
        target.activeRunIds = activeRunIds;
        final inventory = await _environment.withVerifiedTrashLocation(
          endpoint,
          target.location,
          (verifiedFileSystem) => service.inspect(
            verifiedFileSystem,
            target.location.trashRoot,
            prefix,
            now,
            trashScope: target.location.scopeKey,
            pathStyle: target.location.pathStyle,
            pathCase: target.location.pathCase,
            isActiveRun: activeRunIds.contains,
            isCancelled: () =>
                _disposed ||
                generation != _scanGeneration ||
                (_scanCancellation?.isCancelled ?? false),
            onPurgedRun: (runId) => _environment.trashActivity.recordPurged([
              runId,
            ], target.location.scopeKey),
          ),
        );
        if (_disposed || generation != _scanGeneration) return;
        target.live = inventory;
        target.cache = inventory.toCache(
          locationKey: target.location.locationKey,
        );
        for (final side in target.sides) {
          switch (side) {
            case SyncSide.left:
              _pairState.trashCacheLeft = target.cache;
              leftCacheChanged = true;
            case SyncSide.right:
              _pairState.trashCacheRight = target.cache;
              rightCacheChanged = true;
          }
        }
      } on RemoteFileException catch (_) {
        // A plan is still useful when its trash side cannot be listed.
      } on FileSystemException catch (_) {
        // Journal I/O is advisory at plan time; retain the stale cache.
      } on SyncTrashActivityLockException catch (_) {
        // Lock failure is fail-closed: retain the stale cache and plan.
      } finally {
        try {
          await inventoryLease?.close();
        } on SyncTrashActivityLockException catch (_) {
          // The registry remains closed locally when unlock is uncertain.
        }
      }
    }
    if (_disposed || generation != _scanGeneration) return;
    final pairId = _pairId;
    if ((leftCacheChanged || rightCacheChanged) && pairId != null) {
      try {
        // Merge only the refreshed cache fields into the newest record;
        // another plan tab may have updated run or clock state meanwhile.
        final latest = await _environment.states.load(pairId);
        if (_disposed || generation != _scanGeneration) return;
        if (leftCacheChanged) {
          latest.trashCacheLeft = _pairState.trashCacheLeft;
        }
        if (rightCacheChanged) {
          latest.trashCacheRight = _pairState.trashCacheRight;
        }
        await _environment.states.save(pairId, latest);
        if (_disposed || generation != _scanGeneration) return;
      } on Object {
        // The cache is advisory. Persistence failure cannot fail a plan.
      }
    }
    notifyListeners();
  }

  Set<String> _activeTrashRunIds(_SyncTrashTargetState target) => {
    ...target.activeRunIds,
    ..._environment.trashActivity.activeRunIds(target.location),
  };

  Future<void> _resolveTrashLocations(int generation) async {
    final locations = <SyncSide, SyncTrashLocation>{};
    final failures = <SyncSide, RemoteFileException>{};
    var failed = false;
    for (final side in SyncSide.values) {
      final endpoint = side == SyncSide.left ? _pair.left : _pair.right;
      if (!_environment.endpointAvailable(endpoint)) continue;
      final root = side == SyncSide.left ? _leftRoot : _rightRoot;
      if (root == null) continue;
      final pathCase =
          (side == SyncSide.left ? _leftCaseSensitive : _rightCaseSensitive)
          ? SyncTrashPathCase.sensitive
          : SyncTrashPathCase.insensitive;
      try {
        final location = await _environment.resolveTrashLocation(
          endpoint: endpoint,
          canonicalRoot: root,
          rules: _pair.rules,
          side: side,
          pathCase: pathCase,
        );
        if (_disposed || generation != _scanGeneration) return;
        locations[side] = location;
      } on RemoteFileException catch (error) {
        failed = true;
        failures[side] = error;
        locations[side] = await _environment.trashLocationFor(
          endpoint: endpoint,
          canonicalRoot: root,
          rules: _pair.rules,
          side: side,
          pathCase: pathCase,
        );
      } on SyncTrashActivityLockException catch (error) {
        failed = true;
        failures[side] = _trashLocationFailure(side, root, error);
        locations[side] = await _environment.trashLocationFor(
          endpoint: endpoint,
          canonicalRoot: root,
          rules: _pair.rules,
          side: side,
          pathCase: pathCase,
        );
      } on SyncTrashPurgeInProgressException catch (error) {
        failed = true;
        failures[side] = _trashLocationFailure(side, root, error);
        locations[side] = await _environment.trashLocationFor(
          endpoint: endpoint,
          canonicalRoot: root,
          rules: _pair.rules,
          side: side,
          pathCase: pathCase,
        );
      }
    }
    if (_disposed || generation != _scanGeneration) return;

    _trashLocations = locations;
    _trashLocationFailures = failures;
    _trashLocationResolutionFailed = failed;
  }

  RemoteFileException _trashLocationFailure(
    SyncSide side,
    String path,
    Object cause,
  ) => RemoteFileException(
    kind: RemoteFileErrorKind.other,
    operation: 'resolve sync trash',
    path: path,
    message: 'Sync trash on the ${side.name} side is unavailable: $cause',
  );

  void _onTrashActivityChanged() {
    if (_disposed) return;
    final run = _lastRun;
    if (run != null) {
      for (final scope in _environment.trashActivity.purgedTrashScopes(
        run.runId,
      )) {
        run.journal.noteTrashScopePurged(scope);
      }
    }
    notifyListeners();
  }

  // -- Scan → diff -------------------------------------------------------

  Future<void> _scanAndDiff() async {
    final generation = ++_scanGeneration;
    // Synchronize was granted for exactly this plan: the first scan
    // takes the intent, and a scan that supersedes it (the user edited
    // the rules, flipped the mode, or rescanned) starts without it.
    final autoRun = _autoRunPending;
    _autoRunPending = false;
    _scanCancellation = ScanCancellation();
    // A rescan renders a NEW plan — the previous run's journal/retry
    // belong to the plan the user is no longer reviewing (rail 1).
    _lastRun = null;
    _binding?.retry = null;
    _holdingForReview = false;
    _comparisonTarget = null;
    _endpointBindings = {};
    _trashLocations = {};
    _trashTargets = {};
    _trashLocationFailures = {};
    _trashLocationResolutionFailed = false;
    _phase = SyncPlanPhase.scanning;
    _errorMessage = null;
    _errorKind = null;
    _leftScanned = 0;
    _rightScanned = 0;
    notifyListeners();
    try {
      var leftScan = await _scanSide(SyncSide.left, _scanCancellation!);
      var rightScan = await _scanSide(SyncSide.right, _scanCancellation!);
      if (_disposed || generation != _scanGeneration) return;
      var left = leftScan.result;
      var right = rightScan.result;
      _leftRoot = left.rootPath;
      _rightRoot = right.rootPath;
      _pairId = _computePairId(left, right);
      _pairState = await _environment.states.load(_pairId!);
      // A definition-time override (pair editor) supersedes the stored
      // flags — the editor is the remote side's only sensitivity input.
      _applyPendingCaseOverrides();
      // A stored per-side override that disagrees with the scan's
      // answer rescans that side under the override — once — and the
      // pairId settles on the override answers.
      final leftOverride = _pairState.caseSensitiveOverrideLeft;
      final rightOverride = _pairState.caseSensitiveOverrideRight;
      if ((leftOverride != null && leftOverride != left.caseSensitive) ||
          (rightOverride != null && rightOverride != right.caseSensitive)) {
        leftScan = await _scanSide(
          SyncSide.left,
          _scanCancellation!,
          caseSensitivityOverride: leftOverride,
        );
        rightScan = await _scanSide(
          SyncSide.right,
          _scanCancellation!,
          caseSensitivityOverride: rightOverride,
        );
        if (_disposed || generation != _scanGeneration) return;
        left = leftScan.result;
        right = rightScan.result;
        _leftRoot = left.rootPath;
        _rightRoot = right.rootPath;
        _pairId = _computePairId(left, right);
        _pairState = await _environment.states.load(_pairId!);
        // The reload returned a different state record — re-apply the
        // pending overrides so they persist under this pairId.
        _applyPendingCaseOverrides();
      }
      _endpointBindings = {
        if (leftScan.endpointBinding != null)
          SyncSide.left: leftScan.endpointBinding!,
        if (rightScan.endpointBinding != null)
          SyncSide.right: rightScan.endpointBinding!,
      };
      _leftCaseSensitive = left.caseSensitive;
      _rightCaseSensitive = right.caseSensitive;
      _pairState.touchedAt = DateTime.now().toUtc();
      await _environment.states.save(_pairId!, _pairState);
      _pendingCaseOverrides = null;
      _plan = await _differ.diff(
        left,
        right,
        // §4's automatic fallback lives in sync_state, outside the
        // ruleset — resolve it here exactly as rsyncExport does, so a
        // flagged pair's next plan compares size-only instead of
        // re-proposing every refused stamp as an update forever.
        _downgradesToSizeOnly
            ? _pairWithRules(
                _rulesWith(comparison: ComparisonMode.sizeOnly),
              )
            : _pair,
        mtimeUnreliableLeft: _pairState.mtimeUnreliableLeft,
        mtimeUnreliableRight: _pairState.mtimeUnreliableRight,
      );
      if (_disposed || generation != _scanGeneration) return;
      _comparisonPaths = _captureComparisonPaths(_plan!, left, right);
      _suggestHeavyDirectory();
      await _resolveTrashLocations(generation);
      if (_disposed || generation != _scanGeneration) return;
      _phase = SyncPlanPhase.ready;
      _reassess();
      final trashRefresh = _refreshTrashInventories(generation);
      if (autoRun) _settleAutoRun();
      await trashRefresh;
      if (_disposed || generation != _scanGeneration) return;
    } catch (error) {
      if (_disposed || generation != _scanGeneration) return;
      _phase = SyncPlanPhase.error;
      _errorMessage = error is RemoteFileException
          ? error.message
          : error.toString();
      _errorKind = error is RemoteFileException
          ? error.kind
          : RemoteFileErrorKind.other;
      notifyListeners();
    } finally {
      if (generation == _scanGeneration) {
        _scanCancellation = null;
        // The scan settled: its remote leases go back to the pool (the
        // next scan, diff hash, or run leases again on demand).
        unawaited(_environment.releaseRemoteLeases());
      }
    }
  }

  Map<SyncItem, ({String left, String right})> _captureComparisonPaths(
    SyncPlan plan,
    ScanResult left,
    ScanResult right,
  ) {
    final leftPaths = Map<EntrySnapshot, String>.identity();
    final rightPaths = Map<EntrySnapshot, String>.identity();
    for (final entry in left.entries.entries) {
      leftPaths[entry.value] = entry.key;
    }
    for (final entry in right.entries.entries) {
      rightPaths[entry.value] = entry.key;
    }

    // The differ carries each scan snapshot into its row. Identity recovers
    // the original side spelling without duplicating the engine's match rules.
    final paths = Map<SyncItem, ({String left, String right})>.identity();
    for (final item in plan.items) {
      final leftSnapshot = item.left;
      final rightSnapshot = item.right;
      if (leftSnapshot?.kind != EntryKind.file ||
          rightSnapshot?.kind != EntryKind.file) {
        continue;
      }

      paths[item] = (
        left: leftPaths[leftSnapshot!] ?? item.relativePath,
        right: rightPaths[rightSnapshot!] ?? item.relativePath,
      );
    }
    return paths;
  }

  Future<({ScanResult result, SyncEndpointBinding? endpointBinding})> _scanSide(
    SyncSide side,
    ScanCancellation cancellation, {
    bool? caseSensitivityOverride,
  }) async {
    final endpoint = side == SyncSide.left ? _pair.left : _pair.right;
    final result = await _scanner.scan(
      endpoint,
      side,
      _pair.rules,
      caseSensitivityOverride: caseSensitivityOverride,
      cancellation: cancellation,
      onProgress: (count) {
        if (side == SyncSide.left) {
          _leftScanned = count;
        } else {
          _rightScanned = count;
        }
        if (!_disposed) notifyListeners();
      },
    );
    final endpointBinding = _environment.endpointAvailable(endpoint)
        ? await _environment.endpointBindingAfterAccess(endpoint)
        : null;

    return (result: result, endpointBinding: endpointBinding);
  }

  /// §9: the pairId's fold flags settle from THIS scan's
  /// case-sensitivity answers. Normalization insensitivity rides the
  /// probe record in pair state — the scan reports no form verdict of
  /// its own, so the flags come from the cached record only. One
  /// helper for both call sites so the override-mismatch recompute
  /// cannot drop a flag the first computation passed.
  String _computePairId(ScanResult left, ScanResult right) => syncPairId(
    _pair,
    leftCaseInsensitive: !left.caseSensitive,
    rightCaseInsensitive: !right.caseSensitive,
    leftNormalizationInsensitive: _pairState
            .caseProbe[left.rootPath]
            ?.normalizationInsensitive ??
        false,
    rightNormalizationInsensitive: _pairState
            .caseProbe[right.rootPath]
            ?.normalizationInsensitive ??
        false,
  );

  /// Writes the pending definition-time overrides onto the loaded
  /// pair state — a null side clears the stored flag (the editor's
  /// 'auto' choice is authoritative).
  void _applyPendingCaseOverrides() {
    final pending = _pendingCaseOverrides;
    if (pending == null) return;
    _pairState.caseSensitiveOverrideLeft = pending.left;
    _pairState.caseSensitiveOverrideRight = pending.right;
  }

  /// First-run suggestion (§9): a known heavy name covering more than
  /// half the actionable items.
  void _suggestHeavyDirectory() {
    _heavySuggestion = null;
    final plan = _plan;
    if (plan == null || _pairState.lastRunAt != null) return;
    const names = {'node_modules', '.git', 'build', 'target', '__pycache__'};
    final actionable = plan.items
        .where(
          (item) =>
              item.effective != SyncActionType.skip &&
              item.effective != SyncActionType.conflict,
        )
        .toList();
    if (actionable.length < 10) return;
    final perName = <String, int>{};
    for (final item in actionable) {
      for (final segment in item.relativePath.split('/')) {
        if (names.contains(segment)) {
          perName[segment] = (perName[segment] ?? 0) + 1;
          break;
        }
      }
    }
    for (final entry in perName.entries) {
      if (entry.value * 2 > actionable.length) {
        _heavySuggestion = SyncHeavyDirectorySuggestion(
          name: entry.key,
          itemCount: entry.value,
        );
        return;
      }
    }
  }

  /// Synchronize's post-scan step (D32 §7): a creates-only plan whose
  /// gate is clear runs now; anything else holds on the review with
  /// the reason banner. A plan with nothing to do simply rests on its
  /// "Both sides match" state.
  void _settleAutoRun() {
    final stats = _stats;
    if (stats == null || !stats.hasWork) return;
    if (syncAutoRunHold(stats) == null && gate is SyncRunClear) {
      unawaited(run());
      return;
    }
    _holdingForReview = true;
    notifyListeners();
  }

  // -- Run ---------------------------------------------------------------

  /// Runs the reviewed plan. The typed confirmation is a VIEW concern:
  /// when [needsTypedConfirmation] the view collects `DELETE` first and
  /// calls [run] with [deleteConfirmed]; a call without it re-surfaces
  /// the gate rather than executing.
  Future<void> run({bool deleteConfirmed = false}) {
    if (_phase == SyncPlanPhase.scanning ||
        _phase == SyncPlanPhase.error ||
        _phase == SyncPlanPhase.running) {
      return Future.value();
    }
    if (!_beginOperation(_SyncPlanOperation.run)) return Future.value();

    final operation = _run(
      deleteConfirmed: deleteConfirmed,
    ).whenComplete(() => _endOperation(_SyncPlanOperation.run));
    return syncTasks.trackSettlingRun(operation);
  }

  Future<void> _run({required bool deleteConfirmed}) async {
    final generation = _scanGeneration;
    final plan = _plan;
    if (plan == null || _disposed) return;
    await _trashInventoryRefresh;
    if (!_operationCanContinue(_SyncPlanOperation.run, generation) ||
        !identical(_plan, plan) ||
        _isPurgingTrash ||
        _trashRootsPurging) {
      return;
    }
    _reassess();
    if (_assessment!.gate is SyncRunRefused) return;
    if (_assessment!.gate is SyncRunNeedsConfirmation &&
        !deleteConfirmed) {
      notifyListeners();
      return;
    }
    _phase = SyncPlanPhase.running;
    _holdingForReview = false;
    _pause = SyncRunPause();
    _runCancellation = RemoteTransferCancellation();
    // A fresh run supersedes the previous task row — its retry verb
    // must not keep routing into the newest _lastRun.
    _binding?.retry = null;
    notifyListeners();
    SyncTrashActivityLease? trashLease;
    try {
      await _ensureRunTrashLocations(plan);
      if (!_operationCanContinue(_SyncPlanOperation.run, generation) ||
          !identical(_plan, plan)) {
        return;
      }

      final runId = _buildExecutor().mintRunId();
      trashLease = await _environment.trashActivity.begin(
        runId,
        _runTrashLocations(),
      );
      if (!_operationCanContinue(_SyncPlanOperation.run, generation)) return;
      final ran = await _environment.withVerifiedEndpointBindings(
        _runEndpointBindings(),
        (fileSystems) async {
          if (!_operationCanContinue(_SyncPlanOperation.run, generation)) {
            return false;
          }
          final executor = _buildExecutor(
            leftFileSystem: fileSystems[0],
            rightFileSystem: fileSystems[1],
          );
          _executor = executor;
          _binding = syncTasks.beginTask(
            spec: _taskSpec(),
            plan: plan,
            pause: _pause!,
            cancellation: _runCancellation!,
            retry: retryFailed,
          );
          final run = await executor.run(
            plan,
            pairId: _pairId ?? _pair.id,
            runId: runId,
            deleteConfirmationAcknowledged: deleteConfirmed,
            cancellation: _runCancellation,
            pause: _pause,
            onEvent: _onRunEvent,
          );
          _lastRun = run;
          // A cancelled run is not a sync — 'last synced', the heavy-dir
          // suppression, and the 90-day ad-hoc prune key on real work.
          if (!run.cancelled) {
            _pairState.lastRunAt = DateTime.now().toUtc();
          }
          // Persist what write-back verification observed, not its inputs.
          _pairState.mtimeUnreliableLeft = run.mtimeUnreliableLeft;
          _pairState.mtimeUnreliableRight = run.mtimeUnreliableRight;
          _pairState.touchedAt = DateTime.now().toUtc();
          await _environment.states.save(_pairId ?? _pair.id, _pairState);
          if (_disposed) return false;
          _finishRunPhase(run);
          return true;
        },
      );
      if (!ran) return;
      await trashLease.close();
      trashLease = null;
      if (_disposed) return;
      await _refreshTrashInventories(_scanGeneration);
      if (_disposed) return;
      notifyListeners();
    } on SyncRunRefusedException catch (refused) {
      // Rail 4 re-checked inside the executor — surface the refusal,
      // never a stripped run.
      _phase = SyncPlanPhase.ready;
      _assessment = SyncDeleteAssessment(
        removals: _assessment?.removals ?? const {},
        sideEntries: _assessment?.sideEntries ?? const {},
        gate: refused.gate,
      );
      notifyListeners();
    } on SyncConfirmationRequiredException {
      // The gate tripped between the dialog and the run — re-render
      // the confirmation requirement.
      _phase = SyncPlanPhase.ready;
      _reassess();
    } on SyncTrashPurgeInProgressException {
      _phase = SyncPlanPhase.ready;
      notifyListeners();
    } catch (error) {
      if (_disposed) return;
      _phase = SyncPlanPhase.failed;
      _errorMessage = error is RemoteFileException
          ? error.message
          : error.toString();
      _binding?.emitTaskState(
        TransferTaskState.failed,
        error: _errorMessage,
      );
      notifyListeners();
    } finally {
      try {
        await trashLease?.close();
      } finally {
        unawaited(_environment.releaseRemoteLeases());
      }
    }
  }

  /// §8's Retry Failed — same run id's next attempt through
  /// `SyncExecutor.retryFailed`; the panel's retry verb lands here too.
  Future<void> retryFailed() {
    if (!_beginOperation(_SyncPlanOperation.retry)) return Future.value();

    final operation = _retryFailed().whenComplete(
      () => _endOperation(_SyncPlanOperation.retry),
    );
    return syncTasks.trackSettlingRun(operation);
  }

  Future<void> _retryFailed() async {
    final generation = _scanGeneration;
    var lastRun = _lastRun;
    if (_executor == null ||
        lastRun == null ||
        lastRun.journal.hasPurgeMarker ||
        isRunning ||
        _isPurgingTrash ||
        _trashLocationResolutionFailed ||
        _trashRootsPurging ||
        _disposed) {
      return;
    }
    SyncTrashActivityLease? trashLease;
    try {
      // Reserve and revalidate inside the reported operation so a changed
      // root becomes a failed task, never an unhandled UI future.
      trashLease = await _environment.trashActivity.begin(
        lastRun.journal.record.runId,
        _runTrashLocations(),
      );
      if (!_operationCanContinue(_SyncPlanOperation.retry, generation)) return;
      final retried = await _environment.withVerifiedEndpointBindings(
        _runEndpointBindings(),
        (fileSystems) async {
          if (!_operationCanContinue(_SyncPlanOperation.retry, generation)) {
            return false;
          }
          lastRun = await _reopenRun(lastRun!);
          if (!_operationCanContinue(_SyncPlanOperation.retry, generation)) {
            return false;
          }
          if (lastRun!.journal.hasPurgeMarker) {
            if (!_disposed) notifyListeners();
            return false;
          }

          _phase = SyncPlanPhase.running;
          _pause = SyncRunPause();
          _runCancellation = RemoteTransferCancellation();
          // Fresh controls make the panel drive this attempt, not the last.
          _binding?.rebind(pause: _pause!, cancellation: _runCancellation!);
          _binding?.emitTaskState(TransferTaskState.running);
          notifyListeners();

          final executor = _buildExecutor(
            leftFileSystem: fileSystems[0],
            rightFileSystem: fileSystems[1],
          );
          _executor = executor;
          final run = await executor.retryFailed(
            lastRun!,
            pause: _pause,
            cancellation: _runCancellation,
            onEvent: _onRunEvent,
          );
          _lastRun = run;
          if (!run.cancelled) {
            _pairState.lastRunAt = DateTime.now().toUtc();
          }
          _pairState.mtimeUnreliableLeft = run.mtimeUnreliableLeft;
          _pairState.mtimeUnreliableRight = run.mtimeUnreliableRight;
          _pairState.touchedAt = DateTime.now().toUtc();
          await _environment.states.save(_pairId ?? _pair.id, _pairState);
          if (_disposed) return false;
          _finishRunPhase(run);
          return true;
        },
      );
      if (!retried) return;
      await trashLease.close();
      trashLease = null;
      if (_disposed) return;
      await _refreshTrashInventories(_scanGeneration);
      if (_disposed) return;
      notifyListeners();
    } on SyncTrashPurgeInProgressException {
      return;
    } catch (error) {
      if (_disposed) return;
      _phase = SyncPlanPhase.failed;
      _errorMessage = error is RemoteFileException
          ? error.message
          : error.toString();
      _binding?.emitTaskState(
        TransferTaskState.failed,
        error: _errorMessage,
      );
      notifyListeners();
    } finally {
      try {
        await trashLease?.close();
      } finally {
        unawaited(_environment.releaseRemoteLeases());
      }
    }
  }

  /// A run's terminal phase — cancelled beats per-item failures (a
  /// cancelled run's pending items flip skipped, not failed).
  void _finishRunPhase(SyncRun run) {
    final failed = run.plan.items.any(
      (item) =>
          item.status == SyncItemStatus.failed ||
          item.status == SyncItemStatus.conflicted,
    );
    _phase = run.cancelled
        ? SyncPlanPhase.cancelled
        : failed
        ? SyncPlanPhase.failed
        : SyncPlanPhase.completed;
    _binding?.emitTaskState(
      switch (_phase) {
        SyncPlanPhase.completed => TransferTaskState.completed,
        SyncPlanPhase.cancelled => TransferTaskState.cancelled,
        _ => TransferTaskState.failed,
      },
      error: failed ? _firstItemError(run) : null,
    );
  }

  String? _firstItemError(SyncRun run) {
    for (final item in run.plan.items) {
      if (item.status == SyncItemStatus.failed) return item.error;
    }
    return null;
  }

  /// Rail 9's restore: trashed/backed-up files return to their
  /// journaled origins, conflict-checked against post-state.
  Future<SyncRestoreReport> restoreTrashed() {
    if (!_beginOperation(_SyncPlanOperation.restore)) {
      return Future.value(const SyncRestoreReport(restored: [], skipped: []));
    }

    return _restoreTrashed().whenComplete(
      () => _endOperation(_SyncPlanOperation.restore),
    );
  }

  Future<SyncRestoreReport> _restoreTrashed() async {
    final generation = _scanGeneration;
    final run = _lastRun;
    final leftEndpoint = _pair.left;
    final rightEndpoint = _pair.right;
    final leftRoot = _leftRoot;
    final rightRoot = _rightRoot;
    if (run == null ||
        isRunning ||
        _isPurgingTrash ||
        _trashLocationResolutionFailed ||
        _trashRootsPurging) {
      return const SyncRestoreReport(restored: [], skipped: []);
    }
    final SyncTrashActivityLease trashLease;
    try {
      trashLease = await _environment.trashActivity.begin(
        run.runId,
        _runTrashLocations(),
      );
    } on SyncTrashPurgeInProgressException {
      return const SyncRestoreReport(restored: [], skipped: []);
    }
    try {
      if (!_operationCanContinue(_SyncPlanOperation.restore, generation)) {
        return const SyncRestoreReport(restored: [], skipped: []);
      }
      return await _environment.withVerifiedEndpointBindings(
        [
          (
            endpoint: leftEndpoint,
            location: _resolvedTrashLocation(SyncSide.left),
            endpointBinding: _endpointBindings[SyncSide.left],
          ),
          (
            endpoint: rightEndpoint,
            location: _resolvedTrashLocation(SyncSide.right),
            endpointBinding: _endpointBindings[SyncSide.right],
          ),
        ],
        (fileSystems) async {
          if (!_operationCanContinue(_SyncPlanOperation.restore, generation)) {
            return const SyncRestoreReport(restored: [], skipped: []);
          }
          final reopened = await _reopenRun(run);
          if (!_operationCanContinue(_SyncPlanOperation.restore, generation)) {
            return const SyncRestoreReport(restored: [], skipped: []);
          }
          if (!reopened.journal.hasUnpurgedTrash) {
            notifyListeners();
            return const SyncRestoreReport(restored: [], skipped: []);
          }

          return restoreTrashedFiles(
            reopened.journal,
            fsFor: (side) => fileSystems[side == SyncSide.left ? 0 : 1],
            rootFor: (side) =>
                (side == SyncSide.left ? leftRoot : rightRoot) ??
                _environment.rootFor(
                  side == SyncSide.left ? leftEndpoint : rightEndpoint,
                ),
          );
        },
      );
    } finally {
      try {
        await trashLease.close();
      } finally {
        unawaited(_environment.releaseRemoteLeases());
      }
    }
  }

  Future<SyncRun> _reopenRun(SyncRun run) async {
    final journal = await SyncRunJournal.open(run.journal.path);
    final reopened = SyncRun(
      journal: journal,
      plan: run.plan,
      mtimeUnreliableLeft: run.mtimeUnreliableLeft,
      mtimeUnreliableRight: run.mtimeUnreliableRight,
      cancelled: run.cancelled,
    );
    if (identical(_lastRun, run)) _lastRun = reopened;
    return reopened;
  }

  /// The panel's pause/resume verb → the run's between-items gate.
  void setPaused(bool paused) {
    if (!isRunning || _pause == null) return;
    paused ? _pause!.pause() : _pause!.resume();
    _binding?.emitTaskState(
      paused ? TransferTaskState.paused : TransferTaskState.running,
    );
    notifyListeners();
  }

  /// The panel's cancel verb → sticky run cancellation.
  void cancelRun() {
    _runCancellation?.cancel();
  }

  bool _beginOperation(_SyncPlanOperation operation) {
    if (_disposed || _activeOperation != null) return false;
    _activeOperation = operation;
    notifyListeners();
    return true;
  }

  bool _operationCanContinue(_SyncPlanOperation operation, int generation) =>
      !_disposed &&
      _activeOperation == operation &&
      _scanGeneration == generation;

  void _endOperation(_SyncPlanOperation operation) {
    if (_activeOperation != operation) return;
    _activeOperation = null;
    if (!_disposed) notifyListeners();
  }

  // -- Executor wiring -----------------------------------------------------

  SyncExecutor _buildExecutor({
    RemoteFileSystem? leftFileSystem,
    RemoteFileSystem? rightFileSystem,
  }) {
    // Remote endpoints throw the typed `unsupported` refusal inside
    // fileSystemFor — the run surfaces it as a failed state, never a
    // simulated transfer.
    final leftFs = leftFileSystem ?? _environment.fileSystemFor(_pair.left);
    final rightFs = rightFileSystem ?? _environment.fileSystemFor(_pair.right);
    final leftTrash = _resolvedTrashLocation(SyncSide.left);
    final rightTrash = _resolvedTrashLocation(SyncSide.right);
    return SyncExecutor(
      leftFileSystem: leftFs,
      rightFileSystem: rightFs,
      leftRoot: _leftRoot ?? _environment.rootFor(_pair.left),
      rightRoot: _rightRoot ?? _environment.rootFor(_pair.right),
      syncRunsDirectory: _environment.syncRunsDirectory,
      deviceId: deviceId,
      mtimeUnreliableLeft: _pairState.mtimeUnreliableLeft,
      mtimeUnreliableRight: _pairState.mtimeUnreliableRight,
      trashRootLeft: leftTrash?.trashRoot,
      trashRootRight: rightTrash?.trashRoot,
      trashScopeLeft: leftTrash?.scopeKey,
      trashScopeRight: rightTrash?.scopeKey,
      trashLocationKeyLeft: leftTrash?.locationKey,
      trashLocationKeyRight: rightTrash?.locationKey,
      trashPathStyleLeft: leftTrash?.pathStyle ?? SyncTrashPathStyle.posix,
      trashPathStyleRight: rightTrash?.pathStyle ?? SyncTrashPathStyle.posix,
    );
  }

  SyncTrashLocation? _resolvedTrashLocation(SyncSide side) {
    final location = _trashLocations[side];
    return location != null && location.isResolved ? location : null;
  }

  Future<void> _ensureRunTrashLocations(SyncPlan plan) async {
    final requiredSides = _requiredTrashSides(plan);
    if (requiredSides.isEmpty ||
        requiredSides.every((side) => _resolvedTrashLocation(side) != null)) {
      return;
    }

    await _resolveTrashLocations(_scanGeneration);
    if (_disposed) return;

    for (final side in requiredSides) {
      if (_resolvedTrashLocation(side) != null) continue;
      final failure = _trashLocationFailures[side];
      if (failure != null) throw failure;

      final root = side == SyncSide.left ? _leftRoot : _rightRoot;
      throw _trashLocationFailure(
        side,
        root ??
            _environment.rootFor(
              side == SyncSide.left ? _pair.left : _pair.right,
            ),
        StateError('the endpoint is unavailable'),
      );
    }
  }

  Set<SyncSide> _requiredTrashSides(SyncPlan plan) {
    final required = <SyncSide>{};
    final rules = plan.pair.rules;
    final removals = assessDeletions(plan).removals;
    if (rules.deletions != DeletionPolicy.permanent) {
      for (final side in SyncSide.values) {
        if ((removals[side] ?? 0) > 0) required.add(side);
      }
    }
    if (rules.backups != BackupPolicy.trash) return required;

    for (final item in plan.items) {
      switch (item.effective) {
        case SyncActionType.updateLeftToRight:
          if (item.right?.kind == EntryKind.file) required.add(SyncSide.right);
        case SyncActionType.updateRightToLeft:
          if (item.left?.kind == EntryKind.file) required.add(SyncSide.left);
        default:
          break;
      }
    }
    return required;
  }

  Set<SyncTrashLocation> _runTrashLocations() =>
      _trashLocations.values.where((location) => location.isResolved).toSet();

  List<
    ({
      SyncEndpoint endpoint,
      SyncTrashLocation? location,
      SyncEndpointBinding? endpointBinding,
    })
  >
  _runEndpointBindings() => [
    (
      endpoint: _pair.left,
      location: _resolvedTrashLocation(SyncSide.left),
      endpointBinding: _endpointBindings[SyncSide.left],
    ),
    (
      endpoint: _pair.right,
      location: _resolvedTrashLocation(SyncSide.right),
      endpointBinding: _endpointBindings[SyncSide.right],
    ),
  ];

  bool get _trashRootsPurging =>
      _runTrashLocations().any(_environment.trashActivity.hasPurge);

  /// The one-row activity-panel task — a sync session rendered through
  /// the transfer vocabulary (route = left root → right root).
  TransferTaskSpec _taskSpec() {
    FsLocation locationFor(SyncEndpoint endpoint) => switch (endpoint) {
      LocalEndpoint() => const LocalFsLocation(),
      RemoteEndpoint(:final server) => ServerFsLocation(
        server.serverConfigId ?? 'remote',
      ),
    };
    return TransferTaskSpec(
      source: locationFor(_pair.left),
      destination: locationFor(_pair.right),
      rootPaths: [_leftRoot ?? _environment.rootFor(_pair.left)],
      destinationDir: _rightRoot ?? _environment.rootFor(_pair.right),
      policy: ResolvedConflictPolicy(),
    );
  }

  /// Executor events → item rows + notify. The item objects are the
  /// plan's — status reads re-render through the same list.
  void _onRunEvent(SyncRunEvent event) {
    final binding = _binding;
    switch (event.kind) {
      case SyncRunEvent.itemStarted:
        final item = event.item;
        if (item != null) binding?.emitItemStarted(item);
      case SyncRunEvent.itemProgress:
        final item = event.item;
        if (item != null) {
          binding?.emitProgress(
            item.relativePath,
            event.transferred ?? 0,
            event.total,
          );
        }
      case SyncRunEvent.itemFinished:
        final item = event.item;
        if (item != null) binding?.emitItemFinished(item);
      case SyncRunEvent.runFinished:
        break; // the terminal task event lands via _finishRunPhase
    }
    if (!_disposed) notifyListeners();
  }

  // -- Pair/rules rebuilds -------------------------------------------------

  SyncPair _pairWithRules(SyncRuleSet rules) => SyncPair(
    id: _pair.id,
    name: _pair.name,
    left: _pair.left,
    right: _pair.right,
    rules: rules,
    lastRunAt: _pair.lastRunAt,
  );

  /// The few edits the view makes go through this one place: the
  /// package's [SyncRuleSet.copyWith] keeps every other field, and the
  /// bidirectional × deletions invariant collapses here — dropping the
  /// deletion policy when the direction no longer admits it.
  SyncRuleSet _rulesWith({
    SyncDirection? direction,
    DeletionPolicy? deletions,
    List<String>? excludeGlobs,
    ComparisonMode? comparison,
  }) {
    final rules = _pair.rules;
    final nextDirection = direction ?? rules.direction;
    return rules.copyWith(
      direction: nextDirection,
      deletions: nextDirection == SyncDirection.bidirectional
          ? DeletionPolicy.none
          : deletions ?? rules.deletions,
      comparison: comparison,
      excludeGlobs: excludeGlobs,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _environment.trashActivity.removeListener(_onTrashActivityChanged);
    _scanCancellation?.cancel();
    _runCancellation?.cancel();
    _trashPurgeCancellation?.cancel();
    _pause?.resume();
    unawaited(_environment.releaseRemoteLeases());
    super.dispose();
  }
}

_CachedTrashSelection _selectCachedTrash(
  TrashCacheEntry cache,
  DateTime now,
  Set<String> activeRunIds,
  String devicePrefix,
) {
  var knownFileCount = 0;
  var runCount = 0;
  var unjournaledRunCount = 0;
  for (final run in cache.runs) {
    if (activeRunIds.contains(run.runId)) continue;
    if (now.difference(run.ageBasis) <= syncTrashRetention) continue;
    final journaled = run.fileCount != null;
    final localOrExport =
        run.runId.startsWith('$devicePrefix-') ||
        run.runId.startsWith(syncTrashRsyncDirPrefix);
    if (!journaled && !localOrExport) continue;
    runCount++;
    if (journaled) {
      knownFileCount += run.fileCount!;
    } else {
      unjournaledRunCount++;
    }
  }
  return _CachedTrashSelection(
    knownFileCount: knownFileCount,
    runCount: runCount,
    unjournaledRunCount: unjournaledRunCount,
  );
}

/// [SyncPairScanner] over the real [TreeScanner] + [SyncEnvironment].
final class _TreeScannerAdapter implements SyncPairScanner {
  _TreeScannerAdapter(this._environment);
  final SyncEnvironment _environment;

  @override
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  }) async {
    final fs = _environment.fileSystemFor(endpoint);
    final root = _environment.rootFor(endpoint);
    final trashPath = await _environment.effectiveTrashPath(
      endpoint: endpoint,
      canonicalRoot: root,
      rules: rules,
      side: side,
    );

    return TreeScanner(fs).scan(
      root,
      side: side,
      rules: rules,
      trashPath: trashPath,
      caseSensitivityOverride: caseSensitivityOverride,
      probeCaseSensitivity: caseSensitivityOverride == null,
      cancellation: cancellation,
      onProgress: onProgress,
    );
  }
}

/// [SyncPlanDiffer] over the engine's `diffScans`.
final class _EngineDiffer implements SyncPlanDiffer {
  _EngineDiffer(this._environment);
  final SyncEnvironment _environment;

  @override
  Future<SyncPlan> diff(
    ScanResult left,
    ScanResult right,
    SyncPair pair, {
    bool mtimeUnreliableLeft = false,
    bool mtimeUnreliableRight = false,
  }) {
    RemoteFileSystem? fsFor(SyncEndpoint endpoint) =>
        _environment.endpointAvailable(endpoint)
        ? _environment.fileSystemFor(endpoint)
        : null;
    return diffScans(
      left: left,
      right: right,
      pair: pair,
      mtimeUnreliableLeft: mtimeUnreliableLeft,
      mtimeUnreliableRight: mtimeUnreliableRight,
      leftFileSystem: fsFor(pair.left),
      rightFileSystem: fsFor(pair.right),
    );
  }
}

/// Recomputes §7's header figures from effective actions — the plan's
/// diff-time [PlanTotals] describe the *suggested* plan; the sentence,
/// the filter chips, and the run button follow what would actually
/// run. Public for tests and the format layer's clause builder.
SyncEffectiveStats computeSyncEffectiveStats(SyncPlan plan) {
  final counts = <SyncActionType, int>{};
  final bytes = <SyncActionType, int>{};
  final replacedBySide = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  final replacedRowsBySide = <SyncSide, int>{
    SyncSide.left: 0,
    SyncSide.right: 0,
  };
  final fileDeletes = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  final dirDeletes = <SyncSide, int>{SyncSide.left: 0, SyncSide.right: 0};
  var replacedFiles = 0;
  var replacedBytes = 0;
  for (final item in plan.items) {
    counts[item.effective] = (counts[item.effective] ?? 0) + 1;
    // Delete-phase rows split by destination kind: files count on the
    // rails and the delete clause; directories are the zero-weight
    // empty-cleanup clause.
    switch (item.effective) {
      case SyncActionType.deleteLeft:
        final map = item.left?.kind == EntryKind.directory
            ? dirDeletes
            : fileDeletes;
        map[SyncSide.left] = map[SyncSide.left]! + 1;
      case SyncActionType.deleteRight:
        final map = item.right?.kind == EntryKind.directory
            ? dirDeletes
            : fileDeletes;
        map[SyncSide.right] = map[SyncSide.right]! + 1;
      default:
        break;
    }
    final source = switch (item.effective) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => item.left,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => item.right,
      _ => null,
    };
    if (source != null && source.kind != EntryKind.directory) {
      bytes[item.effective] =
          (bytes[item.effective] ?? 0) + (source.size ?? 0);
    }
    // Rule-4 pre-delete weight — same accounting the rails use, so the
    // replace clause and the confirm dialog agree.
    final destSide = switch (item.effective) {
      SyncActionType.copyLeftToRight ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.makeDirRight => SyncSide.right,
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateRightToLeft ||
      SyncActionType.makeDirLeft => SyncSide.left,
      _ => null,
    };
    if (destSide == null) continue;
    final dest = destSide == SyncSide.left ? item.left : item.right;
    if (dest == null) continue;
    final typeChange = switch (item.effective) {
      SyncActionType.makeDirLeft || SyncActionType.makeDirRight =>
        dest.kind != EntryKind.directory,
      SyncActionType.copyLeftToRight ||
      SyncActionType.copyRightToLeft ||
      SyncActionType.updateLeftToRight ||
      SyncActionType.updateRightToLeft => dest.kind != EntryKind.file,
      _ => false,
    };
    if (!typeChange) continue;
    var weight = 0;
    var weightBytes = 0;
    if (dest.kind == EntryKind.directory) {
      for (final snapshot
          in item.destinationSubtree?.values ?? const <EntrySnapshot>[]) {
        if (snapshot.kind != EntryKind.directory) {
          weight++;
          weightBytes += snapshot.size ?? 0;
        }
      }
    } else {
      weight = 1;
      weightBytes = dest.size ?? 0;
    }
    replacedFiles += weight;
    replacedBytes += weightBytes;
    replacedBySide[destSide] = replacedBySide[destSide]! + weight;
    replacedRowsBySide[destSide] = replacedRowsBySide[destSide]! + 1;
  }
  return SyncEffectiveStats(
    counts: counts,
    bytes: bytes,
    replacedFiles: replacedFiles,
    replacedBytes: replacedBytes,
    replacedBySide: replacedBySide,
    replacedRowsBySide: replacedRowsBySide,
    fileDeletesBySide: fileDeletes,
    dirDeletesBySide: dirDeletes,
  );
}
