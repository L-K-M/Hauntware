import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Account _account(String generation, {int floor = 1}) => Account(
  username: 'alice',
  generation: generation,
  authVerifierHash: 'hash',
  verifierSalt: 'salt',
  argonSalt: 'argon',
  argonParams: const Argon2Params(),
  recordEnvelopeFloor: floor,
);

EncryptedRecord _record(
  String id, {
  required int envelopeVersion,
  required int updatedAt,
  required int? seq,
  String deviceId = 'device',
  int blobByte = 1,
  int blobBytes = 1,
}) => EncryptedRecord(
  envelopeVersion: envelopeVersion,
  id: id,
  updatedAt: updatedAt,
  deviceId: deviceId,
  deleted: false,
  seq: seq,
  blob: Uint8List(blobBytes)..fillRange(0, blobBytes, blobByte),
);

bool _sameRecord(EncryptedRecord a, EncryptedRecord b) {
  if (a.envelopeVersion != b.envelopeVersion ||
      a.id != b.id ||
      a.updatedAt != b.updatedAt ||
      a.deviceId != b.deviceId ||
      a.deleted != b.deleted ||
      a.seq != b.seq ||
      a.blob.length != b.blob.length) {
    return false;
  }
  for (var index = 0; index < a.blob.length; index++) {
    if (a.blob[index] != b.blob[index]) return false;
  }
  return true;
}

Future<AuthPrincipal> _principal(Storage storage) async {
  final token = await storage.createToken('alice');
  return (await storage.principalForToken(
    token,
    now: DateTime.now().millisecondsSinceEpoch,
  ))!;
}

Future<EncryptedRecord> _putLegacy(Storage storage, String id) async {
  final seq = await storage.nextSeq('alice');
  final record = _record(
    id,
    envelopeVersion: 1,
    updatedAt: seq,
    seq: seq,
    blobByte: seq,
  );
  await storage.putRecord('alice', record);
  return record;
}

