import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

/// [query] as a pattern, or null when it does not compile. Unicode mode
/// comes first, so `\p{Lu}` and characters outside the BMP match as the
/// journal's PCRE2 matches them. It rejects escapes PCRE2 takes, such as
/// `a\-b`, so a pattern it refuses gets the lenient mode.
RegExp? compileLogPattern(String query, {required bool caseSensitive}) {
  if (query.isEmpty) return null;
  for (final unicode in const [true, false]) {
    try {
      return RegExp(query, caseSensitive: caseSensitive, unicode: unicode);
    } on FormatException {
      continue;
    }
  }
  return null;
}

/// One question to the worker: the pattern, then whether it asks for the
/// matches' places in the one text of [texts] rather than a count for
/// each.
typedef _Request = (
  String query,
  bool caseSensitive,
  bool ranges,
  List<String> texts,
);

/// An isolate that matches a regular expression against rows' texts for
/// a `LogSearch` (LOG-06), so no pattern runs on the UI isolate: Dart's
/// `RegExp` backtracks without a limit, and a pattern a user types can
/// take seconds for 50,000 rows or never finish on one (UIB-1). Nothing
/// can stop a match from inside its isolate, but [close] kills this one
/// in the middle of one.
///
/// It answers one question at a time; null answers that it died or was
/// closed. A match of no characters is never counted or placed.
final class LogPatternWorker {
  LogPatternWorker() {
    _replies.listen(_onReply);
    unawaited(_spawn());
  }

  final _replies = ReceivePort();
  final _requests = Completer<SendPort?>();
  Isolate? _isolate;
  Completer<Int32List?>? _pending;
  bool _closed = false;

  /// How many matches each of [texts] holds.
  Future<Int32List?> counts(
    String query,
    List<String> texts, {
    required bool caseSensitive,
  }) => _ask((query, caseSensitive, false, texts));

  /// Where [text]'s matches start and end, as pairs of code unit
  /// offsets in order.
  Future<Int32List?> ranges(
    String query,
    String text, {
    required bool caseSensitive,
  }) => _ask((query, caseSensitive, true, [text]));

  /// Stops the isolate at once, whatever it is matching.
  void close() {
    if (_closed) return;
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _replies.close();
    _fail();
  }

  Future<void> _spawn() async {
    try {
      final isolate = await Isolate.spawn(
        _serve,
        _replies.sendPort,
        onExit: _replies.sendPort,
        onError: _replies.sendPort,
        debugName: 'log search',
      );
      if (_closed) {
        isolate.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = isolate;
    } on IsolateSpawnException {
      _fail();
    }
  }

  Future<Int32List?> _ask(_Request request) async {
    // The worker answers one question at a time.
    assert(_pending == null);
    final pending = _pending = Completer<Int32List?>();
    final requests = await _requests.future;
    if (requests == null) {
      _answer(null);
    } else if (!_closed) {
      requests.send(request);
    }
    return pending.future;
  }

  void _onReply(Object? reply) {
    switch (reply) {
      case final SendPort requests:
        _requests.complete(requests);
      case final Int32List answer:
        _answer(answer);
      // The isolate's exit (null) or an error it did not catch (a list
      // of its text and stack trace).
      default:
        _fail();
    }
  }

  void _fail() {
    if (!_requests.isCompleted) _requests.complete(null);
    _answer(null);
  }

  void _answer(Int32List? answer) {
    final pending = _pending;
    _pending = null;
    pending?.complete(answer);
  }
}

/// The worker isolate: answers each [_Request] with an [Int32List].
void _serve(SendPort replies) {
  final requests = ReceivePort();
  replies.send(requests.sendPort);

  (String, bool)? compiled;
  RegExp? pattern;
  requests.listen((message) {
    final (query, caseSensitive, ranges, texts) = message as _Request;
    if (compiled != (query, caseSensitive)) {
      compiled = (query, caseSensitive);
      pattern = compileLogPattern(query, caseSensitive: caseSensitive);
    }

    final matcher = pattern;
    if (matcher == null) {
      replies.send(Int32List(ranges ? 0 : texts.length));
      return;
    }
    if (ranges) {
      replies.send(
        Int32List.fromList([
          for (final match in matcher.allMatches(texts.single))
            if (match.end > match.start) ...[match.start, match.end],
        ]),
      );
      return;
    }

    final counts = Int32List(texts.length);
    for (var i = 0; i < texts.length; i++) {
      for (final match in matcher.allMatches(texts[i])) {
        if (match.end > match.start) counts[i]++;
      }
    }
    replies.send(counts);
  });
}
