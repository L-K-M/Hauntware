import 'package:planchette_core/planchette_core.dart';

/// User-facing editor copy. Hosts can adapt their existing localization system
/// without taking a dependency on another application's generated resources.
class EditorStrings {
  const EditorStrings();

  String get findHint => 'Find in file';
  String get matchCase => 'Match case';
  String get wholeWords => 'Whole words';
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
  String indentation(Indentation value) => value.style == IndentStyle.tabs
      ? 'Tab Size: ${value.width}'
      : 'Spaces: ${value.width}';
  String get goToLine => 'Go to line';
  String get closeGoToLine => 'Close go to line';
  String goToLineHint(int lines) => 'Line or line:column, 1 to $lines';
  String goToLineInvalid(int lines) =>
      'Enter a line from 1 to $lines, or line:column.';
  String selectionSummary(int characters, int lines) => lines > 1
      ? '$characters selected on $lines lines'
      : '$characters selected';
  String languageName(SyntaxLanguage? language) => switch (language?.id) {
    null => 'Plain Text',
    'c-family' => 'C-style',
    'css' => 'CSS',
    'dart' => 'Dart',
    'diff' => 'Diff',
    'dockerfile' => 'Dockerfile',
    'dotenv' => '.env',
    'go' => 'Go',
    'ini' => 'INI',
    'javascript' => 'JavaScript',
    'json' => 'JSON',
    'lua' => 'Lua',
    'markdown' => 'Markdown',
    'perl' => 'Perl',
    'python' => 'Python',
    'ruby' => 'Ruby',
    'rust' => 'Rust',
    'shell' => 'Shell',
    'sql' => 'SQL',
    'xml' => 'XML',
    'yaml' => 'YAML',
    final id => id,
  };
  String documentPosition(int line, int column, int lines, int bytes) =>
      'Ln $line, Col $column · $lines ${lines == 1 ? 'line' : 'lines'} · '
      '$bytes ${bytes == 1 ? 'byte' : 'bytes'}';
}
