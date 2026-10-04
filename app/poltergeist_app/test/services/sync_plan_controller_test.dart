// SyncPlanController coverage (M8): the scan→ready pipeline, the
// override vocabulary and its carve-outs, the rails' run gating, and
// the run/retry/restore lifecycle against real temp trees.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/server_config_source.dart';
import 'package:poltergeist_app/services/sync_compare_controller.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_app/services/sync_trash_activity.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/fake_bookmark_store.dart';
import '../support/sync_harness.dart';

const _locationGateSuffix = '.location.gate.lock';

SyncPlanController _controller({
  required SyncPair pair,
  required SyncPlan plan,
  SyncEnvironment? environment,
  SyncQueueTasks? syncTasks,
  Directory? scratch,
}) {
  final left = testScanResult('/left', const {});
  final right = testScanResult('/right', const {});
  return testController(
    pair: pair,
    scanner: FakeSyncScanner(left: left, right: right),
    differ: FakeSyncDiffer(plan),
    environment:
        environment ??
        testSyncEnvironment(scratch ?? Directory.systemTemp.createTempSync()),
    syncTasks: syncTasks,
  );
}

Future<SyncPlanController> _ready(SyncPlanController controller) async {
  controller.start();
  await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
  return controller;
}

void main() {
  group('scan → ready', () {
    test('produces plan, stats, pairId, and ready phase', () async {
      final pair = testSyncPair();
      final plan = testPlan(pair, [
        testItem(
          'a.txt',
          left: testFile(size: 4),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
      ]);
      final controller = await _ready(_controller(pair: pair, plan: plan));
      addTearDown(controller.dispose);
      expect(controller.plan, same(plan));
      expect(controller.stats!.countOf(SyncActionType.copyLeftToRight), 1);
      expect(controller.pairId, isNotEmpty);
      expect(controller.isRunning, isFalse);
    });

    test('a differ failure lands in the error phase', () async {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      final controller = SyncPlanController(
        pair: pair,
        environment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult('/right', const {}),
        ),
        differ: FakeSyncDiffer(null, error: StateError('boom')),
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.error);
      expect(controller.errorMessage, contains('boom'));
      expect(controller.errorKind, RemoteFileErrorKind.other);
    });

    test('comparison uses the canonical scan roots', () async {
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final leftRoot = p.join(scratch.path, 'canonical-left');
      final rightRoot = p.join(scratch.path, 'canonical-right');
      final pair = testSyncPair(left: '~/left', right: '~/right');
      final item = testItem(
        'nested/a.txt',
        left: testFile(),
        right: testFile(),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = SyncPlanController(
        pair: pair,
        environment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        scanner: FakeSyncScanner(
          left: testScanResult(leftRoot, const {}),
          right: testScanResult(rightRoot, const {}),
        ),
        differ: FakeSyncDiffer(testPlan(pair, [item])),
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      await _ready(controller);

      final comparison = controller.comparisonFor(item)!;
      addTearDown(comparison.dispose);

      expect(
        (comparison.request.left as LocalSyncCompareSource).fullPath,
        p.join(leftRoot, 'nested', 'a.txt'),
      );
      expect(
        (comparison.request.right as LocalSyncCompareSource).fullPath,
        p.join(rightRoot, 'nested', 'a.txt'),
      );
    });

    test(
      'docroot warning keeps a canonical root without trash identity',
      () async {
        final scratch = Directory.systemTemp.createTempSync('pg-sync-docroot-');
        addTearDown(() => scratch.deleteSync(recursive: true));
        final rightRoot = Directory(p.join(scratch.path, 'www', 'site'))
          ..createSync(recursive: true);
        final pair = testSyncPair(right: '.');
        final controller = SyncPlanController(
          pair: pair,
          environment: testSyncEnvironment(scratch),
          syncTasks: SyncQueueTasks(),
          scanner: FakeSyncScanner(
            left: testScanResult('/left', const {}),
            right: testScanResult(rightRoot.path, const {}),
          ),
          differ: FakeSyncDiffer(testPlan(pair, const [])),
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);

        await _ready(controller);

        expect(controller.docrootWarnings, hasLength(1));
        expect(controller.docrootWarnings.single.rootPath, rightRoot.path);
      },
    );

    test('docroot containment follows the scanned root case rule', () async {
      final scratch = Directory.systemTemp.createTempSync('pg-sync-docroot-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final rightRoot = Directory(p.join(scratch.path, 'www', 'site'))
        ..createSync(recursive: true);
      final trashPath = p.join(scratch.path, 'WWW', 'site', 'private');
      final pair = testSyncPair(
        right: rightRoot.path,
        rules: SyncRuleSet(trashPathRight: trashPath),
      );
      final controller = SyncPlanController(
        pair: pair,
        environment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult(rightRoot.path, const {}, caseSensitive: false),
        ),
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _ready(controller);

      expect(controller.docrootWarnings, hasLength(1));
    });

    test('focused comparison selection drives command enablement', () async {
      final pair = testSyncPair();
      final comparable = testItem(
        'both.txt',
        left: testFile(),
        right: testFile(),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final oneSided = testItem(
        'left.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [comparable, oneSided])),
      );
      addTearDown(controller.dispose);

      expect(controller.canCompareSelection, isFalse);

      controller.setComparisonTarget(oneSided);
      expect(controller.canCompareSelection, isFalse);

      controller.setComparisonTarget(comparable);
      expect(controller.canCompareSelection, isTrue);
      final comparison = controller.comparisonForSelection()!;
      addTearDown(comparison.dispose);
      expect(comparison.request.relativePath, 'both.txt');

      final rescan = controller.rescan();
      expect(controller.canCompareSelection, isFalse);
      expect(controller.comparisonAvailableFor(comparable), isFalse);
      expect(controller.comparisonFor(comparable), isNull);
      await rescan;
    });

    test('relative trash stays excluded and receives update backups', () async {
      final scratch = Directory.systemTemp.createTempSync(
        'poltergeist-relative-trash-',
      );
      addTearDown(() => scratch.deleteSync(recursive: true));
      final leftRoot = Directory(p.join(scratch.path, 'left'))..createSync();
      final rightRoot = Directory(p.join(scratch.path, 'right'))..createSync();
      File(
        p.join(leftRoot.path, 'document.txt'),
      ).writeAsStringSync('new content');
      File(p.join(rightRoot.path, 'document.txt')).writeAsStringSync('old');
      final trashRoot = Directory(p.join(rightRoot.path, 'trash', 'custom'))
        ..createSync(recursive: true);
      await resolveSyncTrashRoot(
        LocalFileSystem(),
        trashRoot.path,
        pathStyle: SyncTrashPathStyle.posix,
        access: SyncTrashRootAccess.createOrClaim,
      );
      const priorRunId = '12345678-12345678-1234-4123-a123-123456789abc';
      final priorRun = Directory(p.join(trashRoot.path, priorRunId))
        ..createSync();
      File(p.join(priorRun.path, '000001-old.txt')).writeAsStringSync('old');
      final pair = SyncPair(
        id: 'relative-trash',
        name: 'relative trash',
        left: LocalEndpoint(leftRoot.path),
        right: LocalEndpoint(rightRoot.path),
        rules: const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          backups: BackupPolicy.trash,
          trashPathRight: 'trash/custom',
        ),
      );
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
        deviceId: () async => 'test-device',
      );
      final controller = SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: SyncQueueTasks(),
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _ready(controller);

      final plannedPaths = controller.plan!.items
          .map((item) => item.relativePath)
          .toList();
      expect(plannedPaths, contains('document.txt'));
      expect(
        plannedPaths.where(
          (path) => path == 'trash/custom' || path.startsWith('trash/custom/'),
        ),
        isEmpty,
      );
      await controller.run();
      expect(controller.phase, SyncPlanPhase.completed);
      expect(
        File(p.join(rightRoot.path, 'document.txt')).readAsStringSync(),
        'new content',
      );
      final runDirectories = trashRoot
          .listSync()
          .whereType<Directory>()
          .where((directory) => isSyncTrashRunId(p.basename(directory.path)))
          .toList();
      expect(runDirectories, hasLength(2));
    });

    for (final variant in [
      (
        name: 'normalization variants',
        leftPath: 'nested/caf\u00e9.txt',
        rightPath: 'nested/cafe\u0301.txt',
        rightCaseSensitive: true,
      ),
      (
        name: 'case variants',
        leftPath: 'nested/Report.txt',
        rightPath: 'nested/report.txt',
        rightCaseSensitive: false,
      ),
    ]) {
      test('comparison preserves ${variant.name} on each side', () async {
        final scratch = Directory.systemTemp.createTempSync();
        addTearDown(() => scratch.deleteSync(recursive: true));
        final leftRoot = p.join(scratch.path, 'left');
        final rightRoot = p.join(scratch.path, 'right');
        final pair = testSyncPair(left: leftRoot, right: rightRoot);
        final controller = SyncPlanController(
          pair: pair,
          environment: testSyncEnvironment(scratch),
          syncTasks: SyncQueueTasks(),
          scanner: FakeSyncScanner(
            left: testScanResult(leftRoot, {
              variant.leftPath: testFile(size: 4),
            }),
            right: testScanResult(rightRoot, {
              variant.rightPath: testFile(size: 8),
            }, caseSensitive: variant.rightCaseSensitive),
          ),
          rsyncEndpoints: resolveRsyncEndpoints,
        );
        addTearDown(controller.dispose);
        await _ready(controller);

        final item = controller.plan!.items.single;
        final comparison = controller.comparisonFor(item)!;
        addTearDown(comparison.dispose);

        expect(
          (comparison.request.left as LocalSyncCompareSource).fullPath,
          p.joinAll([leftRoot, ...variant.leftPath.split('/')]),
        );
        expect(
          (comparison.request.right as LocalSyncCompareSource).fullPath,
          p.joinAll([rightRoot, ...variant.rightPath.split('/')]),
        );
      });
    }
  });

  group('availableOverrides', () {
    test('Update mode offers copies and skip but no delete', () async {
      final pair = testSyncPair(); // Update defaults: deletions none.
      final item = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      final offers = controller.availableOverrides(item);
      expect(
        offers,
        containsAll(<SyncActionType>[
          SyncActionType.copyLeftToRight,
          SyncActionType.skip,
        ]),
      );
      expect(offers, isNot(contains(SyncActionType.deleteRight)));
      expect(offers, isNot(contains(SyncActionType.deleteLeft)));
    });

    test('Mirror offers delete only for sides the item exists on', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final leftOnly = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [leftOnly])),
      );
      addTearDown(controller.dispose);
      final offers = controller.availableOverrides(leftOnly);
      expect(offers, contains(SyncActionType.deleteLeft));
      expect(offers, isNot(contains(SyncActionType.deleteRight)));
    });

    test('conflict rows admit both copy directions', () async {
      final pair = testSyncPair(); // leftToRight Update.
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 10),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      final offers = controller.availableOverrides(conflict);
      // A conflict asks the direction question itself — even a
      // one-way pair offers both copies plus skip.
      expect(offers, contains(SyncActionType.updateLeftToRight));
      expect(offers, contains(SyncActionType.updateRightToLeft));
      expect(offers, contains(SyncActionType.skip));
    });
  });

  group('applyOverride', () {
    test('a valid override mutates effective and reassesses', () async {
      final pair = testSyncPair();
      final item = testItem(
        'a.txt',
        left: testFile(size: 9),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      expect(controller.stats!.countOf(SyncActionType.copyLeftToRight), 1);
      controller.applyOverride(item, SyncActionType.skip);
      expect(item.effective, SyncActionType.skip);
      expect(item.userOverridden, isTrue);
      expect(controller.stats!.countOf(SyncActionType.copyLeftToRight), 0);
      expect(controller.stats!.hasWork, isFalse);
    });

    test('an action outside the offer set is ignored', () async {
      final pair = testSyncPair(); // Update — delete is never offered.
      final item = testItem(
        'a.txt',
        left: testFile(),
        right: testFile(),
        suggested: SyncActionType.updateLeftToRight,
        reason: SyncReason.newerOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      controller.applyOverride(item, SyncActionType.deleteRight);
      expect(item.effective, SyncActionType.updateLeftToRight);
      expect(item.userOverridden, isFalse);
    });

    test('re-picking the suggested action resets the override', () async {
      final pair = testSyncPair();
      final item = testItem(
        'a.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [item])),
      );
      addTearDown(controller.dispose);
      controller.applyOverride(item, SyncActionType.skip);
      expect(item.userOverridden, isTrue);
      controller.applyOverride(item, SyncActionType.copyLeftToRight);
      expect(item.effective, SyncActionType.copyLeftToRight);
      expect(item.userOverridden, isFalse);
    });

    test('a bulk copy reports typeDiffers rows it skipped', () async {
      final pair = testSyncPair();
      final typeChange = testItem(
        'thing',
        left: testDir,
        right: testFile(),
        suggested: SyncActionType.skip,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {
          'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        },
      );
      final plain = testItem(
        'b.txt',
        left: testFile(),
        suggested: SyncActionType.copyLeftToRight,
        reason: SyncReason.onlyOnLeft,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [typeChange, plain])),
      );
      addTearDown(controller.dispose);
      final skipped = controller.applyOverrideTo([
        typeChange,
        plain,
      ], SyncActionType.copyLeftToRight);
      // §6 rule 4: a no-delete mode's bulk copy must not silently
      // authorize a pre-delete — the type-differs row is reported.
      expect(skipped, contains(typeChange));
      expect(typeChange.effective, SyncActionType.skip);
      expect(plain.effective, SyncActionType.copyLeftToRight);
    });

    test('a bulk copy skips a typeDiffers row through its offered '
        'action', () async {
      // The carve-out is about the ACTION being rule-4 authorization:
      // the row's own offered copy/update verb is exactly that, so the
      // bulk path must skip it too — the exemption lives on the
      // per-row menu (applyOverride), not the bulk verb.
      final pair = testSyncPair(); // Update — deletions: none.
      final typeChange = testItem(
        'thing',
        left: testDir,
        right: testFile(),
        suggested: SyncActionType.skip,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {
          'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        },
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [typeChange])),
      );
      addTearDown(controller.dispose);
      // updateLeftToRight IS this row's offered action (destination is
      // a file) — the offer-set check cannot catch it.
      expect(
        controller.availableOverrides(typeChange),
        contains(SyncActionType.updateLeftToRight),
      );
      final skipped = controller.applyOverrideTo([
        typeChange,
      ], SyncActionType.updateLeftToRight);
      expect(skipped, contains(typeChange));
      expect(typeChange.effective, SyncActionType.skip);
    });
  });

  group('resolveConflicts', () {
    test('keepLeft / keepRight / skip resolve every conflict row', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 10),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      expect(controller.resolveConflicts(SyncConflictChoice.keepLeft), 1);
      expect(conflict.effective, SyncActionType.updateLeftToRight);
      conflict.effective = SyncActionType.conflict;
      expect(controller.resolveConflicts(SyncConflictChoice.keepRight), 1);
      expect(conflict.effective, SyncActionType.updateRightToLeft);
      conflict.effective = SyncActionType.conflict;
      expect(controller.resolveConflicts(SyncConflictChoice.skip), 1);
      expect(conflict.effective, SyncActionType.skip);
    });

    test('newerWins resolves by mtime and hides on untrusted clocks', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 30),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      expect(controller.offersNewerWins, isTrue);
      expect(controller.resolveConflicts(SyncConflictChoice.newerWins), 1);
      expect(conflict.effective, SyncActionType.updateLeftToRight);
      controller.pairState.mtimeUnreliableLeft = true;
      expect(controller.offersNewerWins, isFalse);
    });

    test('a bulk keep leaves a typeDiffers row unresolved in a '
        'no-delete mode', () async {
      // §7: rule-4 authorization is per-item only — the bulk bar must
      // not smuggle it in on a typeDiffers row (every such row is a
      // conflict in a no-delete mode, so it lands in the bulk set).
      final pair = testSyncPair(); // Update — deletions: none.
      final typeChange = testItem(
        'thing',
        left: testDir,
        right: testFile(),
        suggested: SyncActionType.conflict,
        reason: SyncReason.typeDiffers,
        destinationSubtree: const {
          'thing/a.txt': EntrySnapshot(kind: EntryKind.file, size: 1),
        },
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [typeChange])),
      );
      addTearDown(controller.dispose);
      expect(controller.resolveConflicts(SyncConflictChoice.keepLeft), 0);
      expect(typeChange.effective, SyncActionType.conflict);
    });

    test('keep-destination in a one-way pair resolves to skip', () async {
      // Mirror L→R: keeping the right (destination) side writes
      // against the direction — the differ's keep-side semantics make
      // that a deliberate skip, never a source-side write.
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
        ),
      );
      final conflict = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 10),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [conflict])),
      );
      addTearDown(controller.dispose);
      expect(controller.resolveConflicts(SyncConflictChoice.keepRight), 1);
      expect(conflict.effective, SyncActionType.skip);
      // keepLeft keeps the source — that direction is permitted.
      conflict.effective = SyncActionType.conflict;
      expect(controller.resolveConflicts(SyncConflictChoice.keepLeft), 1);
      expect(conflict.effective, SyncActionType.updateLeftToRight);
    });

    test('newerWins treats a sub-tolerance delta as equal and refuses '
        'flagged clocks', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(direction: SyncDirection.bidirectional),
      );
      // Default mtimeToleranceSecs is 2 — a 1-second gap is not
      // "newer", matching EntryComparator's verdict.
      final closeCall = testItem(
        'a.txt',
        left: testFile(mtimeSecs: 21),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final realGap = testItem(
        'b.txt',
        left: testFile(mtimeSecs: 1000),
        right: testFile(mtimeSecs: 20),
        suggested: SyncActionType.conflict,
        reason: SyncReason.bothChanged,
      );
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, [closeCall, realGap])),
      );
      addTearDown(controller.dispose);
      expect(controller.resolveConflicts(SyncConflictChoice.newerWins), 1);
      expect(closeCall.effective, SyncActionType.conflict);
      expect(realGap.effective, SyncActionType.updateLeftToRight);

      // An engine-flagged clock refuses even a real gap.
      realGap.effective = SyncActionType.conflict;
      controller.pairState.mtimeUnreliableRight = true;
      expect(controller.resolveConflicts(SyncConflictChoice.newerWins), 0);
      expect(realGap.effective, SyncActionType.conflict);
    });
  });

  group('updatePairDefinition', () {
    test('case overrides persist under the post-edit pairId through '
        'the rescan', () async {
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final states = MemorySyncStateStore();
      final scanner = FakeSyncScanner(
        left: testScanResult('/left', const {}),
        right: testScanResult('/right', const {}),
      );
      final pair = testSyncPair();
      final controller = SyncPlanController(
        pair: pair,
        environment: testSyncEnvironment(scratch, states: states),
        syncTasks: SyncQueueTasks(),
        scanner: scanner,
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      final originalPairId = controller.pairId!;

      // The editor's save: new endpoints plus a remote-side override
      // that disagrees with the probe — the override-mismatch rescan
      // fires, and the overrides must survive its state reload.
      final edited = SyncPair(
        id: pair.id,
        name: pair.name,
        left: const LocalEndpoint('/left2'),
        right: const LocalEndpoint('/right2'),
        rules: pair.rules,
      );
      await controller.updatePairDefinition(
        edited,
        caseOverrides: const SyncCaseOverrides(right: false),
      );
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.pairId, isNot(originalPairId));
      expect(scanner.overrides[SyncSide.right], isFalse);
      expect(controller.pairState.caseSensitiveOverrideRight, isFalse);
      // Persisted under the FINAL pair id — not the stale pre-edit one.
      final stored = await states.load(controller.pairId!);
      expect(stored.caseSensitiveOverrideRight, isFalse);
    });
  });

  group('rails', () {
    test('rail 3 gates the run behind the typed confirmation', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      // 12 deletes of 20 files on the right: > 50 % and ≥ 10.
      final items = [
        for (var i = 0; i < 12; i++)
          testItem(
            'gone$i.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
        for (var i = 0; i < 8; i++)
          testItem(
            'keep$i.txt',
            right: testFile(),
            suggested: SyncActionType.skip,
          ),
      ];
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, items, rightFileCount: 20),
        ),
      );
      addTearDown(controller.dispose);
      expect(controller.needsTypedConfirmation, isTrue);
      expect(controller.gate, isA<SyncRunNeedsConfirmation>());
      // A run() without the acknowledgement re-surfaces the gate —
      // nothing executes (items stay pending, phase never runs).
      await controller.run();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(items.first.status, SyncItemStatus.pending);
      expect(controller.syncTasks.tasks, isEmpty);
    });

    test('rail 4 refuses the plan outright — run stays disabled', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash, maxDelete: 2),
      );
      final items = [
        for (var i = 0; i < 3; i++)
          testItem(
            'gone$i.txt',
            right: testFile(),
            suggested: SyncActionType.deleteRight,
            reason: SyncReason.onlyOnRight,
          ),
      ];
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, items)),
      );
      addTearDown(controller.dispose);
      expect(controller.refusal, isNotNull);
      expect(controller.refusal!.deleteCount, 3);
      expect(controller.refusal!.maxDelete, 2);
      await controller.run(deleteConfirmed: true);
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.syncTasks.tasks, isEmpty);
    });
  });

  group('run lifecycle (real engine over temp dirs)', () {
    late Directory scratch;
    late Directory left;
    late Directory right;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('pg-sync-ctl-');
      left = Directory('${scratch.path}/left')..createSync();
      right = Directory('${scratch.path}/right')..createSync();
    });
    tearDown(() => scratch.deleteSync(recursive: true));

    SyncPlanController realController(
      SyncRuleSet rules, {
      SyncQueueTasks? tasks,
      SyncEnvironment? environment,
    }) => SyncPlanController(
      pair: testSyncPair(left: left.path, right: right.path, rules: rules),
      environment: environment ?? testSyncEnvironment(scratch),
      syncTasks: tasks ?? SyncQueueTasks(),
      deviceId: 'test-device',
      rsyncEndpoints: resolveRsyncEndpoints,
    );

    Future<({SyncEnvironment environment, String journalPath, SyncPair pair})>
    leaveInterruptedRestore(
      _RestoreCleanupFailureFileSystem fileSystem, {
      SyncRuleSet? rules,
    }) async {
      final effectiveRules =
          rules ??
          const SyncRuleSet(
            direction: SyncDirection.leftToRight,
            deletions: DeletionPolicy.trash,
            conflictDefault: ConflictDefault.keepLeft,
          );
      final pair = testSyncPair(
        left: left.path,
        right: right.path,
        rules: effectiveRules,
      );
      final environment = testSyncEnvironment(
        scratch,
        localFileSystem: () => fileSystem,
      );
      final controller = SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );

      File('${left.path}/entry').writeAsStringSync('replacement');
      Directory('${right.path}/entry').createSync();
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run();

      fileSystem.failStageDelete = true;
      await expectLater(
        controller.restoreTrashed(),
        throwsA(isA<RemoteFileException>()),
      );
      final journalPath = controller.lastRun!.journal.path;
      controller.dispose();

      return (environment: environment, journalPath: journalPath, pair: pair);
    }

    SyncPlanController recoveryController({
      required SyncEnvironment environment,
      required SyncPair pair,
      required SyncPairScanner scanner,
    }) => SyncPlanController(
      pair: pair,
      environment: environment,
      syncTasks: SyncQueueTasks(),
      scanner: scanner,
      deviceId: 'test-device',
      rsyncEndpoints: resolveRsyncEndpoints,
    );

    test('copy run completes, item rows land in the panel task', () async {
      File('${left.path}/a.txt').writeAsStringSync('alpha');
      File('${left.path}/b.txt').writeAsStringSync('beta');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(), tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.stats!.newFilesTo(SyncSide.right), 2);
      expect(
        File(
          p.join(
            left.path,
            RemoteTrash.rootDirectoryName,
            syncTrashRootMarkerName,
            'identity',
          ),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(
            right.path,
            RemoteTrash.rootDirectoryName,
            syncTrashRootMarkerName,
            'identity',
          ),
        ).existsSync(),
        isTrue,
      );
      await pumpUntil(() => !controller.trashPurgeBlocksActions);
      expect(controller.trashPurgeBlocksActions, isFalse);

      await controller.run();
      expect(controller.phase, SyncPlanPhase.completed);
      expect(File('${right.path}/a.txt').readAsStringSync(), 'alpha');
      // The activity-panel task exists and finished completed.
      expect(tasks.tasks, hasLength(1));
      final task = tasks.tasks.single;
      expect(task.state, TransferTaskState.completed);
      expect(task.items.length, 2);
      // sync_state landed under the canonical pair id.
      expect(controller.pairId, isNotEmpty);
    });

    test('run preflight freezes the reviewed pair and plan', () async {
      File('${left.path}/a.txt').writeAsStringSync('alpha');
      final controller = realController(const SyncRuleSet());
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      final reviewedPair = controller.pair;
      final reviewedItem = controller.plan!.items.single;
      final reviewedAction = reviewedItem.effective;

      final run = controller.run();
      final modeUpdate = controller.setMode(
        direction: SyncDirection.rightToLeft,
      );
      final pairUpdate = controller.updatePairDefinition(
        testSyncPair(
          left: left.path,
          right: right.path,
          rules: const SyncRuleSet(direction: SyncDirection.rightToLeft),
        ),
      );
      controller.applyOverride(reviewedItem, SyncActionType.skip);

      expect(controller.planMutationsBlocked, isTrue);
      expect(controller.pair, same(reviewedPair));
      expect(reviewedItem.effective, reviewedAction);
      expect(await pairUpdate, isFalse);
      await modeUpdate;
      await run;

      expect(File('${right.path}/a.txt').readAsStringSync(), 'alpha');
    });

    test('a changed trash marker blocks the reviewed run', () async {
      File('${left.path}/a.txt').writeAsStringSync('alpha');
      final controller = realController(const SyncRuleSet());
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      final marker = File(
        p.join(
          right.path,
          RemoteTrash.rootDirectoryName,
          syncTrashRootMarkerName,
          'identity',
        ),
      );
      marker.writeAsStringSync('changed');

      await controller.run();

      expect(controller.phase, SyncPlanPhase.failed);
      expect(File('${right.path}/a.txt').existsSync(), isFalse);
    });

    test('permanent delete rejects a host changed after its scan', () async {
      final remoteFileSystem = _UnavailableTrashFileSystem();
      final connections = _RetargetableConnections(remoteFileSystem);
      var config = _serverConfig('one.example.com');
      final bookmarks = FakeBookmarkStore();
      addTearDown(bookmarks.close);
      final serverConfigs = AppServerConfigSource(
        bookmarks: bookmarks,
        catalogLookup: (_) => config,
      );
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
        deviceId: () async => 'test-device',
        connections: connections,
        serverConfigs: serverConfigs,
      );
      final remote = RemoteEndpoint(
        server: const BookmarkServerRef(serverConfigId: 'target'),
        path: left.path,
      );
      final pair = SyncPair(
        id: 'retargeted-delete',
        name: 'Retargeted delete',
        left: remote,
        right: LocalEndpoint(right.path),
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.permanent,
          backups: BackupPolicy.none,
        ),
      );
      final oldFile = File(p.join(left.path, 'old.txt'))
        ..writeAsStringSync('old');
      final plan = testPlan(pair, [
        testItem(
          'old.txt',
          left: testFile(size: 3),
          suggested: SyncActionType.deleteLeft,
          reason: SyncReason.onlyOnLeft,
        ),
      ], leftFileCount: 1);
      final controller = SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: SyncQueueTasks(),
        scanner: _EndpointTouchingScanner(environment),
        differ: FakeSyncDiffer(plan),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );
      addTearDown(controller.dispose);

      await _ready(controller);
      await pumpUntil(() => connections.releaseCount > 0);
      config = _serverConfig('two.example.com');
      connections.endpointIdentity = _endpointIdentity('two.example.com');

      await controller.run(deleteConfirmed: true);

      expect(controller.phase, SyncPlanPhase.failed);
      expect(controller.syncTasks.tasks, isEmpty);
      expect(oldFile.existsSync(), isTrue);
    });

    test('a failed item surfaces failed phase and retries to done', () async {
      final source = File('${left.path}/a.txt')..writeAsStringSync('x');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(), tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // Vanish the source between preview and run — rail 7 flips the
      // item conflicted/failed rather than copying stale bytes.
      source.deleteSync();
      await controller.run();
      expect(
        controller.phase,
        isIn([SyncPlanPhase.failed, SyncPlanPhase.completed]),
      );
      final item = controller.lastRun!.plan.items.firstWhere(
        (i) => i.relativePath == 'a.txt',
      );
      expect(
        item.status,
        isIn([SyncItemStatus.failed, SyncItemStatus.conflicted]),
      );
      if (item.status == SyncItemStatus.failed) {
        expect(controller.canRetryFailed, isTrue);
        source.writeAsStringSync('x');
        await controller.retryFailed();
        expect(item.status, SyncItemStatus.done);
      }
    });

    test('mirror delete trashes and restoreTrashed returns the file', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final tasks = SyncQueueTasks();
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        tasks: tasks,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      // 1 deletion of the side's 1 file trips rail 3's 90 % floor —
      // the typed acknowledgement is part of the run call.
      expect(controller.needsTypedConfirmation, isTrue);
      await controller.run(deleteConfirmed: true);
      expect(controller.phase, SyncPlanPhase.completed);
      expect(File('${right.path}/old.txt').existsSync(), isFalse);
      expect(controller.canRestore, isTrue);

      final report = await controller.restoreTrashed();
      expect(report.restored, isNotEmpty);
      expect(File('${right.path}/old.txt').readAsStringSync(), 'old');
    });

    test('empty-directory replacement remains restorable', () async {
      File('${left.path}/entry').writeAsStringSync('replacement');
      Directory('${right.path}/entry').createSync();
      final controller = realController(
        const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
          conflictDefault: ConflictDefault.keepLeft,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(
        controller.plan!.items.single.effective,
        SyncActionType.copyLeftToRight,
      );

      await controller.run();

      expect(File('${right.path}/entry').readAsStringSync(), 'replacement');
      expect(controller.canRestore, isTrue);

      final report = await controller.restoreTrashed();

      expect(report.restored, contains('entry'));
      expect(Directory('${right.path}/entry').existsSync(), isTrue);
    });

    test('incomplete restore blocks mutations but admits recovery', () async {
      File('${left.path}/entry').writeAsStringSync('replacement');
      Directory('${right.path}/entry').createSync();
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final controller = realController(
        const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
          conflictDefault: ConflictDefault.keepLeft,
        ),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run();
      final reviewedPair = controller.pair;
      final reviewedPlan = controller.plan;

      fileSystem.failStageDelete = true;
      await expectLater(
        controller.restoreTrashed(),
        throwsA(isA<RemoteFileException>()),
      );

      expect(controller.lastRun!.journal.hasIncompleteRestore, isTrue);
      expect(controller.planMutationsBlocked, isTrue);
      expect(controller.canRestore, isTrue);
      expect(controller.canRetryFailed, isFalse);
      expect(controller.prepareFullTrashPurge(), isNull);
      final recoveryRun = controller.lastRun;

      await controller.updateRules(
        const SyncRuleSet(direction: SyncDirection.rightToLeft),
      );
      await controller.rescan();
      await controller.run();

      expect(controller.pair, same(reviewedPair));
      expect(controller.plan, same(reviewedPlan));
      expect(controller.lastRun, same(recoveryRun));

      fileSystem.failStageDelete = false;
      final report = await controller.restoreTrashed();

      expect(report.restored, contains('entry'));
      expect(controller.lastRun!.journal.hasIncompleteRestore, isFalse);
      expect(Directory('${right.path}/entry').existsSync(), isTrue);
    });

    test(
      'restart detects recovery before scanning and resumes after cancel',
      () async {
        final fileSystem = _RestoreCleanupFailureFileSystem();
        final interrupted = await leaveInterruptedRestore(fileSystem);
        final scanner = _CountingScanner(interrupted.environment);
        final controller = recoveryController(
          environment: interrupted.environment,
          pair: interrupted.pair,
          scanner: scanner,
        );
        addTearDown(controller.dispose);

        controller.start();
        controller.start();
        await pumpUntil(() => controller.phase == SyncPlanPhase.recovery);

        expect(scanner.calls, 0);
        expect(controller.lastRun, isNull);
        expect(controller.recoveryPending, isTrue);
        expect(controller.restoreImpact, isNotNull);
        expect(controller.canRestore, isTrue);
        expect(controller.planMutationsBlocked, isTrue);

        final originalPair = controller.pair;
        await controller.rescan();
        await controller.updateRules(const SyncRuleSet());
        await controller.run();
        await controller.retryFailed();
        expect(controller.pair, same(originalPair));
        expect(scanner.calls, 0);
        expect(controller.prepareFullTrashPurge(), isNull);

        await expectLater(
          controller.restoreTrashed(),
          throwsA(
            isA<RemoteFileException>().having(
              (error) => error.kind,
              'kind',
              RemoteFileErrorKind.disconnected,
            ),
          ),
        );
        expect(
          controller.errorMessage,
          'connection lost during restore cleanup',
        );
        expect(controller.errorKind, RemoteFileErrorKind.disconnected);
        expect(controller.phase, SyncPlanPhase.recovery);
        expect(controller.recoveryPending, isTrue);
        expect(controller.canRestore, isTrue);
        expect(scanner.calls, 0);

        fileSystem.failStageDelete = false;
        fileSystem.gateTrashVerification();
        final cancelledRestore = controller.restoreTrashed();
        await fileSystem.trashVerificationStarted;
        controller.cancelRestore();
        fileSystem.releaseTrashVerification();
        final cancelledReport = await cancelledRestore;

        expect(cancelledReport.restored, isEmpty);
        expect(controller.phase, SyncPlanPhase.recovery);
        expect(controller.recoveryPending, isTrue);
        expect(controller.canRestore, isTrue);
        expect(scanner.calls, 0);

        final report = await controller.restoreTrashed();

        expect(report.restored, contains('entry'));
        expect(controller.recoveryPending, isFalse);
        expect(controller.phase, SyncPlanPhase.ready);
        expect(scanner.calls, 2);
        expect(Directory('${right.path}/entry').existsSync(), isTrue);
      },
    );

    test('rescan before start still discovers recovery first', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);

      await controller.rescan();

      expect(controller.phase, SyncPlanPhase.recovery);
      expect(controller.recoveryPending, isTrue);
      expect(scanner.calls, 0);
    });

    test('recovery discovery failure retries before scanning', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);
      fileSystem.failTrashVerification = true;

      controller.start();
      await pumpUntil(() => controller.phase != SyncPlanPhase.scanning);

      expect(controller.phase, SyncPlanPhase.error);
      expect(controller.errorMessage, 'restore transport unavailable');
      expect(controller.recoveryPending, isFalse);
      expect(controller.planMutationsBlocked, isTrue);
      expect(controller.canRescan, isTrue);
      expect(scanner.calls, 0);

      fileSystem.failTrashVerification = false;
      await controller.rescan();

      expect(controller.phase, SyncPlanPhase.recovery);
      expect(controller.recoveryPending, isTrue);
      expect(scanner.calls, 0);
    });

    test('recovery journal reopen failure is reported in state', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);
      fileSystem.failStageDelete = false;
      controller.start();
      await pumpUntil(() => controller.canRestore);
      await File(
        interrupted.journalPath,
      ).writeAsString('not a sync journal\n', flush: true);

      await expectLater(
        controller.restoreTrashed(),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.other,
          ),
        ),
      );
      expect(controller.phase, SyncPlanPhase.recovery);
      expect(controller.recoveryPending, isTrue);
      expect(controller.errorMessage, isNotEmpty);
      expect(controller.errorKind, RemoteFileErrorKind.other);
      expect(scanner.calls, 0);
    });

    test('recovery lease failure is reported as a restore error', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);
      fileSystem.failStageDelete = false;
      controller.start();
      await pumpUntil(() => controller.canRestore);
      final lockPath = p.join(
        interrupted.environment.syncRunsDirectory,
        kSyncTrashActivityDirectoryName,
      );
      final lockDirectory = Directory(lockPath);
      if (lockDirectory.existsSync()) lockDirectory.deleteSync(recursive: true);
      File(lockPath).writeAsStringSync('occupied');

      await expectLater(
        controller.restoreTrashed(),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.other,
          ),
        ),
      );
      expect(controller.phase, SyncPlanPhase.recovery);
      expect(controller.recoveryPending, isTrue);
      expect(controller.errorMessage, isNotEmpty);
      expect(controller.errorKind, RemoteFileErrorKind.other);
      expect(scanner.calls, 0);
    });

    test('recovery rebinds roots before external-trash mutation', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(
        fileSystem,
        rules: SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
          conflictDefault: ConflictDefault.keepLeft,
          trashPathLeft: p.join(scratch.path, 'external-left-trash'),
          trashPathRight: p.join(scratch.path, 'external-right-trash'),
        ),
      );
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.canRestore);
      final changedRoot = Directory(p.join(scratch.path, 'changed-right'))
        ..createSync();
      fileSystem.retargetCanonicalRoot(
        interrupted.environment.rootFor(interrupted.pair.right),
        await changedRoot.resolveSymbolicLinks(),
      );

      await expectLater(
        controller.restoreTrashed(),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
      expect(controller.errorKind, RemoteFileErrorKind.conflict);
      expect(controller.phase, SyncPlanPhase.recovery);
      expect(controller.recoveryPending, isTrue);
      expect(controller.canRestore, isTrue);
      expect(scanner.calls, 0);
    });

    test('recovery discovery releases its remote lease', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final connections = _RetargetableConnections(fileSystem);
      final bookmarks = FakeBookmarkStore();
      addTearDown(bookmarks.close);
      final serverConfigs = AppServerConfigSource(
        bookmarks: bookmarks,
        catalogLookup: (_) => _serverConfig('one.example.com'),
      );
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
        deviceId: () async => 'test-device',
        localFileSystem: () => fileSystem,
        connections: connections,
        serverConfigs: serverConfigs,
      );
      final pair = SyncPair(
        id: 'remote-recovery',
        name: 'Remote recovery',
        left: RemoteEndpoint(
          server: const BookmarkServerRef(serverConfigId: 'target'),
          path: left.path,
        ),
        right: LocalEndpoint(right.path),
        rules: const SyncRuleSet(
          direction: SyncDirection.leftToRight,
          deletions: DeletionPolicy.trash,
          conflictDefault: ConflictDefault.keepLeft,
        ),
      );
      final original = SyncPlanController(
        pair: pair,
        environment: environment,
        syncTasks: SyncQueueTasks(),
        deviceId: 'test-device',
        rsyncEndpoints: resolveRsyncEndpoints,
      );

      File('${left.path}/entry').writeAsStringSync('replacement');
      Directory('${right.path}/entry').createSync();
      original.start();
      await pumpUntil(() => original.phase == SyncPlanPhase.ready);
      await environment.releaseRemoteLeases();
      await original.run();
      fileSystem.failStageDelete = true;
      await expectLater(
        original.restoreTrashed(),
        throwsA(isA<RemoteFileException>()),
      );
      original.dispose();
      await environment.releaseRemoteLeases();
      final releasesBeforeDiscovery = connections.releaseCount;
      final scanner = _CountingScanner(environment);
      final recovery = recoveryController(
        environment: environment,
        pair: pair,
        scanner: scanner,
      );
      addTearDown(recovery.dispose);

      recovery.start();
      await pumpUntil(() => recovery.canRestore);

      expect(recovery.phase, SyncPlanPhase.recovery);
      expect(scanner.calls, 0);
      expect(connections.releaseCount, releasesBeforeDiscovery + 1);
    });

    test('restart selects the exact-root recovery candidate', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final source = File(interrupted.journalPath);
      final lines = await source.readAsLines();
      final headerIndex = lines.indexWhere((line) => line.trim().isNotEmpty);
      final header = Map<String, Object?>.from(
        jsonDecode(lines[headerIndex]) as Map,
      );
      header['runId'] = 'newer-distinct-roots';
      header['startedAt'] = DateTime.parse(
        header['startedAt']! as String,
      ).add(const Duration(days: 1)).toIso8601String();
      header['canonicalRootLeft'] = p.join(scratch.path, 'other-left');
      header['canonicalRootRight'] = p.join(scratch.path, 'other-right');
      lines[headerIndex] = jsonEncode(header);
      await File(
        p.join(interrupted.environment.syncRunsDirectory, 'newer.jsonl'),
      ).writeAsString('${lines.join('\n')}\n', flush: true);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.recovery);

      expect(controller.recoveryPending, isTrue);
      expect(controller.canRestore, isTrue);
      expect(scanner.calls, 0);
    });

    test('distinct-root pair-id collision proceeds to scan', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final journal = File(interrupted.journalPath);
      final lines = await journal.readAsLines();
      final headerIndex = lines.indexWhere((line) => line.trim().isNotEmpty);
      final header =
          Map<String, Object?>.from(jsonDecode(lines[headerIndex]) as Map)
            ..['canonicalRootLeft'] = p.join(scratch.path, 'other-left')
            ..['canonicalRootRight'] = p.join(scratch.path, 'other-right');
      lines[headerIndex] = jsonEncode(header);
      await journal.writeAsString('${lines.join('\n')}\n', flush: true);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      expect(controller.recoveryPending, isFalse);
      expect(scanner.calls, 2);
    });

    test('matching unreadable recovery blocks scan and restore', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      await File(interrupted.journalPath).writeAsString(
        '\n${jsonEncode(const <String, Object?>{'v': 999, 'type': 'futureRecovery'})}\n',
        mode: FileMode.append,
        flush: true,
      );
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.recovery);

      expect(scanner.calls, 0);
      expect(controller.recoveryPending, isFalse);
      expect(controller.restoreImpact, isNull);
      expect(controller.canRestore, isFalse);
      expect(controller.planMutationsBlocked, isTrue);
      expect(controller.errorMessage, interrupted.journalPath);
      final report = await controller.restoreTrashed();
      expect(report.restored, isEmpty);
      expect(scanner.calls, 0);
    });

    test('unrelated unreadable recovery does not block scanning', () async {
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final interrupted = await leaveInterruptedRestore(fileSystem);
      final journal = File(interrupted.journalPath);
      final lines = await journal.readAsLines();
      final headerIndex = lines.indexWhere((line) => line.trim().isNotEmpty);
      final header = Map<String, Object?>.from(
        jsonDecode(lines[headerIndex]) as Map,
      )..['pairId'] = 'unrelated-pair';
      lines[headerIndex] = jsonEncode(header);
      lines.add(
        jsonEncode(const <String, Object?>{'v': 999, 'type': 'futureRecovery'}),
      );
      await journal.writeAsString('${lines.join('\n')}\n', flush: true);
      final scanner = _CountingScanner(interrupted.environment);
      final controller = recoveryController(
        environment: interrupted.environment,
        pair: interrupted.pair,
        scanner: scanner,
      );
      addTearDown(controller.dispose);

      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      expect(controller.recoveryPending, isFalse);
      expect(scanner.calls, 2);
    });

    test('restore reserves its trash roots against purge', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final fileSystem = _RestoreGateFileSystem();
      final activity = SyncTrashActivityRegistry();
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: '${scratch.path}/sync_runs',
        deviceId: () async => 'test-device',
        localFileSystem: () => fileSystem,
        trashActivity: activity,
      );
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);

      final restore = controller.restoreTrashed();
      await fileSystem.restoreStarted.future;
      final location = await environment.resolveTrashLocation(
        endpoint: controller.pair.right,
        canonicalRoot: right.path,
        rules: controller.pair.rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final purge = await activity.tryBeginPurge([
        location,
      ], SyncTrashPurgeAdmission.requireIdle);
      final restoreHeldLease = purge == null;
      await purge?.close();
      fileSystem.releaseRestore();
      await restore;

      expect(restoreHeldLease, isTrue);
    });

    test('restore report survives trash-lease release failure', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/new.txt').writeAsStringSync('new');
      final lockDirectory = p.join(scratch.path, 'activity-locks');
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
        deviceId: () async => 'test-device',
        trashActivity: SyncTrashActivityRegistry(lockDirectory: lockDirectory),
      );
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      final location = await environment.resolveTrashLocation(
        endpoint: controller.pair.right,
        canonicalRoot: right.path,
        rules: controller.pair.rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );

      final report = await _withFailingActivityUnlock(
        lockDirectory: lockDirectory,
        location: location,
        body: controller.restoreTrashed,
      );

      expect(report.restored, contains('old.txt'));
      expect(File('${right.path}/old.txt').readAsStringSync(), 'old');
    });

    test('lease release failure does not mask the restore error', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/new.txt').writeAsStringSync('new');
      final lockDirectory = p.join(scratch.path, 'activity-locks');
      final fileSystem = _RestoreCleanupFailureFileSystem();
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
        deviceId: () async => 'test-device',
        localFileSystem: () => fileSystem,
        trashActivity: SyncTrashActivityRegistry(lockDirectory: lockDirectory),
      );
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      final location = await environment.resolveTrashLocation(
        endpoint: controller.pair.right,
        canonicalRoot: right.path,
        rules: controller.pair.rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );
      fileSystem.failTrashVerification = true;

      await expectLater(
        _withFailingActivityUnlock(
          lockDirectory: lockDirectory,
          location: location,
          body: controller.restoreTrashed,
        ),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.message,
            'message',
            'restore transport unavailable',
          ),
        ),
      );
    });

    test('restore cancellation releases its trash lease', () async {
      File('${right.path}/old-a.txt').writeAsStringSync('a');
      File('${right.path}/old-b.txt').writeAsStringSync('b');
      File('${left.path}/new.txt').writeAsStringSync('new');
      final fileSystem = _RestoreGateFileSystem();
      final activity = SyncTrashActivityRegistry();
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: '${scratch.path}/sync_runs',
        deviceId: () async => 'test-device',
        localFileSystem: () => fileSystem,
        trashActivity: activity,
      );
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);

      final restore = controller.restoreTrashed();
      await fileSystem.restoreStarted.future;
      expect(controller.isRestoringTrash, isTrue);
      controller.cancelRestore();
      fileSystem.releaseRestore();
      final report = await restore;

      expect(report.restored, hasLength(1));
      expect(controller.isRestoringTrash, isFalse);
      expect(
        [
          'old-a.txt',
          'old-b.txt',
        ].where((name) => File('${right.path}/$name').existsSync()),
        hasLength(1),
      );
      final location = await environment.resolveTrashLocation(
        endpoint: controller.pair.right,
        canonicalRoot: right.path,
        rules: controller.pair.rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final purge = await activity.tryBeginPurge([
        location,
      ], SyncTrashPurgeAdmission.requireIdle);
      expect(purge, isNotNull);
      await purge!.close();
    });

    test('restore blocks another run on the same controller', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final fileSystem = _RestoreGateFileSystem();
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);

      final restore = controller.restoreTrashed();
      await fileSystem.restoreStarted.future;
      final restoringRun = controller.lastRun;
      await controller.run(deleteConfirmed: true);

      expect(controller.lastRun, same(restoringRun));
      fileSystem.releaseRestore();
      await restore;
    });

    test('restore blocks a run on another controller', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final fileSystem = _TrashVerificationGateFileSystem();
      final environment = testSyncEnvironment(
        scratch,
        localFileSystem: () => fileSystem,
      );
      final restoringController = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(restoringController.dispose);
      restoringController.start();
      await pumpUntil(() => restoringController.phase == SyncPlanPhase.ready);
      await restoringController.run(deleteConfirmed: true);

      File('${left.path}/a.txt').writeAsStringSync('changed content');
      final runningController = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(runningController.dispose);
      runningController.start();
      await pumpUntil(() => runningController.phase == SyncPlanPhase.ready);
      await pumpUntil(() => runningController.canPurgeTrash);

      fileSystem.armVerification();
      final restore = restoringController.restoreTrashed();
      await fileSystem.verificationStarted.future;
      addTearDown(fileSystem.releaseVerification);
      await runningController.run(deleteConfirmed: true);

      expect(runningController.phase, SyncPlanPhase.ready);
      expect(File('${right.path}/a.txt').readAsStringSync(), 'a');

      fileSystem.releaseVerification();
      await restore;
    });

    test('active run blocks restore on another controller', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final fileSystem = _CancelAwareGateFs();
      final environment = testSyncEnvironment(
        scratch,
        localFileSystem: () => fileSystem,
      );
      final restoringController = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(restoringController.dispose);
      restoringController.start();
      await pumpUntil(() => restoringController.phase == SyncPlanPhase.ready);
      await restoringController.run(deleteConfirmed: true);

      File('${left.path}/a.txt').writeAsStringSync('changed content');
      final runningController = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(runningController.dispose);
      runningController.start();
      await pumpUntil(() => runningController.phase == SyncPlanPhase.ready);
      await pumpUntil(() => runningController.canPurgeTrash);

      fileSystem.arm();
      addTearDown(fileSystem.release);
      final run = runningController.run(deleteConfirmed: true);
      await fileSystem.uploadStarted;
      final blockedReport = await restoringController.restoreTrashed();

      expect(blockedReport.restored, isEmpty);
      expect(File('${right.path}/old.txt').existsSync(), isFalse);
      expect(restoringController.canRestore, isTrue);

      fileSystem.release();
      await run;
      final report = await restoringController.restoreTrashed();

      expect(report.restored, contains('old.txt'));
      expect(File('${right.path}/old.txt').readAsStringSync(), 'old');
    });

    test('dispose during restore preflight prevents restoration', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final fileSystem = _TrashVerificationGateFileSystem();
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
      );
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      fileSystem.armVerification();

      final restore = controller.restoreTrashed();
      await fileSystem.verificationStarted.future;
      controller.dispose();
      fileSystem.releaseVerification();
      final report = await restore;

      expect(report.restored, isEmpty);
      expect(File('${right.path}/old.txt').existsSync(), isFalse);
    });

    test('restore preflight blocks pair and plan mutations', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final fileSystem = _TrashVerificationGateFileSystem();
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      final reviewedPair = controller.pair;
      final reviewedPlan = controller.plan!;
      final reviewedItem = reviewedPlan.items.first;
      final reviewedAction = reviewedItem.effective;
      fileSystem.armVerification();

      final restore = controller.restoreTrashed();
      await fileSystem.verificationStarted.future;
      final rulesUpdate = controller.updateRules(
        const SyncRuleSet(direction: SyncDirection.rightToLeft),
      );
      final rescan = controller.rescan();
      controller.applyOverride(reviewedItem, SyncActionType.skip);
      await Future<void>.delayed(Duration.zero);

      expect(controller.pair, same(reviewedPair));
      expect(controller.plan, same(reviewedPlan));
      expect(reviewedItem.effective, reviewedAction);
      expect(controller.phase, SyncPlanPhase.completed);

      fileSystem.releaseVerification();
      final report = await restore;
      await Future.wait([rulesUpdate, rescan]);

      expect(report.restored, isNotEmpty);
      expect(File('${right.path}/old.txt').readAsStringSync(), 'old');
    });

    test('purging the last run disables restore immediately', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      expect(controller.canRestore, isTrue);

      final request = await controller.prepareFullTrashPurgeLive();
      expect(request, isNotNull);
      await controller.purgeTrash(request!);

      expect(controller.canRestore, isFalse);
    });

    test('a purge lock failure reports an active run', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final lockPath = p.join(scratch.path, 'purge-locks');
      final environment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
        deviceId: () async => 'test-device',
        trashActivity: SyncTrashActivityRegistry(lockDirectory: lockPath),
      );
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
        environment: environment,
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      final request = await controller.prepareFullTrashPurgeLive();
      expect(request, isNotNull);

      Directory(lockPath).deleteSync(recursive: true);
      File(lockPath).writeAsStringSync('occupied');

      await expectLater(
        controller.purgeTrash(request!),
        throwsA(isA<SyncTrashActiveRunException>()),
      );
    });

    test('restore reopens a journal purged by another process', () async {
      File('${right.path}/old.txt').writeAsStringSync('old');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run(deleteConfirmed: true);
      expect(controller.canRestore, isTrue);

      final staleRun = controller.lastRun!;
      final scope = staleRun.journal.record.trashScopeRight!;
      final external = await SyncRunJournal.open(staleRun.journal.path);
      await external.markPurged(trashScope: scope);
      expect(controller.canRestore, isTrue);

      final report = await controller.restoreTrashed();

      expect(report.restored, isEmpty);
      expect(File('${right.path}/old.txt').existsSync(), isFalse);
      expect(controller.canRestore, isFalse);
    });

    test('the typed confirmation carries through to a real run', () async {
      // 10 deletes of 11 files on the right trips rail 3's fraction
      // clause (≥ 10 and > 50 %, under the 90 % floor).
      for (var i = 0; i < 10; i++) {
        File('${right.path}/gone$i.txt').writeAsStringSync('x');
      }
      File('${right.path}/keep.txt').writeAsStringSync('k');
      File('${left.path}/a.txt').writeAsStringSync('a');
      final controller = realController(
        const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.needsTypedConfirmation, isTrue);
      await controller.run();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(File('${right.path}/gone0.txt').existsSync(), isTrue);
      await controller.run(deleteConfirmed: true);
      expect(controller.phase, SyncPlanPhase.completed);
      expect(File('${right.path}/gone0.txt').existsSync(), isFalse);
    });

    test('a retry rebinds the task — panel pause/cancel reach the '
        'retry run', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs();
      final tasks = SyncQueueTasks();
      final controller = realController(
        const SyncRuleSet(),
        tasks: tasks,
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // Fail the run: uploads throw — `failed` is the status
      // retryFailed re-runs (a vanished source reads `conflicted`).
      gateFs.failUploads = true;
      await controller.run();
      expect(controller.canRetryFailed, isTrue);
      final task = tasks.tasks.single;
      final binding = tasks.bindingFor(task.id)!;
      final firstCancellation = binding.cancellation;
      final firstPause = binding.pause;

      // Arm the gate so the retry blocks mid-upload, then drive the
      // panel verbs: they must land on the RETRY's controls, not the
      // dead run's detached objects.
      gateFs.failUploads = false;
      gateFs.arm();
      unawaited(controller.retryFailed());
      await pumpUntil(() => controller.isRunning);
      expect(binding.cancellation, isNot(same(firstCancellation)));
      expect(binding.pause, isNot(same(firstPause)));
      expect(tasks.cancel(task.id), isTrue);
      await pumpUntil(() => !controller.isRunning);
      expect(controller.phase, SyncPlanPhase.cancelled);
    });

    test('retry reopens a journal purged by another process', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs()..failUploads = true;
      final controller = realController(
        const SyncRuleSet(),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run();
      expect(controller.canRetryFailed, isTrue);

      final staleRun = controller.lastRun!;
      final external = await SyncRunJournal.open(staleRun.journal.path);
      await external.markPurged(trashScope: external.record.trashScopeRight);
      gateFs.failUploads = false;
      expect(controller.canRetryFailed, isTrue);

      await controller.retryFailed();

      expect(staleRun.plan.items.single.status, SyncItemStatus.failed);
      expect(controller.canRetryFailed, isFalse);
    });

    test('dispose during retry preflight does not start the retry', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final fileSystem = _TrashVerificationGateFileSystem()..failUploads = true;
      final controller = realController(
        const SyncRuleSet(),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => fileSystem,
        ),
      );
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      await controller.run();
      expect(controller.phase, SyncPlanPhase.failed);
      fileSystem.failUploads = false;
      fileSystem.armVerification();

      final retry = controller.retryFailed();
      await fileSystem.verificationStarted.future;
      controller.dispose();
      fileSystem.releaseVerification();
      await retry;

      expect(controller.phase, SyncPlanPhase.failed);
      expect(File('${right.path}/a.txt').existsSync(), isFalse);
    });

    test('a fresh run retires the previous task row\u2019s retry', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(), tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      File('${left.path}/a.txt').deleteSync();
      await controller.run();
      final firstTask = tasks.tasks.single;
      expect(tasks.canRetry(firstTask.id), isTrue);

      // A fresh run supersedes the failed one — the old row must not
      // keep routing retry into the newest _lastRun.
      File('${left.path}/a.txt').writeAsStringSync('x');
      await controller.run();
      expect(controller.phase, SyncPlanPhase.completed);
      expect(tasks.canRetry(firstTask.id), isFalse);
    });

    test('a rescan retires Retry Failed and the stale task row', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final tasks = SyncQueueTasks();
      final controller = realController(const SyncRuleSet(), tasks: tasks);
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      File('${left.path}/a.txt').deleteSync();
      await controller.run();
      expect(controller.canRetryFailed, isTrue);
      final firstTask = tasks.tasks.single;

      // A rescan renders a NEW plan — retrying the old run's failures
      // would execute work the reviewed plan no longer shows (rail 1).
      File('${left.path}/a.txt').writeAsStringSync('x');
      await controller.rescan();
      expect(controller.phase, SyncPlanPhase.ready);
      expect(controller.canRetryFailed, isFalse);
      expect(tasks.canRetry(firstTask.id), isFalse);
    });

    test('a cancelled run never stamps lastRunAt', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs();
      final controller = realController(
        const SyncRuleSet(),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // A cancelled run is not a sync — 'last synced' stays unset.
      gateFs.arm();
      unawaited(controller.run());
      await pumpUntil(() => controller.isRunning);
      controller.cancelRun();
      await pumpUntil(() => !controller.isRunning);
      expect(controller.phase, SyncPlanPhase.cancelled);
      expect(controller.pairState.lastRunAt, isNull);
    });

    test(
      'the queue wait seam follows a controller run to cancellation',
      () async {
        File('${left.path}/a.txt').writeAsStringSync('x');
        final gateFs = _CancelAwareGateFs();
        final tasks = SyncQueueTasks();
        final controller = realController(
          const SyncRuleSet(),
          tasks: tasks,
          environment: testSyncEnvironment(
            scratch,
            localFileSystem: () => gateFs,
          ),
        );
        addTearDown(controller.dispose);
        controller.start();
        await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

        gateFs.arm();
        unawaited(controller.run());
        await pumpUntil(() => controller.isRunning);

        var settled = false;
        final wait = tasks.waitForSettlingRuns().then((_) => settled = true);
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);

        controller.cancelRun();
        await wait;
        expect(controller.phase, SyncPlanPhase.cancelled);
      },
    );

    test('a retry that completes stamps lastRunAt like a run', () async {
      File('${left.path}/a.txt').writeAsStringSync('x');
      final gateFs = _CancelAwareGateFs();
      final controller = realController(
        const SyncRuleSet(),
        environment: testSyncEnvironment(
          scratch,
          localFileSystem: () => gateFs,
        ),
      );
      addTearDown(controller.dispose);
      controller.start();
      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);

      // The failed item is what retryFailed re-runs — an upload throw
      // rather than a vanished source (which reads `conflicted`).
      gateFs.failUploads = true;
      await controller.run();
      expect(controller.canRetryFailed, isTrue);
      controller.pairState.lastRunAt = null;
      gateFs.failUploads = false;
      await controller.retryFailed();
      expect(controller.pairState.lastRunAt, isNotNull);
    });
  });

  // 05 §2.1's export seam: `rsyncExport` renders the effective
  // ruleset with the plan's override count and engine-imposed skips;
  // the resolver is the injected seam the shell binds to the catalog.
  group('rsyncExport', () {
    final stamp = DateTime.utc(2026, 9, 22, 15, 4, 7);

    test('renders the effective ruleset with the injected resolver', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(deletions: DeletionPolicy.trash),
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, [
            testItem(
              'a.txt',
              left: testFile(size: 4),
              suggested: SyncActionType.copyLeftToRight,
              reason: SyncReason.onlyOnLeft,
            ),
          ]),
        ),
      );
      addTearDown(controller.dispose);

      expect(controller.canExportRsync, isTrue);
      final export = controller.rsyncExport(now: stamp);
      expect(export, isNotNull);
      expect(export!.text, contains('rsync -n -i'));
      expect(export.text, contains('--delete-delay'));
      expect(export.text, contains('rsync-20260922-150407'));
      expect(export.permanentDeletions, isFalse);
    });

    test('permanent+none flags the toast differentiation', () async {
      final pair = testSyncPair(
        rules: const SyncRuleSet(
          deletions: DeletionPolicy.permanent,
          backups: BackupPolicy.none,
        ),
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, [
            testItem(
              'old.txt',
              right: testFile(),
              suggested: SyncActionType.deleteRight,
              reason: SyncReason.onlyOnRight,
            ),
          ]),
        ),
      );
      addTearDown(controller.dispose);

      final export = controller.rsyncExport(now: stamp)!;
      expect(export.permanentDeletions, isTrue);
    });

    test('manual overrides and engine skips land in the export', () async {
      final pair = testSyncPair();
      final plan = testPlan(pair, [
        testItem(
          'a.txt',
          left: testFile(size: 4),
          suggested: SyncActionType.copyLeftToRight,
          reason: SyncReason.onlyOnLeft,
        ),
        testItem('bad/sub', left: testDir, reason: SyncReason.scanError),
      ]);
      final controller = await _ready(_controller(pair: pair, plan: plan));
      addTearDown(controller.dispose);
      // One manual override on the plan's first row.
      controller.applyOverrideTo([plan.items.first], SyncActionType.skip);

      final export = controller.rsyncExport(now: stamp)!;
      expect(export.text, contains('1 manual per-item override'));
      expect(export.text, contains("--exclude='/bad/sub'"));
      expect(
        export.text,
        contains('scan-error subtrees and symlinks are excluded'),
      );
    });

    test('a null resolver answer disables the export', () async {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final controller = testController(
        pair: pair,
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult('/right', const {}),
        ),
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        environment: testSyncEnvironment(scratch),
        rsyncEndpoints: (_) => null,
      );
      addTearDown(controller.dispose);
      await _ready(controller);

      expect(controller.canExportRsync, isFalse);
      expect(controller.rsyncExport(now: stamp), isNull);
    });

    test('no plan yet — nothing to export', () {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      final controller = testController(
        pair: pair,
        scanner: FakeSyncScanner(
          left: testScanResult('/left', const {}),
          right: testScanResult('/right', const {}),
        ),
        differ: FakeSyncDiffer(testPlan(pair, const [])),
        environment: testSyncEnvironment(scratch),
      );
      addTearDown(controller.dispose);

      expect(controller.canExportRsync, isFalse);
      expect(controller.rsyncExport(now: stamp), isNull);
    });

    test('a mid-rescan stale plan is not exportable', () async {
      final pair = testSyncPair();
      final controller = await _ready(
        _controller(pair: pair, plan: testPlan(pair, const [])),
      );
      addTearDown(controller.dispose);
      expect(controller.canExportRsync, isTrue);

      unawaited(controller.rescan());
      expect(controller.phase, SyncPlanPhase.scanning);
      // `_plan` still holds the previous scan's result — exporting it
      // would render current rules against stale skip paths.
      expect(controller.canExportRsync, isFalse);
      expect(controller.rsyncExport(now: stamp), isNull);

      await pumpUntil(() => controller.phase == SyncPlanPhase.ready);
      expect(controller.canExportRsync, isTrue);
    });

    test('untrusted mtimes downgrade the export to --size-only', () async {
      final pair = testSyncPair();
      final scratch = Directory.systemTemp.createTempSync();
      addTearDown(() => scratch.deleteSync(recursive: true));
      // Seed the §4 flag under the id the scan will settle on — the
      // fakes report caseSensitive roots and no probe answers, so the
      // pairId resolves with the default fold flags.
      final states = MemorySyncStateStore();
      await states.save(
        syncPairId(pair),
        SyncPairState(mtimeUnreliableLeft: true),
      );
      final controller = await _ready(
        _controller(
          pair: pair,
          plan: testPlan(pair, const []),
          environment: testSyncEnvironment(scratch, states: states),
        ),
      );
      addTearDown(controller.dispose);

      final export = controller.rsyncExport(now: stamp)!;
      expect(export.text, contains('--size-only'));
      expect(export.text, isNot(contains('--modify-window')));
      expect(export.text, contains('mtimes untrusted'));
    });
  });
}

