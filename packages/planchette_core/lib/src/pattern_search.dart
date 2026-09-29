part of 'editor_syntax.dart';

/// How long one pattern search may run before its worker is stopped.
///
/// Dart cannot interrupt a [RegExp] while it matches, and a pattern that
/// backtracks catastrophically, such as `(a+)+$` against a long run of `a`
/// that ends in something else, takes time that doubles with every
/// character. A second is ample for a sensible pattern on a large file and
/// short enough that a runaway one reads as a problem rather than a hang.
const Duration patternSearchBudget = Duration(seconds: 1);

/// The most matches one pattern search collects.
///
/// A pattern search lists every match in the document at once, so that the
/// find bar can page through them without searching again. A one-character
/// class in a large file matches millions of times, and listing them all
/// would cost more memory than it is worth; past this many, the find bar
/// shows its count as a lower bound.
const int patternMatchLimit = 100000;

/// A find-bar regular expression, compiled once for its source and case
/// setting.
///
/// Compiled with `multiLine`, so `^` and `$` anchor to lines the way they read
/// in a find bar, and with `unicode`, so `.` and classes see characters rather
/// than halves of surrogate pairs, and a case-insensitive pattern folds every
/// script (`Σ`, `σ` and `ς` are one letter). The host's [CaseFolder] does not
/// apply: the expression engine folds case itself.
final class FindPattern {
  /// Throws a [FormatException] whose message says why when [source] is not a
  /// valid pattern.
  FindPattern(this.source, {this.caseSensitive = false})
    : _regExp = RegExp(
        source,
        multiLine: true,
        unicode: true,
        caseSensitive: caseSensitive,
      );

  /// The pattern as typed.
  final String source;
  final bool caseSensitive;
  final RegExp _regExp;

  /// Every match in [text], in order and without overlaps, up to [limit].
  ///
  /// A match of nothing, as `x*` or `^` find at every position, is skipped:
  /// the find bar cannot highlight or replace an empty range. The scan goes
  /// on past it, so `a*` still finds `aa` in `baab`. With [wholeWord], a match
  /// that runs on into a word is skipped the way literal search skips one,
  /// and the scan resumes just after its start, since a whole word may begin
  /// inside it.
  PatternMatches findAll(
    String text, {
    bool wholeWord = false,
    int limit = patternMatchLimit,
  }) {
    final bounds = <int>[];
    var capped = false;
    for (final match in _matchesIn(text, wholeWord: wholeWord)) {
      if (bounds.length >> 1 >= limit) {
        capped = true;
        break;
      }
      bounds
        ..add(match.start)
        ..add(match.end);
    }
    return PatternMatches._(Int32List.fromList(bounds), capped: capped);
  }

  /// [text] with every match [findAll] would report replaced by [template],
  /// expanded for that match by [expandPatternReplacement]; null when nothing
  /// matched. Unlike [findAll] this has no limit: Replace All covers the
  /// whole document.
  PatternReplacement? replaceAll(
    String text,
    String template, {
    bool wholeWord = false,
  }) {
    final replaced = StringBuffer();
    var copied = 0;
    var count = 0;
    var firstEnd = 0;
    for (final match in _matchesIn(text, wholeWord: wholeWord)) {
      final expanded = expandPatternReplacement(template, match);
      replaced
        ..write(text.substring(copied, match.start))
        ..write(expanded);
      if (count == 0) firstEnd = match.start + expanded.length;
      count++;
      copied = match.end;
    }
    if (count == 0) return null;
    replaced.write(text.substring(copied));
    return PatternReplacement._(
      text: replaced.toString(),
      count: count,
      firstEnd: firstEnd,
    );
  }

  /// The match starting exactly at [start], when it is one [findAll] would
  /// report: not empty and, with [wholeWord], standing as whole words.
  ///
  /// Anchored at [start], so it repeats only the one attempt that found the
  /// match there. When that match came from a worker search of the same text,
  /// the attempt already ran within [patternSearchBudget], which is what makes
  /// it safe to repeat on the calling isolate.
  RegExpMatch? matchAt(String text, int start, {bool wholeWord = false}) {
    if (start < 0 || start > text.length) return null;
    final match = _regExp.matchAsPrefix(text, start);
    if (match is! RegExpMatch || match.end == match.start) return null;
    if (wholeWord && !_isWholeWordMatch(text, match.start, match.end)) {
      return null;
    }
    return match;
  }

  Iterable<RegExpMatch> _matchesIn(
    String text, {
    required bool wholeWord,
  }) sync* {
    var from = 0;
    restart:
    while (true) {
      // allMatches steps past an empty match by itself, a whole character
      // in unicode mode, so skipping one needs no bookkeeping here.
      for (final match in _regExp.allMatches(text, from)) {
        if (match.end == match.start) continue;
        if (wholeWord && !_isWholeWordMatch(text, match.start, match.end)) {
          from = _nextCharacter(text, match.start);
          continue restart;
        }
        yield match;
      }
      return;
    }
  }
}

