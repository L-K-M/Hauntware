// NET-11 and DKE-09's port forwards (03 §5.11, M6 N22): a listener on the
// device's loopback interface per forward, each connection to it relayed
// over the server's link as a `direct-tcpip` channel to a host and port
// as the server sees them. Spike S7 (03 §5.11) found no in-app web view
// a channel can feed on every platform, so a forward is this loopback
// listener, opened only when the user asks and closed with its view.
import 'dart:async';
import 'dart:io';

import 'package:seance_core/seance_core.dart';

import '../engine/protocol.dart';

/// Binds a forward's listener: `127.0.0.1` at a port the system picks.
typedef PortForwardBinder = Future<ServerSocket> Function();

Future<ServerSocket> _bindLoopback() =>
    ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

/// The engine's open port forwards, by forward id. Each listens until the
/// app closes it, its server's link goes, or the server leaves the fleet,
/// and reports each change as a [PortForwardState].
final class PortForwards {
  PortForwards({
    required this._linkFor,
    required this._emit,
    this._bind = _bindLoopback,
  });

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final PortForwardBinder _bind;
  final Map<String, _Forward> _forwards = {};

  /// Opens [request]'s forward, or ends it at once with the reason it
  /// cannot open: a target [portForwardTargetProblem] refuses, an id
  /// already open, [kPortForwardsMax] forwards open, no link to the
  /// server, or a listener the system would not bind.
  Future<void> open(OpenPortForward request) async {
    final OpenPortForward(:serverId, :forwardId, :host, :port) = request;
    PortForwardEnd? refusal;
    if (portForwardTargetProblem(host, port) != null) {
      refusal = PortForwardEnd.invalidTarget;
    } else if (_forwards.containsKey(forwardId)) {
      refusal = PortForwardEnd.duplicateId;
    } else if (_forwards.length >= kPortForwardsMax) {
      refusal = PortForwardEnd.tooMany;
    } else if (_linkFor(serverId) == null) {
      refusal = PortForwardEnd.noLink;
    }
    if (refusal != null) {
      _emit(
        PortForwardState(
          serverId: serverId,
          forwardId: forwardId,
          host: host,
          port: port,
          ended: refusal,
        ),
      );
      return;
    }

    // Held before the bind, so a close or a lost link meanwhile ends it.
    final forward = _forwards[forwardId] = _Forward(
      serverId,
      forwardId,
      host,
      port,
    );
    final ServerSocket listener;
    try {
      listener = await _bind();
    } on SocketException {
      if (identical(_forwards[forwardId], forward)) {
        _end(forward, PortForwardEnd.bindFailed);
      }
      return;
    }
    if (!identical(_forwards[forwardId], forward)) {
      await listener.close();
      return;
    }

    forward
      ..listener = listener
      ..accepting = listener.listen(
        (client) => unawaited(_relay(forward, client)),
        onError: (Object _) => _end(forward, PortForwardEnd.bindFailed),
      );
    _report(forward);
  }

  /// Ends [forwardId]'s forward as the app asked; an unknown id is ignored.
  void close(String forwardId) {
    if (_forwards[forwardId] case final forward?) {
      _end(forward, PortForwardEnd.closed);
    }
  }

  /// Follows [serverId]'s link: its forwards end once it has none, since
  /// a new link starts without their channels.
  void update(String serverId) {
    if (_linkFor(serverId) != null) return;
    _endServer(serverId, PortForwardEnd.linkLost);
  }

  /// Ends the forwards of [serverIds]: they left the fleet, or their
  /// endpoint now names another machine (SYN-08).
  void forget(Iterable<String> serverIds) {
    for (final serverId in serverIds) {
      _endServer(serverId, PortForwardEnd.serverForgotten);
    }
  }

  /// Ends every forward, as the engine stops.
  void dispose() {
    for (final forward in [..._forwards.values]) {
      _end(forward, PortForwardEnd.closed);
    }
  }

  void _endServer(String serverId, PortForwardEnd reason) {
    for (final forward in [..._forwards.values]) {
      if (forward.serverId == serverId) _end(forward, reason);
    }
  }

  /// One connection to [forward]'s listener, relayed over a channel until
  /// either side closes. A channel that cannot open closes the
  /// connection and says why on the forward, which keeps listening.
  Future<void> _relay(_Forward forward, Socket client) async {
    final link = _linkFor(forward.serverId);
    if (link == null) {
      client.destroy();
      return;
    }
    final ByteDuplex channel;
    try {
      channel = await link.openTcpStream(forward.host, forward.port);
    } on Object catch (error) {
      client.destroy();
      if (forward.ended) return;
      forward.failure = switch (error) {
        ChannelOpenException(refusal: ChannelRefusal.forwardDisabled) =>
          PortForwardFailure.forwardingDisabled,
        _ => PortForwardFailure.connectFailed,
      };
      _report(forward);
      return;
    }
    if (forward.ended) {
      client.destroy();
      unawaited(channel.close());
      return;
    }

    final connection = (client: client, channel: channel);
    forward
      ..connections.add(connection)
      ..failure = null;
    _report(forward);
    try {
      await Future.wait([
        channel.sink.addStream(client).then((_) => channel.sink.close()),
        client.addStream(channel.stream).then((_) => client.close()),
      ], eagerError: true);
    } on Object {
      // Either side failing ends the connection; the finally closes both.
    } finally {
      client.destroy();
      unawaited(channel.close());
      if (forward.connections.remove(connection) && !forward.ended) {
        _report(forward);
      }
    }
  }

  void _report(_Forward forward) => _emit(
    PortForwardState(
      serverId: forward.serverId,
      forwardId: forward.forwardId,
      host: forward.host,
      port: forward.port,
      localPort: forward.listener?.port,
      connections: forward.connections.length,
      failure: forward.failure,
    ),
  );

  void _end(_Forward forward, PortForwardEnd reason) {
    if (forward.ended) return;
    forward.ended = true;
    _forwards.remove(forward.forwardId);
    unawaited(forward.accepting?.cancel());
    unawaited(forward.listener?.close());
    for (final (:client, :channel) in forward.connections) {
      client.destroy();
      unawaited(channel.close());
    }
    forward.connections.clear();
    _emit(
      PortForwardState(
        serverId: forward.serverId,
        forwardId: forward.forwardId,
        host: forward.host,
        port: forward.port,
        ended: reason,
      ),
    );
  }
}

typedef _Connection = ({Socket client, ByteDuplex channel});

final class _Forward {
  _Forward(this.serverId, this.forwardId, this.host, this.port);

  final String serverId;
  final String forwardId;
  final String host;
  final int port;
  ServerSocket? listener;
  StreamSubscription<Socket>? accepting;
  final Set<_Connection> connections = {};
  PortForwardFailure? failure;
  bool ended = false;
}
