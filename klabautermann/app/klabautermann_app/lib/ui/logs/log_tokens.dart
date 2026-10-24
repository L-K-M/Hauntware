/// LOG-07's highlighting (M5 plan Q9): the URLs, IP addresses and HTTP
/// status codes in a line's text, which the log view colours where the
/// line's own SGR styles set no colour (03 §10.8). A pure pass over the
/// visible text; it never changes what a row says or how wide it is.
library;

/// What a [LogToken] marks.
enum LogTokenKind {
  url,
  ipAddress,

  /// An HTTP status of 1xx or 2xx.
  httpSuccess,

  /// 3xx.
  httpRedirect,

  /// 4xx.
  httpClientError,

  /// 5xx.
  httpServerError,
}

/// One highlighted range of a line's text, as code unit offsets.
typedef LogToken = ({int start, int end, LogTokenKind kind});

/// A URL with a scheme a log names: up to the first space, quote or angle
/// bracket.
final _url = RegExp(r'''\b(?:https?|wss?|ftp)://[^\s<>"'`]+''');

/// Trailing punctuation that ends a sentence rather than a URL.
final _urlTail = RegExp(r'[.,;:!?)\]}]+$');

const _octet = r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)';

/// A dotted IPv4 address, with an optional port or prefix length, that is
/// not part of a longer dotted number such as a version.
final _ipv4 = RegExp(
  '(?<![\\w.])(?:$_octet\\.){3}$_octet(?::\\d{1,5}|/\\d{1,2})?(?!\\.?\\w)',
);

/// An IPv6 address in full form (eight groups) or compressed with `::`.
/// Six colon-separated pairs (a MAC address) and clock times have neither
/// shape.
final _ipv6 = RegExp(
  r'(?<![\w:])(?:'
  r'(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'
  r'|(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{0,4}::'
  r'(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{0,4}'
  r')(?:%[\w.]+)?(?![\w:])',
);

/// The places a status code is known to be one: after the protocol of a
/// status line or an access log's request (`HTTP/1.1" 404`), after a
/// method and its target (`GET /healthz 200`), and as a `status` or `code`
/// field. Group 1 is the code.
final _httpStatus = RegExp(
  r'(?:HTTP/\d(?:\.\d)?"?\s+'
  r'|\b(?:GET|HEAD|POST|PUT|DELETE|PATCH|OPTIONS|CONNECT|TRACE)\s+\S+\s+'
  r'|\b(?:[Ss]tatus|STATUS|[Cc]ode|CODE)(?:_code)?["\x27]?\s*[=:]\s*"?)'
  r'([1-5]\d\d)\b',
);

/// The [LogToken]s in [text], in order and not overlapping. URLs win over
/// the addresses and codes inside them.
List<LogToken> logTokens(String text) {
  final tokens = <LogToken>[];

  bool free(int start, int end) =>
      tokens.every((token) => end <= token.start || start >= token.end);

  for (final match in _url.allMatches(text)) {
    final tail = _urlTail.firstMatch(match[0]!)?.group(0)?.length ?? 0;
    final end = match.end - tail;
    if (end > match.start) {
      tokens.add((start: match.start, end: end, kind: LogTokenKind.url));
    }
  }

  for (final pattern in [_ipv4, _ipv6]) {
    for (final match in pattern.allMatches(text)) {
      // A bare `::` names no address.
      if (match.end - match.start < 3) continue;
      if (free(match.start, match.end)) {
        tokens.add((
          start: match.start,
          end: match.end,
          kind: LogTokenKind.ipAddress,
        ));
      }
    }
  }

  for (final match in _httpStatus.allMatches(text)) {
    final end = match.end;
    final start = end - 3;
    if (!free(start, end)) continue;
    tokens.add((
      start: start,
      end: end,
      kind: switch (match[1]!.codeUnitAt(0)) {
        0x31 || 0x32 => LogTokenKind.httpSuccess,
        0x33 => LogTokenKind.httpRedirect,
        0x34 => LogTokenKind.httpClientError,
        _ => LogTokenKind.httpServerError,
      },
    ));
  }

  tokens.sort((a, b) => a.start.compareTo(b.start));
  return tokens;
}
