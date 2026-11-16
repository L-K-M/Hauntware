// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get actionBack => 'Back';

  @override
  String get actionCancel => 'Cancel';

  @override
  String get actionClose => 'Close';

  @override
  String get actionOpen => 'Open';

  @override
  String get actionSignIn => 'Sign in';

  @override
  String get serversTitle => 'Workspace servers';

  @override
  String get serversRefresh => 'Refresh catalog';

  @override
  String get serversSignInPrompt => 'Sign in to your existing suite catalog.';

  @override
  String get serversUrl => 'Server URL';

  @override
  String get serversUsername => 'Username';

  @override
  String get serversPassword => 'Account password';

  @override
  String get serversPassphrase => 'Encryption passphrase';

  @override
  String get serversSyncCredentials => 'Sync saved passwords and keys';

  @override
  String get serversSyncCredentialsDetail =>
      'Optional. Credentials stay encrypted on this device.';

  @override
  String get serversDownloadOnly =>
      'Planchette only downloads catalog changes.';

  @override
  String serversAccount(String username, String baseUrl) {
    return '$username · $baseUrl';
  }

  @override
  String get serversSearch => 'Search servers';

  @override
  String get serversEmptyCatalog =>
      'No servers in the cached catalog. Refresh to download changes.';

  @override
  String get serversNoMatch => 'No matching servers.';

  @override
  String hostKeyConflict(String locator) {
    return 'Another device synced a different host key for $locator. Planchette kept this device\'s key and is not using the other one. If the server\'s key really changed, trust the new one; otherwise keep yours.';
  }

  @override
  String get hostKeyLocal => 'This device trusts';

  @override
  String get hostKeyPulled => 'The other device synced';

  @override
  String get hostKeyKeepLocal => 'Keep this device\'s key';

  @override
  String get hostKeyTrustNew => 'Trust the new key';

  @override
  String remoteFolderTitle(String server) {
    return 'Open Folder on $server';
  }

  @override
  String get remoteFolderLabel => 'Remote folder';

  @override
  String get remoteFolderHelper =>
      'Absolute path or relative to your login home.';

  @override
  String get remoteFolderInvalid => 'Enter a folder using /path, ~ or ~/path.';

  @override
  String get credentialExplanation =>
      'Used for this workspace session and never saved.';

  @override
  String get credentialRetry =>
      'That passphrase did not open the key. Try again. It is used for this workspace session and never saved.';

  @override
  String get credentialConnect => 'Connect';

  @override
  String diskChanged(String name) {
    return '$name changed on disk. Reload it to see the new version.';
  }

  @override
  String diskChangedWithEdits(String name) {
    return '$name changed on disk. Reload it, or keep your edits and replace it when you save.';
  }

  @override
  String get diskKeepMine => 'Keep Mine';

  @override
  String get diskReload => 'Reload';

  @override
  String diskMissing(String name) {
    return '$name was deleted or moved. Save to create it again.';
  }

  @override
  String get actionSave => 'Save';

  @override
  String get statusLineEndingTooltip => 'Line endings apply on next save';

  @override
  String get statusEncodingTooltip =>
      'Encoding applies on next save, a UTF-8 BOM adds 3 bytes';

  @override
  String get statusIndentationTooltip => 'Indentation';

  @override
  String get indentSpaces => 'Spaces';

  @override
  String get indentTabs => 'Tabs';

  @override
  String statusIndentWidth(int width) {
    return 'Width $width';
  }

  @override
  String get statusConvertToSpaces => 'Convert to Spaces';

  @override
  String get statusConvertToTabs => 'Convert to Tabs';

  @override
  String get sidebarHide => 'Hide sidebar';

  @override
  String get sidebarShow => 'Show sidebar';

  @override
  String get menuFile => 'File';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuText => 'Text';

  @override
  String get menuFind => 'Find';

  @override
  String get menuView => 'View';

  @override
  String get menuWindow => 'Window';

  @override
  String get menuNew => 'New';

  @override
  String get menuNewWindow => 'New Window';

  @override
  String get menuOpen => 'Open…';

  @override
  String get menuOpenRecent => 'Open Recent';

  @override
  String get menuNoRecentDocuments => 'No Recent Documents';

  @override
  String menuRecentDocumentInFolder(String name, String folder) {
    return '$name ($folder)';
  }

  @override
  String get menuClearRecentDocuments => 'Clear Menu';

  @override
  String get menuOpenFolder => 'Open Folder…';

  @override
  String get menuOpenServer => 'Open Server…';

  @override
  String get menuRecoverRemoteEdits => 'Recover Remote Edits…';

  @override
  String get menuOpenContainingFolder => 'Open Containing Folder';

  @override
  String get menuCloseFolderWorkspace => 'Close Folder Workspace';

  @override
  String get menuSave => 'Save';

  @override
  String get menuSaveAs => 'Save As…';

  @override
  String get menuSaveLocalCopy => 'Save a Local Copy…';

  @override
  String get menuSaveAll => 'Save All';

  @override
  String get menuRevertToSaved => 'Revert to Saved';

  @override
  String get menuExportHtml => 'Export as HTML…';

  @override
  String get menuCopyPath => 'Copy Path';

  @override
  String get menuSettings => 'Settings…';

  @override
  String get menuCloseTab => 'Close Tab';

  @override
  String get menuCloseWindow => 'Close Window';

  @override
  String get menuReopenClosedTab => 'Reopen Closed Tab';

  @override
  String get menuQuit => 'Quit';

  @override
  String get menuQuitApp => 'Quit Planchette';

  @override
  String get menuUndo => 'Undo';

  @override
  String get menuRedo => 'Redo';

  @override
  String get menuCut => 'Cut';

  @override
  String get menuCopy => 'Copy';

  @override
  String get menuPaste => 'Paste';

  @override
  String get menuSelectAll => 'Select All';

  @override
  String get menuRecentRuns => 'Recent';

  @override
  String get menuNoRecentRuns => 'No Recent Runs';

  @override
  String get menuFindEllipsis => 'Find…';

  @override
  String get menuReplace => 'Replace…';

  @override
  String get menuFindNext => 'Find Next';

  @override
  String get menuFindPrevious => 'Find Previous';

  @override
  String get menuGoToLine => 'Go to Line…';

  @override
  String get menuCompareWithSaved => 'Compare with Saved';

  @override
  String get menuHideSidebar => 'Hide Sidebar';

  @override
  String get menuShowSidebar => 'Show Sidebar';

  @override
  String get menuZoomIn => 'Zoom In';

  @override
  String get menuZoomOut => 'Zoom Out';

  @override
  String get menuActualSize => 'Actual Size';

  @override
  String get menuCommandPalette => 'Command Palette…';

  @override
  String get menuNextTab => 'Next Tab';

  @override
  String get menuPreviousTab => 'Previous Tab';

  @override
  String menuActiveWindow(String title) {
    return '✓ $title';
  }

  @override
  String get tabMenuClose => 'Close';

  @override
  String get tabMenuCloseOthers => 'Close Others';

  @override
  String get tabMenuCloseAll => 'Close All Tabs';

  @override
  String get tabMenuCopyFullPath => 'Copy Full Path';

  @override
  String tabStripNewTooltip(String shortcut) {
    return 'New ($shortcut)';
  }

  @override
  String tabStripOpenTooltip(String shortcut) {
    return 'Open… ($shortcut)';
  }

  @override
  String tabStripSaveTooltip(String shortcut) {
    return 'Save ($shortcut)';
  }

  @override
  String get commandsTooltip => 'Commands';

  @override
  String recentDocumentMissing(String name, String path) {
    return '$name is no longer at $path, so it was removed from Open Recent.';
  }

  @override
  String recentDocumentFolderUnavailable(String name, String folder) {
    return 'Could not open $name: the folder $folder is not available. If it is on a disk or share that is not connected, connect it and try again.';
  }

  @override
  String folderOpenFailed(Object error) {
    return 'Could not open folder: $error';
  }

  @override
  String workspaceOpenFailed(Object error) {
    return 'Could not open workspace: $error';
  }

  @override
  String get recoverRemoteEditsTitle => 'Recover Remote Edits';

  @override
  String get recoverRemoteEditsEmpty => 'No remote edits are awaiting upload.';

  @override
  String get recoverRemoteEditsItem =>
      'Saved locally. Open its server before retrying upload.';

  @override
  String get emptyStateTitle => 'Start with a blank page';

  @override
  String get emptyStateNew => 'New document';

  @override
  String get emptyStateOpen => 'Open…';

  @override
  String get emptyStateRecent => 'Recent';

  @override
  String get remoteSaving => 'Saving to server…';

  @override
  String get remoteUnsaved => 'Unsaved editor changes';

  @override
  String get remoteUploadPending => 'Saved locally. Upload pending.';

  @override
  String get remoteSaved => 'Saved to server';

  @override
  String remoteNotice(String path, String state) {
    return '$path\n$state';
  }

  @override
  String get remoteRetryUpload => 'Retry upload';

  @override
  String get reopenWithEncodingTooltip => 'Read the file in another encoding';

  @override
  String get reopenWithEncoding => 'Reopen with Encoding…';

  @override
  String get dismissErrorTooltip => 'Dismiss error';

  @override
  String get ghostLineSpirits => 'Start typing. The spirits are listening…';

  @override
  String get ghostLineBoard => 'Start typing. The board is waiting…';

  @override
  String get ghostLineWritten => 'Start typing. Something wants to be written…';

  @override
  String get ghostLineFinger =>
      'Start typing. Rest a finger on the planchette…';

  @override
  String get ghostLineAnswer => 'Start typing. Ask, and it will answer…';

  @override
  String tooltipWithShortcut(String action, String shortcut) {
    return '$action $shortcut';
  }

  @override
  String get folderClose => 'Close folder workspace';

  @override
  String get folderRoot => 'Workspace root';

  @override
  String get folderParent => 'Parent folder';

  @override
  String get folderRefresh => 'Refresh folder';

  @override
  String get folderHideHidden => 'Hide hidden files';

  @override
  String get folderShowHidden => 'Show hidden files';

  @override
  String get folderEmpty => 'This folder is empty';

  @override
  String get folderBrowserWidth => 'File browser width';

  @override
  String folderBrowserWidthValue(int pixels) {
    return '$pixels pixels';
  }

  @override
  String tabClose(String name) {
    return 'Close $name';
  }

  @override
  String tabUnsaved(String name) {
    return '$name, unsaved changes';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsThemeSystem => 'System';

  @override
  String get settingsThemeLight => 'Light';

  @override
  String get settingsThemeDark => 'Dark';

  @override
  String get settingsText => 'Text';

  @override
  String get settingsTextSize => 'Size';

  @override
  String get settingsLigatures => 'Ligatures';

  @override
  String get settingsLigaturesDetail =>
      'Join character pairs such as -> and != into one symbol, in fonts that draw them.';

  @override
  String get settingsIndentation => 'Indentation for new documents';

  @override
  String get settingsIndentWith => 'Indent with';

  @override
  String get settingsIndentWidth => 'Width';

  @override
  String get settingsIndentationDetail =>
      'A file that already indents, or a format that requires tabs, keeps its own.';

  @override
  String get settingsSaving => 'Saving';

  @override
  String get settingsTrimWhitespace => 'Trim trailing whitespace on save';

  @override
  String get settingsFinalNewline => 'Ensure final newline on save';

  @override
  String get settingsKeepUnsaved => 'Keep unsaved changes when quitting';

  @override
  String get settingsKeepUnsavedDetail =>
      'Quit without being asked; the open windows and unsaved changes come back at the next launch. They are kept in a private folder on this device until saved or discarded. Turn off to be asked to save instead.';

  @override
  String get settingsAppLockTitle => 'App lock';

  @override
  String get settingsAppLock => 'Require device authentication';

  @override
  String settingsAppLockDetail(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutes minutes',
      one: '1 minute',
    );
    return 'Ask for this device\'s passcode, PIN or biometrics when Planchette opens and after $_temp0 in the background. Your documents stay open behind the lock.';
  }

  @override
  String get settingsAppLockUnsupported =>
      'This platform has no device authentication Planchette can ask for.';

  @override
  String get settingsAppLockUnavailable =>
      'Set up a passcode, PIN or biometrics on this device to use the app lock.';

  @override
  String settingsAppLockNotChanged(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notAuthenticated':
          'The app lock did not change: authentication failed or was cancelled.',
      'unavailable':
          'The app lock did not change: this device has no authentication to ask for.',
      'notSaved':
          'The app lock did not change: the setting could not be saved.',
      'other': 'The app lock did not change.',
    });
    return '$_temp0';
  }

  @override
  String get appLockTitle => 'Planchette is locked';

  @override
  String get appLockDetail =>
      'Unlock with this device\'s passcode, PIN or biometrics. Your open documents and unsaved changes are kept.';

  @override
  String get appLockUnlock => 'Unlock';

  @override
  String get appLockFailed =>
      'Authentication failed or was cancelled. Try again.';

  @override
  String get appLockUnavailable =>
      'This device has no passcode, PIN or biometrics to ask for. Set one up, then try again.';

  @override
  String get appLockReason => 'Unlock Planchette';

  @override
  String get settingsAbout => 'About';

  @override
  String get settingsVersionUnknown => 'Version unknown';

  @override
  String settingsVersion(String version) {
    return 'Version $version';
  }

  @override
  String get settingsLicenses => 'Open-source licenses';

  @override
  String get settingsLicensesDetail =>
      'Public domain (Unlicense). The libraries, fonts and engine it includes keep their own licenses.';

  @override
  String get settingsLicensesLegalese =>
      'Planchette\'s own code is public domain (Unlicense). It includes third-party components that keep their own licenses, listed here.';

  @override
  String get actionDone => 'Done';

  @override
  String get settingsFont => 'Font';

  @override
  String settingsFontDefault(String font) {
    return '$font (default)';
  }

  @override
  String settingsSliderValue(String label, int value) {
    return '$label $value';
  }

  @override
  String get pickerOpenFolder => 'Open Folder';

  @override
  String get pickerOneKeyFile => 'Choose one private-key file.';

  @override
  String replaceTitle(String name) {
    return 'Replace “$name”?';
  }

  @override
  String get replaceBody =>
      'The existing file will be replaced with this document.';

  @override
  String get replaceAction => 'Replace';

  @override
  String bulkCloseTitle(int count) {
    return 'Save changes to $count documents?';
  }

  @override
  String bulkCloseBody(String names) {
    return '$names\n\nYour changes will be lost if you close without saving them.';
  }

  @override
  String get bulkCloseSaveAll => 'Save All';

  @override
  String closeTitle(String name) {
    return 'Save changes to “$name”?';
  }

  @override
  String get closeBody =>
      'Your changes will be lost if you close this document without saving.';

  @override
  String readOnlyTitle(String name) {
    return '“$name” is read-only';
  }

  @override
  String get readOnlyBody =>
      'Saving replaces the file anyway and keeps it read-only. You can save your changes as a new file instead.';

  @override
  String get readOnlySaveAnyway => 'Save Anyway';

  @override
  String get actionSaveAs => 'Save As…';

  @override
  String revertTitle(String name) {
    return 'Revert “$name” to its saved version?';
  }

  @override
  String get revertBody => 'Your unsaved changes will be lost.';

  @override
  String get revertAction => 'Revert';

  @override
  String recoveryDeleteTitle(String name) {
    return 'Delete the recovery copy “$name”?';
  }

  @override
  String get recoveryDeleteBody =>
      'It holds the earlier contents of a document Planchette could not save. If you keep it, it opens again the next time you start Planchette.';

  @override
  String get actionKeep => 'Keep';

  @override
  String get actionDelete => 'Delete';

  @override
  String saveElsewhereTitle(String name) {
    return 'Save “$name” somewhere else?';
  }

  @override
  String saveElsewhereBody(String folder) {
    return 'The folder $folder does not let Planchette create the temporary file a safe save needs, so the file cannot be saved there. You can save a copy in another folder instead.';
  }

  @override
  String siblingsTitle(String name) {
    return 'Files left by an interrupted save of “$name”';
  }

  @override
  String siblingsBody(int count, String files) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'these files',
      one: 'this file',
    );
    return 'An earlier save of this document stopped before it finished and left $_temp0 beside it. Each holds a version of its text: the one before that save or the one it was writing. Open them to compare, or delete them if you do not need them.\n\n$files';
  }

  @override
  String listedMore(String names, int count) {
    return '$names\nand $count more';
  }

  @override
  String get editUnsaved => 'Not saved';

  @override
  String get editorShowReplaceTooltip => 'Find and replace';

  @override
  String get editorReplaceHint => 'Replace with';

  @override
  String get editorReplaceLabel => 'Replace';

  @override
  String get editorReplaceAllLabel => 'Replace all';

  @override
  String get editorFindHint => 'Find in file';

  @override
  String get editorMatchCaseTooltip => 'Match case';

  @override
  String get editorPreviousMatchTooltip => 'Previous match';

  @override
  String get editorNextMatchTooltip => 'Next match';

  @override
  String get editorCloseSearchTooltip => 'Close search';

  @override
  String get editorNoMatches => 'No matches';

  @override
  String editorMatchCount(int current, int total) {
    return '$current/$total';
  }

  @override
  String editorMatchCountCapped(int current, int total) {
    return '$current/$total+';
  }

  @override
  String get editorWholeWordsTooltip => 'Whole words';

  @override
  String get editorRegularExpressionTooltip => 'Regular expression';

  @override
  String get editorFindPatternHint => 'Find by regular expression';

  @override
  String editorPatternInvalid(String detail) {
    return 'Invalid pattern: $detail';
  }

  @override
  String get editorPatternTooSlow => 'Pattern took too long to search';

  @override
  String get editorCaseFoldLimited =>
      'This text cannot be compared without case, so matching was exact.';

  @override
  String get editorGoToLineTooltip => 'Go to line';

  @override
  String get editorCloseGoToLineTooltip => 'Close go to line';

  @override
  String editorGoToLineHint(int lines) {
    return 'Line or line:column, 1 to $lines';
  }

  @override
  String editorGoToLineInvalid(int lines) {
    return 'Enter a line from 1 to $lines, or line:column.';
  }

  @override
  String get editorBrowseTextTools => 'Browse Text Tools…';

  @override
  String get editorLineActions => 'Line actions';

  @override
  String get editorKeepMatchingLines => 'Keep matching';

  @override
  String get editorDeleteMatchingLines => 'Delete matching';

  @override
  String editorLineMatchCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matching lines',
      one: '1 matching line',
    );
    return '$_temp0';
  }

  @override
  String get editorExtractAction => 'Extract';

  @override
  String get editorExtractWholeLinesTooltip => 'Extract whole matching lines';

  @override
  String get editorExtractTemplateHint => 'Template (optional)';

  @override
  String editorExtractCountLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return '$_temp0';
  }

  @override
  String editorExtractCountMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return '$_temp0';
  }

  @override
  String editorReplacementPreviewPlain(String expanded) {
    return '→ $expanded';
  }

  @override
  String editorReplacementPreview(String expanded, String groups) {
    return '→ $expanded  $groups';
  }

  @override
  String get editorReplacementPreviewEmpty => '';

  @override
  String get editorSearchInSelection => 'in selection';

  @override
  String get editorSearchScopeHint =>
      'Only the stored selection is searched — remove to search the file.';

  @override
  String get editorFindInSelection => 'Find in Selection';

  @override
  String get editorSearchHistory => 'Search history';

  @override
  String get editorSearchHistoryEmpty => 'No recent searches this session.';

  @override
  String get editorUseSelectionForFind => 'Use Selection for Find';

  @override
  String get editorFindSelectedText => 'Find Selected Text';

  @override
  String get editorGrepCheatSheet => 'Grep cheat sheet';

  @override
  String get editorGrepCheatSheetTitle => 'Regular expressions';

  @override
  String get editorTextToolsTitle => 'Text Tools';

  @override
  String get editorTextToolsClose => 'Close text tools';

  @override
  String get editorTextToolsFilterHint => 'Filter tools';

  @override
  String get editorTextToolsNoResults => 'No tools match.';

  @override
  String get editorTextToolsHistoryGroup => 'Repeat and Recent';

  @override
  String get editorCommandsGroup => 'Editing';

  @override
  String get editorCommandDuplicateLine => 'Duplicate Line';

  @override
  String get editorCommandMoveLineUp => 'Move Line Up';

  @override
  String get editorCommandMoveLineDown => 'Move Line Down';

  @override
  String get editorCommandDeleteLine => 'Delete Line';

  @override
  String get editorCommandJoinLines => 'Join Lines';

  @override
  String get editorCommandToggleComment => 'Toggle Comment';

  @override
  String get editorCommandSelectLine => 'Select Line';

  @override
  String get editorCommandSelectParagraph => 'Select Paragraph';

  @override
  String get editorCommandSelectEnclosingBrackets =>
      'Select Enclosing Brackets';

  @override
  String get editorCommandInsertLineAbove => 'Insert Line Above';

  @override
  String get editorCommandInsertLineBelow => 'Insert Line Below';

  @override
  String get editorCommandCopyLine => 'Copy Line';

  @override
  String get editorCommandCutLine => 'Cut Line';

  @override
  String get editorCommandIncrementNumber => 'Increment Number';

  @override
  String get editorCommandDecrementNumber => 'Decrement Number';

  @override
  String get editorCommandPasteMatchIndentation =>
      'Paste and Match Indentation';

  @override
  String get editorCommandGoToMatchingBracket => 'Go to Matching Bracket';

  @override
  String get editorCommandSelectToMatchingBracket =>
      'Select to Matching Bracket';

  @override
  String get editorCommandNextProblem => 'Next Problem';

  @override
  String get editorCommandPreviousProblem => 'Previous Problem';

  @override
  String get editorTextToolGroupLines => 'Lines';

  @override
  String get editorTextToolGroupChangeCase => 'Case';

  @override
  String get editorTextToolGroupWhitespace => 'Whitespace';

  @override
  String get editorTextToolGroupCleanUp => 'Clean Up';

  @override
  String get editorTextToolGroupWrap => 'Wrap';

  @override
  String get editorTextToolGroupEncode => 'Encode';

  @override
  String get editorTextToolGroupInsert => 'Insert';

  @override
  String get editorTextToolNameSortLines => 'Sort Lines';

  @override
  String get editorTextToolNameReverseLines => 'Reverse Lines';

  @override
  String get editorTextToolNameShuffleLines => 'Shuffle Lines';

  @override
  String get editorTextToolNameRemoveDuplicateLines => 'Remove Duplicate Lines';

  @override
  String get editorTextToolNameRemoveBlankLines => 'Remove Blank Lines';

  @override
  String get editorTextToolNameCollapseBlankLines => 'Collapse Blank Lines';

  @override
  String get editorTextToolNameUppercase => 'UPPERCASE';

  @override
  String get editorTextToolNameLowercase => 'lowercase';

  @override
  String get editorTextToolNameTitleCase => 'Title Case';

  @override
  String get editorTextToolNameSentenceCase => 'Sentence case';

  @override
  String get editorTextToolNameCamelCase => 'camelCase';

  @override
  String get editorTextToolNamePascalCase => 'PascalCase';

  @override
  String get editorTextToolNameSnakeCase => 'snake_case';

  @override
  String get editorTextToolNameKebabCase => 'kebab-case';

  @override
  String get editorTextToolNameConstantCase => 'CONSTANT_CASE';

  @override
  String get editorTextToolNameTrimTrailingWhitespace =>
      'Trim Trailing Whitespace';

  @override
  String get editorTextToolNameTrimLeadingWhitespace =>
      'Trim Leading Whitespace';

  @override
  String get editorTextToolNameNormalizeSpaces => 'Normalize Spaces';

  @override
  String get editorTextToolNameNormalizeLineEndings => 'Normalize Line Endings';

  @override
  String get editorTextToolNameConvertIndentationToSpaces =>
      'Convert Indentation to Spaces';

  @override
  String get editorTextToolNameConvertIndentationToTabs =>
      'Convert Indentation to Tabs';

  @override
  String get editorTextToolNameConvertTabsToSpaces => 'Convert Tabs to Spaces';

  @override
  String get editorTextToolNameHardWrap => 'Hard Wrap';

  @override
  String get editorTextToolNameStraightenQuotes => 'Straighten Quotes';

  @override
  String get editorTextToolNameZapGremlins => 'Zap Gremlins';

  @override
  String get editorTextToolNameRemoveAnsiEscapes => 'Remove ANSI Escapes';

  @override
  String get editorTextToolNameConvertToAscii => 'Convert to ASCII';

  @override
  String get editorTextToolNameStripDiacritics => 'Strip Diacritics';

  @override
  String get editorTextToolNameComposeAccents => 'Compose Accents';

  @override
  String get editorTextToolNameDecomposeAccents => 'Decompose Accents';

  @override
  String get editorTextToolNamePrefixSuffixLines => 'Prefix/Suffix Lines';

  @override
  String get editorTextToolNameNumberLines => 'Number Lines';

  @override
  String get editorTextToolNameUnwrapParagraphs => 'Unwrap Paragraphs';

  @override
  String get editorTextToolNameJoinLinesWith => 'Join Lines With';

  @override
  String get editorTextToolNameUrlEncode => 'URL Encode';

  @override
  String get editorTextToolNameUrlDecode => 'URL Decode';

  @override
  String get editorTextToolNameBase64Encode => 'Base64 Encode';

  @override
  String get editorTextToolNameBase64Decode => 'Base64 Decode';

  @override
  String get editorTextToolNameHtmlEntityEncode => 'Encode HTML Entities';

  @override
  String get editorTextToolNameHtmlEntityDecode => 'Decode HTML Entities';

  @override
  String get editorTextToolNameEscapeJsonString => 'Escape as JSON String';

  @override
  String get editorTextToolNameUnescapeBackslashSequences =>
      'Unescape Backslash Sequences';

  @override
  String get editorTextToolNameFormatJson => 'Format JSON';

  @override
  String get editorTextToolNameMinifyJson => 'Minify JSON';

  @override
  String get editorTextToolNameInsertDate => 'Date';

  @override
  String get editorTextToolNameInsertDateTime => 'Date and Time';

  @override
  String get editorTextToolNameInsertUtcTimestamp => 'UTC Timestamp';

  @override
  String get editorTextToolNameInsertUuid => 'UUID';

  @override
  String get editorTextToolNameKeepLinesMatching => 'Keep Lines Matching';

  @override
  String get editorTextToolNameDeleteLinesMatching => 'Delete Lines Matching';

  @override
  String get editorTextToolNameExtractMatches => 'Extract Matches';

  @override
  String get editorTextToolDescriptionSortLines =>
      'Orders lines alphabetically.';

  @override
  String get editorTextToolDescriptionReverseLines =>
      'Reverses the order of lines.';

  @override
  String get editorTextToolDescriptionShuffleLines =>
      'Puts lines in a random order.';

  @override
  String get editorTextToolDescriptionRemoveDuplicateLines =>
      'Deletes repeated lines, keeping the first of each.';

  @override
  String get editorTextToolDescriptionRemoveBlankLines =>
      'Deletes empty and whitespace-only lines.';

  @override
  String get editorTextToolDescriptionCollapseBlankLines =>
      'Collapses runs of blank lines to a single blank line.';

  @override
  String get editorTextToolDescriptionUppercase =>
      'Changes the word or selection to UPPERCASE.';

  @override
  String get editorTextToolDescriptionLowercase =>
      'Changes the word or selection to lowercase.';

  @override
  String get editorTextToolDescriptionTitleCase =>
      'Changes the word or selection to Title Case.';

  @override
  String get editorTextToolDescriptionSentenceCase =>
      'Changes the word or selection to Sentence case.';

  @override
  String get editorTextToolDescriptionCamelCase =>
      'Changes the word or selection to camelCase.';

  @override
  String get editorTextToolDescriptionPascalCase =>
      'Changes the word or selection to PascalCase.';

  @override
  String get editorTextToolDescriptionSnakeCase =>
      'Changes the word or selection to snake_case.';

  @override
  String get editorTextToolDescriptionKebabCase =>
      'Changes the word or selection to kebab-case.';

  @override
  String get editorTextToolDescriptionConstantCase =>
      'Changes the word or selection to CONSTANT_CASE.';

  @override
  String get editorTextToolDescriptionTrimTrailingWhitespace =>
      'Removes spaces and tabs from the ends of lines.';

  @override
  String get editorTextToolDescriptionTrimLeadingWhitespace =>
      'Removes spaces and tabs from the starts of lines.';

  @override
  String get editorTextToolDescriptionNormalizeSpaces =>
      'Replaces no-break and other Unicode spaces with plain spaces.';

  @override
  String get editorTextToolDescriptionNormalizeLineEndings =>
      'Makes all line breaks follow the buffer convention.';

  @override
  String get editorTextToolDescriptionConvertIndentationToSpaces =>
      'Replaces leading tabs with spaces, then indents with spaces.';

  @override
  String get editorTextToolDescriptionConvertIndentationToTabs =>
      'Replaces leading space runs with tabs, then indents with tabs.';

  @override
  String get editorTextToolDescriptionConvertTabsToSpaces =>
      'Expands all tabs to text-column stops. The width starts from the document setting.';

  @override
  String get editorTextToolDescriptionHardWrap =>
      'Wraps words to text columns, keeping quote/comment prefixes and leaving lists intact.';

  @override
  String get editorTextToolDescriptionStraightenQuotes =>
      'Replaces curly quotes with straight ASCII quotes.';

  @override
  String get editorTextToolDescriptionZapGremlins =>
      'Removes or replaces characters that do not belong in text.';

  @override
  String get editorTextToolDescriptionRemoveAnsiEscapes =>
      'Strips terminal colors and escape sequences.';

  @override
  String get editorTextToolDescriptionConvertToAscii =>
      'Replaces quotes, dashes and accented Latin with ASCII look-alikes.';

  @override
  String get editorTextToolDescriptionStripDiacritics =>
      'Removes combining marks, leaving the base letters.';

  @override
  String get editorTextToolDescriptionComposeAccents =>
      'Composes accented characters into their composed form.';

  @override
  String get editorTextToolDescriptionDecomposeAccents =>
      'Decomposes accented characters into base plus marks.';

  @override
  String get editorTextToolDescriptionPrefixSuffixLines =>
      'Adds or removes the same text at the start or end of each line.';

  @override
  String get editorTextToolDescriptionNumberLines =>
      'Adds or removes line numbers.';

  @override
  String get editorTextToolDescriptionUnwrapParagraphs =>
      'Joins each paragraph into a single line.';

  @override
  String get editorTextToolDescriptionJoinLinesWith =>
      'Joins the selected lines with a separator.';

  @override
  String get editorTextToolDescriptionUrlEncode =>
      'Percent-encodes the selection for a URL.';

  @override
  String get editorTextToolDescriptionUrlDecode =>
      'Decodes percent-encoded text.';

  @override
  String get editorTextToolDescriptionBase64Encode =>
      'Encodes the selection as Base64.';

  @override
  String get editorTextToolDescriptionBase64Decode => 'Decodes Base64 text.';

  @override
  String get editorTextToolDescriptionHtmlEntityEncode =>
      'Escapes HTML specials and non-ASCII as entities.';

  @override
  String get editorTextToolDescriptionHtmlEntityDecode =>
      'Decodes named and numeric HTML entities.';

  @override
  String get editorTextToolDescriptionEscapeJsonString =>
      'Escapes the selection as a JSON string body.';

  @override
  String get editorTextToolDescriptionUnescapeBackslashSequences =>
      'Decodes backslash escapes such as \\n and \\uXXXX.';

  @override
  String get editorTextToolDescriptionFormatJson =>
      'Pretty-prints JSON with two-space indent, keeping values verbatim.';

  @override
  String get editorTextToolDescriptionMinifyJson =>
      'Removes insignificant whitespace from JSON, keeping values verbatim.';

  @override
  String get editorTextToolDescriptionInsertDate =>
      'Inserts the current date as YYYY-MM-DD.';

  @override
  String get editorTextToolDescriptionInsertDateTime =>
      'Inserts the local date and time as YYYY-MM-DDThh:mm:ss.';

  @override
  String get editorTextToolDescriptionInsertUtcTimestamp =>
      'Inserts the UTC timestamp as YYYY-MM-DDThh:mm:ssZ.';

  @override
  String get editorTextToolDescriptionInsertUuid => 'Inserts a random UUID.';

  @override
  String get editorTextToolDescriptionKeepLinesMatching =>
      'Deletes every line that does not match the pattern.';

  @override
  String get editorTextToolDescriptionDeleteLinesMatching =>
      'Deletes every line that matches the pattern.';

  @override
  String get editorTextToolDescriptionExtractMatches =>
      'Collects every match, one per line, where it is sent.';

  @override
  String get editorTextToolKeywordsConvertTabsToSpaces =>
      'detab\nexpand tabs\ntab stops';

  @override
  String get editorTextToolKeywordsHardWrap =>
      'reflow\nfill paragraph\nwrap lines';

  @override
  String get editorTextToolKeywordsNormalizeLineEndings =>
      'eol\ncrlf\nlf\ncarriage return';

  @override
  String get editorTextToolKeywordsSortLines => 'order\nalphabetize\narrange';

  @override
  String get editorTextToolKeywordsReverseLines => 'flip\ninvert order';

  @override
  String get editorTextToolKeywordsShuffleLines => 'randomize\nmix lines';

  @override
  String get editorTextToolKeywordsRemoveDuplicateLines =>
      'dedupe\nuniq\nunique';

  @override
  String get editorTextToolKeywordsRemoveBlankLines =>
      'empty lines\ndelete blanks';

  @override
  String get editorTextToolKeywordsCollapseBlankLines =>
      'squeeze blank lines\nsingle blank\ncollapse empty';

  @override
  String get editorTextToolKeywordsUppercase => 'all caps\ncapitalize\nupcase';

  @override
  String get editorTextToolKeywordsLowercase => 'downcase\nsmall letters';

  @override
  String get editorTextToolKeywordsTitleCase => 'capitalize words\nheadline';

  @override
  String get editorTextToolKeywordsSentenceCase => 'capitalize sentences';

  @override
  String get editorTextToolKeywordsCamelCase => 'lower camel\nidentifier';

  @override
  String get editorTextToolKeywordsPascalCase => 'upper camel\nidentifier';

  @override
  String get editorTextToolKeywordsSnakeCase => 'underscore\nidentifier';

  @override
  String get editorTextToolKeywordsKebabCase => 'hyphen\ndash case\nidentifier';

  @override
  String get editorTextToolKeywordsConstantCase =>
      'screaming snake\nmacro\nidentifier';

  @override
  String get editorTextToolKeywordsTrimTrailingWhitespace =>
      'trailing spaces\nrstrip\nstrip whitespace';

  @override
  String get editorTextToolKeywordsTrimLeadingWhitespace =>
      'leading spaces\nlstrip\nunindent all';

  @override
  String get editorTextToolKeywordsNormalizeSpaces =>
      'non-breaking space\nunicode spaces\nnbsp';

  @override
  String get editorTextToolKeywordsConvertIndentationToSpaces =>
      'tabs to spaces\ndetab';

  @override
  String get editorTextToolKeywordsConvertIndentationToTabs =>
      'spaces to tabs\nentab';

  @override
  String get editorTextToolKeywordsStraightenQuotes =>
      'smart quotes\ntypographic quotes';

  @override
  String get editorTextToolKeywordsZapGremlins =>
      'control characters\ninvisible characters';

  @override
  String get editorTextToolKeywordsConvertToAscii =>
      'ascii\ntransliterate\nlatin\nunaccent';

  @override
  String get editorTextToolKeywordsStripDiacritics =>
      'diacritics\naccents\nremove marks\ncombining';

  @override
  String get editorTextToolKeywordsComposeAccents =>
      'nfc\nprecompose\nunicode normalize\naccents';

  @override
  String get editorTextToolKeywordsDecomposeAccents =>
      'nfd\ndecompose\nunicode normalize\naccents';

  @override
  String get editorTextToolKeywordsPrefixSuffixLines =>
      'quote level\ncomment out\naffix';

  @override
  String get editorTextToolKeywordsNumberLines => 'line numbers\nenumerate';

  @override
  String get editorTextToolKeywordsRemoveAnsiEscapes =>
      'terminal colors\nansi codes\nvt100';

  @override
  String get editorTextToolKeywordsUnwrapParagraphs =>
      'unwrap lines\nreflow\nremove line breaks';

  @override
  String get editorTextToolKeywordsJoinLinesWith => 'join\nunlines\nflatten';

  @override
  String get editorTextToolKeywordsUrlEncode => 'percent encode\nuri encode';

  @override
  String get editorTextToolKeywordsUrlDecode => 'percent decode\nuri decode';

  @override
  String get editorTextToolKeywordsBase64Encode => 'b64\nencode base64';

  @override
  String get editorTextToolKeywordsBase64Decode => 'b64\ndecode base64';

  @override
  String get editorTextToolKeywordsHtmlEntityEncode =>
      'html escape\nentities\nescape html';

  @override
  String get editorTextToolKeywordsHtmlEntityDecode =>
      'html unescape\nentities\nunescape html';

  @override
  String get editorTextToolKeywordsEscapeJsonString =>
      'json escape\nescape string';

  @override
  String get editorTextToolKeywordsUnescapeBackslashSequences =>
      'unescape\nescape sequences\nbackslash';

  @override
  String get editorTextToolKeywordsFormatJson =>
      'pretty print\njson format\nindent json';

  @override
  String get editorTextToolKeywordsMinifyJson =>
      'minify\ncompact json\njson min';

  @override
  String get editorTextToolKeywordsKeepLinesMatching =>
      'process lines matching\nfilter lines\ngrep lines';

  @override
  String get editorTextToolKeywordsDeleteLinesMatching =>
      'process lines matching\nfilter lines\ndelete matching';

  @override
  String get editorTextToolKeywordsExtractMatches =>
      'collect matches\ngrep -o\nsubmatches';

  @override
  String get editorTextToolKeywordsInsertDate => 'today\ncurrent date';

  @override
  String get editorTextToolKeywordsInsertDateTime =>
      'now\ntimestamp\ncurrent time';

  @override
  String get editorTextToolKeywordsInsertUtcTimestamp =>
      'now\nzulu\ngmt\ntimestamp';

  @override
  String get editorTextToolKeywordsInsertUuid => 'guid\nrandom id';

  @override
  String get editorTextToolOptionSortLinesOrder => 'Order';

  @override
  String get editorTextToolOptionSortLinesIgnoreCase => 'Ignore case';

  @override
  String get editorTextToolOptionSortLinesNumbersByValue => 'Numbers by value';

  @override
  String get editorTextToolOptionSortLinesByLength => 'By length';

  @override
  String get editorTextToolOptionSortLinesIgnoreLeadingWhitespace =>
      'Ignore leading whitespace';

  @override
  String get editorTextToolOptionSortLinesKeepFirstLine =>
      'Leave first line in place';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesAdjacentOnly =>
      'Adjacent only';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesIgnoreCase =>
      'Ignore case';

  @override
  String
  get editorTextToolOptionRemoveDuplicateLinesIgnoreSurroundingWhitespace =>
      'Ignore surrounding whitespace';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesKeepBlankLines =>
      'Keep blank lines';

  @override
  String get editorTextToolOptionRemoveDuplicateLinesRemoveEveryCopy =>
      'Remove every copy';

  @override
  String get editorTextToolOptionZapGremlinsControls => 'Control characters';

  @override
  String get editorTextToolOptionZapGremlinsInvisible => 'Invisible characters';

  @override
  String get editorTextToolOptionZapGremlinsBidi => 'Bidirectional controls';

  @override
  String get editorTextToolOptionZapGremlinsDamaged => 'Damaged encoding';

  @override
  String get editorTextToolOptionZapGremlinsNonAscii => 'All non-ASCII';

  @override
  String get editorTextToolOptionZapGremlinsAction => 'Action';

  @override
  String get editorTextToolOptionZapGremlinsCharacter =>
      'Replacement character';

  @override
  String get editorTextToolOptionPrefixSuffixLinesMode => 'Mode';

  @override
  String get editorTextToolOptionPrefixSuffixLinesWhere => 'Where';

  @override
  String get editorTextToolOptionPrefixSuffixLinesText => 'Text';

  @override
  String get editorTextToolOptionPrefixSuffixLinesSkipBlankLines =>
      'Skip blank lines';

  @override
  String get editorTextToolOptionNumberLinesMode => 'Mode';

  @override
  String get editorTextToolOptionNumberLinesStart => 'Start at';

  @override
  String get editorTextToolOptionNumberLinesStep => 'Step by';

  @override
  String get editorTextToolOptionNumberLinesSeparator => 'Separator';

  @override
  String get editorTextToolOptionNumberLinesPadding => 'Padding';

  @override
  String get editorTextToolOptionJoinLinesWithSeparator => 'Separator';

  @override
  String get editorTextToolOptionJoinLinesWithTrim => 'Trim lines';

  @override
  String get editorTextToolOptionJoinLinesWithSkipBlankLines =>
      'Skip blank lines';

  @override
  String get editorTextToolOptionConvertTabsToSpacesWidth => 'Tab width';

  @override
  String get editorTextToolOptionHardWrapWidth => 'Text columns';

  @override
  String get editorTextToolOptionHardWrapFill => 'Fill paragraphs';

  @override
  String get editorTextToolChoiceAscending => 'A to Z';

  @override
  String get editorTextToolChoiceDescending => 'Z to A';

  @override
  String get editorTextToolChoiceInsert => 'Insert';

  @override
  String get editorTextToolChoiceRemove => 'Remove';

  @override
  String get editorTextToolChoiceAdd => 'Add';

  @override
  String get editorTextToolChoicePrefix => 'Prefix';

  @override
  String get editorTextToolChoiceSuffix => 'Suffix';

  @override
  String get editorTextToolChoiceNone => 'None';

  @override
  String get editorTextToolChoiceSpaces => 'Spaces';

  @override
  String get editorTextToolChoiceZeros => 'Zeros';

  @override
  String get editorTextToolChoiceDelete => 'Delete';

  @override
  String get editorTextToolChoiceReplaceWithCharacter =>
      'Replace with character';

  @override
  String get editorTextToolChoiceEntity => 'Numeric entity';

  @override
  String get editorTextToolChoiceInPlace => 'In place';

  @override
  String get editorTextToolChoiceClipboard => 'Clipboard';

  @override
  String get editorTextToolChoiceNewDocument => 'New document';

  @override
  String editorTextToolChoiceEscape(String form) {
    return 'Escape as $form';
  }

  @override
  String editorTextToolDisabledToggle(String option) {
    return 'no $option';
  }

  @override
  String editorTextToolOptionWithValue(String option, int value) {
    return '$option $value';
  }

  @override
  String get editorTextToolRepeatNone => 'Repeat';

  @override
  String editorTextToolRepeat(String name) {
    return 'Repeat $name';
  }

  @override
  String editorTextToolRepeatWithSummary(String name, String summary) {
    return 'Repeat $name ($summary)';
  }

  @override
  String editorTextToolRecentWithSummary(String name, String summary) {
    return '$name ($summary)';
  }

  @override
  String get editorTextToolWhereSelection => 'in the selection';

  @override
  String get editorTextToolWhereDocument => 'in the whole document';

  @override
  String get editorTextToolWhereParagraph => 'in the paragraph';

  @override
  String get editorTextToolWhereWord => 'in the word';

  @override
  String get editorTextToolWhereCaret => 'at the caret';

  @override
  String get editorTextToolRefusalNothingSelected => 'nothing selected';

  @override
  String get editorTextToolRefusalNoWordAtCaret => 'no word at the caret';

  @override
  String get editorTextToolRefusalResultNotText =>
      'the result is binary, not text';

  @override
  String get editorTextToolRefusalTooLarge => 'the result is too large to save';

  @override
  String get editorTextToolRefusalRequiresTabs =>
      'this format requires tab indentation';

  @override
  String get editorTextToolRefusalRequiresNormalizedLineEndings =>
      'use Normalize Line Endings first for lone CR separators';

  @override
  String get editorTextToolRefusalNoPattern => 'no pattern to match';

  @override
  String get editorTextToolRefusalInvalidPattern =>
      'the pattern does not compile';

  @override
  String get editorTextToolRefusalPatternFailed => 'the pattern search failed';

  @override
  String get editorTextToolRefusalUnavailable =>
      'this destination is not available';

  @override
  String get editorTextToolRefusalInvalidJson => 'invalid JSON';

  @override
  String editorTextToolRefusalInvalidJsonAt(String detail) {
    return 'invalid JSON at $detail';
  }

  @override
  String editorTextToolChangedSortLines(int changed, int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'moved $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedReverseLines(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'reversed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedShuffleLines(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'shuffled $_temp0 $where.';
  }

  @override
  String editorTextToolChangedRemovedOfScope(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'removed $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedRemoveBlankLines(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed blank lines',
      one: '1 blank line',
    );
    return 'removed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedCollapseBlankLines(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed blank lines',
      one: '1 blank line',
    );
    return 'collapsed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedTrimmedWhitespaceOn(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'trimmed whitespace on $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedNormalizedSpaces(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed spaces',
      one: '1 space',
    );
    return 'normalized $_temp0 $where.';
  }

  @override
  String editorTextToolChangedExpandedTabs(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed tabs',
      one: '1 tab',
    );
    return 'expanded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedHardWrap(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'wrapped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedNormalizeLineEndings(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope line breaks',
      one: '1 line break',
    );
    return 'normalized $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedChangedCase(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'changed the case of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertedIndentationToSpaces(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'converted indentation to spaces on $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertedIndentationToTabs(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'converted indentation to tabs on $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedUppercased(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'uppercased $_temp0 $where.';
  }

  @override
  String editorTextToolChangedLowercased(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'lowercased $_temp0 $where.';
  }

  @override
  String editorTextToolChangedStraightenedQuotes(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed quotes',
      one: '1 quote',
    );
    return 'straightened $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertToAscii(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'converted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedConvertToAsciiWithLeft(
    int changed,
    String where,
    int left,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    String _temp1 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$left characters',
      one: '1 character',
    );
    return 'converted $_temp0 $where, $_temp1 without an equivalent left.';
  }

  @override
  String editorTextToolChangedStrippedMarks(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed marks',
      one: '1 mark',
    );
    return 'stripped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedComposed(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'composed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedDecomposed(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'decomposed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedFormatted(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'formatted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedMinified(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'minified $_temp0 $where.';
  }

  @override
  String editorTextToolChangedZapEscaped(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'escaped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedZapReplaced(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'replaced $_temp0 $where.';
  }

  @override
  String editorTextToolChangedZapReplacedWithEntities(
    int changed,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'replaced $_temp0 with entities $where.';
  }

  @override
  String editorTextToolChangedZapRemoved(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'removed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedRemovedEscapeSequences(
    int changed,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed escape sequences',
      one: '1 escape sequence',
    );
    return 'removed $_temp0 $where.';
  }

  @override
  String editorTextToolChangedUnwrapped(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed line breaks',
      one: '1 line break',
    );
    return 'unwrapped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedChangedOfScope(
    int changed,
    int scope,
    String where,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'changed $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolChangedJoined(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'joined $_temp0 $where.';
  }

  @override
  String editorTextToolChangedEncoded(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'encoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedDecoded(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'decoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedEncodedAsEntities(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'encoded $_temp0 as entities $where.';
  }

  @override
  String editorTextToolChangedDecodedEntities(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed entities',
      one: '1 entity',
    );
    return 'decoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedEscaped(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'escaped $_temp0 $where.';
  }

  @override
  String editorTextToolChangedDecodedEscapes(int changed, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed escapes',
      one: '1 escape',
    );
    return 'decoded $_temp0 $where.';
  }

  @override
  String editorTextToolChangedInsertedDate(String where) {
    return 'inserted the current date $where.';
  }

  @override
  String editorTextToolChangedInsertedDateTime(String where) {
    return 'inserted the date and time $where.';
  }

  @override
  String editorTextToolChangedInsertedUtcTimestamp(String where) {
    return 'inserted the UTC timestamp $where.';
  }

  @override
  String editorTextToolChangedInsertedUuid(String where) {
    return 'inserted a UUID $where.';
  }

  @override
  String editorTextToolChangedExtractCopiedLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'copied $_temp0 to the clipboard.';
  }

  @override
  String editorTextToolChangedExtractCopiedMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return 'copied $_temp0 to the clipboard.';
  }

  @override
  String editorTextToolChangedExtractOpenedLines(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'opened $_temp0 in a new document.';
  }

  @override
  String editorTextToolChangedExtractOpenedMatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return 'opened $_temp0 in a new document.';
  }

  @override
  String editorTextToolChangedExtractedLines(int count, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'extracted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedExtractedMatches(int count, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count matches',
      one: '1 match',
    );
    return 'extracted $_temp0 $where.';
  }

  @override
  String editorTextToolChangedFallback(int changed, int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope units',
      one: '1 unit',
    );
    return 'changed $changed of $_temp0 $where.';
  }

  @override
  String editorTextToolUnchangedNoMatches(String where) {
    return 'no matches $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyInOrder(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'nothing to change, $_temp0 $where already in order.';
  }

  @override
  String editorTextToolUnchangedNothingToChangeScope(int scope, String where) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'nothing to change, $_temp0 $where.';
  }

  @override
  String editorTextToolUnchangedNoDuplicateLines(String where) {
    return 'nothing to change, no duplicate lines $where.';
  }

  @override
  String editorTextToolUnchangedNoBlankLines(String where) {
    return 'nothing to change, no blank lines $where.';
  }

  @override
  String editorTextToolUnchangedNoBlankLineRuns(String where) {
    return 'nothing to change, no blank-line runs $where.';
  }

  @override
  String editorTextToolUnchangedNothingToTrim(String where) {
    return 'nothing to trim $where.';
  }

  @override
  String editorTextToolUnchangedNoUnicodeSpaces(String where) {
    return 'no Unicode spaces $where.';
  }

  @override
  String editorTextToolUnchangedNoTabsToExpand(String where) {
    return 'no tabs to expand $where.';
  }

  @override
  String editorTextToolUnchangedNothingToWrap(String where) {
    return 'nothing to wrap $where.';
  }

  @override
  String editorTextToolUnchangedEndingsConsistent(String where) {
    return 'line endings already consistent $where.';
  }

  @override
  String editorTextToolUnchangedNothingToConvert(String where) {
    return 'nothing to convert $where.';
  }

  @override
  String editorTextToolUnchangedNothingToChange(String where) {
    return 'nothing to change $where.';
  }

  @override
  String editorTextToolUnchangedNothingToStraighten(String where) {
    return 'nothing to straighten $where.';
  }

  @override
  String editorTextToolUnchangedNothingToZap(String where) {
    return 'nothing to zap $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyAscii(String where) {
    return 'already ASCII $where.';
  }

  @override
  String editorTextToolUnchangedNothingToConvertWithLeft(
    String where,
    int left,
  ) {
    String _temp0 = intl.Intl.pluralLogic(
      left,
      locale: localeName,
      other: '$left characters',
      one: '1 character',
    );
    return 'nothing to convert $where, $_temp0 without an equivalent.';
  }

  @override
  String editorTextToolUnchangedNoDiacritics(String where) {
    return 'no diacritics $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyComposed(String where) {
    return 'already composed $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyDecomposed(String where) {
    return 'already decomposed $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyFormatted(String where) {
    return 'already formatted $where.';
  }

  @override
  String editorTextToolUnchangedAlreadyMinified(String where) {
    return 'already minified $where.';
  }

  @override
  String editorTextToolUnchangedNoEscapeSequences(String where) {
    return 'no escape sequences $where.';
  }

  @override
  String editorTextToolUnchangedNothingToUnwrap(String where) {
    return 'nothing to unwrap $where.';
  }

  @override
  String editorTextToolUnchangedNothingToJoin(String where) {
    return 'nothing to join $where.';
  }

  @override
  String editorTextToolUnchangedNothingToDecode(String where) {
    return 'nothing to decode $where.';
  }

  @override
  String editorTextToolUnchangedNoEntities(String where) {
    return 'no entities $where.';
  }

  @override
  String editorTextToolUnchangedNoEscapes(String where) {
    return 'no escapes $where.';
  }

  @override
  String editorTextToolUnchangedEveryLineMatched(String where) {
    return 'nothing to change, every line matched $where.';
  }

  @override
  String editorTextToolUnchangedNothingMatched(String where) {
    return 'nothing matched $where.';
  }

  @override
  String get editorTextToolApply => 'Apply';

  @override
  String get editorTextToolClose => 'Close';

  @override
  String get editorTextToolAppliesTo => 'Applies to';

  @override
  String editorTextToolSelectedLinesScope(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return '$_temp0 selected';
  }

  @override
  String editorTextToolWholeDocumentScope(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'Whole document, $_temp0';
  }

  @override
  String editorTextToolNothingSelectedScope(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines',
      one: '1 line',
    );
    return 'Nothing selected: whole document, $_temp0';
  }

  @override
  String get editorTextToolParagraphAtCaret => 'the paragraph at the caret';

  @override
  String get editorTextToolWordAtCaret => 'the word at the caret';

  @override
  String get editorTextToolAtCaret => 'the caret';

  @override
  String get editorTextToolPreviewDeferred => 'count is computed on Apply';

  @override
  String get editorTextToolPreviewNothing => 'nothing to change';

  @override
  String editorTextToolPreviewWillExpandTabs(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed tabs',
      one: '1 tab',
    );
    return 'will expand $_temp0';
  }

  @override
  String editorTextToolPreviewWillWrapLines(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will wrap $_temp0';
  }

  @override
  String editorTextToolPreviewWillNormalizeBreaks(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed line breaks',
      one: '1 line break',
    );
    return 'will normalize $_temp0';
  }

  @override
  String editorTextToolPreviewSortWillMove(int changed, int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return '$changed of $_temp0 will move';
  }

  @override
  String editorTextToolPreviewWillReverse(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will reverse $_temp0';
  }

  @override
  String editorTextToolPreviewWillShuffle(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will shuffle $_temp0';
  }

  @override
  String editorTextToolPreviewWillRemoveOfScope(int changed, int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will remove $changed of $_temp0';
  }

  @override
  String editorTextToolPreviewWillRemoveLines(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'will remove $_temp0';
  }

  @override
  String editorTextToolPreviewWillCollapse(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed blank lines',
      one: '1 blank line',
    );
    return 'will collapse $_temp0';
  }

  @override
  String editorTextToolPreviewWillTrimLines(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'will trim $_temp0';
  }

  @override
  String editorTextToolPreviewWillNormalizeSpaces(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed spaces',
      one: '1 space',
    );
    return 'will normalize $_temp0';
  }

  @override
  String editorTextToolPreviewWillUppercase(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will uppercase $_temp0';
  }

  @override
  String editorTextToolPreviewWillLowercase(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will lowercase $_temp0';
  }

  @override
  String editorTextToolPreviewWillRemoveEscapeSequences(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed escape sequences',
      one: '1 escape sequence',
    );
    return 'will remove $_temp0';
  }

  @override
  String editorTextToolPreviewWillJoinAtBreaks(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed line breaks',
      one: '1 line break',
    );
    return 'will join lines at $_temp0';
  }

  @override
  String editorTextToolPreviewWillConvert(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will convert $_temp0';
  }

  @override
  String editorTextToolPreviewWillStrip(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed marks',
      one: '1 mark',
    );
    return 'will strip $_temp0';
  }

  @override
  String editorTextToolPreviewWillCompose(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will compose $_temp0';
  }

  @override
  String editorTextToolPreviewWillDecompose(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will decompose $_temp0';
  }

  @override
  String editorTextToolPreviewWillFormat(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will format $_temp0';
  }

  @override
  String editorTextToolPreviewWillMinify(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed characters',
      one: '1 character',
    );
    return 'will minify $_temp0';
  }

  @override
  String editorTextToolPreviewWillZap(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed gremlins',
      one: '1 gremlin',
    );
    return 'will zap $_temp0';
  }

  @override
  String editorTextToolPreviewWillChangeOfScope(int changed, int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will change $changed of $_temp0';
  }

  @override
  String editorTextToolPreviewWillRenumber(int scope) {
    String _temp0 = intl.Intl.pluralLogic(
      scope,
      locale: localeName,
      other: '$scope lines',
      one: '1 line',
    );
    return 'will renumber $_temp0';
  }

  @override
  String editorTextToolPreviewWillJoinLines(int changed) {
    String _temp0 = intl.Intl.pluralLogic(
      changed,
      locale: localeName,
      other: '$changed lines',
      one: '1 line',
    );
    return 'will join $_temp0';
  }

  @override
  String editorStatusPosition(int line, int column, int lines, int bytes) {
    String _temp0 = intl.Intl.pluralLogic(
      lines,
      locale: localeName,
      other: '$lines lines',
      one: '1 line',
    );
    String _temp1 = intl.Intl.pluralLogic(
      bytes,
      locale: localeName,
      other: '$bytes bytes',
      one: '1 byte',
    );
    return 'Ln $line, Col $column · $_temp0 · $_temp1';
  }

  @override
  String editorStatusSelection(int characters) {
    return '$characters selected';
  }

  @override
  String editorStatusSelectionLines(int characters, int lines) {
    return '$characters selected on $lines lines';
  }

  @override
  String get editorStatusSaving => 'Saving…';

  @override
  String get editorStatusLargeFile => 'Large file: no highlighting';

  @override
  String editorStatusProblemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count problems',
      one: '1 problem',
    );
    return '$_temp0';
  }

  @override
  String get editorStatusNextProblemHint => 'Go to the next problem (F8)';

  @override
  String editorProblemSyntaxError(String detail) {
    return 'Syntax error: $detail';
  }

  @override
  String editorProblemDuplicateKey(String key, int line) {
    return 'Duplicate key \"$key\", first set on line $line';
  }

  @override
  String editorProblemDuplicateTable(String table, int line) {
    return 'Duplicate table [$table], first declared on line $line';
  }

  @override
  String editorProblemDuplicateAttribute(String attribute) {
    return 'Duplicate attribute \"$attribute\"';
  }

  @override
  String get editorProblemJsonComment => 'Comments are not allowed in JSON';

  @override
  String get editorProblemJsonTrailingComma =>
      'Trailing commas are not allowed in JSON';

  @override
  String get editorProblemUnterminatedQuote =>
      'This quoted value is never closed';

  @override
  String get editorProblemTabIndentation =>
      'YAML does not allow tabs for indentation';

  @override
  String editorProblemMismatchedClosingTag(String tag, String open, int line) {
    return '</$tag> does not match <$open> on line $line';
  }

  @override
  String editorProblemUnclosedElement(String tag) {
    return '<$tag> is never closed';
  }

  @override
  String editorProblemUnexpectedClosingTag(String tag) {
    return '</$tag> closes no open element';
  }

  @override
  String get editorProblemMergeConflict => 'Unresolved merge conflict';

  @override
  String editorStatusIndentSpaces(int width) {
    return 'Spaces: $width';
  }

  @override
  String editorStatusIndentTabs(int width) {
    return 'Tab Size: $width';
  }

  @override
  String get editorLanguagePlainText => 'Plain Text';

  @override
  String get editorLanguageCStyle => 'C-style';

  @override
  String get editorUndoLabel => 'Undo';

  @override
  String editorGrepCheatSheetDart(
    String quantifier,
    String bracedRef,
    String namedRef,
  ) {
    return '. any character (except line breaks; (?s) includes them)\n\\d digits  \\w words  \\s whitespace  \\b word edge\n^ start of line  \$ end of line  (?i) ignore case\n(a|b) either  (?:...) group  (?<n>...) named group\na* none+  a+ one+  a? maybe  a$quantifier range (greedy)\n\$1 \$$bracedRef \$$namedRef \$0 in replacements  \$\$ a dollar\nBackslashes stay literal in replacements: \\n is two characters.';
  }

  @override
  String editorGrepCheatSheetBBEdit(String hexRef) {
    return '(?P<n>...) becomes (?<n>...)\n(?>...) becomes (?:...)\na*+ becomes a* (no possessive quantifiers)\n[[:alpha:]] becomes \\w or explicit ranges\n\\A \\z \\Z become ^ \$\n\\x$hexRef becomes \\u$hexRef\n(?x) verbose mode is unsupported\n\\r alone matches CR only; use \\r?\\n for breaks';
  }

  @override
  String editorTextToolNoticeRefused(String name, String reason) {
    return '$name: not applied, $reason.';
  }

  @override
  String editorTextToolNoticeSentence(String name, String sentence) {
    return '$name: $sentence';
  }

  @override
  String editorTextToolPreviewRefused(String reason) {
    return 'not applied, $reason';
  }

  @override
  String windowTitleDocument(String name) {
    return '$name — Planchette';
  }

  @override
  String windowTitleDocumentInFolder(String name, String folder) {
    return '$name | $folder | Planchette';
  }

  @override
  String windowTitleFolder(String folder) {
    return '$folder | Planchette';
  }

  @override
  String windowTitleUnsaved(String title) {
    return '● $title';
  }

  @override
  String get untitledName => 'Untitled';

  @override
  String untitledNameNumbered(int number) {
    return 'Untitled $number';
  }

  @override
  String get listSeparator => ', ';

  @override
  String get sentenceListSeparator => '; ';

  @override
  String failureItem(String name, String detail) {
    return '$name ($detail)';
  }

  @override
  String openDocumentsFailed(Object error) {
    return 'Could not open documents: $error';
  }

  @override
  String openFailed(String name, String detail) {
    return 'Could not open $name: $detail';
  }

  @override
  String openFailedSeveral(int count, String files) {
    return 'Could not open $count files: $files';
  }

  @override
  String openFailedSeveralMore(int count, String files, int more) {
    return 'Could not open $count files: $files, and $more more';
  }

  @override
  String get saveReasonReverting => 'it is being reverted';

  @override
  String get saveReasonOpening => 'still opening';

  @override
  String get saveReasonComposing => 'the input method is still composing';

  @override
  String get saveReasonChangedOnDisk => 'it changed on disk';

  @override
  String get saveReasonMissing => 'it was deleted or moved';

  @override
  String get localCopySameLocation =>
      'Choose another location for the local copy.';

  @override
  String saveComposing(String name) {
    return '$name was not saved. Finish typing in the input method, then save again.';
  }

  @override
  String get localCopyNotUploaded =>
      'The local copy was saved, but it was not uploaded.';

  @override
  String saveFailed(String name, Object error) {
    return 'Could not save $name: $error';
  }

  @override
  String alreadyOpenInTab(String name) {
    return '$name is already open in another tab.';
  }

  @override
  String alreadyOpenInWindow(String name) {
    return '$name is already open in another window.';
  }

  @override
  String saveAllFailed(int saved, int total, String failures) {
    return 'Saved $saved of $total. Could not save: $failures.';
  }

  @override
  String saveAllStopped(int count, String names) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Save All stopped with $count documents not saved: $names.',
      one: 'Save All stopped with $count document not saved: $names.',
    );
    return '$_temp0';
  }

  @override
  String exportReverting(String name) {
    return '$name is being reverted. Export it once the file is read.';
  }

  @override
  String exportOpenInTab(String name) {
    return '$name is open in a tab. Export to another file.';
  }

  @override
  String exportOpenInWindow(String name) {
    return '$name is open in another window. Export to another file.';
  }

  @override
  String exportTooLarge(String name, String size, String limit) {
    return '$name is too large to export as HTML: the page would be $size MB, over the $limit MB limit.';
  }

  @override
  String exportFailed(String name, Object error) {
    return 'Could not export $name: $error';
  }

  @override
  String compareReverting(String name) {
    return '$name is being reverted. Compare it again once the file is read.';
  }

  @override
  String compareBusy(String name) {
    return '$name is busy. Compare it again once it finishes.';
  }

  @override
  String compareSavedElsewhere(String name) {
    return '$name was saved somewhere else while it was being compared. Compare it again.';
  }

  @override
  String compareChanged(String name) {
    return '$name changed while it was being compared. Compare it again.';
  }

  @override
  String compareDialogOpen(String name) {
    return 'A dialog is open, so the comparison of $name could not be shown. Compare it again after closing it.';
  }

  @override
  String compareOnDisk(String name) {
    return '$name (on disk)';
  }

  @override
  String compareInEditor(String name) {
    return '$name (in the editor)';
  }

  @override
  String compareIdentical(String name) {
    return '$name has no differences from the file on disk.';
  }

  @override
  String compareTooLarge(String name) {
    return 'The differences between $name and the file on disk are too large to show as a diff.';
  }

  @override
  String compareTimedOut(String name) {
    return 'Comparing $name with the file on disk ran out of time. Compare it again.';
  }

  @override
  String compareFailed(String name, Object error) {
    return 'Could not compare $name with the file on disk: $error';
  }

  @override
  String compareTabName(String name) {
    return '$name vs saved';
  }

  @override
  String siblingDeleteFailure(String name, Object error) {
    return '$name: $error';
  }

  @override
  String siblingsDeleteFailed(String failures) {
    return 'Could not delete $failures.';
  }

  @override
  String recoveryDeleteFailed(String name, Object error) {
    return 'Could not delete the recovery copy $name: $error';
  }

  @override
  String discardFailed(String name, Object error) {
    return 'Could not discard $name: $error';
  }

  @override
  String discardChangedClose(String name) {
    return '$name changed while the prompt was open, so nothing was discarded. Review it, then close again.';
  }

  @override
  String discardChangedQuit(String name) {
    return '$name changed while the prompt was open, so nothing was discarded. Review it, then quit again.';
  }

  @override
  String closeSaving(String name) {
    return '$name is still being saved. Close it again once the save finishes.';
  }

  @override
  String closeBusy(String name) {
    return '$name is busy. Close it again in a moment.';
  }

  @override
  String notReady(String name) {
    return '$name is still opening. Try again in a moment.';
  }

  @override
  String revertFailed(String name, Object error) {
    return 'Could not revert $name: $error';
  }

  @override
  String reloadFailed(String name, Object error) {
    return 'Could not reload $name: $error';
  }

  @override
  String diskCheckFailed(String name, Object error) {
    return 'Could not check $name for changes on disk: $error';
  }

  @override
  String diskReadFailed(String name, Object error) {
    return 'Could not read the new version of $name: $error';
  }

  @override
  String restoreProblems(String problems) {
    return 'Some documents from the last session need attention: $problems.';
  }

  @override
  String restoreChangedOnDisk(String name) {
    return '$name changed on disk after its unsaved edits were kept. They are back over the new version: compare before saving';
  }

  @override
  String get restoreOpenElsewhere => 'it is open in another window';

  @override
  String restoreFailed(String name, String reason) {
    return '$name could not be reopened ($reason)';
  }

  @override
  String restoreFailedKept(String name, String reason) {
    return '$name could not be reopened ($reason); its unsaved text is in an untitled tab';
  }

  @override
  String get quitBlockedBusy =>
      'A document is still opening or closing, or a dialog is waiting. Quit again once it finishes.';

  @override
  String get quitBlockedSaving =>
      'A save is still running. Quit again once it finishes.';

  @override
  String get folderOutsideWorkspace => 'Choose a folder inside this workspace.';

  @override
  String windowOpenFailed(Object error) {
    return 'Could not open a window: $error';
  }

  @override
  String windowRaiseFailed(Object error) {
    return 'Could not bring a window forward to close it: $error';
  }

  @override
  String appCloseFailed(Object error) {
    return 'Could not close Planchette: $error';
  }

  @override
  String windowCloseFailed(Object error) {
    return 'Could not close the window: $error';
  }

  @override
  String journalWriteFailed(Object error) {
    return 'Unsaved changes could not be kept for the next launch: $error';
  }

  @override
  String remoteFileFailed(Object error) {
    return 'Remote file: $error';
  }

  @override
  String get settingsUnreadable =>
      'Your settings file could not be read, so Planchette started with its default settings.';

  @override
  String settingsUnreadableKept(String path) {
    return 'Your settings file could not be read, so Planchette started with its default settings. The file was kept as $path.';
  }

  @override
  String settingsSaveFailed(String detail) {
    return 'Could not save settings: $detail';
  }
}
