import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// RFC 4253 §6.1: the largest `packet_length` an implementation must
/// accept, and the limit dartssh2 4.1.0 enforces (`SSHPacket.maxLength`).
const _maxPacketLength = 35000;

/// The smallest `packet_length` dartssh2 accepts: the padding-length byte
/// plus RFC 4253 §6's four bytes of padding.
const _minPacketLength = 5;

const _uint32Bytes = 4;
const _paddingLengthBytes = 1;
const _messageIdBytes = 1;
const _booleanBytes = 1;

/// `packet_length`, `padding_length` and the message number: enough of a
/// packet to tell whether it is the KEXINIT.
const _packetPeekBytes = _uint32Bytes + _paddingLengthBytes + _messageIdBytes;

/// The tap holds at most one maximal packet, or one line of the
/// identification exchange no longer than that.
const _maxBufferedBytes = _uint32Bytes + _maxPacketLength;

/// RFC 4253 §6: unencrypted packets are aligned to 8 bytes.
const _cleartextAlignment = 8;
const _minPaddingLength = 4;

/// Lines a server may send before its identification line. RFC 4253 §4.2
/// sets no limit; dartssh2 4.1.0 and OpenSSH stop after 1024.
const _maxPreBannerLines = 1024;

const _lineFeed = 0x0a;

/// RFC 4253 §12's message numbers. dartssh2 does not export its own.
const _disconnectMessageId = 1;
const _kexInitMessageId = 20;
const _newKeysMessageId = 21;

/// RFC 4253 §7.1: the KEXINIT cookie, and the name-lists that follow it
/// (key exchange, host key, then cipher, MAC, compression and language,
/// each client-to-server and server-to-client).
const _cookieBytes = 16;
const _kexInitNameLists = 10;

/// One part of a key exchange that needs an algorithm both sides accept.
/// A cipher or MAC that is missing in either direction counts once.
enum SshAlgorithmCategory { keyExchange, hostKey, cipher, mac }

/// The algorithms a server offered in its first SSH_MSG_KEXINIT (RFC 4253
/// §7.1), by wire name.
final class ServerKexInit {
  ServerKexInit._(List<Set<String>> lists)
    : kex = lists[0],
      hostKey = lists[1],
      cipherClientToServer = lists[2],
      cipherServerToClient = lists[3],
      macClientToServer = lists[4],
      macServerToClient = lists[5];

  final Set<String> kex;
  final Set<String> hostKey;
  final Set<String> cipherClientToServer;
  final Set<String> cipherServerToClient;
  final Set<String> macClientToServer;
  final Set<String> macServerToClient;

  /// The KEXINIT in [payload], which starts at its message number, or null
  /// when that is not a complete, well-formed KEXINIT. Every length is
  /// checked against the payload before it is read; bytes after the
  /// reserved field are ignored, as dartssh2 ignores them.
  static ServerKexInit? decode(Uint8List payload) {
    if (payload.isEmpty || payload.first != _kexInitMessageId) return null;

    final bytes = ByteData.sublistView(payload);
    var offset = _messageIdBytes + _cookieBytes;
    final lists = <Set<String>>[];
    for (var i = 0; i < _kexInitNameLists; i++) {
      if (payload.length - offset < _uint32Bytes) return null;
      final length = bytes.getUint32(offset);
      offset += _uint32Bytes;
      if (payload.length - offset < length) return null;

      lists.add(
        _nameList(Uint8List.sublistView(payload, offset, offset + length)),
      );
      offset += length;
    }

    // first_kex_packet_follows and the reserved uint32 end the message.
    if (payload.length - offset < _booleanBytes + _uint32Bytes) return null;
    return ServerKexInit._(lists);
  }

  /// The key exchange a client proposing [proposal] agrees on with this
  /// server, picked as dartssh2 picks it (RFC 4253 §7.1: the client's first
  /// entry that the server also offers), or null when there is none.
  SSHKexType? negotiatedKex(SSHAlgorithms proposal) =>
      _firstOffered(proposal.kex, kex, (algorithm) => algorithm.name);

