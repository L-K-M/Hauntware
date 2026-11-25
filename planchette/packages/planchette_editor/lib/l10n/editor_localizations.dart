import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'editor_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of EditorLocalizations
/// returned by `EditorLocalizations.of(context)`.
///
/// Applications need to include `EditorLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/editor_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: EditorLocalizations.localizationsDelegates,
///   supportedLocales: EditorLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the EditorLocalizations.supportedLocales
/// property.
abstract class EditorLocalizations {
  EditorLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static EditorLocalizations of(BuildContext context) {
    return Localizations.of<EditorLocalizations>(context, EditorLocalizations)!;
  }

  static const LocalizationsDelegate<EditorLocalizations> delegate =
      _EditorLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Remote editor: shown while the text differs from the server's.
  ///
  /// In en, this message translates to:
  /// **'Not saved'**
  String get editUnsaved;

  /// Tooltip of the shared editor's replace controls toggle.
  ///
  /// In en, this message translates to:
  /// **'Find and replace'**
  String get editorShowReplaceTooltip;

  /// Hint of the shared editor's replacement text field.
  ///
  /// In en, this message translates to:
  /// **'Replace with'**
  String get editorReplaceHint;

  /// Replace the active literal search match.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get editorReplaceLabel;

  /// Replace all literal search matches in the document.
  ///
  /// In en, this message translates to:
  /// **'Replace all'**
  String get editorReplaceAllLabel;

  /// Hint text of the editor's find query field (06 §2.3).
  ///
  /// In en, this message translates to:
  /// **'Find in file'**
  String get editorFindHint;

  /// Tooltip of the find bar's case-sensitivity toggle.
  ///
  /// In en, this message translates to:
  /// **'Match case'**
  String get editorMatchCaseTooltip;

  /// Tooltip of the find bar's previous-match button.
  ///
  /// In en, this message translates to:
  /// **'Previous match'**
  String get editorPreviousMatchTooltip;

  /// Tooltip of the find bar's next-match button.
  ///
  /// In en, this message translates to:
  /// **'Next match'**
  String get editorNextMatchTooltip;

  /// Tooltip of the find bar's close button.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get editorCloseSearchTooltip;

  /// Find bar counter shown when the query has no hits.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get editorNoMatches;

  /// Find bar counter: ordinal of the active match over the total.
  ///
  /// In en, this message translates to:
  /// **'{current}/{total}'**
  String editorMatchCount(int current, int total);

  /// Find bar counter at the match cap: the plus marks a truncated total.
  ///
  /// In en, this message translates to:
  /// **'{current}/{total}+'**
  String editorMatchCountCapped(int current, int total);

  /// Tooltip of the find bar's whole-word toggle.
  ///
  /// In en, this message translates to:
  /// **'Whole words'**
  String get editorWholeWordsTooltip;

  /// Tooltip of the find bar's regular-expression toggle.
  ///
  /// In en, this message translates to:
  /// **'Regular expression'**
  String get editorRegularExpressionTooltip;

  /// Hint text of the find query field while regular-expression mode is on.
  ///
  /// In en, this message translates to:
  /// **'Find by regular expression'**
  String get editorFindPatternHint;

  /// Find bar notice for a regular expression that does not compile; detail is the engine's own explanation, such as 'Unterminated group'.
  ///
  /// In en, this message translates to:
  /// **'Invalid pattern: {detail}'**
  String editorPatternInvalid(String detail);

  /// Find bar notice for a regular expression stopped at the search time budget.
  ///
  /// In en, this message translates to:
  /// **'Pattern took too long to search'**
  String get editorPatternTooSlow;

  /// Find bar notice when a case-insensitive search had to fall back to exact matching.
  ///
  /// In en, this message translates to:
  /// **'This text cannot be compared without case, so matching was exact.'**
  String get editorCaseFoldLimited;

  /// Label of the editor's Go to Line bar (Cmd+L on Apple platforms, Ctrl+G elsewhere).
  ///
  /// In en, this message translates to:
  /// **'Go to line'**
  String get editorGoToLineTooltip;

  /// Tooltip of the Go to Line bar's close button.
  ///
  /// In en, this message translates to:
  /// **'Close go to line'**
  String get editorCloseGoToLineTooltip;

  /// Hint text of the Go to Line field; lines is the document's line count.
  ///
  /// In en, this message translates to:
  /// **'Line or line:column, 1 to {lines}'**
  String editorGoToLineHint(int lines);

  /// Go to Line error for input that is not a line or line:column in range.
  ///
  /// In en, this message translates to:
  /// **'Enter a line from 1 to {lines}, or line:column.'**
  String editorGoToLineInvalid(int lines);

  /// Menu item and tooltip that opens the text tools browser.
  ///
  /// In en, this message translates to:
  /// **'Browse Text Tools…'**
  String get editorBrowseTextTools;

  /// Tooltip of the shared find bar's line-action row toggle.
  ///
  /// In en, this message translates to:
  /// **'Line actions'**
  String get editorLineActions;

  /// Line-action row button: keep only the lines that match the pattern.
  ///
  /// In en, this message translates to:
  /// **'Keep matching'**
  String get editorKeepMatchingLines;

  /// Line-action row button: delete the lines that match the pattern.
  ///
  /// In en, this message translates to:
  /// **'Delete matching'**
  String get editorDeleteMatchingLines;

  /// The line-action row's live count of matching lines.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 matching line} other{{count} matching lines}}'**
  String editorLineMatchCount(int count);

  /// Extraction row button: extract the pattern's matches.
  ///
  /// In en, this message translates to:
  /// **'Extract'**
  String get editorExtractAction;

  /// Tooltip of the extraction row's whole-lines toggle.
  ///
  /// In en, this message translates to:
  /// **'Extract whole matching lines'**
  String get editorExtractWholeLinesTooltip;

  /// Hint of the extraction row's replacement-template field.
  ///
  /// In en, this message translates to:
  /// **'Template (optional)'**
  String get editorExtractTemplateHint;

  /// Extraction row live count when whole lines are extracted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 line} other{{count} lines}}'**
  String editorExtractCountLines(int count);

  /// Extraction row live count when matches are extracted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 match} other{{count} matches}}'**
  String editorExtractCountMatches(int count);

  /// Replace-field preview of the active match without capture groups.
  ///
  /// In en, this message translates to:
  /// **'→ {expanded}'**
  String editorReplacementPreviewPlain(String expanded);

  /// Replace-field preview of the active match with its capture groups.
  ///
  /// In en, this message translates to:
  /// **'→ {expanded}  {groups}'**
  String editorReplacementPreview(String expanded, String groups);

  /// Placeholder shown when the replace preview has nothing to say.
  ///
  /// In en, this message translates to:
  /// **''**
  String get editorReplacementPreviewEmpty;

  /// Chip marking the find scope as the stored selection.
  ///
  /// In en, this message translates to:
  /// **'in selection'**
  String get editorSearchInSelection;

  /// Helper text explaining the stored-selection find scope.
  ///
  /// In en, this message translates to:
  /// **'Only the stored selection is searched — remove to search the file.'**
  String get editorSearchScopeHint;

  /// Find control that captures the selection as the search scope.
  ///
  /// In en, this message translates to:
  /// **'Find in Selection'**
  String get editorFindInSelection;

  /// The find bar's session search-history popover title.
  ///
  /// In en, this message translates to:
  /// **'Search history'**
  String get editorSearchHistory;

  /// The search-history popover's empty state.
  ///
  /// In en, this message translates to:
  /// **'No recent searches this session.'**
  String get editorSearchHistoryEmpty;

  /// Find control that seeds the find field from the selection.
  ///
  /// In en, this message translates to:
  /// **'Use Selection for Find'**
  String get editorUseSelectionForFind;

  /// Find control that opens the find bar seeded with the selection.
  ///
  /// In en, this message translates to:
  /// **'Find Selected Text'**
  String get editorFindSelectedText;

  /// Tooltip of the find bar's inline regular-expression cheat sheet toggle.
  ///
  /// In en, this message translates to:
  /// **'Grep cheat sheet'**
  String get editorGrepCheatSheet;

  /// Heading of the inline grep cheat sheet.
  ///
  /// In en, this message translates to:
  /// **'Regular expressions'**
  String get editorGrepCheatSheetTitle;

  /// Heading of the shared text-tools browser.
  ///
  /// In en, this message translates to:
  /// **'Text Tools'**
  String get editorTextToolsTitle;

  /// Tooltip of the browser's close button.
  ///
  /// In en, this message translates to:
  /// **'Close text tools'**
  String get editorTextToolsClose;

  /// Hint of the browser's filter field.
  ///
  /// In en, this message translates to:
  /// **'Filter tools'**
  String get editorTextToolsFilterHint;

  /// The browser's empty state when the filter matches no tool.
  ///
  /// In en, this message translates to:
  /// **'No tools match.'**
  String get editorTextToolsNoResults;

  /// The browser group listing Repeat and Recent runs.
  ///
  /// In en, this message translates to:
  /// **'Repeat and Recent'**
  String get editorTextToolsHistoryGroup;

  /// Text-tools browser group listing editing commands such as Duplicate Line, after the tool groups.
  ///
  /// In en, this message translates to:
  /// **'Editing'**
  String get editorCommandsGroup;

  /// Editing command row in the text-tools browser: Copies the selected lines, or the caret line, below themselves.
  ///
  /// In en, this message translates to:
  /// **'Duplicate Line'**
  String get editorCommandDuplicateLine;

  /// Editing command row in the text-tools browser: Swaps the selected lines, or the caret line, with the line above.
  ///
  /// In en, this message translates to:
  /// **'Move Line Up'**
  String get editorCommandMoveLineUp;

  /// Editing command row in the text-tools browser: Swaps the selected lines, or the caret line, with the line below.
  ///
  /// In en, this message translates to:
  /// **'Move Line Down'**
  String get editorCommandMoveLineDown;

  /// Editing command row in the text-tools browser: Removes the selected lines, or the caret line.
  ///
  /// In en, this message translates to:
  /// **'Delete Line'**
  String get editorCommandDeleteLine;

  /// Editing command row in the text-tools browser: Joins the selected lines, or the caret line with the next one.
  ///
  /// In en, this message translates to:
  /// **'Join Lines'**
  String get editorCommandJoinLines;

  /// Editing command row in the text-tools browser: Comments or uncomments the touched lines in the file's language.
  ///
  /// In en, this message translates to:
  /// **'Toggle Comment'**
  String get editorCommandToggleComment;

