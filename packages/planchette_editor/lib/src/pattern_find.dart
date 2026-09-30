import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart' show TextRange;
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;

import 'code_editing_controller.dart' show SearchResult;

/// The find bar's regular-expression mode for one editor controller.
///
/// Matching runs in a [PatternWorker] under a time budget, because Dart
/// cannot interrupt a [RegExp] and a catastrophic pattern would otherwise
/// freeze the editor. The worker lists every match in the document at once,
/// and this keeps that list, so the find bar's pages, its counter and Find
/// Next and Previous are served from it synchronously, exactly as literal
/// search serves them, without asking the worker again.
///
/// The list belongs to one text, query and set of flags. Changing the query
/// or a flag drops it: its matches are for a different search, and showing
/// them would be wrong rather than stale. Editing the text instead carries it
/// through the edit, dropping the matches the edit touched, so the user keeps
/// their place while the edited text is searched again. Either way the new
/// search waits for [settleDelay] of quiet, and an answer that arrives for a
/// text or query that has since changed is discarded.
class PatternFind {
  PatternFind({required this.budget, required this._onSettled});

  /// How long a search waits after the query or the text last changed, so
  /// typing does not start a worker search per keystroke.
  static const settleDelay = Duration(milliseconds: 120);

  /// How long each worker search may run; see [patternSearchBudget].
  final Duration budget;

  /// Called when a search's answer has been adopted.
  final void Function() _onSettled;

  String? _compiledQuery;
  bool? _compiledCaseSensitive;
  FindPattern? _pattern;
  PatternUnusable? _syntaxFailure;
  _Results? _results;
  _Key? _wanted;
  Timer? _delay;
  PatternWorker? _worker;
  PatternWorker? _replacer;
  PatternFailure? _replaceFailure;
  int _generation = 0;
  bool _disposed = false;

  /// The query compiled with the current case setting, or null when the
  /// query is empty or does not compile.
  FindPattern? get pattern => _pattern;

  /// Why the query found nothing it could stand behind: it does not compile,
  /// or its last search or Replace All failed or ran out of time.
  PatternFailure? get failure =>
      _syntaxFailure ?? _results?.failure ?? _replaceFailure;

  /// Whether a search is waiting to run or running.
  bool get pending => _wanted != null;

  /// Whether the held matches stop at [patternMatchLimit] with more to come.
  bool get capped => _results?.matches.capped ?? false;

  /// Brings the search up to date with [text], [query] and the flags. With
  /// [scope] — a stored find-in-selection range — the worker enumerates
  /// only matches lying wholly inside it, so its limit bounds the scope,
  /// not the document. When the held matches are not for exactly these, it
  /// schedules a search, and [page] serves nothing (or the matches carried
  /// through an edit) until it settles.
  void update(
    String text,
    String query, {
    required bool caseSensitive,
    required bool wholeWord,
    ({int start, int end})? scope,
  }) {
    _compile(query, caseSensitive);
    if (_pattern == null) {
      _stopSearching();
      _results = null;
      _replaceFailure = null;
      return;
    }
    final key = _Key(
      text,
      query,
      caseSensitive,
      wholeWord,
      scope?.start,
      scope?.end,
    );
    final results = _results;
    if (results != null && results.key.sameAs(key) && !results.provisional) {
      return;
    }
    if (_wanted?.sameAs(key) ?? false) return;
    if (results != null && !results.key.sameAs(key)) _results = null;
    _replaceFailure = null;
    _schedule(key);
  }

  /// Carries the held matches from [before] into [after], an edit that
  /// replaced `[start, end)` with text [delta] code units longer, and
  /// searches the edited text again. [scope] is the stored search scope
  /// as the edit left it — the controller maps it first, so a scope the
  /// edit consumed has already become null here.
  void followEdit(
    String before,
    String after, {
    required int start,
    required int end,
    required int delta,
    ({int start, int end})? scope,
  }) {
    final results = _results;
    if (results != null && identical(results.key.text, before)) {
      _results = _Results(
        results.key.withText(after).withScope(scope),
        results.matches.afterEdit(start: start, end: end, delta: delta),
        failure: results.failure,
        provisional: true,
      );
    } else {
      _results = null;
    }
    _replaceFailure = null;
    final search = _wanted ?? results?.key;
    if (_pattern == null || search == null) return;
    _schedule(search.withText(after).withScope(scope));
  }

  /// One page of the held matches of [text], in the shape literal search
  /// returns, with [SearchResult.precedingCount] always counted. [start] and
  /// [reverse] mean what they mean to `searchText`. With [scope] — a stored
  /// find-in-selection range — the page is a window of the matches lying
  /// wholly inside it, so counts stay scope-relative and stepping never
  /// leaves the range.
  SearchResult page(
    String text, {
    int? start,
    ({int start, int end})? scope,
    bool reverse = false,
    int limit = searchMatchLimit,
  }) {
    final results = _results;
    if (results == null || !identical(results.key.text, text) || limit <= 0) {
      return const SearchResult(
        matches: [],
        caseFolding: CaseFolding.exact,
        precedingCount: 0,
      );
    }
    final matches = results.matches;
    // The held list spans the document; the page is its in-scope window.
    // One match can still straddle the scope's far edge — a start inside
    // with an end outside — and matches never overlap, so it is the last
    // one in the window and simply drops.
    var low = 0;
    var high = matches.length;
    if (scope != null) {
      low = matches.indexAtOrAfter(scope.start);
      high = matches.indexAtOrAfter(scope.end);
      if (high > low && matches.endOf(high - 1) > scope.end) high--;
    }
    final int first;
    final int end;
    if (reverse) {
      end = math.min(
        high,
        start == null ? high : matches.indexAtOrAfter(start),
      );
      first = math.max(low, end - limit);
    } else {
      first = math.max(
        low,
        start == null ? low : matches.indexAtOrAfter(start),
      );
      end = math.min(high, first + limit);
    }
    return SearchResult(
      matches: [
        for (var i = first; i < end; i++)
          TextRange(start: matches.startOf(i), end: matches.endOf(i)),
      ],
      caseFolding: CaseFolding.exact,
      precedingCount: first - low,
    );
  }

