@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

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
    await Directory(
      p.join(first.trashRoot, syncTrashRootMarkerName),
    ).delete(recursive: true);
    final replacement = await resolveSyncTrashRoot(
      LocalFileSystem(),
      first.trashRoot,
      pathStyle: SyncTrashPathStyle.posix,
      access: SyncTrashRootAccess.createOrClaim,
    );
    expect(replacement.scopeKey, isNot(first.scopeKey));

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
}
