// Byte goldens for the two sync documents whose writer changes hands in
// the catalog move (docs/design/catalog-library.md sections 11 and 14):
// `servers.json` from FileServerConfigStore and `sync_records.json` from
// PersistentLocalRecordStore, built from fixed inputs (clock, device id,
// records) through the stores' default writer and compared byte for byte
// with store_goldens.dart.
//
// The goldens were captured from the pre-move writer. Change them only for
// an intentional format change, from the actual document a failure prints.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'store_goldens.dart';

const _deviceId = 'device-golden';
const _peerDeviceId = 'device-peer';
final _now = DateTime.utc(2026, 10, 13, 12);
final _nowMs = _now.millisecondsSinceEpoch;

/// Compares the file's exact bytes: the goldens are ASCII, so reading each
/// byte as one code unit keeps a mismatch readable without decoding.
Future<void> _expectGolden(String actualPath, String golden) async {
  final actual = await File(actualPath).readAsBytes();

  expect(String.fromCharCodes(actual), golden);
}

EncryptedRecord _record(
  String id, {
  required int updatedAt,
  String deviceId = _deviceId,
  int? seq,
  List<int> blob = const [1, 2, 3],
}) => EncryptedRecord(
  id: id,
  updatedAt: updatedAt,
  deviceId: deviceId,
  deleted: false,
  seq: seq,
  blob: Uint8List.fromList(blob),
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('catalog-golden');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  String pathIn(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test(
    'servers.json bytes: rows, tuples, a tombstone and preserved rows',
    () async {
      final path = pathIn('servers.json');
      // Two rows this build cannot decode: they must ride every write
      // verbatim, after the decoded rows.
      await File(path).writeAsString(
        jsonEncode({
          'version': 1,
          'servers': [
            {
              'label': 'no id',
              'futureField': [1, 2],
            },
            'opaque-row',
          ],
        }),
      );
      final store = FileServerConfigStore(
        path: path,
        now: () => _now,
        syncDeviceId: () => _deviceId,
      );

      await store.save(
        ServerConfig(
          id: 'srv-alpha',
          label: 'alpha',
          host: 'alpha.example.com',
          username: 'root',
          group: 'Production',
          color: ServerColor.blue,
          icon: ServerIcon.database,
          startDirectory: '/srv/app',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await store.save(
        ServerConfig(
          id: 'srv-beta',
          label: 'Beta',
          host: 'beta.example.com',
          port: 2222,
          username: 'deploy',
          authMethod: AuthMethod.password,
          secretRef: 'secret-beta',
          syncSecret: true,
          jumpHostId: 'srv-alpha',
          createdAt: 2,
          updatedAt: 2,
        ),
      );
      await store.save(
        ServerConfig(
          id: 'srv-doomed',
          label: 'doomed',
          host: 'doomed.example.com',
          username: 'ops',
          createdAt: 3,
          updatedAt: 3,
        ),
      );
      // A local delete leaves a tombstone tuple behind the dropped row.
      expect(await store.remove('srv-doomed'), isTrue);
      // A pulled peer winner keeps its own stamps and the envelope tuple.
      await store.applySyncedRecord(
        ServerConfig(
          id: 'srv-gamma',
          label: 'Gamma',
          host: 'gamma.example.com',
          username: 'peer',
          excludeFromSync: false,
          createdAt: 4,
          updatedAt: _nowMs - 5000,
        ),
        ServerSyncTuple(updatedAt: _nowMs - 5000, deviceId: _peerDeviceId),
      );
      // A pulled tombstone for a row this device never held.
      await store.removeSyncedRecord(
        'srv-remote-gone',
        ServerSyncTuple(
          updatedAt: _nowMs - 4000,
          deviceId: _peerDeviceId,
          deleted: true,
        ),
      );

      await _expectGolden(path, serversGolden);
    },
  );

  test('servers.json bytes: no sync device keeps the clean shape', () async {
    final path = pathIn('servers.json');
    final store = FileServerConfigStore(path: path, now: () => _now);

    await store.save(
      ServerConfig(
        id: 'srv-local',
        label: 'local only',
        host: 'local.example.com',
        username: 'me',
        createdAt: 1,
        updatedAt: 1,
      ),
    );

    await _expectGolden(path, serversUnsyncedGolden);
  });

  test('sync_records.json bytes: cursors, dirty rows, tombstones and a '
      'displaced winner', () async {
    final path = pathIn('sync_records.json');
    final store = PersistentLocalRecordStore(path: path, now: () => _now);

    // Clean pulled rows, one of them a tombstone.
    await store.putRemote(
      _record('srv-alpha', updatedAt: 1000, deviceId: _peerDeviceId, seq: 7),
    );
    await store.putRemote(
      EncryptedRecord(
        id: 'srv-gone',
        updatedAt: 1100,
        deviceId: _peerDeviceId,
        deleted: true,
        seq: 8,
        blob: Uint8List(0),
      ),
    );
    await store.setHighWaterSeq(9);
    await store.setLastAppliedSeq(8);

    // Dirty local rows: a live record and a tombstone.
    await store.putLocal(_record('bookmark:bm-1', updatedAt: 1200));
    await store.putLocal(
      EncryptedRecord.tombstone(
        id: 'hostkey:alpha.example.com:22',
        updatedAt: 1300,
        deviceId: _deviceId,
      ),
    );

    // A clean pulled winner a losing local edit displaces.
    await store.putRemote(
      _record(
        'bookmark:bm-2',
        updatedAt: 2000,
        deviceId: _peerDeviceId,
        seq: 9,
        blob: const [4, 5, 6],
      ),
    );
    await store.putLocal(
      _record('bookmark:bm-2', updatedAt: 1500, blob: const [7, 8, 9]),
    );

    // A local edit the server accepted: seq stamped, no longer dirty.
    await store.putLocal(_record('secret:s-1', updatedAt: 1400));
    await store.markSynced('secret:s-1', 10);

    await _expectGolden(path, syncRecordsGolden);
  });
}
