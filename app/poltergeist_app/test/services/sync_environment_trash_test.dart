@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

final SyncTrashPathStyle _nativeTrashPathStyle = Platform.isWindows
    ? SyncTrashPathStyle.windows
    : SyncTrashPathStyle.posix;

const String _restoreTransactionId = '0123456789abcdef0123456789abcdef';
final String _mismatchedTrashScope = '0' * 64;
final String _mismatchedTrashLocationKey = '1' * 64;
int _nextRecoveryRun = 0;

final class _CaseVariantRunListingFileSystem extends LocalFileSystem {
  String? trashRoot;
  String? runId;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final entries = await super.listDirectory(path);
    if (trashRoot == null || p.normalize(path) != p.normalize(trashRoot!)) {
      return entries;
    }

    return [
      for (final entry in entries)
        if (entry.name == runId)
          RemoteFileEntry(
            path: p.join(path, entry.name.toUpperCase()),
            name: entry.name.toUpperCase(),
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

final class _InaccessiblePathFileSystem extends LocalFileSystem {
  final Set<String> inaccessibleRoots = {};
  final List<String> blockedAccesses = [];

  bool _isInaccessible(String path) {
    final normalized = p.normalize(path);
    return inaccessibleRoots.any(
      (root) => p.equals(root, normalized) || p.isWithin(root, normalized),
    );
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (_isInaccessible(path)) {
      blockedAccesses.add(path);
      throw RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'inspect',
        path: path,
        message: 'path is intentionally inaccessible',
      );
    }

    return super.stat(path, followLinks: followLinks);
  }
}

final class _CanonicalRootSwapFileSystem extends LocalFileSystem {
  String? watchedPath;
  String? firstRoot;
  String? secondRoot;
  int watchedCanonicalizations = 0;

  @override
  Future<String> canonicalize(String path) {
    final watched = watchedPath;
    if (watched == null || !p.equals(path, watched)) {
      return super.canonicalize(path);
    }

    watchedCanonicalizations++;
    return Future.value(
      watchedCanonicalizations == 1 ? firstRoot! : secondRoot!,
    );
  }
}

Future<SyncRunJournal> _recoveryJournal(
  SyncEnvironment environment, {
  required SyncRuleSet rules,
  required String? canonicalRootLeft,
  required String? canonicalRootRight,
  required String? trashScopeLeft,
  required String? trashScopeRight,
  required String? trashLocationKeyLeft,
  required String? trashLocationKeyRight,
  String pairId = 'pair-1',
  DateTime? startedAt,
}) async {
  final journal = await SyncRunJournal.create(
    environment.syncRunsDirectory,
    SyncRunRecord(
      runId: 'recovery-run-${_nextRecoveryRun++}',
      pairId: pairId,
      startedAt: startedAt ?? DateTime.utc(2026),
      canonicalRootLeft: canonicalRootLeft,
      canonicalRootRight: canonicalRootRight,
      trashScopeLeft: trashScopeLeft,
      trashScopeRight: trashScopeRight,
      trashLocationKeyLeft: trashLocationKeyLeft,
      trashLocationKeyRight: trashLocationKeyRight,
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
  const restoreStarted = <String, Object?>{
    'v': 2,
    'type': 'replaceRestoreStarted',
    'transactionId': _restoreTransactionId,
    'side': 'left',
    'parent': 'entry',
  };
  await File(journal.path).writeAsString(
    '\n${jsonEncode(restoreStarted)}\n',
    mode: FileMode.append,
    flush: true,
  );

  return SyncRunJournal.open(journal.path);
}

void main() {
  late Directory scratch;
  late SyncEnvironment environment;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'poltergeist-trash-location-',
    );
    environment = SyncEnvironment(
      states: MemorySyncStateStore(),
      syncRunsDirectory: p.join(scratch.path, 'sync_runs'),
      deviceId: () async => 'test-device',
    );
  });

  tearDown(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test('relative configured trash is rooted under the scanned side', () async {
    final root = Directory(p.join(scratch.path, 'root'))..createSync();

    final location = await environment.resolveTrashLocation(
      endpoint: LocalEndpoint(root.path),
      canonicalRoot: root.path,
      rules: const SyncRuleSet(trashPathLeft: 'trash/custom'),
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );

    expect(location.trashRoot, p.join(root.path, 'trash', 'custom'));
  });

  test(
    'custom trash paths preserve case across filesystem boundaries',
    () async {
      final root = Directory(p.join(scratch.path, 'root'))..createSync();
      const remoteServer = BookmarkServerRef(serverConfigId: 'server-1');
      final cases =
          <({SyncEndpoint endpoint, String root, String upper, String lower})>[
            (
              endpoint: LocalEndpoint(root.path),
              root: root.path,
              upper: p.join(scratch.path, 'Trash'),
              lower: p.join(scratch.path, 'trash'),
            ),
            (
              endpoint: const RemoteEndpoint(
                server: remoteServer,
                path: '/sync',
              ),
              root: '/sync',
              upper: '/Trash',
              lower: '/trash',
            ),
          ];

      for (final item in cases) {
        final upper = await environment.trashLocationFor(
          endpoint: item.endpoint,
          canonicalRoot: item.root,
          rules: SyncRuleSet(trashPathLeft: item.upper),
          side: SyncSide.left,
          pathCase: SyncTrashPathCase.insensitive,
        );
        final lower = await environment.trashLocationFor(
          endpoint: item.endpoint,
          canonicalRoot: item.root,
          rules: SyncRuleSet(trashPathLeft: item.lower),
          side: SyncSide.left,
          pathCase: SyncTrashPathCase.insensitive,
        );
        final inRoot = await environment.trashLocationFor(
          endpoint: item.endpoint,
          canonicalRoot: item.root,
          rules: const SyncRuleSet(),
          side: SyncSide.left,
          pathCase: SyncTrashPathCase.insensitive,
        );

        expect(upper.pathCase, SyncTrashPathCase.sensitive);
        expect(lower.pathCase, SyncTrashPathCase.sensitive);
        expect(upper.locationKey, isNot(lower.locationKey));
        expect(inRoot.pathCase, SyncTrashPathCase.insensitive);
      }
    },
  );

  test(
    'missing trash roots resolve through an existing symlink parent',
    () async {
      final physical = Directory(p.join(scratch.path, 'physical'))
        ..createSync();
      final alias = Link(p.join(scratch.path, 'alias'))
        ..createSync(physical.path);
      final aliasedTrash = p.join(alias.path, 'missing', 'trash');
      final physicalTrash = p.join(physical.path, 'missing', 'trash');

      final aliased = await environment.resolveTrashLocation(
        endpoint: LocalEndpoint(physical.path),
        canonicalRoot: physical.path,
        rules: SyncRuleSet(trashPathLeft: aliasedTrash),
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final canonical = await environment.resolveTrashLocation(
        endpoint: LocalEndpoint(physical.path),
        canonicalRoot: physical.path,
        rules: SyncRuleSet(trashPathLeft: physicalTrash),
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );

      expect(aliased.trashRoot, physicalTrash);
      expect(aliased, canonical);
      expect(aliased.scopeKey, canonical.scopeKey);
      await environment.verifyTrashLocation(
        LocalEndpoint(physical.path),
        aliased,
      );
    },
    skip: Platform.isWindows,
  );

  test(
    'scan exclusion resolves an alias before a missing trash suffix',
    () async {
      final physical = Directory(p.join(scratch.path, 'scan-physical'))
        ..createSync();
      final alias = Link(p.join(scratch.path, 'scan-alias'))
        ..createSync(physical.path);
      final configured = p.join(alias.path, 'missing', 'trash');
      final expected = p.join(
        await physical.resolveSymbolicLinks(),
        'missing',
        'trash',
      );

      final effective = await environment.effectiveTrashPath(
        endpoint: LocalEndpoint(physical.path),
        canonicalRoot: physical.path,
        rules: SyncRuleSet(trashPathLeft: configured),
        side: SyncSide.left,
      );

      expect(effective, expected);
    },
    skip: Platform.isWindows,
  );

  test('home-relative trash passes pre-mutation verification', () async {
    final home = Directory(p.join(scratch.path, 'home'))..createSync();
    final root = Directory(p.join(scratch.path, 'root'))..createSync();
    final homeFileSystem = LocalFileSystem(
      environment: {'HOME': home.path, 'USERPROFILE': home.path},
    );
    final homeEnvironment = SyncEnvironment(
      states: MemorySyncStateStore(),
      syncRunsDirectory: p.join(scratch.path, 'home_sync_runs'),
      deviceId: () async => 'test-device',
      localFileSystem: () => homeFileSystem,
    );
    final endpoint = LocalEndpoint(root.path);
    final location = await homeEnvironment.resolveTrashLocation(
      endpoint: endpoint,
      canonicalRoot: root.path,
      rules: const SyncRuleSet(trashPathLeft: '~/trash'),
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );

    await homeEnvironment.verifyTrashLocation(endpoint, location);
  });

  test(
    'restore context maps a pane-swapped pair by journal identity',
    () async {
      final originalLeft = LocalEndpoint(
        (Directory(p.join(scratch.path, 'restore-left'))..createSync()).path,
      );
      final originalRight = LocalEndpoint(
        (Directory(p.join(scratch.path, 'restore-right'))..createSync()).path,
      );
      const journalRules = SyncRuleSet();
      final leftLocation = await environment.resolveTrashLocation(
        endpoint: originalLeft,
        canonicalRoot: originalLeft.path,
        rules: journalRules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final rightLocation = await environment.resolveTrashLocation(
        endpoint: originalRight,
        canonicalRoot: originalRight.path,
        rules: journalRules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final originalLeftRoot = await Directory(
        originalLeft.path,
      ).resolveSymbolicLinks();
      final originalRightRoot = await Directory(
        originalRight.path,
      ).resolveSymbolicLinks();
      final journal = await _recoveryJournal(
        environment,
        rules: journalRules,
        canonicalRootLeft: originalLeftRoot,
        canonicalRootRight: originalRightRoot,
        trashScopeLeft: leftLocation.scopeKey,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: leftLocation.locationKey,
        trashLocationKeyRight: rightLocation.locationKey,
      );
      final pair = SyncPair(
        id: 'pair',
        name: 'pair',
        left: originalRight,
        right: originalLeft,
        // Recovery must use the run snapshot, not a later favorite edit.
        rules: const SyncRuleSet(
          trashPathLeft: 'changed-left-trash',
          trashPathRight: 'changed-right-trash',
        ),
      );

      final selection = await environment.resolveRestoreRecoveryContext(
        pair: pair,
        journals: [journal],
      );
      final context = selection!.context;

      expect(selection.journal.path, journal.path);
      expect(context.endpoints[SyncSide.left], same(originalLeft));
      expect(context.endpoints[SyncSide.right], same(originalRight));
      expect(context.roots[SyncSide.left], originalLeftRoot);
      expect(context.roots[SyncSide.right], originalRightRoot);
      expect(
        context.trashLocations[SyncSide.left]!.scopeKey,
        leftLocation.scopeKey,
      );
      expect(
        context.trashLocations[SyncSide.right]!.scopeKey,
        rightLocation.scopeKey,
      );
      expect(context.endpointBindings.keys, containsAll(SyncSide.values));
    },
  );

  test(
    'restore context opens only each endpoint assigned trash side',
    () async {
      final fileSystem = _InaccessiblePathFileSystem();
      final recoveryEnvironment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'assigned_sync_runs'),
        deviceId: () async => 'test-device',
        localFileSystem: () => fileSystem,
      );
      final left = LocalEndpoint(
        (Directory(p.join(scratch.path, 'assigned-left'))..createSync()).path,
      );
      final right = LocalEndpoint(
        (Directory(p.join(scratch.path, 'assigned-right'))..createSync()).path,
      );
      const rules = SyncRuleSet(
        trashPathLeft: 'left-trash',
        trashPathRight: 'right-trash',
      );
      final leftLocation = await recoveryEnvironment.resolveTrashLocation(
        endpoint: left,
        canonicalRoot: left.path,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final rightLocation = await recoveryEnvironment.resolveTrashLocation(
        endpoint: right,
        canonicalRoot: right.path,
        rules: rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final leftRoot = await Directory(left.path).resolveSymbolicLinks();
      final rightRoot = await Directory(right.path).resolveSymbolicLinks();
      final journal = await _recoveryJournal(
        recoveryEnvironment,
        rules: rules,
        canonicalRootLeft: leftRoot,
        canonicalRootRight: rightRoot,
        trashScopeLeft: leftLocation.scopeKey,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: leftLocation.locationKey,
        trashLocationKeyRight: rightLocation.locationKey,
      );
      fileSystem.inaccessibleRoots.addAll({
        p.join(leftRoot, rules.trashPathRight!),
        p.join(rightRoot, rules.trashPathLeft!),
      });
      final pair = SyncPair(
        id: 'pair',
        name: 'pair',
        left: left,
        right: right,
        rules: rules,
      );

      final selection = await recoveryEnvironment.resolveRestoreRecoveryContext(
        pair: pair,
        journals: [journal],
      );

      expect(selection, isNotNull);
      expect(fileSystem.blockedAccesses, isEmpty);
    },
  );

  test('restore context rejects a root changed after assignment', () async {
    final firstLeft = Directory(p.join(scratch.path, 'root-swap-first'))
      ..createSync();
    final secondLeft = Directory(p.join(scratch.path, 'root-swap-second'))
      ..createSync();
    final right = Directory(p.join(scratch.path, 'root-swap-right'))
      ..createSync();
    final requestedLeft = p.join(scratch.path, 'root-swap-requested');
    final leftTrash = p.join(scratch.path, 'root-swap-left-trash');
    final rightTrash = p.join(scratch.path, 'root-swap-right-trash');
    final rules = SyncRuleSet(
      trashPathLeft: leftTrash,
      trashPathRight: rightTrash,
    );
    final leftLocation = await environment.resolveTrashLocation(
      endpoint: LocalEndpoint(firstLeft.path),
      canonicalRoot: firstLeft.path,
      rules: rules,
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final rightLocation = await environment.resolveTrashLocation(
      endpoint: LocalEndpoint(right.path),
      canonicalRoot: right.path,
      rules: rules,
      side: SyncSide.right,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final firstCanonical = await firstLeft.resolveSymbolicLinks();
    final secondCanonical = await secondLeft.resolveSymbolicLinks();
    final rightCanonical = await right.resolveSymbolicLinks();
    final journal = await _recoveryJournal(
      environment,
      rules: rules,
      canonicalRootLeft: firstCanonical,
      canonicalRootRight: rightCanonical,
      trashScopeLeft: leftLocation.scopeKey,
      trashScopeRight: rightLocation.scopeKey,
      trashLocationKeyLeft: leftLocation.locationKey,
      trashLocationKeyRight: rightLocation.locationKey,
    );
    final fileSystem = _CanonicalRootSwapFileSystem()
      ..watchedPath = requestedLeft
      ..firstRoot = firstCanonical
      ..secondRoot = secondCanonical;
    final recoveryEnvironment = SyncEnvironment(
      states: MemorySyncStateStore(),
      syncRunsDirectory: environment.syncRunsDirectory,
      deviceId: () async => 'test-device',
      localFileSystem: () => fileSystem,
    );
    final pair = SyncPair(
      id: 'pair',
      name: 'pair',
      left: LocalEndpoint(requestedLeft),
      right: LocalEndpoint(right.path),
      rules: rules,
    );

    await expectLater(
      recoveryEnvironment.resolveRestoreRecoveryContext(
        pair: pair,
        journals: [journal],
      ),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.conflict,
        ),
      ),
    );
    expect(fileSystem.watchedCanonicalizations, 2);
  });

  test('restore context refuses an ambiguous endpoint order', () async {
    final root = Directory(p.join(scratch.path, 'restore-shared'))
      ..createSync();
    final endpoint = LocalEndpoint(root.path);
    const rules = SyncRuleSet();
    final location = await environment.resolveTrashLocation(
      endpoint: endpoint,
      canonicalRoot: root.path,
      rules: rules,
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final journal = await _recoveryJournal(
      environment,
      rules: rules,
      canonicalRootLeft: await root.resolveSymbolicLinks(),
      canonicalRootRight: await root.resolveSymbolicLinks(),
      trashScopeLeft: location.scopeKey,
      trashScopeRight: location.scopeKey,
      trashLocationKeyLeft: location.locationKey,
      trashLocationKeyRight: location.locationKey,
    );
    final pair = SyncPair(
      id: 'pair',
      name: 'pair',
      left: endpoint,
      right: endpoint,
      rules: rules,
    );

    await expectLater(
      environment.resolveRestoreRecoveryContext(
        pair: pair,
        journals: [journal],
      ),
      throwsA(
        isA<RemoteFileException>()
            .having((error) => error.kind, 'kind', RemoteFileErrorKind.conflict)
            .having(
              (error) => error.message,
              'message',
              contains('both endpoint orders'),
            ),
      ),
    );
  });

  test(
    'folded pair-id collision selects the newest matching canonical roots',
    () async {
      if (Platform.isWindows) return;

      final upperRoot = Directory(p.join(scratch.path, 'Data'))..createSync();
      final lowerRoot = Directory(p.join(scratch.path, 'data'))..createSync();
      final peerRoot = Directory(p.join(scratch.path, 'peer'))..createSync();
      final upperCanonical = await upperRoot.resolveSymbolicLinks();
      final lowerCanonical = await lowerRoot.resolveSymbolicLinks();
      final peerCanonical = await peerRoot.resolveSymbolicLinks();
      if (upperCanonical == lowerCanonical) return;

      final leftTrash = p.join(scratch.path, 'shared-left-trash');
      final rightTrash = p.join(scratch.path, 'shared-right-trash');
      final rules = SyncRuleSet(
        trashPathLeft: leftTrash,
        trashPathRight: rightTrash,
      );
      final upperPair = SyncPair(
        id: 'upper',
        name: 'upper',
        left: LocalEndpoint(upperCanonical),
        right: LocalEndpoint(peerCanonical),
        rules: rules,
      );
      final lowerPair = SyncPair(
        id: 'lower',
        name: 'lower',
        left: LocalEndpoint(lowerCanonical),
        right: LocalEndpoint(peerCanonical),
        rules: rules,
      );
      final leftLocation = await environment.resolveTrashLocation(
        endpoint: upperPair.left,
        canonicalRoot: upperCanonical,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final rightLocation = await environment.resolveTrashLocation(
        endpoint: upperPair.right,
        canonicalRoot: await peerRoot.resolveSymbolicLinks(),
        rules: rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );

      Future<SyncRunJournal> recovery({
        required String root,
        required String pairId,
        required DateTime startedAt,
      }) => _recoveryJournal(
        environment,
        rules: rules,
        canonicalRootLeft: root,
        canonicalRootRight: peerCanonical,
        trashScopeLeft: leftLocation.scopeKey,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: leftLocation.locationKey,
        trashLocationKeyRight: rightLocation.locationKey,
        pairId: pairId,
        startedAt: startedAt,
      );

      final currentPairId = syncPairId(upperPair);
      final sharedCandidates = syncPairIdCandidates(
        upperPair,
      ).intersection(syncPairIdCandidates(lowerPair));
      expect(sharedCandidates, isNotEmpty);
      final collidingPairId = sharedCandidates.first;
      final olderMatch = await recovery(
        root: upperCanonical,
        pairId: currentPairId,
        startedAt: DateTime.utc(2026, 1, 1),
      );
      final newerMatch = await recovery(
        root: upperCanonical,
        pairId: currentPairId,
        startedAt: DateTime.utc(2026, 1, 2),
      );
      final newerCollision = await recovery(
        root: lowerCanonical,
        pairId: collidingPairId,
        startedAt: DateTime.utc(2026, 1, 3),
      );
      final lookup = await SyncRunJournal.findIncompleteRestoreForPairs(
        environment.syncRunsDirectory,
        syncPairIdCandidates(upperPair),
      );
      expect(lookup, isA<SyncIncompleteRestoreFound>());
      final journals = (lookup as SyncIncompleteRestoreFound).journals;
      expect(journals.map((journal) => journal.path), [
        newerCollision.path,
        newerMatch.path,
        olderMatch.path,
      ]);

      final selection = await environment.resolveRestoreRecoveryContext(
        pair: upperPair,
        journals: journals,
      );

      expect(selection, isNotNull);
      expect(selection!.journal.path, newerMatch.path);
      expect(selection.context.roots[SyncSide.left], upperCanonical);
      expect(
        await environment.resolveRestoreRecoveryContext(
          pair: upperPair,
          journals: [newerCollision],
        ),
        isNull,
      );
    },
  );

  test('restore context does not recreate a missing trash root', () async {
    final left = LocalEndpoint(
      (Directory(
        p.join(scratch.path, 'restore-mismatch-left'),
      )..createSync()).path,
    );
    final right = LocalEndpoint(
      (Directory(
        p.join(scratch.path, 'restore-mismatch-right'),
      )..createSync()).path,
    );
    const rules = SyncRuleSet();
    final leftLocation = await environment.resolveTrashLocation(
      endpoint: left,
      canonicalRoot: left.path,
      rules: rules,
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final rightLocation = await environment.resolveTrashLocation(
      endpoint: right,
      canonicalRoot: right.path,
      rules: rules,
      side: SyncSide.right,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final journal = await _recoveryJournal(
      environment,
      rules: rules,
      canonicalRootLeft: await Directory(left.path).resolveSymbolicLinks(),
      canonicalRootRight: await Directory(right.path).resolveSymbolicLinks(),
      trashScopeLeft: leftLocation.scopeKey,
      trashScopeRight: rightLocation.scopeKey,
      trashLocationKeyLeft: leftLocation.locationKey,
      trashLocationKeyRight: rightLocation.locationKey,
    );
    await Directory(leftLocation.trashRoot).delete(recursive: true);
    final pair = SyncPair(
      id: 'pair',
      name: 'pair',
      left: left,
      right: right,
      rules: rules,
    );

    await expectLater(
      environment.resolveRestoreRecoveryContext(
        pair: pair,
        journals: [journal],
      ),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.conflict,
        ),
      ),
    );
    expect(Directory(leftLocation.trashRoot).existsSync(), isFalse);
  });

  test(
    'restore context refuses missing scopes and location mismatches',
    () async {
      final left = LocalEndpoint(
        (Directory(
          p.join(scratch.path, 'restore-invalid-left'),
        )..createSync()).path,
      );
      final right = LocalEndpoint(
        (Directory(
          p.join(scratch.path, 'restore-invalid-right'),
        )..createSync()).path,
      );
      const rules = SyncRuleSet();
      final leftLocation = await environment.resolveTrashLocation(
        endpoint: left,
        canonicalRoot: left.path,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final rightLocation = await environment.resolveTrashLocation(
        endpoint: right,
        canonicalRoot: right.path,
        rules: rules,
        side: SyncSide.right,
        pathCase: SyncTrashPathCase.sensitive,
      );
      final pair = SyncPair(
        id: 'pair',
        name: 'pair',
        left: left,
        right: right,
        rules: rules,
      );
      final missingScope = await _recoveryJournal(
        environment,
        rules: rules,
        canonicalRootLeft: await Directory(left.path).resolveSymbolicLinks(),
        canonicalRootRight: await Directory(right.path).resolveSymbolicLinks(),
        trashScopeLeft: null,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: leftLocation.locationKey,
        trashLocationKeyRight: rightLocation.locationKey,
      );

      await expectLater(
        environment.resolveRestoreRecoveryContext(
          pair: pair,
          journals: [missingScope],
        ),
        throwsA(isA<RemoteFileException>()),
      );

      final wrongScope = await _recoveryJournal(
        environment,
        rules: rules,
        canonicalRootLeft: await Directory(left.path).resolveSymbolicLinks(),
        canonicalRootRight: await Directory(right.path).resolveSymbolicLinks(),
        trashScopeLeft: _mismatchedTrashScope,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: leftLocation.locationKey,
        trashLocationKeyRight: rightLocation.locationKey,
      );
      await expectLater(
        environment.resolveRestoreRecoveryContext(
          pair: pair,
          journals: [wrongScope],
        ),
        throwsA(isA<RemoteFileException>()),
      );

      final wrongLocation = await _recoveryJournal(
        environment,
        rules: rules,
        canonicalRootLeft: await Directory(left.path).resolveSymbolicLinks(),
        canonicalRootRight: await Directory(right.path).resolveSymbolicLinks(),
        trashScopeLeft: leftLocation.scopeKey,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: _mismatchedTrashLocationKey,
        trashLocationKeyRight: rightLocation.locationKey,
      );
      await expectLater(
        environment.resolveRestoreRecoveryContext(
          pair: pair,
          journals: [wrongLocation],
        ),
        throwsA(isA<RemoteFileException>()),
      );

      final missingLocation = await _recoveryJournal(
        environment,
        rules: rules,
        canonicalRootLeft: await Directory(left.path).resolveSymbolicLinks(),
        canonicalRootRight: await Directory(right.path).resolveSymbolicLinks(),
        trashScopeLeft: leftLocation.scopeKey,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: null,
        trashLocationKeyRight: rightLocation.locationKey,
      );
      await expectLater(
        environment.resolveRestoreRecoveryContext(
          pair: pair,
          journals: [missingLocation],
        ),
        throwsA(isA<RemoteFileException>()),
      );

      final missingRoot = await _recoveryJournal(
        environment,
        rules: rules,
        canonicalRootLeft: null,
        canonicalRootRight: await Directory(right.path).resolveSymbolicLinks(),
        trashScopeLeft: leftLocation.scopeKey,
        trashScopeRight: rightLocation.scopeKey,
        trashLocationKeyLeft: leftLocation.locationKey,
        trashLocationKeyRight: rightLocation.locationKey,
      );
      await expectLater(
        environment.resolveRestoreRecoveryContext(
          pair: pair,
          journals: [missingRoot],
        ),
        throwsA(isA<RemoteFileException>()),
      );
    },
  );

  test('a deleted root releases its prior scoped journals', () async {
    final root = Directory(p.join(scratch.path, 'root'))..createSync();
    final endpoint = LocalEndpoint(root.path);
    const rules = SyncRuleSet();
    final first = await environment.resolveTrashLocation(
      endpoint: endpoint,
      canonicalRoot: root.path,
      rules: rules,
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final runId =
        '${syncRunDevicePrefix('test-device')}-'
        '12345678-1234-4123-a123-123456789abc';
    final journal = await SyncRunJournal.create(
      environment.syncRunsDirectory,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-1',
        startedAt: DateTime.now(),
        trashScopeLeft: first.scopeKey,
        trashLocationKeyLeft: first.locationKey,
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
        parentPath: 'a.txt',
        relativePath: 'a.txt',
        side: SyncSide.left,
        trashLocation: p.join(first.trashRoot, runId, '000001-a.txt'),
        bytes: 3,
      ),
    );
    await Directory(first.trashRoot).delete(recursive: true);

    final replacement = await environment.resolveTrashLocation(
      endpoint: endpoint,
      canonicalRoot: root.path,
      rules: rules,
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );

    expect(replacement.scopeKey, isNot(first.scopeKey));
    final reopened = await SyncRunJournal.open(journal.path);
    expect(reopened.isTrashScopePurged(first.scopeKey), isTrue);
    expect(reopened.hasUnpurgedTrash, isFalse);
  });

  test('a replacement marker cannot retire surviving old trash', () async {
    final root = Directory(p.join(scratch.path, 'root'))..createSync();
    final endpoint = LocalEndpoint(root.path);
    const rules = SyncRuleSet();
    final first = await environment.resolveTrashLocation(
      endpoint: endpoint,
      canonicalRoot: root.path,
      rules: rules,
      side: SyncSide.left,
      pathCase: SyncTrashPathCase.sensitive,
    );
    final runId =
        '${syncRunDevicePrefix('test-device')}-'
        '12345678-1234-4123-a123-123456789abc';
    final runDirectory = Directory(p.join(first.trashRoot, runId))
      ..createSync();
    final trashed = File(p.join(runDirectory.path, '000001-a.txt'))
      ..writeAsStringSync('old');
    final journal = await SyncRunJournal.create(
      environment.syncRunsDirectory,
      SyncRunRecord(
        runId: runId,
        pairId: 'pair-1',
        startedAt: DateTime.now(),
        trashScopeLeft: first.scopeKey,
        trashLocationKeyLeft: first.locationKey,
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
        parentPath: 'a.txt',
        relativePath: 'a.txt',
        side: SyncSide.left,
        trashLocation: trashed.path,
        bytes: 3,
      ),
    );
    final replacementRoot = p.join(scratch.path, 'replacement-trash');
    final replacement = await resolveSyncTrashRoot(
      LocalFileSystem(),
      replacementRoot,
      pathStyle: _nativeTrashPathStyle,
      access: SyncTrashRootAccess.createOrClaim,
    );
    expect(replacement.scopeKey, isNot(first.scopeKey));
    await File(
      p.join(replacementRoot, syncTrashRootMarkerName, 'identity'),
    ).copy(p.join(first.trashRoot, syncTrashRootMarkerName, 'identity'));

    await expectLater(
      environment.resolveTrashLocation(
        endpoint: endpoint,
        canonicalRoot: root.path,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
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
    expect(reopened.hasPurgeMarker, isFalse);
    expect(reopened.hasUnpurgedTrash, isTrue);
  });

  test(
    'case-insensitive stale-scope reconciliation preserves live trash',
    () async {
      final fileSystem = _CaseVariantRunListingFileSystem();
      final caseEnvironment = SyncEnvironment(
        states: MemorySyncStateStore(),
        syncRunsDirectory: p.join(scratch.path, 'case_sync_runs'),
        deviceId: () async => 'test-device',
        localFileSystem: () => fileSystem,
      );
      final root = Directory(p.join(scratch.path, 'case-root'))..createSync();
      final endpoint = LocalEndpoint(root.path);
      const rules = SyncRuleSet();
      final first = await caseEnvironment.resolveTrashLocation(
        endpoint: endpoint,
        canonicalRoot: root.path,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.insensitive,
      );
      final runId =
          '${syncRunDevicePrefix('test-device')}-'
          '12345678-1234-4123-a123-123456789abc';
      final runDirectory = Directory(p.join(first.trashRoot, runId))
        ..createSync();
      final trashed = File(p.join(runDirectory.path, '000001-a.txt'))
        ..writeAsStringSync('old');
      final journal = await SyncRunJournal.create(
        caseEnvironment.syncRunsDirectory,
        SyncRunRecord(
          runId: runId,
          pairId: 'pair-1',
          startedAt: DateTime.now(),
          trashScopeLeft: first.scopeKey,
          trashLocationKeyLeft: first.locationKey,
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
          parentPath: 'a.txt',
          relativePath: 'a.txt',
          side: SyncSide.left,
          trashLocation: trashed.path,
          bytes: 3,
        ),
      );
      fileSystem
        ..trashRoot = first.trashRoot
        ..runId = runId;
      final replacementRoot = p.join(scratch.path, 'replacement-trash');
      final replacement = await resolveSyncTrashRoot(
        LocalFileSystem(),
        replacementRoot,
        pathStyle: _nativeTrashPathStyle,
        access: SyncTrashRootAccess.createOrClaim,
      );
      expect(replacement.scopeKey, isNot(first.scopeKey));
      await File(
        p.join(replacementRoot, syncTrashRootMarkerName, 'identity'),
      ).copy(p.join(first.trashRoot, syncTrashRootMarkerName, 'identity'));

      await expectLater(
        caseEnvironment.resolveTrashLocation(
          endpoint: endpoint,
          canonicalRoot: root.path,
          rules: rules,
          side: SyncSide.left,
          pathCase: SyncTrashPathCase.insensitive,
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
      expect(reopened.hasPurgeMarker, isFalse);
      expect(reopened.hasUnpurgedTrash, isTrue);
    },
  );
}
