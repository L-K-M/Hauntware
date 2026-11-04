import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

final _fixedNow = DateTime.utc(2026, 9, 20, 12);

/// Separator-robust basename (listSync joins with the host separator).
String _basenameOf(String path) => path.split(RegExp(r'[\\/]')).last;

EncryptedRecord _record(
  String id, {
  int updatedAt = 100,
  String deviceId = 'device-a',
  bool deleted = false,
  int? seq,
  List<int>? blob,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: deleted,
      seq: seq,
      blob: Uint8List.fromList(blob ?? const [1, 2, 3]),
    );

EncryptedRecord _tombstone(
  String id, {
  int updatedAt = 100,
  String deviceId = 'device-a',
  int? seq,
}) =>
    EncryptedRecord(
      id: id,
      updatedAt: updatedAt,
      deviceId: deviceId,
      deleted: true,
      seq: seq,
      blob: Uint8List(0),
    );

void main() {
  late Directory tempDir;
  late String path;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('record_store_test');
    path = '${tempDir.path}/sync_records.json';
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  PersistentLocalRecordStore open({
    SyncAccountScope? scope,
    bool adoptLegacy = false,
    bool resetExisting = false,
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
  }) =>
      PersistentLocalRecordStore(
        path: path,
        scope: scope,
        adoptLegacy: adoptLegacy,
        resetExisting: resetExisting,
        now: now,
        onError: onError,
      );

  final alice = SyncAccountScope(
    baseUrl: 'https://sync.example',
    username: 'alice',
  );

  group('mutation and reload', () {
    test('persists records, dirty flags, and both cursors across reload',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 50));
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));
      await store.setHighWaterSeq(9);
      await store.setLastAppliedSeq(8);

      final reloaded = open();
      final records = await reloaded.allRecords();
      expect(records, hasLength(2));
      expect((await reloaded.dirtyRecords()).map((r) => r.id),
          ['bookmark:a']);
      expect(await reloaded.highWaterSeq(), 9);
      expect(await reloaded.lastAppliedSeq(), 8);
      expect(
          (await reloaded.getRecord('bookmark:b'))!.seq, 7);
    });

    test('markSynced clears dirty and stamps the server seq', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a'));
      await store.markSynced('bookmark:a', 12);

      final reloaded = open();
      expect(await reloaded.dirtyRecords(), isEmpty);
      expect((await reloaded.getRecord('bookmark:a'))!.seq, 12);
    });

    test('highWaterSeq and lastAppliedSeq only advance', () async {
      final store = open();
      await store.setHighWaterSeq(10);
      await store.setHighWaterSeq(5);
      await store.setLastAppliedSeq(9);
      await store.setLastAppliedSeq(3);
      expect(await store.highWaterSeq(), 10);
      expect(await store.lastAppliedSeq(), 9);
    });

    test('resetSyncCursors zeroes both cursors for a full resync', () async {
      final store = open();
      await store.putRemote(_record('bookmark:clean', seq: 8));
      await store.setHighWaterSeq(10);
      await store.setLastAppliedSeq(9);
      await store.resetSyncCursors();
      expect(await store.highWaterSeq(), 0);
      expect(await store.lastAppliedSeq(), 0);
      // The reset must be durable: a restart cannot resurrect stale
      // cursors and skip the records that needed re-pulling.
      final reloaded = open();
      expect(await reloaded.highWaterSeq(), 0);
      expect(await reloaded.lastAppliedSeq(), 0);
      expect(await reloaded.getRecord('bookmark:clean'), isNotNull,
          reason: 'a deliberate apply rescan keeps the server mirror');
    });

    test('rejected cursor recovery re-queues mirror and preserves local edits',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:clean', seq: 8));
      await store.putRemote(_record('bookmark:edited', seq: 9));
      await store.putLocal(_record('bookmark:edited', updatedAt: 110));
      await store.putRemote(_tombstone('bookmark:deleted', seq: 10));
      await store.setHighWaterSeq(10);
      await store.setLastAppliedSeq(9);

      await store.recoverFromRejectedCursor();

      final reloaded = open();
      expect((await reloaded.getRecord('bookmark:clean'))!.seq, isNull);
      expect(
        (await reloaded.dirtyRecords()).map((record) => record.id),
        unorderedEquals([
          'bookmark:clean',
          'bookmark:edited',
          'bookmark:deleted',
        ]),
      );
      expect((await reloaded.getRecord('bookmark:deleted'))!.deleted, isTrue);
      expect((await reloaded.getRecord('bookmark:deleted'))!.seq, isNull,
          reason: 'the current server copy must be able to settle the retry');
      expect(await reloaded.displacedRecords(), isEmpty);
      expect(await reloaded.highWaterSeq(), 0);
      expect(await reloaded.lastAppliedSeq(), 0);
      expect(await reloaded.cursorRecoveryPending(), isTrue);

      await reloaded.completeCursorRecovery();

      expect(await open().cursorRecoveryPending(), isFalse);
    });
  });

  group('atomic writes', () {
    test('every mutation leaves a complete JSON document on disk', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a'));
      final decoded =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      expect(decoded['version'], 1);
      expect(decoded['highWaterSeq'], 0);
      expect(decoded['lastAppliedSeq'], 0);
      expect(decoded['records'], hasLength(1));
      expect(decoded['records'][0]['dirty'], isTrue);
    });

    test('no stray temp siblings remain after writes', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a'));
      await store.putRemote(_record('bookmark:b', seq: 3));
      final siblings =
          tempDir.listSync().map((entity) => _basenameOf(entity.path)).toList();
      expect(siblings, ['sync_records.json']);
    });
  });

  group('LWW merge and tombstones', () {
    test('putRemote stores a winning pulled record clean', () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 10));
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4));
      expect((await store.getRecord('bookmark:a'))!.updatedAt, 20);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('putRemote never overwrites a dirty local record that beats it',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 30));
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4));
      final kept = await store.getRecord('bookmark:a');
      expect(kept!.updatedAt, 30);
      expect(await store.dirtyRecords(), isNotEmpty);
    });

    const rejected = PushResult(id: 'bookmark:a', seq: 0, accepted: false);

    test('a rejected push restores a stashed losing pull after a reopen',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:a', updatedAt: 30));
      // The server's copy loses to the dirty local — but it is still the
      // record the server holds, and must resurface if the push is rejected.
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4));

      // Settle through a freshly opened store: the stash must round-trip
      // through disk, since the pull cursor has already moved past its seq.
      final reloaded = open();
      final sent = (await reloaded.dirtyRecords()).single;
      final restored = await reloaded.settlePush(
        sent,
        const PushResult(id: 'bookmark:a', seq: 4, accepted: false),
      );
      expect(restored, isNotNull);
      expect(restored!.updatedAt, 20);
      expect(restored.seq, 4);
      expect(await reloaded.getRecord('bookmark:a'), same(restored));
      expect(await reloaded.dirtyRecords(), isEmpty);
      expect(await reloaded.displacedRecords(), isEmpty);
      expect(await open().displacedRecords(), isEmpty);
      // Consume-on-restore: settling the same push again resurrects nothing.
      expect(await reloaded.settlePush(sent, rejected), isNull);
    });

    test('a rejected push restores a clean winner its edit evicted',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      // A clock-skewed local edit loses to the pulled winner's tuple.
      await store.putLocal(_record('bookmark:a', updatedAt: 100));

      final reloaded = open();
      final sent = (await reloaded.dirtyRecords()).single;
      expect(sent.updatedAt, 100);
      final restored = await reloaded.settlePush(
        sent,
        const PushResult(id: 'bookmark:a', seq: 5, accepted: false),
      );
      expect(restored!.updatedAt, 200);
      expect(restored.seq, 5);
      expect(await reloaded.getRecord('bookmark:a'), same(restored));
      expect(await reloaded.dirtyRecords(), isEmpty);
      expect(await reloaded.displacedRecords(), isEmpty);
      expect(await open().displacedRecords(), isEmpty);
      expect(await reloaded.settlePush(sent, rejected), isNull);
    });

    test('a rejected push waits for a queued write that stashes the winner',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      // Queue the displacing putLocal and settle without awaiting it: the
      // stash lands inside the serialized write, so settlePush must run
      // behind it on the same queue.
      final local = _record('bookmark:a', updatedAt: 100);
      final put = store.putLocal(local);
      final restored = await store.settlePush(
        local,
        const PushResult(id: 'bookmark:a', seq: 5, accepted: false),
      );
      expect(restored, isNotNull);
      expect(restored!.updatedAt, 200);
      expect(restored.seq, 5);
      await put;
      expect(await store.dirtyRecords(), isEmpty);
      expect(await store.displacedRecords(), isEmpty);
    });

    test('a rejected push with nothing displaced keeps the edit dirty',
        () async {
      final store = open();
      final local = _record('bookmark:a', updatedAt: 30);
      await store.putLocal(local);
      expect(await store.settlePush(local, rejected), isNull);
      expect((await store.dirtyRecords()).single, same(local));
    });

    test('a rejection for a newer winner drops a stale displaced copy',
        () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      final sent = (await store.dirtyRecords()).single;

      final restored = await store.settlePush(
        sent,
        const PushResult(id: 'bookmark:a', seq: 6, accepted: false),
      );

      expect(restored, isNull);
      expect(await store.getRecord('bookmark:a'), same(sent));
      expect(await store.dirtyRecords(), [same(sent)]);
      expect(await store.displacedRecords(), isEmpty);
      expect(await open().displacedRecords(), isEmpty);
    });

    test('markSynced drops a populated displaced stash', () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      expect(await store.displacedRecords(), hasLength(1));
      // The edit is accepted after all — the displaced copy is dead.
      await store.markSynced('bookmark:a', 9);
      expect(await store.displacedRecords(), isEmpty);
    });

    test('an accepted push drops a populated displaced stash', () async {
      final store = open();
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      expect(await store.displacedRecords(), hasLength(1));
      final sent = (await store.dirtyRecords()).single;
      expect(
        await store.settlePush(
          sent,
          const PushResult(id: 'bookmark:a', seq: 9, accepted: true),
        ),
        isNull,
      );
      expect(await store.displacedRecords(), isEmpty);
      expect((await store.getRecord('bookmark:a'))!.seq, 9);
      expect(await store.dirtyRecords(), isEmpty);
    });

    test('cancelling a brand-new local publication removes it durably',
        () async {
      final store = open();
      await store.putLocal(_record('bookmark:new'));

      await store.cancelLocal('bookmark:new');

      expect(await store.getRecord('bookmark:new'), isNull);
      expect(await store.dirtyRecords(), isEmpty);
      expect(await open().getRecord('bookmark:new'), isNull);
    });

    test('cancelling a local edit restores the clean server copy', () async {
      final store = open();
      final remote = _record(
        'bookmark:a',
        updatedAt: 10,
        deviceId: 'remote',
        seq: 5,
        blob: [8, 9],
      );
      await store.putRemote(remote);
      await store.putLocal(_record(
        'bookmark:a',
        updatedAt: 20,
        deviceId: 'local',
        blob: [1, 2],
      ));

      final reopened = open();
      await reopened.cancelLocal('bookmark:a');

      final restored = await reopened.getRecord('bookmark:a');
      expect(restored!.seq, 5);
      expect(restored.blob, [8, 9]);
      expect(await reopened.dirtyRecords(), isEmpty);
      expect((await open().getRecord('bookmark:a'))!.blob, [8, 9]);
    });

    test('tombstone wins over an older pulled edit and stays in the store',
        () async {
      final store = open();
      await store.putLocal(_tombstone('bookmark:a', updatedAt: 50));
      await store.putRemote(_record('bookmark:a', updatedAt: 40, seq: 3));
      final kept = await store.getRecord('bookmark:a');
      expect(kept!.deleted, isTrue);
      expect(kept.updatedAt, 50);
      // The tombstone is retained indefinitely — never GC'd.
      expect(await store.allRecords(), hasLength(1));
    });

    test('a newer pulled edit legitimately beats a tombstone', () async {
      final store = open();
      await store.putLocal(_tombstone('bookmark:a', updatedAt: 10));
      await store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 6));
      expect((await store.getRecord('bookmark:a'))!.deleted, isFalse);
    });

    test('LWW tie breaks on deviceId', () async {
      final store = open();
      await store.putRemote(
          _record('bookmark:a', updatedAt: 10, deviceId: 'zzz', seq: 1));
      await store.putRemote(
          _record('bookmark:a', updatedAt: 10, deviceId: 'aaa', seq: 2));
      expect((await store.getRecord('bookmark:a'))!.deviceId, 'zzz');
    });
  });

  group('corrupt-store quarantine', () {
    test('a corrupt file is quarantined and the store restarts empty',
        () async {
      File(path).writeAsStringSync('{not json');
      final errors = <Object>[];
      final store = open(
          now: () => _fixedNow, onError: (error, _) => errors.add(error));

      expect(await store.allRecords(), isEmpty);
      expect(errors, hasLength(1));

      final quarantined = tempDir
          .listSync()
          .map((entity) => _basenameOf(entity.path))
          .where((name) => name.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(1));
      expect(quarantined.single, startsWith('sync_records.json.corrupt-'));
      expect(store.quarantinedPath, isNotNull);
    });

    test('a same-timestamp second corruption gets a distinct counter name',
        () async {
      File(path).writeAsStringSync('{not json');
      await open(now: () => _fixedNow).allRecords();

      // Corrupt the freshly recreated file at the same injected instant.
      File(path).writeAsStringSync('["still not a map doc"');
      await open(now: () => _fixedNow).allRecords();

      final quarantined = tempDir
          .listSync()
          .map((entity) => _basenameOf(entity.path))
          .where((name) => name.contains('.corrupt-'))
          .toList();
      expect(quarantined, hasLength(2));
    });

    test('a document with no version field is quarantined, not adopted',
        () async {
      // A versionless map was never written by this build — it quarantines
      // like any other malformed root rather than loading as v1.
      File(path).writeAsStringSync(
          '{"highWaterSeq":0,"lastAppliedSeq":0,"records":[]}');
      final errors = <Object>[];
      final store =
          open(now: () => _fixedNow, onError: (error, _) => errors.add(error));
      expect(await store.allRecords(), isEmpty);
      expect(errors, hasLength(1));
      expect(
          tempDir
              .listSync()
              .where((e) => _basenameOf(e.path).contains('.corrupt-')),
          hasLength(1));
    });

    test('a double version equal to the store version still quarantines',
        () async {
      // JSON 1.0 decodes as a double; numeric equality with 1 must not
      // adopt the foreign document as v1.
      File(path).writeAsStringSync(
          '{"version":1.0,"highWaterSeq":0,"lastAppliedSeq":0,'
          '"records":[]}');
      final errors = <Object>[];
      final store =
          open(now: () => _fixedNow, onError: (error, _) => errors.add(error));
      expect(await store.allRecords(), isEmpty);
      expect(errors, hasLength(1));
      expect(
          tempDir
              .listSync()
              .where((e) => _basenameOf(e.path).contains('.corrupt-')),
          hasLength(1));
    });

    test('a non-int watermark field is quarantined, not cast', () async {
      File(path).writeAsStringSync(
          '{"version":1,"highWaterSeq":"oops","lastAppliedSeq":0,'
          '"records":[]}');
      final errors = <Object>[];
      final store =
          open(now: () => _fixedNow, onError: (error, _) => errors.add(error));
      expect(await store.allRecords(), isEmpty);
      expect(await store.highWaterSeq(), 0);
      expect(errors, hasLength(1));
      expect(
          tempDir
              .listSync()
              .where((e) => _basenameOf(e.path).contains('.corrupt-')),
          hasLength(1));
    });

    test('a newer document version fails closed without quarantining',
        () async {
      File(path).writeAsStringSync(
          '{"version":2,"highWaterSeq":0,"lastAppliedSeq":0,"records":[]}');
      final store = open(now: () => _fixedNow);
      await expectLater(store.allRecords(), throwsFormatException);
      // The unreadable newer file stays put rather than being moved aside.
      expect(File(path).readAsStringSync(), contains('"version":2'));
    });
  });

  group('account scope', () {
    test('a missing scoped store is bound eagerly', () async {
      final store = open(scope: alice);
      await store.initialize();

      final doc = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(doc['version'], 2);
      expect(doc['account'], {
        'baseUrl': 'https://sync.example',
        'username': 'alice',
      });
      expect(doc['records'], isEmpty);
    });

    test('adopts a legacy store once and preserves all durable state',
        () async {
      final legacy = open();
      await legacy.putRemote(
        _record('bookmark:a', updatedAt: 200, seq: 5, blob: [8, 9]),
      );
      await legacy.putLocal(
        _record('bookmark:a', updatedAt: 100, blob: [1, 2]),
      );
      await legacy.setHighWaterSeq(12);
      await legacy.setLastAppliedSeq(11);

      final scoped = open(scope: alice, adoptLegacy: true);
      await scoped.initialize();

      expect(await scoped.highWaterSeq(), 12);
      expect(await scoped.lastAppliedSeq(), 11);
      expect((await scoped.dirtyRecords()).single.blob, [1, 2]);
      expect((await scoped.displacedRecords()).single.blob, [8, 9]);
      final doc = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(doc['version'], 2);
      expect(doc['account'], {
        'baseUrl': 'https://sync.example',
        'username': 'alice',
      });

      final reopened = open(scope: alice);
      expect(await reopened.highWaterSeq(), 12);
      expect(await reopened.lastAppliedSeq(), 11);
      expect((await reopened.dirtyRecords()).single.blob, [1, 2]);
      expect((await reopened.displacedRecords()).single.blob, [8, 9]);
    });

    test('does not assign an unclaimed legacy store to an account', () async {
      final legacy = open();
      await legacy.putLocal(_record('bookmark:a'));
      await legacy.setHighWaterSeq(9);

      final scoped = open(scope: alice);
      await scoped.initialize();

      expect(await scoped.allRecords(), isEmpty);
      expect(await scoped.highWaterSeq(), 0);
      expect(await scoped.lastAppliedSeq(), 0);
      final doc = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(doc['version'], 2);
      expect(doc['account'], {
        'baseUrl': 'https://sync.example',
        'username': 'alice',
      });
    });

    test('endpoint or username changes reset records and both cursors',
        () async {
      final first = open(scope: alice);
      await first.putLocal(_record('bookmark:a'));
      await first.setHighWaterSeq(9);
      await first.setLastAppliedSeq(8);

      final endpointChanged = open(
        scope: SyncAccountScope(
          baseUrl: 'https://other.example',
          username: 'alice',
        ),
      );
      await endpointChanged.initialize();
      expect(await endpointChanged.allRecords(), isEmpty);
      expect(await endpointChanged.highWaterSeq(), 0);
      expect(await endpointChanged.lastAppliedSeq(), 0);

      await endpointChanged.putLocal(_record('bookmark:b'));
      await endpointChanged.setHighWaterSeq(4);
      final usernameChanged = open(
        scope: SyncAccountScope(
          baseUrl: 'https://other.example',
          username: 'bob',
        ),
      );
      await usernameChanged.initialize();
      expect(await usernameChanged.allRecords(), isEmpty);
      expect(await usernameChanged.highWaterSeq(), 0);
    });

    test('resetExisting clears a recreated account with the same name',
        () async {
      final first = open(scope: alice);
      await first.putLocal(_record('bookmark:a'));
      await first.setHighWaterSeq(9);
      await first.recoverFromRejectedCursor();
      expect(await first.cursorRecoveryPending(), isTrue);

      final recreated = open(scope: alice, resetExisting: true);
      await recreated.initialize();

      expect(await recreated.allRecords(), isEmpty);
      expect(await recreated.dirtyRecords(), isEmpty);
      expect(await recreated.highWaterSeq(), 0);
      expect(await recreated.lastAppliedSeq(), 0);
      expect(await recreated.cursorRecoveryPending(), isFalse);
    });

    test('malformed scoped account is quarantined and rebound', () async {
      File(path).writeAsStringSync(
        '{"version":2,"account":{"baseUrl":7,"username":"alice"},'
        '"highWaterSeq":0,"lastAppliedSeq":0,"records":[]}',
      );
      final errors = <Object>[];
      final store = open(
        scope: alice,
        now: () => _fixedNow,
        onError: (error, _) => errors.add(error),
      );

      await store.initialize();

      expect(errors, hasLength(1));
      expect(store.quarantinedPath, isNotNull);
      expect(await store.allRecords(), isEmpty);
      final doc = jsonDecode(File(path).readAsStringSync()) as Map;
      expect(doc['version'], 2);
      expect(doc['account'], {
        'baseUrl': 'https://sync.example',
        'username': 'alice',
      });
    });

    test('future scoped versions fail closed in place', () async {
      File(path).writeAsStringSync(
        '{"version":3,"account":{"baseUrl":"https://sync.example",'
        '"username":"alice"},"highWaterSeq":0,"lastAppliedSeq":0,'
        '"records":[]}',
      );
      final store = open(scope: alice, resetExisting: true);

      await expectLater(store.initialize(), throwsFormatException);
      expect(File(path).readAsStringSync(), contains('"version":3'));
      expect(
        tempDir
            .listSync()
            .where((e) => _basenameOf(e.path).contains('.corrupt-')),
        isEmpty,
      );
    });

    test('an unscoped consumer cannot open a scoped document', () async {
      await open(scope: alice).initialize();

      await expectLater(open().allRecords(), throwsFormatException);
      expect(File(path).readAsStringSync(), contains('"version":2'));
    });
  });
}
