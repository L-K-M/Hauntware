import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/capabilities/capability_cache.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:klabautermann_core/src/fleet/endpoint_pins.dart';
import 'package:seance_core/catalog.dart'
    show EndpointPin, EndpointPinStore, FileEndpointPinStore;
import 'package:seance_core/seance_core.dart' show ServerConfig;
import 'package:test/test.dart';

import 'support/answering_link.dart';
import 'support/fake_sync_server.dart';

const _deviceId = '6f1c2f0e-3c5e-4d7a-9b1e-0a2b3c4d5e6f';
const _srv = 'srv-a';

/// A synced id the capability cache names a file for (a UUID).
const _uuid = '0b5e7c1a-2d3f-4a6b-8c9d-0e1f2a3b4c5d';

/// Endpoint pins whose reads fail while [failReads] is set, as the file
/// store's do when it cannot read `endpoint_pins.json`.
final class _FlakyPins implements EndpointPinStore {
  _FlakyPins(this._inner);

  final EndpointPinStore _inner;
  bool failReads = false;

  @override
  Future<EndpointPin?> pinFor(String serverId) => failReads
      ? Future.error(const FileSystemException('unreadable'))
      : _inner.pinFor(serverId);

  @override
  Future<void> confirm(EndpointPin pin) => _inner.confirm(pin);

  @override
  Future<void> drop(String serverId) => _inner.drop(serverId);
}

/// The engine run in this isolate, as in the links tests, so a test holds
/// the link its dial hands out, with keystore requests answered from
/// [keystore] as the app's binding would and left out of [next].
final class _Engine {
  _Engine._(this._commands, this._messages);

  final SendPort _commands;
  final StreamIterator<Object?> _messages;
  final keystore = MemoryKeystore();