  /// Editing command row in the text-tools browser: Selects the caret line, or every line the selection touches.
  ///
  /// In en, this message translates to:
  /// **'Select Line'**
  String get editorCommandSelectLine;

  /// Editing command row in the text-tools browser: Selects the run of non-blank lines around the caret.
  ///
  /// In en, this message translates to:
  /// **'Select Paragraph'**
  String get editorCommandSelectParagraph;

  /// Editing command row in the text-tools browser: Selects the innermost bracket pair around the selection, widening on repeat.
  ///
  /// In en, this message translates to:
  /// **'Select Enclosing Brackets'**
  String get editorCommandSelectEnclosingBrackets;

  /// Editing command row in the text-tools browser: Inserts an empty indented line above the caret line.
  ///
  /// In en, this message translates to:
  /// **'Insert Line Above'**
  String get editorCommandInsertLineAbove;

  /// Editing command row in the text-tools browser: Inserts an empty indented line below the caret line.
  ///
  /// In en, this message translates to:
  /// **'Insert Line Below'**
  String get editorCommandInsertLineBelow;

  /// Editing command row in the text-tools browser: Copies the touched lines to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy Line'**
  String get editorCommandCopyLine;

  /// Editing command row in the text-tools browser: Copies the touched lines to the clipboard and removes them.
  ///
  /// In en, this message translates to:
  /// **'Cut Line'**
  String get editorCommandCutLine;

  /// Editing command row in the text-tools browser: Adds one to the number at the caret, keeping its width.
  ///
  /// In en, this message translates to:
  /// **'Increment Number'**
  String get editorCommandIncrementNumber;

  /// Editing command row in the text-tools browser: Subtracts one from the number at the caret, keeping its width.
  ///
  /// In en, this message translates to:
  /// **'Decrement Number'**
  String get editorCommandDecrementNumber;

  /// Editing command row in the text-tools browser: Pastes with later lines reindented to the caret line.
  ///
  /// In en, this message translates to:
  /// **'Paste and Match Indentation'**
  String get editorCommandPasteMatchIndentation;

  /// Editing command row in the text-tools browser: Moves the caret to the partner of the bracket beside it.
  ///
  /// In en, this message translates to:
  /// **'Go to Matching Bracket'**
  String get editorCommandGoToMatchingBracket;

  /// Editing command row in the text-tools browser: Extends the selection to the partner of the bracket beside the caret.
  ///
  /// In en, this message translates to:
  /// **'Select to Matching Bracket'**
  String get editorCommandSelectToMatchingBracket;

  /// Editing command row in the text-tools browser: Moves the caret to the next problem the editor found, such as a key set twice or JSON that does not parse.
  ///
  /// In en, this message translates to:
  /// **'Next Problem'**
  String get editorCommandNextProblem;

  /// Editing command row in the text-tools browser: Moves the caret to the previous problem the editor found.
  ///
  /// In en, this message translates to:
  /// **'Previous Problem'**
  String get editorCommandPreviousProblem;

  /// Text-tools browser group: line operations.
  ///
  /// In en, this message translates to:
  /// **'Lines'**
  String get editorTextToolGroupLines;

  /// Text-tools browser group: case conversion.
  ///
  /// In en, this message translates to:
  /// **'Case'**
  String get editorTextToolGroupChangeCase;

  /// Text-tools browser group: whitespace normalization.
  ///
  /// In en, this message translates to:
  /// **'Whitespace'**
  String get editorTextToolGroupWhitespace;

  /// Text-tools browser group: character cleanup.
  ///
  /// In en, this message translates to:
  /// **'Clean Up'**
  String get editorTextToolGroupCleanUp;

  /// Text-tools browser group: wrapping and joining.
  ///
  /// In en, this message translates to:
  /// **'Wrap'**
  String get editorTextToolGroupWrap;

  /// Text-tools browser group: encoding conversions.
  ///
  /// In en, this message translates to:
  /// **'Encode'**
  String get editorTextToolGroupEncode;

  /// Text-tools browser group: insertions.
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get editorTextToolGroupInsert;

  /// Display name of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Sort Lines'**
  String get editorTextToolNameSortLines;

  /// Display name of the reverseLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Reverse Lines'**
  String get editorTextToolNameReverseLines;

  /// Display name of the shuffleLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Shuffle Lines'**
  String get editorTextToolNameShuffleLines;

  /// Display name of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Remove Duplicate Lines'**
  String get editorTextToolNameRemoveDuplicateLines;

  /// Display name of the removeBlankLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Remove Blank Lines'**
  String get editorTextToolNameRemoveBlankLines;

  /// Display name of the collapseBlankLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Collapse Blank Lines'**
  String get editorTextToolNameCollapseBlankLines;

  /// Display name of the uppercase text tool.
  ///
  /// In en, this message translates to:
  /// **'UPPERCASE'**
  String get editorTextToolNameUppercase;

  /// Display name of the lowercase text tool.
  ///
  /// In en, this message translates to:
  /// **'lowercase'**
  String get editorTextToolNameLowercase;

  /// Display name of the titleCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Title Case'**
  String get editorTextToolNameTitleCase;

  /// Display name of the sentenceCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Sentence case'**
  String get editorTextToolNameSentenceCase;

  /// Display name of the camelCase text tool.
  ///
  /// In en, this message translates to:
  /// **'camelCase'**
  String get editorTextToolNameCamelCase;

  /// Display name of the pascalCase text tool.
  ///
  /// In en, this message translates to:
  /// **'PascalCase'**
  String get editorTextToolNamePascalCase;

  /// Display name of the snakeCase text tool.
  ///
  /// In en, this message translates to:
  /// **'snake_case'**
  String get editorTextToolNameSnakeCase;

  /// Display name of the kebabCase text tool.
  ///
  /// In en, this message translates to:
  /// **'kebab-case'**
  String get editorTextToolNameKebabCase;

  /// Display name of the constantCase text tool.
  ///
  /// In en, this message translates to:
  /// **'CONSTANT_CASE'**
  String get editorTextToolNameConstantCase;

  /// Display name of the trimTrailingWhitespace text tool.
  ///
  /// In en, this message translates to:
  /// **'Trim Trailing Whitespace'**
  String get editorTextToolNameTrimTrailingWhitespace;

  /// Display name of the trimLeadingWhitespace text tool.
  ///
  /// In en, this message translates to:
  /// **'Trim Leading Whitespace'**
  String get editorTextToolNameTrimLeadingWhitespace;

  /// Display name of the normalizeSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Normalize Spaces'**
  String get editorTextToolNameNormalizeSpaces;

  /// Display name of the normalizeLineEndings text tool.
  ///
  /// In en, this message translates to:
  /// **'Normalize Line Endings'**
  String get editorTextToolNameNormalizeLineEndings;

  /// Display name of the convertIndentationToSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Convert Indentation to Spaces'**
  String get editorTextToolNameConvertIndentationToSpaces;

  /// Display name of the convertIndentationToTabs text tool.
  ///
  /// In en, this message translates to:
  /// **'Convert Indentation to Tabs'**
  String get editorTextToolNameConvertIndentationToTabs;

  /// Display name of the convertTabsToSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Convert Tabs to Spaces'**
  String get editorTextToolNameConvertTabsToSpaces;

  /// Display name of the hardWrap text tool.
  ///
  /// In en, this message translates to:
  /// **'Hard Wrap'**
  String get editorTextToolNameHardWrap;

  /// Display name of the straightenQuotes text tool.
  ///
  /// In en, this message translates to:
  /// **'Straighten Quotes'**
  String get editorTextToolNameStraightenQuotes;

  /// Display name of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Zap Gremlins'**
  String get editorTextToolNameZapGremlins;

  /// Display name of the removeAnsiEscapes text tool.
  ///
  /// In en, this message translates to:
  /// **'Remove ANSI Escapes'**
  String get editorTextToolNameRemoveAnsiEscapes;

  /// Display name of the convertToAscii text tool.
  ///
  /// In en, this message translates to:
  /// **'Convert to ASCII'**
  String get editorTextToolNameConvertToAscii;

  /// Display name of the stripDiacritics text tool.
  ///
  /// In en, this message translates to:
  /// **'Strip Diacritics'**
  String get editorTextToolNameStripDiacritics;

  /// Display name of the composeAccents text tool.
  ///
  /// In en, this message translates to:
  /// **'Compose Accents'**
  String get editorTextToolNameComposeAccents;

  /// Display name of the decomposeAccents text tool.
  ///
  /// In en, this message translates to:
  /// **'Decompose Accents'**
  String get editorTextToolNameDecomposeAccents;

  /// Display name of the prefixSuffixLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Prefix/Suffix Lines'**
  String get editorTextToolNamePrefixSuffixLines;

  /// Display name of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Number Lines'**
  String get editorTextToolNameNumberLines;

  /// Display name of the unwrapParagraphs text tool.
  ///
  /// In en, this message translates to:
  /// **'Unwrap Paragraphs'**
  String get editorTextToolNameUnwrapParagraphs;

  /// Display name of the joinLinesWith text tool.
  ///
  /// In en, this message translates to:
  /// **'Join Lines With'**
  String get editorTextToolNameJoinLinesWith;

  /// Display name of the urlEncode text tool.
  ///
  /// In en, this message translates to:
  /// **'URL Encode'**
  String get editorTextToolNameUrlEncode;

  /// Display name of the urlDecode text tool.
  ///
  /// In en, this message translates to:
  /// **'URL Decode'**
  String get editorTextToolNameUrlDecode;

  /// Display name of the base64Encode text tool.
  ///
  /// In en, this message translates to:
  /// **'Base64 Encode'**
  String get editorTextToolNameBase64Encode;

  /// Display name of the base64Decode text tool.
  ///
  /// In en, this message translates to:
  /// **'Base64 Decode'**
  String get editorTextToolNameBase64Decode;

  /// Display name of the htmlEntityEncode text tool.
  ///
  /// In en, this message translates to:
  /// **'Encode HTML Entities'**
  String get editorTextToolNameHtmlEntityEncode;

  /// Display name of the htmlEntityDecode text tool.
  ///
  /// In en, this message translates to:
  /// **'Decode HTML Entities'**
  String get editorTextToolNameHtmlEntityDecode;

  /// Display name of the escapeJsonString text tool.
  ///
  /// In en, this message translates to:
  /// **'Escape as JSON String'**
  String get editorTextToolNameEscapeJsonString;

