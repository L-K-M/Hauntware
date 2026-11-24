import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/log_tokens.dart';

/// [text]'s tokens as (text, kind) pairs.
List<(String, LogTokenKind)> _tokens(String text) => [
  for (final token in logTokens(text))
    (text.substring(token.start, token.end), token.kind),
];

/// The URL patterns as they stood before UIB-2, when the tail's search
/// was quadratic: where a URL token must still end.
final _urlBefore = RegExp(r'''\b(?:https?|wss?|ftp)://[^\s<>"'`]+''');
final _urlTailBefore = RegExp(r'[.,;:!?)\]}]+$');

List<(int, int)> _urlsBefore(String text) => [
  for (final match in _urlBefore.allMatches(text))
    (
      match.start,
      match.end - (_urlTailBefore.firstMatch(match[0]!)?.group(0)?.length ?? 0),
    ),
];

const _urlCorpus = [
  'see https://example.com/a?b=1, then (http://x.test/).',
  'ws://10.0.0.5:8080/feed',
  'GET http://10.0.0.1/a 200 then 10.0.0.2 status=503 https://h.test',
  'Fetching https://registry.test/v2/........ done',
  'Fetching https://registry.test/v2/...',
  'http://a.test/x).',
  'http://a.test/(x)',
  'http://a.test/x]}:;!?',
  'http://a.test/x.,y.,',
  'http://...',
  'http://',
  'http://.',
  'http://.a',
  'ftp://f.test/a.b.c. wss://w.test:443/s?x=[1]',
  '<https://a.test/b>, "https://c.test/d." and `http://e.test`!',
  'https://a.test/\u00e9\u{1f600}.',
  'no URL here: just text.',
  'xhttp://not.a.url/ and nothttps://x.test/.',
  '',
];

void main() {
  test('a URL ends where the pattern before UIB-2 ended it', () {
    for (final text in _urlCorpus) {
      expect(
        [
          for (final token in logTokens(text))
            if (token.kind == LogTokenKind.url) (token.start, token.end),
        ],
        _urlsBefore(text),
        reason: text,
      );
    }
  });

  test('a long adversarial line is read in linear time (UIB-2)', () {
    const length = 64 * 1024;
    String filled(String piece) =>
        (piece * (length ~/ piece.length + 1)).substring(0, length);
    final lines = [
      'http://${filled('.')}a',
      'http://${filled('.')}',
      filled('http://....a '),
      filled('http://a.test/. '),
      filled('1.1.1.1 '),
      filled('http://a.test 1.1.1.1 status=200 '),
      filled('255.255.255.255:'),
      filled('1.'),
      filled('ffff:'),
      filled(':'),
      filled(' a:a:a:a:a:a:a'),
      'fe80::1%${filled('a.')}:',
      'GET${filled(' ')}x',
      'GET ${filled('x')}',
      filled('GET x '),
      filled('status '),
      'HTTP/1${filled(' ')}x',
      filled('7'),
    ];

    // Before the fix the first line alone took over half a minute here.
    final watch = Stopwatch()..start();
    for (final line in lines) {
      logTokens(line);
    }
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

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
