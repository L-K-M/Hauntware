/// Case-insensitive search over expanding folds: `ß` matches `ss`.
///
/// Internal to the search in `editor_syntax.dart`; not exported.
library;

/// Characters whose Unicode full case fold is longer than they are, with that
/// fold. Unicode's full table also expands Greek letters with a combining
/// iota (`ᾳ` to `αι`), Armenian ligatures and a few precomposed letters such
/// as `ŉ`; this covers the Latin ones a search is most often typed for.
/// Every key is one UTF-16 unit, which the fast path's scan relies on.
const Map<int, String> _expansions = {
  0x00DF: 'ss', // ß
  0x1E9E: 'ss', // ẞ, capital sharp s
  0x0130: 'i̇', // İ, capital I with dot above
  0xFB00: 'ff', // ﬀ
  0xFB01: 'fi', // ﬁ
  0xFB02: 'fl', // ﬂ
  0xFB03: 'ffi', // ﬃ
  0xFB04: 'ffl', // ﬄ
  0xFB05: 'st', // ﬅ
  0xFB06: 'st', // ﬆ
};

/// [query] with every expanding character replaced by its fold, then
/// folded with [fold], for the needle side of a search.
String foldQueryForSearch(String query, String Function(String) fold) {
  if (!_hasExpansion(query)) return fold(query);
  final expanded = StringBuffer();
  for (final unit in query.codeUnits) {
    expanded.write(_expansions[unit] ?? String.fromCharCode(unit));
  }
  return fold(expanded.toString());
}

/// A document folded for a case-insensitive search, with what it takes to
/// turn offsets into the folded [text] back into offsets into the original.
///
/// The map is sparse: one entry per expanded character, nothing for the
/// rest, so a document with no such character carries no map at all and its
/// offsets pass through unchanged.
final class FoldedSearchText {
  FoldedSearchText._(this.text, this._entries);

  /// The folded document a search runs on.
  final String text;

  /// Each expanded character's (folded start, original start), in order.
  /// Its folded end is its start plus its fold's length; its original end,
  /// its start plus one.
  final List<({int folded, int original, int length})>? _entries;

  /// Whether any offset needs translating. False for the common document.
  bool get isMapped => _entries != null;

  /// The folded offset of original [offset]. An offset is never inside an
  /// expanded character, since each is one unit.
  int folded(int offset) {
    final entries = _entries;
    if (entries == null) return offset;
    final at = _lastAtOrBefore(entries, offset, (entry) => entry.original);
    if (at < 0) return offset;
    final entry = entries[at];
    if (offset == entry.original) return entry.folded;
    return entry.folded + entry.length + (offset - entry.original - 1);
  }

  /// The original offset where a match starting at folded [offset] starts:
  /// a start inside an expanded character moves back to that character.
  int originalStart(int offset) => _original(offset, roundUp: false);

  /// The original offset where a match ending at folded [offset] ends: an
  /// end inside an expanded character moves on past it.
  int originalEnd(int offset) => _original(offset, roundUp: true);

  int _original(int offset, {required bool roundUp}) {
    final entries = _entries;
    if (entries == null) return offset;
    final at = _lastAtOrBefore(entries, offset, (entry) => entry.folded);
    if (at < 0) return offset;
    final entry = entries[at];
    final end = entry.folded + entry.length;
    if (offset >= end) return entry.original + 1 + (offset - end);
    if (offset == entry.folded) return entry.original;
    return roundUp ? entry.original + 1 : entry.original;
  }

  static int _lastAtOrBefore(
    List<({int folded, int original, int length})> entries,
    int offset,
    int Function(({int folded, int original, int length})) key,
  ) {
    var low = 0;
    var high = entries.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (key(entries[middle]) <= offset) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }
}

/// [text] folded with [fold] for a case-insensitive search, expanding the
/// characters whose full fold is longer. Null when [fold] itself changes the
/// length of a run of text: its offsets cannot be mapped back, so the
/// search compares exactly and says so.
FoldedSearchText? foldDocumentForSearch(
  String text,
  String Function(String) fold,
) {
  if (!_hasExpansion(text)) {
    final folded = fold(text);
    return folded.length == text.length
        ? FoldedSearchText._(folded, null)
        : null;
  }
  final out = StringBuffer();
  final entries = <({int folded, int original, int length})>[];
  var runStart = 0;
  var foldedLength = 0;
  bool foldRun(int end) {
    if (end == runStart) return true;
    final run = fold(text.substring(runStart, end));
    if (run.length != end - runStart) return false;
    out.write(run);
    foldedLength += run.length;
    return true;
  }

  for (var i = 0; i < text.length; i++) {
    final expansion = _expansions[text.codeUnitAt(i)];
    if (expansion == null) continue;
    if (!foldRun(i)) return null;
    entries.add((folded: foldedLength, original: i, length: expansion.length));
    out.write(expansion);
    foldedLength += expansion.length;
    runStart = i + 1;
  }
  if (!foldRun(text.length)) return null;
  return FoldedSearchText._(out.toString(), entries);
}

bool _hasExpansion(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    // Every key is at or above U+00DF; most text never reaches the lookup.
    if (unit >= 0xDF && _expansions.containsKey(unit)) return true;
  }
  return false;
}
