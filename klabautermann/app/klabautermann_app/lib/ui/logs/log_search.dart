import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart'
    show TextMatch, findSearchMatches;

import 'log_text.dart';
import 'log_view_controller.dart';

/// A search match: the [LogEntry.seq] of its line and its place among the
/// line's matches.
typedef LogMatch = ({int seq, int index});

/// Text search over the lines a [LogViewController] holds (LOG-05, 03
/// §7.6): plain text, or a regular expression while [regex] is on (LOG-06),
/// ignoring case unless [caseSensitive], with stepping from match to match.
/// A pattern that does not compile matches nothing and says so through
/// [invalidPattern]; a match of no characters is skipped. It reads each row's visible text ([logRowText]),
/// a container row's time and stream mark included (CTX-02), with
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
/// A new query or case setting searches every held line at once, which
/// took 73 to 125 ms for 50,000 journal rows of about 115 characters in a
/// JIT test run, so a search field should debounce its input or search in
/// slices across frames.
class LogSearch extends ChangeNotifier {
  LogSearch(this._logs) {
    _logs.addListener(_onLines);
  }

  final LogViewController _logs;

  String _query = '';
  bool _caseSensitive = false;
  bool _regex = false;

  /// [_query] compiled while [_regex] is on, or null when it does not
  /// compile.
  RegExp? _pattern;

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

  /// The matches in [line]'s [logRowText], in order.
  List<TextMatch> matchesIn(LogLine line) {
    if (!_searching || _find(line.seq) < 0) return const [];
    return _search(_rowText(line));
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
    _searchNew();
    notifyListeners();
  }

  void _onLines() {
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

    if (_searchNew() || changed) notifyListeners();
  }

  /// Searches the lines not yet searched; returns whether any matched.
  bool _searchNew() {
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

  /// [line]'s row text, a container line's time and stream included.
  String _rowText(LogLine line) =>
      logRowText(line, container: _logs.containerOf(line));

  /// Whether a query is set that can match.
  bool get _searching => _query.isNotEmpty && !invalidPattern;

  RegExp? _compile() {
    if (!_regex || _query.isEmpty) return null;
    try {
      return RegExp(_query, caseSensitive: _caseSensitive, unicode: true);
    } on FormatException {
      return null;
    }
  }

  /// Every match in [text]: the limit is the most a text can hold.
  List<TextMatch> _search(String text) {
    if (!_regex) {
      return findSearchMatches(
        text,
        _query,
        caseSensitive: _caseSensitive,
        limit: text.length,
      );
    }
    final pattern = _pattern;
    if (pattern == null) return const [];
    return [
      for (final match in pattern.allMatches(text))
        if (match.end > match.start)
          TextMatch(start: match.start, end: match.end),
    ];
  }
}
