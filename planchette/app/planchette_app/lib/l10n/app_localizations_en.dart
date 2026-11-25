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
