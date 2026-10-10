// The algorithm proposal every SSH client in this package sends: what 3.0.2
// negotiated with every server, plus chacha20-poly1305 (see
// `suiteSshAlgorithms` for the reasoning).
//
// The lists are pinned by wire name rather than compared to the definition:
// a re-pin that moves dartssh2's defaults must fail here and be looked at,
// not change the proposal silently.
import 'dart:async';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_kex.dart';
// The extension dartssh2 itself builds KEXINIT name-lists with.
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_algorithm.dart' show SSHAlgorithmList;
import 'package:seance_core/seance_core.dart';
import 'package:seance_core/src/ssh/ssh_algorithms.dart';
import 'package:test/test.dart';

// dartssh2 4.1.0's own defaults, in its order (`SSHAlgorithms` in
// lib/src/ssh_algorithm.dart).
const _defaultKex = [
  'curve25519-sha256',
  'curve25519-sha256@libssh.org',
  'ecdh-sha2-nistp521',
  'ecdh-sha2-nistp384',
  'ecdh-sha2-nistp256',
  'diffie-hellman-group-exchange-sha256',
  'diffie-hellman-group14-sha256',
];
const _defaultHostkey = [
  'ssh-ed25519',
  'rsa-sha2-512',
  'rsa-sha2-256',
  'ecdsa-sha2-nistp521',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp256',
];
const _defaultCipher = [
  'aes256-gcm@openssh.com',
  'aes128-gcm@openssh.com',
  'chacha20-poly1305@openssh.com',
  'aes256-ctr',
  'aes128-ctr',
];
const _defaultMac = [
  'hmac-sha2-256-etm@openssh.com',
  'hmac-sha2-512-etm@openssh.com',
  'hmac-sha2-256',
  'hmac-sha2-512',
  'hmac-sha1',
];

// What the suite proposes (owner decisions on the dartssh2 4.1.0 re-pin).
// Key exchange: the defaults, then the two SHA-1 exchanges 4.0.0 dropped.
const _suiteKex = [
  ..._defaultKex,
  'diffie-hellman-group14-sha1',
  'diffie-hellman-group-exchange-sha1',
];
// Host keys: 3.0.2's order, ssh-rsa before ECDSA, so an old server keeps
// presenting the RSA key its users pinned.
const _suiteHostkey = [
  'ssh-ed25519',
  'rsa-sha2-512',
  'rsa-sha2-256',
  'ssh-rsa',
  'ecdsa-sha2-nistp521',
  'ecdsa-sha2-nistp384',
  'ecdsa-sha2-nistp256',
];
// Ciphers: AES-CTR first as under 3.0.2 (dartssh2's AES-GCM is pure Dart and
// slow), then chacha20-poly1305, AES-GCM, and the CBC ciphers 4.0.0 dropped.
const _suiteCipher = [
  'aes128-ctr',
  'aes256-ctr',
  'chacha20-poly1305@openssh.com',
  'aes256-gcm@openssh.com',
  'aes128-gcm@openssh.com',
  'aes256-cbc',
  'aes128-cbc',
];
// The legacy entries 4.0.0 removed from the defaults.
const _legacyFallback = [
  'diffie-hellman-group14-sha1',
  'diffie-hellman-group-exchange-sha1',
  'ssh-rsa',
  'aes256-cbc',
  'aes128-cbc',
];

// What 3.1.0 removed from the defaults as broken. None of it comes back.
const _brokenIn310 = [
  'diffie-hellman-group1-sha1',
  'hmac-md5',
  'hmac-sha2-256-96',
  'hmac-sha2-512-96',
];

const _lineFeed = 0x0a;

ServerConfig _server() => ServerConfig(
  id: 's',
  label: 's',
  host: 'legacy.example.com',
  port: 22,
  username: 'me',
  authMethod: AuthMethod.password,
  createdAt: 0,
  updatedAt: 0,
);

/// Records what the client writes and hangs up once its KEXINIT is complete.
///
/// The client sends its identification line and KEXINIT the moment it is
/// constructed, before reading anything (RFC 4253 §4.2, §7.1), so nothing has
/// to be answered for the proposal to be on the wire.
class _KexInitCaptureSocket implements SSHSocket {
  _KexInitCaptureSocket() {
    _outgoing.stream.listen((bytes) {
      _written.addAll(bytes);
      final kexInit = _clientKexInit(_written);
      if (kexInit == null || kexInitSent.isCompleted) return;

      kexInitSent.complete(kexInit);
      unawaited(close());
    });
  }

  final kexInitSent = Completer<SSH_Message_KexInit>();

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();
  final _written = <int>[];

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (_done.isCompleted) return;

    _done.complete();
    await _incoming.close();
  }

  @override
  void destroy() => unawaited(close());

  @override
  Future<void> flush() async {}
}

