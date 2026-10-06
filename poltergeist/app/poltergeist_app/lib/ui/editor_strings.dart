import 'package:planchette_editor/planchette_editor.dart';

import '../l10n/app_localizations.dart';

/// Adapt the shared editor's user-facing copy to Poltergeist's localization
/// resources. Every string the shared surface can render while this host
/// shows it — find and replace bars, Go to Line, the text-tools browser,
/// the tool bar, and the post-run notice — comes from the ARB catalog. The
/// shared status row stays unadapted: this editor hides that row and draws
/// its own from the same catalog. [regexHint] stays the package's own
/// technical text, like the engine detail inside [patternInvalid].
class PoltergeistEditorStrings extends EditorStrings {
  const PoltergeistEditorStrings(this.l10n);
  final AppLocalizations l10n;

  @override
  String get findHint => l10n.editorFindHint;
  @override
  String get matchCase => l10n.editorMatchCaseTooltip;
  @override
  String get previousMatch => l10n.editorPreviousMatchTooltip;
  @override
  String get nextMatch => l10n.editorNextMatchTooltip;
  @override
  String get closeSearch => l10n.editorCloseSearchTooltip;
  @override
  String get noMatches => l10n.editorNoMatches;
  @override
  String get showReplace => l10n.editorShowReplaceTooltip;
  @override
  String get replaceHint => l10n.editorReplaceHint;
  @override
  String get replace => l10n.editorReplaceLabel;
  @override
  String get replaceAll => l10n.editorReplaceAllLabel;
  @override
  String matchCount(int current, int total, {bool capped = false}) => capped
      ? l10n.editorMatchCountCapped(current, total)
      : l10n.editorMatchCount(current, total);
  @override
  String get wholeWords => l10n.editorWholeWordsTooltip;
  @override
  String get regularExpression => l10n.editorRegularExpressionTooltip;
  @override
  String get findPatternHint => l10n.editorFindPatternHint;
  @override
  String patternInvalid(String detail) => l10n.editorPatternInvalid(detail);
  @override
  String get patternTooSlow => l10n.editorPatternTooSlow;
  @override
  String get caseFoldLimited => l10n.editorCaseFoldLimited;
  @override
  String get goToLine => l10n.editorGoToLineTooltip;
  @override
  String get closeGoToLine => l10n.editorCloseGoToLineTooltip;
  @override
  String goToLineHint(int lines) => l10n.editorGoToLineHint(lines);
  @override
  String goToLineInvalid(int lines) => l10n.editorGoToLineInvalid(lines);

  // ── Find-bar extras ──

  @override
  String get searchInSelection => l10n.editorSearchInSelection;
  @override
  String get searchScopeHint => l10n.editorSearchScopeHint;
  @override
  String get findInSelection => l10n.editorFindInSelection;
  @override
  String get searchHistory => l10n.editorSearchHistory;
  @override
  String get searchHistoryEmpty => l10n.editorSearchHistoryEmpty;
  @override
  String get useSelectionForFind => l10n.editorUseSelectionForFind;
  @override
  String get findSelectedText => l10n.editorFindSelectedText;
  @override
  String get lineActions => l10n.editorLineActions;
  @override
  String get keepMatchingLines => l10n.editorKeepMatchingLines;
  @override
  String get deleteMatchingLines => l10n.editorDeleteMatchingLines;
  @override
  String lineMatchCount(int count) => l10n.editorLineMatchCount(count);
  @override
  String get extractAction => l10n.editorExtractAction;
  @override
  String get extractWholeLinesTooltip => l10n.editorExtractWholeLinesTooltip;
  @override
  String get extractTemplateHint => l10n.editorExtractTemplateHint;
  @override
  String extractCount(int count, {required bool wholeLines}) => wholeLines
      ? l10n.editorExtractCountLines(count)
      : l10n.editorExtractCountMatches(count);
  @override
  String replacementPreview(String expanded, List<String> groups) =>
      groups.isEmpty
      ? l10n.editorReplacementPreviewPlain(expanded)
      : l10n.editorReplacementPreview(expanded, groups.join('  '));
  @override
  String get replacementPreviewEmpty => l10n.editorReplacementPreviewEmpty;
  @override
  String? regexHint(String query) => patternHintFor(query);

  // ── Grep cheat sheet ──

  @override
  String get grepCheatSheet => l10n.editorGrepCheatSheet;
  @override
  String get grepCheatSheetTitle => l10n.editorGrepCheatSheetTitle;

  // The brace-bearing regex tokens ride as placeholders: gen-l10n's ICU
  // parser offers no escape for literal braces inside a message.
  @override
  List<String> get grepCheatSheetDart => l10n
      .editorGrepCheatSheetDart('{2,4}', '{1}', '{name}')
      .split('\n');
  @override
  List<String> get grepCheatSheetBBEdit => l10n
      .editorGrepCheatSheetBBEdit('{NNNN}')
      .split('\n');

  // ── Text-tools browser ──