/// An upload gate that releases early on cancellation — arming it
/// holds a run mid-copy until [disarm] or the run's own cancellation
/// unwinds it. Disarmed during scans: the case probe writes through
/// the same verb.
final class _CancelAwareGateFs extends LocalFileSystem {
  Completer<void>? _gate;
  Completer<void>? _uploadStarted;
  bool failUploads = false;

  void arm() {
    _gate = Completer<void>();
    _uploadStarted = Completer<void>();
  }

  Future<void> get uploadStarted {
    final started = _uploadStarted;
    if (started != null) return started.future;
    throw StateError('The upload gate is not armed.');
  }

  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void disarm() {
    release();
    _gate = null;
    _uploadStarted = null;
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    // A generic throw lands in the executor's non-conflict bucket —
    // the item is `failed`, which is the status `retryFailed` re-runs
    // (a vanished source reads `conflicted` and is deliberately not
    // retryable).
    if (failUploads && !path.contains(syncTrashRootMarkerName)) {
      throw StateError('injected upload failure');
    }
    final gate = _gate;
    if (gate != null) {
      final started = _uploadStarted;
      if (started != null && !started.isCompleted) started.complete();
      await Future.any([
        gate.future,
        if (cancellation != null) cancellation.whenCancelled,
      ]);
      cancellation?.throwIfCancelled();
    }
    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }
}

