import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart'
    show TextMatch, findSearchMatches;

import 'log_pattern_worker.dart';
import 'log_text.dart';
import 'log_view_controller.dart';

/// The most rows one question to the pattern worker holds, and the most
/// characters: a pattern that reads a row in a few microseconds answers
/// in a few milliseconds, so the worker turns to the rows in sight and
/// to a new query soon.
const _chunkLines = 256;
const _chunkChars = 128 * 1024;

/// The most matches' places kept for the rows in sight, and the most
/// rows waiting for theirs.
const _rangesMax = 20000;
const _wantedMax = 256;

/// A search match: the [LogEntry.seq] of its line and its place among the
/// line's matches.
typedef LogMatch = ({int seq, int index});

/// Text search over the lines a [LogViewController] holds (LOG-05, 03
/// §7.6): plain text, or a regular expression while [regex] is on (LOG-06),
/// ignoring case unless [caseSensitive], with stepping from match to match.
/// A pattern that does not compile matches nothing and says so through
/// [invalidPattern]; a match of no characters is skipped. It reads each row's visible text ([logRowText]),
/// a row's time and a container row's stream mark included (CTX-02), with
/// `planchette_core`'s `findSearchMatches` and keeps up as lines arrive
/// and leave, holding only a count for each matching line; a view asks
/// [matchesIn] for the matches of a line it draws.
///
/// That search compares exactly where lowercasing would change a text's
/// length, and `searchText` reports when it did. On the Dart VM, which
/// runs the app on every platform, `toLowerCase` maps each code point to
/// one of the same length, so the plain matches tell the whole story.
///
/// [next] and [previous] wrap around at the newest and oldest match. From
/// no current match, [next] goes to the oldest and [previous] to the
/// newest. A new query or case setting starts with no current match.
///
/// A new plain query or case setting searches every held line at once,
/// which took 73 to 125 ms for 50,000 journal rows of about 115
/// characters in a JIT test run, so a search field should debounce its
/// input.
///
/// A regular expression never runs on the UI isolate (UIB-1): Dart's
/// `RegExp` backtracks without a limit, so an ordinary pattern can take
/// many seconds for a full buffer and a nested quantifier may never
/// finish one row. A [LogPatternWorker] counts the matches a slice of
/// rows at a time, oldest first, and [total] grows as it answers;
/// [searching] is true until it has read every row held when the query
/// was set. A new query, setting or zone stops the worker in the middle
/// of a match and starts over. [matchesIn] answers from the places the
/// worker sent for the rows a view drew, and is empty for a row until
/// they arrive, when listeners hear of it. A question the worker does not
/// answer within the limit ends the search: [tooCostly] says so, and it
/// matches nothing until the query or a setting changes.
class LogSearch extends ChangeNotifier {
  LogSearch(
    this._logs, {
    @visibleForTesting this._patternLimit = const Duration(seconds: 5),
  }) : _zoneOffset = _logs.zoneOffset {
    _logs.addListener(_onLines);
  }

  final LogViewController _logs;

  /// How long the pattern worker may take over one question.
  final Duration _patternLimit;

  /// The zone offset the lines were searched at: a new one changes every
  /// row's time, so the search starts over as for a new query.
  Duration? _zoneOffset;

  String _query = '';
  bool _caseSensitive = false;
  bool _regex = false;

  /// [_query] compiled while [_regex] is on, or null when it does not
  /// compile. Only whether it compiles is read here: the worker matches.
  RegExp? _pattern;

  /// The isolate that matches while [_regex] is on, from its first
  /// question until the search leaves regular expressions.
  LogPatternWorker? _worker;

  /// Stands for the question the worker has not answered yet. A search
  /// that starts over drops it, so the answer is ignored.
  Object? _asked;
  Timer? _limit;
  bool _catchingUp = false;
  bool _tooCostly = false;

  /// The seqs of matching rows a view drew without their matches'
  /// places, oldest request first.
  final _wanted = <int>{};

  /// The matches' places of the rows a view drew last, least recently
  /// read first, and how many they are.
  final _ranges = <int, List<TextMatch>>{};
  int _rangesHeld = 0;

  /// The matching lines, oldest first, and how many matches each holds.
  final _lines = ListQueue<({int seq, int count})>();
  int _total = 0;

  /// The seq after the last line searched.
  int _searchedTo = 0;

  LogMatch? _current;
  int _steps = 0;

  String get query => _query;

  bool get caseSensitive => _caseSensitive;

  /// Whether the query is a regular expression (LOG-06).
  bool get regex => _regex;

  /// Whether [regex] is on and the query does not compile.
  bool get invalidPattern => _regex && _query.isNotEmpty && _pattern == null;

  /// Whether [regex] is on and the search has not yet read every row
  /// that was held when the query or a setting changed; [total] is the
  /// count so far.
  bool get searching => _catchingUp;

  /// Whether [regex] is on and matching the query took longer than the
  /// search waits, so it stopped and matches nothing.
  bool get tooCostly => _tooCostly;

