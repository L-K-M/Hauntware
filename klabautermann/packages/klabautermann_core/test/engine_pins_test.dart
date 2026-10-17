import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:klabautermann_core/src/fleet/ssh_config_import_store.dart'
    show sshConfigImportsFileName;
import 'package:klabautermann_core/src/links/host_key_pins.dart';
import 'package:seance_core/seance_core.dart'
    show
        HostKey,
        HostKeyPrompter,
        KeyboardInteractiveResponder,
        ServerConfig,
        SshConnectException,
        SshConnectionLog,
        SshCredentials,
        SshJumpHostResolver,
        SshLink,
        SshLinkClosed,
        SshLinkClosedReason,
        SshLinkReady,
        SshLinkSeen,
        SshLinkState,
        TofuVerifier;
import 'package:test/test.dart';

const _web = 'ssh-config:web';
const _webConfig = 'Host web\n  HostName 192.0.2.10\n  User me\n';
const _otherConfig = 'Host other\n  HostName 192.0.2.11\n  User me\n';

const _blocked = LinkBlocked(LinkBlockedReason.hostKeyChanged);

/// A link that reports ready and can be lost underneath.
final class _Link implements SshLink {
  final _states = StreamController<SshLinkState>();

  @override
  Stream<SshLinkState> get states => _states.stream;

  void ready() => _states.add(const SshLinkReady(SshLinkSeen()));

  void lose() => _states.add(const SshLinkClosed(SshLinkClosedReason.linkLost));

  @override
  Future<void> close() async {}

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// A server whose host key the test changes, dialed as `SshLink.connect`
/// dials (seance_core's `_verifyHostKey`): a pinned key passes, any other
/// goes to `onHostKey`, a trusted one is pinned through
/// `TofuVerifier.pin`, and a refusal ends the connect.
final class _Server {
  String keyType = 'ssh-ed25519';
  String fingerprint = 'SHA256:first';
  final List<_Link> links = [];

  void rekey() {
    keyType = 'ecdsa-sha2-nistp256';
    fingerprint = 'SHA256:rekeyed';
  }

  Future<SshLink> dial({
    required ServerConfig config,
    required SshCredentials credentials,
    required TofuVerifier tofu,
    required HostKeyPrompter onHostKey,
    KeyboardInteractiveResponder? onKeyboardInteractive,
    SshJumpHostResolver? resolveJumpHost,
  }) async {
    final key = HostKey(
      host: config.host,
      port: config.port,
      type: keyType,
      fingerprintSha256: fingerprint,
      pinnedAt: 0,
    );
    final decision = await tofu.check(key);
    if (!decision.isTrusted) {
      if (!await onHostKey(decision)) {
        throw SshConnectException(
          'refused',
          Exception('key'),
          SshConnectionLog(),
        );
      }
      await tofu.pin(key);
    }
    final link = _Link();
    links.add(link);
    // Ready once the supervisor listens, as a real link reports it.
    scheduleMicrotask(link.ready);
    return link;
  }
}

/// One engine run in this isolate over a support directory; a test that
/// starts a second over the same directory restarts the engine. It is
/// never sent [Shutdown], whose `Isolate.exit` would end the test isolate.
final class _Engine {
  _Engine._(this._commands, this._messages);

  final SendPort _commands;
  final StreamIterator<Object?> _messages;

  static Future<_Engine> start(
    Directory support,
    _Server server, {
    required SupportDirectoryAccess access,
  }) async {
    final port = ReceivePort();
    final messages = StreamIterator<Object?>(port);
    addTearDown(port.close);
    engineMain(
      EngineStart(
        uiPort: port.sendPort,
        supportDirectory: support.path,
        linksEnabled: true,
        supportDirectoryAccess: access,
      ),
      dial: server.dial,
    );
    expect(await messages.moveNext(), isTrue);
    final engine = _Engine._(messages.current as SendPort, messages)
      ..send(const Hello());
    expect(await engine.next(), isA<EngineReady>());
    expect(await engine.next(), isA<CatalogReplaced>());
    return engine;
  }

  void send(EngineRequest request) => _commands.send(request);

  Future<EngineEvent> next() async {
    final arrived = await _messages.moveNext().timeout(
      const Duration(seconds: 5),
    );
    expect(arrived, isTrue);
    return _messages.current as EngineEvent;
  }

  Future<void> import(String config) async {
    send(ImportSshConfig(config));
    expect(await next(), isA<CatalogReplaced>());
    expect(await next(), isA<SshConfigImported>());
  }

