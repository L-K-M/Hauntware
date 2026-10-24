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
import 'package:seance_core/seance_core.dart'
    show ProbeStatus, Prober, ServerConfig, TcpBannerProber;
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

/// The bound on one engine event arriving. On a loaded CI runner the
/// isolate's event loop has been observed slipping past 10 seconds; the
/// bound only exists to fail a real deadlock.
const _engineEventWait = Duration(seconds: 30);

/// Records each probe's `host:port` and answers online, as a reachable
/// host would.
final class _RecordingProber implements Prober {
  final probed = <String>[];

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    probed.add('$host:$port');
    return ProbeStatus.online;
  }
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
    List<bool>? prompting,
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    EndpointPinStore? pins,
    Prober? prober,
  }) async {
    final port = ReceivePort();
    final messages = StreamIterator<Object?>(port);
    addTearDown(port.close);
    engineMain(
      EngineStart(
        uiPort: port.sendPort,
        supportDirectory: supportDirectory,
        linksEnabled: true,
        probesEnabled: prober != null,
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
            // Only the user's connect may ask anything (03 §4.5).
            prompting?.add(onKeyboardInteractive != null);
            return links.last;
          },
      syncTransport: server.transport,
      endpointPinStore: pins,
      prober: prober ?? const TcpBannerProber(),
    );
    expect(
      await messages.moveNext().timeout(_engineEventWait),
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
      final arrived = await _messages.moveNext().timeout(_engineEventWait);
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
  late List<bool> prompting;

  setUp(() async {
    support = Directory.systemTemp.createTempSync('klab-endpoints-');
    server = await FakeSyncServer.create();
    await server.seedServer(fakeServer(_srv, 'alpha'));
    dials = [];
    links = [AnsweringLink()];
    prompting = [];
  });
  tearDown(() => support.deleteSync(recursive: true));

  Future<_Engine> start({
    SupportDirectoryAccess access = SupportDirectoryAccess.exclusive,
    EndpointPinStore? pins,
    Prober? prober,
  }) => _Engine.start(
    support.path,
    server: server,
    dials: dials,
    links: links,
    prompting: prompting,
    access: access,
    pins: pins,
    prober: prober,
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

  // FL-04, 03 §5.12: a probe is a TCP connect, so it would hand the
  // user's address to whoever rewrote an unconfirmed endpoint.
  test('probes reach only confirmed endpoints, stop when a sync moves one '
      'and report a jump-routed import unknown', () async {
    await server.seedServer(fakeServer('srv-b', 'beta'));
    final prober = _RecordingProber();
    final engine = await start(prober: prober);
    await engine.enroll();

    /// Reads answers until every one of [ids] has one, and returns the
    /// latest of each.
    Future<Map<String, ReachabilityStatus>> answersFor(Set<String> ids) async {
      final answers = <String, ReachabilityStatus>{};
      while (!answers.keys.toSet().containsAll(ids)) {
        final answer = await engine.until<Reachability>();
        answers[answer.serverId] = answer.status;
      }
      return answers;
    }

    engine.send(const ConfirmEndpoints([_srv]));
    expect(await answersFor({_srv}), {_srv: ReachabilityStatus.online});
    expect(prober.probed, ['alpha.example.com:22']);

    engine.send(
      const ImportSshConfig(
        'Host web\n  HostName web.example.com\n  User deploy\n'
        'Host inner\n  HostName inner.example.com\n  User deploy\n'
        '  ProxyJump web\n',
      ),
    );
    final answers = await answersFor({'ssh-config:web', 'ssh-config:inner'});
    expect(answers['ssh-config:web'], ReachabilityStatus.online);
    expect(answers['ssh-config:inner'], ReachabilityStatus.unknown);
    expect(prober.probed.toSet(), {
      'alpha.example.com:22',
      'web.example.com:22',
    });

    // Another device moves the confirmed server: nothing probes it until
    // the user confirms the new endpoint.
    await server.seedServer(
      fakeServer(_srv, 'alpha').copyWith(host: 'moved.example.com'),
      updatedAt: 2,
    );
    engine.send(const RunSyncRound());
    final round = await engine.untilSyncEnds();
    expect(round.whereType<EndpointChanged>().single.serverId, _srv);
    expect(
      round.whereType<Reachability>().map((answer) => answer.serverId),
      isNot(contains(_srv)),
    );

    engine.send(const ConfirmEndpoints([_srv]));
    while (!prober.probed.contains('moved.example.com:22')) {
      await engine.until<Reachability>();
    }
    expect(
      prober.probed.where((target) => target.startsWith('beta.')),
      isEmpty,
      reason: 'the unconfirmed server is never probed',
    );
  });

  test('the background holds probes back until the foreground', () async {
    final prober = _RecordingProber();
    final engine = await start(prober: prober);
    await engine.enroll();

    engine
      ..send(const SetAppActivity(AppActivity.background))
      ..send(const ConfirmEndpoints([_srv]));
    expect(
      _endpointIn([await engine.until<CatalogReplaced>()]),
      EndpointConfirmation.confirmed,
    );
    // One more answer gives a probe the confirmation started time to
    // report.
    engine.send(const ConfirmEndpoints([]));
    expect(await engine.next(), isA<CatalogReplaced>());
    expect(prober.probed, isEmpty);

    engine.send(const SetAppActivity(AppActivity.foreground));
    expect((await engine.until<Reachability>()).serverId, _srv);
    expect(prober.probed, ['alpha.example.com:22']);
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

  group('the monitor set (FL-21, 03 §4.3 step 4)', () {
    const web = 'ssh-config:web';
    const webConfig = 'Host web\n  HostName 192.0.2.10\n  User me\n';

    Future<void> import(_Engine engine, String config) async {
      engine.send(ImportSshConfig(config));
      await engine.until<SshConfigImported>();
    }

    test('samples a confirmed synced server over an unattended link, and '
        'loses it when a sync moves the server', () async {
      final engine = await start();
      await engine.enroll();

      engine.send(const SetMonitorSet([_srv]));
      final refused = await engine.next() as RequestRejected;
      expect(refused.requestName, 'SetMonitorSet');
      expect(refused.reason, contains(_srv), reason: 'not confirmed yet');
      await pumpEventQueue();
      expect(dials, isEmpty);

      engine.send(const ConfirmEndpoints([_srv]));
      await engine.until<CatalogReplaced>();
      // No view connects or subscribes: the set alone samples it.
      engine.send(const SetMonitorSet([_srv]));
      final sample = await engine.until<Sample>();
      expect((sample.serverId, sample.stream), (_srv, SampleStream.overview));
      expect(prompting, [false], reason: 'background connects never ask');

      await server.seedServer(
        fakeServer(_srv, 'alpha').copyWith(host: 'moved.example.com'),
        updatedAt: 2,
      );
      engine.send(const RunSyncRound());
      await engine.untilSyncEnds();
      expect(links.single.closes, 1);
      expect(links.single.running, isEmpty, reason: 'sampling stopped');

      // Confirming the new endpoint does not bring it back: the app sends
      // its set again after the fleet it hears.
      engine.send(const ConfirmEndpoints([_srv]));
      await engine.until<CatalogReplaced>();
      await pumpEventQueue();
      expect(dials, hasLength(1));
    });

    test('a set of more than ten is rejected whole, and ids outside the '
        'fleet are skipped by name', () async {
      final engine = await start();
      final ids = [for (var i = 1; i <= kMonitorSetLimit + 1; i++) 's$i'];
      await import(
        engine,
        [
          for (final id in ids) 'Host $id\n  HostName 192.0.2.1\n  User me\n',
        ].join(),
      );

      engine.send(const SetMonitorSet(['ssh-config:s1', 'ssh-config:gone']));
      final skipped = await engine.until<RequestRejected>();
      expect(skipped.reason, contains('ssh-config:gone'));
      expect(skipped.reason, isNot(contains('ssh-config:s1')));
      await engine.until<Sample>();

      engine.send(SetMonitorSet([for (final id in ids) 'ssh-config:$id']));
      final refused = await engine.until<RequestRejected>();
      expect(refused.reason, contains('more than $kMonitorSetLimit'));
      await pumpEventQueue();
      expect(dials, hasLength(1), reason: 'the last set stands');
      expect(links.single.closes, 0);
    });

    test('a view\'s Disconnect keeps a monitored server\'s link, and '
        'leaving the set keeps the link a view holds', () async {
      final engine = await start();
      await import(engine, webConfig);
      final link = links.single;

      engine
        ..send(const SetMonitorSet([web]))
        ..send(const Connect(web))
        ..send(const Disconnect(web));
      await engine.until<Sample>();
      expect(link.closes, 0, reason: 'the monitor set holds it');

      engine
        ..send(const Connect(web))
        ..send(const SetMonitorSet([]));
      await pumpEventQueue();
      expect(link.closes, 0, reason: 'the open view holds it');
      expect(link.running, isEmpty, reason: 'nothing subscribes now');

      engine.send(const Disconnect(web));
      expect(
        (await engine.until<LinkState>()).status,
        const LinkClosed(LinkClosedReason.closedByOwner),
      );
      expect(link.closes, 1);
      expect(dials, hasLength(1));
    });
  });
}