  /// Display name of the unescapeBackslashSequences text tool.
  ///
  /// In en, this message translates to:
  /// **'Unescape Backslash Sequences'**
  String get editorTextToolNameUnescapeBackslashSequences;

  /// Display name of the formatJson text tool.
  ///
  /// In en, this message translates to:
  /// **'Format JSON'**
  String get editorTextToolNameFormatJson;

  /// Display name of the minifyJson text tool.
  ///
  /// In en, this message translates to:
  /// **'Minify JSON'**
  String get editorTextToolNameMinifyJson;

  /// Display name of the insertDate text tool.
  ///
  /// In en, this message translates to:
  /// **'Date'**
  String get editorTextToolNameInsertDate;

  /// Display name of the insertDateTime text tool.
  ///
  /// In en, this message translates to:
  /// **'Date and Time'**
  String get editorTextToolNameInsertDateTime;

  /// Display name of the insertUtcTimestamp text tool.
  ///
  /// In en, this message translates to:
  /// **'UTC Timestamp'**
  String get editorTextToolNameInsertUtcTimestamp;

  /// Display name of the insertUuid text tool.
  ///
  /// In en, this message translates to:
  /// **'UUID'**
  String get editorTextToolNameInsertUuid;

  /// Display name of the keepLinesMatching text tool.
  ///
  /// In en, this message translates to:
  /// **'Keep Lines Matching'**
  String get editorTextToolNameKeepLinesMatching;

  /// Display name of the deleteLinesMatching text tool.
  ///
  /// In en, this message translates to:
  /// **'Delete Lines Matching'**
  String get editorTextToolNameDeleteLinesMatching;

  /// Display name of the extractMatches text tool.
  ///
  /// In en, this message translates to:
  /// **'Extract Matches'**
  String get editorTextToolNameExtractMatches;

  /// One-line description of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Orders lines alphabetically.'**
  String get editorTextToolDescriptionSortLines;

  /// One-line description of the reverseLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Reverses the order of lines.'**
  String get editorTextToolDescriptionReverseLines;

  /// One-line description of the shuffleLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Puts lines in a random order.'**
  String get editorTextToolDescriptionShuffleLines;

  /// One-line description of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Deletes repeated lines, keeping the first of each.'**
  String get editorTextToolDescriptionRemoveDuplicateLines;

  /// One-line description of the removeBlankLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Deletes empty and whitespace-only lines.'**
  String get editorTextToolDescriptionRemoveBlankLines;

  /// One-line description of the collapseBlankLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Collapses runs of blank lines to a single blank line.'**
  String get editorTextToolDescriptionCollapseBlankLines;

  /// One-line description of the uppercase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to UPPERCASE.'**
  String get editorTextToolDescriptionUppercase;

  /// One-line description of the lowercase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to lowercase.'**
  String get editorTextToolDescriptionLowercase;

  /// One-line description of the titleCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to Title Case.'**
  String get editorTextToolDescriptionTitleCase;

  /// One-line description of the sentenceCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to Sentence case.'**
  String get editorTextToolDescriptionSentenceCase;

  /// One-line description of the camelCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to camelCase.'**
  String get editorTextToolDescriptionCamelCase;

  /// One-line description of the pascalCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to PascalCase.'**
  String get editorTextToolDescriptionPascalCase;

  /// One-line description of the snakeCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to snake_case.'**
  String get editorTextToolDescriptionSnakeCase;

  /// One-line description of the kebabCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to kebab-case.'**
  String get editorTextToolDescriptionKebabCase;

  /// One-line description of the constantCase text tool.
  ///
  /// In en, this message translates to:
  /// **'Changes the word or selection to CONSTANT_CASE.'**
  String get editorTextToolDescriptionConstantCase;

  /// One-line description of the trimTrailingWhitespace text tool.
  ///
  /// In en, this message translates to:
  /// **'Removes spaces and tabs from the ends of lines.'**
  String get editorTextToolDescriptionTrimTrailingWhitespace;

  /// One-line description of the trimLeadingWhitespace text tool.
  ///
  /// In en, this message translates to:
  /// **'Removes spaces and tabs from the starts of lines.'**
  String get editorTextToolDescriptionTrimLeadingWhitespace;

  /// One-line description of the normalizeSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Replaces no-break and other Unicode spaces with plain spaces.'**
  String get editorTextToolDescriptionNormalizeSpaces;

  /// One-line description of the normalizeLineEndings text tool.
  ///
  /// In en, this message translates to:
  /// **'Makes all line breaks follow the buffer convention.'**
  String get editorTextToolDescriptionNormalizeLineEndings;

  /// One-line description of the convertIndentationToSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Replaces leading tabs with spaces, then indents with spaces.'**
  String get editorTextToolDescriptionConvertIndentationToSpaces;

  /// One-line description of the convertIndentationToTabs text tool.
  ///
  /// In en, this message translates to:
  /// **'Replaces leading space runs with tabs, then indents with tabs.'**
  String get editorTextToolDescriptionConvertIndentationToTabs;

  /// One-line description of the convertTabsToSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Expands all tabs to text-column stops. The width starts from the document setting.'**
  String get editorTextToolDescriptionConvertTabsToSpaces;

  /// One-line description of the hardWrap text tool.
  ///
  /// In en, this message translates to:
  /// **'Wraps words to text columns, keeping quote/comment prefixes and leaving lists intact.'**
  String get editorTextToolDescriptionHardWrap;

  /// One-line description of the straightenQuotes text tool.
  ///
  /// In en, this message translates to:
  /// **'Replaces curly quotes with straight ASCII quotes.'**
  String get editorTextToolDescriptionStraightenQuotes;

  /// One-line description of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Removes or replaces characters that do not belong in text.'**
  String get editorTextToolDescriptionZapGremlins;

  /// One-line description of the removeAnsiEscapes text tool.
  ///
  /// In en, this message translates to:
  /// **'Strips terminal colors and escape sequences.'**
  String get editorTextToolDescriptionRemoveAnsiEscapes;

  /// One-line description of the convertToAscii text tool.
  ///
  /// In en, this message translates to:
  /// **'Replaces quotes, dashes and accented Latin with ASCII look-alikes.'**
  String get editorTextToolDescriptionConvertToAscii;

  /// One-line description of the stripDiacritics text tool.
  ///
  /// In en, this message translates to:
  /// **'Removes combining marks, leaving the base letters.'**
  String get editorTextToolDescriptionStripDiacritics;

  /// One-line description of the composeAccents text tool.
  ///
  /// In en, this message translates to:
  /// **'Composes accented characters into their composed form.'**
  String get editorTextToolDescriptionComposeAccents;

  /// One-line description of the decomposeAccents text tool.
  ///
  /// In en, this message translates to:
  /// **'Decomposes accented characters into base plus marks.'**
  String get editorTextToolDescriptionDecomposeAccents;

  /// One-line description of the prefixSuffixLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Adds or removes the same text at the start or end of each line.'**
  String get editorTextToolDescriptionPrefixSuffixLines;

  /// One-line description of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Adds or removes line numbers.'**
  String get editorTextToolDescriptionNumberLines;

  /// One-line description of the unwrapParagraphs text tool.
  ///
  /// In en, this message translates to:
  /// **'Joins each paragraph into a single line.'**
  String get editorTextToolDescriptionUnwrapParagraphs;

  /// One-line description of the joinLinesWith text tool.
  ///
  /// In en, this message translates to:
  /// **'Joins the selected lines with a separator.'**
  String get editorTextToolDescriptionJoinLinesWith;

  /// One-line description of the urlEncode text tool.
  ///
  /// In en, this message translates to:
  /// **'Percent-encodes the selection for a URL.'**
  String get editorTextToolDescriptionUrlEncode;

  /// One-line description of the urlDecode text tool.
  ///
  /// In en, this message translates to:
  /// **'Decodes percent-encoded text.'**
  String get editorTextToolDescriptionUrlDecode;

  /// One-line description of the base64Encode text tool.
  ///
  /// In en, this message translates to:
  /// **'Encodes the selection as Base64.'**
  String get editorTextToolDescriptionBase64Encode;

  /// One-line description of the base64Decode text tool.
  ///
  /// In en, this message translates to:
  /// **'Decodes Base64 text.'**
  String get editorTextToolDescriptionBase64Decode;

  /// One-line description of the htmlEntityEncode text tool.
  ///
  /// In en, this message translates to:
  /// **'Escapes HTML specials and non-ASCII as entities.'**
  String get editorTextToolDescriptionHtmlEntityEncode;

  /// One-line description of the htmlEntityDecode text tool.
  ///
  /// In en, this message translates to:
  /// **'Decodes named and numeric HTML entities.'**
  String get editorTextToolDescriptionHtmlEntityDecode;

  /// One-line description of the escapeJsonString text tool.
  ///
  /// In en, this message translates to:
  /// **'Escapes the selection as a JSON string body.'**
  String get editorTextToolDescriptionEscapeJsonString;

  /// One-line description of the unescapeBackslashSequences text tool.
  ///
  /// In en, this message translates to:
  /// **'Decodes backslash escapes such as \\n and \\uXXXX.'**
  String get editorTextToolDescriptionUnescapeBackslashSequences;

  /// One-line description of the formatJson text tool.
  ///
  /// In en, this message translates to:
  /// **'Pretty-prints JSON with two-space indent, keeping values verbatim.'**
  String get editorTextToolDescriptionFormatJson;

  /// One-line description of the minifyJson text tool.
  ///
  /// In en, this message translates to:
  /// **'Removes insignificant whitespace from JSON, keeping values verbatim.'**
  String get editorTextToolDescriptionMinifyJson;

  /// One-line description of the insertDate text tool.
  ///
  /// In en, this message translates to:
  /// **'Inserts the current date as YYYY-MM-DD.'**
  String get editorTextToolDescriptionInsertDate;

  /// One-line description of the insertDateTime text tool.
  ///
  /// In en, this message translates to:
  /// **'Inserts the local date and time as YYYY-MM-DDThh:mm:ss.'**
  String get editorTextToolDescriptionInsertDateTime;

  /// One-line description of the insertUtcTimestamp text tool.
  ///
  /// In en, this message translates to:
  /// **'Inserts the UTC timestamp as YYYY-MM-DDThh:mm:ssZ.'**
  String get editorTextToolDescriptionInsertUtcTimestamp;