  /// The next [LinkState] of [serverId] or [Prompt], skipping the rest.
  Future<EngineEvent> nextLinkEvent([String serverId = _web]) async {
    while (true) {
      switch (await next()) {
        case final LinkState state when state.serverId == serverId:
          return state;
        case final Prompt prompt:
          return prompt;
        default:
          continue;
      }
    }
  }

  /// The [LinkStatus] of [serverId]'s next [LinkState]; a [Prompt] fails.
  Future<LinkStatus> nextStatus([String serverId = _web]) async {
    final event = await nextLinkEvent(serverId);
    expect(event, isA<LinkState>(), reason: 'no prompt expected');
    return (event as LinkState).status;
  }

  /// Sends [Connect] for [serverId], answers its host-key prompt with
  /// [trust] and returns the prompt's request.
  Future<HostKeyPromptRequest> connectAnswering(
    bool trust, [
    String serverId = _web,
  ]) async {
    send(Connect(serverId));
    expect(await nextStatus(serverId), const LinkConnecting());
    final event = await nextLinkEvent(serverId);
    expect(event, isA<Prompt>(), reason: 'a host-key prompt expected');
    final prompt = event as Prompt;
    expect(await nextStatus(serverId), isA<LinkNeedsUser>());
    send(AnswerPrompt(prompt.promptId, PromptTrustAnswer(trust)));
    return prompt.request as HostKeyPromptRequest;
  }