  /// Whether the pattern worker owes an answer: matches of rows that
  /// arrived, or the places of a row's matches.
  @visibleForTesting
  bool get working => _asked != null;

  /// The matches in the lines held.
  int get total => _total;

  /// The current match, or null before the first step.
  LogMatch? get current => _current;

  /// Counts [next] and [previous] calls that moved to a match, so a view
  /// can bring the current match into sight on each.
  int get steps => _steps;

  /// The current match's place among all matches, from 1.
  int? get currentNumber {
    final current = _current;
    if (current == null) return null;

    var before = 0;
    for (final line in _lines) {
      if (line.seq == current.seq) break;
      before += line.count;
    }
    return before + current.index + 1;
  }

  void setQuery(String query) {
    if (query == _query) return;
    _query = query;
    _searchAll();
  }

  void setCaseSensitive(bool caseSensitive) {
    if (caseSensitive == _caseSensitive) return;
    _caseSensitive = caseSensitive;
    _searchAll();
  }

  void setRegex(bool regex) {
    if (regex == _regex) return;
    _regex = regex;
    _searchAll();
  }

  /// The matches in [line]'s [logRowText], in order. For a regular
  /// expression, empty until the worker sent their places; listeners are
  /// notified when it has.
  List<TextMatch> matchesIn(LogLine line) {
    if (!_searching || _find(line.seq) < 0) return const [];
    if (!_regex) return _search(_rowText(line));

    // Read again, so it is the last to leave.
    final held = _ranges.remove(line.seq);
    if (held != null) return _ranges[line.seq] = held;

    if (_wanted.add(line.seq)) {
      if (_wanted.length > _wantedMax) _wanted.remove(_wanted.first);
      _askWorker();
    }
    return const [];
  }

  /// The index in [matchesIn] of the current match when it is in [line].
  int? currentIndexIn(LogLine line) =>
      _current?.seq == line.seq ? _current!.index : null;

  /// Moves to the next match toward the newest line.
  void next() => _step(forward: true);

  /// Moves to the next match toward the oldest line.
  void previous() => _step(forward: false);

  @override
  void dispose() {
    _logs.removeListener(_onLines);
    _stopWorker();
    super.dispose();
  }

  void _step({required bool forward}) {
    if (_lines.isEmpty) return;

    final current = _current;
    final at = current == null ? -1 : _find(current.seq);
    if (current != null && at >= 0) {
      final count = _lines.elementAt(at).count;
      final index = current.index + (forward ? 1 : -1);
      if (index >= 0 && index < count) {
        _moveTo((seq: current.seq, index: index));
        return;
      }
    }

    final line = switch ((at, forward)) {
      (< 0, true) => _lines.first,
      (< 0, false) => _lines.last,
      (_, true) => _lines.elementAt((at + 1) % _lines.length),
      (_, false) => _lines.elementAt((at - 1) % _lines.length),
    };
    _moveTo((seq: line.seq, index: forward ? 0 : line.count - 1));
  }

  void _moveTo(LogMatch match) {
    _current = match;
    _steps++;
    notifyListeners();
  }

