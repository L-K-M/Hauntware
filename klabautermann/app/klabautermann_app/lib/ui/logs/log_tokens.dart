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

/// Whether [unit] is punctuation that ends a sentence rather than a URL
/// when it ends one: any of `.,;:!?)]}`.
bool _isUrlTail(int unit) => switch (unit) {
  0x2e || 0x2c || 0x3b || 0x3a || 0x21 || 0x3f || 0x29 || 0x5d || 0x7d => true,
  _ => false,
};

/// Where the URL from [start] to [end] of [text] ends without its
/// trailing punctuation. A walk back from the end: a pattern anchored at
/// the end is tried from every start, which took seconds for a URL with
/// a long run of dots inside it (UIB-2).
int _urlEnd(String text, int start, int end) {
  while (end > start && _isUrlTail(text.codeUnitAt(end - 1))) {
    end--;
  }
  return end;
}

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
  var tokens = <LogToken>[
    for (final match in _url.allMatches(text))
      (
        start: match.start,
        end: _urlEnd(text, match.start, match.end),
        kind: LogTokenKind.url,
      ),
  ];

  for (final pattern in [_ipv4, _ipv6]) {
    tokens = _withFree(tokens, [
      for (final match in pattern.allMatches(text))
        // A bare `::` names no address.
        if (match.end - match.start >= 3)
          (start: match.start, end: match.end, kind: LogTokenKind.ipAddress),
    ]);
  }

  return _withFree(tokens, [
    for (final match in _httpStatus.allMatches(text))
      (
        start: match.end - 3,
        end: match.end,
        kind: switch (match[1]!.codeUnitAt(0)) {
          0x31 || 0x32 => LogTokenKind.httpSuccess,
          0x33 => LogTokenKind.httpRedirect,
          0x34 => LogTokenKind.httpClientError,
          _ => LogTokenKind.httpServerError,
        },
      ),
  ]);
}

/// [tokens] with those of [found] that overlap none of them, in order.
/// Both are in order and apart from their own, so one pass merges them:
/// checking each new token against every one held is quadratic in a line
/// of nothing but addresses.
List<LogToken> _withFree(List<LogToken> tokens, List<LogToken> found) {
  if (found.isEmpty) return tokens;

  final merged = <LogToken>[];
  var held = 0;
  for (final token in found) {
    while (held < tokens.length && tokens[held].end <= token.start) {
      merged.add(tokens[held++]);
    }
    if (held == tokens.length || tokens[held].start >= token.end) {
      merged.add(token);
    }
  }
  merged.addAll(tokens.skip(held));
  return merged;
}