  /// Sends [Connect] and expects the link ready without a prompt.
  Future<void> connectSilently([String serverId = _web]) async {
    send(Connect(serverId));
    expect(await nextStatus(serverId), const LinkConnecting());
    expect(await nextStatus(serverId), const LinkAuthenticating());
    expect(await nextStatus(serverId), const LinkReady());
  }
}

/// Each file under [directory] with its bytes, by relative path.
Map<String, String> _files(Directory directory) => {
  for (final entity in directory.listSync(recursive: true))
    if (entity is File)
      entity.path.substring(directory.path.length): base64.encode(
        entity.readAsBytesSync(),
      ),
};

void main() {
  late Directory support;
  late _Server server;
  late File pinFile;

  setUp(() {
    support = Directory.systemTemp.createTempSync('klab-engine-pins-');
    server = _Server();
    pinFile = File('${support.path}${Platform.pathSeparator}$hostKeysFileName');
  });

  tearDown(() => support.deleteSync(recursive: true));

  Future<_Engine> start(SupportDirectoryAccess access) =>
      _Engine.start(support, server, access: access);

  /// Pins web's key through an engine that holds the directory alone.
  Future<void> pinWeb() async {
    final engine = await start(SupportDirectoryAccess.exclusive);
    await engine.import(_webConfig);
    final request = await engine.connectAnswering(true);
    expect(request.pinnedFingerprintSha256, isNull, reason: 'first seen');
    expect(await engine.nextStatus(), const LinkAuthenticating());
    expect(await engine.nextStatus(), const LinkReady());
  }

  List<String> pinnedFingerprints() => [
    for (final json in jsonDecode(pinFile.readAsStringSync()) as List)
      (json as Map)['fingerprintSha256'] as String,
  ];

  group('with the support directory to itself, the engine', () {
    test('keeps pins in host_keys.json, which outlive the engine', () async {
      await pinWeb();
      expect(pinnedFingerprints(), ['SHA256:first']);

      // The restarted engine reads the saved import and the pin: no prompt.
      final restarted = await start(SupportDirectoryAccess.exclusive);
      await restarted.connectSilently();
    });

    test('still blocks a changed key after a restart, and the next Connect '
        'reviews it: trusting it re-pins for the next run', () async {
      await pinWeb();
      server.rekey();

      final restarted = await start(SupportDirectoryAccess.exclusive);
      restarted.send(const Connect(_web));
      expect(await restarted.nextStatus(), const LinkConnecting());
      expect(await restarted.nextStatus(), _blocked);

      final request = await restarted.connectAnswering(true);
      expect(
        (
          request.keyType,
          request.fingerprintSha256,
          request.pinnedKeyType,
          request.pinnedFingerprintSha256,
        ),
        (
          'ecdsa-sha2-nistp256',
          'SHA256:rekeyed',
          'ssh-ed25519',
          'SHA256:first',
        ),
      );
      expect(await restarted.nextStatus(), const LinkAuthenticating());
      expect(await restarted.nextStatus(), const LinkReady());
      expect(pinnedFingerprints(), ['SHA256:rekeyed']);

      final again = await start(SupportDirectoryAccess.exclusive);
      await again.connectSilently();
    });

    test('a declined review blocks again and keeps the old pin', () async {
      await pinWeb();
      server.rekey();

      final restarted = await start(SupportDirectoryAccess.exclusive);
      restarted.send(const Connect(_web));
      expect(await restarted.nextStatus(), const LinkConnecting());
      expect(await restarted.nextStatus(), _blocked);

      await restarted.connectAnswering(false);
      expect(await restarted.nextStatus(), _blocked);
      expect(pinnedFingerprints(), ['SHA256:first']);
    });

    test('never asks about a changed key on a background reconnect', () async {
      final engine = await start(SupportDirectoryAccess.exclusive);
      await engine.import(_webConfig);
      await engine.connectAnswering(true);
      expect(await engine.nextStatus(), const LinkAuthenticating());
      expect(await engine.nextStatus(), const LinkReady());

      // The server is rekeyed and the link drops: the supervisor backs
      // off and redials unattended, which blocks without a prompt.
      server.rekey();
      server.links.single.lose();
      expect(
        await engine.nextStatus(),
        const LinkClosed(LinkClosedReason.linkLost),
      );
      expect(await engine.nextStatus(), isA<LinkBackoff>());
      expect(await engine.nextStatus(), const LinkConnecting());
      expect(await engine.nextStatus(), _blocked);
      expect(pinnedFingerprints(), ['SHA256:first']);
    });
  });

  group('without the instance lock, the engine', () {
    test('reads the pins but writes nothing: a pin, a re-pin and a damaged '
        'file all stay in memory', () async {
      await pinWeb();
      // A second server, saved by the import, to pin anew below.
      final writer = await start(SupportDirectoryAccess.exclusive);
      await writer.import('$_webConfig$_otherConfig');
      server.rekey();
      final before = _files(support);

      final engine = await start(SupportDirectoryAccess.unguarded);
      // The saved pin is read: the changed key blocks.
      engine.send(const Connect(_web));
      expect(await engine.nextStatus(), const LinkConnecting());
      expect(await engine.nextStatus(), _blocked);
      // The re-pin holds for this run only.
      await engine.connectAnswering(true);
      expect(await engine.nextStatus(), const LinkAuthenticating());
      expect(await engine.nextStatus(), const LinkReady());
      engine.send(const Disconnect(_web));
      expect(
        await engine.nextStatus(),
        const LinkClosed(LinkClosedReason.closedByOwner),
      );
      await engine.connectSilently();
      // So does a first-seen pin.
      await engine.connectAnswering(true, 'ssh-config:other');
      expect(
        await engine.nextStatus('ssh-config:other'),
        const LinkAuthenticating(),
      );
      expect(await engine.nextStatus('ssh-config:other'), const LinkReady());

      expect(_files(support), before);
      expect(pinnedFingerprints(), ['SHA256:first']);
    });

    test('starts empty over a damaged file and leaves it in place', () async {
      final writer = await start(SupportDirectoryAccess.exclusive);
      await writer.import(_webConfig);
      pinFile.writeAsStringSync('[{"host": ');
      final before = _files(support);

      final engine = await start(SupportDirectoryAccess.unguarded);
      final request = await engine.connectAnswering(true);
      expect(request.pinnedFingerprintSha256, isNull, reason: 'first seen');
      expect(await engine.nextStatus(), const LinkAuthenticating());
      expect(await engine.nextStatus(), const LinkReady());

      expect(_files(support), before, reason: 'not quarantined');
    });
  });

  test('a Connect to a fleet server without a config says why (D61)', () async {
    // A schema 1 store kept addresses only, so the engine maps no config
    // until the next import.
    File(
      '${support.path}${Platform.pathSeparator}$sshConfigImportsFileName',
    ).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'entries': [
          {'alias': 'web', 'host': '192.0.2.10', 'port': 22, 'user': 'me'},
        ],
      }),
    );
    final engine = await start(SupportDirectoryAccess.exclusive);

    engine.send(const Connect(_web));
    final rejected = await engine.next() as ConnectRejected;
    expect(
      (rejected.serverId, rejected.reason),
      (_web, ConnectRejectedReason.addressOnlyImport),
    );
    expect(server.links, isEmpty);

    // An id outside the fleet is no server the app lists.
    engine.send(const Connect('ssh-config:gone'));
    expect((await engine.next() as RequestRejected).requestName, 'Connect');
  });
}
