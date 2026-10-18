// A fake Docker or Podman engine behind a socket for the engine's Docker
// session: `_ping` and `/version` answer as the engine configured, and
// versioned paths from the test's routes.
import 'dart:convert';

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
