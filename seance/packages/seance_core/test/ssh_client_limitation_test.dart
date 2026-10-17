// 03 §5.3's client limitations, classified from the server's first KEXINIT.
//
// Every server here is a scripted transcript: the KEXINIT is built byte by
// byte below, not with dartssh2's encoder, so the tap is checked against
// RFC 4253's layout rather than against the library it watches.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/ssh/server_kex_init.dart';
import 'package:seance_core/src/ssh/ssh_algorithms.dart';
import 'package:test/test.dart';

import 'support/ssh_peer.dart';

const _identification = 'SSH-2.0-OpenSSH_9.6\r\n';
const _disconnectId = 1;
const _ignoreId = 2;
const _kexInitId = 20;
const _newKeysId = 21;
const _kexDhReplyId = 31;
const _strictKexServer = 'kex-strict-s-v00@openssh.com';
const _maxPacketLength = 35000;

const _curve = 'curve25519-sha256';
const _group14 = 'diffie-hellman-group14-sha256';
const _groupExchange = 'diffie-hellman-group-exchange-sha256';
const _ed25519 = 'ssh-ed25519';
const _aesCtr = 'aes128-ctr';
const _chacha = 'chacha20-poly1305@openssh.com';
const _etm = 'hmac-sha2-256-etm@openssh.com';

/// Algorithms nothing in dartssh2 4.1.0 implements.
const _mlKem = 'mlkem768x25519-sha256';
const _sntrup = 'sntrup761x25519-sha512@openssh.com';
const _dss = 'ssh-dss';
const _tripleDes = '3des-cbc';
const _umac = 'umac-64@openssh.com';

/// What the suite refuses as insecure (`suiteRefusedSshAlgorithms`).
const _group1 = 'diffie-hellman-group1-sha1';
const _md5 = 'hmac-md5';
const _sha256Truncated = 'hmac-sha2-256-96';
const _sha512Truncated = 'hmac-sha2-512-96';

