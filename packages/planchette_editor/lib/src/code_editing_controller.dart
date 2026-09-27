// Extracted from Poltergeist and Seance; see the repository provenance notes.
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

  /// How many leading spaces [outdent] lifts on a line that has no tab —
  /// the common four-space indent. Indent itself always inserts a literal
  /// tab; a spaces-mode belongs to a future indentation setting.
  static const int _outdentSpaces = 4;

  /// The document field's Tab: inserts a tab at a collapsed caret, or
  /// indents every line the selection touches. A selection ending exactly
  /// at a line start does not pull that trailing line in — the same rule
  /// VSCode applies. The expanded selection covers the touched lines.
  void indent() {
    final selection = this.selection;
    if (!selection.isValid) return;
    if (selection.isCollapsed) {
      final offset = selection.extentOffset.clamp(0, text.length);
      value = TextEditingValue(
        text: text.replaceRange(offset, offset, '\t'),
        selection: TextSelection.collapsed(offset: offset + 1),
      );
      return;
    }
    final starts = lineStartOffsets(text);
    final (first, last) = _touchedLines(starts, selection);
    final buffer = StringBuffer();
    var cursor = 0;
    for (var line = first; line <= last; line++) {
      buffer
        ..write(text.substring(cursor, starts[line]))
        ..write('\t');
      cursor = starts[line];
    }
    buffer.write(text.substring(cursor));
    final end = _lineEnd(starts, last) + (last - first + 1);
    value = TextEditingValue(
      text: buffer.toString(),
      // A selection dragged upward keeps its direction: base stays on the
      // anchor side instead of collapsing to the line start.
      selection: selection.extentOffset >= selection.baseOffset
          ? TextSelection(baseOffset: starts[first], extentOffset: end)
          : TextSelection(baseOffset: end, extentOffset: starts[first]),
    );
  }

  /// Shift+Tab in the document: lifts one tab (or up to [_outdentSpaces]
  /// leading spaces) from every touched line. Lines with no leading
  /// whitespace are left alone; a caret line with none is a no-op, so the
  /// undo stack is not polluted by dead presses.
  void outdent() {
    final selection = this.selection;
    if (!selection.isValid) return;
    final starts = lineStartOffsets(text);
    final (first, last) = _touchedLines(starts, selection);
    final buffer = StringBuffer();
    var cursor = 0;
    var removed = 0;
    var caretShift = 0;
    for (var line = first; line <= last; line++) {
      buffer.write(text.substring(cursor, starts[line]));
      cursor = starts[line];
      var width = 0;
      if (cursor < text.length && text.codeUnitAt(cursor) == 0x09) {
        width = 1;
      } else {
        while (width < _outdentSpaces &&
            cursor + width < text.length &&
            text.codeUnitAt(cursor + width) == 0x20) {
          width++;
        }
      }
      // A collapsed caret slides left by what was stripped before it;
      // inside the stripped run it lands on the line's new first column.
      if (width > 0 && starts[line] < selection.extentOffset) {
        final visible = selection.extentOffset - starts[line];
        caretShift += visible < width ? visible : width;
      }
      cursor += width;
      removed += width;
    }
    buffer.write(text.substring(cursor));
    if (removed == 0) return;
    final end = _lineEnd(starts, last) - removed;
    value = TextEditingValue(
      text: buffer.toString(),
      selection: selection.isCollapsed
          ? TextSelection.collapsed(offset: selection.extentOffset - caretShift)
          : selection.extentOffset >= selection.baseOffset
          ? TextSelection(baseOffset: starts[first], extentOffset: end)
          : TextSelection(baseOffset: end, extentOffset: starts[first]),
    );
  }

  /// First and last line indices the selection overlaps. `end - 1` keeps a
  /// selection that stops at a line boundary out of that trailing line.
  (int, int) _touchedLines(List<int> starts, TextSelection selection) {
    final lastOffset = selection.end > selection.start
        ? selection.end - 1
        : selection.end;
    var first = 0, last = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= selection.start) first = i;
      if (starts[i] <= lastOffset) last = i;
    }
    return (first, last);
  }

  int _lineEnd(List<int> starts, int line) =>
      line + 1 < starts.length ? starts[line + 1] : text.length;

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