  @override
  String get textToolsTitle => l10n.editorTextToolsTitle;
  @override
  String get textToolsClose => l10n.editorTextToolsClose;
  @override
  String get textToolsFilterHint => l10n.editorTextToolsFilterHint;
  @override
  String get textToolsNoResults => l10n.editorTextToolsNoResults;
  @override
  String get textToolsHistoryGroup => l10n.editorTextToolsHistoryGroup;
  @override
  String get editorCommandsGroup => l10n.editorCommandsGroup;
  @override
  String editorCommandLabel(EditorCommand command) => switch (command) {
    EditorCommand.duplicateLines => l10n.editorCommandDuplicateLine,
    EditorCommand.moveLinesUp => l10n.editorCommandMoveLineUp,
    EditorCommand.moveLinesDown => l10n.editorCommandMoveLineDown,
    EditorCommand.deleteLines => l10n.editorCommandDeleteLine,
    EditorCommand.joinLines => l10n.editorCommandJoinLines,
    EditorCommand.toggleComment => l10n.editorCommandToggleComment,
    EditorCommand.selectLine => l10n.editorCommandSelectLine,
    EditorCommand.selectParagraph => l10n.editorCommandSelectParagraph,
    EditorCommand.selectEnclosingBrackets =>
      l10n.editorCommandSelectEnclosingBrackets,
    EditorCommand.insertLineAbove => l10n.editorCommandInsertLineAbove,
    EditorCommand.insertLineBelow => l10n.editorCommandInsertLineBelow,
    EditorCommand.copyLine => l10n.editorCommandCopyLine,
    EditorCommand.cutLine => l10n.editorCommandCutLine,
    EditorCommand.incrementNumber => l10n.editorCommandIncrementNumber,
    EditorCommand.decrementNumber => l10n.editorCommandDecrementNumber,
    EditorCommand.pasteAndMatchIndentation =>
      l10n.editorCommandPasteMatchIndentation,
    EditorCommand.goToMatchingBracket => l10n.editorCommandGoToMatchingBracket,
    EditorCommand.selectToMatchingBracket =>
      l10n.editorCommandSelectToMatchingBracket,
    // Already in the catalog for the find bar's own copy.
    EditorCommand.findInSelection => findInSelection,
  };
  @override
  String get browseTextTools => l10n.editorTextToolsTooltip;

  @override
  String textToolGroupName(TextToolGroup group) => switch (group) {
    TextToolGroup.lines => l10n.editorTextToolGroupLines,
    TextToolGroup.changeCase => l10n.editorTextToolGroupChangeCase,
    TextToolGroup.whitespace => l10n.editorTextToolGroupWhitespace,
    TextToolGroup.cleanUp => l10n.editorTextToolGroupCleanUp,
    TextToolGroup.wrap => l10n.editorTextToolGroupWrap,
    TextToolGroup.encode => l10n.editorTextToolGroupEncode,
    TextToolGroup.insert => l10n.editorTextToolGroupInsert,
  };

  @override
  String textToolName(String id) => switch (id) {
    'sortLines' => l10n.editorTextToolNameSortLines,
    'reverseLines' => l10n.editorTextToolNameReverseLines,
    'shuffleLines' => l10n.editorTextToolNameShuffleLines,
    'removeDuplicateLines' => l10n.editorTextToolNameRemoveDuplicateLines,
    'removeBlankLines' => l10n.editorTextToolNameRemoveBlankLines,
    'collapseBlankLines' => l10n.editorTextToolNameCollapseBlankLines,
    'uppercase' => l10n.editorTextToolNameUppercase,
    'lowercase' => l10n.editorTextToolNameLowercase,
    'titleCase' => l10n.editorTextToolNameTitleCase,
    'sentenceCase' => l10n.editorTextToolNameSentenceCase,
    'camelCase' => l10n.editorTextToolNameCamelCase,
    'pascalCase' => l10n.editorTextToolNamePascalCase,
    'snakeCase' => l10n.editorTextToolNameSnakeCase,
    'kebabCase' => l10n.editorTextToolNameKebabCase,
    'constantCase' => l10n.editorTextToolNameConstantCase,
    'trimTrailingWhitespace' => l10n.editorTextToolNameTrimTrailingWhitespace,
    'trimLeadingWhitespace' => l10n.editorTextToolNameTrimLeadingWhitespace,
    'normalizeSpaces' => l10n.editorTextToolNameNormalizeSpaces,
    'normalizeLineEndings' => l10n.editorTextToolNameNormalizeLineEndings,
    'convertIndentationToSpaces' =>
      l10n.editorTextToolNameConvertIndentationToSpaces,
    'convertIndentationToTabs' => l10n.editorTextToolNameConvertIndentationToTabs,
    'convertTabsToSpaces' => l10n.editorTextToolNameConvertTabsToSpaces,
    'hardWrap' => l10n.editorTextToolNameHardWrap,
    'straightenQuotes' => l10n.editorTextToolNameStraightenQuotes,
    'zapGremlins' => l10n.editorTextToolNameZapGremlins,
    'removeAnsiEscapes' => l10n.editorTextToolNameRemoveAnsiEscapes,
    'convertToAscii' => l10n.editorTextToolNameConvertToAscii,
    'stripDiacritics' => l10n.editorTextToolNameStripDiacritics,
    'composeAccents' => l10n.editorTextToolNameComposeAccents,
    'decomposeAccents' => l10n.editorTextToolNameDecomposeAccents,
    'prefixSuffixLines' => l10n.editorTextToolNamePrefixSuffixLines,
    'numberLines' => l10n.editorTextToolNameNumberLines,
    'unwrapParagraphs' => l10n.editorTextToolNameUnwrapParagraphs,
    'joinLinesWith' => l10n.editorTextToolNameJoinLinesWith,
    'urlEncode' => l10n.editorTextToolNameUrlEncode,
    'urlDecode' => l10n.editorTextToolNameUrlDecode,
    'base64Encode' => l10n.editorTextToolNameBase64Encode,
    'base64Decode' => l10n.editorTextToolNameBase64Decode,
    'htmlEntityEncode' => l10n.editorTextToolNameHtmlEntityEncode,
    'htmlEntityDecode' => l10n.editorTextToolNameHtmlEntityDecode,
    'escapeJsonString' => l10n.editorTextToolNameEscapeJsonString,
    'unescapeBackslashSequences' =>
      l10n.editorTextToolNameUnescapeBackslashSequences,
    'formatJson' => l10n.editorTextToolNameFormatJson,
    'minifyJson' => l10n.editorTextToolNameMinifyJson,
    'insertDate' => l10n.editorTextToolNameInsertDate,
    'insertDateTime' => l10n.editorTextToolNameInsertDateTime,
    'insertUtcTimestamp' => l10n.editorTextToolNameInsertUtcTimestamp,
    'insertUuid' => l10n.editorTextToolNameInsertUuid,
    'keepLinesMatching' => l10n.editorTextToolNameKeepLinesMatching,
    'deleteLinesMatching' => l10n.editorTextToolNameDeleteLinesMatching,
    'extractMatches' => l10n.editorTextToolNameExtractMatches,
    _ => super.textToolName(id),
  };

