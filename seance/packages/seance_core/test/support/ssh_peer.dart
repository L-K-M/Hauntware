// An in-memory SSH server for tests that need dartssh2's real client to reach
// an authenticated state. Since dartssh2 3.2.0 the client refuses any message
// but key exchange while the first exchange runs (SSH_MSG_UNIMPLEMENTED, or a
// disconnect under strict kex), so a fixture can no longer inject
// USERAUTH_SUCCESS behind a bare version line.
//
// The server half reuses dartssh2's own KEX, hash, key-derivation and cipher
// helpers, so the host-key signature and the encrypted packets are exactly the
// ones the client verifies. Those helpers are the dependency's internals: an
// internal move in a dartssh2 release breaks this file, which is the intended
// signal to revisit it.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/kex/kex_x25519.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_kex.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_kex_ecdh.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_request.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_service.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_userauth.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_kex_utils.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/utils/openssh_chacha20_poly1305.dart';

const _serverVersion = 'SSH-2.0-SeanceTestPeer';
const _userauthService = 'ssh-userauth';
const _uint32Bytes = 4;
const _paddingLengthBytes = 1;
const _packetHeaderBytes = _uint32Bytes + _paddingLengthBytes;
const _minimumPaddingBytes = 4;
const _packetBlockBytes = 8;
const _lineFeed = 0x0a;

const _kexType = SSHKexType.x25519Rfc;
const _cipherType = SSHCipherType.chacha20poly1305;

// RFC 8032 §7.1, test 1: deliberately public ed25519 test material.
const _hostKeySeed =
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60';
const _hostPublicKey =
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a';

/// How the peer answers every user-authentication request.
enum PeerAuthentication { accept, reject }

/// The client's end of an in-memory connection to a minimal SSH server.
///
/// The server sends KEXINIT as its first packet, runs curve25519-sha256 with
/// an ed25519 host key, agrees strict key exchange when the client offers it,
/// and encrypts both directions with chacha20-poly1305@openssh.com after
/// NEWKEYS. It then accepts the ssh-userauth service and answers every
/// authentication request as [authentication] says. It stops there: global
/// requests are refused like OpenSSH refuses unknown ones, and any other
/// message fails the connection instead of leaving the client waiting.
///
/// The peer never calls [close] itself: that is the client's hang-up, so a
/// subclass can count or delay it.
class SshPeerSocket implements SSHSocket {
  SshPeerSocket({this.authentication = PeerAuthentication.accept}) {
    _outgoing.stream.listen(_receive);
    _incoming.add(Uint8List.fromList(latin1.encode('$_serverVersion\r\n')));
    _send(_serverKexInit);
  }

  final PeerAuthentication authentication;

  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();
  final _done = Completer<void>();
  final _pending = <int>[];

  final _hostKey = OpenSSHEd25519KeyPair(
    _decodeHex(_hostPublicKey),
    _decodeHex('$_hostKeySeed$_hostPublicKey'),
    'seance test peer',
  );
  final _serverKexInit = SSH_Message_KexInit(
    kexAlgorithms: [_kexType.name, SSHKexPseudoAlgorithm.strictKexServer],
    serverHostKeyAlgorithms: [SSHHostkeyType.ed25519.name],
    encryptionClientToServer: [_cipherType.name],
    encryptionServerToClient: [_cipherType.name],
    // Negotiated but unused: the AEAD cipher authenticates its own packets.
    macClientToServer: [SSHMacType.hmacSha256.name],
    macServerToClient: [SSHMacType.hmacSha256.name],
    compressionClientToServer: const ['none'],
    compressionServerToClient: const ['none'],
    firstKexPacketFollows: false,
  ).encode();

  String? _clientVersion;
  Uint8List? _clientKexInit;
  var _strictKex = false;
  BigInt? _sharedSecret;
  Uint8List? _exchangeHash;
  OpenSSHChaCha20Poly1305? _encrypter;
  OpenSSHChaCha20Poly1305? _decrypter;
  var _sendSequence = 0;
  var _receiveSequence = 0;

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() {
    if (_done.isCompleted) return done;

    _done.complete();
    unawaited(_incoming.close());
    unawaited(_outgoing.close());
    return done;
  }

  @override
  void destroy() => unawaited(close());

  @override
  Future<void> flush() async {}

  void _receive(List<int> bytes) {
    // Writes queued before the hang-up still drain here; nobody is listening.
    if (_incoming.isClosed) return;

    try {
      _pending.addAll(bytes);
      if (_clientVersion == null && !_readClientVersion()) return;

      // Stream chunks need not align with SSH packets.
      while (true) {
        final payload = _nextPayload();
        if (payload == null) return;

        _receiveSequence++;
        _handle(payload);
      }
    } on Object catch (error, stackTrace) {
      // Fail the client's transport with the cause rather than hang it.
      _incoming.addError(error, stackTrace);
      unawaited(_incoming.close());
    }
  }

  bool _readClientVersion() {
    final lineEnd = _pending.indexOf(_lineFeed);
    if (lineEnd < 0) return false;

    _clientVersion = latin1.decode(_pending.sublist(0, lineEnd)).trimRight();
    _pending.removeRange(0, lineEnd + 1);
    return true;
  }

