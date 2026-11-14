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
}
