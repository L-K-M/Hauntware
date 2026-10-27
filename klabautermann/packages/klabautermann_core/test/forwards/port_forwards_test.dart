// NET-11 and DKE-09's port forwards (03 §5.11): a loopback listener per
// forward, each connection relayed over the link to the server's target.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/forwards/port_forwards.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import '../support/scripted_link.dart';

/// A link whose `direct-tcpip` channels reach a local socket at [target]'s
/// port, wherever the request names, or throw the next queued failure.
final class _TcpLink extends TestLinkBase {
  _TcpLink(this.target);

  final ServerSocket target;
  final opened = <(String, int)>[];
  final failures = <Object>[];

  @override
  Future<ByteDuplex> openTcpStream(String host, int port) async {
    opened.add((host, port));
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return _SocketDuplex(
      await Socket.connect(InternetAddress.loopbackIPv4, target.port),
    );
  }
}

final class _SocketDuplex implements ByteDuplex {
  _SocketDuplex(this._socket);

  final Socket _socket;

  @override
  Stream<List<int>> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async => _socket.destroy();
}

void main() {
  late ServerSocket echo;
  late _TcpLink link;
  late List<PortForwardState> states;
  late PortForwards forwards;
  SshLink? current;

  setUp(() async {
    // An echo service standing in for the target on the server.
    echo = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    echo.listen((socket) => socket.listen(socket.add, onDone: socket.close));
    link = _TcpLink(echo);
    current = link;
    states = [];
    forwards = PortForwards(
      linkFor: (_) => current,
      emit: (event) {
        states.add(event as PortForwardState);
      },
    );
  });

  tearDown(() async {
    forwards.dispose();
    await echo.close();
  });

  Future<PortForwardState> listening(String id, {int port = 8080}) async {
    await forwards.open(
      OpenPortForward(
        serverId: 'srv-1',
        forwardId: id,
        host: '172.17.0.2',
        port: port,
      ),
    );
    return states.lastWhere((s) => s.forwardId == id);
  }

  Future<String> roundTrip(int localPort, String text) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      localPort,
    );
    socket.write(text);
    await socket.flush();
    final reply = await socket
        .map(utf8.decode)
        .firstWhere((chunk) => chunk.isNotEmpty);
    socket.destroy();
    return reply;
  }

  test('a forward listens on loopback and relays each connection to its '
      'target over the link', () async {
    final state = await listening('f-1');
    expect(state.ended, isNull);
    expect(state.localPort, isNotNull);

    expect(await roundTrip(state.localPort!, 'hello'), 'hello');
    expect(link.opened, [('172.17.0.2', 8080)]);
    expect(states.map((s) => s.connections), contains(1));
  });

  test('closing ends the listener, and a final state says so', () async {
    final state = await listening('f-1');
    forwards.close('f-1');

    expect(states.last.ended, PortForwardEnd.closed);
    expect(states.last.localPort, isNull);
    await expectLater(
      Socket.connect(InternetAddress.loopbackIPv4, state.localPort!),
      throwsA(isA<SocketException>()),
    );
  });

  test('a refused channel closes that connection and says why, and the '
      'forward keeps listening', () async {
    final state = await listening('f-1');
    link.failures.add(
      const ChannelOpenException(ChannelRefusal.forwardDisabled, 'refused'),
    );

    final refused = await Socket.connect(
      InternetAddress.loopbackIPv4,
      state.localPort!,
    );
    await refused.drain<void>().catchError((Object _) {});
    await pumpEventQueue();
    expect(states.last.failure, PortForwardFailure.forwardingDisabled);
    expect(states.last.ended, isNull);

    expect(await roundTrip(state.localPort!, 'again'), 'again');
    expect(states.last.failure, isNull);
  });

  test('a lost link and a forgotten server end their forwards', () async {
    await listening('f-1');
    current = null;
    forwards.update('srv-1');
    expect(states.last.ended, PortForwardEnd.linkLost);

    current = link;
    await listening('f-2');
    forwards.forget({'srv-1'});
    expect(states.last.ended, PortForwardEnd.serverForgotten);
  });

  test('a bad target, a duplicate id, no link or too many forwards end at '
      'once', () async {
    await forwards.open(
      const OpenPortForward(
        serverId: 'srv-1',
        forwardId: 'bad',
        host: 'a b',
        port: 80,
      ),
    );
    expect(states.last.ended, PortForwardEnd.invalidTarget);
    expect(portForwardTargetProblem('db', 0), PortForwardTargetProblem.badPort);
    expect(portForwardTargetProblem('', 80), PortForwardTargetProblem.badHost);
    expect(portForwardTargetProblem('::1', 65535), isNull);

    await listening('f-1');
    await listening('f-1');
    expect(states.last.ended, PortForwardEnd.duplicateId);

    for (var i = 2; i <= kPortForwardsMax; i++) {
      await listening('f-$i');
    }
    await listening('f-extra');
    expect(states.last.ended, PortForwardEnd.tooMany);

    forwards.dispose();
    current = null;
    await listening('f-none');
    expect(states.last.ended, PortForwardEnd.noLink);
    expect(link.opened, isEmpty, reason: 'nothing connected');
  });
}