  Uint8List? _nextPayload() {
    if (_pending.length < _uint32Bytes) return null;

    final decrypter = _decrypter;
    final header = Uint8List.fromList(_pending.sublist(0, _uint32Bytes));
    final packetLength = decrypter == null
        ? ByteData.sublistView(header).getUint32(0)
        : decrypter.decryptPacketLength(header, _receiveSequence);
    final end = decrypter == null
        ? _uint32Bytes + packetLength
        : _uint32Bytes + packetLength + OpenSSHChaCha20Poly1305.tagSize;
    if (_pending.length < end) return null;

    final wire = Uint8List.fromList(_pending.sublist(0, end));
    _pending.removeRange(0, end);
    final packet = decrypter == null
        ? wire
        : decrypter.decryptPacket(wire, _receiveSequence);
    final padding = packet[_uint32Bytes];
    return Uint8List.sublistView(
      packet,
      _packetHeaderBytes,
      packet.length - padding,
    );
  }

  void _handle(Uint8List payload) {
    switch (payload.first) {
      case SSH_Message_KexInit.messageId:
        _clientKexInit = payload;
        _strictKex = SSH_Message_KexInit.decode(
          payload,
        ).kexAlgorithms.contains(SSHKexPseudoAlgorithm.strictKexClient);
      case SSH_Message_KexECDH_Init.messageId:
        _replyToKeyExchange(
          SSH_Message_KexECDH_Init.decode(payload).ecdhPublicKey,
        );
      case SSH_Message_NewKeys.messageId:
        _decrypter = OpenSSHChaCha20Poly1305(
          _deriveKey(SSHDeriveKeyType.clientKey),
        );
        if (_strictKex) _receiveSequence = 0;
      case SSH_Message_Service_Request.messageId:
        _requireEncryption(payload);
        final service = SSH_Message_Service_Request.decode(payload);
        if (service.serviceName != _userauthService) {
          throw StateError('Unexpected service ${service.serviceName}.');
        }
        _send(SSH_Message_Service_Accept(_userauthService).encode());
      case SSH_Message_Userauth_Request.messageId:
        _requireEncryption(payload);
        final reply = switch (authentication) {
          PeerAuthentication.accept => SSH_Message_Userauth_Success(),
          PeerAuthentication.reject => SSH_Message_Userauth_Failure(
            methodsLeft: const ['password'],
          ),
        };
        _send(reply.encode());
      case SSH_Message_Global_Request.messageId:
        if (SSH_Message_Global_Request.decode(payload).wantReply) {
          _send(SSH_Message_Request_Failure().encode());
        }
      default:
        throw StateError('The test peer has no reply for ${payload.first}.');
    }
  }

  void _replyToKeyExchange(Uint8List clientPublicKey) {
    final keyExchange = SSHKexX25519();
    final hostKey = _hostKey.toPublicKey().encode();
    final sharedSecret = keyExchange.computeSecret(clientPublicKey);
    final exchangeHash = SSHKexUtils.computeExchangeHash(
      digest: _kexType.createDigest(),
      clientVersion: _clientVersion!,
      serverVersion: _serverVersion,
      clientKexInit: _clientKexInit!,
      serverKexInit: _serverKexInit,
      hostKey: hostKey,
      clientPublicKey: clientPublicKey,
      serverPublicKey: keyExchange.publicKey,
      sharedSecret: sharedSecret,
    );
    _sharedSecret = sharedSecret;
    _exchangeHash = exchangeHash;

    _send(
      SSH_Message_KexECDH_Reply(
        hostPublicKey: hostKey,
        ecdhPublicKey: keyExchange.publicKey,
        signature: _hostKey.sign(exchangeHash).encode(),
      ).encode(),
    );

    // Like OpenSSH, send NEWKEYS right after the reply and encrypt from here.
    _send(SSH_Message_NewKeys().encode());
    _encrypter = OpenSSHChaCha20Poly1305(
      _deriveKey(SSHDeriveKeyType.serverKey),
    );
    if (_strictKex) _sendSequence = 0;
  }

  /// Keys for the first and only exchange, whose hash is the session id.
  Uint8List _deriveKey(SSHDeriveKeyType keyType) => SSHKexUtils.deriveKey(
    digest: _kexType.createDigest(),
    sharedSecret: _sharedSecret!,
    exchangeHash: _exchangeHash!,
    keyType: keyType,
    sessionId: _exchangeHash!,
    keySize: _cipherType.keySize,
  );

  void _requireEncryption(Uint8List payload) {
    if (_decrypter != null) return;

    throw StateError('Message ${payload.first} arrived before NEWKEYS.');
  }

  void _send(Uint8List payload) {
    if (_incoming.isClosed) return;

    // RFC 4253 §6 aligns the whole clear-text packet; the OpenSSH chacha20
    // construction leaves its encrypted length field out of the alignment.
    final encrypter = _encrypter;
    final aligned = encrypter == null
        ? _packetHeaderBytes + payload.length
        : _paddingLengthBytes + payload.length;
    var padding = _packetBlockBytes - aligned % _packetBlockBytes;
    if (padding < _minimumPaddingBytes) padding += _packetBlockBytes;

    final packet = Uint8List(_packetHeaderBytes + payload.length + padding);
    ByteData.sublistView(packet).setUint32(0, packet.length - _uint32Bytes);
    packet[_uint32Bytes] = padding;
    packet.setRange(
      _packetHeaderBytes,
      _packetHeaderBytes + payload.length,
      payload,
    );
    _incoming.add(
      encrypter == null
          ? packet
          : encrypter.encryptPacket(packet, _sendSequence),
    );
    _sendSequence++;
  }
}

Uint8List _decodeHex(String value) => Uint8List.fromList([
  for (var offset = 0; offset < value.length; offset += 2)
    int.parse(value.substring(offset, offset + 2), radix: 16),
]);
