import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/catalog/klabautermann_records.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:test/test.dart';

import 'support/fake_sync_server.dart';

const _deviceId = '6f1c2f0e-3c5e-4d7a-9b1e-0a2b3c4d5e6f';
const _account = SyncAccountInfo(
  baseUrl: 'https://sync.example.com',
  username: fakeSyncUser,
);

// The engine's sync wiring (03 §4.3, §10.1, D62, D63): the requests, the
// keystore pair answered ahead of the request queue, and the fleet after
// an enrollment. EngineSync's own rules are in catalog/engine_sync_test.
void main() {
  late Directory support;

  setUp(() => support = Directory.systemTemp.createTempSync('klab-sync-'));
  tearDown(() => support.deleteSync(recursive: true));

  Future<(IsolateEngineClient, StreamIterator<EngineEvent>)> spawn({
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    void Function(EngineStart start) entryPoint = engineMain,
  }) async {
    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      supportDirectoryAccess: access,
      deviceId: _deviceId,
      entryPoint: entryPoint,
    );
    addTearDown(client.shutdown);
    final events = StreamIterator(client.events);
    addTearDown(events.cancel);
    // The startup fleet.
    expect(await events.moveNext(), isTrue);
    return (client, events);
  }

  /// The events up to the end of the next sync operation, answering each
  /// keystore request from [keystore] as the app's binding would.
  Future<List<EngineEvent>> untilSyncEnds(
    IsolateEngineClient client,
    StreamIterator<EngineEvent> events,
    MemoryKeystore keystore,
  ) async {
    final seen = <EngineEvent>[];
    while (await events.moveNext()) {
      final event = events.current;
      seen.add(event);
      if (event case KeystoreRequest(:final requestId, :final operation)) {
        final KeystoreResult result = switch (operation) {
          KeystorePutApiKey(:final name, :final value) =>
            await keystore
                .putApiKey(name, value)
                .then((_) => const KeystoreDone()),
          KeystoreGetApiKey(:final name) => KeystoreApiKey(
            await keystore.getApiKey(name),
          ),
          KeystoreDeleteApiKey() => const KeystoreDone(),
          KeystoreReadMasterKey() => KeystoreMasterKey(
            switch (keystore.masterKey) {
              final key? => Uint8List.fromList(key),
              null => null,
            },
          ),
          KeystoreWriteMasterKey(:final key) =>
            await keystore
                .writeMasterKey(key)
                .then((_) => const KeystoreDone()),
        };
        client.send(AnswerKeystore(requestId, result));
      }
      if (event is SyncStatus && event.phase != SyncPhase.running) break;
    }
    return seen;
  }

  test('sync is refused while another instance may use the files', () async {
    final (client, events) = await spawn(
      access: SupportDirectoryAccess.unguarded,
    );

    client.send(const RunSyncRound());

    final seen = await untilSyncEnds(client, events, MemoryKeystore());
    expect(
      [
        for (final event in seen.cast<SyncStatus>())
          (event.phase, event.failure),
      ],
      [
        (SyncPhase.running, null),
        (SyncPhase.failed, SyncFailure.directoryShared),
      ],
    );
  });

  test('a round asks the app for the keystore and reads its answers', () async {
    File('${support.path}/sync_enrollment.json').writeAsStringSync(
      '{"version":1,"passphraseUnverified":false,"notices":[],'
      '"account":{"baseUrl":"https://sync.example.com","username":"ops",'
      '"mode":"shared"}}',
    );
    File('${support.path}/sync_tripwires.json').writeAsStringSync('[]');
    final (client, events) = await spawn();
    expect(client.ready.syncAccount, _account);
    expect(
      [for (final issue in client.ready.syncStoreIssues) issue.fileName],
      ['sync_tripwires.json'],
    );

    client.send(const RunSyncRound());
    final keystore = MemoryKeystore()..apiKeys['sync.token'] = 'token-1';
    final seen = await untilSyncEnds(client, events, keystore);

    expect(
      [
        for (final event in seen.whereType<KeystoreRequest>())
          event.operation.runtimeType,
      ],
      [KeystoreGetApiKey, KeystoreReadMasterKey],
    );
    final end = seen.last as SyncStatus;
    expect(end.failure, SyncFailure.keystoreUnavailable);
    expect(end.detail, 'no vault key');
  });

  test('an enrollment lists the synced servers before it answers, and a '
      'later round succeeds', () async {
    final server = await FakeSyncServer.create();
    await server.seedServer(fakeServer('srv-a', 'alpha'));
    final (client, events) = await spawn(
      entryPoint: (start) => engineMain(start, syncTransport: server.transport),
    );
    final keystore = MemoryKeystore();

    client.send(
      const EnrollSync(
        baseUrl: 'https://sync.example.com',
        username: fakeSyncUser,
        password: fakeSyncPassword,
        encryptionPassphrase: fakeSyncPassword,
      ),
    );
    final enrolled = await untilSyncEnds(client, events, keystore);

    final fleet = enrolled.whereType<CatalogReplaced>().single;
    expect(enrolled.indexOf(fleet), lessThan(enrolled.length - 1));
    expect(
      [for (final entry in fleet.entries) (entry.serverId, entry.origin)],
      [('srv-a', FleetEntryOrigin.synced)],
    );
    final status = enrolled.last as SyncStatus;
    expect(status.phase, SyncPhase.succeeded, reason: status.detail);
    expect(status.account, _account);
    expect(keystore.apiKeys['sync.token'], 'token-1');

    client.send(const RunSyncRound());
    final round = await untilSyncEnds(client, events, keystore);
    final roundStatus = round.last as SyncStatus;
    expect(roundStatus.phase, SyncPhase.succeeded, reason: roundStatus.detail);
  });

  test('a saved server shows in the fleet, confirmed on this device, '
      'before the answer, and a round pushes it', () async {
    final server = await FakeSyncServer.create();
    await server.seedServer(fakeServer('srv-a', 'alpha'));
    final (client, events) = await spawn(
      entryPoint: (start) => engineMain(start, syncTransport: server.transport),
    );
    final keystore = MemoryKeystore();
    client.send(
      const EnrollSync(
        baseUrl: 'https://sync.example.com',
        username: fakeSyncUser,
        password: fakeSyncPassword,
        encryptionPassphrase: fakeSyncPassword,
      ),
    );
    await untilSyncEnds(client, events, keystore);

    client.send(
      const SaveServer(
        requestId: 'save-1',
        draft: ServerDraft(
          id: 'srv-new',
          label: 'web-3',
          host: 'web-3.example.com',
          port: 22,
          username: 'deploy',
          auth: ServerDraftAuth.agent,
        ),
      ),
    );
    final seen = await untilSyncEnds(client, events, keystore);

    final fleet = seen.whereType<CatalogReplaced>().first;
    final written = seen.whereType<CatalogWritten>().single;
    expect(seen.indexOf(fleet), lessThan(seen.indexOf(written)));
    expect(written.requestId, 'save-1');
    final saved = fleet.entries.singleWhere((e) => e.serverId == 'srv-new');
    expect(saved.endpoint, EndpointConfirmation.confirmed);
    expect(
      fleet.entries.singleWhere((e) => e.serverId == 'srv-a').endpoint,
      EndpointConfirmation.unconfirmed,
    );
    final round = seen.last as SyncStatus;
    expect(round.operation, SyncOperation.round);
    expect(round.phase, SyncPhase.succeeded, reason: round.detail);

    client.send(
      const ReadServerDraft(requestId: 'read-1', serverId: 'srv-new'),
    );
    while (await events.moveNext()) {
      if (events.current case ServerDraftRead(:final draft)) {
        expect(draft?.host, 'web-3.example.com');
        break;
      }
    }
  });

  test('synced preferences go out after the fleet, then only when they '
      'change', () async {
    final server = await FakeSyncServer.create();
    final prefId = KlabautermannRecordType.pref.idOf('srv-a');
    await server.seedServer(fakeServer('srv-a', 'alpha'));
    await server.seedKlabautermann(
      prefId,
      encodeServerPrefs('srv-a', const ServerPrefs(marks: {'nginx'})),
    );
    final (client, events) = await spawn(
      entryPoint: (start) => engineMain(start, syncTransport: server.transport),
    );
    final keystore = MemoryKeystore();
    const enroll = EnrollSync(
      baseUrl: 'https://sync.example.com',
      username: fakeSyncUser,
      password: fakeSyncPassword,
      encryptionPassphrase: fakeSyncPassword,
    );

    client.send(enroll);
    final enrolled = await untilSyncEnds(client, events, keystore);
    final changed = enrolled.whereType<ServerPrefsChanged>().single;
    expect(
      enrolled.indexOf(changed),
      greaterThan(
        enrolled.indexOf(enrolled.whereType<CatalogReplaced>().single),
      ),
    );
    expect(changed.serverId, 'srv-a');
    expect(changed.prefs?.marks, {'nginx'});

    // Nothing changed: nothing goes out.
    client.send(const RunSyncRound());
    final quiet = await untilSyncEnds(client, events, keystore);
    expect(quiet.whereType<ServerPrefsChanged>(), isEmpty);

    // A restarted engine sends them after its startup fleet.
    await events.cancel();
    await client.shutdown();
    final (_, restarted) = await spawn();
    expect(await restarted.moveNext(), isTrue);
    final again = restarted.current as ServerPrefsChanged;
    expect(again.prefs?.marks, {'nginx'});
  });
}