  @override
  String textToolMenuLabel(String id) {
    final tool = textToolById(id);
    final name = textToolName(id);
    return tool != null && tool.options.isNotEmpty ? '$name…' : name;
  }

  @override
  String textToolDescription(String id) => switch (id) {
    'sortLines' => l10n.editorTextToolDescriptionSortLines,
    'reverseLines' => l10n.editorTextToolDescriptionReverseLines,
    'shuffleLines' => l10n.editorTextToolDescriptionShuffleLines,
    'removeDuplicateLines' => l10n.editorTextToolDescriptionRemoveDuplicateLines,
    'removeBlankLines' => l10n.editorTextToolDescriptionRemoveBlankLines,
    'collapseBlankLines' => l10n.editorTextToolDescriptionCollapseBlankLines,
    'uppercase' => l10n.editorTextToolDescriptionUppercase,
    'lowercase' => l10n.editorTextToolDescriptionLowercase,
    'titleCase' => l10n.editorTextToolDescriptionTitleCase,
    'sentenceCase' => l10n.editorTextToolDescriptionSentenceCase,
    'camelCase' => l10n.editorTextToolDescriptionCamelCase,
    'pascalCase' => l10n.editorTextToolDescriptionPascalCase,
    'snakeCase' => l10n.editorTextToolDescriptionSnakeCase,
    'kebabCase' => l10n.editorTextToolDescriptionKebabCase,
    'constantCase' => l10n.editorTextToolDescriptionConstantCase,
    'trimTrailingWhitespace' =>
      l10n.editorTextToolDescriptionTrimTrailingWhitespace,
    'trimLeadingWhitespace' =>
      l10n.editorTextToolDescriptionTrimLeadingWhitespace,
    'normalizeSpaces' => l10n.editorTextToolDescriptionNormalizeSpaces,
    'normalizeLineEndings' =>
      l10n.editorTextToolDescriptionNormalizeLineEndings,
    'convertIndentationToSpaces' =>
      l10n.editorTextToolDescriptionConvertIndentationToSpaces,
    'convertIndentationToTabs' =>
      l10n.editorTextToolDescriptionConvertIndentationToTabs,
    'convertTabsToSpaces' => l10n.editorTextToolDescriptionConvertTabsToSpaces,
    'hardWrap' => l10n.editorTextToolDescriptionHardWrap,
    'straightenQuotes' => l10n.editorTextToolDescriptionStraightenQuotes,
    'zapGremlins' => l10n.editorTextToolDescriptionZapGremlins,
    'removeAnsiEscapes' => l10n.editorTextToolDescriptionRemoveAnsiEscapes,
    'convertToAscii' => l10n.editorTextToolDescriptionConvertToAscii,
    'stripDiacritics' => l10n.editorTextToolDescriptionStripDiacritics,
    'composeAccents' => l10n.editorTextToolDescriptionComposeAccents,
    'decomposeAccents' => l10n.editorTextToolDescriptionDecomposeAccents,
    'prefixSuffixLines' => l10n.editorTextToolDescriptionPrefixSuffixLines,
    'numberLines' => l10n.editorTextToolDescriptionNumberLines,
    'unwrapParagraphs' => l10n.editorTextToolDescriptionUnwrapParagraphs,
    'joinLinesWith' => l10n.editorTextToolDescriptionJoinLinesWith,
    'urlEncode' => l10n.editorTextToolDescriptionUrlEncode,
    'urlDecode' => l10n.editorTextToolDescriptionUrlDecode,
    'base64Encode' => l10n.editorTextToolDescriptionBase64Encode,
    'base64Decode' => l10n.editorTextToolDescriptionBase64Decode,
    'htmlEntityEncode' => l10n.editorTextToolDescriptionHtmlEntityEncode,
    'htmlEntityDecode' => l10n.editorTextToolDescriptionHtmlEntityDecode,
    'escapeJsonString' => l10n.editorTextToolDescriptionEscapeJsonString,
    'unescapeBackslashSequences' =>
      l10n.editorTextToolDescriptionUnescapeBackslashSequences,
    'formatJson' => l10n.editorTextToolDescriptionFormatJson,
    'minifyJson' => l10n.editorTextToolDescriptionMinifyJson,
    'insertDate' => l10n.editorTextToolDescriptionInsertDate,
    'insertDateTime' => l10n.editorTextToolDescriptionInsertDateTime,
    'insertUtcTimestamp' => l10n.editorTextToolDescriptionInsertUtcTimestamp,
    'insertUuid' => l10n.editorTextToolDescriptionInsertUuid,
    'keepLinesMatching' => l10n.editorTextToolDescriptionKeepLinesMatching,
    'deleteLinesMatching' => l10n.editorTextToolDescriptionDeleteLinesMatching,
    'extractMatches' => l10n.editorTextToolDescriptionExtractMatches,
    _ => super.textToolDescription(id),
  };

