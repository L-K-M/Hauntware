// The capture tool's transport: a Unix-socket connection adapted to the
// package's ByteDuplex seam, and a tap that keeps every byte the daemon
// sends. dart:io stays here, outside lib/ (tool/guards.yaml no_dart_io).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';

/// One connection to the engine socket at a filesystem path.
final class UnixSocketDuplex implements ByteDuplex {
  UnixSocketDuplex._(this._socket, {void Function(Uint8List bytes)? onBytes}) {
    _stream = _socket.transform(
      StreamTransformer<Uint8List, List<int>>.fromHandlers(
        handleData: (bytes, sink) {
          onBytes?.call(bytes);
          sink.add(bytes);
        },
        handleError: (error, stackTrace, sink) {
          sink.addError(error, stackTrace);
        },
        handleDone: (sink) {
          _finish();
          sink.close();
        },
      ),
    );
  }

  /// Connects to the Unix socket at [path]. [onBytes] sees every inbound
  /// chunk before the client does.
  static Future<UnixSocketDuplex> connect(
    String path, {
    void Function(Uint8List bytes)? onBytes,
  }) async {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    return UnixSocketDuplex._(socket, onBytes: onBytes);
  }

  final Socket _socket;
  late final Stream<List<int>> _stream;
  final Completer<void> _done = Completer<void>();

  @override
  Stream<List<int>> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> closeWrite() async {
    // Socket.close ends the write direction only.
    try {
      await _socket.close();
    } on SocketException {
      // Already closed by the peer.
    }
  }

  @override
  Future<void> close() async {
    _socket.destroy();
    _finish();
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Collects what one exchange's connection receives.
final class ResponseTap {
  final BytesBuilder _bytes = BytesBuilder();

  void add(Uint8List bytes) => _bytes.add(bytes);

  /// Everything received so far.
  Uint8List get bytes => _bytes.toBytes();
}