  /// One-line description of the insertUuid text tool.
  ///
  /// In en, this message translates to:
  /// **'Inserts a random UUID.'**
  String get editorTextToolDescriptionInsertUuid;

  /// One-line description of the keepLinesMatching text tool.
  ///
  /// In en, this message translates to:
  /// **'Deletes every line that does not match the pattern.'**
  String get editorTextToolDescriptionKeepLinesMatching;

  /// One-line description of the deleteLinesMatching text tool.
  ///
  /// In en, this message translates to:
  /// **'Deletes every line that matches the pattern.'**
  String get editorTextToolDescriptionDeleteLinesMatching;

  /// One-line description of the extractMatches text tool.
  ///
  /// In en, this message translates to:
  /// **'Collects every match, one per line, where it is sent.'**
  String get editorTextToolDescriptionExtractMatches;

  /// Filter keywords of the convertTabsToSpaces text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'detab\nexpand tabs\ntab stops'**
  String get editorTextToolKeywordsConvertTabsToSpaces;

  /// Filter keywords of the hardWrap text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'reflow\nfill paragraph\nwrap lines'**
  String get editorTextToolKeywordsHardWrap;

  /// Filter keywords of the normalizeLineEndings text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'eol\ncrlf\nlf\ncarriage return'**
  String get editorTextToolKeywordsNormalizeLineEndings;

  /// Filter keywords of the sortLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'order\nalphabetize\narrange'**
  String get editorTextToolKeywordsSortLines;

  /// Filter keywords of the reverseLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'flip\ninvert order'**
  String get editorTextToolKeywordsReverseLines;

  /// Filter keywords of the shuffleLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'randomize\nmix lines'**
  String get editorTextToolKeywordsShuffleLines;

  /// Filter keywords of the removeDuplicateLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'dedupe\nuniq\nunique'**
  String get editorTextToolKeywordsRemoveDuplicateLines;

  /// Filter keywords of the removeBlankLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'empty lines\ndelete blanks'**
  String get editorTextToolKeywordsRemoveBlankLines;

  /// Filter keywords of the collapseBlankLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'squeeze blank lines\nsingle blank\ncollapse empty'**
  String get editorTextToolKeywordsCollapseBlankLines;

  /// Filter keywords of the uppercase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'all caps\ncapitalize\nupcase'**
  String get editorTextToolKeywordsUppercase;

  /// Filter keywords of the lowercase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'downcase\nsmall letters'**
  String get editorTextToolKeywordsLowercase;

  /// Filter keywords of the titleCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'capitalize words\nheadline'**
  String get editorTextToolKeywordsTitleCase;

  /// Filter keywords of the sentenceCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'capitalize sentences'**
  String get editorTextToolKeywordsSentenceCase;

  /// Filter keywords of the camelCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'lower camel\nidentifier'**
  String get editorTextToolKeywordsCamelCase;

  /// Filter keywords of the pascalCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'upper camel\nidentifier'**
  String get editorTextToolKeywordsPascalCase;

  /// Filter keywords of the snakeCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'underscore\nidentifier'**
  String get editorTextToolKeywordsSnakeCase;

  /// Filter keywords of the kebabCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'hyphen\ndash case\nidentifier'**
  String get editorTextToolKeywordsKebabCase;

  /// Filter keywords of the constantCase text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'screaming snake\nmacro\nidentifier'**
  String get editorTextToolKeywordsConstantCase;

  /// Filter keywords of the trimTrailingWhitespace text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'trailing spaces\nrstrip\nstrip whitespace'**
  String get editorTextToolKeywordsTrimTrailingWhitespace;

  /// Filter keywords of the trimLeadingWhitespace text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'leading spaces\nlstrip\nunindent all'**
  String get editorTextToolKeywordsTrimLeadingWhitespace;

  /// Filter keywords of the normalizeSpaces text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'non-breaking space\nunicode spaces\nnbsp'**
  String get editorTextToolKeywordsNormalizeSpaces;

  /// Filter keywords of the convertIndentationToSpaces text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'tabs to spaces\ndetab'**
  String get editorTextToolKeywordsConvertIndentationToSpaces;

  /// Filter keywords of the convertIndentationToTabs text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'spaces to tabs\nentab'**
  String get editorTextToolKeywordsConvertIndentationToTabs;

  /// Filter keywords of the straightenQuotes text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'smart quotes\ntypographic quotes'**
  String get editorTextToolKeywordsStraightenQuotes;

  /// Filter keywords of the zapGremlins text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'control characters\ninvisible characters'**
  String get editorTextToolKeywordsZapGremlins;

  /// Filter keywords of the convertToAscii text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'ascii\ntransliterate\nlatin\nunaccent'**
  String get editorTextToolKeywordsConvertToAscii;

  /// Filter keywords of the stripDiacritics text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'diacritics\naccents\nremove marks\ncombining'**
  String get editorTextToolKeywordsStripDiacritics;

  /// Filter keywords of the composeAccents text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'nfc\nprecompose\nunicode normalize\naccents'**
  String get editorTextToolKeywordsComposeAccents;

  /// Filter keywords of the decomposeAccents text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'nfd\ndecompose\nunicode normalize\naccents'**
  String get editorTextToolKeywordsDecomposeAccents;

  /// Filter keywords of the prefixSuffixLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'quote level\ncomment out\naffix'**
  String get editorTextToolKeywordsPrefixSuffixLines;

  /// Filter keywords of the numberLines text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'line numbers\nenumerate'**
  String get editorTextToolKeywordsNumberLines;

  /// Filter keywords of the removeAnsiEscapes text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'terminal colors\nansi codes\nvt100'**
  String get editorTextToolKeywordsRemoveAnsiEscapes;

  /// Filter keywords of the unwrapParagraphs text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'unwrap lines\nreflow\nremove line breaks'**
  String get editorTextToolKeywordsUnwrapParagraphs;

  /// Filter keywords of the joinLinesWith text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'join\nunlines\nflatten'**
  String get editorTextToolKeywordsJoinLinesWith;

  /// Filter keywords of the urlEncode text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'percent encode\nuri encode'**
  String get editorTextToolKeywordsUrlEncode;

  /// Filter keywords of the urlDecode text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'percent decode\nuri decode'**
  String get editorTextToolKeywordsUrlDecode;

  /// Filter keywords of the base64Encode text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'b64\nencode base64'**
  String get editorTextToolKeywordsBase64Encode;

  /// Filter keywords of the base64Decode text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'b64\ndecode base64'**
  String get editorTextToolKeywordsBase64Decode;

  /// Filter keywords of the htmlEntityEncode text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'html escape\nentities\nescape html'**
  String get editorTextToolKeywordsHtmlEntityEncode;

  /// Filter keywords of the htmlEntityDecode text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'html unescape\nentities\nunescape html'**
  String get editorTextToolKeywordsHtmlEntityDecode;

  /// Filter keywords of the escapeJsonString text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'json escape\nescape string'**
  String get editorTextToolKeywordsEscapeJsonString;

  /// Filter keywords of the unescapeBackslashSequences text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'unescape\nescape sequences\nbackslash'**
  String get editorTextToolKeywordsUnescapeBackslashSequences;

  /// Filter keywords of the formatJson text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'pretty print\njson format\nindent json'**
  String get editorTextToolKeywordsFormatJson;

  /// Filter keywords of the minifyJson text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'minify\ncompact json\njson min'**
  String get editorTextToolKeywordsMinifyJson;

  /// Filter keywords of the keepLinesMatching text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'process lines matching\nfilter lines\ngrep lines'**
  String get editorTextToolKeywordsKeepLinesMatching;

  /// Filter keywords of the deleteLinesMatching text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'process lines matching\nfilter lines\ndelete matching'**
  String get editorTextToolKeywordsDeleteLinesMatching;

  /// Filter keywords of the extractMatches text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'collect matches\ngrep -o\nsubmatches'**
  String get editorTextToolKeywordsExtractMatches;

  /// Filter keywords of the insertDate text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'today\ncurrent date'**
  String get editorTextToolKeywordsInsertDate;

  /// Filter keywords of the insertDateTime text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'now\ntimestamp\ncurrent time'**
  String get editorTextToolKeywordsInsertDateTime;

  /// Filter keywords of the insertUtcTimestamp text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'now\nzulu\ngmt\ntimestamp'**
  String get editorTextToolKeywordsInsertUtcTimestamp;

  /// Filter keywords of the insertUuid text tool, one per line.
  ///
  /// In en, this message translates to:
  /// **'guid\nrandom id'**
  String get editorTextToolKeywordsInsertUuid;

  /// Label of the order option of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Order'**
  String get editorTextToolOptionSortLinesOrder;

  /// Label of the ignoreCase option of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Ignore case'**
  String get editorTextToolOptionSortLinesIgnoreCase;

  /// Label of the numbersByValue option of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Numbers by value'**
  String get editorTextToolOptionSortLinesNumbersByValue;

  /// Label of the byLength option of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'By length'**
  String get editorTextToolOptionSortLinesByLength;

  /// Label of the ignoreLeadingWhitespace option of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Ignore leading whitespace'**
  String get editorTextToolOptionSortLinesIgnoreLeadingWhitespace;

  /// Label of the keepFirstLine option of the sortLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Leave first line in place'**
  String get editorTextToolOptionSortLinesKeepFirstLine;

  /// Label of the adjacentOnly option of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Adjacent only'**
  String get editorTextToolOptionRemoveDuplicateLinesAdjacentOnly;

  /// Label of the ignoreCase option of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Ignore case'**
  String get editorTextToolOptionRemoveDuplicateLinesIgnoreCase;

  /// Label of the ignoreSurroundingWhitespace option of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Ignore surrounding whitespace'**
  String
  get editorTextToolOptionRemoveDuplicateLinesIgnoreSurroundingWhitespace;

  /// Label of the keepBlankLines option of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Keep blank lines'**
  String get editorTextToolOptionRemoveDuplicateLinesKeepBlankLines;

  /// Label of the removeEveryCopy option of the removeDuplicateLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Remove every copy'**
  String get editorTextToolOptionRemoveDuplicateLinesRemoveEveryCopy;

  /// Label of the controls option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Control characters'**
  String get editorTextToolOptionZapGremlinsControls;

  /// Label of the invisible option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Invisible characters'**
  String get editorTextToolOptionZapGremlinsInvisible;

