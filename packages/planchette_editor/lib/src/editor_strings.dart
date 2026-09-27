/// User-facing editor copy. Hosts can adapt their existing localization system
/// without taking a dependency on another application's generated resources.
class EditorStrings {
  const EditorStrings();

  String get findHint => 'Find in file';
  String get matchCase => 'Match case';
  String get regularExpression => 'Regular expression';
  String get clearSearch => 'Clear the search';
  String get previousMatch => 'Previous match';
  String get nextMatch => 'Next match';
  String get closeSearch => 'Close search';
  String get noMatches => 'No matches';
  String get showReplace => 'Find and replace';
  String get replaceHint => 'Replace with';
  String get replace => 'Replace';
  String get replaceAll => 'Replace all';
  String get unsaved => 'Unsaved edits';
  String get saving => 'Saving…';
  String matchCount(int current, int total, {bool capped = false}) =>
      '$current/$total${capped ? '+' : ''}';

  /// What the status bar says about a non-empty selection. A collapsed caret
  /// has nothing to report, and the caller omits this rather than asking for a
  /// string it will not show — so this never returns null and does not pretend
  /// to know which case it is in.
  String selectionCount(int words, int characters) =>
      '$words ${words == 1 ? 'word' : 'words'} · $characters selected';

  String documentPosition(int line, int column, int lines, int bytes) =>
      'Ln $line, Col $column · $lines lines · $bytes bytes';
}