  @override
  List<String> textToolKeywords(String id) {
    // One ARB message per tool holds its keywords, one per line; ids the
    // catalog has not taught this host yet keep the package's own words.
    final joined = switch (id) {
      'convertTabsToSpaces' => l10n.editorTextToolKeywordsConvertTabsToSpaces,
      'hardWrap' => l10n.editorTextToolKeywordsHardWrap,
      'normalizeLineEndings' => l10n.editorTextToolKeywordsNormalizeLineEndings,
      'sortLines' => l10n.editorTextToolKeywordsSortLines,
      'reverseLines' => l10n.editorTextToolKeywordsReverseLines,
      'shuffleLines' => l10n.editorTextToolKeywordsShuffleLines,
      'removeDuplicateLines' =>
        l10n.editorTextToolKeywordsRemoveDuplicateLines,
      'removeBlankLines' => l10n.editorTextToolKeywordsRemoveBlankLines,
      'collapseBlankLines' => l10n.editorTextToolKeywordsCollapseBlankLines,
      'uppercase' => l10n.editorTextToolKeywordsUppercase,
      'lowercase' => l10n.editorTextToolKeywordsLowercase,
      'titleCase' => l10n.editorTextToolKeywordsTitleCase,
      'sentenceCase' => l10n.editorTextToolKeywordsSentenceCase,
      'camelCase' => l10n.editorTextToolKeywordsCamelCase,
      'pascalCase' => l10n.editorTextToolKeywordsPascalCase,
      'snakeCase' => l10n.editorTextToolKeywordsSnakeCase,
      'kebabCase' => l10n.editorTextToolKeywordsKebabCase,
      'constantCase' => l10n.editorTextToolKeywordsConstantCase,
      'trimTrailingWhitespace' =>
        l10n.editorTextToolKeywordsTrimTrailingWhitespace,
      'trimLeadingWhitespace' =>
        l10n.editorTextToolKeywordsTrimLeadingWhitespace,
      'normalizeSpaces' => l10n.editorTextToolKeywordsNormalizeSpaces,
      'convertIndentationToSpaces' =>
        l10n.editorTextToolKeywordsConvertIndentationToSpaces,
      'convertIndentationToTabs' =>
        l10n.editorTextToolKeywordsConvertIndentationToTabs,
      'straightenQuotes' => l10n.editorTextToolKeywordsStraightenQuotes,
      'zapGremlins' => l10n.editorTextToolKeywordsZapGremlins,
      'convertToAscii' => l10n.editorTextToolKeywordsConvertToAscii,
      'stripDiacritics' => l10n.editorTextToolKeywordsStripDiacritics,
      'composeAccents' => l10n.editorTextToolKeywordsComposeAccents,
      'decomposeAccents' => l10n.editorTextToolKeywordsDecomposeAccents,
      'prefixSuffixLines' => l10n.editorTextToolKeywordsPrefixSuffixLines,
      'numberLines' => l10n.editorTextToolKeywordsNumberLines,
      'removeAnsiEscapes' => l10n.editorTextToolKeywordsRemoveAnsiEscapes,
      'unwrapParagraphs' => l10n.editorTextToolKeywordsUnwrapParagraphs,
      'joinLinesWith' => l10n.editorTextToolKeywordsJoinLinesWith,
      'urlEncode' => l10n.editorTextToolKeywordsUrlEncode,
      'urlDecode' => l10n.editorTextToolKeywordsUrlDecode,
      'base64Encode' => l10n.editorTextToolKeywordsBase64Encode,
      'base64Decode' => l10n.editorTextToolKeywordsBase64Decode,
      'htmlEntityEncode' => l10n.editorTextToolKeywordsHtmlEntityEncode,
      'htmlEntityDecode' => l10n.editorTextToolKeywordsHtmlEntityDecode,
      'escapeJsonString' => l10n.editorTextToolKeywordsEscapeJsonString,
      'unescapeBackslashSequences' =>
        l10n.editorTextToolKeywordsUnescapeBackslashSequences,
      'formatJson' => l10n.editorTextToolKeywordsFormatJson,
      'minifyJson' => l10n.editorTextToolKeywordsMinifyJson,
      'keepLinesMatching' => l10n.editorTextToolKeywordsKeepLinesMatching,
      'deleteLinesMatching' => l10n.editorTextToolKeywordsDeleteLinesMatching,
      'extractMatches' => l10n.editorTextToolKeywordsExtractMatches,
      'insertDate' => l10n.editorTextToolKeywordsInsertDate,
      'insertDateTime' => l10n.editorTextToolKeywordsInsertDateTime,
      'insertUtcTimestamp' => l10n.editorTextToolKeywordsInsertUtcTimestamp,
      'insertUuid' => l10n.editorTextToolKeywordsInsertUuid,
      _ => null,
    };
    return joined?.split('\n') ?? super.textToolKeywords(id);
  }