final class _RestoreGateFileSystem extends LocalFileSystem {
  final Completer<void> restoreStarted = Completer<void>();
  final Completer<void> _restoreRelease = Completer<void>();

  void releaseRestore() {
    if (!_restoreRelease.isCompleted) _restoreRelease.complete();
  }

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) async {
    if (oldPath.contains(RemoteTrash.rootDirectoryName) &&
        !oldPath.contains(syncTrashRootMarkerName)) {
      if (!restoreStarted.isCompleted) restoreStarted.complete();
      await _restoreRelease.future;
    }

    return super.rename(oldPath, newPath, overwrite: overwrite);
  }
}

final class _RestoreCleanupFailureFileSystem extends LocalFileSystem {
  static const _restoreStagePrefix = '.poltergeist-restore-';

  bool failStageDelete = false;
  bool failTrashVerification = false;
  String? _retargetedPath;
  String? _retargetedCanonicalRoot;
  Completer<void>? _trashVerificationStarted;
  Completer<void>? _trashVerificationRelease;

  Future<void> get trashVerificationStarted =>
      _trashVerificationStarted?.future ??
      Future<void>.error(StateError('Trash verification is not gated.'));

  void gateTrashVerification() {
    _trashVerificationStarted = Completer<void>();
    _trashVerificationRelease = Completer<void>();
  }