  /// Replace All in a worker of its own, under the same budget, so it
  /// neither waits behind a search nor cancels one. Null when [query] is not
  /// a usable pattern, which [failure] then explains. With [scope], only
  /// the matches lying wholly inside it are replaced.
  Future<PatternOutcome<PatternReplacement?>?> replaceAll(
    String text,
    String query,
    String template, {
    required bool caseSensitive,
    required bool wholeWord,
    ({int start, int end})? scope,
  }) async {
    _compile(query, caseSensitive);
    if (_pattern == null) return null;
    _replacer?.dispose();
    final worker = _replacer = PatternWorker(budget: budget);
    try {
      final outcome = await worker.replaceAll(
        text,
        query,
        template,
        caseSensitive: caseSensitive,
        wholeWord: wholeWord,
        scope: scope,
      );
      if (!_disposed && outcome is PatternFailed<PatternReplacement?>) {
        _replaceFailure = outcome.failure;
      }
      return outcome;
    } finally {
      worker.dispose();
      if (identical(_replacer, worker)) _replacer = null;
    }
  }

  /// Stops searching, for a find bar that closed. The held matches stay, so
  /// Find Next on an unchanged document needs no new search.
  void reset() => _stopSearching();

  void dispose() {
    _disposed = true;
    _stopSearching();
    _replacer?.dispose();
    _replacer = null;
  }

  void _compile(String query, bool caseSensitive) {
    if (query == _compiledQuery && caseSensitive == _compiledCaseSensitive) {
      return;
    }
    _compiledQuery = query;
    _compiledCaseSensitive = caseSensitive;
    _pattern = null;
    _syntaxFailure = null;
    if (query.isEmpty) return;
    try {
      _pattern = FindPattern(query, caseSensitive: caseSensitive);
    } on FormatException catch (error) {
      _syntaxFailure = PatternUnusable(error.message);
    }
  }

  void _schedule(_Key key) {
    final generation = ++_generation;
    _wanted = key;
    _delay?.cancel();
    _delay = Timer(settleDelay, () => unawaited(_search(key, generation)));
  }

  Future<void> _search(_Key key, int generation) async {
    final worker = _worker ??= PatternWorker(budget: budget);
    final outcome = await worker.findAll(
      key.text,
      key.query,
      caseSensitive: key.caseSensitive,
      wholeWord: key.wholeWord,
      scope: key.scope,
    );
    // A newer search, a closed find bar or disposal makes this answer
    // stale: the text or query it describes may be gone.
    if (_disposed || generation != _generation) return;
    _wanted = null;
    switch (outcome) {
      case PatternCompleted(:final value):
        _results = _Results(key, value);
      case PatternFailed(:final failure):
        // Held like an answer, so the same search is not retried until the
        // text or the query changes.
        _results = _Results(key, PatternMatches.none, failure: failure);
      case PatternCancelled():
        return;
    }
    _onSettled();
  }

  void _stopSearching() {
    _generation++;
    _delay?.cancel();
    _delay = null;
    _wanted = null;
    _worker?.dispose();
    _worker = null;
  }
}

/// What a search was for: the text by identity, since a full comparison of
/// a large document per keystroke is what the cache is there to avoid.
final class _Key {
  const _Key(
    this.text,
    this.query,
    this.caseSensitive,
    this.wholeWord, [
    this.scopeStart,
    this.scopeEnd,
  ]);

  final String text;
  final String query;
  final bool caseSensitive;
  final bool wholeWord;
  final int? scopeStart;
  final int? scopeEnd;

  /// The stored find-in-selection range as the core's bounds record.
  ({int start, int end})? get scope =>
      scopeStart == null ? null : (start: scopeStart!, end: scopeEnd!);

  bool sameAs(_Key other) =>
      identical(text, other.text) &&
      query == other.query &&
      caseSensitive == other.caseSensitive &&
      wholeWord == other.wholeWord &&
      scopeStart == other.scopeStart &&
      scopeEnd == other.scopeEnd;

  _Key withText(String value) =>
      _Key(value, query, caseSensitive, wholeWord, scopeStart, scopeEnd);

  _Key withScope(({int start, int end})? scope) =>
      _Key(text, query, caseSensitive, wholeWord, scope?.start, scope?.end);
}

final class _Results {
  const _Results(
    this.key,
    this.matches, {
    this.failure,
    this.provisional = false,
  });

  final _Key key;
  final PatternMatches matches;
  final PatternFailure? failure;

  /// Carried through an edit rather than found in this text; a search of the
  /// edited text is on its way.
  final bool provisional;
}