  @override
  String textToolOptionName(String toolId, String optionId) =>
      switch ((toolId, optionId)) {
        ('sortLines', 'order') => l10n.editorTextToolOptionSortLinesOrder,
        ('sortLines', 'ignoreCase') =>
          l10n.editorTextToolOptionSortLinesIgnoreCase,
        ('sortLines', 'numbersByValue') =>
          l10n.editorTextToolOptionSortLinesNumbersByValue,
        ('sortLines', 'byLength') => l10n.editorTextToolOptionSortLinesByLength,
        ('sortLines', 'ignoreLeadingWhitespace') =>
          l10n.editorTextToolOptionSortLinesIgnoreLeadingWhitespace,
        ('sortLines', 'keepFirstLine') =>
          l10n.editorTextToolOptionSortLinesKeepFirstLine,
        ('removeDuplicateLines', 'adjacentOnly') =>
          l10n.editorTextToolOptionRemoveDuplicateLinesAdjacentOnly,
        ('removeDuplicateLines', 'ignoreCase') =>
          l10n.editorTextToolOptionRemoveDuplicateLinesIgnoreCase,
        ('removeDuplicateLines', 'ignoreSurroundingWhitespace') =>
          l10n.editorTextToolOptionRemoveDuplicateLinesIgnoreSurroundingWhitespace,
        ('removeDuplicateLines', 'keepBlankLines') =>
          l10n.editorTextToolOptionRemoveDuplicateLinesKeepBlankLines,
        ('removeDuplicateLines', 'removeEveryCopy') =>
          l10n.editorTextToolOptionRemoveDuplicateLinesRemoveEveryCopy,
        ('zapGremlins', 'controls') => l10n.editorTextToolOptionZapGremlinsControls,
        ('zapGremlins', 'invisible') =>
          l10n.editorTextToolOptionZapGremlinsInvisible,
        ('zapGremlins', 'bidi') => l10n.editorTextToolOptionZapGremlinsBidi,
        ('zapGremlins', 'damaged') => l10n.editorTextToolOptionZapGremlinsDamaged,
        ('zapGremlins', 'nonAscii') =>
          l10n.editorTextToolOptionZapGremlinsNonAscii,
        ('zapGremlins', 'action') => l10n.editorTextToolOptionZapGremlinsAction,
        ('zapGremlins', 'character') =>
          l10n.editorTextToolOptionZapGremlinsCharacter,
        ('prefixSuffixLines', 'mode') =>
          l10n.editorTextToolOptionPrefixSuffixLinesMode,
        ('prefixSuffixLines', 'where') =>
          l10n.editorTextToolOptionPrefixSuffixLinesWhere,
        ('prefixSuffixLines', 'text') =>
          l10n.editorTextToolOptionPrefixSuffixLinesText,
        ('prefixSuffixLines', 'skipBlankLines') =>
          l10n.editorTextToolOptionPrefixSuffixLinesSkipBlankLines,
        ('numberLines', 'mode') => l10n.editorTextToolOptionNumberLinesMode,
        ('numberLines', 'start') => l10n.editorTextToolOptionNumberLinesStart,
        ('numberLines', 'step') => l10n.editorTextToolOptionNumberLinesStep,
        ('numberLines', 'separator') =>
          l10n.editorTextToolOptionNumberLinesSeparator,
        ('numberLines', 'padding') => l10n.editorTextToolOptionNumberLinesPadding,
        ('joinLinesWith', 'separator') =>
          l10n.editorTextToolOptionJoinLinesWithSeparator,
        ('joinLinesWith', 'trim') => l10n.editorTextToolOptionJoinLinesWithTrim,
        ('joinLinesWith', 'skipBlankLines') =>
          l10n.editorTextToolOptionJoinLinesWithSkipBlankLines,
        ('convertTabsToSpaces', 'width') =>
          l10n.editorTextToolOptionConvertTabsToSpacesWidth,
        ('hardWrap', 'width') => l10n.editorTextToolOptionHardWrapWidth,
        ('hardWrap', 'fill') => l10n.editorTextToolOptionHardWrapFill,
        _ => super.textToolOptionName(toolId, optionId),
      };

  @override
  String textToolChoiceName(String choiceId) => switch (choiceId) {
    'ascending' => l10n.editorTextToolChoiceAscending,
    'descending' => l10n.editorTextToolChoiceDescending,
    'insert' => l10n.editorTextToolChoiceInsert,
    'remove' => l10n.editorTextToolChoiceRemove,
    'add' => l10n.editorTextToolChoiceAdd,
    'prefix' => l10n.editorTextToolChoicePrefix,
    'suffix' => l10n.editorTextToolChoiceSuffix,
    'none' => l10n.editorTextToolChoiceNone,
    'spaces' => l10n.editorTextToolChoiceSpaces,
    'zeros' => l10n.editorTextToolChoiceZeros,
    'delete' => l10n.editorTextToolChoiceDelete,
    'escape' => l10n.editorTextToolChoiceEscape(r'\u{…}'),
    'replace' => l10n.editorTextToolChoiceReplaceWithCharacter,
    'entity' => l10n.editorTextToolChoiceEntity,
    'inPlace' => l10n.editorTextToolChoiceInPlace,
    'clipboard' => l10n.editorTextToolChoiceClipboard,
    'newDocument' => l10n.editorTextToolChoiceNewDocument,
    _ => super.textToolChoiceName(choiceId),
  };

  @override
  String textToolDisabledToggleName(String toolId, String optionId) =>
      l10n.editorTextToolDisabledToggle(
        textToolOptionName(toolId, optionId),
      );

  @override
  String textToolOptionsSummary(TextToolRunRecord record) {
    final tool = textToolById(record.toolId);
    if (tool == null) return '';
    final parts = <String>[
      for (final option in tool.options)
        if (option is ChoiceOption &&
            record.options[option.id] is String &&
            record.options[option.id] != option.defaultValue)
          textToolChoiceName(record.options[option.id] as String)
        else if (option is ToggleOption &&
            record.options[option.id] is bool &&
            record.options[option.id] != option.defaultValue)
          record.options[option.id] == true
              ? textToolOptionName(tool.id, option.id)
              : textToolDisabledToggleName(tool.id, option.id)
        else if (option is IntegerOption &&
            record.options[option.id] is int &&
            record.options[option.id] != option.defaultValue)
          l10n.editorTextToolOptionWithValue(
            textToolOptionName(tool.id, option.id),
            record.options[option.id] as int,
          ),
    ];
    return parts.join(', ');
  }

