import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/atomic_file.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_core/catalog.dart' show PersistentLocalRecordStore;
import 'package:seance_core/seance_core.dart';

class _AcceptingSyncApi implements SyncApi {
  final Map<String, EncryptedRecord> records = {};
  int _latestSeq = 0;

  @override
  Future<PullResponse> pull({required int since}) async => PullResponse(
    records: records.values
        .where((record) => (record.seq ?? 0) > since)
        .toList(),
    latestSeq: _latestSeq,
  );

  @override
  Future<PushResponse> push(List<EncryptedRecord> pushed) async {
    final results = <PushResult>[];
    for (final record in pushed) {
      final stored = record.withSeq(++_latestSeq);
      records[record.id] = stored;
      results.add(PushResult(id: record.id, seq: _latestSeq, accepted: true));
    }
    return PushResponse(results: results, latestSeq: _latestSeq);
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('seance_atomic_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('writeStringAtomically', () {
    test('creates the parent directory and round-trips content', () async {
      final file = File('${dir.path}/nested/deep/data.json');
      await writeStringAtomically(file, '{"hello":"world"}');
      expect(await file.readAsString(), '{"hello":"world"}');
    });

    test('replaces existing content and leaves no temp file behind', () async {
      final file = File('${dir.path}/data.json');
      await writeStringAtomically(file, 'first');
      await writeStringAtomically(file, 'second');
      expect(await file.readAsString(), 'second');
      expect(await File('${file.path}.tmp').exists(), isFalse);
    });

    test('overlapping writes preserve the last requested complete snapshot',
        () async {
      final file = File('${dir.path}/data.json');
      final snapshots = [
        for (var i = 0; i < 16; i++) '{"snapshot":"$i${'x' * (4096 + i)}"}',
      ];
      await Future.wait([
        for (final snapshot in snapshots)
          writeStringAtomically(File(file.path), snapshot),
      ]);
      expect(await file.readAsString(), snapshots.last);
      expect(await dir.list().toList(), hasLength(1));
    });

    test('a failed write does not block later saves to the same path', () async {
      final file = File('${dir.path}/data.json');
      final blocked = Directory('${file.path}.tmp');
      await blocked.create();
      await expectLater(writeStringAtomically(file, 'first'),
          throwsA(isA<FileSystemException>()));
      await blocked.delete();

      await writeStringAtomically(file, 'second');
      expect(await file.readAsString(), 'second');
    });

    test('case-variant paths preserve write order and filesystem identity',
        () async {
      final file = File('${dir.path}/data.json');
      final alias = File('${dir.path}/DATA.json');
      await file.writeAsString('initial');
      // Windows and ordinary macOS volumes alias these names; Linux usually
      // keeps two files. The queue must protect either filesystem's behavior.
      final aliasesSameFile = await alias.exists();
      final snapshots = [
        for (var i = 0; i < 16; i++) '$i:${'x' * (4096 + i)}',
      ];

      await Future.wait([
        for (var i = 0; i < snapshots.length; i++)
          writeStringAtomically(i.isEven ? file : alias, snapshots[i]),
      ]);

      expect(await file.readAsString(),
          aliasesSameFile ? snapshots.last : snapshots[snapshots.length - 2]);
      expect(await alias.readAsString(), snapshots.last);
      expect(await dir.list().toList(), hasLength(aliasesSameFile ? 1 : 2));
    });
  });

  group('quarantineCorruptFile', () {
    test('moves the bad file aside to *.corrupt', () async {
      final file = File('${dir.path}/data.json');
      await file.writeAsString('not json');
      await quarantineCorruptFile(file);
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.corrupt').exists(), isTrue);
    });
  });

