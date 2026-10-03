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

    final lease = await registry.begin('device-run', [first]);

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

    final lease = await registry.begin('device-run', [first]);

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

    final lease = await registry.begin('device-run', [location, location]);
    await lease.close();
    await lease.close();

    expect(notifications, 2);
    expect(registry.activeRunIds(location), isEmpty);
  });

  test('aged purge snapshots existing runs and blocks new ones', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    final run = await registry.begin('active-run', [location]);

    final purge = await registry.tryBeginPurge([
      location,
    ], SyncTrashPurgeAdmission.excludeActiveRuns);

    expect(purge, isNotNull);
    expect(purge!.activeRunIds(location), {'active-run'});
    await expectLater(
      registry.begin('new-run', [location]),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );
    await purge.close();
    await run.close();
  });

  test('full purge requires every target root to be idle', () async {
    final location = _localLocation('/one');
    final registry = SyncTrashActivityRegistry();
    final run = await registry.begin('active-run', [location]);

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
        second.begin('new-run', [location]),
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

  test('purge gate in another process blocks a new run', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final location = _localLocation('/one');
    final gatePath = p.join(directory.path, '${location.scopeKey}.gate.lock');
    final child = await startTestFileLockHolder(directory, gatePath);
    addTearDown(child.stop);
    final registry = SyncTrashActivityRegistry(lockDirectory: directory.path);

    await expectLater(
      registry.begin('new-run', [location]),
      throwsA(isA<SyncTrashPurgeInProgressException>()),
    );
  });

  test('lock setup failure does not admit a run', () async {
    final directory = await Directory.systemTemp.createTemp('trash-locks-');
    addTearDown(() => directory.delete(recursive: true));
    final lockPath = p.join(directory.path, 'not-a-directory');
    await File(lockPath).writeAsString('occupied');
    final registry = SyncTrashActivityRegistry(lockDirectory: lockPath);

    await expectLater(
      registry.begin('new-run', [_localLocation('/one')]),
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

String _rootId(String seed) =>
    sha256.convert(utf8.encode(seed)).toString().substring(0, 32);
