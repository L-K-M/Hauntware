import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

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

  /// Returns from the sign-in form to the server list.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get actionBack;

  /// Closes a dialog without acting.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// Closes the workspace servers dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get actionClose;

  /// Opens the chosen remote folder.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get actionOpen;

  /// Shows or submits the catalog sign-in form.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get actionSignIn;

  /// Title of the dialog that lists the synced server catalog.
  ///
  /// In en, this message translates to:
  /// **'Workspace servers'**
  String get serversTitle;

  /// Tooltip of the button that downloads catalog changes.
  ///
  /// In en, this message translates to:
  /// **'Refresh catalog'**
  String get serversRefresh;

  /// Heading of the catalog sign-in form.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your existing suite catalog.'**
  String get serversSignInPrompt;

  /// Label of the sync server address field.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serversUrl;

  /// Label of the catalog account name field.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get serversUsername;

  /// Label of the catalog account password field.
  ///
  /// In en, this message translates to:
  /// **'Account password'**
  String get serversPassword;

  /// Label of the catalog encryption passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Encryption passphrase'**
  String get serversPassphrase;

  /// Switch that also downloads stored server credentials.
  ///
  /// In en, this message translates to:
  /// **'Sync saved passwords and keys'**
  String get serversSyncCredentials;

  /// Explains the credential sync switch.
  ///
  /// In en, this message translates to:
  /// **'Optional. Credentials stay encrypted on this device.'**
  String get serversSyncCredentialsDetail;

  /// Says the editor never uploads catalog changes.
  ///
  /// In en, this message translates to:
  /// **'Planchette only downloads catalog changes.'**
  String get serversDownloadOnly;

  /// The signed-in catalog account above the server list.
  ///
  /// In en, this message translates to:
  /// **'{username} · {baseUrl}'**
  String serversAccount(String username, String baseUrl);

  /// Label of the server list filter field.
  ///
  /// In en, this message translates to:
  /// **'Search servers'**
  String get serversSearch;

  /// Shown when the downloaded catalog has no servers.
  ///
  /// In en, this message translates to:
  /// **'No servers in the cached catalog. Refresh to download changes.'**
  String get serversEmptyCatalog;

  /// Shown when the filter matches no server.
  ///
  /// In en, this message translates to:
  /// **'No matching servers.'**
  String get serversNoMatch;

  /// Explains a synced host key that differs from this device's pin.
  ///
  /// In en, this message translates to:
  /// **'Another device synced a different host key for {locator}. Planchette kept this device\'s key and is not using the other one. If the server\'s key really changed, trust the new one; otherwise keep yours.'**
  String hostKeyConflict(String locator);

  /// Heads this device's pinned host key fingerprint.
  ///
  /// In en, this message translates to:
  /// **'This device trusts'**
  String get hostKeyLocal;

  /// Heads the synced host key fingerprint.
  ///
  /// In en, this message translates to:
  /// **'The other device synced'**
  String get hostKeyPulled;

  /// Keeps the pinned host key and drops the synced one.
  ///
  /// In en, this message translates to:
  /// **'Keep this device\'s key'**
  String get hostKeyKeepLocal;

  /// Replaces the pinned host key with the synced one.
  ///
  /// In en, this message translates to:
  /// **'Trust the new key'**
  String get hostKeyTrustNew;

  /// Title of the dialog that opens a server folder as a workspace.
  ///
  /// In en, this message translates to:
  /// **'Open Folder on {server}'**
  String remoteFolderTitle(String server);

  /// Label of the server folder path field.
  ///
  /// In en, this message translates to:
  /// **'Remote folder'**
  String get remoteFolderLabel;

  /// Explains the accepted server folder paths.
  ///
  /// In en, this message translates to:
  /// **'Absolute path or relative to your login home.'**
  String get remoteFolderHelper;

  /// Shown when the server folder path has no accepted form.
  ///
  /// In en, this message translates to:
  /// **'Enter a folder using /path, ~ or ~/path.'**
  String get remoteFolderInvalid;

  /// Explains how a server credential typed for a workspace is kept.
  ///
  /// In en, this message translates to:
  /// **'Used for this workspace session and never saved.'**
  String get credentialExplanation;

  /// Shown when a key passphrase was wrong.
  ///
  /// In en, this message translates to:
  /// **'That passphrase did not open the key. Try again. It is used for this workspace session and never saved.'**
  String get credentialRetry;

  /// Submits a server credential.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get credentialConnect;

  /// Notice above an unedited document whose file another program changed.
  ///
  /// In en, this message translates to:
  /// **'{name} changed on disk. Reload it to see the new version.'**
  String diskChanged(String name);

  /// Notice above an edited document whose file another program changed.
  ///
  /// In en, this message translates to:
  /// **'{name} changed on disk. Reload it, or keep your edits and replace it when you save.'**
  String diskChangedWithEdits(String name);

  /// Keeps the edits in the editor and replaces the changed file on the next save.
  ///
  /// In en, this message translates to:
  /// **'Keep Mine'**
  String get diskKeepMine;

  /// Reads the changed file into the editor, dropping the editor copy.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get diskReload;

  /// Notice above a document whose file is gone.
  ///
  /// In en, this message translates to:
  /// **'{name} was deleted or moved. Save to create it again.'**
  String diskMissing(String name);

  /// Saves the document, or confirms a save location.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// Tooltip of the status bar line ending menu.
  ///
  /// In en, this message translates to:
  /// **'Line endings apply on next save'**
  String get statusLineEndingTooltip;

  /// Tooltip of the status bar encoding menu.
  ///
  /// In en, this message translates to:
  /// **'Encoding applies on next save, a UTF-8 BOM adds 3 bytes'**
  String get statusEncodingTooltip;

  /// Tooltip of the status bar indentation menu.
  ///
  /// In en, this message translates to:
  /// **'Indentation'**
  String get statusIndentationTooltip;

  /// Indents with spaces.
  ///
  /// In en, this message translates to:
  /// **'Spaces'**
  String get indentSpaces;

  /// Indents with tabs.
  ///
  /// In en, this message translates to:
  /// **'Tabs'**
  String get indentTabs;

  /// Sets the indentation width in columns.
  ///
  /// In en, this message translates to:
  /// **'Width {width}'**
  String statusIndentWidth(int width);

  /// Rewrites the document indentation as spaces.
  ///
  /// In en, this message translates to:
  /// **'Convert to Spaces'**
  String get statusConvertToSpaces;

  /// Rewrites the document indentation as tabs.
  ///
  /// In en, this message translates to:
  /// **'Convert to Tabs'**
  String get statusConvertToTabs;

  /// Tooltip of the button that hides the folder sidebar.
  ///
  /// In en, this message translates to:
  /// **'Hide sidebar'**
  String get sidebarHide;

  /// Tooltip of the button that shows the folder sidebar.
  ///
  /// In en, this message translates to:
  /// **'Show sidebar'**
  String get sidebarShow;

  /// A tooltip naming an action and its keyboard shortcut, such as Ctrl+B.
  ///
  /// In en, this message translates to:
  /// **'{action} {shortcut}'**
  String tooltipWithShortcut(String action, String shortcut);

  /// Tooltip of the button that closes the open folder.
  ///
  /// In en, this message translates to:
  /// **'Close folder workspace'**
  String get folderClose;

  /// Tooltip of the button that returns to the open folder itself.
  ///
  /// In en, this message translates to:
  /// **'Workspace root'**
  String get folderRoot;

  /// Tooltip of the button that goes up one folder.
  ///
  /// In en, this message translates to:
  /// **'Parent folder'**
  String get folderParent;

  /// Tooltip of the button that lists the folder again.
  ///
  /// In en, this message translates to:
  /// **'Refresh folder'**
  String get folderRefresh;

  /// Tooltip of the toggle while hidden files are shown.
  ///
  /// In en, this message translates to:
  /// **'Hide hidden files'**
  String get folderHideHidden;

  /// Tooltip of the toggle while hidden files are hidden.
  ///
  /// In en, this message translates to:
  /// **'Show hidden files'**
  String get folderShowHidden;

  /// Shown in the file browser for an empty folder.
  ///
  /// In en, this message translates to:
  /// **'This folder is empty'**
  String get folderEmpty;

  /// Screen reader label of the handle that resizes the file browser.
  ///
  /// In en, this message translates to:
  /// **'File browser width'**
  String get folderBrowserWidth;

  /// Screen reader value of the file browser resize handle.
  ///
  /// In en, this message translates to:
  /// **'{pixels} pixels'**
  String folderBrowserWidthValue(int pixels);

  /// Tooltip and screen reader action of a tab close button.
  ///
  /// In en, this message translates to:
  /// **'Close {name}'**
  String tabClose(String name);

  /// Screen reader label of a tab whose document has unsaved edits.
  ///
  /// In en, this message translates to:
  /// **'{name}, unsaved changes'**
  String tabUnsaved(String name);

  /// Title of the settings dialog.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Settings section heading for the theme.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// Follows the system light or dark theme.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get settingsThemeSystem;

  /// Always uses the light theme.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get settingsThemeLight;

  /// Always uses the dark theme.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get settingsThemeDark;

  /// Settings section heading for the editor text.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get settingsText;

  /// Label of the editor text size slider.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get settingsTextSize;

  /// Switch that turns font ligatures on.
  ///
  /// In en, this message translates to:
  /// **'Ligatures'**
  String get settingsLigatures;

  /// Explains the ligatures switch.
  ///
  /// In en, this message translates to:
  /// **'Join character pairs such as -> and != into one symbol, in fonts that draw them.'**
  String get settingsLigaturesDetail;

  /// Settings section heading for default indentation.
  ///
  /// In en, this message translates to:
  /// **'Indentation for new documents'**
  String get settingsIndentation;

  /// Label of the spaces or tabs choice.
  ///
  /// In en, this message translates to:
  /// **'Indent with'**
  String get settingsIndentWith;

  /// Label of the indentation width slider.
  ///
  /// In en, this message translates to:
  /// **'Width'**
  String get settingsIndentWidth;

  /// Explains when the default indentation applies.
  ///
  /// In en, this message translates to:
  /// **'A file that already indents, or a format that requires tabs, keeps its own.'**
  String get settingsIndentationDetail;

  /// Settings section heading for save options.
  ///
  /// In en, this message translates to:
  /// **'Saving'**
  String get settingsSaving;

  /// Switch that removes spaces at line ends when saving.
  ///
  /// In en, this message translates to:
  /// **'Trim trailing whitespace on save'**
  String get settingsTrimWhitespace;

  /// Switch that ends a saved file with a line break.
  ///
  /// In en, this message translates to:
  /// **'Ensure final newline on save'**
  String get settingsFinalNewline;

  /// Switch for hot exit: quitting keeps unsaved documents and windows for the next launch instead of asking to save them.
  ///
  /// In en, this message translates to:
  /// **'Keep unsaved changes when quitting'**
  String get settingsKeepUnsaved;

  /// Explains the keep-unsaved-changes switch, where the changes are kept and what turning it off does.
  ///
  /// In en, this message translates to:
  /// **'Quit without being asked; the open windows and unsaved changes come back at the next launch. They are kept in a private folder on this device until saved or discarded. Turn off to be asked to save instead.'**
  String get settingsKeepUnsavedDetail;

  /// Settings section heading for the version and licenses.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// Shown when the running version cannot be read.
  ///
  /// In en, this message translates to:
  /// **'Version unknown'**
  String get settingsVersionUnknown;

  /// The running app version.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String settingsVersion(String version);

  /// Opens the third-party license list.
  ///
  /// In en, this message translates to:
  /// **'Open-source licenses'**
  String get settingsLicenses;

  /// Summarizes the app license. Keep it consistent with the README license statement.
  ///
  /// In en, this message translates to:
  /// **'Public domain (Unlicense). The libraries, fonts and engine it includes keep their own licenses.'**
  String get settingsLicensesDetail;

  /// Legal line at the top of the license list. Keep it consistent with the README license statement.
  ///
  /// In en, this message translates to:
  /// **'Planchette\'s own code is public domain (Unlicense). It includes third-party components that keep their own licenses, listed here.'**
  String get settingsLicensesLegalese;

  /// Closes the settings dialog, keeping the changes.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// Label of the editor font picker.
  ///
  /// In en, this message translates to:
  /// **'Font'**
  String get settingsFont;

  /// The default editor font in the font picker button.
  ///
  /// In en, this message translates to:
  /// **'{font} (default)'**
  String settingsFontDefault(String font);

  /// Screen reader value of a settings slider, such as Size 14.
  ///
  /// In en, this message translates to:
  /// **'{label} {value}'**
  String settingsSliderValue(String label, int value);

  /// Confirm button of the folder picker.
  ///
  /// In en, this message translates to:
  /// **'Open Folder'**
  String get pickerOpenFolder;

  /// Shown when more than one key file was picked.
  ///
  /// In en, this message translates to:
  /// **'Choose one private-key file.'**
  String get pickerOneKeyFile;

  /// Asks before a save replaces an existing file.
  ///
  /// In en, this message translates to:
  /// **'Replace “{name}”?'**
  String replaceTitle(String name);

  /// Explains the replace question.
  ///
  /// In en, this message translates to:
  /// **'The existing file will be replaced with this document.'**
  String get replaceBody;

  /// Replaces the existing file.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replaceAction;

  /// Asks before closing several unsaved documents.
  ///
  /// In en, this message translates to:
  /// **'Save changes to {count} documents?'**
  String bulkCloseTitle(int count);

  /// Lists the unsaved documents, one per line, before the warning.
  ///
  /// In en, this message translates to:
  /// **'{names}\n\nYour changes will be lost if you close without saving them.'**
  String bulkCloseBody(String names);

  /// Saves every listed document, then closes.
  ///
  /// In en, this message translates to:
  /// **'Save All'**
  String get bulkCloseSaveAll;

  /// Asks before closing an unsaved document.
  ///
  /// In en, this message translates to:
  /// **'Save changes to “{name}”?'**
  String closeTitle(String name);

  /// Explains the close question.
  ///
  /// In en, this message translates to:
  /// **'Your changes will be lost if you close this document without saving.'**
  String get closeBody;

  /// Title shown before saving over a read-only file.
  ///
  /// In en, this message translates to:
  /// **'“{name}” is read-only'**
  String readOnlyTitle(String name);

  /// Explains the read-only save question.
  ///
  /// In en, this message translates to:
  /// **'Saving replaces the file anyway and keeps it read-only. You can save your changes as a new file instead.'**
  String get readOnlyBody;

  /// Replaces the read-only file.
  ///
  /// In en, this message translates to:
  /// **'Save Anyway'**
  String get readOnlySaveAnyway;

  /// Saves the document under a new name.
  ///
  /// In en, this message translates to:
  /// **'Save As…'**
  String get actionSaveAs;

  /// Asks before discarding unsaved edits.
  ///
  /// In en, this message translates to:
  /// **'Revert “{name}” to its saved version?'**
  String revertTitle(String name);

  /// Explains the revert question.
  ///
  /// In en, this message translates to:
  /// **'Your unsaved changes will be lost.'**
  String get revertBody;

  /// Discards the edits and reads the saved file.
  ///
  /// In en, this message translates to:
  /// **'Revert'**
  String get revertAction;

  /// Asks before deleting a recovery copy of a document that could not be saved.
  ///
  /// In en, this message translates to:
  /// **'Delete the recovery copy “{name}”?'**
  String recoveryDeleteTitle(String name);

  /// Explains the recovery copy question.
  ///
  /// In en, this message translates to:
  /// **'It holds the earlier contents of a document Planchette could not save. If you keep it, it opens again the next time you start Planchette.'**
  String get recoveryDeleteBody;

  /// Keeps the file and closes the question.
  ///
  /// In en, this message translates to:
  /// **'Keep'**
  String get actionKeep;

  /// Deletes the named file or files.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// Offered when the document folder refuses a save.
  ///
  /// In en, this message translates to:
  /// **'Save “{name}” somewhere else?'**
  String saveElsewhereTitle(String name);

  /// Explains why a save into the folder failed.
  ///
  /// In en, this message translates to:
  /// **'The folder {folder} does not let Planchette create the temporary file a safe save needs, so the file cannot be saved there. You can save a copy in another folder instead.'**
  String saveElsewhereBody(String folder);

  /// Offered when files from an interrupted save sit beside an opened document.
  ///
  /// In en, this message translates to:
  /// **'Files left by an interrupted save of “{name}”'**
  String siblingsTitle(String name);

  /// Explains the leftover files, followed by their names, one per line.
  ///
  /// In en, this message translates to:
  /// **'An earlier save of this document stopped before it finished and left {count, plural, =1{this file} other{these files}} beside it. Each holds a version of its text: the one before that save or the one it was writing. Open them to compare, or delete them if you do not need them.\n\n{files}'**
  String siblingsBody(int count, String files);

  /// A shortened list of file names, one per line, and how many were left out.
  ///
  /// In en, this message translates to:
  /// **'{names}\nand {count} more'**
  String listedMore(String names, int count);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