ServerConfig _server() => ServerConfig(
  id: 's',
  label: 's',
  host: 'limited.example.com',
  port: 22,
  username: 'me',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

const _target = 'me@limited.example.com:22';

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

/// An RFC 4251 §5 string.
List<int> _string(String value) {
  final bytes = latin1.encode(value);
  return [..._uint32(bytes.length), ...bytes];
}

List<int> _nameList(List<String> names) => _string(names.join(','));

/// A KEXINIT payload as RFC 4253 §7.1 lays it out: message number, cookie,
/// ten name-lists, first_kex_packet_follows and the reserved uint32. Each
/// direction gets the same cipher and MAC list unless told otherwise.
Uint8List _kexInit({
  List<String> kex = const [_curve, _strictKexServer],
  List<String> hostKey = const [_ed25519],
  List<String> cipher = const [_aesCtr, _chacha],
  List<String>? cipherServerToClient,
  List<String> mac = const [_etm],
  List<String>? macServerToClient,
}) => Uint8List.fromList([
  _kexInitId,
  ...List.filled(16, 0x5a),
  ..._nameList(kex),
  ..._nameList(hostKey),
  ..._nameList(cipher),
  ..._nameList(cipherServerToClient ?? cipher),
  ..._nameList(mac),
  ..._nameList(macServerToClient ?? mac),
  ..._nameList(const ['none']),
  ..._nameList(const ['none']),
  ..._nameList(const []),
  ..._nameList(const []),
  0,
  ..._uint32(0),
]);

/// An unencrypted binary packet (RFC 4253 §6) aligned to 8 bytes, with
/// [padding] in place of the computed length when given.
Uint8List _packet(List<int> payload, {int? padding}) {
  var aligned = 8 - (5 + payload.length) % 8;
  if (aligned < 4) aligned += 8;
  final paddingLength = padding ?? aligned;
  return Uint8List.fromList([
    ..._uint32(1 + payload.length + paddingLength),
    paddingLength,
    ...payload,
    ...List.filled(paddingLength, 0),
  ]);
}

Uint8List _ignorePacket() => _packet([_ignoreId, ..._uint32(3), 1, 2, 3]);

Uint8List _disconnectPacket() => _packet([
  _disconnectId,
  ..._uint32(2), // SSH_DISCONNECT_PROTOCOL_ERROR
  ..._string('bad packet'),
  ..._string(''), // language tag
]);

/// The start of a server's stream: its identification line, then [kexInit]
/// as a packet.
List<int> _greeting(Uint8List kexInit) => [
  ...latin1.encode(_identification),
  ..._packet(kexInit),
];

/// What the scripted server does once the client has written.
enum _Then { stayOpen, hangUp, reset, disconnect }

/// Sends [script] the moment it is connected, then does as [then] says when
/// the client's first bytes arrive, which is during the key exchange: the
/// client writes its identification line and KEXINIT before reading
/// anything (RFC 4253 §4.2, §7.1).
final class _ScriptedServer implements SSHSocket {
  _ScriptedServer(List<int> script, {this.then = _Then.stayOpen}) {
    _outgoing.stream.listen((_) => _clientWrote());
    _incoming.add(Uint8List.fromList(script));
  }

  final _Then then;
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();
  var _answered = false;

  void _clientWrote() {
    if (_answered || _incoming.isClosed) return;
    _answered = true;
    switch (then) {
      case _Then.stayOpen:
        return;
      case _Then.hangUp:
        unawaited(_incoming.close());
      case _Then.reset:
        _incoming.addError(const SocketException('Connection reset by peer'));
        unawaited(_incoming.close());
      case _Then.disconnect:
        _incoming.add(_disconnectPacket());
        unawaited(_incoming.close());
    }
  }

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() {
    if (!_done.isCompleted) _done.complete();
    if (!_incoming.isClosed) unawaited(_incoming.close());
    unawaited(_outgoing.close());
    return done;
  }

  @override
  void destroy() => unawaited(close());

  @override
  Future<void> flush() async {}

  @override
  String toString() => 'scripted server';
}

Future<SshConnectException> _connectFailure(
  SSHSocket socket, {
  SshConnectionLog? log,
  HostKeyPrompter? onHostKey,
}) async {
  try {
    await openAuthenticatedClient(
      config: _server(),
      credentials: const SshCredentials.password('pw'),
      tofu: TofuVerifier(InMemoryHostKeyStore()),
      onHostKey: onHostKey ?? (_) async => true,
      connect: (host, port, timeout) async => socket,
      keepAliveInterval: null,
      log: log,
    );
  } on SshConnectException catch (e) {
    return e;
  }
  fail('the connection was expected to fail');
}

Matcher _ofKind(SshConnectFailureKind kind) =>
    isA<SshConnectException>().having((e) => e.kind, 'kind', kind);

/// The failure dartssh2 itself reports for a KEXINIT it shares nothing
/// with: proof that the transcript reached its check, not only the tap.
Matcher _dartssh2NoMatching(String part) => isA<SshConnectException>()
    .having((e) => e.cause, 'cause', isA<SSHAuthAbortError>())
    .having(
      (e) => '${(e.cause as SSHAuthAbortError).reason}',
      'dartssh2 reason',
      contains('No matching $part algorithm'),
    );

/// A fake connection whose server sends [chunks], observed by [tap].
/// Returns the tap's offer and every chunk the observed stream delivered.
Future<(ServerKexInit?, List<Uint8List>)> _tapRead(
  List<List<int>> chunks, {
  ServerKexTap? tap,
}) async {
  final incoming = StreamController<Uint8List>();
  tap ??= ServerKexTap();
  final observed = tap.observe(_StreamSocket(incoming.stream));
  final delivered = <Uint8List>[];
  final finished = observed.stream.forEach(delivered.add);
  for (final chunk in chunks) {
    incoming.add(Uint8List.fromList(chunk));
  }
  await incoming.close();
  await finished;
  return (tap.serverKexInit, delivered);
}

/// [chunks] joined and cut into single bytes, the worst split a TCP stream
/// can deliver.
List<List<int>> _byteByByte(List<List<int>> chunks) => [
  for (final chunk in chunks)
    for (final byte in chunk) [byte],
];

final class _StreamSocket implements SSHSocket {
  _StreamSocket(this.stream);

  @override
  final Stream<Uint8List> stream;

  @override
  final StreamSink<List<int>> sink = StreamController<List<int>>().sink;

  var closed = 0;
  var destroyed = 0;
  var flushed = 0;
  final doneCompleter = Completer<void>();

  @override
  Future<void> get done => doneCompleter.future;

  @override
  Future<void> close() async => closed++;

  @override
  void destroy() => destroyed++;

  @override
  Future<void> flush() async => flushed++;

  @override
  String toString() => 'the wrapped socket';
}

void main() {
  group('ServerKexTap', () {
    test('reads the offer however the stream is split', () async {
      final kexInit = _kexInit(
        kex: const [_curve, _group14, _strictKexServer],
        cipher: const [_chacha, _aesCtr],
        macServerToClient: const [_md5],
      );
      final stream = [
        // RFC 4253 §4.2: lines before the identification, LF-only too.
        ...latin1.encode('Authorized use only\r\nno CR here\n'),
        ...latin1.encode(_identification),
        // SSH_MSG_IGNORE may come before the KEXINIT.
        ..._ignorePacket(),
        ..._packet(kexInit),
        // The rest of the exchange is skipped up to NEWKEYS, and what
        // follows it, encrypted, is not read: no DISCONNECT counts there.
        ..._packet([_kexDhReplyId, ...List.filled(300, 7)]),
        ..._packet(const [_newKeysId]),
        ..._disconnectPacket(),
      ];

      for (final chunks in [
        [stream],
        _byteByByte([stream]),
      ]) {
        final tap = ServerKexTap();
        final (offer, _) = await _tapRead(chunks, tap: tap);
        expect(tap.serverDisconnected, isFalse);
        expect(offer, isNotNull);
        expect(offer!.kex, [_curve, _group14, _strictKexServer]);
        expect(offer.hostKey, [_ed25519]);
        expect(offer.cipherClientToServer, [_chacha, _aesCtr]);
        expect(offer.cipherServerToClient, [_chacha, _aesCtr]);
        expect(offer.macClientToServer, [_etm]);
        expect(offer.macServerToClient, [_md5]);
      }
    });

    test('notes a DISCONNECT before NEWKEYS', () async {
      for (final stream in [
        [..._greeting(_kexInit()), ..._disconnectPacket()],
        [...latin1.encode(_identification), ..._disconnectPacket()],
      ]) {
        final tap = ServerKexTap();
        await _tapRead([stream], tap: tap);
        expect(tap.serverDisconnected, isTrue);
      }
    });

    test('hands every chunk through unchanged and in order', () async {
      final chunks = [
        latin1.encode(_identification),
        _packet(_kexInit()),
        [0xde, 0xad, 0xbe, 0xef],
      ];
      final incoming = StreamController<Uint8List>();
      final wrapped = _StreamSocket(incoming.stream);
      final observed = ServerKexTap().observe(wrapped);
      final events = <Object>[];
      final finished = Completer<void>();
      observed.stream.listen(
        events.add,
        onError: (Object error) => events.add('error: $error'),
        onDone: finished.complete,
      );

      final sent = [for (final chunk in chunks) Uint8List.fromList(chunk)];
      incoming.add(sent[0]);
      incoming.addError(StateError('socket trouble'));
      incoming.add(sent[1]);
      incoming.add(sent[2]);
      await incoming.close();
      await finished.future;

      expect(events, hasLength(4));
      expect(identical(events[0], sent[0]), isTrue);
      expect(events[1], 'error: Bad state: socket trouble');
      expect(identical(events[2], sent[1]), isTrue);
      expect(identical(events[3], sent[2]), isTrue);

      // Everything else belongs to the wrapped socket.
      expect(identical(observed.sink, wrapped.sink), isTrue);
      expect(identical(observed.done, wrapped.done), isTrue);
      await observed.flush();
      await observed.close();
      observed.destroy();
      expect((wrapped.flushed, wrapped.closed, wrapped.destroyed), (1, 1, 1));
      expect('$observed', 'the wrapped socket');
    });

    group('stops with no offer, and never throws, on', () {
      final kexInit = _kexInit(kex: const [_mlKem]);
      final valid = _packet(kexInit);
      final identification = latin1.encode(_identification);

      Uint8List withLength(Uint8List packet, int packetLength) =>
          Uint8List.fromList(packet)
            ..buffer.asByteData().setUint32(0, packetLength);

      final cases = <String, List<int>>{
        'a name-list longer than the payload': [
          ...identification,
          ..._packet(
            Uint8List.fromList(kexInit)
              ..buffer.asByteData().setUint32(17, 0x7fffffff),
          ),
        ],
        'a KEXINIT cut before its reserved field': [
          ...identification,
          ..._packet(Uint8List.sublistView(kexInit, 0, kexInit.length - 3)),
        ],
        'a packet longer than RFC 4253 allows': [
          ...identification,
          ...withLength(valid, _maxPacketLength + 1),
          ...List.filled(_maxPacketLength + 8, 0),
        ],
        'a packet too short to hold padding': [
          ...identification,
          ...withLength(valid, 4),
        ],
        'padding that leaves no payload': [
          ...identification,
          ..._uint32(12),
          11,
          ...List.filled(11, _kexInitId),
        ],
        'padding below the aligned minimum': [
          ...identification,
          ..._packet(kexInit, padding: 2),
        ],
        'an identification line past the buffer limit': [
          ...latin1.encode('SSH-2.0-'),
          ...List.filled(_maxPacketLength + 8, 0x41),
          ...latin1.encode('\r\n'),
          ...valid,
        ],
        'an SSH 1 identification': [
          ...latin1.encode('SSH-1.5-ancient\r\n'),
          ...valid,
        ],
        'more than 1024 lines before the identification': [
          for (var i = 0; i < 1025; i++) ...latin1.encode('banner\r\n'),
          ...identification,
          ...valid,
        ],
        'random bytes': [
          ...identification,
          ...() {
            final random = Random(7);
            return List.generate(4096, (_) => random.nextInt(256));
          }(),
        ],
      };

      for (final MapEntry(key: name, value: stream) in cases.entries) {
        test(name, () async {
          for (final chunks in [
            [stream],
            _byteByByte([stream]),
          ]) {
            final (offer, delivered) = await _tapRead(chunks);
            expect(offer, isNull);
            expect(delivered.expand((chunk) => chunk), stream);
          }
        });
      }

      test('a stream that ends mid-packet', () async {
        final (offer, _) = await _tapRead([
          [...identification, ...valid.sublist(0, valid.length - 1)],
        ]);
        expect(offer, isNull);
      });
    });
  });

  group('ServerKexInit', () {
    ServerKexInit offer(Uint8List kexInit) => ServerKexInit.decode(kexInit)!;

    test('negotiates key exchange in the client order', () {
      final server = offer(_kexInit(kex: const [_group14, _curve]));
      expect(server.negotiatedKex(suiteSshAlgorithms), SSHKexType.x25519Rfc);
      expect(
        offer(_kexInit(kex: const [_mlKem])).negotiatedKex(suiteSshAlgorithms),
        isNull,
      );
    });

    test('shares everything with a modern server', () {
      expect(offer(_kexInit()).unshared(suiteSshAlgorithms), isEmpty);
    });

    test('names each part with no common algorithm', () {
      expect(
        offer(
          _kexInit(kex: const [_mlKem], cipher: const [_tripleDes]),
        ).unshared(suiteSshAlgorithms),
        {SshAlgorithmCategory.keyExchange, SshAlgorithmCategory.cipher},
      );
      expect(
        offer(_kexInit(hostKey: const [_dss])).unshared(suiteSshAlgorithms),
        {SshAlgorithmCategory.hostKey},
      );
      expect(
        offer(
          _kexInit(cipherServerToClient: const [_tripleDes]),
        ).unshared(suiteSshAlgorithms),
        {SshAlgorithmCategory.cipher},
      );
    });

    test('needs a MAC only beside a cipher that is not AEAD', () {
      // chacha20-poly1305 authenticates itself.
      expect(
        offer(
          _kexInit(cipher: const [_chacha], mac: const []),
        ).unshared(suiteSshAlgorithms),
        isEmpty,
      );
      // The suite ranks AES-CTR first, so dartssh2 picks it and then needs
      // a MAC, even though the server offers chacha20-poly1305 too.
      expect(
        offer(
          _kexInit(
            cipher: const [_chacha, _aesCtr],
            macServerToClient: [_umac],
          ),
        ).unshared(suiteSshAlgorithms),
        {SshAlgorithmCategory.mac},
      );
    });
  });

  group('client limitations', () {
    final unsupported = <String, (Uint8List, String, String)>{
      'key exchange': (
        _kexInit(kex: const [_mlKem, _sntrup, _strictKexServer]),
        'key exchange',
        'key exchange',
      ),
      'host key': (_kexInit(hostKey: const [_dss]), 'host key', 'host key'),
      'cipher': (
        _kexInit(cipher: const [_tripleDes]),
        'client cipher',
        'cipher',
      ),
      'MAC': (
        _kexInit(cipher: const [_aesCtr], mac: const [_umac]),
        'client MAC',
        'MAC',
      ),
    };
    for (final MapEntry(key: name, value: (kexInit, dartssh2Part, phrase))
        in unsupported.entries) {
      test('no common $name algorithm is unsupportedAlgorithm', () async {
        final log = SshConnectionLog();
        final failure = await _connectFailure(
          _ScriptedServer(_greeting(kexInit)),
          log: log,
        );

        expect(failure, _ofKind(SshConnectFailureKind.unsupportedAlgorithm));
        expect(failure, _dartssh2NoMatching(dartssh2Part));
        expect(
          failure.message,
          'Could not agree on SSH algorithms with $_target: the server '
          'requires a $phrase algorithm this client does not support.',
        );
        expect(log.lines, contains(failure.message));
      });
    }

    test('several missing parts are named together', () async {
      final failure = await _connectFailure(
        _ScriptedServer(
          _greeting(
            _kexInit(
              kex: const [_mlKem],
              hostKey: const [_dss],
              cipher: const [_tripleDes],
            ),
          ),
        ),
      );
      expect(failure, _ofKind(SshConnectFailureKind.unsupportedAlgorithm));
      expect(
        failure.message,
        contains('requires a key exchange, host key or cipher algorithm'),
      );
    });

    final insecure = <String, (Uint8List, String, String)>{
      'diffie-hellman-group1-sha1': (
        _kexInit(kex: const [_group1]),
        'key exchange',
        _group1,
      ),
      'hmac-md5': (
        _kexInit(cipher: const [_aesCtr], mac: const [_md5]),
        'client MAC',
        _md5,
      ),
      'the truncated SHA-2 MACs': (
        _kexInit(
          cipher: const [_aesCtr],
          mac: const [_sha512Truncated, _sha256Truncated],
        ),
        'client MAC',
        '$_sha256Truncated, $_sha512Truncated',
      ),
      'a refused key exchange beside one dartssh2 lacks': (
        _kexInit(kex: const [_mlKem, _group1]),
        'key exchange',
        _group1,
      ),
      'a refused key exchange and a refused MAC': (
        _kexInit(kex: const [_group1], cipher: const [_aesCtr], mac: [_md5]),
        'key exchange',
        '$_group1, $_md5',
      ),
    };
    for (final MapEntry(key: name, value: (kexInit, dartssh2Part, refused))
        in insecure.entries) {
      test('only $name is insecureAlgorithmsOnly', () async {
        final failure = await _connectFailure(
          _ScriptedServer(_greeting(kexInit)),
        );

        expect(failure, _ofKind(SshConnectFailureKind.insecureAlgorithmsOnly));
        expect(failure, _dartssh2NoMatching(dartssh2Part));
        expect(
          failure.message,
          'Could not agree on SSH algorithms with $_target: the server '
          'offers only algorithms this client refuses as insecure '
          '($refused).',
        );
      });
    }

    test('a refused algorithm does not excuse an unsupported one', () async {
      final failure = await _connectFailure(
        _ScriptedServer(
          _greeting(_kexInit(kex: const [_group1], cipher: const [_tripleDes])),
        ),
      );
      expect(failure, _ofKind(SshConnectFailureKind.unsupportedAlgorithm));
      // Only the part no refused algorithm would fix is named.
      expect(failure.message, contains('requires a cipher algorithm'));
    });

    for (final (kex, then) in [
      (_group14, _Then.hangUp),
      (_groupExchange, _Then.hangUp),
      (_group14, _Then.reset),
    ]) {
      test('$kex then a ${then.name} during key exchange is '
          'keyExchangeTimedOut', () async {
        final log = SshConnectionLog();
        final failure = await _connectFailure(
          _ScriptedServer(
            _greeting(_kexInit(kex: [_mlKem, kex, _strictKexServer])),
            then: then,
          ),
          log: log,
        );

        expect(failure, _ofKind(SshConnectFailureKind.keyExchangeTimedOut));
        expect(
          failure.message,
          'Could not finish key exchange with $_target in time. $kex is '
          'finite-field Diffie-Hellman, which can be too slow on some '
          'devices; enabling curve25519-sha256 or an ecdh-sha2 key exchange '
          'on the server avoids it.',
        );
        expect(log.lines, contains(failure.message));
      });
    }

    test('a finite-field key exchange past the deadline is '
        'keyExchangeTimedOut', () {
      fakeAsync((async) {
        // Group exchange waits for the server's group before any isolate
        // starts, so fake time controls everything here.
        final server = _ScriptedServer(
          _greeting(_kexInit(kex: const [_groupExchange])),
        );
        Object? failure;
        openAuthenticatedClient(
          config: _server(),
          credentials: const SshCredentials.password('pw'),
          tofu: TofuVerifier(InMemoryHostKeyStore()),
          onHostKey: (_) async => true,
          connect: (host, port, timeout) async => server,
          keepAliveInterval: null,
        ).then<void>(
          (_) => fail('the key exchange cannot finish'),
          onError: (Object error) => failure = error,
        );

        async.elapse(const Duration(minutes: 5, seconds: 1));
        expect(
          failure,
          isA<SshConnectException>()
              .having((e) => e.cause, 'cause', isA<TimeoutException>())
              .having(
                (e) => e.kind,
                'kind',
                SshConnectFailureKind.keyExchangeTimedOut,
              ),
        );
      });
    });

    test('a curve key exchange that ends early stays other', () async {
      final failure = await _connectFailure(
        _ScriptedServer(_greeting(_kexInit()), then: _Then.hangUp),
      );
      expect(failure, _ofKind(SshConnectFailureKind.other));
    });

    test('a server that disconnects with a reason stays other', () async {
      // dartssh2 may be computing the exchange when the DISCONNECT arrives
      // and then report only the close; the tap sees the DISCONNECT either
      // way, and group exchange, which starts no isolate yet, has dartssh2
      // read it too.
      for (final kex in [_group14, _groupExchange]) {
        final failure = await _connectFailure(
          _ScriptedServer(
            _greeting(_kexInit(kex: [kex])),
            then: _Then.disconnect,
          ),
        );
        expect(failure, _ofKind(SshConnectFailureKind.other), reason: kex);
        if (kex == _groupExchange) {
          expect(
            (failure.cause as SSHAuthAbortError).reason,
            isA<SSHDisconnectError>(),
          );
        }
      }
    });

    test(
      'a protocol error during a finite-field exchange stays other',
      () async {
        // A packet too short to be one: dartssh2 fails the transport itself,
        // which is not the server giving up on a slow client.
        final failure = await _connectFailure(
          _ScriptedServer([
            ..._greeting(_kexInit(kex: const [_groupExchange])),
            ..._uint32(4),
            ...List.filled(12, 0),
          ]),
        );
        expect(failure, _ofKind(SshConnectFailureKind.other));
        expect(
          (failure.cause as SSHAuthAbortError).reason,
          isA<SSHPacketError>(),
        );
      },
    );

    test('a hang-up while the host key prompt is open stays other', () async {
      // The exchange is computed and signed by then: the wait is the
      // user's, not the key exchange's.
      final peer = SshPeerSocket(keyExchange: SSHKexType.dh14Sha256);
      final failure = await _connectFailure(
        peer,
        onHostKey: (_) {
          peer.hangUp();
          return Completer<bool>().future;
        },
      );
      expect(failure, _ofKind(SshConnectFailureKind.other));
    });

    group('a malformed KEXINIT falls back to other', () {
      final dhOnly = _kexInit(kex: const [_group14]);
      final cases = {
        'cut before its reserved field': _greeting(
          Uint8List.sublistView(dhOnly, 0, dhOnly.length - 3),
        ),
        'in an oversized packet': [
          ...latin1.encode(_identification),
          ...(_packet(_kexInit(kex: const [_mlKem]))
            ..buffer.asByteData().setUint32(0, _maxPacketLength + 1)),
        ],
      };
      for (final MapEntry(key: name, value: script) in cases.entries) {
        test(name, () async {
          final failure = await _connectFailure(
            _ScriptedServer(script, then: _Then.hangUp),
          );
          expect(failure, _ofKind(SshConnectFailureKind.other));
        });
      }
    });

    group('a normal connection is unaffected', () {
      for (final kex in [SSHKexType.x25519Rfc, SSHKexType.dh14Sha256]) {
        test('with ${kex.name}', () async {
          final log = SshConnectionLog();
          final (client, _) = await openAuthenticatedClient(
            config: _server(),
            credentials: const SshCredentials.password('pw'),
            tofu: TofuVerifier(InMemoryHostKeyStore()),
            onHostKey: (_) async => true,
            connect: (host, port, timeout) async =>
                SshPeerSocket(keyExchange: kex),
            keepAliveInterval: null,
            log: log,
          );
          addTearDown(client.close);

          // dartssh2 names the socket in its trace; the tap keeps the name.
          expect(
            log.lines,
            contains(contains("<- Instance of 'SshPeerSocket': SSH-2.0-")),
          );
          expect(log.lines.join('\n'), isNot(contains('_TappedSocket')));
        });
      }
    });
  });
}
