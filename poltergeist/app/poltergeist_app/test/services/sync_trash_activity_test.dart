@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/sync_trash_activity.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/file_lock_holder.dart';

void main() {
  test('same physical root shares active runs across pairs', () async {
    final registry = SyncTrashActivityRegistry();
    final first = _localLocation('/shared/');
    final second = syncTrashLocation(
      endpoint: const LocalEndpoint('/two'),
      canonicalRoot: '/shared',
      rules: const SyncRuleSet(),
      side: SyncSide.right,
      rootId: _rootId('/shared'),
    );

    final lease = await registry.begin('device-run', [
      first,
    ], mode: SyncTrashActivityMode.run);

    expect(registry.activeRunIds(second), {'device-run'});
    await lease.close();
    expect(registry.activeRunIds(first), isEmpty);
  });

  test('different hosts and configured roots do not collide', () async {
    const firstServer = BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'one.example',
        username: 'alice',
        authMethod: AuthMethod.agent,
      ),
    );
    const secondServer = BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'two.example',
        username: 'alice',
        authMethod: AuthMethod.agent,
      ),
    );
    const rules = SyncRuleSet(trashPathLeft: '/shared-trash');
    final first = syncTrashLocation(
      endpoint: const RemoteEndpoint(server: firstServer, path: '/site'),
      canonicalRoot: '/site',
      rules: rules,
      side: SyncSide.left,
      rootId: _rootId('one'),
    );
    final second = syncTrashLocation(
      endpoint: const RemoteEndpoint(server: secondServer, path: '/site'),
      canonicalRoot: '/site',
      rules: rules,
      side: SyncSide.left,
      rootId: _rootId('two'),
    );
    final registry = SyncTrashActivityRegistry();

    final lease = await registry.begin('device-run', [
      first,
    ], mode: SyncTrashActivityMode.run);

    expect(registry.hasActiveRun(first), isTrue);
    expect(registry.hasActiveRun(second), isFalse);
    await lease.close();
  });

  test('unresolved roots keep separate location identities', () {
    final first = unresolvedSyncTrashLocation(
      endpoint: const LocalEndpoint('/one'),
      trashRoot: '/one/.poltergeist-trash',
      pathCase: SyncTrashPathCase.sensitive,
    );
    final second = unresolvedSyncTrashLocation(
      endpoint: const LocalEndpoint('/two'),
      trashRoot: '/two/.poltergeist-trash',
      pathCase: SyncTrashPathCase.sensitive,
    );

    expect(first.locationKey, isNot(second.locationKey));
    expect(first, isNot(second));
  });

  test('endpoint aliases sharing a marker share a root', () {
    const catalog = BookmarkServerRef(serverConfigId: 'server-1');
    const embedded = BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'EXAMPLE.COM',
        username: 'alice',
        authMethod: AuthMethod.agent,
      ),
    );
    final first = syncTrashLocation(
      endpoint: const RemoteEndpoint(server: catalog, path: '/srv/site'),
      canonicalRoot: '/srv/site',
      rules: const SyncRuleSet(trashPathLeft: '/srv/tmp/../trash'),
      side: SyncSide.left,
      rootId: _rootId('shared-remote-root'),
    );
    final second = syncTrashLocation(
      endpoint: const RemoteEndpoint(server: embedded, path: '/srv/site'),
      canonicalRoot: '/srv/site',
      rules: const SyncRuleSet(trashPathLeft: '/srv/trash/'),
      side: SyncSide.left,
      rootId: _rootId('shared-remote-root'),
    );

    expect(first, second);
    expect(first.scopeKey, second.scopeKey);
  });

  test('marker identity keeps the operational path', () {
    final first = syncTrashLocation(
      endpoint: const LocalEndpoint('/one'),
      canonicalRoot: '/one',
      rules: const SyncRuleSet(),
      side: SyncSide.left,
      rootId: _rootId('volume-trash'),
      resolvedTrashRoot: '/Volume/Trash',
      pathCase: SyncTrashPathCase.insensitive,
    );
    final second = syncTrashLocation(
      endpoint: const LocalEndpoint('/two'),
      canonicalRoot: '/two',
      rules: const SyncRuleSet(),
      side: SyncSide.left,
      rootId: _rootId('volume-trash'),
      resolvedTrashRoot: '/volume/trash',
      pathCase: SyncTrashPathCase.insensitive,
    );

    expect(first, second);
    expect(first.scopeKey, second.scopeKey);
    expect(first.trashRoot, '/Volume/Trash');
  });

  test('one lease deduplicates roots and closes once', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    var notifications = 0;
    registry.addListener(() => notifications++);

    final lease = await registry.begin('device-run', [
      location,
      location,
    ], mode: SyncTrashActivityMode.run);
    await lease.close();
    await lease.close();

    expect(notifications, 2);
    expect(registry.activeRunIds(location), isEmpty);
  });

  test('restore lease blocks a new run until release', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    final restore = await registry.begin('restore-run', [
      location,
    ], mode: SyncTrashActivityMode.restore);

    await expectLater(
      registry.begin('new-run', [location], mode: SyncTrashActivityMode.run),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );

    await restore.close();
    final run = await registry.begin('new-run', [
      location,
    ], mode: SyncTrashActivityMode.run);
    await run.close();
  });

  test('one run close retains the shared cross-process gate', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final firstRegistry = SyncTrashActivityRegistry(
      lockDirectory: directory.path,
    );
    final secondRegistry = SyncTrashActivityRegistry(
      lockDirectory: directory.path,
    );
    final first = await firstRegistry.begin('first-run', [
      location,
    ], mode: SyncTrashActivityMode.run);
    final second = await secondRegistry.begin('second-run', [
      location,
    ], mode: SyncTrashActivityMode.run);
    addTearDown(first.close);
    addTearDown(second.close);
    final gatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );

    await first.close();

    expect(await testFileLockIsAvailable(directory, gatePath), isFalse);

    await second.close();
    expect(await testFileLockIsAvailable(directory, gatePath), isTrue);
  });

  test('normal alias runs coexist', () async {
    final location = _localLocation('/one');
    final alias = _localAliasLocation(location, '/alias');
    final registry = SyncTrashActivityRegistry();
    final first = await registry.begin('first-run', [
      location,
    ], mode: SyncTrashActivityMode.run);
    final second = await registry.begin('second-run', [
      alias,
    ], mode: SyncTrashActivityMode.run);
    addTearDown(first.close);
    addTearDown(second.close);

    expect(registry.activeRunIds(location), {'first-run', 'second-run'});
  });

  test('active alias run blocks restore until release', () async {
    final location = _localLocation('/one');
    final alias = _localAliasLocation(location, '/alias');
    final registry = SyncTrashActivityRegistry();
    final run = await registry.begin('active-run', [
      location,
    ], mode: SyncTrashActivityMode.run);
    addTearDown(run.close);

    Object? failure;
    SyncTrashActivityLease? unexpected;
    try {
      unexpected = await registry.begin('restore-run', [
        alias,
      ], mode: SyncTrashActivityMode.restore);
    } catch (error) {
      failure = error;
    }
    addTearDown(() => unexpected?.close());

    expect(failure, isA<SyncTrashPurgeInProgressException>());

    await run.close();
    final restore = await registry.begin('restore-run', [
      alias,
    ], mode: SyncTrashActivityMode.restore);
    await restore.close();
  });

  test('restore blocks an alias run until release', () async {
    final location = _localLocation('/one');
    final alias = _localAliasLocation(location, '/alias');
    final registry = SyncTrashActivityRegistry();
    final restore = await registry.begin('restore-run', [
      location,
    ], mode: SyncTrashActivityMode.restore);
    addTearDown(restore.close);

    Object? failure;
    SyncTrashActivityLease? unexpected;
    try {
      unexpected = await registry.begin('new-run', [
        alias,
      ], mode: SyncTrashActivityMode.run);
    } catch (error) {
      failure = error;
    }
    addTearDown(() => unexpected?.close());

    expect(failure, isA<SyncTrashPurgeInProgressException>());

    await restore.close();
    final run = await registry.begin('new-run', [
      alias,
    ], mode: SyncTrashActivityMode.run);
    await run.close();
  });

  test('external alias run marker blocks restore', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final alias = _localAliasLocation(location, '/alias');
    const runId = 'external-run';
    final runKey = base64Url.encode(utf8.encode(runId));
    final markerPath = p.join(
      directory.path,
      '${location.scopeKey}.active.v2.$runKey.lock',
    );
    final child = await startTestFileLockHolder(directory, markerPath);
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    Object? failure;
    SyncTrashActivityLease? unexpected;
    try {
      unexpected = await registry.begin('restore-run', [
        alias,
      ], mode: SyncTrashActivityMode.restore);
    } catch (error) {
      failure = error;
    }
    addTearDown(() => unexpected?.close());

    expect(failure, isA<SyncTrashPurgeInProgressException>());
  });

  test('restore keeps the physical scope gate exclusive', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final alias = _localAliasLocation(location, '/alias');
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);
    final restore = await registry.begin('restore-run', [
      location,
    ], mode: SyncTrashActivityMode.restore);
    addTearDown(restore.close);
    final gatePath = p.join(directory.path, '${alias.scopeKey}.gate.lock');

    expect(
      await testFileLockIsAvailable(
        directory,
        gatePath,
        lockMode: TestFileLockMode.shared,
      ),
      isFalse,
    );

    await restore.close();
    expect(
      await testFileLockIsAvailable(
        directory,
        gatePath,
        lockMode: TestFileLockMode.shared,
      ),
      isTrue,
    );
  });

  test('active run blocks restore until release', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    final run = await registry.begin('active-run', [
      location,
    ], mode: SyncTrashActivityMode.run);

    await expectLater(
      registry.begin('restore-run', [
        location,
      ], mode: SyncTrashActivityMode.restore),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );

    await run.close();
    final restore = await registry.begin('restore-run', [
      location,
    ], mode: SyncTrashActivityMode.restore);
    await restore.close();
  });

  test('aged purge snapshots existing runs and blocks new ones', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    final run = await registry.begin('active-run', [
      location,
    ], mode: SyncTrashActivityMode.run);

    final purge = await registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.excludeActiveRuns);

    expect(purge, isNotNull);
    expect(purge!.activeRunIds(location), {'active-run'});
    await expectLater(
      registry.begin('new-run', [location], mode: SyncTrashActivityMode.run),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );
    await purge.close();
    await run.close();
  });

  test('full purge requires every target root to be idle', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    final run = await registry.begin('active-run', [
      location,
    ], mode: SyncTrashActivityMode.run);

    expect(
      await registry.tryBeginPurge([
        location,
      ], SyncTrashPurgeAdmission.requireIdle),
      isNull,
    );

    await run.close();
    final purge = await registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.requireIdle);
    expect(purge, isNotNull);
    await purge!.close();
  });

  test(
    'registries sharing a lock directory exclude in-process starts',
    () async {
      final directory = await Directory.systemTemp.createTemp('trash-locks-');
      addTearDown(() => directory.delete(recursive: true));
      final location = _localLocation('/one');
      final first = SyncTrashActivityRegistry(lockDirectory: directory.path);
      final second = SyncTrashActivityRegistry(lockDirectory: directory.path);
      final purge = await first.tryBeginPurge([
        location,
      ], SyncTrashPurgeAdmission.requireIdle);
      addTearDown(() => purge?.close());

      expect(purge, isNotNull);
      await expectLater(
        second.begin('new-run', [location], mode: SyncTrashActivityMode.run),
        throwsA(isA<SyncTrashPurgeInProgressException>()),
      );
      await purge!.close();
    },
  );

  test('purge notifications retain each trash scope', () {
    final first = _localLocation('/one');
    final second = _localLocation('/two');
    final registry = SyncTrashActivityRegistry();
    var notifications = 0;
    registry.addListener(() => notifications++);

    registry.recordPurged(['run-1'], first.scopeKey);
    registry.recordPurged(['run-1'], first.scopeKey);
    registry.recordPurged(['run-1'], second.scopeKey);

    expect(registry.wasPurged('run-1', first.scopeKey), isTrue);
    expect(registry.wasPurged('run-1', second.scopeKey), isTrue);
    expect(registry.purgedTrashScopes('run-1'), {
      first.scopeKey,
      second.scopeKey,
    });
    expect(notifications, 2);
  });

  test('locked marker in another process is reported as active', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    const runId = 'external-run';
    final runKey = base64Url.encode(utf8.encode(runId));
    final markerPath = p.join(
      directory.path,
      '${location.scopeKey}.active.v2.$runKey.lock',
    );
    final child = await startTestFileLockHolder(directory, markerPath);
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    expect(
      await registry.tryBeginPurge([
        location,
      ], SyncTrashPurgeAdmission.requireIdle),
      isNull,
    );

    final purge = await registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.excludeActiveRuns);
    expect(purge, isNotNull);
    expect(purge!.activeRunIds(location), {runId});
    await purge.close();
  });

  test('legacy marker blocks the same run reservation', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    const runId = 'external-run';
    final runKey = sha256.convert(utf8.encode(runId));
    final markerPath = p.join(
      directory.path,
      '${location.scopeKey}.active.$runKey.lock',
    );
    final child = await startTestFileLockHolder(
      directory,
      markerPath,
      markerContents: runId,
    );
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    await expectLater(
      registry.begin(runId, [location], mode: SyncTrashActivityMode.run),
      throwsA(isA<SyncTrashActivityLockException>()),
    );
  });

  test('failed begin releases location gate and preserves its error', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    const runId = 'external-run';
    final currentKey = base64Url.encode(utf8.encode(runId));
    final currentPath = p.join(
      directory.path,
      '${location.scopeKey}.active.v2.$currentKey.lock',
    );
    final child = await startTestFileLockHolder(directory, currentPath);
    addTearDown(child.stop);
    final locationGatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );
    final scopeGatePath = p.join(
      directory.path,
      '${location.scopeKey}.gate.lock',
    );
    final legacyKey = sha256.convert(utf8.encode(runId));
    final legacyPath = p.join(
      directory.path,
      '${location.scopeKey}.active.$legacyKey.lock',
    );
    final locationGate = _LockProbe();
    final marker = _LockProbe(failUnlock: true);
    addTearDown(locationGate.forceClose);
    addTearDown(marker.forceClose);
    final files = {
      locationGatePath: _TrackedLockFile(File(locationGatePath), locationGate),
      scopeGatePath: File(scopeGatePath),
      legacyPath: _TrackedLockFile(File(legacyPath), marker),
      currentPath: File(currentPath),
    };
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    Object? failure;
    await IOOverrides.runZoned(() async {
      try {
        await registry.begin(runId, [
          location,
        ], mode: SyncTrashActivityMode.run);
      } catch (error) {
        failure = error;
      }
    }, createFile: (path) => files[path]!);

    expect(failure, isA<SyncTrashActivityLockException>());
    expect(
      (failure! as SyncTrashActivityLockException).operation,
      'reserve active-run marker',
    );
    expect(locationGate.closed, isTrue);
  });

  test(
    'successful begin transfers failed scope release to its lease',
    () async {
      final directory = await Directory.systemTemp.createTemp('trash-locks-');
      addTearDown(() => directory.delete(recursive: true));
      final location = _localLocation('/one');
      const runId = 'admitted-run';
      final currentKey = base64Url.encode(utf8.encode(runId));
      final legacyKey = sha256.convert(utf8.encode(runId));
      final locationGatePath = p.join(
        directory.path,
        '${location.locationKey}.location.gate.lock',
      );
      final scopeGatePath = p.join(
        directory.path,
        '${location.scopeKey}.gate.lock',
      );
      final legacyPath = p.join(
        directory.path,
        '${location.scopeKey}.active.$legacyKey.lock',
      );
      final currentPath = p.join(
        directory.path,
        '${location.scopeKey}.active.v2.$currentKey.lock',
      );
      final locationGate = _LockProbe();
      final scopeGate = _LockProbe(failUnlock: true);
      final legacyMarker = _LockProbe();
      final currentMarker = _LockProbe();
      addTearDown(locationGate.forceClose);
      addTearDown(scopeGate.forceClose);
      addTearDown(legacyMarker.forceClose);
      addTearDown(currentMarker.forceClose);
      final files = {
        locationGatePath: _TrackedLockFile(
          File(locationGatePath),
          locationGate,
        ),
        scopeGatePath: _TrackedLockFile(File(scopeGatePath), scopeGate),
        legacyPath: _TrackedLockFile(File(legacyPath), legacyMarker),
        currentPath: _TrackedLockFile(File(currentPath), currentMarker),
      };
      final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

      final lease = await IOOverrides.runZoned(
        () =>
            registry.begin(runId, [location], mode: SyncTrashActivityMode.run),
        createFile: (path) => files[path]!,
      );

      expect(registry.activeRunIds(location), {runId});
      expect(scopeGate.closed, isTrue);

      await lease.close();

      expect(registry.activeRunIds(location), isEmpty);
      expect(locationGate.closed, isTrue);
      expect(legacyMarker.closed, isTrue);
      expect(currentMarker.closed, isTrue);
    },
  );

  test(
    'failed purge scan releases every gate and preserves its error',
    () async {
      final directory = await Directory.systemTemp.createTemp('trash-locks-');
      addTearDown(() => directory.delete(recursive: true));
      final location = _localLocation('/one');
      final markerPath = p.join(
        directory.path,
        '${location.scopeKey}.active.v2.!.lock',
      );
      final child = await startTestFileLockHolder(directory, markerPath);
      addTearDown(child.stop);
      final locationGatePath = p.join(
        directory.path,
        '${location.locationKey}.location.gate.lock',
      );
      final scopeGatePath = p.join(
        directory.path,
        '${location.scopeKey}.gate.lock',
      );
      final locationGate = _LockProbe();
      final scopeGate = _LockProbe(failUnlock: true);
      addTearDown(locationGate.forceClose);
      addTearDown(scopeGate.forceClose);
      final files = {
        locationGatePath: _TrackedLockFile(
          File(locationGatePath),
          locationGate,
        ),
        scopeGatePath: _TrackedLockFile(File(scopeGatePath), scopeGate),
        markerPath: File(markerPath),
      };
      final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

      Object? failure;
      await IOOverrides.runZoned(() async {
        try {
          await registry.tryBeginPurge([
            location,
          ], SyncTrashPurgeAdmission.excludeActiveRuns);
        } catch (error) {
          failure = error;
        }
      }, createFile: (path) => files[path]!);

      expect(failure, isA<SyncTrashActivityLockException>());
      expect(
        (failure! as SyncTrashActivityLockException).operation,
        'decode active-run marker name',
      );
      expect(locationGate.closed, isTrue);
    },
  );

  test('failed run close still releases the location gate', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    const runId = 'external-run';
    final currentKey = base64Url.encode(utf8.encode(runId));
    final legacyKey = sha256.convert(utf8.encode(runId));
    final locationGatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );
    final scopeGatePath = p.join(
      directory.path,
      '${location.scopeKey}.gate.lock',
    );
    final legacyPath = p.join(
      directory.path,
      '${location.scopeKey}.active.$legacyKey.lock',
    );
    final currentPath = p.join(
      directory.path,
      '${location.scopeKey}.active.v2.$currentKey.lock',
    );
    final locationGate = _LockProbe();
    final marker = _LockProbe(failUnlock: true);
    addTearDown(locationGate.forceClose);
    addTearDown(marker.forceClose);
    final files = {
      locationGatePath: _TrackedLockFile(File(locationGatePath), locationGate),
      scopeGatePath: File(scopeGatePath),
      legacyPath: File(legacyPath),
      currentPath: _TrackedLockFile(File(currentPath), marker),
    };
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    Object? failure;
    await IOOverrides.runZoned(() async {
      final lease = await registry.begin(runId, [
        location,
      ], mode: SyncTrashActivityMode.run);
      try {
        await lease.close();
      } catch (error) {
        failure = error;
      }
    }, createFile: (path) => files[path]!);

    expect(failure, isA<SyncTrashActivityLockException>());
    expect(
      (failure! as SyncTrashActivityLockException).operation,
      'release active-run markers',
    );
    expect(locationGate.closed, isTrue);
  });

  test('failed purge close still releases the location gate', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final locationGatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );
    final scopeGatePath = p.join(
      directory.path,
      '${location.scopeKey}.gate.lock',
    );
    final locationGate = _LockProbe();
    final scopeGate = _LockProbe(failUnlock: true);
    addTearDown(locationGate.forceClose);
    addTearDown(scopeGate.forceClose);
    final files = {
      locationGatePath: _TrackedLockFile(File(locationGatePath), locationGate),
      scopeGatePath: _TrackedLockFile(File(scopeGatePath), scopeGate),
    };
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    Object? failure;
    await IOOverrides.runZoned(() async {
      final purge = await registry.tryBeginPurge([
        location,
      ], SyncTrashPurgeAdmission.requireIdle);
      try {
        await purge!.close();
      } catch (error) {
        failure = error;
      }
    }, createFile: (path) => files[path]!);

    expect(failure, isA<SyncTrashActivityLockException>());
    expect(
      (failure! as SyncTrashActivityLockException).operation,
      'release gate locks',
    );
    expect(locationGate.closed, isTrue);
  });

  test('locked legacy-only marker identifies a run or fails closed', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    const runId = 'external-run';
    final runKey = sha256.convert(utf8.encode(runId));
    final markerPath = p.join(
      directory.path,
      '${location.scopeKey}.active.$runKey.lock',
    );
    final child = await startTestFileLockHolder(
      directory,
      markerPath,
      markerContents: runId,
    );
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    final scan = registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.excludeActiveRuns);
    if (Platform.isWindows) {
      await expectLater(scan, throwsA(isA<SyncTrashActivityLockException>()));
      expect(await File(markerPath).exists(), isTrue);
      return;
    }

    final purge = await scan;

    expect(purge, isNotNull);
    expect(purge!.activeRunIds(location), {runId});
    expect(await File(markerPath).exists(), isTrue);
    await purge.close();
  });

  test('unlocked malformed current marker is reclaimed', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final marker = File(
      p.join(directory.path, '${location.scopeKey}.active.v2.!.lock'),
    );
    await marker.writeAsString('stale');
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    final purge = await registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.requireIdle);

    expect(purge, isNotNull);
    expect(await marker.exists(), isFalse);
    await purge!.close();
  });

  test('current marker identifies its unreadable legacy companion', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final currentHolderDirectory = Directory(
      p.join(directory.path, 'current-holder'),
    )..createSync();
    final legacyHolderDirectory = Directory(
      p.join(directory.path, 'legacy-holder'),
    )..createSync();
    final location = _localLocation('/one');
    const runId = 'external-run';
    final currentKey = base64Url.encode(utf8.encode(runId));
    final legacyKey = sha256.convert(utf8.encode(runId));
    final current = await startTestFileLockHolder(
      currentHolderDirectory,
      p.join(directory.path, '${location.scopeKey}.active.v2.$currentKey.lock'),
    );
    final legacy = await startTestFileLockHolder(
      legacyHolderDirectory,
      p.join(directory.path, '${location.scopeKey}.active.$legacyKey.lock'),
    );
    addTearDown(current.stop);
    addTearDown(legacy.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    final purge = await registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.excludeActiveRuns);

    expect(purge, isNotNull);
    expect(purge!.activeRunIds(location), {runId});
    await purge.close();
  });

  test('purge gate in another process blocks a new run', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final gatePath = p.join(directory.path, '${location.scopeKey}.gate.lock');
    final child = await startTestFileLockHolder(directory, gatePath);
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    await expectLater(
      registry.begin('new-run', [location], mode: SyncTrashActivityMode.run),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );
  });

  test('restore gate in another process blocks a new run', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final gatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );
    final child = await startTestFileLockHolder(directory, gatePath);
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    await expectLater(
      registry.begin('new-run', [location], mode: SyncTrashActivityMode.run),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );
  });

  test('run gate in another process blocks restore', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final gatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );
    final child = await startTestFileLockHolder(
      directory,
      gatePath,
      lockMode: TestFileLockMode.shared,
    );
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    await expectLater(
      registry.begin('restore-run', [
        location,
      ], mode: SyncTrashActivityMode.restore),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );
  });

  test('failed restore close keeps later runs blocked', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    const runId = 'restore-run';
    final currentKey = base64Url.encode(utf8.encode(runId));
    final legacyKey = sha256.convert(utf8.encode(runId));
    final locationGatePath = p.join(
      directory.path,
      '${location.locationKey}.location.gate.lock',
    );
    final scopeGatePath = p.join(
      directory.path,
      '${location.scopeKey}.gate.lock',
    );
    final legacyPath = p.join(
      directory.path,
      '${location.scopeKey}.active.$legacyKey.lock',
    );
    final currentPath = p.join(
      directory.path,
      '${location.scopeKey}.active.v2.$currentKey.lock',
    );
    final locationGate = _LockProbe(failUnlock: true);
    addTearDown(locationGate.forceClose);
    final files = {
      locationGatePath: _TrackedLockFile(File(locationGatePath), locationGate),
      scopeGatePath: File(scopeGatePath),
      legacyPath: File(legacyPath),
      currentPath: File(currentPath),
    };
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    Object? failure;
    await IOOverrides.runZoned(() async {
      final lease = await registry.begin(runId, [
        location,
      ], mode: SyncTrashActivityMode.restore);
      try {
        await lease.close();
      } catch (error) {
        failure = error;
      }
    }, createFile: (path) => files[path]!);

    SyncTrashActivityLease? admitted;
    Object? admissionFailure;
    try {
      admitted = await registry.begin('later-run', [
        location,
      ], mode: SyncTrashActivityMode.run);
    } catch (error) {
      admissionFailure = error;
    }
    addTearDown(() => admitted?.close());

    expect(failure, isA<SyncTrashActivityLockException>());
    expect(locationGate.closed, isTrue);
    expect(admissionFailure, isA<SyncTrashPurgeInProgressException>());
  });

  test('lock setup failure does not admit a run', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final lockPath = p.join(directory.path, 'not-a-directory');
    await File(lockPath).writeAsString('occupied');
    final registry = SyncTrashActivityRegistry(lockDirectory: lockPath);

    await expectLater(
      registry.begin('new-run', [
        _localLocation('/one'),
      ], mode: SyncTrashActivityMode.run),
      throwsA(isA<SyncTrashActivityLockException>()),
    );
  });
}