  @override
  String repeatTextToolLabel(TextToolRunRecord? record) {
    if (record == null) return l10n.editorTextToolRepeatNone;
    final summary = textToolOptionsSummary(record);
    final name = textToolName(record.toolId);
    return summary.isEmpty
        ? l10n.editorTextToolRepeat(name)
        : l10n.editorTextToolRepeatWithSummary(name, summary);
  }

  @override
  String recentTextToolLabel(TextToolRunRecord record) {
    final summary = textToolOptionsSummary(record);
    final name = textToolName(record.toolId);
    return summary.isEmpty
        ? name
        : l10n.editorTextToolRecentWithSummary(name, summary);
  }

  // ── Post-run notice ──

  @override
  String get undo => l10n.editorUndoLabel;

  @override
  String textToolNotice(TextToolReport report) {
    final name = textToolName(report.tool.id);
    final where = _wherePhrase(report.ranOn);
    return switch (report.outcome) {
      TextToolRefused(:final reason, :final detail) => l10n
          .editorTextToolNoticeRefused(name, _refusalText(reason, detail)),
      TextToolUnchanged(:final scope, :final detail) => l10n
          .editorTextToolNoticeSentence(
            name,
            _unchangedSentence(report.tool.id, scope, where, detail),
          ),
      TextToolChanged(:final changed, :final scope, :final detail) => l10n
          .editorTextToolNoticeSentence(
            name,
            _changedSentence(report.tool.id, changed, scope, where, detail),
          ),
    };
  }

  String _wherePhrase(TextToolRanOn ranOn) => switch (ranOn) {
    TextToolRanOn.selection => l10n.editorTextToolWhereSelection,
    TextToolRanOn.document => l10n.editorTextToolWhereDocument,
    TextToolRanOn.paragraph => l10n.editorTextToolWhereParagraph,
    TextToolRanOn.word => l10n.editorTextToolWhereWord,
    TextToolRanOn.caret => l10n.editorTextToolWhereCaret,
  };

  String _refusalText(TextToolRefusal reason, String? detail) =>
      switch (reason) {
        TextToolRefusal.nothingSelected =>
          l10n.editorTextToolRefusalNothingSelected,
        TextToolRefusal.noWordAtCaret => l10n.editorTextToolRefusalNoWordAtCaret,
        TextToolRefusal.resultNotText => l10n.editorTextToolRefusalResultNotText,
        TextToolRefusal.tooLarge => l10n.editorTextToolRefusalTooLarge,
        TextToolRefusal.requiresTabs => l10n.editorTextToolRefusalRequiresTabs,
        TextToolRefusal.requiresNormalizedLineEndings =>
          l10n.editorTextToolRefusalRequiresNormalizedLineEndings,
        TextToolRefusal.noPattern => l10n.editorTextToolRefusalNoPattern,
        TextToolRefusal.invalidPattern =>
          l10n.editorTextToolRefusalInvalidPattern,
        TextToolRefusal.patternFailed => l10n.editorTextToolRefusalPatternFailed,
        TextToolRefusal.unavailable => l10n.editorTextToolRefusalUnavailable,
        TextToolRefusal.invalidJson =>
          detail == null
          ? l10n.editorTextToolRefusalInvalidJson
          : l10n.editorTextToolRefusalInvalidJsonAt(detail),
      };

  String _changedSentence(
    String id,
    int changed,
    int scope,
    String where,
    String? detail,
  ) => switch (id) {
    'sortLines' => l10n.editorTextToolChangedSortLines(changed, scope, where),
    'reverseLines' => l10n.editorTextToolChangedReverseLines(scope, where),
    'shuffleLines' => l10n.editorTextToolChangedShuffleLines(scope, where),
    'removeDuplicateLines' ||
    'keepLinesMatching' ||
    'deleteLinesMatching' =>
      l10n.editorTextToolChangedRemovedOfScope(changed, scope, where),
    'removeBlankLines' => l10n.editorTextToolChangedRemoveBlankLines(
      changed,
      where,
    ),
    'collapseBlankLines' => l10n.editorTextToolChangedCollapseBlankLines(
      changed,
      where,
    ),
    'trimLeadingWhitespace' ||
    'trimTrailingWhitespace' =>
      l10n.editorTextToolChangedTrimmedWhitespaceOn(changed, scope, where),
    'normalizeSpaces' => l10n.editorTextToolChangedNormalizedSpaces(
      changed,
      where,
    ),
    'convertTabsToSpaces' => l10n.editorTextToolChangedExpandedTabs(
      changed,
      where,
    ),
    'hardWrap' => l10n.editorTextToolChangedHardWrap(scope, where),
    'normalizeLineEndings' => l10n.editorTextToolChangedNormalizeLineEndings(
      changed,
      scope,
      where,
    ),
    'titleCase' ||
    'sentenceCase' ||
    'camelCase' ||
    'pascalCase' ||
    'snakeCase' ||
    'kebabCase' ||
    'constantCase' =>
      l10n.editorTextToolChangedChangedCase(changed, where),
    'convertIndentationToSpaces' =>
      l10n.editorTextToolChangedConvertedIndentationToSpaces(
        changed,
        scope,
        where,
      ),
    'convertIndentationToTabs' =>
      l10n.editorTextToolChangedConvertedIndentationToTabs(
        changed,
        scope,
        where,
      ),
    'uppercase' => l10n.editorTextToolChangedUppercased(changed, where),
    'lowercase' => l10n.editorTextToolChangedLowercased(changed, where),
    'straightenQuotes' => l10n.editorTextToolChangedStraightenedQuotes(
      changed,
      where,
    ),
    'convertToAscii' => _asciiChangedSentence(changed, where, detail),
    'stripDiacritics' => l10n.editorTextToolChangedStrippedMarks(
      changed,
      where,
    ),
    'composeAccents' => l10n.editorTextToolChangedComposed(changed, where),
    'decomposeAccents' => l10n.editorTextToolChangedDecomposed(changed, where),
    'formatJson' => l10n.editorTextToolChangedFormatted(changed, where),
    'minifyJson' => l10n.editorTextToolChangedMinified(changed, where),
    'zapGremlins' => switch (detail) {
      'escape' => l10n.editorTextToolChangedZapEscaped(changed, where),
      'replace' => l10n.editorTextToolChangedZapReplaced(changed, where),
      'entity' => l10n.editorTextToolChangedZapReplacedWithEntities(
        changed,
        where,
      ),
      _ => l10n.editorTextToolChangedZapRemoved(changed, where),
    },
    'removeAnsiEscapes' => l10n.editorTextToolChangedRemovedEscapeSequences(
      changed,
      where,
    ),
    'unwrapParagraphs' => l10n.editorTextToolChangedUnwrapped(
      changed,
      where,
    ),
    'prefixSuffixLines' ||
    'numberLines' => l10n.editorTextToolChangedChangedOfScope(
      changed,
      scope,
      where,
    ),
    'joinLinesWith' => l10n.editorTextToolChangedJoined(changed, where),
    'urlEncode' || 'base64Encode' => l10n.editorTextToolChangedEncoded(
      changed,
      where,
    ),
    'urlDecode' || 'base64Decode' => l10n.editorTextToolChangedDecoded(
      changed,
      where,
    ),
    'htmlEntityEncode' => l10n.editorTextToolChangedEncodedAsEntities(
      changed,
      where,
    ),
    'htmlEntityDecode' => l10n.editorTextToolChangedDecodedEntities(
      changed,
      where,
    ),
    'escapeJsonString' => l10n.editorTextToolChangedEscaped(changed, where),
    'unescapeBackslashSequences' => l10n.editorTextToolChangedDecodedEscapes(
      changed,
      where,
    ),
    'insertDate' => l10n.editorTextToolChangedInsertedDate(where),
    'insertDateTime' => l10n.editorTextToolChangedInsertedDateTime(where),
    'insertUtcTimestamp' => l10n.editorTextToolChangedInsertedUtcTimestamp(
      where,
    ),
    'insertUuid' => l10n.editorTextToolChangedInsertedUuid(where),
    'extractMatches' => _extractSentence(changed, where, detail),
    _ => l10n.editorTextToolChangedFallback(scope, where),
  };