  /// The parts in which a client proposing [proposal] and this server share
  /// no algorithm, by the checks dartssh2 4.1.0 makes before it gives up
  /// with `No matching … algorithm` (`SSHTransport._handleMessageKexInit`).
  /// Empty when the two agree on everything.
  ///
  /// A MAC is needed only in a direction whose cipher is not AEAD, and that
  /// cipher is the client's first choice, so a server that also offers an
  /// AEAD cipher still needs a MAC when the client ranks AES-CTR first.
  Set<SshAlgorithmCategory> unshared(SSHAlgorithms proposal) {
    SSHCipherType? cipherFor(Set<String> offered) =>
        _firstOffered(proposal.cipher, offered, (cipher) => cipher.name);
    bool lacksMac(SSHCipherType? cipher, Set<String> offered) =>
        cipher != null &&
        !cipher.isAead &&
        _firstOffered(proposal.mac, offered, (mac) => mac.name) == null;

    final clientCipher = cipherFor(cipherClientToServer);
    final serverCipher = cipherFor(cipherServerToClient);
    return {
      if (negotiatedKex(proposal) == null) SshAlgorithmCategory.keyExchange,
      if (_firstOffered(proposal.hostkey, hostKey, (key) => key.name) == null)
        SshAlgorithmCategory.hostKey,
      if (clientCipher == null || serverCipher == null)
        SshAlgorithmCategory.cipher,
      if (lacksMac(clientCipher, macClientToServer) ||
          lacksMac(serverCipher, macServerToClient))
        SshAlgorithmCategory.mac,
    };
  }
}

/// Names are US-ASCII (RFC 4251 §6); latin1 decodes any byte, and a name
/// that is not ASCII simply matches nothing.
Set<String> _nameList(Uint8List bytes) => Set.unmodifiable(
  latin1.decode(bytes).split(',').where((name) => name.isNotEmpty),
);

// dartssh2 does not export the `SSHAlgorithm` base its types share.
T? _firstOffered<T>(
  List<T> proposed,
  Set<String> offered,
  String Function(T algorithm) nameOf,
) {
  for (final algorithm in proposed) {
    if (offered.contains(nameOf(algorithm))) return algorithm;
  }
  return null;
}

enum _TapPhase { identification, packets, finished }

/// Watches the part of a key exchange a server sends in the clear (RFC 4253
/// §7), so that a failed handshake can be explained from the server's own
/// offer. dartssh2 4.1.0 reports a mismatch only as `StateError('No
/// matching … algorithm')` and keeps the server's lists to itself.
///
/// Passive: the socket from [observe] hands dartssh2 every chunk unchanged
/// and in the same event, and the tap reads alongside it. It follows the
/// identification exchange and the unencrypted binary packets, keeps the
/// first KEXINIT, and stops at the server's first NEWKEYS, after which the
/// stream is encrypted. Anything it cannot follow, such as a malformed or
/// oversized packet, also makes it stop. It holds at most one maximal
/// packet, skips the others unbuffered, and never throws into the stream,
/// so classification can fall back but a connection dartssh2 would
/// complete is never failed by the tap.
final class ServerKexTap {
  /// The server's first KEXINIT, once it has arrived whole and decoded.
  ServerKexInit? get serverKexInit => _serverKexInit;
  ServerKexInit? _serverKexInit;

  /// Whether the server sent SSH_MSG_DISCONNECT before its first NEWKEYS.
  /// Seen here because dartssh2 does not read a packet that arrives while
  /// it computes a Diffie-Hellman exchange, and reports the close that
  /// follows it as a bare close.
  bool get serverDisconnected => _serverDisconnected;
  var _serverDisconnected = false;

  /// Whether any byte of a binary packet arrived after the server's
  /// identification line, readable or not: a server that closes before one
  /// never began its side of the key exchange.
  bool get packetStarted => _packetStarted;
  var _packetStarted = false;

  /// [socket] with every byte the server sends shown to this tap as well.
  SSHSocket observe(SSHSocket socket) => _TappedSocket(socket, this);

  var _phase = _TapPhase.identification;
  final _pending = <int>[];
  var _preBannerLines = 0;
  var _packetLength = 0;
  var _paddingLength = 0;
  var _skipping = 0;

  void _add(List<int> chunk) {
    if (_phase == _TapPhase.finished) return;

    try {
      var offset = 0;
      while (offset < chunk.length && _phase != _TapPhase.finished) {
        offset = _phase == _TapPhase.identification
            ? _readIdentification(chunk, offset)
            : _readPacket(chunk, offset);
      }
    } catch (_) {
      // The bounds checks keep the reader from throwing. This backstop
      // keeps a defect in it from reaching dartssh2's socket stream.
      _finish();
    }
  }

