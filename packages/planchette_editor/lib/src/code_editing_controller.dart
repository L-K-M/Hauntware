// Extracted from Poltergeist and Seance; see the repository provenance notes.
import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;
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
///
/// When [tabStyle] is given, runs of tab characters get it merged over their
/// surrounding style (see [CodeEditingController.tabWidth]).
List<InlineSpan> buildHighlightedSpans({
  required String text,
  required List<SyntaxToken> tokens,
  required List<TextRange> matches,
  required int activeMatchIndex,
  required EditorSyntaxTheme theme,
  TextStyle? tabStyle,
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
    _addSegment(spans, text.substring(position, end), style, tabStyle);
    position = end;
  }
  return spans;
}

void _addSegment(
  List<InlineSpan> spans,
  String segment,
  TextStyle? style,
  TextStyle? tabStyle,
) {
  if (tabStyle == null || !segment.contains('\t')) {
    spans.add(TextSpan(text: segment, style: style));
    return;
  }
  final tab = style?.merge(tabStyle) ?? tabStyle;
  var from = 0;
  while (from < segment.length) {
    final at = segment.indexOf('\t', from);
    if (at < 0) break;
    var run = at;
    while (run < segment.length && segment.codeUnitAt(run) == 0x09) {
      run++;
    }
    if (at > from) {
      spans.add(TextSpan(text: segment.substring(from, at), style: style));
    }
    spans.add(TextSpan(text: segment.substring(at, run), style: tab));
    from = run;
  }
  if (from < segment.length) {
    spans.add(TextSpan(text: segment.substring(from), style: style));
  }
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

  /// How many spaces wide a tab character renders. Flutter's paragraph engine
  /// draws a tab as a single space, which flattens tab-indented files, so each
  /// tab gets letter spacing for the remaining width. This is a fixed width,
  /// not a tab stop: a tab after text is still [tabWidth] spaces wide.
  int get tabWidth => _tabWidth;
  int _tabWidth = defaultIndentWidth;
  set tabWidth(int value) {
    if (_tabWidth == value) return;
    _tabWidth = value;
    notifyListeners();
  }

  String? _tabScannedText;
  bool _hasTabs = false;
  TextStyle? _spaceStyle;
  TextScaler? _spaceScaler;
  double _spaceWidth = 0;

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

  TextStyle? _tabStyleFor(BuildContext context, TextStyle? style) {
    if (!identical(_tabScannedText, text)) {
      _tabScannedText = text;
      _hasTabs = text.contains('\t');
    }
    if (!_hasTabs || tabWidth <= 1) return null;
    final scaler =
        MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
    if (_spaceStyle != style || _spaceScaler != scaler) {
      final painter = TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      _spaceWidth = painter.width;
      painter.dispose();
      _spaceStyle = style;
      _spaceScaler = scaler;
    }
    // Letter spacing is not scaled by the text scaler; the measured space is.
    return TextStyle(letterSpacing: _spaceWidth * (tabWidth - 1));
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = withComposing && value.isComposingRangeValid;
    final tabStyle = text.isEmpty ? null : _tabStyleFor(context, style);
    if (composing) {
      if (tabStyle == null) {
        return super.buildTextSpan(
          context: context,
          style: style,
          withComposing: withComposing,
        );
      }
      // Keep tab widths stable while an input method composes, with the
      // same underline the default span uses.
      final underline =
          style?.merge(const TextStyle(decoration: TextDecoration.underline)) ??
          const TextStyle(decoration: TextDecoration.underline);
      final spans = <InlineSpan>[];
      _addSegment(spans, value.composing.textBefore(text), null, tabStyle);
      _addSegment(spans, value.composing.textInside(text), underline, tabStyle);
      _addSegment(spans, value.composing.textAfter(text), null, tabStyle);
      return TextSpan(style: style, children: spans);
    }
    if (text.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final tokens = _tokensFor(text);
    if (tokens.isEmpty && _matches.isEmpty) {
      if (tabStyle == null) return TextSpan(style: style, text: text);
      final spans = <InlineSpan>[];
      _addSegment(spans, text, null, tabStyle);
      return TextSpan(style: style, children: spans);
    }
    return TextSpan(
      style: style,
      children: buildHighlightedSpans(
        text: text,
        tokens: tokens,
        matches: _matches,
        activeMatchIndex: _activeMatchIndex,
        theme: theme,
        tabStyle: tabStyle,
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
}) => searchText(
  text,
  query,
  caseSensitive: caseSensitive,
  limit: limit,
  fold: fold,
).matches;

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
