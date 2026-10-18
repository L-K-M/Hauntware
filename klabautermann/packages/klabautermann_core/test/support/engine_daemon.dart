// A fake Docker or Podman engine behind a socket for the engine's Docker
// session: `_ping` and `/version` answer as the engine configured,
// versioned paths from the test's routes, `/events` and container logs
// as streams the test writes to, and answers the test holds back until it
// releases them.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_docker/testing.dart';

import 'forwarding_link.dart';

final class EngineDaemon extends FakeDaemon {
  EngineDaemon({
    this.apiVersion = '1.52',
    this.minApiVersion = '1.24',
    this.libpodApiVersion,
  });

  /// `Api-Version` on `_ping` and `ApiVersion` on `/version`.
  final String apiVersion;
  final String? minApiVersion;

  /// Set for Podman's compat layer, which sends it on `_ping` only;
  /// `/version` names no Podman component here.
  final String? libpodApiVersion;

  /// The bodies of 200 answers by path, query left out.
  final routes = <String, String>{};

  /// A status and daemon message by path, ahead of everything else.
  final failures = <String, (int, String)>{};

  /// Paths whose answers wait in [held] until [release].
  bool Function(String path) hold = (_) => false;
  final held = <(String, FakeDuplexPair)>[];

  /// The open `/events` streams' connections.
  final eventStreams = <FakeDuplexPair>[];

  /// The open container logs streams' connections, and the
  /// `Content-Type` their heads carry: Docker 20.10 and Podman send none
  /// (D01).
  final logStreams = <FakeDuplexPair>[];
  String? logsContentType = 'application/vnd.docker.multiplexed-stream';

  @override
  void handle(String requestLine, FakeDuplexPair connection) {
    final path = requestLine.split(' ')[1].split('?').first;
    if (hold(path)) {
      held.add((requestLine, connection));
    } else if (path.endsWith('/events') && !failures.containsKey(path)) {
      eventStreams.add(connection);
      unawaited(
        connection.server.done.then((_) => eventStreams.remove(connection)),
      );
      connection.server.sink.add(
        utf8.encode(
          'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
          'Transfer-Encoding: chunked\r\n\r\n',
        ),
      );
    } else if (path.endsWith('/logs') && !failures.containsKey(path)) {
      logStreams.add(connection);
      unawaited(
        connection.server.done.then((_) => logStreams.remove(connection)),
      );
      final type = logsContentType;
      connection.server.sink.add(
        utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          '${type == null ? '' : 'Content-Type: $type\r\n'}'
          'Transfer-Encoding: chunked\r\n\r\n',
        ),
      );
    } else {
      super.handle(requestLine, connection);
    }
  }

  /// Answers every held request.
  void release() {
    final answers = held.toList();
    held.clear();
    for (final (line, connection) in answers) {
      super.handle(line, connection);
    }
  }

  /// Writes [event] to every open `/events` stream.
  void emit(Map<String, Object?> event) {
    final line = utf8.encode('${jsonEncode(event)}\n');
    for (final connection in eventStreams) {
      _chunk(connection, line);
    }
  }

  /// Writes [bytes] as one chunk to every open logs stream.
  void writeLogs(List<int> bytes) {
    for (final connection in logStreams) {
      _chunk(connection, bytes);
    }
  }

  /// Ends every logs stream with its last chunk, as the daemon does when
  /// the container stops; the connections stay open.
  void endLogs() {
    for (final connection in logStreams.toList()) {
      connection.server.sink.add(utf8.encode('0\r\n\r\n'));
      logStreams.remove(connection);
    }
  }

  static void _chunk(FakeDuplexPair connection, List<int> bytes) =>
      connection.server.sink
        ..add(utf8.encode('${bytes.length.toRadixString(16)}\r\n'))
        ..add(bytes)
        ..add(utf8.encode('\r\n'));

  /// Ends every `/events` stream, as a daemon restart or a lost channel
  /// does.
  Future<void> dropEvents() async {
    for (final connection in eventStreams.toList()) {
      await connection.server.close();
    }
  }

  @override
  String respond(String requestLine) {
    final [method, target, ...] = requestLine.split(' ');
    final path = target.split('?').first;
    if (failures[path] case (final status, final message)) {
      return _response(status, jsonEncode({'message': message}));
    }
    if (path == '/_ping') {
      return _response(
        200,
        method == 'HEAD' ? '' : 'OK',
        headers: {
          'Api-Version': apiVersion,
          'Libpod-API-Version': ?libpodApiVersion,
        },
      );
    }
    if (path == '/version') {
      return _response(
        200,
        jsonEncode({
          'Version': '29.0.0',
          'ApiVersion': apiVersion,
          'MinAPIVersion': ?minApiVersion,
          'Os': 'linux',
          'Arch': 'amd64',
          'Components': [
            {'Name': 'Engine', 'Version': '29.0.0'},
          ],
        }),
      );
    }
    if (routes[path] case final body?) return _response(200, body);
    return _response(404, jsonEncode({'message': 'page not found'}));
  }

  static String _response(
    int status,
    String body, {
    Map<String, String> headers = const {},
  }) {
    final bytes = utf8.encode(body);
    final head = StringBuffer('HTTP/1.1 $status X\r\n');
    for (final MapEntry(:key, :value) in headers.entries) {
      head.write('$key: $value\r\n');
    }
    head
      ..write('Content-Type: application/json\r\n')
      ..write('Content-Length: ${bytes.length}\r\n\r\n');
    return '$head$body';
  }
}