  static Future<_Engine> start(
    String supportDirectory, {
    required FakeSyncServer server,
    required List<ServerConfig> dials,
    required List<AnsweringLink> links,
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    EndpointPinStore? pins,
  }) async {
    final port = ReceivePort();
    final messages = StreamIterator<Object?>(port);
    addTearDown(port.close);
    engineMain(
      EngineStart(
        uiPort: port.sendPort,
        supportDirectory: supportDirectory,
        linksEnabled: true,
        supportDirectoryAccess: access,
        deviceId: _deviceId,
      ),
      dial:
          ({
            required config,
            required credentials,
            required tofu,
            required onHostKey,
            onKeyboardInteractive,
            resolveJumpHost,
          }) async {
            dials.add(config);
            return links.last;
          },
      syncTransport: server.transport,
      endpointPinStore: pins,
    );
    expect(
      await messages.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    final engine = _Engine._(messages.current as SendPort, messages)
      ..send(const Hello());
    expect(await engine.next(), isA<EngineReady>());
    expect(await engine.next(), isA<CatalogReplaced>());
    return engine;
  }

  void send(EngineRequest request) => _commands.send(request);

  Future<EngineEvent> next() async {
    while (true) {
      final arrived = await _messages.moveNext().timeout(
        const Duration(seconds: 10),
      );
      expect(arrived, isTrue);
      final event = _messages.current as EngineEvent;
      if (event is! KeystoreRequest) return event;
      send(AnswerKeystore(event.requestId, await _answer(event.operation)));
    }
  }

  Future<KeystoreResult> _answer(
    KeystoreOperation operation,
  ) async => switch (operation) {
    KeystorePutApiKey(:final name, :final value) =>
      await keystore.putApiKey(name, value).then((_) => const KeystoreDone()),
    KeystoreGetApiKey(:final name) => KeystoreApiKey(
      await keystore.getApiKey(name),
    ),
    KeystoreDeleteApiKey(:final name) =>
      await keystore.deleteApiKey(name).then((_) => const KeystoreDone()),
    KeystoreReadMasterKey() => KeystoreMasterKey(switch (keystore.masterKey) {
      final key? => Uint8List.fromList(key),
      null => null,
    }),
    KeystoreWriteMasterKey(:final key) =>
      await keystore.writeMasterKey(key).then((_) => const KeystoreDone()),
  };

  /// Reads events until one of type [T].
  Future<T> until<T extends EngineEvent>() async {
    while (true) {
      if (await next() case final T event) return event;
    }
  }

  /// The events up to the end of the next sync operation.
  Future<List<EngineEvent>> untilSyncEnds() async {
    final seen = <EngineEvent>[];
    while (true) {
      final event = await next();
      seen.add(event);
      if (event is SyncStatus && event.phase != SyncPhase.running) {
        expect(event.phase, SyncPhase.succeeded, reason: event.detail);
        return seen;
      }
    }
  }

  Future<List<EngineEvent>> enroll() {
    send(
      const EnrollSync(
        baseUrl: 'https://sync.example.com',
        username: fakeSyncUser,
        password: fakeSyncPassword,
        encryptionPassphrase: fakeSyncPassword,
      ),
    );
    return untilSyncEnds();
  }
}

EndpointConfirmation? _endpointIn(
  List<EngineEvent> events, {
  String serverId = _srv,
}) => events
    .whereType<CatalogReplaced>()
    .last
    .entries
    .singleWhere((entry) => entry.serverId == serverId)
    .endpoint;

// 03 §4.3 step 3, §4.7, SAF-09, SYN-08: the engine dials a synced server
// only once its endpoint is confirmed, and a sync that changes a
// confirmed endpoint closes its link and asks again.
void main() {
  late Directory support;
  late FakeSyncServer server;
  late List<ServerConfig> dials;
  late List<AnsweringLink> links;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('klab-endpoints-');
    server = await FakeSyncServer.create();
    await server.seedServer(fakeServer(_srv, 'alpha'));
    dials = [];
    links = [AnsweringLink()];
  });
  tearDown(() => support.deleteSync(recursive: true));

  Future<_Engine> start({
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    EndpointPinStore? pins,
  }) => _Engine.start(
    support.path,
    server: server,
    dials: dials,
    links: links,
    access: access,
    pins: pins,
  );

  test('a synced server dials only once confirmed, and a sync that moves '
      'it stops its link and sampling until it is confirmed again', () async {
    final engine = await start();
    expect(
      _endpointIn(await engine.enroll()),
      EndpointConfirmation.unconfirmed,
    );

    engine.send(const Connect(_srv));
    final rejected = await engine.next() as ConnectRejected;
    expect(rejected.reason, ConnectRejectedReason.endpointNotConfirmed);

    engine.send(const ConfirmEndpoints([_srv, 'ssh-config:none']));
    expect(_endpointIn([await engine.next()]), EndpointConfirmation.confirmed);
    expect(File('${support.path}/endpoint_pins.json').existsSync(), isTrue);

    engine
      ..send(
        const Subscribe(
          serverId: _srv,
          subscriptionId: 'overview',
          streams: {SampleStream.core},
        ),
      )
      ..send(const Connect(_srv));
    await engine.until<Sample>();
    expect([for (final config in dials) config.host], ['alpha.example.com']);

    // Another device moves the server.
    await server.seedServer(
      fakeServer(_srv, 'alpha').copyWith(host: 'moved.example.com'),
      updatedAt: 2,
    );
    engine.send(const RunSyncRound());
    final round = (await engine.untilSyncEnds())
        .where((event) => event is! Sample)
        .toList();

    final changed = round.whereType<EndpointChanged>().single;
    expect(changed.serverId, _srv);
    expect(
      round.indexOf(changed),
      lessThan(round.indexOf(round.whereType<CatalogReplaced>().single)),
    );
    expect(_endpointIn(round), EndpointConfirmation.changed);
    expect(
      round.whereType<LinkState>().map((event) => event.status),
      contains(const LinkClosed(LinkClosedReason.closedByOwner)),
    );
    expect(links.single.running, isEmpty, reason: 'sampling stopped');
    expect(links.single.closes, 1);

    engine.send(const Connect(_srv));
    final again = await engine.until<ConnectRejected>();
    expect(again.reason, ConnectRejectedReason.endpointNotConfirmed);
    expect(dials, hasLength(1), reason: 'nothing dials the moved host');

    engine.send(const ConfirmEndpoints([_srv]));
    expect(
      _endpointIn([await engine.until<CatalogReplaced>()]),
      EndpointConfirmation.confirmed,
    );
    links.add(AnsweringLink());
    engine.send(const Connect(_srv));
    await engine.until<Sample>();
    expect(dials.last.host, 'moved.example.com');
  });

  test('a pin that cannot be saved leaves the server unconfirmed and says '
      'so', () async {
    // A directory where the file belongs: every read and write fails.
    Directory('${support.path}/endpoint_pins.json').createSync();
    final engine = await start();
    await engine.enroll();

    engine.send(const ConfirmEndpoints([_srv]));
    final rejection = await engine.next() as RequestRejected;
    expect(rejection.requestName, 'ConfirmEndpoints');
    expect(rejection.reason, contains('endpoint_pins.json'));
    expect(
      _endpointIn([await engine.next()]),
      EndpointConfirmation.unconfirmed,
    );
  });

  test('pins persist only with the support directory held alone', () async {
    final pin = EndpointPin(
      serverId: _srv,
      host: 'alpha.example.com',
      port: kSshDefaultPort,
      username: 'deploy',
      jumpRouteIds: const [],
      confirmedAt: DateTime.utc(2026, 10, 17),
    );
    final file = File('${support.path}/endpoint_pins.json');

    final shared = openEndpointPins(
      support.path,
      access: SupportDirectoryAccess.unguarded,
    );
    await shared.confirm(pin);
    expect(await shared.pinFor(_srv), pin);
    expect(file.existsSync(), isFalse);

    final owned = openEndpointPins(
      support.path,
      access: SupportDirectoryAccess.exclusive,
    );
    expect(owned, isA<FileEndpointPinStore>());
    await owned.confirm(pin);
    expect(file.existsSync(), isTrue);

    // An engine holding the directory enrolls and confirms the server, so
    // the directory holds the synced catalog and its pin. An engine run
    // in this isolate cannot shut down (Shutdown exits the isolate), so
    // it is left idle.
    final held = await start();
    await held.enroll();
    held.send(const ConfirmEndpoints([_srv]));
    expect(_endpointIn([await held.next()]), EndpointConfirmation.confirmed);

    // An unguarded engine still lists no synced server (D63), so nothing
    // in the directory is confirmed or dialed through it.
    final engine = await start(access: SupportDirectoryAccess.unguarded);
    engine.send(const ConfirmEndpoints([_srv]));
    expect((await engine.next() as CatalogReplaced).entries, isEmpty);
    engine.send(const Connect(_srv));
    expect((await engine.next() as RequestRejected).requestName, 'Connect');
    expect(dials, isEmpty);
  });

  test('a pin the store cannot read fails closed without counting as an '
      'endpoint change (SYN-08)', () async {
    await server.seedServer(fakeServer(_uuid, 'bravo'));
    final pins = _FlakyPins(
      FileEndpointPinStore(File('${support.path}/endpoint_pins.json')),
    );
    final engine = await start(pins: pins);
    await engine.enroll();
    engine.send(const ConfirmEndpoints([_uuid]));
    expect(
      _endpointIn([await engine.next()], serverId: _uuid),
      EndpointConfirmation.confirmed,
    );

    // A profile cached for the server, as a probe would have left it.
    final cacheFile = File(
      '${support.path}/$capabilityCacheDirectoryName/'
      '${capabilityCacheFileName(_uuid)}',
    );
    final cache = await CapabilityCache.open(
      support,
      access: SupportDirectoryAccess.exclusive,
      fleet: const {_uuid},
      purge: CachePurge.never,
    );
    await cache.probed(_uuid, HostProfile(systemdVersion: 252));
    expect(cacheFile.existsSync(), isTrue);

    engine
      ..send(
        const Subscribe(
          serverId: _uuid,
          subscriptionId: 'overview',
          streams: {SampleStream.core},
        ),
      )
      ..send(const Connect(_uuid));
    await engine.until<Sample>();

    /// Runs a round and returns its events without samples.
    Future<List<EngineEvent>> round() async {
      engine.send(const RunSyncRound());
      return [
        for (final event in await engine.untilSyncEnds())
          if (event is! Sample) event,
      ];
    }

    void expectUntouched(List<EngineEvent> events) {
      expect(events.whereType<EndpointChanged>(), isEmpty);
      expect(events.whereType<LinkState>(), isEmpty);
      expect(links.single.closes, 0);
      expect(cacheFile.existsSync(), isTrue);
    }

    // Unreadable: not dialable, yet no change.
    pins.failReads = true;
    final failed = await round();
    expectUntouched(failed);
    expect(
      _endpointIn(failed, serverId: _uuid),
      isNot(EndpointConfirmation.confirmed),
    );
    engine.send(const Connect(_uuid));
    expect(
      (await engine.until<ConnectRejected>()).reason,
      ConnectRejectedReason.endpointNotConfirmed,
    );

    // Readable again: confirmed, still no change.
    pins.failReads = false;
    final recovered = await round();
    expectUntouched(recovered);
    expect(
      _endpointIn(recovered, serverId: _uuid),
      EndpointConfirmation.confirmed,
    );

    // A move while the store fails is caught once it reads again.
    await server.seedServer(
      fakeServer(_uuid, 'bravo').copyWith(host: 'moved.example.com'),
      updatedAt: 2,
    );
    pins.failReads = true;
    expectUntouched(await round());

    pins.failReads = false;
    final moved = await round();
    expect(moved.whereType<EndpointChanged>().single.serverId, _uuid);
    expect(_endpointIn(moved, serverId: _uuid), EndpointConfirmation.changed);
    expect(links.single.closes, 1);
    final sw = Stopwatch()..start();
    while (cacheFile.existsSync()) {
      if (sw.elapsed > const Duration(seconds: 5)) fail('file not purged');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}
