// Extracted from Poltergeist and Seance; see the repository provenance notes.
import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;
import 'package:planchette_core/planchette_core.dart' as core;

/// Token and search-match colors. Pass one to [PlanchetteEditor.syntaxTheme],
/// or add it to a host's `ThemeData.extensions` to style every editor.
class EditorSyntaxTheme extends ThemeExtension<EditorSyntaxTheme> {
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
    // Darkened from 0xFF3D8A78, which held white text at 4.11:1 — the least
    // readable pair in either theme. 0xFF377A69 clears AA at 5.06:1.
    activeMatchBackground: Color(0xFF377A69),
    activeMatchForeground: Color(0xFFFFFFFF),
  );

  static EditorSyntaxTheme of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  @override
  EditorSyntaxTheme copyWith({
    Color? comment,
    Color? string,
    Color? number,
    Color? keyword,
    Color? meta,
    Color? matchBackground,
    Color? matchForeground,
    Color? activeMatchBackground,
    Color? activeMatchForeground,
  }) => EditorSyntaxTheme(
    comment: comment ?? this.comment,
    string: string ?? this.string,
    number: number ?? this.number,
    keyword: keyword ?? this.keyword,
    meta: meta ?? this.meta,
    matchBackground: matchBackground ?? this.matchBackground,
    matchForeground: matchForeground ?? this.matchForeground,
    activeMatchBackground: activeMatchBackground ?? this.activeMatchBackground,
    activeMatchForeground: activeMatchForeground ?? this.activeMatchForeground,
  );

  @override
  EditorSyntaxTheme lerp(EditorSyntaxTheme? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return EditorSyntaxTheme(
      comment: mix(comment, other.comment),
      string: mix(string, other.string),
      number: mix(number, other.number),
      keyword: mix(keyword, other.keyword),
      meta: mix(meta, other.meta),
      matchBackground: mix(matchBackground, other.matchBackground),
      matchForeground: mix(matchForeground, other.matchForeground),
      activeMatchBackground: mix(
        activeMatchBackground,
        other.activeMatchBackground,
      ),
      activeMatchForeground: mix(
        activeMatchForeground,
        other.activeMatchForeground,
      ),
    );
  }

  // Value equality, so ThemeData built afresh in a host's build compares
  // equal and does not restart the theme animation.
  @override
  bool operator ==(Object other) =>
      other is EditorSyntaxTheme &&
      other.comment == comment &&
      other.string == string &&
      other.number == number &&
      other.keyword == keyword &&
      other.meta == meta &&
      other.matchBackground == matchBackground &&
      other.matchForeground == matchForeground &&
      other.activeMatchBackground == activeMatchBackground &&
      other.activeMatchForeground == activeMatchForeground;

  @override
  int get hashCode => Object.hash(
    comment,
    string,
    number,
    keyword,
    meta,
    matchBackground,
    matchForeground,
    activeMatchBackground,
    activeMatchForeground,
  );

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

  /// The syntax tokens of the whole text, for a command that must tell code
  /// from strings and comments. Empty past [syntaxHighlightingMaxChars], as
  /// for painting: tokenizing a document that large took up to half a second
  /// after every edit and could meet a tokenizer's worst case, so commands
  /// then treat the whole text as code.
  List<SyntaxToken> get syntaxTokens => _tokensFor(text);

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
  CaseFolder fold = _defaultCaseFolder,
  int? start,
  bool reverse = false,
}) => core
    .searchText(
      text,
      query,
      caseSensitive: caseSensitive,
      limit: limit,
      fold: fold,
      start: start,
      reverse: reverse,
    )
    .matches
    .map((match) => TextRange(start: match.start, end: match.end))
    .toList(growable: false);

String _defaultCaseFolder(String value) => value.toLowerCase();

/// A search outcome in Flutter ranges, carrying the case-handling report that
/// the pure-Dart [core.SearchResult] gives its callers.
final class SearchResult {
  const SearchResult({required this.matches, required this.caseFolding});

  final List<TextRange> matches;
  final CaseFolding caseFolding;

  bool get caseFoldedExactly => caseFolding == CaseFolding.exact;
}

/// [core.searchText] with Flutter ranges, keeping its case-handling report.
SearchResult searchText(
  String text,
  String query, {
  bool caseSensitive = false,
  int limit = searchMatchLimit,
  CaseFolder fold = _defaultCaseFolder,
}) {
  final result = core.searchText(
    text,
    query,
    caseSensitive: caseSensitive,
    limit: limit,
    fold: fold,
  );
  return SearchResult(
    matches: [
      for (final match in result.matches)
        TextRange(start: match.start, end: match.end),
    ],
    caseFolding: result.caseFolding,
  );
}