  void releaseTrashVerification() {
    final release = _trashVerificationRelease;
    if (release != null && !release.isCompleted) release.complete();
    _trashVerificationStarted = null;
    _trashVerificationRelease = null;
  }

  void retargetCanonicalRoot(String path, String canonicalRoot) {
    _retargetedPath = path;
    _retargetedCanonicalRoot = canonicalRoot;
  }

  @override
  Future<String> canonicalize(String path) {
    final retargetedPath = _retargetedPath;
    if (retargetedPath != null && p.equals(path, retargetedPath)) {
      return Future.value(_retargetedCanonicalRoot!);
    }

    return super.canonicalize(path);
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (failTrashVerification && path.contains(syncTrashRootMarkerName)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'verify sync trash',
        path: path,
        message: 'restore transport unavailable',
      );
    }

    final started = _trashVerificationStarted;
    final release = _trashVerificationRelease;
    if (started != null &&
        release != null &&
        path.contains(syncTrashRootMarkerName)) {
      if (!started.isCompleted) started.complete();
      await release.future;
    }

    return super.stat(path, followLinks: followLinks);
  }

  @override
  Future<void> delete(RemoteFileEntry entry) {
    if (failStageDelete &&
        p.basename(entry.path).startsWith(_restoreStagePrefix)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'delete restore stage',
        path: entry.path,
        message: 'connection lost during restore cleanup',
      );
    }

    return super.delete(entry);
  }
}

