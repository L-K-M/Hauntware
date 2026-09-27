// Extracted from Poltergeist and Seance; see the repository provenance notes.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart' hide findSearchMatches;
import 'package:planchette_core/planchette_core.dart' as core;

class EditorSyntaxTheme {
  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color meta;
  final Color matchBackground;
  final Color matchForeground;
  final Color activeMatchBackground;
  final Color activeMatchForeground;

  const EditorSyntaxTheme({
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.meta,
    required this.matchBackground,
    required this.matchForeground,
    required this.activeMatchBackground,
    required this.activeMatchForeground,
  });

  static const dark = EditorSyntaxTheme(
    comment: Color(0xFF91A3AB),
    string: Color(0xFF7FD8B0),
    number: Color(0xFFE6C177),
    keyword: Color(0xFFC9A6E8),
    meta: Color(0xFF7FB5F7),
    matchBackground: Color(0x66E6C177),
    matchForeground: Color(0xFFF2F6F5),
    activeMatchBackground: Color(0xFF8AD8C8),
    activeMatchForeground: Color(0xFF10181A),
  );

  static const light = EditorSyntaxTheme(
    comment: Color(0xFF5F6B72),
    string: Color(0xFF1F7A54),
    number: Color(0xFF7A5A00),
    keyword: Color(0xFF8A3FA8),
    meta: Color(0xFF2B4FBF),
    matchBackground: Color(0x80F5D89B),
    matchForeground: Color(0xFF233028),
    activeMatchBackground: Color(0xFF3D8A78),
    activeMatchForeground: Color(0xFFFFFFFF),
  );

  static EditorSyntaxTheme of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  Color colorFor(SyntaxTokenType type) => switch (type) {
    SyntaxTokenType.comment => comment,
    SyntaxTokenType.string => string,
    SyntaxTokenType.number => number,
    SyntaxTokenType.keyword => keyword,
    SyntaxTokenType.meta => meta,
  };
}

/// Flatten syntax [tokens] and search [matches] into styled spans. Both
/// inputs are ordered and internally non-overlapping; a search hit overlaying
/// a token keeps the token's color and adds the hit background.
List<InlineSpan> buildHighlightedSpans({
  required String text,
  required List<SyntaxToken> tokens,
  required List<TextRange> matches,
  required int activeMatchIndex,
  required EditorSyntaxTheme theme,
}) {
  final spans = <InlineSpan>[];
  final n = text.length;
  var position = 0;
  var tokenIndex = 0;
  var matchIndex = 0;
  while (position < n) {
    while (tokenIndex < tokens.length && tokens[tokenIndex].end <= position) {
      tokenIndex++;
    }
    while (matchIndex < matches.length && matches[matchIndex].end <= position) {
      matchIndex++;
    }
    final token = tokenIndex < tokens.length ? tokens[tokenIndex] : null;
    final match = matchIndex < matches.length ? matches[matchIndex] : null;
    final inToken = token != null && token.start <= position;
    final inMatch = match != null && match.start <= position;
    var end = n;
    if (token != null) end = end.clamp(0, inToken ? token.end : token.start);
    if (match != null) end = end.clamp(0, inMatch ? match.end : match.start);
    TextStyle? style;
    if (inToken) style = TextStyle(color: theme.colorFor(token.type));
    if (inMatch) {
      final active = matchIndex == activeMatchIndex;
      style = (style ?? const TextStyle()).copyWith(
        color: active ? theme.activeMatchForeground : theme.matchForeground,
        backgroundColor: active
            ? theme.activeMatchBackground
            : theme.matchBackground,
      );
    }
    spans.add(TextSpan(text: text.substring(position, end), style: style));
    position = end;
  }
  return spans;
}

/// A [TextEditingController] that renders syntax and search-match highlights.
///
/// Tokenization is memoized on the text instance, so selection movement and
/// repaints don't re-scan; only actual edits do. During IME composition it
/// falls back to the default span (plain text + composing underline) so
/// highlighting can never fight the input method.
class CodeEditingController extends TextEditingController {
  SyntaxLanguage? language;
  EditorSyntaxTheme theme;

  List<TextRange> _matches = const [];
  int _activeMatchIndex = -1;

  String? _tokenizedText;
  SyntaxLanguage? _tokenizedLanguage;
  List<SyntaxToken> _tokens = const [];

  CodeEditingController({this.language, this.theme = EditorSyntaxTheme.dark});

  List<TextRange> get searchMatches => _matches;
  int get activeMatchIndex => _activeMatchIndex;

  void setSearchMatches(List<TextRange> matches, int activeIndex) {
    if (identical(_matches, matches) && _activeMatchIndex == activeIndex) {
      return;
    }
    _matches = matches;
    _activeMatchIndex = activeIndex;
    notifyListeners();
  }

  List<SyntaxToken> _tokensFor(String text) {
    final language = this.language;
    if (language == null || text.length > syntaxHighlightingMaxChars) {
      return const [];
    }
    if (!identical(_tokenizedText, text) ||
        !identical(_tokenizedLanguage, language)) {
      _tokens = tokenizeSyntax(text, language);
      _tokenizedText = text;
      _tokenizedLanguage = language;
    }
    return _tokens;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = withComposing && value.isComposingRangeValid;
    if (composing || text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final tokens = _tokensFor(text);
    if (tokens.isEmpty && _matches.isEmpty) {
      return TextSpan(style: style, text: text);
    }
    return TextSpan(
      style: style,
      children: buildHighlightedSpans(
        text: text,
        tokens: tokens,
        matches: _matches,
        activeMatchIndex: _activeMatchIndex,
        theme: theme,
      ),
    );
  }

  /// The (first, last) line indices the selection touches. An extent that
  /// lands exactly on a line start does not touch that line.
  (int, int) _selectedLines(List<int> starts) {
    int lineOf(int offset) {
      var lo = 0, hi = starts.length - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) ~/ 2;
        if (starts[mid] <= offset) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return lo;
    }

    final base = selection.baseOffset.clamp(0, text.length);
    final extent = selection.extentOffset.clamp(0, text.length);
    final first = lineOf(math.min(base, extent));
    var last = lineOf(math.max(base, extent));
    if (last > first && starts[last] == math.max(base, extent)) last--;
    return (first, last);
  }