  String _asciiChangedSentence(int changed, String where, String? detail) {
    final left = _unmappedCount(detail);
    return left > 0
        ? l10n.editorTextToolChangedConvertToAsciiWithLeft(
            changed,
            where,
            left,
          )
        : l10n.editorTextToolChangedConvertToAscii(changed, where);
  }

  String _extractSentence(int count, String where, String? detail) {
    final parts = detail?.split(':') ?? const [];
    final lines = parts.firstOrNull == 'lines';
    return switch (parts.lastOrNull) {
      'clipboard' => lines
          ? l10n.editorTextToolChangedExtractCopiedLines(count)
          : l10n.editorTextToolChangedExtractCopiedMatches(count),
      'newDocument' => lines
          ? l10n.editorTextToolChangedExtractOpenedLines(count)
          : l10n.editorTextToolChangedExtractOpenedMatches(count),
      _ => lines
          ? l10n.editorTextToolChangedExtractedLines(count, where)
          : l10n.editorTextToolChangedExtractedMatches(count, where),
    };
  }

  String _unchangedSentence(
    String id,
    int scope,
    String where,
    String? detail,
  ) => switch (id) {
    'extractMatches' => detail == null
        ? l10n.editorTextToolUnchangedNoMatches(where)
        : _extractSentence(scope, where, detail),
    'sortLines' => l10n.editorTextToolUnchangedAlreadyInOrder(scope, where),
    'reverseLines' ||
    'shuffleLines' => l10n.editorTextToolUnchangedNothingToChangeScope(
      scope,
      where,
    ),
    'removeDuplicateLines' => l10n.editorTextToolUnchangedNoDuplicateLines(
      where,
    ),
    'removeBlankLines' => l10n.editorTextToolUnchangedNoBlankLines(where),
    'collapseBlankLines' => l10n.editorTextToolUnchangedNoBlankLineRuns(where),
    'trimTrailingWhitespace' ||
    'trimLeadingWhitespace' => l10n.editorTextToolUnchangedNothingToTrim(where),
    'normalizeSpaces' => l10n.editorTextToolUnchangedNoUnicodeSpaces(where),
    'convertTabsToSpaces' => l10n.editorTextToolUnchangedNoTabsToExpand(where),
    'hardWrap' => l10n.editorTextToolUnchangedNothingToWrap(where),
    'normalizeLineEndings' => l10n.editorTextToolUnchangedEndingsConsistent(
      where,
    ),
    'convertIndentationToSpaces' ||
    'convertIndentationToTabs' => l10n.editorTextToolUnchangedNothingToConvert(
      where,
    ),
    'uppercase' ||
    'lowercase' ||
    'titleCase' ||
    'sentenceCase' ||
    'camelCase' ||
    'pascalCase' ||
    'snakeCase' ||
    'kebabCase' ||
    'constantCase' => l10n.editorTextToolUnchangedNothingToChange(where),
    'straightenQuotes' => l10n.editorTextToolUnchangedNothingToStraighten(
      where,
    ),
    'zapGremlins' => l10n.editorTextToolUnchangedNothingToZap(where),
    'convertToAscii' => _asciiUnchangedSentence(where, detail),
    'stripDiacritics' => l10n.editorTextToolUnchangedNoDiacritics(where),
    'composeAccents' => l10n.editorTextToolUnchangedAlreadyComposed(where),
    'decomposeAccents' => l10n.editorTextToolUnchangedAlreadyDecomposed(where),
    'formatJson' => l10n.editorTextToolUnchangedAlreadyFormatted(where),
    'minifyJson' => l10n.editorTextToolUnchangedAlreadyMinified(where),
    'removeAnsiEscapes' => l10n.editorTextToolUnchangedNoEscapeSequences(where),
    'unwrapParagraphs' => l10n.editorTextToolUnchangedNothingToUnwrap(where),
    'joinLinesWith' => l10n.editorTextToolUnchangedNothingToJoin(where),
    'urlDecode' || 'base64Decode' => l10n.editorTextToolUnchangedNothingToDecode(
      where,
    ),
    'htmlEntityDecode' => l10n.editorTextToolUnchangedNoEntities(where),
    'unescapeBackslashSequences' => l10n.editorTextToolUnchangedNoEscapes(
      where,
    ),
    'keepLinesMatching' => l10n.editorTextToolUnchangedEveryLineMatched(where),
    'deleteLinesMatching' => l10n.editorTextToolUnchangedNothingMatched(where),
    _ => l10n.editorTextToolUnchangedNothingToChange(where),
  };