/// The client's first packet, once it has arrived whole: the identification
/// line, then an unencrypted binary packet (RFC 4253 §6) holding KEXINIT.
SSH_Message_KexInit? _clientKexInit(List<int> written) {
  final versionEnd = written.indexOf(_lineFeed) + 1;
  if (versionEnd == 0 || written.length < versionEnd + 5) return null;

  final packet = Uint8List.fromList(written.sublist(versionEnd));
  final packetLength = ByteData.sublistView(packet).getUint32(0);
  if (packet.length < 4 + packetLength) return null;

  final padding = packet[4];
  return SSH_Message_KexInit.decode(
    Uint8List.sublistView(packet, 5, 4 + packetLength - padding),
  );
}

void main() {
  group('suiteSshAlgorithms', () {
    final algorithms = suiteSshAlgorithms;

    test('proposes exactly the suite lists', () {
      expect(algorithms.kex.toNameList(), _suiteKex);
      expect(algorithms.hostkey.toNameList(), _suiteHostkey);
      expect(algorithms.cipher.toNameList(), _suiteCipher);
      // MACs need no fallback: hmac-sha1 is still in the defaults.
      expect(algorithms.mac.toNameList(), _defaultMac);
    });

    test('the pinned dartssh2 defaults are what the lists assume', () {
      // Ties the literal lists above to the dependency: if this fails, a
      // re-pin moved the defaults and the suite lists need a decision.
      const defaults = SSHAlgorithms();
      expect(defaults.kex.toNameList(), _defaultKex);
      expect(defaults.hostkey.toNameList(), _defaultHostkey);
      expect(defaults.cipher.toNameList(), _defaultCipher);
      expect(defaults.mac.toNameList(), _defaultMac);
    });

    test('keeps every default and adds only the 4.0.0 removals', () {
      // Reordering is deliberate; dropping a default or adding anything
      // else is not.
      for (final (proposed, defaults) in [
        (_suiteKex, _defaultKex),
        (_suiteHostkey, _defaultHostkey),
        (_suiteCipher, _defaultCipher),
      ]) {
        expect(proposed.toSet().containsAll(defaults), isTrue);
        expect(
          proposed.where((name) => !defaults.contains(name)),
          everyElement(isIn(_legacyFallback)),
        );
        expect(proposed.toSet(), hasLength(proposed.length));
      }
    });

    test('legacy key exchanges come after every modern one', () {
      final kex = algorithms.kex.toNameList();
      expect(kex.sublist(kex.length - 2), [
        'diffie-hellman-group14-sha1',
        'diffie-hellman-group-exchange-sha1',
      ]);
    });

    test('re-adds nothing 3.1.0 removed as broken', () {
      final proposed = [
        ...algorithms.kex.toNameList(),
        ...algorithms.hostkey.toNameList(),
        ...algorithms.cipher.toNameList(),
        ...algorithms.mac.toNameList(),
      ];
      for (final broken in _brokenIn310) {
        expect(proposed, isNot(contains(broken)), reason: broken);
      }
    });

    test('cannot be edited by a consumer', () {
      // Shared by every client in two products; an add() in one would
      // change the proposal of all of them.
      expect(
        () => algorithms.kex.add(SSHKexType.dh1Sha1),
        throwsUnsupportedError,
      );
      expect(
        () => algorithms.cipher.add(SSHCipherType.aes192cbc),
        throwsUnsupportedError,
      );
      expect(
        () => algorithms.hostkey.add(SSHHostkeyType.rsaSha1),
        throwsUnsupportedError,
      );
    });
  });

  test('openAuthenticatedClient sends that proposal on the wire', () async {
    // The one SSHClient this package builds, which also authenticates every
    // ProxyJump hop. Read back from the client's actual KEXINIT rather than
    // from the constructor argument, so a client built without it fails here.
    final socket = _KexInitCaptureSocket();

    await expectLater(
      openAuthenticatedClient(
        config: _server(),
        credentials: const SshCredentials.password('pw'),
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => true,
        connect: (host, port, timeout) async => socket,
        log: SshConnectionLog(),
      ),
      throwsA(isA<SshConnectException>()),
    );

    final kexInit = await socket.kexInitSent.future;
    final expected = suiteSshAlgorithms;
    expect(kexInit.kexAlgorithms, [
      ...expected.kex.toNameList(),
      // Appended by dartssh2 to the first KEXINIT, after the real methods.
      SSHKexPseudoAlgorithm.strictKexClient,
      SSHKexPseudoAlgorithm.extInfoClient,
    ]);
    expect(kexInit.serverHostKeyAlgorithms, expected.hostkey.toNameList());
    expect(kexInit.encryptionClientToServer, expected.cipher.toNameList());
    expect(kexInit.encryptionServerToClient, expected.cipher.toNameList());
    expect(kexInit.macClientToServer, expected.mac.toNameList());
    expect(kexInit.macServerToClient, expected.mac.toNameList());
  });
}