  /// The place of [seq] in [_lines], or -1.
  int _find(int seq) {
    var low = 0;
    var high = _lines.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final found = _lines.elementAt(mid).seq;
      if (found == seq) return mid;
      if (found < seq) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  void _searchAll() {
    _pattern = _compile();
    _lines.clear();
    _total = 0;
    _current = null;
    _searchedTo = _logs.firstSeq;
    _forgetPattern();
    if (_regex) {
      _catchingUp = _searching;
      _askWorker();
    } else {
      _stopWorker();
      _searchNew();
    }
    notifyListeners();
  }

  void _onLines() {
    if (_logs.zoneOffset != _zoneOffset) {
      _zoneOffset = _logs.zoneOffset;
      _searchAll();
      return;
    }

    final first = _logs.firstSeq;
    var changed = false;
    while (_lines.isNotEmpty && _lines.first.seq < first) {
      _total -= _lines.removeFirst().count;
      changed = true;
    }
    if (_current case (:final seq, index: _) when seq < first) {
      _current = null;
      changed = true;
    }
    if (_searchedTo < first) _searchedTo = first;

    if (_regex) {
      _wanted.removeWhere((seq) => seq < first);
      _ranges.removeWhere((seq, places) {
        if (seq >= first) return false;
        _rangesHeld -= places.length;
        return true;
      });
      final catchingUp = _catchingUp;
      _askWorker();
      if (changed || catchingUp != _catchingUp) notifyListeners();
      return;
    }

    if (_searchNew() || changed) notifyListeners();
  }

  /// Asks the worker its next question unless it owes an answer: the
  /// places of a row's matches a view is waiting for, else the counts of
  /// the next rows not yet searched.
  void _askWorker() {
    if (!_regex || !_searching || _asked != null) return;

    final first = _logs.firstSeq;
    final end = first + _logs.length;
    while (_wanted.isNotEmpty) {
      final seq = _wanted.first;
      _wanted.remove(seq);
      if (seq < first || _find(seq) < 0 || _ranges.containsKey(seq)) continue;

      final text = _rowText(_logs[seq - first] as LogLine);
      _ask(
        (worker) => worker.ranges(_query, text, caseSensitive: _caseSensitive),
        (places) => _takeRanges(seq, places),
      );
      return;
    }

    final seqs = <int>[];
    final texts = <String>[];
    var chars = 0;
    while (_searchedTo < end &&
        seqs.length < _chunkLines &&
        chars < _chunkChars) {
      final entry = _logs[_searchedTo++ - first];
      if (entry is! LogLine) continue;

      final text = _rowText(entry);
      seqs.add(entry.seq);
      texts.add(text);
      chars += text.length;
    }
    if (seqs.isEmpty) {
      _catchingUp = false;
      return;
    }
    _ask(
      (worker) => worker.counts(_query, texts, caseSensitive: _caseSensitive),
      (counts) => _takeCounts(seqs, counts),
    );
  }

  /// Sends [question] to the worker and hands its answer to [take], then
  /// asks the next. The search stops as too costly when the worker takes
  /// longer than the limit or dies.
  Future<void> _ask(
    Future<Int32List?> Function(LogPatternWorker worker) question,
    void Function(Int32List answer) take,
  ) async {
    final asked = _asked = Object();
    _limit = Timer(_patternLimit, _giveUp);
    final answer = await question(_worker ??= LogPatternWorker());
    // The search started over or stopped while the worker matched.
    if (!identical(asked, _asked)) return;

    _limit?.cancel();
    _asked = null;
    if (answer == null) {
      _giveUp();
      return;
    }
    take(answer);
    _askWorker();
    notifyListeners();
  }

  void _takeCounts(List<int> seqs, Int32List counts) {
    final first = _logs.firstSeq;
    for (var i = 0; i < seqs.length; i++) {
      // A row that left the buffer while the worker read it.
      if (counts[i] == 0 || seqs[i] < first) continue;

      _lines.add((seq: seqs[i], count: counts[i]));
      _total += counts[i];
    }
  }

  void _takeRanges(int seq, Int32List places) {
    if (seq < _logs.firstSeq) return;

    final matches = [
      for (var i = 0; i < places.length; i += 2)
        TextMatch(start: places[i], end: places[i + 1]),
    ];
    _ranges[seq] = matches;
    _rangesHeld += matches.length;
    while (_rangesHeld > _rangesMax && _ranges.length > 1) {
      _rangesHeld -= _ranges.remove(_ranges.keys.first)!.length;
    }
  }

  /// Ends the search as too costly: nothing it found is kept, since a
  /// count of part of the rows would read as the whole.
  void _giveUp() {
    _forgetPattern();
    _stopWorker();
    _lines.clear();
    _total = 0;
    _current = null;
    _tooCostly = true;
    notifyListeners();
  }

  /// Drops what the worker was asked and what it sent for the query
  /// before. A worker in the middle of a match is killed: a new one
  /// starts with the next question, where waiting for the old could
  /// take for ever.
  void _forgetPattern() {
    _limit?.cancel();
    if (_asked != null) _stopWorker();
    _asked = null;
    _wanted.clear();
    _ranges.clear();
    _rangesHeld = 0;
    _catchingUp = false;
    _tooCostly = false;
  }

  void _stopWorker() {
    _limit?.cancel();
    _asked = null;
    _worker?.close();
    _worker = null;
  }

  /// Searches the lines not yet searched; returns whether any matched.
  bool _searchNew() {
    // A pattern is matched by the worker.
    assert(!_regex);
    final first = _logs.firstSeq;
    final end = first + _logs.length;
    var found = false;
    for (; _searchedTo < end && _searching; _searchedTo++) {
      final entry = _logs[_searchedTo - first];
      if (entry is! LogLine) continue;

      final count = _search(_rowText(entry)).length;
      if (count == 0) continue;

      _lines.add((seq: entry.seq, count: count));
      _total += count;
      found = true;
    }
    _searchedTo = end;
    return found;
  }

  /// [line]'s row text, a row's time and a container line's stream
  /// included.
  String _rowText(LogLine line) => _logs.rowText(line);

  /// Whether a query is set that can match.
  bool get _searching => _query.isNotEmpty && !invalidPattern && !_tooCostly;

  /// The query as a pattern ([compileLogPattern]), or null when it is
  /// plain text or does not compile.
  RegExp? _compile() =>
      _regex ? compileLogPattern(_query, caseSensitive: _caseSensitive) : null;

  /// Every match of the plain query in [text]: the limit is the most a
  /// text can hold.
  List<TextMatch> _search(String text) => findSearchMatches(
    text,
    _query,
    caseSensitive: _caseSensitive,
    limit: text.length,
  );
}