Future<T> _withFailingActivityUnlock<T>({
  required String lockDirectory,
  required SyncTrashLocation location,
  required Future<T> Function() body,
}) {
  final locationGatePath = p.absolute(
    p.normalize(
      p.join(lockDirectory, '${location.locationKey}$_locationGateSuffix'),
    ),
  );
  final probe = _UnlockFailureProbe();
  addTearDown(probe.forceClose);
  final parentZone = Zone.current;

  return IOOverrides.runZoned(
    body,
    createFile: (path) {
      final delegate = parentZone.run(() => File(path));
      if (p.absolute(p.normalize(path)) != locationGatePath) return delegate;

      return _UnlockFailureFile(delegate, probe);
    },
  );
}

final class _UnlockFailureProbe {
  RandomAccessFile? file;
  bool closed = false;

  Future<void> forceClose() async {
    if (closed) return;
    await file?.close();
    closed = true;
  }
}

final class _UnlockFailureFile implements File {
  const _UnlockFailureFile(this._delegate, this._probe);

  final File _delegate;
  final _UnlockFailureProbe _probe;

  @override
  String get path => _delegate.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final file = await _delegate.open(mode: mode);
    _probe.file = file;
    return _UnlockFailureRandomAccessFile(file, _probe);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _UnlockFailureRandomAccessFile implements RandomAccessFile {
  const _UnlockFailureRandomAccessFile(this._delegate, this._probe);

  final RandomAccessFile _delegate;
  final _UnlockFailureProbe _probe;

  @override
  String get path => _delegate.path;

  @override
  Future<void> close() async {
    await _delegate.close();
    _probe.closed = true;
  }

  @override
  Future<RandomAccessFile> lock([
    FileLock mode = FileLock.exclusive,
    int start = 0,
    int end = -1,
  ]) async {
    await _delegate.lock(mode, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) {
    throw FileSystemException('injected unlock failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TrashVerificationGateFileSystem extends LocalFileSystem {
  final Completer<void> verificationStarted = Completer<void>();
  final Completer<void> _verificationRelease = Completer<void>();
  var _gateVerification = false;
  var failUploads = false;

  void armVerification() => _gateVerification = true;

  void releaseVerification() {
    if (!_verificationRelease.isCompleted) _verificationRelease.complete();
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (_gateVerification && path.contains(syncTrashRootMarkerName)) {
      _gateVerification = false;
      if (!verificationStarted.isCompleted) verificationStarted.complete();
      await _verificationRelease.future;
    }

    return super.stat(path, followLinks: followLinks);
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) {
    if (failUploads && !path.contains(syncTrashRootMarkerName)) {
      throw StateError('injected upload failure');
    }

    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }
}

ServerConfig _serverConfig(String host) => ServerConfig(
  id: 'target',
  label: 'Target',
  host: host,
  username: 'deploy',
  createdAt: 0,
  updatedAt: 0,
);

AuthenticatedEndpointIdentity _endpointIdentity(String host) =>
    AuthenticatedEndpointIdentity(
      host: host,
      port: 22,
      username: 'deploy',
      fingerprintSha256: 'SHA256:$host',
    );

final class _RetargetableConnections implements ConnectionManager {
  _RetargetableConnections(this.fileSystem)
    : endpointIdentity = _endpointIdentity('one.example.com');

  final RemoteFileSystem fileSystem;
  AuthenticatedEndpointIdentity endpointIdentity;
  int releaseCount = 0;

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async =>
      _RetargetableLease(fileSystem, endpointIdentity, () => releaseCount++);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _RetargetableLease implements TransferChannelLease {
  _RetargetableLease(this.fs, this.endpointIdentity, this._onRelease);

  @override
  final RemoteFileSystem fs;
  @override
  final AuthenticatedEndpointIdentity endpointIdentity;
  final void Function() _onRelease;

  @override
  Future<void> release() async => _onRelease();

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

final class _UnavailableTrashFileSystem extends LocalFileSystem {
  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    if (path.contains(RemoteTrash.rootDirectoryName)) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'stat',
        path: path,
        message: 'trash unavailable',
      );
    }

    return super.stat(path, followLinks: followLinks);
  }
}

final class _EndpointTouchingScanner implements SyncPairScanner {
  const _EndpointTouchingScanner(this.environment);

  final SyncEnvironment environment;

  @override
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  }) async {
    final root = await environment
        .fileSystemFor(endpoint)
        .canonicalize(environment.rootFor(endpoint));
    final entries = side == SyncSide.left
        ? {'old.txt': testFile(size: 3)}
        : const <String, EntrySnapshot>{};
    onProgress?.call(entries.length);

    return testScanResult(root, entries);
  }
}

final class _CountingScanner implements SyncPairScanner {
  _CountingScanner(this.environment);

  final SyncEnvironment environment;
  int calls = 0;

  @override
  Future<ScanResult> scan(
    SyncEndpoint endpoint,
    SyncSide side,
    SyncRuleSet rules, {
    bool? caseSensitivityOverride,
    ScanCancellation? cancellation,
    void Function(int entriesScanned)? onProgress,
  }) async {
    calls++;
    final root = environment.rootFor(endpoint);
    final trashPath = await environment.effectiveTrashPath(
      endpoint: endpoint,
      canonicalRoot: root,
      rules: rules,
      side: side,
    );

    return TreeScanner(environment.fileSystemFor(endpoint)).scan(
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
