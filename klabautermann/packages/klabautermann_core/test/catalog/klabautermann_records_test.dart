// The `klabautermann:` records on the shared coordinator (03 §4.8, M5
// plan M04): every rule of 4.8, the forged-tombstone case X3 names, the
// caps and the prefix budget.
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/klabautermann_records.dart';
import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

final _key = List<int>.unmodifiable(List<int>.generate(32, (i) => i));
const _ruleId = '0b7e4c3a-5d1f-4e2a-9c8b-7a6f5e4d3c2b';

ServerConfig _server(String id, {bool excluded = false}) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example.com',
  username: 'deploy',
  excludeFromSync: excluded,
  createdAt: 1,
  updatedAt: 1,
);

const _prefs = ServerPrefs(
  readOnly: true,
  cadence: CadenceProfile.phone,
  pinnedUnits: ['nginx.service'],
  pinnedContainers: ['web'],
  marks: {'postgresql.service'},
  panelOrder: ['docker', 'overview'],
  hostAuditLine: false,
  stackScanDirs: ['/srv/stacks'],
);

const _rule = SyncedRule(
  id: _ruleId,
  rule: ThresholdRule(
    metric: 'cpu.busy',
    scope: RuleScope.server,
    op: ThresholdOp.greaterThan,
    raise: ThresholdBound(value: 90, duration: Duration(minutes: 5)),
    clear: ThresholdBound(value: 70, duration: Duration(minutes: 2)),
    evalScope: RuleEvalScope.client,
  ),
  target: 'srv-a',
);

/// One device's stores and a coordinator with the handler, fed pulled
/// records directly.
final class _Device {
  _Device._(this.dir, this.records, this.servers, this.store, this.tripwires);

  static Future<_Device> create(
    Directory dir, {
    PushPolicy pushPolicy = PushPolicy.none,
  }) async {
    final device = _Device._(
      dir,
      PersistentLocalRecordStore(path: '${dir.path}/sync_records.json'),
      FileServerConfigStore(
        path: '${dir.path}/servers.json',
        syncDeviceId: () => 'device-a',
      ),
      await KlabautermannRecordStore.open(
        dir,
        access: SupportDirectoryAccess.exclusive,
      ),
      InMemorySyncTripwireStore(),
    );
    device.coordinator = RecordCoordinator(
      records: device.records,
      handlers: [
        KlabautermannRecordHandler(
          store: device.store,
          servers: device.servers,
        ),
      ],
      hostKeys: InMemoryConflictAwareHostKeyStore(),
      hostKeyMutations: HostKeyMutationGate(),
      crypto: _crypto,
      deviceId: 'device-a',
      pinVerdicts: InMemoryPinVerdictStore(),
      tripwires: device.tripwires,
      catalogMode: CatalogMode.shared,
      pushPolicy: pushPolicy,
      servers: device.servers,
    );
    return device;
  }

  static final _crypto = RecordCrypto(RecordCodec(_key));

  final Directory dir;
  final PersistentLocalRecordStore records;
  final FileServerConfigStore servers;
  final KlabautermannRecordStore store;
  final InMemorySyncTripwireStore tripwires;
  late final RecordCoordinator coordinator;
  var _seq = 0;

  /// Stores [data] as pulled under [id], sealed as [kind], and applies the
  /// pass.
  Future<ApplyReport> pull(
    String id,
    Map<String, Object?> data, {
    int updatedAt = 10,
    RecordKind kind = RecordKind.klabautermann,
  }) async {
    final sealed = await _crypto.seal(
      DecryptedRecord(
        id: id,
        kind: kind,
        updatedAt: updatedAt,
        deviceId: 'device-b',
        data: data,
      ),
    );
    await records.putRemote(sealed.withSeq(++_seq));
    return coordinator.applyPulled();
  }

  /// Stores an unsealed tombstone of [id] as pulled and applies the pass.
  Future<ApplyReport> pullTombstone(String id, {int updatedAt = 20}) async {
    await records.putRemote(
      EncryptedRecord(
        id: id,
        updatedAt: updatedAt,
        deviceId: 'forger',
        deleted: true,
        seq: ++_seq,
        blob: Uint8List(0),
      ),
    );
    return coordinator.applyPulled();
  }

  Future<ApplyReport> pullServer(ServerConfig server) async {
    final sealed = await _crypto.seal(
      DecryptedRecord(
        id: server.id,
        kind: RecordKind.serverConfig,
        updatedAt: 1,
        deviceId: 'device-b',
        data: server.toJson(),
      ),
    );
    await records.putRemote(sealed.withSeq(++_seq));
    return coordinator.applyPulled();
  }
}