/// The offset of the character after the one at [index], stepping over a
/// whole surrogate pair.
int _nextCharacter(String text, int index) =>
    index + 1 < text.length &&
        _isHighSurrogate(text.codeUnitAt(index)) &&
        _isLowSurrogate(text.codeUnitAt(index + 1))
    ? index + 2
    : index + 1;

/// [template] with the references to [match]'s groups replaced by their text.
///
/// `$1` to `$99` and `${1}` name numbered groups, `$0` the whole match, and
/// `${name}` a named group. Two digits name a group only when the pattern has
/// that many, as in JavaScript: with one group, `$12` is group 1 and then a
/// literal `2`. `$$` is a literal `$`. A reference to a group the pattern
/// lacks stays as typed, and a group that did not take part in the match
/// expands to nothing.
String expandPatternReplacement(String template, RegExpMatch match) {
  if (!template.contains(r'$')) return template;
  final expanded = StringBuffer();
  var index = 0;
  while (index < template.length) {
    final unit = template.codeUnitAt(index);
    if (unit != _dollar || index + 1 == template.length) {
      expanded.writeCharCode(unit);
      index++;
      continue;
    }
    final next = template.codeUnitAt(index + 1);
    if (next == _dollar) {
      expanded.writeCharCode(_dollar);
      index += 2;
      continue;
    }
    if (next == _openBrace) {
      final close = template.indexOf('}', index + 2);
      if (close > index + 2 &&
          _writeGroup(expanded, match, template.substring(index + 2, close))) {
        index = close + 1;
        continue;
      }
    } else if (_isDigit(next)) {
      final hasSecond =
          index + 2 < template.length &&
          _isDigit(template.codeUnitAt(index + 2));
      if (hasSecond &&
          _writeGroup(
            expanded,
            match,
            template.substring(index + 1, index + 3),
          )) {
        index += 3;
        continue;
      }
      if (_writeGroup(expanded, match, String.fromCharCode(next))) {
        index += 2;
        continue;
      }
    }
    expanded.writeCharCode(_dollar);
    index++;
  }
  return expanded.toString();
}

const _dollar = 0x24;
const _openBrace = 0x7b;

/// Writes the group [reference] names, a number or a name, and returns
/// whether [match] has it.
bool _writeGroup(StringBuffer out, RegExpMatch match, String reference) {
  if (reference.codeUnits.every(_isDigit)) {
    // Parsed digit by digit so an absurdly long number cannot overflow into
    // a valid group.
    var number = 0;
    for (final unit in reference.codeUnits) {
      number = number * 10 + unit - 0x30;
      if (number > match.groupCount) return false;
    }
    out.write(match.group(number) ?? '');
    return true;
  }
  if (!match.groupNames.contains(reference)) return false;
  out.write(match.namedGroup(reference) ?? '');
  return true;
}

/// A pattern search's matches, held compactly: a large file can have tens of
/// thousands, and they cross from the worker isolate as one typed list.
final class PatternMatches {
  PatternMatches._(this._bounds, {required this.capped});

  /// No matches, for a search that found none or could not run.
  static final none = PatternMatches._(Int32List(0), capped: false);

  /// Start and end of each match in turn.
  final Int32List _bounds;

  /// Whether the search stopped at its limit with more matches to come.
  final bool capped;

  int get length => _bounds.length >> 1;
  bool get isEmpty => _bounds.isEmpty;

  int startOf(int index) => _bounds[index * 2];
  int endOf(int index) => _bounds[index * 2 + 1];
  TextMatch operator [](int index) =>
      TextMatch(start: startOf(index), end: endOf(index));