  group('FileConfigStore resilience', () {
    test('a corrupt servers file does not throw and starts empty', () async {
      final file = File('${dir.path}/servers.json');
      await file.writeAsString('}{ this is not valid json');
      final store = FileConfigStore(file);
      // Must not throw (previously this crashed app startup).
      expect(await store.listServers(), isEmpty);
      // The bad file was quarantined so it can't wedge the next launch either.
      expect(await File('${file.path}.corrupt').exists(), isTrue);
    });

    test('a valid round-trip still works after the atomic-write change',
        () async {
      final file = File('${dir.path}/servers.json');
      final store = FileConfigStore(file);
      final now = DateTime.now().millisecondsSinceEpoch;
      await store.putServer(ServerConfig(
        id: 'a',
        label: 'box',
        host: 'example.com',
        username: 'me',
        authMethod: AuthMethod.password,
        createdAt: now,
        updatedAt: now,
      ));
      final reloaded = FileConfigStore(file);
      final servers = await reloaded.listServers();
      expect(servers, hasLength(1));
      expect(servers.single.host, 'example.com');
    });

    test(
      'a quarantined partial rewrite heals from the durable sync mirror',
      () async {
        final serversFile = File('${dir.path}/servers.json');
        final mirrorFile = File('${dir.path}/sync_records.json');
        final marker = File('${serversFile.path}.sync-recovery');
        final key = secureRandomBytes(32);
        final codec = RecordCodec(key);
        const mirrored = ServerConfig(
          id: 'mirrored',
          label: 'Mirrored',
          host: 'mirrored.example.com',
          username: 'deploy',
          createdAt: 1,
          updatedAt: 10,
        );
        const writtenAfterDamage = ServerConfig(
          id: 'new',
          label: 'New',
          host: 'new.example.com',
          username: 'deploy',
          createdAt: 20,
          updatedAt: 20,
        );

        final mirror = PersistentLocalRecordStore(path: mirrorFile.path);
        await mirror.initialize();
        await mirror.putLocal(
          await codec.encrypt(
            DecryptedRecord(
              id: mirrored.id,
              kind: RecordKind.serverConfig,
              updatedAt: mirrored.updatedAt,
              deviceId: 'local',
              data: mirrored.toJson(),
            ),
          ),
        );

        await serversFile.writeAsString('{not valid json');
        final damaged = FileConfigStore(serversFile);
        expect(await damaged.listServers(), isEmpty);
        expect(marker.existsSync(), isTrue);

        // A save before the next sync is a valid but incomplete snapshot. The
        // durable sidecar must survive it and the following process restart.
        await damaged.putServer(writtenAfterDamage);
        final reopenedSource = FileConfigStore(serversFile);
        expect(
          reopenedSource.syncCollectionFailed,
          isFalse,
          reason: 'the source has not loaded its durable marker yet',
        );
        expect(
          (await reopenedSource.listServers()).map((server) => server.id),
          [writtenAfterDamage.id],
        );
        expect(reopenedSource.syncCollectionFailed, isTrue);

        final reopenedMirror = PersistentLocalRecordStore(
          path: mirrorFile.path,
        );
        await reopenedMirror.initialize();
        final api = _AcceptingSyncApi();
        await SyncCoordinator(
          configStore: reopenedSource,
          hostKeyStore: InMemoryHostKeyStore(),
          codec: codec,
          local: reopenedMirror,
          deviceId: 'local',
        ).run(api);

        expect(
          (await reopenedSource.listServers()).map((server) => server.id),
          unorderedEquals([mirrored.id, writtenAfterDamage.id]),
        );
        expect(
          api.records.keys,
          unorderedEquals([mirrored.id, writtenAfterDamage.id]),
        );
        expect(reopenedSource.syncCollectionFailed, isFalse);
        expect(marker.existsSync(), isFalse);
      },
    );
  });

  test('concurrent host-key approvals persist every approved key', () async {
    final file = File('${dir.path}/known_hosts.json');
    final store = FileHostKeyStore(file);
    final keys = [
      for (var i = 0; i < 8; i++)
        HostKey(
          host: 'host$i.test',
          port: 22,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:key$i',
          pinnedAt: i,
        ),
    ];
    await Future.wait(keys.map(store.put));

    final restored = await FileHostKeyStore(file).all();
    expect(restored.map((key) => key.fingerprintSha256),
        unorderedEquals(keys.map((key) => key.fingerprintSha256)));
  });

  test('a failed host-key write cannot leak into a later snapshot', () async {
    final file = File('${dir.path}/known_hosts.json');
    // Block the staging path used by writeStringAtomically().
    final blocked = Directory('${file.path}.tmp')..createSync();
    final store = FileHostKeyStore(file);
    const failed = HostKey(
      host: 'failed.example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:failed',
      pinnedAt: 1,
    );
    const saved = HostKey(
      host: 'saved.example.com',
      port: 22,
      type: 'ssh-ed25519',
      fingerprintSha256: 'SHA256:saved',
      pinnedAt: 2,
    );

    try {
      await expectLater(store.put(failed), throwsA(isA<FileSystemException>()));
    } finally {
      await blocked.delete();
    }
    await store.put(saved);

    final restored = await FileHostKeyStore(file).all();
    expect(restored.map((key) => key.locator), [saved.locator]);
    expect(await store.get(failed.host, failed.port), isNull);
  });
}
