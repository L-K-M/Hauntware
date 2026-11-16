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

  /// The browser's Repeat row before the first text-tool run.
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
