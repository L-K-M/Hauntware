// The bridged lease's app-side config answers (AppServerConfigSource)
// and the sync environment's remote endpoints over it: bookmark →
// embedded identity, catalog reference → pulled config, Quick Connect
// ids → null (the engine reuses its browse-open config), and a sync
// endpoint leasing under its registered id and releasing on demand.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/server_config_source.dart';
import 'package:poltergeist_app/services/sync_environment.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_state_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/sync_harness.dart';

final _now = DateTime.utc(2026, 9, 24);

Bookmark _bookmark(String id, BookmarkServerRef server) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: 'label-$id',
  server: server,
  sortKey: 'm',
  createdAt: _now,
  updatedAt: _now,
);

const _identity = EmbeddedHostIdentity(
  host: 'web.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.password,
  secretRef: 'secret-1',
);

final class _Bookmarks implements BookmarkRepository {
  _Bookmarks(this.bookmarks);

  final List<Bookmark> bookmarks;

  @override
  Future<List<Bookmark>> load() async => bookmarks;

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {}
}

final class _Connections implements ConnectionManager {
  _Connections({RemoteFileSystem? fileSystem})
    : _fileSystem = fileSystem ?? _Canonical();

  final RemoteFileSystem _fileSystem;
  final leases = <String>[];
  int released = 0;

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async {
    leases.add(serverId);
    return _Lease(_fileSystem, () => released++);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _Lease implements TransferChannelLease {
  _Lease(this.fs, this._onRelease);

  @override
  final RemoteFileSystem fs;
  final void Function() _onRelease;

  @override
  Future<void> release() async => _onRelease();

  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

final class _Canonical implements RemoteFileSystem {
  @override
  Future<String> canonicalize(String path) async => '/canonical$path';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

final class _RetargetingLocalFileSystem extends LocalFileSystem {
  _RetargetingLocalFileSystem(this._retarget);

  final void Function() _retarget;
  var _didRetarget = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    if (!_didRetarget) {
      _didRetarget = true;
      _retarget();
    }

    return super.stat(path, followLinks: followLinks);
  }
}

final class _ToggleTrashResolutionFileSystem extends LocalFileSystem {
  bool failTrashResolution = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) {
    if (failTrashResolution && path.endsWith('.poltergeist-trash')) {
      throw RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'stat',
        path: path,
        message: 'offline',
      );
    }

    return super.stat(path, followLinks: followLinks);
  }
}

void main() {
  group('AppServerConfigSource', () {
    test('an embedded-identity bookmark dials its identity', () async {
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b1', const BookmarkServerRef(identity: _identity)),
        ]),
      );
      final config = await source.configFor('b1');
      expect(config?.id, 'b1');
      expect(config?.host, 'web.example.com');
      expect(config?.port, 2222);
      expect(config?.username, 'deploy');
      expect(config?.secretRef, 'secret-1');
    });

