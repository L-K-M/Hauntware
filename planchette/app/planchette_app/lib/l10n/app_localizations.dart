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

  /// The File menu.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get menuFile;

  /// The Edit menu.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get menuEdit;

  /// The Text menu of text tools.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get menuText;

  /// The Find menu.
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get menuFind;

  /// The View menu.
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get menuView;

  /// The Window menu.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get menuWindow;

  /// File menu: opens a new untitled tab.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get menuNew;

  /// File menu: opens a new window.
  ///
  /// In en, this message translates to:
  /// **'New Window'**
  String get menuNewWindow;

  /// File menu: picks files to open.
  ///
  /// In en, this message translates to:
  /// **'Open…'**
  String get menuOpen;

  /// File menu: the submenu of recently opened files.
  ///
  /// In en, this message translates to:
  /// **'Open Recent'**
  String get menuOpenRecent;

  /// The disabled row of an empty Open Recent submenu.
  ///
  /// In en, this message translates to:
  /// **'No Recent Documents'**
  String get menuNoRecentDocuments;

  /// An Open Recent row whose file name another row shares, with its folder.
  ///
  /// In en, this message translates to:
  /// **'{name} ({folder})'**
  String menuRecentDocumentInFolder(String name, String folder);

  /// Open Recent: forgets the remembered files.
  ///
  /// In en, this message translates to:
  /// **'Clear Menu'**
  String get menuClearRecentDocuments;

  /// File menu: opens a local folder as the workspace.
  ///
  /// In en, this message translates to:
  /// **'Open Folder…'**
  String get menuOpenFolder;

  /// File menu: opens a server folder as the workspace.
  ///
  /// In en, this message translates to:
  /// **'Open Server…'**
  String get menuOpenServer;

  /// File menu: lists server files saved locally but not uploaded.
  ///
  /// In en, this message translates to:
  /// **'Recover Remote Edits…'**
  String get menuRecoverRemoteEdits;

  /// File menu: opens the active file's folder as the workspace.
  ///
  /// In en, this message translates to:
  /// **'Open Containing Folder'**
  String get menuOpenContainingFolder;

  /// File menu: closes the folder workspace.
  ///
  /// In en, this message translates to:
  /// **'Close Folder Workspace'**
  String get menuCloseFolderWorkspace;

  /// File menu: saves the active document.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get menuSave;

  /// File menu: saves the active document under a new name.
  ///
  /// In en, this message translates to:
  /// **'Save As…'**
  String get menuSaveAs;

  /// File menu: Save As for a server file, which saves a local copy.
  ///
  /// In en, this message translates to:
  /// **'Save a Local Copy…'**
  String get menuSaveLocalCopy;

  /// File menu: saves every document with changes.
  ///
  /// In en, this message translates to:
  /// **'Save All'**
  String get menuSaveAll;

  /// File menu: discards edits and rereads the file.
  ///
  /// In en, this message translates to:
  /// **'Revert to Saved'**
  String get menuRevertToSaved;

  /// File menu: exports the document as highlighted HTML.
  ///
  /// In en, this message translates to:
  /// **'Export as HTML…'**
  String get menuExportHtml;

  /// File menu: copies the active file's path.
  ///
  /// In en, this message translates to:
  /// **'Copy Path'**
  String get menuCopyPath;

  /// Opens Settings, in the File menu or the macOS application menu.
  ///
  /// In en, this message translates to:
  /// **'Settings…'**
  String get menuSettings;

  /// File menu: closes the active tab.
  ///
  /// In en, this message translates to:
  /// **'Close Tab'**
  String get menuCloseTab;

  /// File menu: closes this window.
  ///
  /// In en, this message translates to:
  /// **'Close Window'**
  String get menuCloseWindow;

  /// File menu: reopens the last closed tab.
  ///
  /// In en, this message translates to:
  /// **'Reopen Closed Tab'**
  String get menuReopenClosedTab;

  /// File menu: quits the app, off macOS.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get menuQuit;

  /// macOS application menu: quits the app.
  ///
  /// In en, this message translates to:
  /// **'Quit Planchette'**
  String get menuQuitApp;

  /// Edit menu: undoes the last edit.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get menuUndo;

  /// Edit menu: redoes the last undone edit.
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get menuRedo;

  /// Edit menu: cuts the selection.
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get menuCut;

  /// Edit menu: copies the selection.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get menuCopy;

  /// Edit menu: pastes the clipboard.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get menuPaste;

  /// Edit menu: selects the whole document.
  ///
  /// In en, this message translates to:
  /// **'Select All'**
  String get menuSelectAll;

  /// Text menu: the submenu of recent text-tool runs.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get menuRecentRuns;

  /// The disabled row of an empty recent text-tool runs submenu.
  ///
  /// In en, this message translates to:
  /// **'No Recent Runs'**
  String get menuNoRecentRuns;

  /// Find menu: opens the find bar.
  ///
  /// In en, this message translates to:
  /// **'Find…'**
  String get menuFindEllipsis;

  /// Find menu: opens find and replace.
  ///
  /// In en, this message translates to:
  /// **'Replace…'**
  String get menuReplace;

  /// Find menu: selects the next match.
  ///
  /// In en, this message translates to:
  /// **'Find Next'**
  String get menuFindNext;

  /// Find menu: selects the previous match.
  ///
  /// In en, this message translates to:
  /// **'Find Previous'**
  String get menuFindPrevious;

  /// Find menu: opens the Go to Line bar.
  ///
  /// In en, this message translates to:
  /// **'Go to Line…'**
  String get menuGoToLine;

  /// Find menu: shows the edits against the saved file as a diff.
  ///
  /// In en, this message translates to:
  /// **'Compare with Saved'**
  String get menuCompareWithSaved;

  /// View menu: hides the workspace sidebar.
  ///
  /// In en, this message translates to:
  /// **'Hide Sidebar'**
  String get menuHideSidebar;

  /// View menu: shows the workspace sidebar.
  ///
  /// In en, this message translates to:
  /// **'Show Sidebar'**
  String get menuShowSidebar;

  /// View menu: makes the text larger.
  ///
  /// In en, this message translates to:
  /// **'Zoom In'**
  String get menuZoomIn;

  /// View menu: makes the text smaller.
  ///
  /// In en, this message translates to:
  /// **'Zoom Out'**
  String get menuZoomOut;

  /// View menu: restores the chosen text size.
  ///
  /// In en, this message translates to:
  /// **'Actual Size'**
  String get menuActualSize;

  /// Window menu: opens the command palette.
  ///
  /// In en, this message translates to:
  /// **'Command Palette…'**
  String get menuCommandPalette;

  /// Window menu: selects the next tab.
  ///
  /// In en, this message translates to:
  /// **'Next Tab'**
  String get menuNextTab;

  /// Window menu: selects the previous tab.
  ///
  /// In en, this message translates to:
  /// **'Previous Tab'**
  String get menuPreviousTab;

  /// Window menu: the front window's row, check-marked.
  ///
  /// In en, this message translates to:
  /// **'✓ {title}'**
  String menuActiveWindow(String title);

  /// Tab context menu: closes the tab.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get tabMenuClose;

  /// Tab context menu: closes every other tab.
  ///
  /// In en, this message translates to:
  /// **'Close Others'**
  String get tabMenuCloseOthers;

  /// Tab context menu: closes every tab.
  ///
  /// In en, this message translates to:
  /// **'Close All Tabs'**
  String get tabMenuCloseAll;

  /// Tab context menu: copies the file's path.
  ///
  /// In en, this message translates to:
  /// **'Copy Full Path'**
  String get tabMenuCopyFullPath;

  /// Tooltip of the tab strip's new-tab button, with its shortcut.
  ///
  /// In en, this message translates to:
  /// **'New ({shortcut})'**
  String tabStripNewTooltip(String shortcut);

  /// Tooltip of the tab strip's open button, with its shortcut.
  ///
  /// In en, this message translates to:
  /// **'Open… ({shortcut})'**
  String tabStripOpenTooltip(String shortcut);

  /// Tooltip of the tab strip's save button, with its shortcut.
  ///
  /// In en, this message translates to:
  /// **'Save ({shortcut})'**
  String tabStripSaveTooltip(String shortcut);

  /// Tooltip of the Android app bar button that opens the command palette.
  ///
  /// In en, this message translates to:
  /// **'Commands'**
  String get commandsTooltip;

  /// Error for an Open Recent file that is gone.
  ///
  /// In en, this message translates to:
  /// **'{name} is no longer at {path}, so it was removed from Open Recent.'**
  String recentDocumentMissing(String name, String path);

  /// Error for an Open Recent file whose folder cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'Could not open {name}: the folder {folder} is not available. If it is on a disk or share that is not connected, connect it and try again.'**
  String recentDocumentFolderUnavailable(String name, String folder);

  /// Error when a workspace folder fails to open.
  ///
  /// In en, this message translates to:
  /// **'Could not open folder: {error}'**
  String folderOpenFailed(Object error);

  /// Error when opening a workspace fails.
  ///
  /// In en, this message translates to:
  /// **'Could not open workspace: {error}'**
  String workspaceOpenFailed(Object error);

  /// Title of the dialog that lists unuploaded server edits.
  ///
  /// In en, this message translates to:
  /// **'Recover Remote Edits'**
  String get recoverRemoteEditsTitle;

  /// Shown when no server edits await upload.
  ///
  /// In en, this message translates to:
  /// **'No remote edits are awaiting upload.'**
  String get recoverRemoteEditsEmpty;

  /// Subtitle of each unuploaded server edit.
  ///
  /// In en, this message translates to:
  /// **'Saved locally. Open its server before retrying upload.'**
  String get recoverRemoteEditsItem;

  /// Heading of a window with no tabs.
  ///
  /// In en, this message translates to:
  /// **'Start with a blank page'**
  String get emptyStateTitle;

  /// Button of a window with no tabs: opens a new tab.
  ///
  /// In en, this message translates to:
  /// **'New document'**
  String get emptyStateNew;

  /// Button of a window with no tabs: picks files to open.
  ///
  /// In en, this message translates to:
  /// **'Open…'**
  String get emptyStateOpen;

  /// Heading of the recent files under a window with no tabs.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get emptyStateRecent;

  /// Server file notice: a save is uploading.
  ///
  /// In en, this message translates to:
  /// **'Saving to server…'**
  String get remoteSaving;

  /// Server file notice: the editor has unsaved changes.
  ///
  /// In en, this message translates to:
  /// **'Unsaved editor changes'**
  String get remoteUnsaved;

  /// Server file notice: saved locally, not yet uploaded.
  ///
  /// In en, this message translates to:
  /// **'Saved locally. Upload pending.'**
  String get remoteUploadPending;

  /// Server file notice: the server has the saved text.
  ///
  /// In en, this message translates to:
  /// **'Saved to server'**
  String get remoteSaved;

  /// Server file notice: the file's server path above its state.
  ///
  /// In en, this message translates to:
  /// **'{path}\n{state}'**
  String remoteNotice(String path, String state);

  /// Server file notice: uploads the local save again.
  ///
  /// In en, this message translates to:
  /// **'Retry upload'**
  String get remoteRetryUpload;

  /// Tooltip of the error banner's encoding menu.
  ///
  /// In en, this message translates to:
  /// **'Read the file in another encoding'**
  String get reopenWithEncodingTooltip;

  /// Error banner menu: rereads the file in a chosen encoding.
  ///
  /// In en, this message translates to:
  /// **'Reopen with Encoding…'**
  String get reopenWithEncoding;

  /// Tooltip of the error banner's close button.
  ///
  /// In en, this message translates to:
  /// **'Dismiss error'**
  String get dismissErrorTooltip;

  /// Placeholder of an empty untitled document.
  ///
  /// In en, this message translates to:
  /// **'Start typing. The spirits are listening…'**
  String get ghostLineSpirits;

  /// Placeholder of an empty untitled document.
  ///
  /// In en, this message translates to:
  /// **'Start typing. The board is waiting…'**
  String get ghostLineBoard;

  /// Placeholder of an empty untitled document.
  ///
  /// In en, this message translates to:
  /// **'Start typing. Something wants to be written…'**
  String get ghostLineWritten;

  /// Placeholder of an empty untitled document.
  ///
  /// In en, this message translates to:
  /// **'Start typing. Rest a finger on the planchette…'**
  String get ghostLineFinger;

  /// Placeholder of an empty untitled document.
  ///
  /// In en, this message translates to:
  /// **'Start typing. Ask, and it will answer…'**
  String get ghostLineAnswer;

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

  /// Settings section heading over the app lock switch.
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get settingsAppLockTitle;

  /// Settings: the app lock switch.
  ///
  /// In en, this message translates to:
  /// **'Require device authentication'**
  String get settingsAppLock;

  /// Settings: what the app lock switch does, and that open documents are not closed by it.
  ///
  /// In en, this message translates to:
  /// **'Ask for this device\'s passcode, PIN or biometrics when Planchette opens and after {minutes, plural, =1{1 minute} other{{minutes} minutes}} in the background. Your documents stay open behind the lock.'**
  String settingsAppLockDetail(int minutes);

  /// Settings: why the app lock switch is off and disabled on Linux.
  ///
  /// In en, this message translates to:
  /// **'This platform has no device authentication Planchette can ask for.'**
  String get settingsAppLockUnsupported;

  /// Settings: why the app lock switch cannot be turned on right now.
  ///
  /// In en, this message translates to:
  /// **'Set up a passcode, PIN or biometrics on this device to use the app lock.'**
  String get settingsAppLockUnavailable;

  /// Settings: a toast after turning the app lock on or off did not take effect, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notAuthenticated{The app lock did not change: authentication failed or was cancelled.} unavailable{The app lock did not change: this device has no authentication to ask for.} notSaved{The app lock did not change: the setting could not be saved.} other{The app lock did not change.}}'**
  String settingsAppLockNotChanged(String reason);

  /// App lock screen: its heading, shown over the whole window while the app lock is engaged.
  ///
  /// In en, this message translates to:
  /// **'Planchette is locked'**
  String get appLockTitle;

  /// App lock screen: what unlocking asks for, and that open documents are kept while locked.
  ///
  /// In en, this message translates to:
  /// **'Unlock with this device\'s passcode, PIN or biometrics. Your open documents and unsaved changes are kept.'**
  String get appLockDetail;

  /// App lock screen: the button that asks for device authentication again.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get appLockUnlock;

  /// App lock screen: the last device authentication was rejected or dismissed.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed or was cancelled. Try again.'**
  String get appLockFailed;

  /// App lock screen: device authentication is not set up or not available, so the lock cannot be opened yet.
  ///
  /// In en, this message translates to:
  /// **'This device has no passcode, PIN or biometrics to ask for. Set one up, then try again.'**
  String get appLockUnavailable;

  /// The reason line the operating system's authentication prompt shows when the app lock asks for it.
  ///
  /// In en, this message translates to:
  /// **'Unlock Planchette'**
  String get appLockReason;

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

  /// Window title: the active document.
  ///
  /// In en, this message translates to:
  /// **'{name} — Planchette'**
  String windowTitleDocument(String name);

  /// Window title: the active document in a folder workspace.
  ///
  /// In en, this message translates to:
  /// **'{name} | {folder} | Planchette'**
  String windowTitleDocumentInFolder(String name, String folder);

  /// Window title: a folder workspace with no document open.
  ///
  /// In en, this message translates to:
  /// **'{folder} | Planchette'**
  String windowTitleFolder(String folder);

  /// Window title of a document with unsaved changes.
  ///
  /// In en, this message translates to:
  /// **'● {title}'**
  String windowTitleUnsaved(String title);

  /// The name of the first new untitled document.
  ///
  /// In en, this message translates to:
  /// **'Untitled'**
  String get untitledName;

  /// The name of a further untitled document.
  ///
  /// In en, this message translates to:
  /// **'Untitled {number}'**
  String untitledNameNumbered(int number);

  /// Joins the items of a list inside a sentence.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get listSeparator;

  /// Joins list items that may contain commas themselves.
  ///
  /// In en, this message translates to:
  /// **'; '**
  String get sentenceListSeparator;

  /// One failed document in a list, with why it failed.
  ///
  /// In en, this message translates to:
  /// **'{name} ({detail})'**
  String failureItem(String name, String detail);

  /// Error when the open dialog fails.
  ///
  /// In en, this message translates to:
  /// **'Could not open documents: {error}'**
  String openDocumentsFailed(Object error);

  /// Error when one file fails to open.
  ///
  /// In en, this message translates to:
  /// **'Could not open {name}: {detail}'**
  String openFailed(String name, String detail);

  /// Error when several files fail to open, listing each.
  ///
  /// In en, this message translates to:
  /// **'Could not open {count} files: {files}'**
  String openFailedSeveral(int count, String files);

  /// Error when more files fail to open than are listed.
  ///
  /// In en, this message translates to:
  /// **'Could not open {count} files: {files}, and {more} more'**
  String openFailedSeveralMore(int count, String files, int more);

  /// Why a save did not run, quoted in a Save All summary.
  ///
  /// In en, this message translates to:
  /// **'it is being reverted'**
  String get saveReasonReverting;

  /// Why a save did not run, quoted in a Save All summary.
  ///
  /// In en, this message translates to:
  /// **'still opening'**
  String get saveReasonOpening;

  /// Why a save did not run, quoted in a Save All summary.
  ///
  /// In en, this message translates to:
  /// **'the input method is still composing'**
  String get saveReasonComposing;

  /// Why a save did not run, quoted in a Save All summary.
  ///
  /// In en, this message translates to:
  /// **'it changed on disk'**
  String get saveReasonChangedOnDisk;

  /// Why a save did not run, quoted in a Save All summary.
  ///
  /// In en, this message translates to:
  /// **'it was deleted or moved'**
  String get saveReasonMissing;

  /// Save a Local Copy chose the server file's own working copy.
  ///
  /// In en, this message translates to:
  /// **'Choose another location for the local copy.'**
  String get localCopySameLocation;

  /// A save refused while an input method composes.
  ///
  /// In en, this message translates to:
  /// **'{name} was not saved. Finish typing in the input method, then save again.'**
  String saveComposing(String name);

  /// A server file saved locally whose upload did not happen.
  ///
  /// In en, this message translates to:
  /// **'The local copy was saved, but it was not uploaded.'**
  String get localCopyNotUploaded;

  /// Error when a save fails.
  ///
  /// In en, this message translates to:
  /// **'Could not save {name}: {error}'**
  String saveFailed(String name, Object error);

  /// Save As chose a file another tab holds.
  ///
  /// In en, this message translates to:
  /// **'{name} is already open in another tab.'**
  String alreadyOpenInTab(String name);

  /// Save As chose a file another window holds.
  ///
  /// In en, this message translates to:
  /// **'{name} is already open in another window.'**
  String alreadyOpenInWindow(String name);

  /// Save All summary when some saves failed.
  ///
  /// In en, this message translates to:
  /// **'Saved {saved} of {total}. Could not save: {failures}.'**
  String saveAllFailed(int saved, int total, String failures);

  /// Save All summary when it stopped before the end.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Save All stopped with {count} document not saved: {names}.} other{Save All stopped with {count} documents not saved: {names}.}}'**
  String saveAllStopped(int count, String names);

  /// Export refused during a revert.
  ///
  /// In en, this message translates to:
  /// **'{name} is being reverted. Export it once the file is read.'**
  String exportReverting(String name);

  /// Export chose a file a tab holds.
  ///
  /// In en, this message translates to:
  /// **'{name} is open in a tab. Export to another file.'**
  String exportOpenInTab(String name);

  /// Export chose a file another window holds.
  ///
  /// In en, this message translates to:
  /// **'{name} is open in another window. Export to another file.'**
  String exportOpenInWindow(String name);

  /// Export refused for size; sizes are formatted numbers.
  ///
  /// In en, this message translates to:
  /// **'{name} is too large to export as HTML: the page would be {size} MB, over the {limit} MB limit.'**
  String exportTooLarge(String name, String size, String limit);

  /// Error when an export fails.
  ///
  /// In en, this message translates to:
  /// **'Could not export {name}: {error}'**
  String exportFailed(String name, Object error);

  /// Compare with Saved interrupted by a revert.
  ///
  /// In en, this message translates to:
  /// **'{name} is being reverted. Compare it again once the file is read.'**
  String compareReverting(String name);

  /// Compare with Saved interrupted by a save.
  ///
  /// In en, this message translates to:
  /// **'{name} is busy. Compare it again once it finishes.'**
  String compareBusy(String name);

  /// Compare with Saved interrupted by a Save As.
  ///
  /// In en, this message translates to:
  /// **'{name} was saved somewhere else while it was being compared. Compare it again.'**
  String compareSavedElsewhere(String name);

  /// Compare with Saved interrupted by an edit.
  ///
  /// In en, this message translates to:
  /// **'{name} changed while it was being compared. Compare it again.'**
  String compareChanged(String name);

  /// Compare with Saved finished under a dialog.
  ///
  /// In en, this message translates to:
  /// **'A dialog is open, so the comparison of {name} could not be shown. Compare it again after closing it.'**
  String compareDialogOpen(String name);

  /// The diff header naming the saved file.
  ///
  /// In en, this message translates to:
  /// **'{name} (on disk)'**
  String compareOnDisk(String name);

  /// The diff header naming the editor's text.
  ///
  /// In en, this message translates to:
  /// **'{name} (in the editor)'**
  String compareInEditor(String name);

  /// Compare with Saved found no differences.
  ///
  /// In en, this message translates to:
  /// **'{name} has no differences from the file on disk.'**
  String compareIdentical(String name);

  /// Compare with Saved found too many differences.
  ///
  /// In en, this message translates to:
  /// **'The differences between {name} and the file on disk are too large to show as a diff.'**
  String compareTooLarge(String name);

  /// Compare with Saved timed out.
  ///
  /// In en, this message translates to:
  /// **'Comparing {name} with the file on disk ran out of time. Compare it again.'**
  String compareTimedOut(String name);

  /// Error when Compare with Saved fails.
  ///
  /// In en, this message translates to:
  /// **'Could not compare {name} with the file on disk: {error}'**
  String compareFailed(String name, Object error);

  /// The name of the tab that shows a comparison; the app adds a .diff extension.
  ///
  /// In en, this message translates to:
  /// **'{name} vs saved'**
  String compareTabName(String name);

  /// One leftover save file that could not be deleted.
  ///
  /// In en, this message translates to:
  /// **'{name}: {error}'**
  String siblingDeleteFailure(String name, Object error);

  /// Error when leftover save files could not be deleted.
  ///
  /// In en, this message translates to:
  /// **'Could not delete {failures}.'**
  String siblingsDeleteFailed(String failures);

  /// Error when an Android recovery copy cannot be deleted.
  ///
  /// In en, this message translates to:
  /// **'Could not delete the recovery copy {name}: {error}'**
  String recoveryDeleteFailed(String name, Object error);

  /// Error when discarding a document fails.
  ///
  /// In en, this message translates to:
  /// **'Could not discard {name}: {error}'**
  String discardFailed(String name, Object error);

  /// Don't Save refused because the text changed.
  ///
  /// In en, this message translates to:
  /// **'{name} changed while the prompt was open, so nothing was discarded. Review it, then close again.'**
  String discardChangedClose(String name);

  /// Discard All refused because the text changed.
  ///
  /// In en, this message translates to:
  /// **'{name} changed while the prompt was open, so nothing was discarded. Review it, then quit again.'**
  String discardChangedQuit(String name);

  /// Close refused during a save.
  ///
  /// In en, this message translates to:
  /// **'{name} is still being saved. Close it again once the save finishes.'**
  String closeSaving(String name);

  /// Close refused while the document is busy.
  ///
  /// In en, this message translates to:
  /// **'{name} is busy. Close it again in a moment.'**
  String closeBusy(String name);

  /// Close or save refused while the document opens.
  ///
  /// In en, this message translates to:
  /// **'{name} is still opening. Try again in a moment.'**
  String notReady(String name);

  /// Error when Revert to Saved fails.
  ///
  /// In en, this message translates to:
  /// **'Could not revert {name}: {error}'**
  String revertFailed(String name, Object error);

  /// Error when reloading a changed file fails.
  ///
  /// In en, this message translates to:
  /// **'Could not reload {name}: {error}'**
  String reloadFailed(String name, Object error);

  /// Error when the file cannot be checked for outside changes.
  ///
  /// In en, this message translates to:
  /// **'Could not check {name} for changes on disk: {error}'**
  String diskCheckFailed(String name, Object error);

  /// Error when an outside change cannot be read.
  ///
  /// In en, this message translates to:
  /// **'Could not read the new version of {name}: {error}'**
  String diskReadFailed(String name, Object error);

  /// Hot exit restore: the documents that need attention.
  ///
  /// In en, this message translates to:
  /// **'Some documents from the last session need attention: {problems}.'**
  String restoreProblems(String problems);

  /// Hot exit restore: a file changed since its edits were kept.
  ///
  /// In en, this message translates to:
  /// **'{name} changed on disk after its unsaved edits were kept. They are back over the new version: compare before saving'**
  String restoreChangedOnDisk(String name);

  /// Hot exit restore: why a file could not be reopened.
  ///
  /// In en, this message translates to:
  /// **'it is open in another window'**
  String get restoreOpenElsewhere;

  /// Hot exit restore: a file that could not be reopened.
  ///
  /// In en, this message translates to:
  /// **'{name} could not be reopened ({reason})'**
  String restoreFailed(String name, String reason);

  /// Hot exit restore: a file that could not be reopened, its edits moved to an untitled tab.
  ///
  /// In en, this message translates to:
  /// **'{name} could not be reopened ({reason}); its unsaved text is in an untitled tab'**
  String restoreFailedKept(String name, String reason);

  /// Quit refused while work is in progress.
  ///
  /// In en, this message translates to:
  /// **'A document is still opening or closing, or a dialog is waiting. Quit again once it finishes.'**
  String get quitBlockedBusy;

  /// Quit refused during a save.
  ///
  /// In en, this message translates to:
  /// **'A save is still running. Quit again once it finishes.'**
  String get quitBlockedSaving;

  /// The folder browser refused a folder outside the workspace.
  ///
  /// In en, this message translates to:
  /// **'Choose a folder inside this workspace.'**
  String get folderOutsideWorkspace;

  /// Error when a new window fails to open.
  ///
  /// In en, this message translates to:
  /// **'Could not open a window: {error}'**
  String windowOpenFailed(Object error);

  /// Error when quit cannot raise a window to ask about it.
  ///
  /// In en, this message translates to:
  /// **'Could not bring a window forward to close it: {error}'**
  String windowRaiseFailed(Object error);

  /// Error when quitting fails after consent.
  ///
  /// In en, this message translates to:
  /// **'Could not close Planchette: {error}'**
  String appCloseFailed(Object error);

  /// Error when a window fails to close.
  ///
  /// In en, this message translates to:
  /// **'Could not close the window: {error}'**
  String windowCloseFailed(Object error);

  /// Error when the hot exit journal cannot be written.
  ///
  /// In en, this message translates to:
  /// **'Unsaved changes could not be kept for the next launch: {error}'**
  String journalWriteFailed(Object error);

  /// Error from a server file operation.
  ///
  /// In en, this message translates to:
  /// **'Remote file: {error}'**
  String remoteFileFailed(Object error);

  /// The settings file could not be used; the defaults took over.
  ///
  /// In en, this message translates to:
  /// **'Your settings file could not be read, so Planchette started with its default settings.'**
  String get settingsUnreadable;

  /// The damaged settings file was moved aside; the defaults took over.
  ///
  /// In en, this message translates to:
  /// **'Your settings file could not be read, so Planchette started with its default settings. The file was kept as {path}.'**
  String settingsUnreadableKept(String path);

  /// Error when the settings file cannot be written.
  ///
  /// In en, this message translates to:
  /// **'Could not save settings: {detail}'**
  String settingsSaveFailed(String detail);
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
