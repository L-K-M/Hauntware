import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/log_tokens.dart';

/// [text]'s tokens as (text, kind) pairs.
List<(String, LogTokenKind)> _tokens(String text) => [
  for (final token in logTokens(text))
    (text.substring(token.start, token.end), token.kind),
];

void main() {
  test('finds URLs and leaves sentence punctuation out', () {
    expect(_tokens('see https://example.com/a?b=1, then (http://x.test/).'), [
      ('https://example.com/a?b=1', LogTokenKind.url),
      ('http://x.test/', LogTokenKind.url),
    ]);
    expect(_tokens('ws://10.0.0.5:8080/feed'), [
      ('ws://10.0.0.5:8080/feed', LogTokenKind.url),
    ]);
  });

  test('finds IPv4 addresses with a port or prefix, not versions', () {
    expect(_tokens('from 192.168.1.20:51234 to 10.0.0.0/8 via 127.0.0.1.'), [
      ('192.168.1.20:51234', LogTokenKind.ipAddress),
      ('10.0.0.0/8', LogTokenKind.ipAddress),
      ('127.0.0.1', LogTokenKind.ipAddress),
    ]);
    expect(_tokens('version 1.2.3.4.5 and 999.1.1.1 and v1.2.3.4'), isEmpty);
  });

  test('finds IPv6 addresses, not clock times, MACs or scopes', () {
    expect(_tokens('peer fe80::1%eth0 and 2001:db8:0:0:0:0:2:1 and ::1 ok'), [
      ('fe80::1%eth0', LogTokenKind.ipAddress),
      ('2001:db8:0:0:0:0:2:1', LogTokenKind.ipAddress),
      ('::1', LogTokenKind.ipAddress),
    ]);
    expect(
      _tokens('at 14:30:05 mac aa:bb:cc:dd:ee:ff in std::io and Foo::add'),
      isEmpty,
    );
  });

  test('finds HTTP status codes only where a log says they are one', () {
    expect(
      _tokens(
        '10.1.2.3 - - [20/Oct/2026] "GET /index.html HTTP/1.1" 404 512 "-"',
      ),
      [
        ('10.1.2.3', LogTokenKind.ipAddress),
        ('404', LogTokenKind.httpClientError),
      ],
    );
    expect(_tokens('GET /healthz 200'), [('200', LogTokenKind.httpSuccess)]);
    expect(_tokens('HTTP/2 301'), [('301', LogTokenKind.httpRedirect)]);
    expect(_tokens('upstream status=502 code: 101'), [
      ('502', LogTokenKind.httpServerError),
      ('101', LogTokenKind.httpSuccess),
    ]);
    // A number alone is not a status.
    expect(_tokens('took 200 ms, 404 files, pid 500'), isEmpty);
  });

  test('tokens are ordered and never overlap', () {
    const text =
        'GET http://10.0.0.1/a 200 then 10.0.0.2 status=503 https://h.test';
    final tokens = logTokens(text);
    for (var i = 1; i < tokens.length; i++) {
      expect(tokens[i].start, greaterThanOrEqualTo(tokens[i - 1].end));
    }
    expect(_tokens(text), [
      ('http://10.0.0.1/a', LogTokenKind.url),
      ('200', LogTokenKind.httpSuccess),
      ('10.0.0.2', LogTokenKind.ipAddress),
      ('503', LogTokenKind.httpServerError),
      ('https://h.test', LogTokenKind.url),
    ]);
  });
}