  /// The index of the first match that starts at or after [offset], or
  /// [length] when none does.
  int indexAtOrAfter(int offset) {
    var low = 0;
    var high = length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (startOf(middle) < offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  /// These matches carried through an edit that replaced `[start, end)` of
  /// the text with text [delta] code units longer.
  ///
  /// A match the edit touched is dropped, since it may no longer match; the
  /// others keep their text and move with it. They are a stand-in until the
  /// edited text is searched again: text elsewhere can change what a pattern
  /// with anchors or lookaround matches, and the edit may have made new
  /// matches.
  PatternMatches afterEdit({
    required int start,
    required int end,
    required int delta,
  }) {
    final kept = <int>[];
    for (var i = 0; i < length; i++) {
      final matchStart = startOf(i);
      final matchEnd = endOf(i);
      if (matchEnd <= start) {
        kept
          ..add(matchStart)
          ..add(matchEnd);
      } else if (matchStart >= end) {
        kept
          ..add(matchStart + delta)
          ..add(matchEnd + delta);
      }
    }
    return PatternMatches._(Int32List.fromList(kept), capped: capped);
  }
}

/// The text a pattern Replace All produced.
final class PatternReplacement {
  PatternReplacement._({
    required this.text,
    required this.count,
    required this.firstEnd,
  });

  /// The whole document after the replacement.
  final String text;

  /// How many matches were replaced.
  final int count;

  /// Where the first replacement ends in [text], for the caret.
  final int firstEnd;
}

/// Why a pattern search produced no matches it could stand behind.
sealed class PatternFailure {
  const PatternFailure();
}

/// The pattern does not compile, or matching it failed; [message] says why.
final class PatternUnusable extends PatternFailure {
  const PatternUnusable(this.message);
  final String message;
}

/// The search ran past its [budget] and was stopped.
final class PatternTimedOut extends PatternFailure {
  const PatternTimedOut(this.budget);
  final Duration budget;
}

/// How a [PatternWorker] request ended.
sealed class PatternOutcome<T> {
  const PatternOutcome();
}

final class PatternCompleted<T> extends PatternOutcome<T> {
  const PatternCompleted(this.value);
  final T value;
}

final class PatternFailed<T> extends PatternOutcome<T> {
  const PatternFailed(this.failure);
  final PatternFailure failure;
}

/// A newer request, or disposal, replaced this one before it finished. Its
/// answer would describe a query or text that is gone.
final class PatternCancelled<T> extends PatternOutcome<T> {
  const PatternCancelled();
}

/// Runs pattern searches in a worker isolate, each under [budget].
///
/// Dart cannot interrupt a [RegExp] that is matching, so a catastrophic
/// pattern freezes whichever isolate runs it. Here that is the worker: when
/// the budget runs out it is killed, the request reports [PatternTimedOut],
/// and the next request starts a fresh worker. The worker keeps the pattern
/// it compiled last, so searching an edited document again does not compile
/// the pattern again.
///
/// One request runs at a time. A new request cancels one still running, by
/// killing the worker if it has started on it: that answer is no longer
/// wanted, and killing is the only way to stop it.
final class PatternWorker {
  PatternWorker({this.budget = patternSearchBudget});

  final Duration budget;

  Isolate? _isolate;
  RawReceivePort? _inbox;
  Completer<SendPort>? _handshake;
  Future<SendPort>? _ready;
  _PendingPattern<Object?>? _pending;
  Timer? _deadline;
  int _tickets = 0;
  bool _disposed = false;

  /// Every match of [source] in [text]; see [FindPattern.findAll].
  Future<PatternOutcome<PatternMatches>> findAll(
    String text,
    String source, {
    bool caseSensitive = false,
    bool wholeWord = false,
    int limit = patternMatchLimit,
  }) => _submit<PatternMatches>(
    (reply) => reply! as PatternMatches,
    text: text,
    source: source,
    caseSensitive: caseSensitive,
    wholeWord: wholeWord,
    limit: limit,
  );

  /// [text] with every match of [source] replaced; see
  /// [FindPattern.replaceAll].
  Future<PatternOutcome<PatternReplacement?>> replaceAll(
    String text,
    String source,
    String template, {
    bool caseSensitive = false,
    bool wholeWord = false,
  }) => _submit<PatternReplacement?>(
    (reply) => reply as PatternReplacement?,
    text: text,
    source: source,
    caseSensitive: caseSensitive,
    wholeWord: wholeWord,
    template: template,
  );

  /// Stops the worker. A request still running reports [PatternCancelled],
  /// and so does every later one.
  void dispose() {
    _disposed = true;
    final pending = _pending;
    _pending = null;
    _deadline?.cancel();
    _stop();
    pending?.cancel();
  }

  Future<PatternOutcome<T>> _submit<T>(
    T Function(Object? reply) decode, {
    required String text,
    required String source,
    required bool caseSensitive,
    required bool wholeWord,
    int limit = patternMatchLimit,
    String? template,
  }) {
    if (_disposed) return Future.value(PatternCancelled<T>());
    _cancelPending();
    final pending = _PendingPattern<T>(++_tickets, decode);
    _pending = pending;
    unawaited(
      _dispatch(
        pending,
        _PatternRequest(
          ticket: pending.ticket,
          text: text,
          source: source,
          caseSensitive: caseSensitive,
          wholeWord: wholeWord,
          limit: limit,
          template: template,
        ),
      ),
    );
    return pending.completer.future;
  }

  Future<void> _dispatch(
    _PendingPattern<Object?> pending,
    _PatternRequest request,
  ) async {
    final SendPort port;
    try {
      port = await (_ready ?? _start());
    } on Object catch (error) {
      // Only a current request can meet a worker that failed to start; one
      // stopped while starting was cancelled already.
      if (identical(_pending, pending)) {
        _pending = null;
        _stop();
        pending.fail(PatternUnusable('$error'));
      }
      return;
    }
    if (!identical(_pending, pending)) return;
    pending.sent = true;
    port.send(request);
    _deadline = Timer(budget, () {
      if (!identical(_pending, pending)) return;
      _pending = null;
      _stop();
      pending.fail(PatternTimedOut(budget));
    });
  }

  void _cancelPending() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    _deadline?.cancel();
    // The worker is busy with it; only killing frees it for the next one.
    if (pending.sent) _stop();
    pending.cancel();
  }

  Future<SendPort> _start() {
    final inbox = RawReceivePort();
    final handshake = Completer<SendPort>();
    inbox.handler = (Object? message) {
      if (message is SendPort) {
        if (!handshake.isCompleted) handshake.complete(message);
        return;
      }
      _receive(message! as _PatternReply);
    };
    _inbox = inbox;
    _handshake = handshake;
    return _ready =
        Isolate.spawn(
          _patternWorkerMain,
          inbox.sendPort,
          debugName: 'pattern search',
        ).then((isolate) {
          if (!identical(_inbox, inbox)) {
            // Stopped while it was starting.
            isolate.kill(priority: Isolate.immediate);
            throw StateError('The pattern worker was stopped.');
          }
          _isolate = isolate;
          return handshake.future;
        });
  }

  void _receive(_PatternReply reply) {
    final pending = _pending;
    if (pending == null || pending.ticket != reply.ticket) return;
    _pending = null;
    _deadline?.cancel();
    final error = reply.error;
    if (error != null) {
      pending.fail(PatternUnusable(error));
    } else {
      pending.answer(reply.payload);
    }
  }

  void _stop() {
    _deadline?.cancel();
    _deadline = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _inbox?.close();
    _inbox = null;
    final handshake = _handshake;
    if (handshake != null && !handshake.isCompleted) {
      handshake.completeError(StateError('The pattern worker was stopped.'));
    }
    _handshake = null;
    _ready = null;
  }
}

final class _PendingPattern<T> {
  _PendingPattern(this.ticket, this._decode);

