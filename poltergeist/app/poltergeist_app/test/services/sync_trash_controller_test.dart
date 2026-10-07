@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_app/services/sync_trash_activity.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/file_lock_holder.dart';
import '../support/sync_harness.dart';

const _mismatchedLocationKey =
    '0000000000000000000000000000000000000000000000000000000000000000';
final SyncTrashPathStyle _nativeTrashPathStyle = Platform.isWindows
    ? SyncTrashPathStyle.windows
    : SyncTrashPathStyle.posix;

void main() {
  late Directory scratch;
  late Directory leftRoot;
  late Directory rightRoot;
  late Directory runsDirectory;
  late MemorySyncStateStore states;
  late SyncTrashActivityRegistry activity;
  late SyncPair pair;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('poltergeist-trash-ui-');
    leftRoot = Directory('${scratch.path}/left')..createSync();
    rightRoot = Directory('${scratch.path}/right')..createSync();
    runsDirectory = Directory('${scratch.path}/sync_runs')..createSync();
    states = MemorySyncStateStore();
    activity = SyncTrashActivityRegistry();
    pair = testSyncPair(left: leftRoot.path, right: rightRoot.path);
    for (final root in [leftRoot, rightRoot]) {
      await resolveSyncTrashRoot(
        LocalFileSystem(),
        '${root.path}${Platform.pathSeparator}.poltergeist-trash',
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
    }
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test(
    'plan-time listing exposes aged journal counts and caches them',
    () async {
      final runId = _runId(syncRunDevicePrefix('test-device'), 'old-plan');
      final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
        ..createSync();
      final runDirectory = Directory('${trashRoot.path}/$runId')..createSync();
      final trashed = File('${runDirectory.path}/000001-a.txt')
        ..writeAsStringSync('old');
      final journal = await _writeJournal(
        runsDirectory,
        runId: runId,
        pairId: 'other-pair',
        trashLocation: trashed.path,
        startedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      final controller = _controller(
        pair: pair,
        states: states,
        activity: activity,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.trashNotices.isNotEmpty);

      final notice = controller.trashNotices.single;
      expect(notice.knownFileCount, 1);
      expect(notice.runCount, 1);
      expect(notice.unjournaledRunCount, 0);
      expect(notice.isStale, isFalse);
      expect(notice.canPurge, isTrue);
      expect(controller.pairState.trashCacheLeft?.runs.single.runId, runId);
      expect(controller.prepareTrashPurge(notice)!.spansOtherPairs, isTrue);
      expect(runDirectory.existsSync(), isTrue);
      expect((await SyncRunJournal.open(journal.path)).hasPurgeMarker, isFalse);
    },
  );

  test('cache persistence failure does not fail the plan', () async {
    final runId = _runId(syncRunDevicePrefix('test-device'), 'old-cache');
    final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
      ..createSync();
    final runDirectory = Directory('${trashRoot.path}/$runId')..createSync();
    final trashed = File('${runDirectory.path}/000001-a.txt')
      ..writeAsStringSync('old');
    await _writeJournal(
      runsDirectory,
      runId: runId,
      pairId: 'pair-1',
      trashLocation: trashed.path,
      startedAt: DateTime.now().subtract(const Duration(days: 31)),
    );
    final failingStates = _FailingCacheStateStore();
    final controller = _controller(
      pair: pair,
      states: failingStates,
      activity: activity,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(() => controller.trashNotices.isNotEmpty);

    expect(controller.phase, SyncPlanPhase.ready);
    expect(controller.trashNotices.single.runCount, 1);
  });

  test(
    'dispose during a failed cache save lets a waiting run settle',
    () async {
      final runId = _runId(syncRunDevicePrefix('test-device'), 'gated-cache');
      final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
        ..createSync();
      final runDirectory = Directory('${trashRoot.path}/$runId')..createSync();
      final trashed = File('${runDirectory.path}/000001-a.txt')
        ..writeAsStringSync('old');
      await _writeJournal(
        runsDirectory,
        runId: runId,
        pairId: 'pair-1',
        trashLocation: trashed.path,
        startedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      final gatedStates = _GatedFailingCacheStateStore();
      final controller = _controller(
        pair: pair,
        states: gatedStates,
        activity: activity,
      );

      controller.start();
      await gatedStates.cacheSaveStarted.future;
      expect(controller.phase, SyncPlanPhase.ready);
      final run = controller.run();

      controller.dispose();
      gatedStates.failCacheSave();

      await expectLater(run, completes);
    },
  );

  test('a cached scope releases journals after whole-root deletion', () async {
    final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
      ..createSync();
    final identity = await resolveSyncTrashRoot(
      LocalFileSystem(),
      trashRoot.path,
      pathStyle: _nativeTrashPathStyle,
      access: SyncTrashRootAccess.createOrClaim,
    );
    final runId = _runId(syncRunDevicePrefix('test-device'), 'deleted-root');
    final journal = await _writeJournal(
      runsDirectory,
      runId: runId,
      pairId: 'pair-1',
      trashLocation: '${trashRoot.path}/$runId/000001-a.txt',
      trashScopeLeft: identity.scopeKey,
      trashLocationKeyLeft: syncTrashLocationKey(
        endpoint: pair.left,
        trashRoot: trashRoot.path,
        pathCase: SyncTrashPathCase.sensitive,
      ),
      startedAt: DateTime.now(),
    );
    final pairId = syncPairId(
      pair,
      leftCaseInsensitive: false,
      rightCaseInsensitive: false,
    );
    await states.save(
      pairId,
      SyncPairState(
        trashCacheLeft: TrashCacheEntry(
          lastListedAt: DateTime.now(),
          trashScope: identity.scopeKey,
          runs: const [],
        ),
      ),
    );
    await trashRoot.delete(recursive: true);
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(
      () =>
          controller.pairState.trashCacheLeft?.trashScope != null &&
          controller.pairState.trashCacheLeft?.trashScope != identity.scopeKey,
    );

    final reopened = await SyncRunJournal.open(journal.path);
    expect(reopened.isTrashScopePurged(identity.scopeKey), isTrue);
    expect(reopened.hasUnpurgedTrash, isFalse);
  });

  test(
    'confirmed aged purge removes the run and releases its journal',
    () async {
      final runId = _runId(syncRunDevicePrefix('test-device'), 'old-purge');
      final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
        ..createSync();
      final identity = await resolveSyncTrashRoot(
        LocalFileSystem(),
        trashRoot.path,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final runDirectory = Directory('${trashRoot.path}/$runId')..createSync();
      final trashed = File('${runDirectory.path}/000001-a.txt')
        ..writeAsStringSync('old');
      final journal = await _writeJournal(
        runsDirectory,
        runId: runId,
        pairId: 'pair-1',
        trashLocation: trashed.path,
        trashScopeLeft: identity.scopeKey,
        startedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      final controller = _controller(
        pair: pair,
        states: states,
        activity: activity,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.trashNotices.isNotEmpty);

      final request = controller.prepareTrashPurge(
        controller.trashNotices.single,
      )!;
      final outcome = await controller.purgeTrash(request);

      expect(outcome.purgedRunCount, 1);
      expect(outcome.failures, isEmpty);
      expect(runDirectory.existsSync(), isFalse);
      expect((await SyncRunJournal.open(journal.path)).purged, isTrue);
      expect(controller.trashNotices, isEmpty);
    },
  );

  test('unreachable side shows stale cache and disables its purge', () async {
    final runId = _runId(syncRunDevicePrefix('test-device'), 'cached');
    final pairId = syncPairId(
      pair,
      leftCaseInsensitive: false,
      rightCaseInsensitive: false,
    );
    final cachedAt = DateTime.now().subtract(const Duration(days: 2));
    await states.save(
      pairId,
      SyncPairState(
        trashCacheLeft: TrashCacheEntry(
          lastListedAt: cachedAt,
          runs: [
            TrashCacheRun(
              runId: runId,
              ageBasis: DateTime.now().subtract(const Duration(days: 31)),
              fileCount: 3,
            ),
          ],
        ),
      ),
    );
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
      localFileSystem: () => _TrashListingFailureFileSystem(),
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(() => controller.trashNotices.isNotEmpty);

    final notice = controller.trashNotices.single;
    expect(notice.knownFileCount, 3);
    expect(notice.isStale, isTrue);
    expect(notice.listedAt, cachedAt);
    expect(notice.canPurge, isFalse);
    expect(controller.prepareTrashPurge(notice), isNull);
  });

  test('cached trash exactly at retention age stays hidden', () async {
    final now = DateTime.utc(2026, 10, 3, 12);
    final runId = _runId(syncRunDevicePrefix('test-device'), 'boundary');
    final pairId = syncPairId(
      pair,
      leftCaseInsensitive: false,
      rightCaseInsensitive: false,
    );
    await states.save(
      pairId,
      SyncPairState(
        trashCacheLeft: TrashCacheEntry(
          lastListedAt: now,
          runs: [
            TrashCacheRun(
              runId: runId,
              ageBasis: now.subtract(syncTrashRetention),
              fileCount: 1,
            ),
          ],
        ),
      ),
    );
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
      localFileSystem: () => _TrashListingFailureFileSystem(),
      now: () => now,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

    expect(controller.trashNotices, isEmpty);
  });

  test('cache from another trash location is not displayed', () async {
    final runId = _runId(syncRunDevicePrefix('test-device'), 'old-location');
    final pairId = syncPairId(
      pair,
      leftCaseInsensitive: false,
      rightCaseInsensitive: false,
    );
    await states.save(
      pairId,
      SyncPairState(
        trashCacheLeft: TrashCacheEntry(
          lastListedAt: DateTime.now().subtract(const Duration(days: 2)),
          locationKey: _mismatchedLocationKey,
          runs: [
            TrashCacheRun(
              runId: runId,
              ageBasis: DateTime.now().subtract(const Duration(days: 31)),
              fileCount: 3,
            ),
          ],
        ),
      ),
    );
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
      localFileSystem: () => _TrashListingFailureFileSystem(),
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
    await controller.prepareFullTrashPurgeLive();

    expect(controller.trashNotices, isEmpty);
  });

  test(
    'trash identity failure keeps stale purge data without blocking',
    () async {
      final runId = _runId(syncRunDevicePrefix('test-device'), 'unresolved');
      final pairId = syncPairId(
        pair,
        leftCaseInsensitive: false,
        rightCaseInsensitive: false,
      );
      await states.save(
        pairId,
        SyncPairState(
          trashCacheLeft: TrashCacheEntry(
            lastListedAt: DateTime.now().subtract(const Duration(days: 2)),
            runs: [
              TrashCacheRun(
                runId: runId,
                ageBasis: DateTime.now().subtract(const Duration(days: 31)),
                fileCount: 1,
              ),
            ],
          ),
        ),
      );
      final controller = _controller(
        pair: pair,
        states: states,
        activity: activity,
        localFileSystem: () => _TrashResolutionFailureFileSystem(),
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      expect(controller.trashNotices.single.isStale, isTrue);
      expect(controller.trashNotices.single.canPurge, isFalse);
      expect(controller.trashPurgeBlocksActions, isFalse);
    },
  );

  test('a no-trash plan runs while trash identity is unavailable', () async {
    final noTrashPair = testSyncPair(
      left: leftRoot.path,
      right: rightRoot.path,
      rules: const SyncRuleSet(
        deletions: DeletionPolicy.permanent,
        backups: BackupPolicy.none,
      ),
    );
    File('${leftRoot.path}/a.txt').writeAsStringSync('alpha');
    final plan = testPlan(noTrashPair, [
      testItem(
        'a.txt',
        left: testFile(size: 5),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      ),
    ]);
    final controller = _controller(
      pair: noTrashPair,
      states: states,
      activity: activity,
      localFileSystem: () => _TrashResolutionFailureFileSystem(),
      plan: plan,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
    await controller.run();

    expect(controller.phase, SyncPlanPhase.completed);
    expect(File('${rightRoot.path}/a.txt').readAsStringSync(), 'alpha');
  });

  test('a trash-writing plan reports an unavailable trash root', () async {
    File('${leftRoot.path}/a.txt').writeAsStringSync('alpha');
    File('${rightRoot.path}/a.txt').writeAsStringSync('older');
    final plan = testPlan(pair, [
      testItem(
        'a.txt',
        left: testFile(size: 5),
        right: testFile(size: 5),
        suggested: SyncActionType.updateLeftToRight,
        reason: SyncReason.newerOnLeft,
      ),
    ]);
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
      localFileSystem: () => _TrashResolutionFailureFileSystem(),
      plan: plan,
    );
    addTearDown(controller.dispose);

    controller.start();
    await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
    await controller.run();

    expect(controller.phase, SyncPlanPhase.failed);
    expect(controller.errorMessage, 'offline');
    expect(File('${rightRoot.path}/a.txt').readAsStringSync(), 'older');
  });

  for (final failure in const <Object>[
    SyncTrashActivityLockException('claim trash'),
    SyncTrashPurgeInProgressException(),
  ]) {
    test('a trash-writing plan reports a ${failure.runtimeType} as an '
        'unavailable trash root', () async {
      File('${leftRoot.path}/a.txt').writeAsStringSync('alpha');
      File('${rightRoot.path}/a.txt').writeAsStringSync('older');
      final plan = testPlan(pair, [
        testItem(
          'a.txt',
          left: testFile(size: 5),
          right: testFile(size: 5),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.newerOnLeft,
        ),
      ]);
      final controller = _controller(
        pair: pair,
        states: states,
        activity: activity,
        localFileSystem: () => _TrashResolutionFailureFileSystem(failure),
        plan: plan,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.trashPurgeBlocksActions, isFalse);
      await controller.run();

      expect(controller.phase, SyncPlanPhase.failed);
      expect(
        controller.errorMessage,
        'Sync trash on the right side is unavailable: $failure',
      );
      expect(File('${rightRoot.path}/a.txt').readAsStringSync(), 'older');
    });
  }

  for (final leftFails in [true, false]) {
    test('a trash failure on one side ${leftFails ? 'still runs the other '
        'but holds Restore' : 'is absent: Restore opens'}', () async {
      File('${leftRoot.path}/a.txt').writeAsStringSync('alpha');
      File('${rightRoot.path}/a.txt').writeAsStringSync('older');
      final plan = testPlan(pair, [
        testItem(
          'a.txt',
          left: testFile(size: 5),
          right: testFile(size: 5),
          suggested: SyncActionType.updateLeftToRight,
          reason: SyncReason.newerOnLeft,
        ),
      ]);
      final controller = _controller(
        pair: pair,
        states: states,
        activity: activity,
        localFileSystem: () => _TrashResolutionFailureFileSystem(
          const SyncTrashActivityLockException('claim trash'),
          leftFails ? leftRoot.path : '${scratch.path}/elsewhere',
        ),
        plan: plan,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run();

      expect(controller.phase, SyncPlanPhase.completed);
      expect(File('${rightRoot.path}/a.txt').readAsStringSync(), 'alpha');
      expect(controller.canRestore, !leftFails);
    });
  }

  test('full purge includes foreign runs but refuses an active root', () async {
    final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
      ..createSync();
    final foreignRunId = _runId('ffffffff', 'foreign');
    final foreign = Directory('${trashRoot.path}/$foreignRunId')..createSync();
    File('${foreign.path}/a.txt').writeAsStringSync('old');
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
    );
    addTearDown(controller.dispose);
    controller.start();
    await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
    await pumpUntil(() => controller.canPurgeTrash);

    final identity = await resolveSyncTrashRoot(
      LocalFileSystem(),
      trashRoot.path,
      pathStyle: _nativeTrashPathStyle,
      access: SyncTrashRootAccess.createOrClaim,
    );
    final location = syncTrashLocation(
      endpoint: pair.left,
      canonicalRoot: leftRoot.path,
      rules: pair.rules,
      side: SyncSide.left,
      rootId: identity.rootId,
      resolvedTrashRoot: identity.canonicalRoot,
    );
    final lease = await activity.begin('active-run', [
      location,
    ], mode: SyncTrashActivityMode.run);
    expect(controller.canPurgeTrash, isFalse);
    expect(controller.prepareFullTrashPurge(), isNull);

    await lease.close();
    final request = controller.prepareFullTrashPurge()!;
    expect(request.foreignRunCount, 1);
    expect(request.runCount, 1);
  });

  test('full purge refreshes its scope before confirmation', () async {
    final trashRoot = Directory('${leftRoot.path}/.poltergeist-trash')
      ..createSync();
    Directory('${trashRoot.path}/${_runId('ffffffff', 'first')}').createSync();
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
    );
    addTearDown(controller.dispose);
    controller.start();
    await pumpUntil(() => controller.canPurgeTrash);
    expect(controller.prepareFullTrashPurge()!.runCount, 1);

    Directory('${trashRoot.path}/${_runId('ffffffff', 'second')}').createSync();
    final request = await controller.prepareFullTrashPurgeLive();

    expect(request, isNotNull);
    expect(request!.runCount, 2);
  });

  test('a later target failure preserves earlier purge results', () async {
    final leftTrash = Directory('${leftRoot.path}/.poltergeist-trash')
      ..createSync();
    final rightTrash = Directory('${rightRoot.path}/.poltergeist-trash')
      ..createSync();
    final leftRunId = _runId('ffffffff', 'left-partial');
    final rightRunId = _runId('ffffffff', 'right-partial');
    final leftRun = Directory('${leftTrash.path}/$leftRunId')..createSync();
    final rightRun = Directory('${rightTrash.path}/$rightRunId')..createSync();
    File('${leftRun.path}/a.txt').writeAsStringSync('left');
    File('${rightRun.path}/b.txt').writeAsStringSync('right');
    final fileSystem = _ToggleTrashListingFailureFileSystem();
    final controller = _controller(
      pair: pair,
      states: states,
      activity: activity,
      localFileSystem: () => fileSystem,
    );
    addTearDown(controller.dispose);
    controller.start();
    await pumpUntil(() => controller.prepareFullTrashPurge()?.rootCount == 2);
    final request = controller.prepareFullTrashPurge()!;
    fileSystem.failingRoot = rightTrash.path;

    final outcome = await controller.purgeTrash(request);

    expect(outcome.purgedRunCount, 1);
    expect(outcome.failures.single.runId, rightRunId);
    expect(leftRun.existsSync(), isFalse);
    expect(rightRun.existsSync(), isTrue);
  });

  test(
    'inventory preserves a journal for another process active run',
    () async {
      final lockDirectory = Directory('${scratch.path}/trash-locks')
        ..createSync();
      final guardedActivity = SyncTrashActivityRegistry(
        lockDirectory: lockDirectory.path,
      );
      final runId = _runId(syncRunDevicePrefix('test-device'), 'active');
      final trashRoot = '${leftRoot.path}/.poltergeist-trash';
      final identity = await resolveSyncTrashRoot(
        LocalFileSystem(),
        trashRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      final runDirectory = Directory('$trashRoot/$runId')..createSync();
      File('${runDirectory.path}/000001-a.txt').writeAsStringSync('old');
      final journal = await _writeJournal(
        runsDirectory,
        runId: runId,
        pairId: 'pair-1',
        trashLocation: '$trashRoot/$runId/000001-a.txt',
        startedAt: DateTime.now().subtract(const Duration(days: 31)),
      );
      final location = syncTrashLocation(
        endpoint: pair.left,
        canonicalRoot: leftRoot.path,
        rules: pair.rules,
        side: SyncSide.left,
        rootId: identity.rootId,
        resolvedTrashRoot: trashRoot,
      );
      final markerKey = base64Url.encode(utf8.encode(runId));
      final markerPath = p.join(
        lockDirectory.path,
        '${location.scopeKey}.active.v2.$markerKey.lock',
      );
      final marker = await startTestFileLockHolder(
        lockDirectory,
        markerPath,
        markerContents: runId,
      );
      addTearDown(marker.stop);
      final controller = _controller(
        pair: pair,
        states: states,
        activity: guardedActivity,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.pairState.trashCacheLeft != null);
      await pumpUntil(() => !controller.trashPurgeBlocksActions);

      final reopened = await SyncRunJournal.open(journal.path);
      expect(reopened.hasPurgeMarker, isFalse);
      expect(reopened.hasUnpurgedTrash, isTrue);
      expect(controller.trashNotices, isEmpty);
      expect(controller.canPurgeTrash, isFalse);
      expect(controller.prepareFullTrashPurge(), isNull);
    },
  );
}

SyncPlanController _controller({
  required SyncPair pair,
  required SyncStateStore states,
  required SyncTrashActivityRegistry activity,
  RemoteFileSystem Function()? localFileSystem,
  SyncPlan? plan,
  DateTime Function()? now,
}) {
  final scratch = Directory((pair.left as LocalEndpoint).path);
  final runsDirectory = Directory('${scratch.parent.path}/sync_runs');
  final environment = SyncEnvironment(
    states: states,
    syncRunsDirectory: runsDirectory.path,
    deviceId: () async => 'test-device',
    localFileSystem: localFileSystem,
    trashActivity: activity,
  );

  return SyncPlanController(
    pair: pair,
    environment: environment,
    syncTasks: SyncQueueTasks(),
    scanner: FakeSyncScanner(
      left: testScanResult((pair.left as LocalEndpoint).path, const {}),
      right: testScanResult((pair.right as LocalEndpoint).path, const {}),
    ),
    differ: FakeSyncDiffer(plan ?? testPlan(pair, const [])),
    deviceId: 'test-device',
    now: now,
    rsyncEndpoints: resolveRsyncEndpoints,
  );
}

Future<SyncRunJournal> _writeJournal(
  Directory runsDirectory, {
  required String runId,
  required String pairId,
  required String trashLocation,
  required DateTime startedAt,
  String? trashScopeLeft,
  String? trashLocationKeyLeft,
}) async {
  final journal = await SyncRunJournal.create(
    runsDirectory.path,
    SyncRunRecord(
      runId: runId,
      pairId: pairId,
      startedAt: startedAt,
      trashScopeLeft: trashScopeLeft,
      trashLocationKeyLeft: trashLocationKeyLeft,
      rules: const SyncRuleSet(),
      totals: const PlanTotals(
        counts: {},
        bytes: {},
        replacedFiles: 0,
        replacedBytes: 0,
      ),
      warnings: const [],
    ),
  );
  await journal.appendItem(
    SyncJournalItemLine(
      relativePath: 'a.txt',
      side: SyncSide.left,
      action: SyncActionType.deleteLeft,
      outcome: SyncItemStatus.done,
      attempt: 1,
      trashLocation: trashLocation,
      trashBytes: 3,
    ),
  );
  return journal;
}

String _runId(String prefix, String label) {
  final hex = sha256.convert(utf8.encode(label)).toString();
  return '$prefix-${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '4${hex.substring(13, 16)}-a${hex.substring(17, 20)}-'
      '${hex.substring(20, 32)}';
}

final class _TrashListingFailureFileSystem extends LocalFileSystem {
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    if (path.endsWith('.poltergeist-trash')) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'list',
        path: path,
        message: 'offline',
      );
    }
    return super.listDirectory(path);
  }
}

final class _TrashResolutionFailureFileSystem extends LocalFileSystem {
  /// What resolving the trash root throws, an offline answer by default,
  /// for every trash root or only the one under [onlyUnder].
  _TrashResolutionFailureFileSystem([this.failure, this.onlyUnder]);

  final Object? failure;
  final String? onlyUnder;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    if (path.endsWith('.poltergeist-trash') &&
        (onlyUnder == null || p.isWithin(onlyUnder!, path))) {
      throw failure ??
          RemoteFileException(
            kind: RemoteFileErrorKind.disconnected,
            operation: 'stat',
            path: path,
            message: 'offline',
          );
    }
    return super.stat(path, followLinks: followLinks);
  }
}

final class _ToggleTrashListingFailureFileSystem extends LocalFileSystem {
  String? failingRoot;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    if (failingRoot != null && p.equals(path, failingRoot!)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'list',
        path: path,
        message: 'offline',
      );
    }
    return super.listDirectory(path);
  }
}

final class _FailingCacheStateStore implements SyncStateStore {
  final MemorySyncStateStore _delegate = MemorySyncStateStore();
  var _saveCount = 0;

  @override
  Future<SyncPairState> load(String pairId) => _delegate.load(pairId);

  @override
  Future<void> save(String pairId, SyncPairState state) {
    _saveCount++;
    if (_saveCount > 1) throw StateError('cache write failed');

    return _delegate.save(pairId, state);
  }
}

final class _GatedFailingCacheStateStore implements SyncStateStore {
  final MemorySyncStateStore _delegate = MemorySyncStateStore();
  final Completer<void> cacheSaveStarted = Completer<void>();
  final Completer<void> _cacheSaveRelease = Completer<void>();
  var _saveCount = 0;

  @override
  Future<SyncPairState> load(String pairId) => _delegate.load(pairId);

  @override
  Future<void> save(String pairId, SyncPairState state) async {
    _saveCount++;
    if (_saveCount == 1) {
      await _delegate.save(pairId, state);
      return;
    }

    cacheSaveStarted.complete();
    await _cacheSaveRelease.future;
    throw StateError('cache write failed');
  }

  void failCacheSave() => _cacheSaveRelease.complete();
}