  String _asciiUnchangedSentence(String where, String? detail) {
    final left = _unmappedCount(detail);
    return left > 0
        ? l10n.editorTextToolUnchangedNothingToConvertWithLeft(where, left)
        : l10n.editorTextToolUnchangedAlreadyAscii(where);
  }

  /// The run's detail is `unmapped:N` when non-ASCII without an equivalent
  /// was kept literal.
  int _unmappedCount(String? detail) {
    if (detail == null || !detail.startsWith('unmapped:')) return 0;
    return int.tryParse(detail.substring('unmapped:'.length)) ?? 0;
  }

  // ── Tool bar ──

  @override
  String get textToolApply => l10n.editorTextToolApply;
  @override
  String get textToolClose => l10n.editorTextToolClose;
  @override
  String get textToolAppliesTo => l10n.editorTextToolAppliesTo;
  @override
  String textToolSelectedLines(int count) =>
      l10n.editorTextToolSelectedLinesScope(count);
  @override
  String textToolWholeDocument(int count) =>
      l10n.editorTextToolWholeDocumentScope(count);
  @override
  String textToolNothingSelected(int count) =>
      l10n.editorTextToolNothingSelectedScope(count);
  @override
  String get textToolParagraphAtCaret => l10n.editorTextToolParagraphAtCaret;
  @override
  String get textToolWordAtCaret => l10n.editorTextToolWordAtCaret;
  @override
  String get textToolAtCaret => l10n.editorTextToolAtCaret;
  @override
  String get textToolPreviewDeferred => l10n.editorTextToolPreviewDeferred;

  @override
  String textToolPreview(TextToolReport report) => switch (report.outcome) {
    TextToolChanged(:final changed, :final scope) => _previewSentence(
      report.tool.id,
      changed,
      scope,
    ),
    TextToolRefused(:final reason, :final detail) => l10n
        .editorTextToolPreviewRefused(_refusalText(reason, detail)),
    TextToolUnchanged() => l10n.editorTextToolPreviewNothing,
  };

  String _previewSentence(String id, int changed, int scope) => switch (id) {
    'convertTabsToSpaces' => l10n.editorTextToolPreviewWillExpandTabs(changed),
    'hardWrap' => l10n.editorTextToolPreviewWillWrapLines(scope),
    'normalizeLineEndings' => l10n.editorTextToolPreviewWillNormalizeBreaks(
      changed,
    ),
    'sortLines' => l10n.editorTextToolPreviewSortWillMove(changed, scope),
    'reverseLines' => l10n.editorTextToolPreviewWillReverse(scope),
    'shuffleLines' => l10n.editorTextToolPreviewWillShuffle(scope),
    'removeDuplicateLines' => l10n.editorTextToolPreviewWillRemoveOfScope(
      changed,
      scope,
    ),
    'removeBlankLines' => l10n.editorTextToolPreviewWillRemoveLines(changed),
    'collapseBlankLines' => l10n.editorTextToolPreviewWillCollapse(changed),
    'trimLeadingWhitespace' => l10n.editorTextToolPreviewWillTrimLines(changed),
    'normalizeSpaces' => l10n.editorTextToolPreviewWillNormalizeSpaces(
      changed,
    ),
    'uppercase' => l10n.editorTextToolPreviewWillUppercase(changed),
    'lowercase' => l10n.editorTextToolPreviewWillLowercase(changed),
    'removeAnsiEscapes' => l10n.editorTextToolPreviewWillRemoveEscapeSequences(
      changed,
    ),
    'unwrapParagraphs' => l10n.editorTextToolPreviewWillJoinAtBreaks(changed),
    'convertToAscii' => l10n.editorTextToolPreviewWillConvert(changed),
    'stripDiacritics' => l10n.editorTextToolPreviewWillStrip(changed),
    'composeAccents' => l10n.editorTextToolPreviewWillCompose(changed),
    'decomposeAccents' => l10n.editorTextToolPreviewWillDecompose(changed),
    'formatJson' => l10n.editorTextToolPreviewWillFormat(changed),
    'minifyJson' => l10n.editorTextToolPreviewWillMinify(changed),
    'zapGremlins' => l10n.editorTextToolPreviewWillZap(changed),
    'prefixSuffixLines' => l10n.editorTextToolPreviewWillChangeOfScope(
      changed,
      scope,
    ),
    'numberLines' => l10n.editorTextToolPreviewWillRenumber(scope),
    'joinLinesWith' => l10n.editorTextToolPreviewWillJoinLines(changed),
    _ => l10n.editorTextToolPreviewWillChangeOfScope(changed, scope),
  };
}