  final int ticket;
  final T Function(Object? reply) _decode;
  final completer = Completer<PatternOutcome<T>>();

  /// Whether the worker has been given this request, and so is busy with it.
  bool sent = false;

  void answer(Object? reply) =>
      completer.complete(PatternCompleted(_decode(reply)));
  void fail(PatternFailure failure) =>
      completer.complete(PatternFailed(failure));
  void cancel() => completer.complete(PatternCancelled<T>());
}

final class _PatternRequest {
  const _PatternRequest({
    required this.ticket,
    required this.text,
    required this.source,
    required this.caseSensitive,
    required this.wholeWord,
    required this.limit,
    required this.template,
  });

  final int ticket;
  final String text;
  final String source;
  final bool caseSensitive;
  final bool wholeWord;
  final int limit;

  /// The replacement for Replace All, or null for a search.
  final String? template;
}

final class _PatternReply {
  const _PatternReply(this.ticket, this.payload, this.error);
  final int ticket;
  final Object? payload;
  final String? error;
}

/// The worker isolate: answers requests in order, keeping the last compiled
/// pattern for the next one.
void _patternWorkerMain(SendPort replies) {
  final requests = RawReceivePort();
  FindPattern? compiled;
  requests.handler = (Object? message) {
    final request = message! as _PatternRequest;
    try {
      var pattern = compiled;
      if (pattern == null ||
          pattern.source != request.source ||
          pattern.caseSensitive != request.caseSensitive) {
        pattern = compiled = FindPattern(
          request.source,
          caseSensitive: request.caseSensitive,
        );
      }
      final template = request.template;
      final Object? payload = template == null
          ? pattern.findAll(
              request.text,
              wholeWord: request.wholeWord,
              limit: request.limit,
            )
          : pattern.replaceAll(
              request.text,
              template,
              wholeWord: request.wholeWord,
            );
      replies.send(_PatternReply(request.ticket, payload, null));
    } on FormatException catch (error) {
      replies.send(_PatternReply(request.ticket, null, error.message));
    } on Object catch (error) {
      // A match can fail at run time, as when it exhausts its stack; the
      // search cannot be trusted, so it reports rather than dies.
      replies.send(_PatternReply(request.ticket, null, '$error'));
    }
  };
  replies.send(requests.sendPort);
}
