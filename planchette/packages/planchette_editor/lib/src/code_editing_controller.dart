// Extracted from Poltergeist and Seance; see the repository provenance notes.
import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;
import 'package:planchette_core/planchette_core.dart' as core;

/// Token, search-match and problem colors. Pass one to
/// [PlanchetteEditor.syntaxTheme], or add it to a host's
/// `ThemeData.extensions` to style every editor.
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

  /// The wash under a find-in-selection range — fainter than
  /// [matchBackground] so matches still stand out inside it.
  final Color searchScopeBackground;

  /// The wavy underline and line number of an error, such as JSON that does
  /// not parse, and of a warning, such as a key set twice. Both mark text
  /// in every token colour, so they need contrast with the background.
  final Color error;
  final Color warning;

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
    required this.searchScopeBackground,
    required this.error,
    required this.warning,
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
    searchScopeBackground: Color(0x22E6C177),
    error: Color(0xFFF2777A),
    warning: Color(0xFFF0A35E),
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
    searchScopeBackground: Color(0x33F5D89B),
    error: Color(0xFFC62828),
    warning: Color(0xFFA35200),
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
    Color? searchScopeBackground,
    Color? error,
    Color? warning,
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
    searchScopeBackground: searchScopeBackground ?? this.searchScopeBackground,
    error: error ?? this.error,
    warning: warning ?? this.warning,
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
      searchScopeBackground: mix(
        searchScopeBackground,
        other.searchScopeBackground,
      ),
      error: mix(error, other.error),
      warning: mix(warning, other.warning),
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
      other.activeMatchForeground == activeMatchForeground &&
      other.searchScopeBackground == searchScopeBackground &&
      other.error == error &&
      other.warning == warning;

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
    searchScopeBackground,
    error,
    warning,
  );

  Color colorFor(SyntaxTokenType type) => switch (type) {
    SyntaxTokenType.comment => comment,
    SyntaxTokenType.string => string,
    SyntaxTokenType.number => number,
    SyntaxTokenType.keyword => keyword,
    SyntaxTokenType.meta => meta,
  };

  /// The colour that marks a problem of [severity].
  Color problemColor(TextProblemSeverity severity) => switch (severity) {
    TextProblemSeverity.error => error,
    TextProblemSeverity.warning => warning,
  };
}

