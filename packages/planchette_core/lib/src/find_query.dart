import 'editor_syntax.dart' show TextMatch, findSearchMatches, searchMatchLimit;

/// A find-bar query: literal text, or a regular expression, compiled once.
///
/// The editor re-runs the search on every keystroke in the find field, and again
/// on every keystroke in the document while the bar is open, so a pattern has to
/// compile once and then be reusable. It also has to be able to say that it is
/// unusable: a mistyped pattern that silently matched nothing looks exactly
/// like a file with no occurrences, which sends people looking in the wrong
/// place.
final class FindQuery {
  FindQuery._(this.text, this.isPattern, this._pattern, this._error);

  /// Plain text, matched as it stands.
  FindQuery.literal(String text) : this._(text, false, null, null);

  /// A regular expression, compiled here so a bad one is reported here.
  ///
  /// Compiled with [multiLine], so `^` and `$` anchor to a line the way they read
  /// in every other find bar rather than to the whole buffer.
  factory FindQuery.pattern(String text) {
    if (text.isEmpty) return FindQuery.literal('');
    try {
      return FindQuery._(text, true, RegExp(text, multiLine: true), null);
    } on FormatException catch (failure) {
      return FindQuery._(text, true, null, failure.message);
    }
  }

  /// What the user typed.
  final String text;

  /// Whether this is a pattern query, which the find bar shows as a badge.
  final bool isPattern;

  final RegExp? _pattern;

  /// Why this query cannot be used, or null when it can. Only a pattern query
  /// can fail.
  String? get error => _error;
  final String? _error;

  /// The case-insensitive twin, built at most once.
  RegExp? _insensitive;

  /// The pattern compiled without regard to case, built on first use.
  ///
  /// Case sensitivity is a toggle the user flips and searches again, not a
  /// property of what they typed, so it is applied here rather than baked into
  /// the query. Compiling it lazily means a case-sensitive search — the common
  /// one — never pays for the other.
  RegExp? _insensitiveOrNull() {
    final source = _pattern?.pattern;
    if (source == null) return null;
    // Stated rather than left to the default, which is `true`: a twin that
    // quietly compiled case-sensitively is the same search twice.
    return _insensitive ??= RegExp(source, caseSensitive: false, multiLine: true);
  }

  /// Every occurrence in [text], in order and without overlaps.
  ///
  /// A pattern that does not compile finds nothing, and says so through [error].
  /// [limit] bounds the work, which matters because the bar highlights every hit
  /// and a one-character query in a large file has hundreds of thousands of them.
  List<TextMatch> findIn(
    String text, {
    bool caseSensitive = false,
    int limit = searchMatchLimit,
  }) {
    if (limit <= 0 || text.isEmpty) return const [];
    final pattern = _pattern;
    if (pattern == null) {
      if (_error != null) return const [];
      return findSearchMatches(
        text,
        this.text,
        caseSensitive: caseSensitive,
        limit: limit,
      );
    }
    final effective = caseSensitive ? pattern : _insensitiveOrNull()!;
    final matches = <TextMatch>[];
    for (final match in effective.allMatches(text)) {
      // A pattern can match nothing — `x*`, `^`, `\b` — and the bar cannot
      // highlight or replace an empty range, so those are skipped rather than
      // reported. Skipping and not stopping matters: `a*` on `aab` finds `aa`
      // first and then an empty match, and stopping there would lose nothing
      // but stopping at a leading empty match would.
      if (match.end == match.start) continue;
      matches.add(TextMatch(start: match.start, end: match.end));
      if (matches.length >= limit) break;
    }
    return matches;
  }
}