    test('a catalog reference resolves through the pulled catalog', () async {
      final pulled = ServerConfig(
        id: 'cfg-9',
        label: 'pulled',
        host: 'pulled.example.com',
        username: 'ops',
        createdAt: 0,
        updatedAt: 0,
      );
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b2', const BookmarkServerRef(serverConfigId: 'cfg-9')),
        ]),
      );
      // The catalog binds late, like main.dart's composition.
      source.catalogLookup = (id) => id == 'cfg-9' ? pulled : null;
      expect((await source.configFor('b2'))?.host, 'pulled.example.com');
    });

    test('a raw catalog id restores its routed lease', () async {
      const pulled = ServerConfig(
        id: 'cfg-db',
        label: 'database',
        host: 'db.internal',
        username: 'ops',
        jumpHostId: 'bastion',
        createdAt: 0,
        updatedAt: 0,
      );
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks(const []),
        catalogLookup: (id) => id == pulled.id ? pulled : null,
      );

      final config = await source.configFor(pulled.id);

      expect(config, same(pulled));
      expect(config?.jumpHostId, 'bastion');
    });

    test('a catalog miss without an identity refuses typed', () async {
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b3', const BookmarkServerRef(serverConfigId: 'gone')),
        ]),
        catalogLookup: (_) => null,
      );
      await expectLater(
        source.configFor('b3'),
        throwsA(
          isA<RemoteFileException>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)
              .having((e) => e.message, 'message', contains('label-b3')),
        ),
      );
    });

    test('a jump-routed catalog server preserves the lease route', () async {
      const pulled = ServerConfig(
        id: 'cfg-db',
        label: 'db',
        host: 'db.internal',
        username: 'ops',
        jumpHostId: 'bastion',
        createdAt: 0,
        updatedAt: 0,
      );
      final source = AppServerConfigSource(
        bookmarks: _Bookmarks([
          _bookmark('b4', const BookmarkServerRef(serverConfigId: 'cfg-db')),
        ]),
        catalogLookup: (id) => id == 'cfg-db' ? pulled : null,
      );
      final endpoint = source.registerEndpoint(
        const BookmarkServerRef(serverConfigId: 'cfg-db'),
      );
      expect((await source.configFor('b4'))?.jumpHostId, 'bastion');
      expect((await source.configFor(endpoint))?.jumpHostId, 'bastion');
    });

    test('an unknown id (Quick Connect) answers null', () async {
      final source = AppServerConfigSource(bookmarks: _Bookmarks(const []));
      expect(await source.configFor('adhoc:1234'), isNull);
    });

    test('registrations win and endpoints share one id per server', () async {
      final source = AppServerConfigSource(bookmarks: _Bookmarks(const []));
      final first = source.registerEndpoint(
        const BookmarkServerRef(identity: _identity),
      );
      final second = source.registerEndpoint(
        const BookmarkServerRef(identity: _identity),
      );
      expect(first, second);
      final config = await source.configFor(first);
      expect(config?.host, 'web.example.com');
      expect(config?.id, first);
    });
  });

  group('SyncEnvironment remote endpoints', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('sync-env-'));
    tearDown(() => temp.deleteSync(recursive: true));

    SyncEnvironment environment({
      ConnectionManager? connections,
      AppServerConfigSource? serverConfigs,
    }) => SyncEnvironment(
      states: FileSyncStateStore(Directory('${temp.path}/state')),
      syncRunsDirectory: '${temp.path}/runs',
      deviceId: () async => 'device',
      connections: connections,
      serverConfigs:
          serverConfigs ??
          AppServerConfigSource(bookmarks: _Bookmarks(const [])),
    );

    const remote = RemoteEndpoint(
      server: BookmarkServerRef(identity: _identity),
      path: '/srv',
    );

    test('without the engine bridge a remote endpoint refuses typed', () {
      final env = environment();
      expect(env.endpointAvailable(remote), isFalse);
      expect(
        () => env.fileSystemFor(remote),
        throwsA(
          isA<RemoteFileException>().having(
            (e) => e.kind,
            'kind',
            RemoteFileErrorKind.unsupported,
          ),
        ),
      );
    });

    test('with the bridge it leases on demand and releases', () async {
      final connections = _Connections();
      final env = environment(connections: connections);
      expect(env.endpointAvailable(remote), isTrue);
      final fs = env.fileSystemFor(remote);
      // One shared filesystem per server.
      expect(identical(fs, env.fileSystemFor(remote)), isTrue);
      expect(await fs.canonicalize('/srv'), '/canonical/srv');
      expect(connections.leases, ['sync-endpoint:deploy@web.example.com:2222']);
      await env.releaseRemoteLeases();
      expect(connections.released, 1);
      // The next call leases again.
      await fs.canonicalize('/srv');
      expect(connections.leases, hasLength(2));
      await env.releaseRemoteLeases();
    });

    test('trash keys follow a retargeted catalog endpoint', () async {
      var config = const ServerConfig(
        id: 'cfg-live',
        label: 'live',
        host: 'one.example.com',
        username: 'deploy',
        createdAt: 0,
        updatedAt: 0,
      );
      final configs = AppServerConfigSource(
        bookmarks: _Bookmarks(const []),
        catalogLookup: (_) => config,
      );
      final env = environment(
        connections: _Connections(fileSystem: LocalFileSystem()),
        serverConfigs: configs,
      );
      final root = Directory('${temp.path}/remote')..createSync();
      const endpoint = RemoteEndpoint(
        server: BookmarkServerRef(serverConfigId: 'cfg-live'),
        path: '/srv',
      );
      final rules = SyncRuleSet(trashPathLeft: '${root.path}/trash');

      final first = await env.resolveTrashLocation(
        endpoint: endpoint,
        canonicalRoot: root.path,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      config = const ServerConfig(
        id: 'cfg-live',
        label: 'live',
        host: 'two.example.com',
        username: 'deploy',
        createdAt: 0,
        updatedAt: 0,
      );
      final second = await env.resolveTrashLocation(
        endpoint: endpoint,
        canonicalRoot: root.path,
        rules: rules,
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );

      expect(second.scopeKey, first.scopeKey);
      expect(second.locationKey, isNot(first.locationKey));
    });

    test(
      'cached catalog trash remains visible after resolution fails',
      () async {
        const config = ServerConfig(
          id: 'cfg-live',
          label: 'live',
          host: 'one.example.com',
          username: 'deploy',
          createdAt: 0,
          updatedAt: 0,
        );
        final configs = AppServerConfigSource(
          bookmarks: _Bookmarks(const []),
          catalogLookup: (_) => config,
        );
        final fileSystem = _ToggleTrashResolutionFileSystem();
        final env = environment(
          connections: _Connections(fileSystem: fileSystem),
          serverConfigs: configs,
        );
        final remoteRoot = Directory('${temp.path}/remote')..createSync();
        final localRoot = Directory('${temp.path}/local')..createSync();
        const endpoint = RemoteEndpoint(
          server: BookmarkServerRef(serverConfigId: 'cfg-live'),
          path: '/srv',
        );
        final pair = SyncPair(
          id: 'pair-1',
          name: 'Remote to local',
          left: endpoint,
          right: LocalEndpoint(localRoot.path),
          rules: const SyncRuleSet(),
        );
        final trashRoot = Directory(
          '${remoteRoot.path}/.poltergeist-trash',
        )..createSync();
        final identity = await resolveSyncTrashRoot(
          fileSystem,
          trashRoot.path,
          pathStyle: SyncTrashPathStyle.posix,
          access: SyncTrashRootAccess.createOrClaim,
        );
        const runId =
            '12345678-12345678-1234-4123-a123-123456789abc';
        final runDirectory = Directory('${trashRoot.path}/$runId')
          ..createSync();
        final trashed = File('${runDirectory.path}/000001-a.txt')
          ..writeAsStringSync('old');
        final journal = await SyncRunJournal.create(
          env.syncRunsDirectory,
          SyncRunRecord(
            runId: runId,
            pairId: pair.id,
            startedAt: DateTime.now().subtract(const Duration(days: 31)),
            trashScopeLeft: identity.scopeKey,
            rules: pair.rules,
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
            bytes: trashed.lengthSync(),
          ),
        );
        final scanner = FakeSyncScanner(
          left: testScanResult(remoteRoot.path, const {}),
          right: testScanResult(localRoot.path, const {}),
        );
        final first = testController(
          pair: pair,
          scanner: scanner,
          differ: FakeSyncDiffer(testPlan(pair, const [])),
          environment: env,
        );

        first.start();
        await pumpUntil(() => first.trashNotices.isNotEmpty);
        await first.prepareFullTrashPurgeLive();
        final cachedLocationKey = first.pairState.trashCacheLeft?.locationKey;
        expect(cachedLocationKey, isNotNull);
        first.dispose();

        fileSystem.failTrashResolution = true;
        final fallback = await env.trashLocationFor(
          endpoint: endpoint,
          canonicalRoot: remoteRoot.path,
          rules: pair.rules,
          side: SyncSide.left,
          pathCase: SyncTrashPathCase.sensitive,
        );
        expect(fallback.locationKey, cachedLocationKey);
        final second = testController(
          pair: pair,
          scanner: scanner,
          differ: FakeSyncDiffer(testPlan(pair, const [])),
          environment: env,
        );
        addTearDown(second.dispose);
        second.start();
        await pumpUntil(() => second.phase == SyncPlanPhase.ready);
        await second.prepareFullTrashPurgeLive();

        expect(second.trashNotices, hasLength(1));
        expect(second.trashNotices.single.isStale, isTrue);
        expect(
          second.pairState.trashCacheLeft?.locationKey,
          cachedLocationKey,
        );
      },
    );

    test('trash resolution rejects a concurrent endpoint retarget', () async {
      var config = const ServerConfig(
        id: 'cfg-live',
        label: 'live',
        host: 'one.example.com',
        username: 'deploy',
        createdAt: 0,
        updatedAt: 0,
      );
      final configs = AppServerConfigSource(
        bookmarks: _Bookmarks(const []),
        catalogLookup: (_) => config,
      );
      final fileSystem = _RetargetingLocalFileSystem(() {
        config = const ServerConfig(
          id: 'cfg-live',
          label: 'live',
          host: 'two.example.com',
          username: 'deploy',
          createdAt: 0,
          updatedAt: 0,
        );
      });
      final env = environment(
        connections: _Connections(fileSystem: fileSystem),
        serverConfigs: configs,
      );
      final root = Directory('${temp.path}/remote')..createSync();
      const endpoint = RemoteEndpoint(
        server: BookmarkServerRef(serverConfigId: 'cfg-live'),
        path: '/srv',
      );

      await expectLater(
        env.resolveTrashLocation(
          endpoint: endpoint,
          canonicalRoot: root.path,
          rules: SyncRuleSet(trashPathLeft: '${root.path}/trash'),
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
    });

    test('trash verification rejects a retargeted endpoint', () async {
      var config = const ServerConfig(
        id: 'cfg-live',
        label: 'live',
        host: 'one.example.com',
        username: 'deploy',
        createdAt: 0,
        updatedAt: 0,
      );
      final configs = AppServerConfigSource(
        bookmarks: _Bookmarks(const []),
        catalogLookup: (_) => config,
      );
      final env = environment(
        connections: _Connections(fileSystem: LocalFileSystem()),
        serverConfigs: configs,
      );
      final root = Directory('${temp.path}/remote')..createSync();
      const endpoint = RemoteEndpoint(
        server: BookmarkServerRef(serverConfigId: 'cfg-live'),
        path: '/srv',
      );
      final location = await env.resolveTrashLocation(
        endpoint: endpoint,
        canonicalRoot: root.path,
        rules: SyncRuleSet(trashPathLeft: '${root.path}/trash'),
        side: SyncSide.left,
        pathCase: SyncTrashPathCase.sensitive,
      );
      config = const ServerConfig(
        id: 'cfg-live',
        label: 'live',
        host: 'two.example.com',
        username: 'deploy',
        createdAt: 0,
        updatedAt: 0,
      );

      await expectLater(
        env.verifyTrashLocation(endpoint, location),
        throwsA(
          isA<RemoteFileException>().having(
            (error) => error.kind,
            'kind',
            RemoteFileErrorKind.conflict,
          ),
        ),
      );
    });
  });
}
