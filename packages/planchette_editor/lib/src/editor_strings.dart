import 'package:planchette_core/planchette_core.dart';

/// User-facing editor copy. Hosts can adapt their existing localization system
/// without taking a dependency on another application's generated resources.
class EditorStrings {
  const EditorStrings();

  String get findHint => 'Find in file';
  String get matchCase => 'Match case';
  String get wholeWords => 'Whole words';
  String get regularExpression => 'Regular expression';
  String get findPatternHint => 'Find by regular expression';

  /// Why a regular expression cannot be searched; [detail] is the engine's
  /// own explanation, such as "Unterminated group".
  String patternInvalid(String detail) => 'Invalid pattern: $detail';
  String get patternTooSlow => 'Pattern took too long to search';
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
  String get largeFile => 'Large file: no highlighting';
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

  // ── Text tools ──

  /// The text tool's display name, for its menu and palette entries.
  String textToolName(String id) => switch (id) {
    'sortLines' => 'Sort Lines',
    'removeDuplicateLines' => 'Remove Duplicate Lines',
    'removeBlankLines' => 'Remove Blank Lines',
    'uppercase' => 'UPPERCASE',
    'lowercase' => 'lowercase',
    'trimTrailingWhitespace' => 'Trim Trailing Whitespace',
    'convertIndentationToSpaces' => 'Convert Indentation to Spaces',
    'convertIndentationToTabs' => 'Convert Indentation to Tabs',
    'straightenQuotes' => 'Straighten Quotes',
    'zapGremlins' => 'Zap Gremlins',
    _ => id,
  };

  /// The one-line notice the document shows after a tool run, such as
  /// "Remove Duplicate Lines: removed 25 of 310 lines in the whole
  /// document."
  String textToolNotice(TextToolReport report) {
    final name = textToolName(report.tool.id);
    final where = switch (report.ranOn) {
      TextToolRanOn.selection => 'in the selection',
      TextToolRanOn.document => 'in the whole document',
      TextToolRanOn.paragraph => 'in the paragraph',
      TextToolRanOn.word => 'in the word',
      TextToolRanOn.caret => 'at the caret',
    };
    return switch (report.outcome) {
      TextToolRefused(:final reason) =>
        '$name: not applied, ${_refusalText(reason)}.',
      TextToolUnchanged(:final scope) =>
        '$name: ${_unchangedText(report.tool.id, scope, where)}',
      TextToolChanged(:final changed, :final scope, :final detail) =>
        '$name: ${_changedText(report.tool.id, changed, scope, where, detail)}',
    };
  }

  String get undo => 'Undo';

  /// What a changed run did, per tool.
  String _changedText(
    String id,
    int changed,
    int scope,
    String where,
    String? detail,
  ) => switch (id) {
    'sortLines' => 'moved $changed of ${_lines(scope)} $where.',
    'removeDuplicateLines' => 'removed $changed of ${_lines(scope)} $where.',
    'removeBlankLines' =>
      'removed $changed blank ${_plural(changed, 'line')} $where.',
    'trimTrailingWhitespace' =>
      'trimmed whitespace on $changed of ${_lines(scope)} $where.',
    'convertIndentationToSpaces' =>
      'converted indentation to spaces on $changed of ${_lines(scope)} '
          '$where.',
    'convertIndentationToTabs' =>
      'converted indentation to tabs on $changed of ${_lines(scope)} $where.',
    'uppercase' => 'uppercased ${_plural(changed, 'character')} $where.',
    'lowercase' => 'lowercased ${_plural(changed, 'character')} $where.',
    'straightenQuotes' => 'straightened ${_plural(changed, 'quote')} $where.',
    'zapGremlins' => switch (detail) {
      'escape' => 'escaped ${_plural(changed, 'gremlin')} $where.',
      'replace' => 'replaced ${_plural(changed, 'gremlin')} $where.',
      'entity' =>
        'replaced ${_plural(changed, 'gremlin')} with entities $where.',
      _ => 'removed ${_plural(changed, 'gremlin')} $where.',
    },
    _ => 'changed $scope units $where.',
  };

  /// What a run that changed nothing found, per tool.
  String _unchangedText(String id, int scope, String where) => switch (id) {
    'sortLines' =>
      'nothing to change, ${_lines(scope)} $where already in order.',
    'removeDuplicateLines' => 'nothing to change, no duplicate lines $where.',
    'removeBlankLines' => 'nothing to change, no blank lines $where.',
    'trimTrailingWhitespace' => 'nothing to trim $where.',
    'convertIndentationToSpaces' ||
    'convertIndentationToTabs' => 'nothing to convert $where.',
    'uppercase' || 'lowercase' => 'nothing to change $where.',
    'straightenQuotes' => 'nothing to straighten $where.',
    'zapGremlins' => 'nothing to zap $where.',
    _ => 'nothing to change $where.',
  };

  String _refusalText(TextToolRefusal reason) => switch (reason) {
    TextToolRefusal.nothingSelected => 'nothing selected',
    TextToolRefusal.noWordAtCaret => 'no word at the caret',
    TextToolRefusal.resultNotText => 'the result is binary, not text',
    TextToolRefusal.tooLarge => 'the result is too large to save',
    TextToolRefusal.requiresTabs => 'this format requires tab indentation',
  };

  String _lines(int count) => _plural(count, 'line');
  String _plural(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';
}