  /// Reads up to the end of one identification-exchange line, returning
  /// where reading stopped in [chunk].
  int _readIdentification(List<int> chunk, int offset) {
    final lineFeed = chunk.indexOf(_lineFeed, offset);
    final end = lineFeed < 0 ? chunk.length : lineFeed + 1;
    if (!_hold(chunk, offset, end) || lineFeed < 0) return end;

    final line = latin1.decode(_pending);
    _pending.clear();
    if (!line.startsWith('SSH-')) {
      // RFC 4253 §4.2 lets a server send other lines first.
      _preBannerLines++;
      if (_preBannerLines > _maxPreBannerLines) _finish();
      return end;
    }

    // dartssh2 refuses anything but SSH 2 at this point.
    if (line.startsWith('SSH-2.0-') || line.startsWith('SSH-1.99-')) {
      _phase = _TapPhase.packets;
    } else {
      _finish();
    }
    return end;
  }

  /// Reads one unencrypted binary packet (RFC 4253 §6), keeping it only if
  /// it is the first KEXINIT, and returns where reading stopped in [chunk].
  int _readPacket(List<int> chunk, int offset) {
    _packetStarted = true;
    if (_skipping > 0) {
      final skipped = min(_skipping, chunk.length - offset);
      _skipping -= skipped;
      return offset + skipped;
    }

    var at = offset;
    if (_pending.length < _packetPeekBytes) {
      final end = min(chunk.length, at + _packetPeekBytes - _pending.length);
      _pending.addAll(chunk.getRange(at, end));
      at = end;
      if (_pending.length < _packetPeekBytes) return at;

      final header = Uint8List.fromList(_pending);
      _packetLength = ByteData.sublistView(header).getUint32(0);
      _paddingLength = header[_uint32Bytes];
      if (!_isWellFramed(_packetLength, _paddingLength)) {
        _finish();
        return chunk.length;
      }

      final messageId = header[_uint32Bytes + _paddingLengthBytes];
      if (messageId == _disconnectMessageId) _serverDisconnected = true;
      if (messageId == _disconnectMessageId || messageId == _newKeysMessageId) {
        _finish();
        return chunk.length;
      }
      if (messageId != _kexInitMessageId || _serverKexInit != null) {
        // The rest of the exchange, and SSH_MSG_IGNORE or SSH_MSG_DEBUG,
        // which may come anywhere (RFC 4253 §11).
        _skipping = _uint32Bytes + _packetLength - _packetPeekBytes;
        _pending.clear();
        return at;
      }
    }

    final packetEnd = _uint32Bytes + _packetLength;
    final end = min(chunk.length, at + packetEnd - _pending.length);
    _pending.addAll(chunk.getRange(at, end));
    if (_pending.length < packetEnd) return end;

    _serverKexInit = ServerKexInit.decode(
      Uint8List.fromList(
        _pending.sublist(
          _uint32Bytes + _paddingLengthBytes,
          packetEnd - _paddingLength,
        ),
      ),
    );
    _pending.clear();
    if (_serverKexInit == null) _finish();
    return end;
  }

  /// The framing checks dartssh2 makes on a packet before any cipher is in
  /// use, so the tap reads only the packets dartssh2 reads too.
  static bool _isWellFramed(int packetLength, int paddingLength) {
    if (packetLength < _minPacketLength || packetLength > _maxPacketLength) {
      return false;
    }

    final payloadLength = packetLength - _paddingLengthBytes - paddingLength;
    if (payloadLength < _messageIdBytes) return false;

    var alignedPadding =
        _cleartextAlignment -
        (_uint32Bytes + _paddingLengthBytes + payloadLength) %
            _cleartextAlignment;
    if (alignedPadding < _minPaddingLength) {
      alignedPadding += _cleartextAlignment;
    }
    return paddingLength >= alignedPadding;
  }

  /// Appends `chunk[start, end)` to the pending line, or stops the tap and
  /// answers false when that would exceed [_maxBufferedBytes].
  bool _hold(List<int> chunk, int start, int end) {
    if (_pending.length + end - start > _maxBufferedBytes) {
      _finish();
      return false;
    }
    _pending.addAll(chunk.getRange(start, end));
    return true;
  }

  void _finish() {
    _phase = _TapPhase.finished;
    _pending.clear();
  }
}

/// [_socket] with what it receives shown to a [ServerKexTap] on the
/// way through. Everything else is the wrapped socket's, its name too:
/// dartssh2 prints the socket in every trace line.
final class _TappedSocket implements SSHSocket {
  _TappedSocket(this._socket, ServerKexTap tap)
    : stream = _socket.stream.map((chunk) {
        tap._add(chunk);
        return chunk;
      });

  final SSHSocket _socket;

  @override
  final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _socket.sink;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();

  @override
  String toString() => _socket.toString();
}