  /// Label of the bidi option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Bidirectional controls'**
  String get editorTextToolOptionZapGremlinsBidi;

  /// Label of the damaged option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Damaged encoding'**
  String get editorTextToolOptionZapGremlinsDamaged;

  /// Label of the nonAscii option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'All non-ASCII'**
  String get editorTextToolOptionZapGremlinsNonAscii;

  /// Label of the action option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get editorTextToolOptionZapGremlinsAction;

  /// Label of the character option of the zapGremlins text tool.
  ///
  /// In en, this message translates to:
  /// **'Replacement character'**
  String get editorTextToolOptionZapGremlinsCharacter;

  /// Label of the mode option of the prefixSuffixLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get editorTextToolOptionPrefixSuffixLinesMode;

  /// Label of the where option of the prefixSuffixLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Where'**
  String get editorTextToolOptionPrefixSuffixLinesWhere;

  /// Label of the text option of the prefixSuffixLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get editorTextToolOptionPrefixSuffixLinesText;

  /// Label of the skipBlankLines option of the prefixSuffixLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Skip blank lines'**
  String get editorTextToolOptionPrefixSuffixLinesSkipBlankLines;

  /// Label of the mode option of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get editorTextToolOptionNumberLinesMode;

  /// Label of the start option of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Start at'**
  String get editorTextToolOptionNumberLinesStart;

  /// Label of the step option of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Step by'**
  String get editorTextToolOptionNumberLinesStep;

  /// Label of the separator option of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Separator'**
  String get editorTextToolOptionNumberLinesSeparator;

  /// Label of the padding option of the numberLines text tool.
  ///
  /// In en, this message translates to:
  /// **'Padding'**
  String get editorTextToolOptionNumberLinesPadding;

  /// Label of the separator option of the joinLinesWith text tool.
  ///
  /// In en, this message translates to:
  /// **'Separator'**
  String get editorTextToolOptionJoinLinesWithSeparator;

  /// Label of the trim option of the joinLinesWith text tool.
  ///
  /// In en, this message translates to:
  /// **'Trim lines'**
  String get editorTextToolOptionJoinLinesWithTrim;

  /// Label of the skipBlankLines option of the joinLinesWith text tool.
  ///
  /// In en, this message translates to:
  /// **'Skip blank lines'**
  String get editorTextToolOptionJoinLinesWithSkipBlankLines;

  /// Label of the width option of the convertTabsToSpaces text tool.
  ///
  /// In en, this message translates to:
  /// **'Tab width'**
  String get editorTextToolOptionConvertTabsToSpacesWidth;

  /// Label of the width option of the hardWrap text tool.
  ///
  /// In en, this message translates to:
  /// **'Text columns'**
  String get editorTextToolOptionHardWrapWidth;

  /// Label of the fill option of the hardWrap text tool.
  ///
  /// In en, this message translates to:
  /// **'Fill paragraphs'**
  String get editorTextToolOptionHardWrapFill;

  /// Choice label ascending, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'A to Z'**
  String get editorTextToolChoiceAscending;

  /// Choice label descending, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Z to A'**
  String get editorTextToolChoiceDescending;

  /// Choice label insert, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get editorTextToolChoiceInsert;

  /// Choice label remove, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get editorTextToolChoiceRemove;

  /// Choice label add, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get editorTextToolChoiceAdd;

  /// Choice label prefix, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Prefix'**
  String get editorTextToolChoicePrefix;

  /// Choice label suffix, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Suffix'**
  String get editorTextToolChoiceSuffix;

  /// Choice label none, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get editorTextToolChoiceNone;

  /// Choice label spaces, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Spaces'**
  String get editorTextToolChoiceSpaces;

  /// Choice label zeros, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Zeros'**
  String get editorTextToolChoiceZeros;

  /// Choice label delete, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get editorTextToolChoiceDelete;

  /// Choice label replace, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Replace with character'**
  String get editorTextToolChoiceReplaceWithCharacter;

  /// Choice label entity, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Numeric entity'**
  String get editorTextToolChoiceEntity;

  /// Choice label inPlace, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'In place'**
  String get editorTextToolChoiceInPlace;

  /// Choice label clipboard, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'Clipboard'**
  String get editorTextToolChoiceClipboard;

  /// Choice label newDocument, shared across text-tool options.
  ///
  /// In en, this message translates to:
  /// **'New document'**
  String get editorTextToolChoiceNewDocument;

  /// Choice label escape, shared across text-tool options; form is the escape syntax.
  ///
  /// In en, this message translates to:
  /// **'Escape as {form}'**
  String editorTextToolChoiceEscape(String form);

  /// A toggle option shown off in a Repeat or Recent summary.
  ///
  /// In en, this message translates to:
  /// **'no {option}'**
  String editorTextToolDisabledToggle(String option);

  /// A number option and its value in a Repeat or Recent summary.
  ///
  /// In en, this message translates to:
  /// **'{option} {value}'**
  String editorTextToolOptionWithValue(String option, int value);

  /// The browser's Repeat row before the first text-tool run.
  ///
  /// In en, this message translates to:
  /// **'Repeat'**
  String get editorTextToolRepeatNone;

  /// The browser's Repeat row, naming the text tool it will rerun.
  ///
  /// In en, this message translates to:
  /// **'Repeat {name}'**
  String editorTextToolRepeat(String name);

  /// The browser's Repeat row, naming the options it will rerun with.
  ///
  /// In en, this message translates to:
  /// **'Repeat {name} ({summary})'**
  String editorTextToolRepeatWithSummary(String name, String summary);

  /// A Recent row in the browser, naming its non-default options.
  ///
  /// In en, this message translates to:
  /// **'{name} ({summary})'**
  String editorTextToolRecentWithSummary(String name, String summary);

  /// Notice phrase: the tool ran on the stored selection.
  ///
  /// In en, this message translates to:
  /// **'in the selection'**
  String get editorTextToolWhereSelection;

  /// Notice phrase: the tool ran on the whole document.
  ///
  /// In en, this message translates to:
  /// **'in the whole document'**
  String get editorTextToolWhereDocument;

  /// Notice phrase: the tool ran on the paragraph at the caret.
  ///
  /// In en, this message translates to:
  /// **'in the paragraph'**
  String get editorTextToolWhereParagraph;

  /// Notice phrase: the tool ran on the word at the caret.
  ///
  /// In en, this message translates to:
  /// **'in the word'**
  String get editorTextToolWhereWord;

  /// Notice phrase: the tool ran at the caret itself.
  ///
  /// In en, this message translates to:
  /// **'at the caret'**
  String get editorTextToolWhereCaret;

  /// Why a text tool refused to run: nothing selected.
  ///
  /// In en, this message translates to:
  /// **'nothing selected'**
  String get editorTextToolRefusalNothingSelected;

  /// Why a text tool refused to run: no word at the caret.
  ///
  /// In en, this message translates to:
  /// **'no word at the caret'**
  String get editorTextToolRefusalNoWordAtCaret;

  /// Why a text tool refused to run: the result is binary, not text.
  ///
  /// In en, this message translates to:
  /// **'the result is binary, not text'**
  String get editorTextToolRefusalResultNotText;

  /// Why a text tool refused to run: the result is too large to save.
  ///
  /// In en, this message translates to:
  /// **'the result is too large to save'**
  String get editorTextToolRefusalTooLarge;

  /// Why a text tool refused to run: this format requires tab indentation.
  ///
  /// In en, this message translates to:
  /// **'this format requires tab indentation'**
  String get editorTextToolRefusalRequiresTabs;

  /// Why a text tool refused to run: use Normalize Line Endings first for lone CR separators.
  ///
  /// In en, this message translates to:
  /// **'use Normalize Line Endings first for lone CR separators'**
  String get editorTextToolRefusalRequiresNormalizedLineEndings;

  /// Why a text tool refused to run: no pattern to match.
  ///
  /// In en, this message translates to:
  /// **'no pattern to match'**
  String get editorTextToolRefusalNoPattern;

  /// Why a text tool refused to run: the pattern does not compile.
  ///
  /// In en, this message translates to:
  /// **'the pattern does not compile'**
  String get editorTextToolRefusalInvalidPattern;

  /// Why a text tool refused to run: the pattern search failed.
  ///
  /// In en, this message translates to:
  /// **'the pattern search failed'**
  String get editorTextToolRefusalPatternFailed;

  /// Why a text tool refused to run: this destination is not available.
  ///
  /// In en, this message translates to:
  /// **'this destination is not available'**
  String get editorTextToolRefusalUnavailable;

  /// Why a JSON text tool refused to run.
  ///
  /// In en, this message translates to:
  /// **'invalid JSON'**
  String get editorTextToolRefusalInvalidJson;

  /// Why a JSON text tool refused to run, with its position.
  ///
  /// In en, this message translates to:
  /// **'invalid JSON at {detail}'**
  String editorTextToolRefusalInvalidJsonAt(String detail);

  /// Changed-run notice: Sort Lines and Keep/Delete Lines Matching moved lines.
  ///
  /// In en, this message translates to:
  /// **'moved {changed} of {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedSortLines(int changed, int scope, String where);

  /// Changed-run notice: Reverse Lines.
  ///
  /// In en, this message translates to:
  /// **'reversed {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedReverseLines(int scope, String where);

  /// Changed-run notice: Shuffle Lines.
  ///
  /// In en, this message translates to:
  /// **'shuffled {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedShuffleLines(int scope, String where);

