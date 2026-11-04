import 'dart:io';

import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

final class _ConnectionInfo implements HttpConnectionInfo {
  _ConnectionInfo(String remote) : remoteAddress = InternetAddress(remote);

  @override
  final InternetAddress remoteAddress;

  @override
  int get localPort => 8787;

  @override
  int get remotePort => 12345;
}

Request _request(String remote, {String? forwarded}) => Request(
      'POST',
      Uri.parse('http://localhost/v1/login'),
      headers: {if (forwarded != null) 'x-forwarded-for': forwarded},
      context: {'shelf.io.connection_info': _ConnectionInfo(remote)},
    );

void main() {
  test('direct requests ignore spoofed forwarding headers', () {
    const resolver = RequestSourceResolver();
    expect(
      resolver(_request('192.0.2.1', forwarded: '198.51.100.2')),
      '192.0.2.1',
    );
  });

  test('trusted proxies select the first untrusted hop from the right', () {
    const resolver = RequestSourceResolver(
      trustedProxies: {'192.0.2.10', '192.0.2.11'},
    );
    expect(
      resolver(_request(
        '192.0.2.10',
        forwarded: '203.0.113.8, 198.51.100.7, 192.0.2.11',
      )),
      '198.51.100.7',
    );
  });

  test('invalid forwarded chains fall back to the immediate peer', () {
    const resolver = RequestSourceResolver(
      trustedProxies: {'192.0.2.10'},
    );
    expect(
      resolver(_request('192.0.2.10', forwarded: 'not-an-ip')),
      '192.0.2.10',
    );
  });

  test('direct handler requests have a stable unknown source', () {
    const resolver = RequestSourceResolver();
    expect(
      resolver(Request('POST', Uri.parse('http://localhost/v1/login'))),
      'unknown',
    );
  });
}
