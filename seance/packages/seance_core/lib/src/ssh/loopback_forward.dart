import 'dart:async';
import 'dart:io';

import 'byte_duplex.dart';

/// Opens one stream to the forward's target, as the server sees it.
typedef ForwardOpener = Future<ByteDuplex> Function();

/// Binds a forward's listener on this device's loopback interface.
typedef LoopbackBinder = Future<ServerSocket> Function(int port);

Future<ServerSocket> _bindLoopback(int port) =>
    ServerSocket.bind(InternetAddress.loopbackIPv4, port);

/// A listener on this device's loopback interface whose every connection is
/// relayed, over a stream [ForwardOpener] opens, to one host and port as a
/// server sees them: `ssh -L`, for a link a server printed about itself
/// (`http://localhost:3000/`).
///
/// Only `127.0.0.1` is bound, so other machines cannot reach the server
/// through it; processes on this device can, for as long as it is open, as
/// with `ssh -L`.
final class LoopbackForward {
  LoopbackForward._(this._listener, this._open) {
    _accepting = _listener.listen(
      (client) => unawaited(_relay(client)),
      onError: (Object _) => unawaited(close()),
    );
  }

  /// Listens on [preferredPort] when it is free, so a page that names its
  /// own port in redirects and cookies still works, and on a port the
  /// system picks otherwise.
  static Future<LoopbackForward> bind(
    ForwardOpener open, {
    int preferredPort = 0,
    LoopbackBinder binder = _bindLoopback,
  }) async {
    ServerSocket listener;
    try {
      listener = await binder(preferredPort);
    } on SocketException {
      if (preferredPort == 0) rethrow;
      listener = await binder(0);
    }
    return LoopbackForward._(listener, open);
  }

  final ServerSocket _listener;
  final ForwardOpener _open;
  late final StreamSubscription<Socket> _accepting;
  final Set<_Connection> _connections = {};
  bool _closed = false;

  /// The loopback port this device's browser connects to.
  int get port => _listener.port;

  bool get isClosed => _closed;

  /// Completes once the forward has closed, by [close] or on its own when
  /// its listener fails.
  Future<void> get done => _done.future;
  final _done = Completer<void>();

  /// Stops listening and ends every relayed connection.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Done once the port is free again, so a forward bound after it can
    // take the same one.
    try {
      await _accepting.cancel();
      await _listener.close();
    } finally {
      _done.complete();
    }
    for (final (:client, :stream) in [..._connections]) {
      client.destroy();
      unawaited(stream.close());
    }
    _connections.clear();
  }

  /// One connection, relayed until either side ends it. A stream that
  /// cannot open ends the connection, which the browser reports; the
  /// forward keeps listening.
  Future<void> _relay(Socket client) async {
    final ByteDuplex stream;
    try {
      stream = await _open();
    } on Object {
      client.destroy();
      return;
    }
    if (_closed) {
      client.destroy();
      unawaited(stream.close());
      return;
    }

    final connection = (client: client, stream: stream);
    _connections.add(connection);
    try {
      await Future.wait([
        stream.sink.addStream(client).then((_) => stream.sink.close()),
        client.addStream(stream.stream).then((_) => client.close()),
      ], eagerError: true);
    } on Object {
      // Either side failing ends the connection; the finally closes both.
    } finally {
      _connections.remove(connection);
      client.destroy();
      unawaited(stream.close());
    }
  }
}

typedef _Connection = ({Socket client, ByteDuplex stream});