  int _lineEnd(List<int> starts, int i) =>
      i + 1 < starts.length ? starts[i + 1] : text.length;

  void _commit(String newText, TextSelection newSelection) {
    value = value.copyWith(
      text: newText,
      selection: newSelection,
      composing: TextRange.empty,
    );
  }

  /// Duplicates the lines the selection touches, selecting the copy.
  void duplicateLines() {
    final text = this.text;
    if (text.isEmpty) return;
    final starts = lineStartOffsets(text);
    final (first, last) = _selectedLines(starts);
    final s = starts[first];
    final e = _lineEnd(starts, last);
    final block = text.substring(s, e);

    final String newText;
    final int shift;
    if (block.endsWith('\n')) {
      newText = '${text.substring(0, e)}$block${text.substring(e)}';
      shift = 0;
    } else {
      // The copied last line lacks the newline it needs to sit on.
      newText = '${text.substring(0, e)}\n$block';
      shift = 1;
    }
    _commit(
      newText,
      TextSelection(
        baseOffset:
            e + shift + (selection.baseOffset - s).clamp(0, block.length),
        extentOffset:
            e + shift + (selection.extentOffset - s).clamp(0, block.length),
      ),
    );
  }

  /// Moves the selected lines one line up or down, carrying the selection
  /// with them. A no-op against the document boundary.
  void moveLines({required bool up}) {
    final text = this.text;
    if (text.isEmpty) return;
    final starts = lineStartOffsets(text);
    final (first, last) = _selectedLines(starts);
    if (up ? first == 0 : last == starts.length - 1) return;
    final s = starts[first];
    final e = _lineEnd(starts, last);
    final block = text.substring(s, e);

    final String newText;
    final int delta;
    if (up) {
      final above = text.substring(starts[first - 1], s);
      newText = block.endsWith('\n')
          ? '${text.substring(0, starts[first - 1])}$block$above${text.substring(e)}'
          // Moving the unterminated final line up: lend it the newline
          // and let the line above become the unterminated tail.
          : '${text.substring(0, starts[first - 1])}$block\n${above.substring(0, above.length - 1)}';
      delta = -above.length;
    } else {
      final nextEnd = _lineEnd(starts, last + 1);
      final next = text.substring(e, nextEnd);
      newText = next.endsWith('\n')
          ? '${text.substring(0, s)}$next$block${text.substring(nextEnd)}'
          // The line below is final and unterminated: the moved block
          // lends it the newline.
          : '${text.substring(0, s)}$next\n${block.substring(0, block.length - 1)}';
      // The block is displaced by everything spliced in ahead of it: the
      // next line, plus the newline it lends in the unterminated case.
      delta = next.length + (next.endsWith('\n') ? 0 : 1);
    }
    _commit(
      newText,
      TextSelection(
        baseOffset: selection.baseOffset + delta,
        extentOffset: selection.extentOffset + delta,
      ),
    );
  }

  /// Deletes the lines the selection touches, leaving the caret where
  /// they started.
  void deleteLines() {
    final text = this.text;
    if (text.isEmpty) return;
    final starts = lineStartOffsets(text);
    final (first, last) = _selectedLines(starts);
    var s = starts[first];
    final e = _lineEnd(starts, last);
    // Deleting the final unterminated line removes the newline before it
    // rather than leaving a dangling one.
    if (e == text.length && s > 0) s--;
    final newText = text.substring(0, s) + text.substring(e);
    _commit(
      newText,
      TextSelection.collapsed(offset: math.min(s, newText.length)),
    );
  }

  /// Joins the selected lines — or this line and the next for a caret —
  /// collapsing each boundary to a single space.
  void joinLines() {
    final text = this.text;
    if (text.isEmpty) return;
    final starts = lineStartOffsets(text);
    var (first, last) = _selectedLines(starts);
    if (last == first) {
      if (first == starts.length - 1) return;
      last = first + 1;
    }
    final s = starts[first];
    var e = _lineEnd(starts, last);
    if (text.codeUnitAt(e - 1) == 0x0A) e--;

    final joined = StringBuffer();
    var caretInResult = 0;
    for (var i = first; i <= last; i++) {
      var lineEnd = _lineEnd(starts, i);
      if (text.codeUnitAt(lineEnd - 1) == 0x0A) lineEnd--;
      final piece = text.substring(starts[i], lineEnd);
      if (i == first) {
        joined.write(piece.trimRight());
        caretInResult = joined.length;
      } else if (piece.trim().isNotEmpty) {
        joined.write(' ');
        joined.write(piece.trim());
      }
    }
    _commit(
      text.substring(0, s) + joined.toString() + text.substring(e),
      TextSelection.collapsed(offset: s + caretInResult),
    );
  }
}

/// Flutter ranges for the shared pure-Dart literal search algorithm.
List<TextRange> findSearchMatches(
  String text,
  String query, {
  bool caseSensitive = false,
  int limit = searchMatchLimit,
}) => [
  for (final match in core.findSearchMatches(
    text,
    query,
    caseSensitive: caseSensitive,
    limit: limit,
  ))
    TextRange(start: match.start, end: match.end),
];