/// Flatten syntax [tokens] and search [matches] into styled spans. Both
/// inputs are ordered and internally non-overlapping; a search hit overlaying
/// a token keeps the token's color and adds the hit background. [scope],
/// a stored find-in-selection range, washes the text inside it — under any
/// match, whose own background stays on top. [problems], in document order,
/// add a wavy underline in their severity's colour over whatever else styles
/// the text; where two overlap, the later one starts where the earlier ends.
///
/// One `TextStyle` per token type is built up front and shared by every
/// span, because a highlighted document produces thousands of spans per
/// frame and a fresh `TextStyle` for each one is pure garbage.
List<InlineSpan> buildHighlightedSpans({
  required String text,
  required List<SyntaxToken> tokens,
  required List<TextRange> matches,
  required int activeMatchIndex,
  required EditorSyntaxTheme theme,
  TextRange? scope,
  List<TextProblem> problems = const [],
}) {
  final tokenStyles = <SyntaxTokenType, TextStyle>{
    for (final type in SyntaxTokenType.values)
      type: TextStyle(color: theme.colorFor(type)),
  };
  final underlines = {
    for (final severity in TextProblemSeverity.values)
      severity: TextStyle(
        decoration: TextDecoration.underline,
        decorationStyle: TextDecorationStyle.wavy,
        decorationColor: theme.problemColor(severity),
      ),
  };
  final spans = <InlineSpan>[];
  final n = text.length;
  final scopeStart = scope?.start.clamp(0, n) ?? 0;
  final scopeEnd = scope?.end.clamp(0, n) ?? 0;
  var position = 0;
  var tokenIndex = 0;
  var matchIndex = 0;
  var problemIndex = 0;
  while (position < n) {
    while (tokenIndex < tokens.length && tokens[tokenIndex].end <= position) {
      tokenIndex++;
    }
    while (matchIndex < matches.length && matches[matchIndex].end <= position) {
      matchIndex++;
    }
    while (problemIndex < problems.length &&
        problems[problemIndex].end <= position) {
      problemIndex++;
    }
    final token = tokenIndex < tokens.length ? tokens[tokenIndex] : null;
    final match = matchIndex < matches.length ? matches[matchIndex] : null;
    final problem = problemIndex < problems.length
        ? problems[problemIndex]
        : null;
    final inToken = token != null && token.start <= position;
    final inMatch = match != null && match.start <= position;
    final inProblem = problem != null && problem.start <= position;
    final inScope = position >= scopeStart && position < scopeEnd;
    var end = n;
    if (token != null) end = end.clamp(0, inToken ? token.end : token.start);
    if (match != null) end = end.clamp(0, inMatch ? match.end : match.start);
    if (problem != null) {
      end = end.clamp(0, inProblem ? problem.end : problem.start);
    }
    if (inScope) {
      end = end.clamp(0, scopeEnd);
    } else if (position < scopeStart) {
      end = end.clamp(0, scopeStart);
    }
    TextStyle? style = inToken ? tokenStyles[token.type] : null;
    if (inMatch) {
      final active = matchIndex == activeMatchIndex;
      style = (style ?? const TextStyle()).copyWith(
        color: active ? theme.activeMatchForeground : theme.matchForeground,
        backgroundColor: active
            ? theme.activeMatchBackground
            : theme.matchBackground,
      );
    } else if (inScope) {
      style = (style ?? const TextStyle()).copyWith(
        backgroundColor: theme.searchScopeBackground,
      );
    }
    if (inProblem) {
      final underline = underlines[problem.severity]!;
      style = style?.merge(underline) ?? underline;
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
  TextRange? _scope;
  List<TextProblem> _problems = const [];

  String? _tokenizedText;
  SyntaxLanguage? _tokenizedLanguage;
  List<SyntaxToken> _tokens = const [];

  CodeEditingController({this.language, this.theme = EditorSyntaxTheme.dark});

  List<TextRange> get searchMatches => _matches;
  int get activeMatchIndex => _activeMatchIndex;

  /// The stored find-in-selection range, or null when search covers the
  /// whole document. Painted as a wash so the scope survives the selection
  /// returning to match-stepping.
  TextRange? get searchScope => _scope;

  void setSearchScope(TextRange? scope) {
    if (_scope == scope) return;
    _scope = scope;
    notifyListeners();
  }

  /// The problems underlined, in document order.
  List<TextProblem> get problems => _problems;

  void setProblems(List<TextProblem> problems) {
    if (identical(_problems, problems)) return;
    assert(() {
      for (var i = 1; i < problems.length; i++) {
        if (problems[i].start < problems[i - 1].start) return false;
      }
      return true;
    }(), 'Problems are drawn in document order; sort them by start.');
    _problems = problems;
    notifyListeners();
  }

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
    final scope = _scope;
    if (tokens.isEmpty &&
        _matches.isEmpty &&
        scope == null &&
        _problems.isEmpty) {
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
        scope: scope,
        problems: _problems,
      ),
    );
  }
}

/// Flutter ranges for the shared pure-Dart literal search algorithm.
List<TextRange> findSearchMatches(
  String text,
  String query, {
  bool caseSensitive = false,
  bool wholeWord = false,
  int limit = searchMatchLimit,
  CaseFolder fold = _defaultCaseFolder,
  int? start,
  TextRange? scope,
  bool reverse = false,
}) => core
    .searchText(
      text,
      query,
      caseSensitive: caseSensitive,
      wholeWord: wholeWord,
      limit: limit,
      fold: fold,
      start: start,
      scope: scope == null ? null : (start: scope.start, end: scope.end),
      reverse: reverse,
    )
    .matches
    .map((match) => TextRange(start: match.start, end: match.end))
    .toList(growable: false);

String _defaultCaseFolder(String value) => value.toLowerCase();

/// A search outcome in Flutter ranges, carrying the case-handling report that
/// the pure-Dart [core.SearchResult] gives its callers.
final class SearchResult {
  const SearchResult({
    required this.matches,
    required this.caseFolding,
    this.precedingCount,
  });

  final List<TextRange> matches;
  final CaseFolding caseFolding;

  /// How many matches come before the first of [matches], when the search
  /// counted them; see [core.SearchResult.precedingCount].
  final int? precedingCount;

  bool get caseFoldedExactly => caseFolding == CaseFolding.exact;
}

/// [core.searchText] with Flutter ranges, keeping its case-handling report.
SearchResult searchText(
  String text,
  String query, {
  bool caseSensitive = false,
  bool wholeWord = false,
  int limit = searchMatchLimit,
  CaseFolder fold = _defaultCaseFolder,
  int? start,
  TextRange? scope,
  bool reverse = false,
}) {
  final result = core.searchText(
    text,
    query,
    caseSensitive: caseSensitive,
    wholeWord: wholeWord,
    limit: limit,
    fold: fold,
    start: start,
    scope: scope == null ? null : (start: scope.start, end: scope.end),
    reverse: reverse,
  );
  return SearchResult(
    matches: [
      for (final match in result.matches)
        TextRange(start: match.start, end: match.end),
    ],
    caseFolding: result.caseFolding,
    precedingCount: result.precedingCount,
  );
}