SyncTrashLocation _localLocation(String root) => syncTrashLocation(
  endpoint: LocalEndpoint(root),
  canonicalRoot: root,
  rules: const SyncRuleSet(),
  side: SyncSide.left,
  rootId: _rootId(p.normalize(root)),
);

SyncTrashLocation _localAliasLocation(
  SyncTrashLocation location,
  String alias,
) => knownSyncTrashLocation(
  endpoint: LocalEndpoint(alias),
  trashRoot: location.trashRoot,
  pathCase: location.pathCase,
  scopeKey: location.scopeKey,
  locationKey: sha256.convert(utf8.encode('location:$alias')).toString(),
);

String _rootId(String seed) =>
    sha256.convert(utf8.encode(seed)).toString().substring(0, 32);

final class _LockProbe {
  _LockProbe({this.failUnlock = false});

  final bool failUnlock;
  RandomAccessFile? _file;
  bool closed = false;

  Future<void> forceClose() async {
    if (closed) return;
    await _file?.close();
    closed = true;
  }
}

final class _TrackedLockFile implements File {
  const _TrackedLockFile(this._delegate, this._probe);

  final File _delegate;
  final _LockProbe _probe;

  @override
  String get path => _delegate.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    final file = await _delegate.open(mode: mode);
    _probe._file = file;
    return _TrackedRandomAccessFile(file, _probe);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _TrackedRandomAccessFile implements RandomAccessFile {
  const _TrackedRandomAccessFile(this._delegate, this._probe);

  final RandomAccessFile _delegate;
  final _LockProbe _probe;

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
  Future<RandomAccessFile> unlock([int start = 0, int end = -1]) async {
    if (_probe.failUnlock) {
      throw FileSystemException('injected unlock failure', path);
    }
    await _delegate.unlock(start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> truncate(int length) async {
    await _delegate.truncate(length);
    return this;
  }

  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _delegate.setPosition(position);
    return this;
  }

  @override
  Future<RandomAccessFile> writeString(
    String string, {
    Encoding encoding = utf8,
  }) async {
    await _delegate.writeString(string, encoding: encoding);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _delegate.flush();
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
