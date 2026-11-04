import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/catalog/atomic_file_writer.dart';
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

/// A fault-injecting stand-in around the real atomic writer: records
/// every document handed to it and deterministically fails the next
/// write after [failNext] is set.
final class _FaultInjectingWriter {
  final List<String> requested = [];
  bool failNext = false;
  bool failAfterWriteNext = false;

  Future<void> call(File target, String contents) async {
    requested.add(contents);
    if (failNext) {
      failNext = false;
      throw const FileSystemException('injected write failure');
    }
    await const AtomicFileWriter().write(target, contents);
    if (failAfterWriteNext) {
      failAfterWriteNext = false;
      throw const FileSystemException('injected post-rename failure');
    }
  }
}

/// A record whose serialization throws: the deterministic way to make
/// the write path itself fail between the edit and the state swap.
final class _PoisonedRecord extends EncryptedRecord {
  _PoisonedRecord(String id)
      : super(
          id: id,
          updatedAt: 50,
          deviceId: 'device-a',
          deleted: false,
          seq: null,
          blob: Uint8List.fromList(const [1, 2, 3]),
        );

  @override
  Map<String, dynamic> toJson() => throw StateError('poisoned');
}

/// The five live state components read through the store's public
/// reads. `EncryptedRecord` has no `==`, so record lists compare by
/// instance identity — exactly what "unchanged" must mean after a
/// failed write.
final class _LiveState {
  _LiveState({
    required this.records,
    required this.dirty,
    required this.displaced,
    required this.highWater,
    required this.lastApplied,
  });

  final List<EncryptedRecord> records;
  final List<EncryptedRecord> dirty;
  final List<EncryptedRecord> displaced;
  final int highWater;
  final int lastApplied;
}

Future<_LiveState> _liveStateOf(SyncRecordStore store) async => _LiveState(
      records: await store.allRecords(),
      dirty: await store.dirtyRecords(),
      displaced: await store.displacedRecords(),
      highWater: await store.highWaterSeq(),
      lastApplied: await store.lastAppliedSeq(),
    );

void _expectUnchanged(_LiveState actual, _LiveState expected) {
  expect(actual.records, equals(expected.records));
  expect(actual.dirty, equals(expected.dirty));
  expect(actual.displaced, equals(expected.displaced));
  expect(actual.highWater, expected.highWater);
  expect(actual.lastApplied, expected.lastApplied);
}

String _diskDoc(String path) => File(path).readAsStringSync();