void main() {
  late Directory dir;
  late _Device device;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('klab-records-');
    device = await _Device.create(dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final prefId = KlabautermannRecordType.pref.idOf('srv-a');
  final ruleId = KlabautermannRecordType.rule.idOf(_ruleId);

  group('codecs', () {
    test('a pref and a rule read back as they were sealed', () {
      final prefs = decodeServerPrefs(encodeServerPrefs('srv-a', _prefs));
      expect(
        [
          prefs.readOnly,
          prefs.cadence,
          prefs.pinnedUnits,
          prefs.pinnedContainers,
          prefs.marks,
          prefs.panelOrder,
          prefs.hostAuditLine,
          prefs.stackScanDirs,
        ],
        [
          true,
          CadenceProfile.phone,
          ['nginx.service'],
          ['web'],
          {'postgresql.service'},
          ['docker', 'overview'],
          false,
          ['/srv/stacks'],
        ],
      );

      final rule = decodeSyncedRule(encodeSyncedRule(_rule));
      expect(rule.id, _ruleId);
      expect(rule.target, 'srv-a');
      expect(rule.rule.toJson(), _rule.rule.toJson());
    });

    test('absent pref fields take their defaults, and a cadence preset '
        'this build does not know leaves the device\'s', () {
      final prefs = decodeServerPrefs({
        'type': 'pref',
        'v': 1,
        'id': prefId,
        'cadence': 'everySecond',
      });
      expect(prefs.readOnly, isFalse);
      expect(prefs.hostAuditLine, isTrue);
      expect(prefs.cadence, isNull);
      expect(prefs.marks, isEmpty);
    });

    test('mistyped fields and relative scan directories are refused', () {
      for (final bad in <Map<String, Object?>>[
        {'readOnly': 'yes'},
        {'protectedTargets': 'nginx'},
        {
          'pinnedUnits': [1],
        },
        {
          'stackScanDirs': ['srv/stacks'],
        },
        {'cadence': 2},
      ]) {
        expect(
          () => decodeServerPrefs(bad),
          throwsFormatException,
          reason: '$bad',
        );
      }
      final rule = encodeSyncedRule(_rule)..['op'] = 'between';
      expect(() => decodeSyncedRule(rule), throwsFormatException);
    });
  });

  group('apply (03 §4.8)', () {
    test('a pref and a rule apply under their envelope ids', () async {
      await device.pullServer(_server('srv-a'));
      final prefReport = await device.pull(
        prefId,
        encodeServerPrefs('srv-a', _prefs),
      );
      final ruleReport = await device.pull(ruleId, encodeSyncedRule(_rule));

      expect(prefReport.appliedIds, contains(prefId));
      expect(ruleReport.appliedIds, contains(ruleId));
      expect(device.store.prefs()['srv-a']?.marks, {'postgresql.service'});
      expect([for (final r in device.store.rules()) r.id], [_ruleId]);
      expect(await device.tripwires.trippedIds(), isEmpty);
    });

    test('a payload whose id or type is not its envelope\'s trips and is '
        'not applied', () async {
      final otherServer = encodeServerPrefs('srv-b', _prefs);
      final otherType = encodeServerPrefs('srv-a', _prefs)..['type'] = 'rule';
      await device.pull(prefId, otherServer);
      await device.pull(ruleId, otherType..['id'] = ruleId);

      expect(device.store.prefs(), isEmpty);
      expect(device.store.rules(), isEmpty);
      expect(await device.tripwires.trippedIds(), {prefId, ruleId});
    });

    test('a record sealed as another kind trips', () async {
      await device.pull(
        prefId,
        encodeServerPrefs('srv-a', _prefs),
        kind: RecordKind.bookmark,
      );
      expect(device.store.prefs(), isEmpty);
      expect(await device.tripwires.trippedIds(), {prefId});
    });

    test('a malformed field trips, and a later good record lifts it', () async {
      await device.pull(
        prefId,
        encodeServerPrefs('srv-a', _prefs)..['readOnly'] = 'yes',
      );
      expect(await device.tripwires.trippedIds(), {prefId});

      await device.pull(
        prefId,
        encodeServerPrefs('srv-a', _prefs),
        updatedAt: 11,
      );
      expect(await device.tripwires.trippedIds(), isEmpty);
      expect(device.store.isLive(prefId), isTrue);
    });

    test('a forged unsealed tombstone leaves a pref and a rule (X3)', () async {
      await device.pullServer(_server('srv-a'));
      await device.pull(prefId, encodeServerPrefs('srv-a', _prefs));
      await device.pull(ruleId, encodeSyncedRule(_rule));

      await device.pullTombstone(prefId);
      await device.pullTombstone(ruleId);

      expect(device.store.prefs()['srv-a']?.readOnly, isTrue);
      expect([for (final r in device.store.rules()) r.id], [_ruleId]);
    });

    test('a sealed removal drops a pref and a rule, and an older live '
        'record does not bring them back', () async {
      await device.pull(prefId, encodeServerPrefs('srv-a', _prefs));
      await device.pull(ruleId, encodeSyncedRule(_rule));

      await device.pull(prefId, removedPayload(prefId), updatedAt: 20);
      await device.pull(ruleId, removedPayload(ruleId), updatedAt: 20);
      expect(device.store.prefs(), isEmpty);
      expect(device.store.rules(), isEmpty);

      await device.pull(
        prefId,
        encodeServerPrefs('srv-a', _prefs),
        updatedAt: 15,
      );
      expect(device.store.prefs(), isEmpty);
      expect(device.store.tupleOf(prefId)?.updatedAt, 20);
    });

    test('an unknown type and a newer version are kept verbatim and '
        'skipped', () async {
      const queryId = 'klabautermann:query:7d1c';
      final query = {'type': 'query', 'v': 1, 'id': queryId, 'name': 'oom'};
      final newerPref = {
        ...encodeServerPrefs('srv-a', _prefs),
        'v': 2,
        'readOnly': 'by schedule',
      };
      final first = await device.pull(queryId, query);
      final second = await device.pull(prefId, newerPref);

      expect(first.appliedIds, isEmpty);
      expect(second.appliedIds, isEmpty);
      expect(await device.tripwires.trippedIds(), isEmpty);
      expect(device.store.sealable(queryId)?.data, query);
      expect(device.store.sealable(prefId)?.data, newerPref);
      // A newer version's preferences are not read by this build.
      expect(device.store.prefs(), isEmpty);
    });

    test('a pref of an excluded server is skipped, and one whose server '
        'is absent stays pending', () async {
      await device.pullServer(_server('srv-x', excluded: true));
      final excludedId = KlabautermannRecordType.pref.idOf('srv-x');
      final absentId = KlabautermannRecordType.pref.idOf('srv-later');

      await device.pull(excludedId, encodeServerPrefs('srv-x', _prefs));
      await device.pull(absentId, encodeServerPrefs('srv-later', _prefs));

      expect(device.store.isLive(excludedId), isFalse);
      expect(device.store.prefs().keys, ['srv-later']);
    });

    test('a sealed removal of an excluded server\'s pref still lands, so '
        'no stale pref is re-sealed after store loss', () async {
      final excludedId = KlabautermannRecordType.pref.idOf('srv-x');
      // Stored while its server is unknown, then the server arrives
      // excluded and the account retracts the pref.
      await device.pull(excludedId, encodeServerPrefs('srv-x', _prefs));
      expect(device.store.isLive(excludedId), isTrue);
      await device.pullServer(_server('srv-x', excluded: true));

      await device.pull(excludedId, removedPayload(excludedId), updatedAt: 20);
      expect(device.store.isLive(excludedId), isFalse);
      expect(device.store.tupleOf(excludedId)?.updatedAt, 20);
    });

    test('a newer version is still held to its type\'s caps, and a version '
        'below 1 trips', () async {
      final big = ServerPrefs(
        pinnedUnits: [for (var i = 0; i < 600; i++) 'unit-$i.service'],
      );
      await device.pull(prefId, {...encodeServerPrefs('srv-a', big), 'v': 2});
      expect(device.store.sealable(prefId), isNull);
      expect(await device.tripwires.trippedIds(), {prefId});

      await device.pull(ruleId, {...encodeSyncedRule(_rule), 'v': 0});
      expect(device.store.sealable(ruleId), isNull);
      expect(await device.tripwires.trippedIds(), {prefId, ruleId});
    });

    test(
      'materialized records survive a restart, so the tuple guard holds',
      () async {
        await device.pull(prefId, encodeServerPrefs('srv-a', _prefs));
        final reopened = await KlabautermannRecordStore.open(
          dir,
          access: SupportDirectoryAccess.exclusive,
        );
        expect(reopened.issue, isNull);
        expect(reopened.tupleOf(prefId)?.updatedAt, 10);
        expect(reopened.prefs()['srv-a']?.panelOrder, ['docker', 'overview']);
      },
    );
  });

  group('caps (03 §4.8)', () {
    test('a pref over 8 KiB is refused with a tripwire', () async {
      final big = ServerPrefs(
        pinnedUnits: [for (var i = 0; i < 600; i++) 'unit-$i.service'],
      );
      await device.pull(prefId, encodeServerPrefs('srv-a', big));
      expect(device.store.isLive(prefId), isFalse);
      expect(await device.tripwires.trippedIds(), {prefId});
    });

    test('the 201st rule is refused with a tripwire; a rule already held '
        'still updates', () async {
      String uuid(int i) =>
          '00000000-0000-4000-8000-${i.toRadixString(16).padLeft(12, '0')}';
      for (var i = 0; i < 200; i++) {
        final rule = SyncedRule(id: uuid(i), rule: _rule.rule);
        await device.records.putRemote(
          (await _Device._crypto.seal(
            DecryptedRecord(
              id: KlabautermannRecordType.rule.idOf(uuid(i)),
              kind: RecordKind.klabautermann,
              updatedAt: 10,
              deviceId: 'device-b',
              data: encodeSyncedRule(rule),
            ),
          )).withSeq(++device._seq),
        );
      }
      await device.coordinator.applyPulled();
      expect(device.store.liveCount(KlabautermannRecordType.rule), 200);

      final extra = KlabautermannRecordType.rule.idOf(uuid(200));
      await device.pull(
        extra,
        encodeSyncedRule(SyncedRule(id: uuid(200), rule: _rule.rule)),
      );
      expect(device.store.isLive(extra), isFalse);
      expect(await device.tripwires.trippedIds(), {extra});

      final held = KlabautermannRecordType.rule.idOf(uuid(0));
      final update = await device.pull(
        held,
        encodeSyncedRule(SyncedRule(id: uuid(0), rule: _rule.rule)),
        updatedAt: 11,
      );
      expect(update.appliedIds, contains(held));
    });

    test('the prefix budget warns from 80 % of 1 MiB', () {
      EncryptedRecord record(String id, int bytes, {bool deleted = false}) =>
          EncryptedRecord(
            id: id,
            updatedAt: 1,
            deviceId: 'd',
            deleted: deleted,
            seq: 1,
            blob: Uint8List(bytes),
          );
      final under = prefixBudgetOf([
        record('klabautermann:pref:a', 800 * 1024),
        record('bookmark:x', 200 * 1024),
        record('klabautermann:pref:b', 100 * 1024, deleted: true),
      ]);
      expect((under.usedBytes, under.warns), (800 * 1024, false));

      final over = prefixBudgetOf([
        record('klabautermann:pref:a', 800 * 1024),
        record('klabautermann:rule:b', 40 * 1024),
      ]);
      expect((over.warns, over.full), (true, false));
    });
  });

  test('the app hears every server\'s preferences once, then changes, and '
      'a null for one that lost them', () {
    final (first, sent) = diffServerPrefs({}, {'srv-a': _prefs});
    expect([for (final e in first) (e.serverId, e.prefs)], [('srv-a', _prefs)]);

    final (same, _) = diffServerPrefs(sent, {
      'srv-a': decodeServerPrefs(encodeServerPrefs('srv-a', _prefs)),
    });
    expect(same, isEmpty);

    final (changed, after) = diffServerPrefs(sent, {
      'srv-a': const ServerPrefs(readOnly: true),
      'srv-b': const ServerPrefs(),
    });
    expect(
      [for (final e in changed) (e.serverId, e.prefs?.readOnly)],
      [('srv-a', true), ('srv-b', false)],
    );

    final (removed, _) = diffServerPrefs(after, {'srv-b': const ServerPrefs()});
    expect([for (final e in removed) (e.serverId, e.prefs)], [('srv-a', null)]);
  });

  group('writes', () {
    test(
      'retracting a server\'s pref is refused while sync is pull-only',
      () async {
        expect(
          await device.coordinator.retractServerPrefs('srv-a'),
          WriteOutcome.refusedPullOnly,
        );
        expect(await device.records.dirtyRecords(), isEmpty);
      },
    );

    test('with pushes on, a retraction seals a removal another device '
        'applies', () async {
      final writerDir = Directory('${dir.path}/writer')..createSync();
      final writer = await _Device.create(
        writerDir,
        pushPolicy: PushPolicy.normal,
      );
      expect(
        await writer.coordinator.retractServerPrefs('srv-a'),
        WriteOutcome.written,
      );
      final dirty = (await writer.records.dirtyRecords()).single;
      expect(dirty.id, prefId);

      await device.pull(prefId, encodeServerPrefs('srv-a', _prefs));
      await device.records.putRemote(dirty.withSeq(++device._seq));
      await device.coordinator.applyPulled();
      expect(device.store.prefs(), isEmpty);
      expect(device.store.tupleOf(prefId)?.deviceId, 'device-a');
    });
  });
}