  /// Changed-run notice: Remove Duplicate Lines and Keep/Delete Lines Matching.
  ///
  /// In en, this message translates to:
  /// **'removed {changed} of {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedRemovedOfScope(
    int changed,
    int scope,
    String where,
  );

  /// Changed-run notice: Remove Blank Lines.
  ///
  /// In en, this message translates to:
  /// **'removed {changed, plural, =1{1 blank line} other{{changed} blank lines}} {where}.'**
  String editorTextToolChangedRemoveBlankLines(int changed, String where);

  /// Changed-run notice: Collapse Blank Lines.
  ///
  /// In en, this message translates to:
  /// **'collapsed {changed, plural, =1{1 blank line} other{{changed} blank lines}} {where}.'**
  String editorTextToolChangedCollapseBlankLines(int changed, String where);

  /// Changed-run notice: Trim Trailing/Leading Whitespace.
  ///
  /// In en, this message translates to:
  /// **'trimmed whitespace on {changed} of {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedTrimmedWhitespaceOn(
    int changed,
    int scope,
    String where,
  );

  /// Changed-run notice: Normalize Spaces.
  ///
  /// In en, this message translates to:
  /// **'normalized {changed, plural, =1{1 space} other{{changed} spaces}} {where}.'**
  String editorTextToolChangedNormalizedSpaces(int changed, String where);

  /// Changed-run notice: Convert Tabs to Spaces.
  ///
  /// In en, this message translates to:
  /// **'expanded {changed, plural, =1{1 tab} other{{changed} tabs}} {where}.'**
  String editorTextToolChangedExpandedTabs(int changed, String where);

  /// Changed-run notice: Hard Wrap.
  ///
  /// In en, this message translates to:
  /// **'wrapped {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedHardWrap(int scope, String where);

  /// Changed-run notice: Normalize Line Endings.
  ///
  /// In en, this message translates to:
  /// **'normalized {changed} of {scope, plural, =1{1 line break} other{{scope} line breaks}} {where}.'**
  String editorTextToolChangedNormalizeLineEndings(
    int changed,
    int scope,
    String where,
  );

  /// Changed-run notice: Title/Sentence/camel/Pascal/snake/kebab/constant case tools.
  ///
  /// In en, this message translates to:
  /// **'changed the case of {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedChangedCase(int changed, String where);

  /// Changed-run notice: Convert Indentation to Spaces.
  ///
  /// In en, this message translates to:
  /// **'converted indentation to spaces on {changed} of {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedConvertedIndentationToSpaces(
    int changed,
    int scope,
    String where,
  );

  /// Changed-run notice: Convert Indentation to Tabs.
  ///
  /// In en, this message translates to:
  /// **'converted indentation to tabs on {changed} of {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedConvertedIndentationToTabs(
    int changed,
    int scope,
    String where,
  );

  /// Changed-run notice: UPPERCASE.
  ///
  /// In en, this message translates to:
  /// **'uppercased {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedUppercased(int changed, String where);

  /// Changed-run notice: lowercase.
  ///
  /// In en, this message translates to:
  /// **'lowercased {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedLowercased(int changed, String where);

  /// Changed-run notice: Straighten Quotes.
  ///
  /// In en, this message translates to:
  /// **'straightened {changed, plural, =1{1 quote} other{{changed} quotes}} {where}.'**
  String editorTextToolChangedStraightenedQuotes(int changed, String where);

  /// Changed-run notice: Convert to ASCII, everything transliterated.
  ///
  /// In en, this message translates to:
  /// **'converted {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedConvertToAscii(int changed, String where);

  /// Changed-run notice: Convert to ASCII, some characters left literal.
  ///
  /// In en, this message translates to:
  /// **'converted {changed, plural, =1{1 character} other{{changed} characters}} {where}, {left, plural, =1{1 character} other{{left} characters}} without an equivalent left.'**
  String editorTextToolChangedConvertToAsciiWithLeft(
    int changed,
    String where,
    int left,
  );

  /// Changed-run notice: Strip Diacritics.
  ///
  /// In en, this message translates to:
  /// **'stripped {changed, plural, =1{1 mark} other{{changed} marks}} {where}.'**
  String editorTextToolChangedStrippedMarks(int changed, String where);

  /// Changed-run notice: Compose Accents.
  ///
  /// In en, this message translates to:
  /// **'composed {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedComposed(int changed, String where);

  /// Changed-run notice: Decompose Accents.
  ///
  /// In en, this message translates to:
  /// **'decomposed {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedDecomposed(int changed, String where);

  /// Changed-run notice: Format JSON.
  ///
  /// In en, this message translates to:
  /// **'formatted {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedFormatted(int changed, String where);

  /// Changed-run notice: Minify JSON.
  ///
  /// In en, this message translates to:
  /// **'minified {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedMinified(int changed, String where);

  /// Changed-run notice: Zap Gremlins, escape action.
  ///
  /// In en, this message translates to:
  /// **'escaped {changed, plural, =1{1 gremlin} other{{changed} gremlins}} {where}.'**
  String editorTextToolChangedZapEscaped(int changed, String where);

  /// Changed-run notice: Zap Gremlins, replace action.
  ///
  /// In en, this message translates to:
  /// **'replaced {changed, plural, =1{1 gremlin} other{{changed} gremlins}} {where}.'**
  String editorTextToolChangedZapReplaced(int changed, String where);

  /// Changed-run notice: Zap Gremlins, entity action.
  ///
  /// In en, this message translates to:
  /// **'replaced {changed, plural, =1{1 gremlin} other{{changed} gremlins}} with entities {where}.'**
  String editorTextToolChangedZapReplacedWithEntities(
    int changed,
    String where,
  );

  /// Changed-run notice: Zap Gremlins, remove action.
  ///
  /// In en, this message translates to:
  /// **'removed {changed, plural, =1{1 gremlin} other{{changed} gremlins}} {where}.'**
  String editorTextToolChangedZapRemoved(int changed, String where);

  /// Changed-run notice: Remove ANSI Escapes.
  ///
  /// In en, this message translates to:
  /// **'removed {changed, plural, =1{1 escape sequence} other{{changed} escape sequences}} {where}.'**
  String editorTextToolChangedRemovedEscapeSequences(int changed, String where);

  /// Changed-run notice: Unwrap Paragraphs.
  ///
  /// In en, this message translates to:
  /// **'unwrapped {changed, plural, =1{1 line break} other{{changed} line breaks}} {where}.'**
  String editorTextToolChangedUnwrapped(int changed, String where);

  /// Changed-run notice: Prefix/Suffix Lines and Number Lines.
  ///
  /// In en, this message translates to:
  /// **'changed {changed} of {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolChangedChangedOfScope(
    int changed,
    int scope,
    String where,
  );

  /// Changed-run notice: Join Lines With.
  ///
  /// In en, this message translates to:
  /// **'joined {changed, plural, =1{1 line} other{{changed} lines}} {where}.'**
  String editorTextToolChangedJoined(int changed, String where);

  /// Changed-run notice: URL/Base64 Encode.
  ///
  /// In en, this message translates to:
  /// **'encoded {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedEncoded(int changed, String where);

  /// Changed-run notice: URL/Base64 Decode.
  ///
  /// In en, this message translates to:
  /// **'decoded {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedDecoded(int changed, String where);

  /// Changed-run notice: Encode HTML Entities.
  ///
  /// In en, this message translates to:
  /// **'encoded {changed, plural, =1{1 character} other{{changed} characters}} as entities {where}.'**
  String editorTextToolChangedEncodedAsEntities(int changed, String where);

  /// Changed-run notice: Decode HTML Entities.
  ///
  /// In en, this message translates to:
  /// **'decoded {changed, plural, =1{1 entity} other{{changed} entities}} {where}.'**
  String editorTextToolChangedDecodedEntities(int changed, String where);

  /// Changed-run notice: Escape as JSON String.
  ///
  /// In en, this message translates to:
  /// **'escaped {changed, plural, =1{1 character} other{{changed} characters}} {where}.'**
  String editorTextToolChangedEscaped(int changed, String where);

  /// Changed-run notice: Unescape Backslash Sequences.
  ///
  /// In en, this message translates to:
  /// **'decoded {changed, plural, =1{1 escape} other{{changed} escapes}} {where}.'**
  String editorTextToolChangedDecodedEscapes(int changed, String where);

  /// Changed-run notice: Date.
  ///
  /// In en, this message translates to:
  /// **'inserted the current date {where}.'**
  String editorTextToolChangedInsertedDate(String where);

  /// Changed-run notice: Date and Time.
  ///
  /// In en, this message translates to:
  /// **'inserted the date and time {where}.'**
  String editorTextToolChangedInsertedDateTime(String where);

  /// Changed-run notice: UTC Timestamp.
  ///
  /// In en, this message translates to:
  /// **'inserted the UTC timestamp {where}.'**
  String editorTextToolChangedInsertedUtcTimestamp(String where);

  /// Changed-run notice: UUID.
  ///
  /// In en, this message translates to:
  /// **'inserted a UUID {where}.'**
  String editorTextToolChangedInsertedUuid(String where);

  /// Changed-run notice: Extract Matches, whole lines, to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'copied {count, plural, =1{1 line} other{{count} lines}} to the clipboard.'**
  String editorTextToolChangedExtractCopiedLines(int count);

  /// Changed-run notice: Extract Matches, matches, to the clipboard.
  ///
  /// In en, this message translates to:
  /// **'copied {count, plural, =1{1 match} other{{count} matches}} to the clipboard.'**
  String editorTextToolChangedExtractCopiedMatches(int count);

  /// Changed-run notice: Extract Matches, whole lines, in a new document.
  ///
  /// In en, this message translates to:
  /// **'opened {count, plural, =1{1 line} other{{count} lines}} in a new document.'**
  String editorTextToolChangedExtractOpenedLines(int count);

  /// Changed-run notice: Extract Matches, matches, in a new document.
  ///
  /// In en, this message translates to:
  /// **'opened {count, plural, =1{1 match} other{{count} matches}} in a new document.'**
  String editorTextToolChangedExtractOpenedMatches(int count);

  /// Changed-run notice: Extract Matches, whole lines, in place.
  ///
  /// In en, this message translates to:
  /// **'extracted {count, plural, =1{1 line} other{{count} lines}} {where}.'**
  String editorTextToolChangedExtractedLines(int count, String where);

  /// Changed-run notice: Extract Matches, matches, in place.
  ///
  /// In en, this message translates to:
  /// **'extracted {count, plural, =1{1 match} other{{count} matches}} {where}.'**
  String editorTextToolChangedExtractedMatches(int count, String where);

  /// Changed-run notice: Unknown tool. changed counts the units it changed out of the scope units it covered.
  ///
  /// In en, this message translates to:
  /// **'changed {changed} of {scope, plural, =1{1 unit} other{{scope} units}} {where}.'**
  String editorTextToolChangedFallback(int changed, int scope, String where);

  /// Unchanged-run notice: Extract Matches found nothing.
  ///
  /// In en, this message translates to:
  /// **'no matches {where}.'**
  String editorTextToolUnchangedNoMatches(String where);

  /// Unchanged-run notice: Sort Lines.
  ///
  /// In en, this message translates to:
  /// **'nothing to change, {scope, plural, =1{1 line} other{{scope} lines}} {where} already in order.'**
  String editorTextToolUnchangedAlreadyInOrder(int scope, String where);

  /// Unchanged-run notice: Reverse/Shuffle Lines.
  ///
  /// In en, this message translates to:
  /// **'nothing to change, {scope, plural, =1{1 line} other{{scope} lines}} {where}.'**
  String editorTextToolUnchangedNothingToChangeScope(int scope, String where);

  /// Unchanged-run notice: Remove Duplicate Lines.
  ///
  /// In en, this message translates to:
  /// **'nothing to change, no duplicate lines {where}.'**
  String editorTextToolUnchangedNoDuplicateLines(String where);

  /// Unchanged-run notice: Remove Blank Lines.
  ///
  /// In en, this message translates to:
  /// **'nothing to change, no blank lines {where}.'**
  String editorTextToolUnchangedNoBlankLines(String where);

  /// Unchanged-run notice: Collapse Blank Lines.
  ///
  /// In en, this message translates to:
  /// **'nothing to change, no blank-line runs {where}.'**
  String editorTextToolUnchangedNoBlankLineRuns(String where);

  /// Unchanged-run notice: Trim Trailing/Leading Whitespace.
  ///
  /// In en, this message translates to:
  /// **'nothing to trim {where}.'**
  String editorTextToolUnchangedNothingToTrim(String where);

  /// Unchanged-run notice: Normalize Spaces.
  ///
  /// In en, this message translates to:
  /// **'no Unicode spaces {where}.'**
  String editorTextToolUnchangedNoUnicodeSpaces(String where);

  /// Unchanged-run notice: Convert Tabs to Spaces.
  ///
  /// In en, this message translates to:
  /// **'no tabs to expand {where}.'**
  String editorTextToolUnchangedNoTabsToExpand(String where);

  /// Unchanged-run notice: Hard Wrap.
  ///
  /// In en, this message translates to:
  /// **'nothing to wrap {where}.'**
  String editorTextToolUnchangedNothingToWrap(String where);

  /// Unchanged-run notice: Normalize Line Endings.
  ///
  /// In en, this message translates to:
  /// **'line endings already consistent {where}.'**
  String editorTextToolUnchangedEndingsConsistent(String where);

  /// Unchanged-run notice: Convert Indentation to Spaces/Tabs.
  ///
  /// In en, this message translates to:
  /// **'nothing to convert {where}.'**
  String editorTextToolUnchangedNothingToConvert(String where);

  /// Unchanged-run notice: Case tools and unknown tools.
  ///
  /// In en, this message translates to:
  /// **'nothing to change {where}.'**
  String editorTextToolUnchangedNothingToChange(String where);

  /// Unchanged-run notice: Straighten Quotes.
  ///
  /// In en, this message translates to:
  /// **'nothing to straighten {where}.'**
  String editorTextToolUnchangedNothingToStraighten(String where);

  /// Unchanged-run notice: Zap Gremlins.
  ///
  /// In en, this message translates to:
  /// **'nothing to zap {where}.'**
  String editorTextToolUnchangedNothingToZap(String where);

  /// Unchanged-run notice: Convert to ASCII.
  ///
  /// In en, this message translates to:
  /// **'already ASCII {where}.'**
  String editorTextToolUnchangedAlreadyAscii(String where);

  /// Unchanged-run notice: Convert to ASCII with unmapped characters.
  ///
  /// In en, this message translates to:
  /// **'nothing to convert {where}, {left, plural, =1{1 character} other{{left} characters}} without an equivalent.'**
  String editorTextToolUnchangedNothingToConvertWithLeft(
    String where,
    int left,
  );

  /// Unchanged-run notice: Strip Diacritics.
  ///
  /// In en, this message translates to:
  /// **'no diacritics {where}.'**
  String editorTextToolUnchangedNoDiacritics(String where);

  /// Unchanged-run notice: Compose Accents.
  ///
  /// In en, this message translates to:
  /// **'already composed {where}.'**
  String editorTextToolUnchangedAlreadyComposed(String where);

  /// Unchanged-run notice: Decompose Accents.
  ///
  /// In en, this message translates to:
  /// **'already decomposed {where}.'**
  String editorTextToolUnchangedAlreadyDecomposed(String where);

  /// Unchanged-run notice: Format JSON.
  ///
  /// In en, this message translates to:
  /// **'already formatted {where}.'**
  String editorTextToolUnchangedAlreadyFormatted(String where);

  /// Unchanged-run notice: Minify JSON.
  ///
  /// In en, this message translates to:
  /// **'already minified {where}.'**
  String editorTextToolUnchangedAlreadyMinified(String where);

  /// Unchanged-run notice: Remove ANSI Escapes.
  ///
  /// In en, this message translates to:
  /// **'no escape sequences {where}.'**
  String editorTextToolUnchangedNoEscapeSequences(String where);

  /// Unchanged-run notice: Unwrap Paragraphs.
  ///
  /// In en, this message translates to:
  /// **'nothing to unwrap {where}.'**
  String editorTextToolUnchangedNothingToUnwrap(String where);

  /// Unchanged-run notice: Join Lines With.
  ///
  /// In en, this message translates to:
  /// **'nothing to join {where}.'**
  String editorTextToolUnchangedNothingToJoin(String where);

  /// Unchanged-run notice: URL/Base64 Decode.
  ///
  /// In en, this message translates to:
  /// **'nothing to decode {where}.'**
  String editorTextToolUnchangedNothingToDecode(String where);

  /// Unchanged-run notice: Decode HTML Entities.
  ///
  /// In en, this message translates to:
  /// **'no entities {where}.'**
  String editorTextToolUnchangedNoEntities(String where);

  /// Unchanged-run notice: Unescape Backslash Sequences.
  ///
  /// In en, this message translates to:
  /// **'no escapes {where}.'**
  String editorTextToolUnchangedNoEscapes(String where);

  /// Unchanged-run notice: Keep Lines Matching.
  ///
  /// In en, this message translates to:
  /// **'nothing to change, every line matched {where}.'**
  String editorTextToolUnchangedEveryLineMatched(String where);

  /// Unchanged-run notice: Delete Lines Matching.
  ///
  /// In en, this message translates to:
  /// **'nothing matched {where}.'**
  String editorTextToolUnchangedNothingMatched(String where);

  /// The tool bar's apply button.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get editorTextToolApply;

  /// The tool bar's close button.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get editorTextToolClose;

  /// The tool bar's scope label.
  ///
  /// In en, this message translates to:
  /// **'Applies to'**
  String get editorTextToolAppliesTo;

  /// The tool bar's scope radio for the selection.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 line} other{{count} lines}} selected'**
  String editorTextToolSelectedLinesScope(int count);

  /// The tool bar's scope radio for the document.
  ///
  /// In en, this message translates to:
  /// **'Whole document, {count, plural, =1{1 line} other{{count} lines}}'**
  String editorTextToolWholeDocumentScope(int count);

  /// The tool bar's scope line with no selection.
  ///
  /// In en, this message translates to:
  /// **'Nothing selected: whole document, {count, plural, =1{1 line} other{{count} lines}}'**
  String editorTextToolNothingSelectedScope(int count);

  /// The tool bar's scope line for paragraph-scoped tools.
  ///
  /// In en, this message translates to:
  /// **'the paragraph at the caret'**
  String get editorTextToolParagraphAtCaret;

  /// The tool bar's scope line for word-scoped tools.
  ///
  /// In en, this message translates to:
  /// **'the word at the caret'**
  String get editorTextToolWordAtCaret;

  /// The tool bar's scope line for caret-scoped tools.
  ///
  /// In en, this message translates to:
  /// **'the caret'**
  String get editorTextToolAtCaret;

  /// The tool bar's count line on a buffer too large to dry-run.
  ///
  /// In en, this message translates to:
  /// **'count is computed on Apply'**
  String get editorTextToolPreviewDeferred;

  /// The tool bar's count line when the dry run changed nothing.
  ///
  /// In en, this message translates to:
  /// **'nothing to change'**
  String get editorTextToolPreviewNothing;

  /// Tool-bar preview: Convert Tabs to Spaces.
  ///
  /// In en, this message translates to:
  /// **'will expand {changed, plural, =1{1 tab} other{{changed} tabs}}'**
  String editorTextToolPreviewWillExpandTabs(int changed);

  /// Tool-bar preview: Hard Wrap.
  ///
  /// In en, this message translates to:
  /// **'will wrap {scope, plural, =1{1 line} other{{scope} lines}}'**
  String editorTextToolPreviewWillWrapLines(int scope);

  /// Tool-bar preview: Normalize Line Endings.
  ///
  /// In en, this message translates to:
  /// **'will normalize {changed, plural, =1{1 line break} other{{changed} line breaks}}'**
  String editorTextToolPreviewWillNormalizeBreaks(int changed);

  /// Tool-bar preview: Sort Lines.
  ///
  /// In en, this message translates to:
  /// **'{changed} of {scope, plural, =1{1 line} other{{scope} lines}} will move'**
  String editorTextToolPreviewSortWillMove(int changed, int scope);

  /// Tool-bar preview: Reverse Lines.
  ///
  /// In en, this message translates to:
  /// **'will reverse {scope, plural, =1{1 line} other{{scope} lines}}'**
  String editorTextToolPreviewWillReverse(int scope);

  /// Tool-bar preview: Shuffle Lines.
  ///
  /// In en, this message translates to:
  /// **'will shuffle {scope, plural, =1{1 line} other{{scope} lines}}'**
  String editorTextToolPreviewWillShuffle(int scope);

  /// Tool-bar preview: Remove Duplicate Lines.
  ///
  /// In en, this message translates to:
  /// **'will remove {changed} of {scope, plural, =1{1 line} other{{scope} lines}}'**
  String editorTextToolPreviewWillRemoveOfScope(int changed, int scope);

  /// Tool-bar preview: Remove Blank Lines.
  ///
  /// In en, this message translates to:
  /// **'will remove {changed, plural, =1{1 line} other{{changed} lines}}'**
  String editorTextToolPreviewWillRemoveLines(int changed);

  /// Tool-bar preview: Collapse Blank Lines.
  ///
  /// In en, this message translates to:
  /// **'will collapse {changed, plural, =1{1 blank line} other{{changed} blank lines}}'**
  String editorTextToolPreviewWillCollapse(int changed);

  /// Tool-bar preview: Trim Leading Whitespace.
  ///
  /// In en, this message translates to:
  /// **'will trim {changed, plural, =1{1 line} other{{changed} lines}}'**
  String editorTextToolPreviewWillTrimLines(int changed);

  /// Tool-bar preview: Normalize Spaces.
  ///
  /// In en, this message translates to:
  /// **'will normalize {changed, plural, =1{1 space} other{{changed} spaces}}'**
  String editorTextToolPreviewWillNormalizeSpaces(int changed);

  /// Tool-bar preview: UPPERCASE.
  ///
  /// In en, this message translates to:
  /// **'will uppercase {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillUppercase(int changed);

  /// Tool-bar preview: lowercase.
  ///
  /// In en, this message translates to:
  /// **'will lowercase {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillLowercase(int changed);

  /// Tool-bar preview: Remove ANSI Escapes.
  ///
  /// In en, this message translates to:
  /// **'will remove {changed, plural, =1{1 escape sequence} other{{changed} escape sequences}}'**
  String editorTextToolPreviewWillRemoveEscapeSequences(int changed);

  /// Tool-bar preview: Unwrap Paragraphs.
  ///
  /// In en, this message translates to:
  /// **'will join lines at {changed, plural, =1{1 line break} other{{changed} line breaks}}'**
  String editorTextToolPreviewWillJoinAtBreaks(int changed);

  /// Tool-bar preview: Convert to ASCII.
  ///
  /// In en, this message translates to:
  /// **'will convert {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillConvert(int changed);

  /// Tool-bar preview: Strip Diacritics.
  ///
  /// In en, this message translates to:
  /// **'will strip {changed, plural, =1{1 mark} other{{changed} marks}}'**
  String editorTextToolPreviewWillStrip(int changed);

  /// Tool-bar preview: Compose Accents.
  ///
  /// In en, this message translates to:
  /// **'will compose {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillCompose(int changed);

  /// Tool-bar preview: Decompose Accents.
  ///
  /// In en, this message translates to:
  /// **'will decompose {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillDecompose(int changed);

  /// Tool-bar preview: Format JSON.
  ///
  /// In en, this message translates to:
  /// **'will format {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillFormat(int changed);

  /// Tool-bar preview: Minify JSON.
  ///
  /// In en, this message translates to:
  /// **'will minify {changed, plural, =1{1 character} other{{changed} characters}}'**
  String editorTextToolPreviewWillMinify(int changed);

  /// Tool-bar preview: Zap Gremlins.
  ///
  /// In en, this message translates to:
  /// **'will zap {changed, plural, =1{1 gremlin} other{{changed} gremlins}}'**
  String editorTextToolPreviewWillZap(int changed);

  /// Tool-bar preview: Prefix/Suffix Lines and unknown tools.
  ///
  /// In en, this message translates to:
  /// **'will change {changed} of {scope, plural, =1{1 line} other{{scope} lines}}'**
  String editorTextToolPreviewWillChangeOfScope(int changed, int scope);

  /// Tool-bar preview: Number Lines.
  ///
  /// In en, this message translates to:
  /// **'will renumber {scope, plural, =1{1 line} other{{scope} lines}}'**
  String editorTextToolPreviewWillRenumber(int scope);

  /// Tool-bar preview: Join Lines With.
  ///
  /// In en, this message translates to:
  /// **'will join {changed, plural, =1{1 line} other{{changed} lines}}'**
  String editorTextToolPreviewWillJoinLines(int changed);

  /// Editor status row's caret position and document size; tapping it opens Go to Line. bytes is the size the file has once saved.
  ///
  /// In en, this message translates to:
  /// **'Ln {line}, Col {column} · {lines, plural, =1{1 line} other{{lines} lines}} · {bytes, plural, =1{1 byte} other{{bytes} bytes}}'**
  String editorStatusPosition(int line, int column, int lines, int bytes);

  /// Editor status row segment for a selection within one line.
  ///
  /// In en, this message translates to:
  /// **'{characters} selected'**
  String editorStatusSelection(int characters);

  /// Editor status row segment for a selection spanning several lines; lines is always more than one.
  ///
  /// In en, this message translates to:
  /// **'{characters} selected on {lines} lines'**
  String editorStatusSelectionLines(int characters, int lines);

  /// Editor status row segment while a save is in flight.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get editorStatusSaving;

  /// Editor status row segment for a document too large to syntax-highlight.
  ///
  /// In en, this message translates to:
  /// **'Large file: no highlighting'**
  String get editorStatusLargeFile;

  /// Editor status row segment counting the problems found in the document; tapping it goes to the next one.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 problem} other{{count} problems}}'**
  String editorStatusProblemCount(int count);

  /// Tooltip of the editor status row's problem count.
  ///
  /// In en, this message translates to:
  /// **'Go to the next problem (F8)'**
  String get editorStatusNextProblemHint;

  /// Editor status row description of a syntax error at the caret; detail is the parser's own English explanation, such as "expected ',' or '}'".
  ///
  /// In en, this message translates to:
  /// **'Syntax error: {detail}'**
  String editorProblemSyntaxError(String detail);

  /// Editor status row description of a key set twice in a .env, JSON, YAML or TOML file.
  ///
  /// In en, this message translates to:
  /// **'Duplicate key \"{key}\", first set on line {line}'**
  String editorProblemDuplicateKey(String key, int line);

  /// Editor status row description of a TOML table declared twice.
  ///
  /// In en, this message translates to:
  /// **'Duplicate table [{table}], first declared on line {line}'**
  String editorProblemDuplicateTable(String table, int line);

  /// Editor status row description of an XML attribute given twice in one tag.
  ///
  /// In en, this message translates to:
  /// **'Duplicate attribute \"{attribute}\"'**
  String editorProblemDuplicateAttribute(String attribute);

  /// Editor status row description of a comment in a strict JSON file.
  ///
  /// In en, this message translates to:
  /// **'Comments are not allowed in JSON'**
  String get editorProblemJsonComment;

  /// Editor status row description of a comma before a closing bracket in a strict JSON file.
  ///
  /// In en, this message translates to:
  /// **'Trailing commas are not allowed in JSON'**
  String get editorProblemJsonTrailingComma;

  /// Editor status row description of a quoted .env value that runs to the end of the file.
  ///
  /// In en, this message translates to:
  /// **'This quoted value is never closed'**
  String get editorProblemUnterminatedQuote;

  /// Editor status row description of a YAML line indented with a tab.
  ///
  /// In en, this message translates to:
  /// **'YAML does not allow tabs for indentation'**
  String get editorProblemTabIndentation;

  /// Editor status row description of an XML closing tag that does not close the element open there; tag and open are element names.
  ///
  /// In en, this message translates to:
  /// **'</{tag}> does not match <{open}> on line {line}'**
  String editorProblemMismatchedClosingTag(String tag, String open, int line);

  /// Editor status row description of an XML element that is never closed; tag is its name.
  ///
  /// In en, this message translates to:
  /// **'<{tag}> is never closed'**
  String editorProblemUnclosedElement(String tag);

  /// Editor status row description of an XML closing tag with no element open; tag is its name.
  ///
  /// In en, this message translates to:
  /// **'</{tag}> closes no open element'**
  String editorProblemUnexpectedClosingTag(String tag);

  /// Editor status row description of version-control conflict markers left in the file.
  ///
  /// In en, this message translates to:
  /// **'Unresolved merge conflict'**
  String get editorProblemMergeConflict;

  /// Editor status row segment: the document indents with spaces, width per level.
  ///
  /// In en, this message translates to:
  /// **'Spaces: {width}'**
  String editorStatusIndentSpaces(int width);

  /// Editor status row segment: the document indents with tabs shown this many columns wide.
  ///
  /// In en, this message translates to:
  /// **'Tab Size: {width}'**
  String editorStatusIndentTabs(int width);

  /// Editor status row language name for a file with no syntax highlighting.
  ///
  /// In en, this message translates to:
  /// **'Plain Text'**
  String get editorLanguagePlainText;

  /// Editor status row language name for C, C++, Java and similar brace languages.
  ///
  /// In en, this message translates to:
  /// **'C-style'**
  String get editorLanguageCStyle;

  /// No description provided for @editorUndoLabel.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get editorUndoLabel;

  /// Dart regular-expression syntax rows of the cheat sheet, one per line.
  ///
  /// In en, this message translates to:
  /// **'. any character (except line breaks; (?s) includes them)\n\\d digits  \\w words  \\s whitespace  \\b word edge\n^ start of line  \$ end of line  (?i) ignore case\n(a|b) either  (?:...) group  (?<n>...) named group\na* none+  a+ one+  a? maybe  a{quantifier} range (greedy)\n\$1 \${bracedRef} \${namedRef} \$0 in replacements  \$\$ a dollar\nBackslashes stay literal in replacements: \\n is two characters.'**
  String editorGrepCheatSheetDart(
    String quantifier,
    String bracedRef,
    String namedRef,
  );

  /// BBEdit-to-Dart compatibility rows of the cheat sheet, one per line.
  ///
  /// In en, this message translates to:
  /// **'(?P<n>...) becomes (?<n>...)\n(?>...) becomes (?:...)\na*+ becomes a* (no possessive quantifiers)\n[[:alpha:]] becomes \\w or explicit ranges\n\\A \\z \\Z become ^ \$\n\\x{hexRef} becomes \\u{hexRef}\n(?x) verbose mode is unsupported\n\\r alone matches CR only; use \\r?\\n for breaks'**
  String editorGrepCheatSheetBBEdit(String hexRef);

  /// Notice for a refused text-tool run.
  ///
  /// In en, this message translates to:
  /// **'{name}: not applied, {reason}.'**
  String editorTextToolNoticeRefused(String name, String reason);

  /// Notice for a text-tool run that changed or examined the text.
  ///
  /// In en, this message translates to:
  /// **'{name}: {sentence}'**
  String editorTextToolNoticeSentence(String name, String sentence);

  /// The tool bar's count line for a refused dry run.
  ///
  /// In en, this message translates to:
  /// **'not applied, {reason}'**
  String editorTextToolPreviewRefused(String reason);
}

class _EditorLocalizationsDelegate
    extends LocalizationsDelegate<EditorLocalizations> {
  const _EditorLocalizationsDelegate();

  @override
  Future<EditorLocalizations> load(Locale locale) {
    return SynchronousFuture<EditorLocalizations>(
      lookupEditorLocalizations(locale),
    );
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_EditorLocalizationsDelegate old) => false;
}

EditorLocalizations lookupEditorLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return EditorLocalizationsEn();
  }

  throw FlutterError(
    'EditorLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
