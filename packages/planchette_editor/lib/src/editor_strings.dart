/// User-facing editor copy. Hosts can adapt their existing localization system
/// without taking a dependency on another application's generated resources.
class EditorStrings {
  const EditorStrings();

  String get findHint => 'Find in file';
  String get matchCase => 'Match case';
  String get previousMatch => 'Previous match';
  String get nextMatch => 'Next match';
  String get closeSearch => 'Close search';
  String get noMatches => 'No matches';
  String get caseFoldLimited =>
      'This text cannot be compared without case, so matching was exact.';
  String get showReplace => 'Find and replace';
  String get replaceHint => 'Replace with';
  String get replace => 'Replace';
  String get replaceAll => 'Replace all';
  String get unsaved => 'Unsaved edits';
  String get saving => 'Saving…';
  String matchCount(int current, int total, {bool capped = false}) =>
      '$current/$total${capped ? '+' : ''}';
  String documentPosition(int line, int column, int lines, int bytes) =>
      'Ln $line, Col $column · $lines lines · $bytes bytes';
}
