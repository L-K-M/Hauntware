/// Case-insensitive search over expanding folds: `ß` matches `ss`.
///
/// Internal to the search in `editor_syntax.dart`; only [unicodeCaseFold]
/// is exported.
library;

import 'dart:typed_data';

part 'unicode_case_fold_data.dart';

/// Unicode's common case folding, CaseFolding.txt status C, of [value]: the
/// default [CaseFolder] of a case-insensitive plain-text search.
///
/// Status C maps every character to exactly one character on the same side
/// of the BMP, so the result has [value]'s length and its unit *i* stands
/// for unit *i* of [value]. That makes it a valid fold for a document, and
/// together with the status F expansions the search applies first
/// ([foldDocumentForSearch]) it is Unicode *full* case folding: `ß` and
/// `ss`, `ﬁ` and `fi`, `ᾳ` and `αι`, and `σ`, `ς` and `Σ` all match. Turkic
/// (T) mappings are not applied, as Unicode's default folding does not.
/// Independent of the platform and of Dart's own case tables, so every host
/// finds the same matches. Lone surrogates pass through unchanged.
String unicodeCaseFold(String value) {
  // For ASCII, status C is exactly A-Z to a-z, and the platform's own
  // lowercasing does that several times faster than the loop below.
  if (_isAscii(value)) return value.toLowerCase();
  final table = _bmpFolds;
  Uint16List? out;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit & _surrogateMask == _highSurrogate &&
        i + 1 < value.length &&
        value.codeUnitAt(i + 1) & _surrogateMask == _lowSurrogate) {
      final low = value.codeUnitAt(i + 1);
      final point = 0x10000 + ((unit & 0x3ff) << 10) + (low & 0x3ff);
      final folded = _foldSupplementary(point);
      if (folded != point) {
        out ??= _copyPrefix(value, i);
        out[i] = _highSurrogate | ((folded - 0x10000) >> 10);
        out[i + 1] = _lowSurrogate | ((folded - 0x10000) & 0x3ff);
      } else if (out != null) {
        out[i] = unit;
        out[i + 1] = low;
      }
      i++;
      continue;
    }
    final folded = table[unit];
    if (folded != unit) out ??= _copyPrefix(value, i);
    if (out != null) out[i] = folded;
  }
  return out == null ? value : String.fromCharCodes(out);
}

bool _isAscii(String value) {
  for (var i = 0; i < value.length; i++) {
    if (value.codeUnitAt(i) >= 0x80) return false;
  }
  return true;
}

const _surrogateMask = 0xfc00;
const _highSurrogate = 0xd800;
const _lowSurrogate = 0xdc00;

Uint16List _copyPrefix(String value, int end) {
  final out = Uint16List(value.length);
  for (var i = 0; i < end; i++) {
    out[i] = value.codeUnitAt(i);
  }
  return out;
}

/// Every BMP unit's status C fold, looked up by index: folding a 4 MiB
/// document is one table read per unit instead of a search of the ranges.
/// Built on first use, 128 KiB per isolate.
final Uint16List _bmpFolds = () {
  final table = Uint16List(0x10000);
  for (var unit = 0; unit < table.length; unit++) {
    table[unit] = unit;
  }
  for (final range in _commonFoldRanges) {
    if (range.start >= 0x10000) break;
    for (var point = range.start; point <= range.end; point += range.stride) {
      table[point] = point + range.delta;
    }
  }
  return table;
}();

int _foldSupplementary(int point) {
  var low = 0;
  var high = _commonFoldRanges.length - 1;
  while (low <= high) {
    final middle = (low + high) >> 1;
    final range = _commonFoldRanges[middle];
    if (point < range.start) {
      high = middle - 1;
    } else if (point > range.end) {
      low = middle + 1;
    } else {
      return (point - range.start) % range.stride == 0
          ? point + range.delta
          : point;
    }
  }
  return point;
}

/// [query] with every expanding character replaced by its fold, then
/// folded with [fold], for the needle side of a search.
String foldQueryForSearch(String query, String Function(String) fold) {
  if (!_hasExpansion(query)) return fold(query);
  final expanded = StringBuffer();
  for (final unit in query.codeUnits) {
    expanded.write(_fullFoldExpansions[unit] ?? String.fromCharCode(unit));
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
///
/// The last result is kept for the identical text and fold (P1). Typing a
/// query, stepping through matches and repainting them search the same
/// unchanged document again and again, and folding it was two thirds of
/// each search: a 4 MiB search took 38 ms with it and takes 12 ms without.
/// Strings are immutable, so the identity check is exact and costs
/// nothing; an edit makes a new string and folds again. The memo holds one
/// document and its folded copy per isolate until the next search.
FoldedSearchText? foldDocumentForSearch(
  String text,
  String Function(String) fold,
) {
  final last = _lastFolded;
  if (last != null && identical(last.text, text) && last.fold == fold) {
    return last.result;
  }
  final result = _foldDocument(text, fold);
  _lastFolded = (text: text, fold: fold, result: result);
  return result;
}

({String text, String Function(String) fold, FoldedSearchText? result})?
_lastFolded;

FoldedSearchText? _foldDocument(String text, String Function(String) fold) {
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
    final expansion = _fullFoldExpansions[text.codeUnitAt(i)];
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
    // Every key is at or above U+00DF (ß); most text never reaches the
    // lookup.
    if (unit >= 0xDF && _fullFoldExpansions.containsKey(unit)) return true;
  }
  return false;
}