void main() {
  for (final sqlite in [false, true]) {
    group(sqlite ? 'sqlite' : 'memory', () {
      late Storage storage;

      setUp(() async {
        storage = sqlite ? SqliteStorage.open(':memory:') : InMemoryStorage();
        await storage.createAccount(_account('generation-a'));
      });

      tearDown(() {
        if (storage is SqliteStorage) {
          (storage as SqliteStorage).close();
        }
      });

      test('exact CAS replaces v1 and checkpoints floor 2', () async {
        final legacy = await _putLegacy(storage, 'record');
        final principal = await _principal(storage);
        final replacement = _record(
          'record',
          envelopeVersion: 2,
          updatedAt: 5,
          seq: null,
          blobByte: 9,
        );

        final result = await storage.migrateLegacyRecordsFor(principal, [
          LegacyRecordMigration(expected: legacy, replacement: replacement),
        ], finalize: true);

        expect(result.migrated, 1);
        expect(result.stale, 0);
        expect(result.recordEnvelopeFloor, 2);
        expect(
          result.latestSeq,
          3,
          reason: 'replacement and irreversible floor each get a sequence',
        );
        final stored = (await storage.getRecord('alice', 'record'))!;
        expect(stored.envelopeVersion, 2);
        expect(stored.seq, 2);
        expect((await storage.getAccount('alice'))!.recordEnvelopeFloor, 2);
      });

      test(
        'tampered expected tuple is stale and blocks finalization',
        () async {
          final legacy = await _putLegacy(storage, 'record');
          final principal = await _principal(storage);
          final tampered = _record(
            legacy.id,
            envelopeVersion: 1,
            updatedAt: legacy.updatedAt,
            seq: legacy.seq,
            deviceId: 'forged',
            blobByte: legacy.blob.single,
          );

          final result = await storage.migrateLegacyRecordsFor(principal, [
            LegacyRecordMigration(
              expected: tampered,
              replacement: _record(
                'record',
                envelopeVersion: 2,
                updatedAt: 2,
                seq: null,
              ),
            ),
          ], finalize: true);

          expect(result.migrated, 0);
          expect(result.stale, 1);
          expect(result.recordEnvelopeFloor, 1);
          expect(
            _sameRecord((await storage.getRecord('alice', 'record'))!, legacy),
            isTrue,
          );
        },
      );

      test('different-id migration never overwrites an existing v1', () async {
        final observed = await _putLegacy(storage, 'forged-id');
        final canonical = await _putLegacy(storage, 'canonical');

        final result = await storage.migrateLegacyRecords('alice', [
          LegacyRecordMigration(
            expected: observed,
            replacement: _record(
              'canonical',
              envelopeVersion: 2,
              updatedAt: 99,
              seq: null,
            ),
          ),
        ], finalize: true);

        expect(result.migrated, 1);
        expect(await storage.getRecord('alice', 'forged-id'), isNull);
        expect(
          _sameRecord(
            (await storage.getRecord('alice', 'canonical'))!,
            canonical,
          ),
          isTrue,
        );
        expect(result.recordEnvelopeFloor, 1);
      });

      test('quota failure rolls back replacement and sequence', () async {
        final legacy = await _putLegacy(storage, 'record');
        final beforeSeq = await storage.latestSeq('alice');

        await expectLater(
          storage.migrateLegacyRecords(
            'alice',
            [
              LegacyRecordMigration(
                expected: legacy,
                replacement: _record(
                  'record',
                  envelopeVersion: 2,
                  updatedAt: 2,
                  seq: null,
                  blobBytes: 100,
                ),
              ),
            ],
            finalize: true,
            quota: const AccountQuota(maxRecords: 10, maxBytes: 1),
          ),
          throwsA(isA<AccountQuotaExceededException>()),
        );

        expect(await storage.latestSeq('alice'), beforeSeq);
        expect(
          _sameRecord((await storage.getRecord('alice', 'record'))!, legacy),
          isTrue,
        );
      });

      test('lexical page progresses after a concurrent CAS removal', () async {
        final a = await _putLegacy(storage, 'a');
        await _putLegacy(storage, 'b');
        await _putLegacy(storage, 'c');
        const limits = PullPageLimits(maxRecords: 1, maxBodyBytes: 4096);

        final first = await storage.legacyRecordPage('alice', limits: limits);
        expect(first.records.single.id, 'a');
        expect(first.nextId, 'a');
        expect(first.hasMore, isTrue);

        await storage.migrateLegacyRecords('alice', [
          LegacyRecordMigration(
            expected: a,
            replacement: _record(
              'a',
              envelopeVersion: 2,
              updatedAt: 1,
              seq: null,
            ),
          ),
        ], finalize: false);
        final second = await storage.legacyRecordPage(
          'alice',
          afterId: first.nextId,
          limits: limits,
        );
        expect(second.records.single.id, 'b');
      });

      test('legacy page byte bound is exact and never stalls', () async {
        final legacy = await _putLegacy(storage, 'record');
        final exact = LegacyRecordPage(
          records: [legacy],
          nextId: legacy.id,
          hasMore: false,
          recordEnvelopeFloor: 1,
        ).encodedSizeBytes();

        final page = await storage.legacyRecordPage(
          'alice',
          limits: PullPageLimits(maxRecords: 1, maxBodyBytes: exact),
        );
        expect(page.records.single.id, 'record');
        await expectLater(
          storage.legacyRecordPage(
            'alice',
            limits: PullPageLimits(maxRecords: 1, maxBodyBytes: exact - 1),
          ),
          throwsA(isA<StoragePageTooSmallException>()),
        );
      });

      test('floor 2 with a legacy row is an internal inconsistency', () async {
        await storage.deleteAccount('alice');
        await storage.createAccount(_account('generation-current', floor: 2));
        await _putLegacy(storage, 'record');

        await expectLater(
          storage.legacyRecordPage(
            'alice',
            limits: const PullPageLimits(maxRecords: 10, maxBodyBytes: 4096),
          ),
          throwsA(isA<StorageEnvelopeFloorViolationException>()),
        );
      });

      test(
        'floor checkpoint is constant across an older pull watermark',
        () async {
          final legacy = await _putLegacy(storage, 'a');
          await storage.pushRecords('alice', [
            _record('b', envelopeVersion: 2, updatedAt: 2, seq: null),
          ]);
          const limits = PullPageLimits(maxRecords: 1, maxBodyBytes: 4096);
          final first = await storage.pullPage('alice', 0, limits: limits);
          expect(first.recordEnvelopeFloor, 1);

          await storage.migrateLegacyRecords('alice', [
            LegacyRecordMigration(
              expected: legacy,
              replacement: _record(
                'a',
                envelopeVersion: 2,
                updatedAt: 1,
                seq: null,
              ),
            ),
          ], finalize: true);
          final continuation = await storage.pullPage(
            'alice',
            first.records.single.seq!,
            throughSeq: first.throughSeq,
            limits: limits,
          );
          expect(continuation.recordEnvelopeFloor, 1);
          final fresh = await storage.pullPage(
            'alice',
            await storage.latestSeq('alice'),
            limits: limits,
          );
          expect(fresh.recordEnvelopeFloor, 2);
        },
      );

      test('stale principal cannot migrate a replacement account', () async {
        final token = await storage.createToken('alice');
        final stale = (await storage.principalForToken(
          token,
          now: DateTime.now().millisecondsSinceEpoch,
        ))!;
        await storage.deleteAccount('alice');
        await storage.createAccount(_account('generation-b'));
        final replacementLegacy = await _putLegacy(storage, 'record');

        Future<void> migrateWithStalePrincipal() async {
          await storage.migrateLegacyRecordsFor(stale, [
            LegacyRecordMigration(
              expected: replacementLegacy,
              replacement: _record(
                'record',
                envelopeVersion: 2,
                updatedAt: 2,
                seq: null,
              ),
            ),
          ], finalize: true);
        }

        await expectLater(
          migrateWithStalePrincipal(),
          throwsA(isA<StalePrincipalException>()),
        );
        expect(
          (await storage.getRecord('alice', 'record'))!.envelopeVersion,
          1,
        );
      });
    });
  }

  test(
    'SQLite upgrades existing accounts at floor 1 and creates new at 2',
    () async {
      final directory = Directory.systemTemp.createTempSync('legacy-floor');
      final path = '${directory.path}/sync.sqlite';
      try {
        final legacy = sqlite3.open(path);
        legacy.execute('''
        CREATE TABLE accounts (
          username TEXT PRIMARY KEY,
          generation TEXT NOT NULL,
          auth_verifier_hash TEXT NOT NULL,
          verifier_salt TEXT NOT NULL,
          argon_salt TEXT NOT NULL,
          argon_params TEXT NOT NULL,
          vault_key_check TEXT
        )
      ''');
        legacy.execute('INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, ?)', [
          'old',
          'generation',
          'hash',
          'salt',
          'argon',
          jsonEncode(const Argon2Params().toJson()),
          null,
        ]);
        legacy.dispose();

        final storage = SqliteStorage.open(path);
        expect((await storage.getAccount('old'))!.recordEnvelopeFloor, 1);
        await storage.createAccount(
          Account(
            username: 'new',
            generation: 'generation-new',
            authVerifierHash: 'hash',
            verifierSalt: 'salt',
            argonSalt: 'argon',
            argonParams: const Argon2Params(),
          ),
        );
        expect((await storage.getAccount('new'))!.recordEnvelopeFloor, 2);
        storage.close();
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('authenticated legacy endpoints enumerate, CAS, and finalize', () async {
    final storage = InMemoryStorage();
    await storage.createAccount(_account('generation-http'));
    final token = await storage.createToken('alice');
    final legacy = await _putLegacy(storage, 'record');
    final handler = SyncServer(
      storage: storage,
      settings: const ServerSettings(),
    ).handler;
    final headers = {
      'authorization': 'Bearer $token',
      'content-type': 'application/json',
      'x-seance-protocol-version': '$kProtocolVersion',
    };

    final pageResponse = await handler(
      Request(
        'GET',
        Uri.parse('http://localhost/v1/records/legacy'),
        headers: headers,
      ),
    );
    expect(pageResponse.statusCode, 200);
    final page = LegacyRecordPage.fromJson(
      (jsonDecode(await pageResponse.readAsString()) as Map).cast(),
    );
    expect(page.records.single.id, 'record');
    expect(page.recordEnvelopeFloor, 1);

    final migrationResponse = await handler(
      Request(
        'PUT',
        Uri.parse('http://localhost/v1/records/legacy'),
        headers: headers,
        body: jsonEncode(
          LegacyMigrationRequest(
            migrations: [
              LegacyRecordMigration(
                expected: legacy,
                replacement: _record(
                  'record',
                  envelopeVersion: 2,
                  updatedAt: 2,
                  seq: null,
                ),
              ),
            ],
            finalize: true,
          ).toJson(),
        ),
      ),
    );
    expect(migrationResponse.statusCode, 200);
    final result = LegacyMigrationResponse.fromJson(
      (jsonDecode(await migrationResponse.readAsString()) as Map).cast(),
    );
    expect(result.migrated, 1);
    expect(result.recordEnvelopeFloor, 2);
  });
}
