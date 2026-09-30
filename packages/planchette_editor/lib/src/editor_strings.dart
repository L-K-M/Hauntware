import 'package:planchette_core/planchette_core.dart';

import 'text_tool_history.dart';

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
    'reverseLines' => 'Reverse Lines',
    'shuffleLines' => 'Shuffle Lines',
    'removeDuplicateLines' => 'Remove Duplicate Lines',
    'removeBlankLines' => 'Remove Blank Lines',
    'collapseBlankLines' => 'Collapse Blank Lines',
    'uppercase' => 'UPPERCASE',
    'lowercase' => 'lowercase',
    'titleCase' => 'Title Case',
    'sentenceCase' => 'Sentence case',
    'camelCase' => 'camelCase',
    'pascalCase' => 'PascalCase',
    'snakeCase' => 'snake_case',
    'kebabCase' => 'kebab-case',
    'constantCase' => 'CONSTANT_CASE',
    'trimTrailingWhitespace' => 'Trim Trailing Whitespace',
    'trimLeadingWhitespace' => 'Trim Leading Whitespace',
    'normalizeSpaces' => 'Normalize Spaces',
    'convertIndentationToSpaces' => 'Convert Indentation to Spaces',
    'convertIndentationToTabs' => 'Convert Indentation to Tabs',
    'straightenQuotes' => 'Straighten Quotes',
    'zapGremlins' => 'Zap Gremlins',
    'prefixSuffixLines' => 'Prefix/Suffix Lines',
    'numberLines' => 'Number Lines',
    'unwrapParagraphs' => 'Unwrap Paragraphs',
    'joinLinesWith' => 'Join Lines With',
    'urlEncode' => 'URL Encode',
    'urlDecode' => 'URL Decode',
    'base64Encode' => 'Base64 Encode',
    'base64Decode' => 'Base64 Decode',
    'htmlEntityEncode' => 'Encode HTML Entities',
    'htmlEntityDecode' => 'Decode HTML Entities',
    'escapeJsonString' => 'Escape as JSON String',
    'unescapeBackslashSequences' => 'Unescape Backslash Sequences',
    'insertDate' => 'Date',
    'insertDateTime' => 'Date and Time',
    'insertUtcTimestamp' => 'UTC Timestamp',
    'insertUuid' => 'UUID',
    _ => id,
  };

  /// The menu label: a tool with options ends in an ellipsis, because the
  /// item opens the tool bar rather than running at defaults.
  String textToolMenuLabel(String id) {
    final tool = textToolById(id);
    final name = textToolName(id);
    return tool != null && tool.options.isNotEmpty ? '$name…' : name;
  }

  /// An option's label in the tool bar, keyed by tool and option id.
  String textToolOptionName(String toolId, String optionId) =>
      switch ((toolId, optionId)) {
        ('sortLines', 'order') => 'Order',
        ('sortLines', 'ignoreCase') => 'Ignore case',
        ('sortLines', 'numbersByValue') => 'Numbers by value',
        ('sortLines', 'byLength') => 'By length',
        ('sortLines', 'ignoreLeadingWhitespace') => 'Ignore leading whitespace',
        ('sortLines', 'keepFirstLine') => 'Leave first line in place',
        ('removeDuplicateLines', 'adjacentOnly') => 'Adjacent only',
        ('removeDuplicateLines', 'ignoreCase') => 'Ignore case',
        ('removeDuplicateLines', 'ignoreSurroundingWhitespace') =>
          'Ignore surrounding whitespace',
        ('removeDuplicateLines', 'keepBlankLines') => 'Keep blank lines',
        ('removeDuplicateLines', 'removeEveryCopy') => 'Remove every copy',
        ('zapGremlins', 'controls') => 'Control characters',
        ('zapGremlins', 'invisible') => 'Invisible characters',
        ('zapGremlins', 'bidi') => 'Bidirectional controls',
        ('zapGremlins', 'damaged') => 'Damaged encoding',
        ('zapGremlins', 'nonAscii') => 'All non-ASCII',
        ('zapGremlins', 'action') => 'Action',
        ('zapGremlins', 'character') => 'Replacement character',
        ('prefixSuffixLines', 'mode') => 'Mode',
        ('prefixSuffixLines', 'where') => 'Where',
        ('prefixSuffixLines', 'text') => 'Text',
        ('prefixSuffixLines', 'skipBlankLines') => 'Skip blank lines',
        ('numberLines', 'mode') => 'Mode',
        ('numberLines', 'start') => 'Start at',
        ('numberLines', 'step') => 'Step by',
        ('numberLines', 'separator') => 'Separator',
        ('numberLines', 'padding') => 'Padding',
        ('joinLinesWith', 'separator') => 'Separator',
        ('joinLinesWith', 'trim') => 'Trim lines',
        ('joinLinesWith', 'skipBlankLines') => 'Skip blank lines',
        _ => optionId,
      };

  /// A choice's display name, keyed by its id — choices share ids across
  /// tools where the words already agree.
  String textToolChoiceName(String choiceId) => switch (choiceId) {
    'ascending' => 'A to Z',
    'descending' => 'Z to A',
    'insert' => 'Insert',
    'remove' => 'Remove',
    'add' => 'Add',
    'prefix' => 'Prefix',
    'suffix' => 'Suffix',
    'none' => 'None',
    'spaces' => 'Spaces',
    'zeros' => 'Zeros',
    'delete' => 'Delete',
    'escape' => r'Escape as \u{…}',
    'replace' => 'Replace with character',
    'entity' => 'Numeric entity',
    _ => choiceId,
  };

  /// A run's short option summary for Repeat and Recent rows — the choice
  /// options that differ from their defaults, so "Repeat Sort Lines (Z to
  /// A)" says what the re-run does. Empty when nothing distinguishes it.
  String textToolOptionsSummary(TextToolRunRecord record) {
    final tool = textToolById(record.toolId);
    if (tool == null) return '';
    final parts = <String>[
      for (final option in tool.options)
        if (option is ChoiceOption &&
            record.options[option.id] is String &&
            record.options[option.id] != option.defaultValue)
          textToolChoiceName(record.options[option.id] as String),
    ];
    return parts.join(', ');
  }

  /// The Repeat row: "Repeat Sort Lines (Z to A)", or "Repeat" alone before
  /// the first run.
  String repeatTextToolLabel(TextToolRunRecord? record) {
    if (record == null) return 'Repeat';
    final summary = textToolOptionsSummary(record);
    final name = textToolName(record.toolId);
    return summary.isEmpty ? 'Repeat $name' : 'Repeat $name ($summary)';
  }

  /// A Recent row: "Sort Lines (Z to A)".
  String recentTextToolLabel(TextToolRunRecord record) {
    final summary = textToolOptionsSummary(record);
    final name = textToolName(record.toolId);
    return summary.isEmpty ? name : '$name ($summary)';
  }

  /// The submenu a [TextToolGroup] becomes in the Text menu.
  String textToolGroupName(TextToolGroup group) => switch (group) {
    TextToolGroup.lines => 'Lines',
    TextToolGroup.changeCase => 'Case',
    TextToolGroup.whitespace => 'Whitespace',
    TextToolGroup.cleanUp => 'Clean Up',
    TextToolGroup.wrap => 'Wrap',
    TextToolGroup.encode => 'Encode',
    TextToolGroup.insert => 'Insert',
  };

  /// The one-line description the palette shows under a tool's name.
  String textToolDescription(String id) => switch (id) {
    'sortLines' => 'Orders lines alphabetically.',
    'reverseLines' => 'Reverses the order of lines.',
    'shuffleLines' => 'Puts lines in a random order.',
    'removeDuplicateLines' =>
      'Deletes repeated lines, keeping the first of each.',
    'removeBlankLines' => 'Deletes empty and whitespace-only lines.',
    'collapseBlankLines' =>
      'Collapses runs of blank lines to a single blank line.',
    'uppercase' => 'Changes the word or selection to UPPERCASE.',
    'lowercase' => 'Changes the word or selection to lowercase.',
    'titleCase' => 'Changes the word or selection to Title Case.',
    'sentenceCase' => 'Changes the word or selection to Sentence case.',
    'camelCase' => 'Changes the word or selection to camelCase.',
    'pascalCase' => 'Changes the word or selection to PascalCase.',
    'snakeCase' => 'Changes the word or selection to snake_case.',
    'kebabCase' => 'Changes the word or selection to kebab-case.',
    'constantCase' => 'Changes the word or selection to CONSTANT_CASE.',
    'trimTrailingWhitespace' =>
      'Removes spaces and tabs from the ends of lines.',
    'trimLeadingWhitespace' =>
      'Removes spaces and tabs from the starts of lines.',
    'normalizeSpaces' =>
      'Replaces no-break and other Unicode spaces with plain spaces.',
    'convertIndentationToSpaces' =>
      'Replaces leading tabs with spaces, then indents with spaces.',
    'convertIndentationToTabs' =>
      'Replaces leading space runs with tabs, then indents with tabs.',
    'straightenQuotes' => 'Replaces curly quotes with straight ASCII quotes.',
    'zapGremlins' =>
      'Removes or replaces characters that do not belong in text.',
    'prefixSuffixLines' =>
      'Adds or removes the same text at the start or end of each line.',
    'numberLines' => 'Adds or removes line numbers.',
    'removeAnsiEscapes' => 'Strips terminal colors and escape sequences.',
    'unwrapParagraphs' => 'Joins each paragraph into a single line.',
    'joinLinesWith' => 'Joins the selected lines with a separator.',
    'urlEncode' => 'Percent-encodes the selection for a URL.',
    'urlDecode' => 'Decodes percent-encoded text.',
    'base64Encode' => 'Encodes the selection as Base64.',
    'base64Decode' => 'Decodes Base64 text.',
    'htmlEntityEncode' => 'Escapes HTML specials and non-ASCII as entities.',
    'htmlEntityDecode' => 'Decodes named and numeric HTML entities.',
    'escapeJsonString' => 'Escapes the selection as a JSON string body.',
    'unescapeBackslashSequences' =>
      r'Decodes backslash escapes such as \n and \uXXXX.',
    'insertDate' => 'Inserts the current date as YYYY-MM-DD.',
    'insertDateTime' => 'Inserts the local date and time.',
    'insertUtcTimestamp' => 'Inserts the UTC timestamp.',
    'insertUuid' => 'Inserts a random UUID.',
    _ => '',
  };

  /// Other words the palette matches a tool by, so "dedupe" finds Remove
  /// Duplicate Lines.
  List<String> textToolKeywords(String id) => switch (id) {
    'sortLines' => const ['order', 'alphabetize', 'arrange'],
    'reverseLines' => const ['flip', 'invert order'],
    'shuffleLines' => const ['randomize', 'mix lines'],
    'removeDuplicateLines' => const ['dedupe', 'uniq', 'unique'],
    'removeBlankLines' => const ['empty lines', 'delete blanks'],
    'collapseBlankLines' => const [
      'squeeze blank lines',
      'single blank',
      'collapse empty',
    ],
    'uppercase' => const ['all caps', 'capitalize', 'upcase'],
    'lowercase' => const ['downcase', 'small letters'],
    'titleCase' => const ['capitalize words', 'headline'],
    'sentenceCase' => const ['capitalize sentences'],
    'camelCase' => const ['lower camel', 'identifier'],
    'pascalCase' => const ['upper camel', 'identifier'],
    'snakeCase' => const ['underscore', 'identifier'],
    'kebabCase' => const ['hyphen', 'dash case', 'identifier'],
    'constantCase' => const ['screaming snake', 'macro', 'identifier'],
    'trimTrailingWhitespace' => const [
      'trailing spaces',
      'rstrip',
      'strip whitespace',
    ],
    'trimLeadingWhitespace' => const [
      'leading spaces',
      'lstrip',
      'unindent all',
    ],
    'normalizeSpaces' => const ['non-breaking space', 'unicode spaces', 'nbsp'],
    'convertIndentationToSpaces' => const ['tabs to spaces', 'detab'],
    'convertIndentationToTabs' => const ['spaces to tabs', 'entab'],
    'straightenQuotes' => const ['smart quotes', 'typographic quotes'],
    'zapGremlins' => const ['control characters', 'invisible characters'],
    'prefixSuffixLines' => const ['quote level', 'comment out', 'affix'],
    'numberLines' => const ['line numbers', 'enumerate'],
    'removeAnsiEscapes' => const ['terminal colors', 'ansi codes', 'vt100'],
    'unwrapParagraphs' => const [
      'unwrap lines',
      'reflow',
      'remove line breaks',
    ],
    'joinLinesWith' => const ['join', 'unlines', 'flatten'],
    'urlEncode' => const ['percent encode', 'uri encode'],
    'urlDecode' => const ['percent decode', 'uri decode'],
    'base64Encode' => const ['b64', 'encode base64'],
    'base64Decode' => const ['b64', 'decode base64'],
    'htmlEntityEncode' => const ['html escape', 'entities', 'escape html'],
    'htmlEntityDecode' => const ['html unescape', 'entities', 'unescape html'],
    'escapeJsonString' => const ['json escape', 'escape string'],
    'unescapeBackslashSequences' => const [
      'unescape',
      'escape sequences',
      'backslash',
    ],
    'insertDate' => const ['today', 'current date'],
    'insertDateTime' => const ['now', 'timestamp', 'current time'],
    'insertUtcTimestamp' => const ['now', 'zulu', 'gmt', 'timestamp'],
    'insertUuid' => const ['guid', 'random id'],
    _ => const [],
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
    'reverseLines' => 'reversed ${_lines(scope)} $where.',
    'shuffleLines' => 'shuffled ${_lines(scope)} $where.',
    'removeDuplicateLines' => 'removed $changed of ${_lines(scope)} $where.',
    'removeBlankLines' =>
      'removed $changed blank ${_plural(changed, 'line')} $where.',
    'collapseBlankLines' =>
      'collapsed $changed blank ${_plural(changed, 'line')} $where.',
    'trimLeadingWhitespace' =>
      'trimmed whitespace on $changed of ${_lines(scope)} $where.',
    'normalizeSpaces' => 'normalized ${_plural(changed, 'space')} $where.',
    'titleCase' ||
    'sentenceCase' ||
    'camelCase' ||
    'pascalCase' ||
    'snakeCase' ||
    'kebabCase' ||
    'constantCase' =>
      'changed the case of ${_plural(changed, 'character')} $where.',
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
    'removeAnsiEscapes' =>
      'removed ${_plural(changed, 'escape sequence')} $where.',
    'unwrapParagraphs' => 'unwrapped ${_plural(changed, 'line break')} $where.',
    'prefixSuffixLines' ||
    'numberLines' => 'changed $changed of ${_lines(scope)} $where.',
    'joinLinesWith' => 'joined ${_lines(changed)} $where.',
    'urlEncode' => 'encoded ${_plural(changed, 'character')} $where.',
    'urlDecode' => 'decoded ${_plural(changed, 'character')} $where.',
    'base64Encode' => 'encoded ${_plural(changed, 'character')} $where.',
    'base64Decode' => 'decoded ${_plural(changed, 'character')} $where.',
    'htmlEntityEncode' =>
      'encoded ${_plural(changed, 'character')} as entities $where.',
    'htmlEntityDecode' => 'decoded ${_plural(changed, 'entity')} $where.',
    'escapeJsonString' => 'escaped ${_plural(changed, 'character')} $where.',
    'unescapeBackslashSequences' =>
      'decoded ${_plural(changed, 'escape')} $where.',
    'insertDate' => 'inserted the current date $where.',
    'insertDateTime' => 'inserted the date and time $where.',
    'insertUtcTimestamp' => 'inserted the UTC timestamp $where.',
    'insertUuid' => 'inserted a UUID $where.',
    _ => 'changed $scope units $where.',
  };

  /// What a run that changed nothing found, per tool.
  String _unchangedText(String id, int scope, String where) => switch (id) {
    'sortLines' =>
      'nothing to change, ${_lines(scope)} $where already in order.',
    'reverseLines' ||
    'shuffleLines' => 'nothing to change, ${_lines(scope)} $where.',
    'removeDuplicateLines' => 'nothing to change, no duplicate lines $where.',
    'removeBlankLines' => 'nothing to change, no blank lines $where.',
    'collapseBlankLines' => 'nothing to change, no blank-line runs $where.',
    'trimTrailingWhitespace' => 'nothing to trim $where.',
    'trimLeadingWhitespace' => 'nothing to trim $where.',
    'normalizeSpaces' => 'no Unicode spaces $where.',
    'convertIndentationToSpaces' ||
    'convertIndentationToTabs' => 'nothing to convert $where.',
    'uppercase' ||
    'lowercase' ||
    'titleCase' ||
    'sentenceCase' ||
    'camelCase' ||
    'pascalCase' ||
    'snakeCase' ||
    'kebabCase' ||
    'constantCase' => 'nothing to change $where.',
    'straightenQuotes' => 'nothing to straighten $where.',
    'zapGremlins' => 'nothing to zap $where.',
    'removeAnsiEscapes' => 'no escape sequences $where.',
    'unwrapParagraphs' => 'nothing to unwrap $where.',
    'joinLinesWith' => 'nothing to join $where.',
    'urlDecode' || 'base64Decode' => 'nothing to decode $where.',
    'htmlEntityDecode' => 'no entities $where.',
    'unescapeBackslashSequences' => 'no escapes $where.',
    _ => 'nothing to change $where.',
  };

  String _refusalText(TextToolRefusal reason) => switch (reason) {
    TextToolRefusal.nothingSelected => 'nothing selected',
    TextToolRefusal.noWordAtCaret => 'no word at the caret',
    TextToolRefusal.resultNotText => 'the result is binary, not text',
    TextToolRefusal.tooLarge => 'the result is too large to save',
    TextToolRefusal.requiresTabs => 'this format requires tab indentation',
  };

  // ── Tool bar ──

  String get textToolApply => 'Apply';
  String get textToolClose => 'Close';
  String get textToolAppliesTo => 'Applies to';

  /// The scope radio for a selection, as in "12 selected lines".
  String textToolSelectedLines(int count) => '${_lines(count)} selected';

  /// The scope radio for the document, as in "Whole document, 310 lines".
  String textToolWholeDocument(int count) => 'Whole document, ${_lines(count)}';

  /// The scope line with no selection: only the document exists.
  String textToolNothingSelected(int count) =>
      'Nothing selected: whole document, ${_lines(count)}';

  /// The count line under the bar, such as "9 of 12 lines will move".
  /// Past the preview limit the count is deferred to Apply.
  String textToolPreview(TextToolReport report) {
    if (report.outcome case TextToolChanged(:final changed, :final scope)) {
      return _previewText(report.tool.id, changed, scope);
    }
    return switch (report.outcome) {
      TextToolRefused(:final reason) => 'not applied, ${_refusalText(reason)}',
      TextToolUnchanged() => 'nothing to change',
      _ => '',
    };
  }

  /// Shown instead of a count on a buffer too large to dry-run.
  String get textToolPreviewDeferred => 'count is computed on Apply';

  String _previewText(String id, int changed, int scope) => switch (id) {
    'sortLines' => '$changed of ${_lines(scope)} will move',
    'reverseLines' => 'will reverse ${_lines(scope)}',
    'shuffleLines' => 'will shuffle ${_lines(scope)}',
    'removeDuplicateLines' => 'will remove $changed of ${_lines(scope)}',
    'removeBlankLines' => 'will remove ${_plural(changed, 'line')}',
    'collapseBlankLines' => 'will collapse ${_plural(changed, 'blank line')}',
    'trimLeadingWhitespace' => 'will trim ${_plural(changed, 'line')}',
    'normalizeSpaces' => 'will normalize ${_plural(changed, 'space')}',
    'removeAnsiEscapes' => 'will remove ${_plural(changed, 'escape sequence')}',
    'unwrapParagraphs' => 'will join ${_plural(changed, 'line')}',
    'zapGremlins' => 'will zap ${_plural(changed, 'gremlin')}',
    'prefixSuffixLines' => 'will change $changed of ${_lines(scope)}',
    'numberLines' => 'will renumber ${_lines(scope)}',
    'joinLinesWith' => 'will join ${_lines(changed)}',
    _ => 'will change $scope units',
  };

  String _lines(int count) => _plural(count, 'line');
  String _plural(int count, String noun) =>
      '$count $noun${count == 1 ? '' : 's'}';
}