List<String> _siblings(Directory dir) =>
    dir.listSync().map((entity) => _basenameOf(entity.path)).toList()..sort();

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
    DateTime Function()? now,
    void Function(Object, StackTrace)? onError,
    Future<void> Function(File target, String contents)? atomicWriter,
  }) =>
      PersistentLocalRecordStore(
        path: path,
        now: now,
        onError: onError,
        atomicWriter: atomicWriter,
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

  group('failed writes leave live state and disk untouched', () {
    // Every mutation kind must edit candidate state only: a failed
    // atomic write can leave neither the five live components mutated
    // in memory nor any trace in a later successful write or a reopen.
    test('a failed putLocal changes neither memory nor disk', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));
      await store.setHighWaterSeq(7);
      await store.setLastAppliedSeq(7);

      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);
      writer.failNext = true;
      await expectLater(
        store.putLocal(_record('bookmark:a', updatedAt: 50)),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);
      expect(_siblings(tempDir), ['sync_records.json']);

      // Nothing from the failed edit rides the next successful write.
      await store.putLocal(_record('bookmark:z', updatedAt: 80));
      final reloaded = open();
      expect((await reloaded.allRecords()).map((r) => r.id).toList(),
          ['bookmark:b', 'bookmark:z']);
      expect(
          (await reloaded.dirtyRecords()).map((r) => r.id), ['bookmark:z']);
      expect(await reloaded.highWaterSeq(), 7);
      expect(await reloaded.lastAppliedSeq(), 7);
    });

    test('a failed putRemote parks no displaced loser', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putLocal(_record('bookmark:a', updatedAt: 30));
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.putRemote(_record('bookmark:a', updatedAt: 20, seq: 4)),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      // A loser stashed only in memory must not ride along with a later
      // successful write and resurrect as a durable displaced entry.
      await store.setHighWaterSeq(4);
      final reloaded = open();
      expect(await reloaded.displacedRecords(), isEmpty);
      expect((await reloaded.dirtyRecords()).single.updatedAt, 30);
      expect(await reloaded.highWaterSeq(), 4);
    });

    test('a failed putRemote replaces nothing when the pull would win',
        () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.putRemote(_record('bookmark:a', updatedAt: 300, seq: 6)),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      // The losing edit stays put: still dirty, stash still parked.
      await store.putLocal(_record('bookmark:z', updatedAt: 80));
      final reloaded = open();
      final reloadedA = await reloaded.getRecord('bookmark:a');
      expect(reloadedA!.updatedAt, 100);
      expect(reloadedA.seq, isNull);
      expect((await reloaded.dirtyRecords()).map((r) => r.id).toList(),
          ['bookmark:a', 'bookmark:z']);
      expect((await reloaded.displacedRecords()).single.updatedAt, 200);
    });

    test('a failed markSynced keeps the edit dirty and the stash parked',
        () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.markSynced('bookmark:a', 9),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      await store.putLocal(_record('bookmark:z', updatedAt: 80));
      final reloaded = open();
      expect((await reloaded.getRecord('bookmark:a'))!.seq, isNull);
      expect((await reloaded.dirtyRecords()).map((r) => r.id).toList(),
          ['bookmark:a', 'bookmark:z']);
      expect((await reloaded.displacedRecords()).single.updatedAt, 200);
    });

    test('a failed settlePush of an accepted result settles nothing', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      final sent = (await store.dirtyRecords()).single;
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.settlePush(
          sent,
          const PushResult(id: 'bookmark:a', seq: 9, accepted: true),
        ),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      await store.putLocal(_record('bookmark:z', updatedAt: 80));
      final reloaded = open();
      expect((await reloaded.getRecord('bookmark:a'))!.seq, isNull);
      expect((await reloaded.dirtyRecords()).map((r) => r.id).toList(),
          ['bookmark:a', 'bookmark:z']);
      expect((await reloaded.displacedRecords()).single.updatedAt, 200);
    });

    test('a failed settlePush of a rejection restores nothing', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:a', updatedAt: 200, seq: 5));
      await store.putLocal(_record('bookmark:a', updatedAt: 100));
      final sent = (await store.dirtyRecords()).single;
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.settlePush(
          sent,
          const PushResult(id: 'bookmark:a', seq: 0, accepted: false),
        ),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      await store.putLocal(_record('bookmark:z', updatedAt: 80));
      final reloaded = open();
      expect((await reloaded.getRecord('bookmark:a'))!.updatedAt, 100);
      expect((await reloaded.dirtyRecords()).map((r) => r.id).toList(),
          ['bookmark:a', 'bookmark:z']);
      expect((await reloaded.displacedRecords()).single.updatedAt, 200);
    });

    test('a failed setHighWaterSeq does not advance the cursor', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));
      await store.setHighWaterSeq(7);
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.setHighWaterSeq(12),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      // A cursor that advanced only in memory would let the next
      // successful write persist a skip point past unread records.
      await store.putLocal(_record('bookmark:z'));
      final reloaded = open();
      expect(await reloaded.highWaterSeq(), 7);
      expect((await reloaded.allRecords()).map((r) => r.id).toList(),
          ['bookmark:b', 'bookmark:z']);
    });

    test('a failed setLastAppliedSeq does not advance the cursor', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));
      await store.setLastAppliedSeq(7);
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.setLastAppliedSeq(12),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      await store.putLocal(_record('bookmark:z'));
      final reloaded = open();
      expect(await reloaded.lastAppliedSeq(), 7);
      expect(
          (await reloaded.dirtyRecords()).map((r) => r.id), ['bookmark:z']);
    });

    test('a failed resetSyncCursors keeps both cursors', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.setHighWaterSeq(7);
      await store.setLastAppliedSeq(6);
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      writer.failNext = true;
      await expectLater(
        store.resetSyncCursors(),
        throwsA(isA<FileSystemException>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      // A reset that landed only in memory would zero the cursors on
      // the next successful write and force a spurious full resync.
      await store.putLocal(_record('bookmark:z'));
      final reloaded = open();
      expect(await reloaded.highWaterSeq(), 7);
      expect(await reloaded.lastAppliedSeq(), 6);
    });

    test('a write queued behind a failed one starts from clean state',
        () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));

      writer.failNext = true;
      final failed = store.putLocal(_record('bookmark:a', updatedAt: 50));
      final queued = store.putLocal(_record('bookmark:z', updatedAt: 80));
      await expectLater(failed, throwsA(isA<FileSystemException>()));
      await queued;

      expect((await store.allRecords()).map((r) => r.id).toList(),
          ['bookmark:b', 'bookmark:z']);
      expect(
          (await store.dirtyRecords()).map((r) => r.id), ['bookmark:z']);
      expect(_siblings(tempDir), ['sync_records.json']);

      final reloaded = open();
      expect((await reloaded.allRecords()).map((r) => r.id).toList(),
          ['bookmark:b', 'bookmark:z']);
      expect(
          (await reloaded.dirtyRecords()).map((r) => r.id), ['bookmark:z']);
    });

    test('a record whose serialization throws is discarded whole', () async {
      final writer = _FaultInjectingWriter();
      final store = open(atomicWriter: writer.call);
      await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));
      final before = await _liveStateOf(store);
      final bytes = _diskDoc(path);

      await expectLater(
        store.putLocal(_PoisonedRecord('bookmark:a')),
        throwsA(isA<StateError>()),
      );
      _expectUnchanged(await _liveStateOf(store), before);
      expect(_diskDoc(path), bytes);

      // The serializer walks every stored record, so discarding the
      // candidate whole is what keeps later writes alive at all.
      await store.putLocal(_record('bookmark:z', updatedAt: 80));
      final reloaded = open();
      expect((await reloaded.allRecords()).map((r) => r.id).toList(),
          ['bookmark:b', 'bookmark:z']);
    });
  });

  test('a post-rename failure reconciles the committed document', () async {
    final writer = _FaultInjectingWriter();
    final store = open(atomicWriter: writer.call);
    await store.putRemote(_record('bookmark:b', updatedAt: 60, seq: 7));

    writer.failAfterWriteNext = true;
    await expectLater(
      store.putLocal(_record('bookmark:a', updatedAt: 50)),
      throwsA(isA<FileSystemException>()),
    );

    // AtomicFileWriter can report a directory-sync failure after rename.
    // The live instance must reload that already-committed candidate before
    // another mutation can overwrite it from stale memory.
    expect((await store.allRecords()).map((r) => r.id).toList(),
        ['bookmark:b', 'bookmark:a']);
    await store.putLocal(_record('bookmark:z', updatedAt: 80));

    final reloaded = open();
    expect((await reloaded.allRecords()).map((r) => r.id).toList(),
        ['bookmark:b', 'bookmark:a', 'bookmark:z']);
    expect((await reloaded.dirtyRecords()).map((r) => r.id).toList(),
        ['bookmark:a', 'bookmark:z']);
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
      final restored = await reloaded.settlePush(sent, rejected);
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
      final restored = await reloaded.settlePush(sent, rejected);
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
      final restored = await store.settlePush(local, rejected);
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
}
