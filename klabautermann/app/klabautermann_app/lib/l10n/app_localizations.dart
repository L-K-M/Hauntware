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

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann'**
  String get appTitle;

  /// No description provided for @fleetTitle.
  ///
  /// In en, this message translates to:
  /// **'Fleet'**
  String get fleetTitle;

  /// No description provided for @fleetSectionServers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get fleetSectionServers;

  /// No description provided for @fleetEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No servers yet'**
  String get fleetEmptyTitle;

  /// No description provided for @fleetEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Add a server to start monitoring your fleet.'**
  String get fleetEmptyBody;

  /// No description provided for @serversCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{no servers} =1{1 server} other{{count} servers}}'**
  String serversCount(int count);

  /// A fleet rail section header's merged screen-reader announcement: its title and member count.
  ///
  /// In en, this message translates to:
  /// **'{title}, {count}'**
  String sidebarSectionSemantics(String title, String count);

  /// No description provided for @sidebarShowSection.
  ///
  /// In en, this message translates to:
  /// **'Show section'**
  String get sidebarShowSection;

  /// No description provided for @sidebarHideSection.
  ///
  /// In en, this message translates to:
  /// **'Hide section'**
  String get sidebarHideSection;

  /// No description provided for @sidebarFilterHint.
  ///
  /// In en, this message translates to:
  /// **'Filter servers'**
  String get sidebarFilterHint;

  /// No description provided for @sidebarFilterClear.
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get sidebarFilterClear;

  /// No description provided for @sidebarAddMenu.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get sidebarAddMenu;

  /// No description provided for @sidebarRowMenu.
  ///
  /// In en, this message translates to:
  /// **'Server actions'**
  String get sidebarRowMenu;

  /// No description provided for @sidebarCompactRows.
  ///
  /// In en, this message translates to:
  /// **'Compact rows'**
  String get sidebarCompactRows;

  /// No description provided for @sidebarComfortableRows.
  ///
  /// In en, this message translates to:
  /// **'Comfortable rows'**
  String get sidebarComfortableRows;

  /// No description provided for @addServer.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get addServer;

  /// Desktop-only menu entry and button that imports the hosts of the user's OpenSSH client config file into the fleet (FL-02). The path stays literal.
  ///
  /// In en, this message translates to:
  /// **'Import from ~/.ssh/config'**
  String get importSshConfig;

  /// Shown after an ssh_config import finished; count is the number of servers it added.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Your ~/.ssh/config names no hosts to import.} =1{Imported 1 server from ~/.ssh/config.} other{Imported {count} servers from ~/.ssh/config.}}'**
  String sshConfigImported(int count);

  /// Shown instead of sshConfigImported when the import left hosts out; importedCount (0 or more) is the number of servers it added, skippedCount (1 or more) the number of hosts it left out. One message, so the translation decides how its sentences join.
  ///
  /// In en, this message translates to:
  /// **'{importedCount, plural, =0{No hosts were imported from ~/.ssh/config.} =1{Imported 1 server from ~/.ssh/config.} other{Imported {importedCount} servers from ~/.ssh/config.}} {skippedCount, plural, =1{1 host was skipped because of settings Klabautermann cannot follow as ssh would, such as a ProxyCommand, Include or Match block.} other{{skippedCount} hosts were skipped because of settings Klabautermann cannot follow as ssh would, such as a ProxyCommand, Include or Match block.}}'**
  String sshConfigImportedWithSkips(int importedCount, int skippedCount);

  /// No description provided for @sshConfigMissing.
  ///
  /// In en, this message translates to:
  /// **'There is no ~/.ssh/config on this computer.'**
  String get sshConfigMissing;

  /// No description provided for @sshConfigUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Your ~/.ssh/config could not be read. Check that it is a regular file you can open.'**
  String get sshConfigUnreadable;

  /// No description provided for @sshConfigTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Your ~/.ssh/config is too large to import.'**
  String get sshConfigTooLarge;

  /// No description provided for @sshConfigImportFailed.
  ///
  /// In en, this message translates to:
  /// **'The import from ~/.ssh/config failed. Try again, and restart the app if it keeps failing.'**
  String get sshConfigImportFailed;

  /// Second top toast after an ssh_config import whose servers appear in the fleet but could not be written to the device's import file.
  ///
  /// In en, this message translates to:
  /// **'This import could not be saved, so it will not be kept after a restart.'**
  String get sshConfigImportNotSaved;

  /// No description provided for @syncFleet.
  ///
  /// In en, this message translates to:
  /// **'Synchronize'**
  String get syncFleet;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get openSettings;

  /// The menu command that opens Settings: in the macOS application menu, in the File menu on Linux and Windows.
  ///
  /// In en, this message translates to:
  /// **'Settings…'**
  String get settingsCommand;

  /// The Linux and Windows File menu's Quit row, which closes the main window the way its close button does.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get appQuitLabel;

  /// Title of the File menu.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get menuFile;

  /// Title of the View menu (macOS, where it holds Enter Full Screen).
  ///
  /// In en, this message translates to:
  /// **'View'**
  String get menuView;

  /// Title of the Window menu (macOS, where it holds Minimize, Zoom and Bring All to Front).
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get menuWindow;

  /// No description provided for @statusConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get statusConnected;

  /// No description provided for @statusConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get statusConnecting;

  /// No description provided for @statusDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get statusDisconnected;

  /// No description provided for @statusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get statusFailed;

  /// No description provided for @statusAuthenticating.
  ///
  /// In en, this message translates to:
  /// **'Authenticating'**
  String get statusAuthenticating;

  /// No description provided for @statusLimited.
  ///
  /// In en, this message translates to:
  /// **'Connected with limits'**
  String get statusLimited;

  /// No description provided for @statusWaitingToReconnect.
  ///
  /// In en, this message translates to:
  /// **'Waiting to reconnect'**
  String get statusWaitingToReconnect;

  /// No description provided for @statusNeedsInput.
  ///
  /// In en, this message translates to:
  /// **'Needs your input'**
  String get statusNeedsInput;

  /// No description provided for @statusBlocked.
  ///
  /// In en, this message translates to:
  /// **'Blocked'**
  String get statusBlocked;

  /// No description provided for @statusConnectionLost.
  ///
  /// In en, this message translates to:
  /// **'Connection lost'**
  String get statusConnectionLost;

  /// Screen-reader label for a server row's status dot.
  ///
  /// In en, this message translates to:
  /// **'Server status: {status}'**
  String statusSemantics(String status);

  /// Why a connect failed (03 §10.1), under the server header and in the fleet row's tooltip: the connection was refused, the host had no route or address, or a jump host could not forward to it.
  ///
  /// In en, this message translates to:
  /// **'This server could not be reached. Check its address and your network connection.'**
  String get linkFailureUnreachable;

  /// Why a connect failed (03 §10.1): connecting, the handshake or signing in ran past its deadline.
  ///
  /// In en, this message translates to:
  /// **'This server did not answer in time. Check that it is running and that your network reaches it.'**
  String get linkFailureTimedOut;

  /// Why a connect failed (03 §10.1): the server refused every credential offered.
  ///
  /// In en, this message translates to:
  /// **'The server rejected your credentials. Make sure it trusts your key or password.'**
  String get linkFailureAuthenticationRejected;

  /// Why a connect failed (03 §10.1): a key file could not be read or holds no key the app can use, or ssh-agent holds no keys. ssh-agent is the OpenSSH program's name, not translated.
  ///
  /// In en, this message translates to:
  /// **'No credential could be offered to this server. Check that its key file can be read and holds a supported key, or load a key into ssh-agent.'**
  String get linkFailureCredentialUnavailable;

  /// Why a connect failed (03 §10.1): the private key of this server or of a jump host on its route is encrypted, and the app has no passphrase prompt yet. A server whose ssh_config entry names a key file uses only that file, so the agent signs only once the IdentityFile line is gone and the config is imported again. ssh-agent, IdentityFile and ~/.ssh/config are OpenSSH names, not translated.
  ///
  /// In en, this message translates to:
  /// **'A key for this server needs a passphrase, which Klabautermann cannot ask for. Load the key into ssh-agent and remove the IdentityFile line that names it from ~/.ssh/config, then import the config again.'**
  String get linkFailureKeyPassphraseRequired;

  /// Why a connect failed (03 §4.5, §10.1): the Flatpak sandbox shows the app only the paths its manifest grants, so the key file of this server or of a jump host on its route reads as missing. A server whose ssh_config entry names a key file uses only that file, so the agent signs only once the IdentityFile line is gone and the config is imported again. ssh-agent, IdentityFile and ~/.ssh/config are OpenSSH names, not translated.
  ///
  /// In en, this message translates to:
  /// **'A key file for this server cannot be read in the Flatpak sandbox. Load the key into ssh-agent and remove the IdentityFile line that names it from ~/.ssh/config, then import the config again.'**
  String get linkFailureKeyFileHiddenBySandbox;

  /// Why a connect failed (03 §4.6, §10.1): the user declined a first-seen host key, or a connect the user did not start declined it without asking.
  ///
  /// In en, this message translates to:
  /// **'This server\'s host key has not been trusted, so Klabautermann did not connect.'**
  String get linkFailureHostKeyDeclined;

  /// Why a connect failed (03 §10.1): the user cancelled the server's keyboard-interactive questions, such as a one-time code.
  ///
  /// In en, this message translates to:
  /// **'The server\'s sign-in questions were cancelled, so Klabautermann did not connect.'**
  String get linkFailureKeyboardInteractiveCancelled;

  /// Client limitation (03 §5.3, CN-23): the server requires an algorithm the SSH library does not implement, such as an ML-KEM key exchange.
  ///
  /// In en, this message translates to:
  /// **'This server requires an algorithm Klabautermann does not support yet.'**
  String get linkFailureUnsupportedAlgorithm;

  /// Client limitation (03 §5.3, D23): the server offers only key exchanges or MACs the suite refuses as broken.
  ///
  /// In en, this message translates to:
  /// **'This server offers only algorithms Klabautermann refuses as insecure.'**
  String get linkFailureInsecureAlgorithmsOnly;

  /// Client limitation (03 §5.3, CN-23): on Android, the server gave up while a finite-field Diffie-Hellman key exchange was still being computed.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not finish this server\'s key exchange in time on this device.'**
  String get linkFailureKeyExchangeTimedOut;

  /// Fleet row state (FL-04): the reachability probe reached the server's SSH port, and nothing is connected to it.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get fleetRowProbeOnline;

  /// Fleet row state (FL-04): the reachability probe was refused, or the host had no route or no address.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get fleetRowProbeOffline;

  /// Fleet row state (FL-04): the reachability probe could not tell, for example after a timeout. Not the same as offline: a host behind a firewall or a jump host may be up.
  ///
  /// In en, this message translates to:
  /// **'Reachability unknown'**
  String get fleetRowProbeUnknown;

  /// A reading's age under a minute: under a fleet row's pressure bar, and as the age in fleetRowUpdated and fleetRowStaleAge.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String fleetRowAgeSeconds(int seconds);

  /// A reading's age under an hour, in whole minutes: under a fleet row's pressure bar, and as the age in fleetRowUpdated and fleetRowStaleAge.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String fleetRowAgeMinutes(int minutes);

  /// A reading's age of an hour or more, in whole hours: under a fleet row's pressure bar, and as the age in fleetRowUpdated and fleetRowStaleAge.
  ///
  /// In en, this message translates to:
  /// **'{hours} h'**
  String fleetRowAgeHours(int hours);

  /// Fleet row freshness (03 §9.5 item 4, OV-04): how long ago the row's CPU and memory reading arrived, in the row's tooltip and screen-reader label.
  ///
  /// In en, this message translates to:
  /// **'Updated {age} ago'**
  String fleetRowUpdated(String age);

  /// Under a fleet row's grey pressure bar, beside a history icon (03 §9.5 item 4, A11Y-01): the values are stale, and age says how old they are. Used when the row's state word (for example Connected or Online) does not already say the connection is down.
  ///
  /// In en, this message translates to:
  /// **'Stale · {age}'**
  String fleetRowStaleAge(String age);

  /// The CPU cell of a fleet row's pressure bar (FL-07), as its summary names it.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get fleetRowCpu;

  /// The memory cell of a fleet row's pressure bar (FL-07), as its summary names it.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get fleetRowMemory;

  /// The disk cell of a fleet row's pressure bar (FL-07): how full the server's root file system is.
  ///
  /// In en, this message translates to:
  /// **'Disk'**
  String get fleetRowDisk;

  /// Fleet row warning (03 §4.6): saved host keys are keyed by address and port, so this server's would collide with those of the named servers, which reach the same address through other jump hosts.
  ///
  /// In en, this message translates to:
  /// **'Host key conflict with {servers}: they reach the same address through a different jump route.'**
  String fleetRowLocatorConflict(String servers);

  /// Between the parts of a fleet row's second line: its state and its address.
  ///
  /// In en, this message translates to:
  /// **' · '**
  String get fleetRowPartSeparator;

  /// Between the parts of a fleet row's screen-reader label, and between server names in fleetRowLocatorConflict.
  ///
  /// In en, this message translates to:
  /// **', '**
  String get fleetRowListSeparator;

  /// Screen-reader announcement when a server's connection state changes (A11Y-15); status is a word such as Connected or Connection lost.
  ///
  /// In en, this message translates to:
  /// **'{server}: {status}'**
  String fleetRowLinkAnnouncement(String server, String status);

  /// Under the fleet filter field while a query matches no server: how many servers match out of all.
  ///
  /// In en, this message translates to:
  /// **'{matches} of {total}'**
  String fleetFilterCount(int matches, int total);

  /// Under the fleet filter field while a query matches servers: how many match out of all, and that the Enter key opens the first match.
  ///
  /// In en, this message translates to:
  /// **'{matches} of {total} · Enter opens the first'**
  String fleetFilterCountOpensFirst(int matches, int total);

  /// Shown in place of the fleet list when the filter matches no server.
  ///
  /// In en, this message translates to:
  /// **'No servers match'**
  String get fleetFilterNoMatches;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsTabGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsTabGeneral;

  /// No description provided for @settingsTabAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsTabAppearance;

  /// No description provided for @settingsTabSync.
  ///
  /// In en, this message translates to:
  /// **'Sync'**
  String get settingsTabSync;

  /// No description provided for @settingsTabServers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get settingsTabServers;

  /// No description provided for @settingsTabDocker.
  ///
  /// In en, this message translates to:
  /// **'Docker'**
  String get settingsTabDocker;

  /// No description provided for @settingsTabSafety.
  ///
  /// In en, this message translates to:
  /// **'Safety'**
  String get settingsTabSafety;

  /// No description provided for @settingsTabAlerts.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get settingsTabAlerts;

  /// No description provided for @themeLabel.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get themeLabel;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// Top toast after a theme pick, in Settings or the desktop settings window, that applied but could not be written to the settings file.
  ///
  /// In en, this message translates to:
  /// **'The theme changed, but it could not be saved, so it will not be kept after a restart.'**
  String get themeNotSaved;

  /// Top toast shown when the app did not take a theme-mode change made in Settings.
  ///
  /// In en, this message translates to:
  /// **'The theme could not be changed.'**
  String get themeNotChanged;

  /// Startup notice: the settings file was damaged, set aside under a new name, and replaced with the defaults.
  ///
  /// In en, this message translates to:
  /// **'Your settings file could not be read and was reset. The old file is kept as {fileName}.'**
  String settingsFileRecovered(String fileName);

  /// Startup notice: the settings file was damaged and set aside under a new name, but writing the defaults over it failed.
  ///
  /// In en, this message translates to:
  /// **'Your settings file could not be read or reset. The old file is kept as {fileName}. Changes you make now may be lost when Klabautermann restarts.'**
  String settingsFileRecoveredNotSaved(String fileName);

  /// Startup notice: the settings file could not be read or set aside, so the app does not write it this session.
  ///
  /// In en, this message translates to:
  /// **'Your settings file could not be read, so it was left as it is. Changes you make now are not saved.'**
  String get settingsFileLeftAsIs;

  /// Startup notice: a newer app version wrote the settings file, so this version does not write it.
  ///
  /// In en, this message translates to:
  /// **'Your settings were saved by a newer version of Klabautermann. Changes you make now are not saved.'**
  String get settingsFileNewer;

  /// Startup notice: writing the settings file failed while the app started.
  ///
  /// In en, this message translates to:
  /// **'Your settings could not be saved. Changes you make now may be lost when Klabautermann restarts.'**
  String get settingsFileNotSaved;

  /// Startup notice: the file holding the servers imported from ~/.ssh/config was damaged and renamed aside, so the fleet starts without them.
  ///
  /// In en, this message translates to:
  /// **'Your imported servers could not be read and were cleared. The old file is kept as {fileName}. Import ~/.ssh/config again to bring them back.'**
  String importsFileRecovered(String fileName);

  /// Startup notice: the file holding the servers imported from ~/.ssh/config could not be read or renamed aside, so it is not written this session.
  ///
  /// In en, this message translates to:
  /// **'Your imported servers could not be read, so their file was left as it is. Servers you import now will not be kept after a restart.'**
  String get importsFileLeftAsIs;

  /// Startup notice: a newer app version wrote the file holding the servers imported from ~/.ssh/config, so this version does not write it.
  ///
  /// In en, this message translates to:
  /// **'Your imported servers were saved by a newer version of Klabautermann. Servers you import now will not be kept after a restart.'**
  String get importsFileNewer;

  /// Startup notice: the lock that keeps a second copy of the desktop app from starting could not be taken, so a second copy would not be stopped.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not check whether it is already running. If you open it twice, the two copies can overwrite each other\'s settings and imported servers.'**
  String get instanceLockUnavailable;

  /// Heading of the only screen a second copy of the desktop app shows before it quits.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann is already running'**
  String get alreadyRunningTitle;

  /// Body of the screen a second copy of the desktop app shows: where to go instead, and why only one copy runs.
  ///
  /// In en, this message translates to:
  /// **'Switch to the Klabautermann window that is already open. Only one copy runs at a time, so two copies never overwrite each other\'s settings and imported servers.'**
  String get alreadyRunningBody;

  /// Button on the already-running screen that quits the second copy.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get alreadyRunningQuit;

  /// Shown in the desktop settings window when the app does not answer it.
  ///
  /// In en, this message translates to:
  /// **'Settings cannot reach Klabautermann. Close this window and open Settings again.'**
  String get settingsWindowUnreachable;

  /// No description provided for @workspaceEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Select a server'**
  String get workspaceEmptyTitle;

  /// No description provided for @workspaceEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Choose a server from the fleet to see its workspace.'**
  String get workspaceEmptyBody;

  /// No description provided for @inspectorTitle.
  ///
  /// In en, this message translates to:
  /// **'Inspector'**
  String get inspectorTitle;

  /// No description provided for @inspectorEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Details, alerts, operations and coverage appear here once you select a server.'**
  String get inspectorEmptyBody;

  /// No description provided for @placeholderMilestone.
  ///
  /// In en, this message translates to:
  /// **'Available in a later milestone.'**
  String get placeholderMilestone;

  /// Heading of the first-run coverage card (03 §9.5 item 1), shown above the fleet on phones and above the workspace on desktops until the user dismisses it.
  ///
  /// In en, this message translates to:
  /// **'How Klabautermann watches your servers'**
  String get coverageFirstRunTitle;

  /// Body of the first-run coverage card: what the app does and does not cover. It names no alerts, since this version has none.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann connects over SSH only while it is open. It installs nothing on your servers unless you ask it to. Charts cover only the time this device was connected.'**
  String get coverageFirstRunBody;

  /// Button that dismisses the first-run coverage card for good on this device.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get coverageFirstRunDismiss;

  /// Button on the first-run coverage card that opens the coverage sheet.
  ///
  /// In en, this message translates to:
  /// **'Coverage details'**
  String get coverageFirstRunDetails;

  /// Top toast when dismissing the first-run coverage card could not be written to the device's settings file; the card stays hidden for this session.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not save that you dismissed the coverage note, so it shows again after a restart.'**
  String get coverageFirstRunNotSaved;

  /// The fleet header's coverage chip (03 §9.5 item 2): how many fleet servers this device watches continuously (its monitor set) out of all of them; watching happens only while the app is open. Opens the coverage sheet.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =1{Watching {watched} of 1 server on this device, only while open} other{Watching {watched} of {total} servers on this device, only while open}}'**
  String coverageChip(int watched, int total);

  /// Screen-reader hint for activating the fleet header's coverage chip.
  ///
  /// In en, this message translates to:
  /// **'Show coverage details'**
  String get coverageChipHint;

  /// Heading of the coverage sheet the fleet header's chip opens.
  ///
  /// In en, this message translates to:
  /// **'Coverage on this device'**
  String get coverageSheetTitle;

  /// Badge naming the execution tier the fleet runs at: T0, SSH only while the app is open (03 §9). Kept as written.
  ///
  /// In en, this message translates to:
  /// **'T0'**
  String get coverageTierBadge;

  /// What the T0 badge means, beside it in the coverage sheet.
  ///
  /// In en, this message translates to:
  /// **'SSH while Klabautermann is open'**
  String get coverageTierTitle;

  /// Explanation under the tier title in the coverage sheet.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann reads your servers over SSH only while it is open. It installs nothing on them unless you ask it to.'**
  String get coverageTierBody;

  /// Heading of the coverage sheet's list of what this device covers.
  ///
  /// In en, this message translates to:
  /// **'Covered'**
  String get coverageCoveredHeading;

  /// Coverage sheet item: the servers the user has open are read live.
  ///
  /// In en, this message translates to:
  /// **'Live readings while open'**
  String get coverageLiveTitle;

  /// Body of the coverage sheet's live-readings item.
  ///
  /// In en, this message translates to:
  /// **'Metrics, processes, services, logs and jobs of the servers you have open.'**
  String get coverageLiveBody;

  /// Coverage sheet item about the servers this device watches continuously (its monitor set, FL-21): listed as covered once one is watched, and as not covered while none is.
  ///
  /// In en, this message translates to:
  /// **'Continuous watching'**
  String get coverageWatchedTitle;

  /// Body of the coverage sheet's watched-servers item; watched is the size of this device's monitor set within the fleet.
  ///
  /// In en, this message translates to:
  /// **'{watched, plural, =0{No server is watched on this device, so each is read only while you have it open.} =1{1 server is read continuously while Klabautermann is open. Any others are read only while you have them open.} other{{watched} servers are read continuously while Klabautermann is open. Any others are read only while you have them open.}}'**
  String coverageWatchedBody(int watched);

  /// Heading of the coverage sheet's list of what this device does not cover.
  ///
  /// In en, this message translates to:
  /// **'Not covered'**
  String get coverageNotCoveredHeading;

  /// Coverage sheet item: nothing is covered while the app is closed.
  ///
  /// In en, this message translates to:
  /// **'While Klabautermann is closed'**
  String get coverageClosedTitle;

  /// Body of the coverage sheet's while-closed item.
  ///
  /// In en, this message translates to:
  /// **'Nothing checks your servers, so nothing can warn you about them.'**
  String get coverageClosedBody;

  /// Coverage sheet item: a server that goes down while the app is closed goes unnoticed.
  ///
  /// In en, this message translates to:
  /// **'A server going down'**
  String get coverageHostDownTitle;

  /// Body of the coverage sheet's server-down item.
  ///
  /// In en, this message translates to:
  /// **'If a server stops while Klabautermann is closed, you find out the next time you open it.'**
  String get coverageHostDownBody;

  /// Coverage sheet item: charts hold no history from before this device connected.
  ///
  /// In en, this message translates to:
  /// **'History before you connected'**
  String get coverageHistoryTitle;

  /// Body of the coverage sheet's history item.
  ///
  /// In en, this message translates to:
  /// **'Charts cover only the time this device was connected. Gaps are marked, never filled in.'**
  String get coverageHistoryBody;

  /// Coverage sheet item shown on iOS and Android only: reading stops in the background (PLT-04).
  ///
  /// In en, this message translates to:
  /// **'While in the background'**
  String get coverageBackgroundTitle;

  /// Body of the coverage sheet's background item, and a line in the header of a phone's server screen (PLT-04), on iOS and Android only.
  ///
  /// In en, this message translates to:
  /// **'Reading stops while Klabautermann is in the background and resumes when you return.'**
  String get coverageBackgroundBody;

  /// An age under a minute in a freshness line (03 §9.5 item 4), as in "Updated 4 s ago".
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String coverageFreshnessSeconds(int seconds);

  /// An age under an hour, in whole minutes, in a freshness line.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String coverageFreshnessMinutes(int minutes);

  /// An age under a day, in whole hours, in a freshness line.
  ///
  /// In en, this message translates to:
  /// **'{hours} h'**
  String coverageFreshnessHours(int hours);

  /// An age of a day or more, in whole days, in a freshness line.
  ///
  /// In en, this message translates to:
  /// **'{days} d'**
  String coverageFreshnessDays(int days);

  /// Freshness line of a server's or panel's values while they are current; age is one of the coverageFreshness age strings.
  ///
  /// In en, this message translates to:
  /// **'Updated {age} ago'**
  String coverageFreshnessUpdated(String age);

  /// Freshness line of values older than their stream's limit, which are drawn grey beside it.
  ///
  /// In en, this message translates to:
  /// **'Stale: updated {age} ago'**
  String coverageFreshnessStale(String age);

  /// Freshness line while the server's connection is down after readings arrived; age is how long it has been down.
  ///
  /// In en, this message translates to:
  /// **'Disconnected {age} ago'**
  String coverageFreshnessDisconnected(String age);

  /// Freshness line while a phone app is in the background and reading is paused.
  ///
  /// In en, this message translates to:
  /// **'Paused: app in background'**
  String get coverageFreshnessPaused;

  /// Freshness line of a server outside this device's monitor set that nothing reads.
  ///
  /// In en, this message translates to:
  /// **'Not watched on this device'**
  String get coverageFreshnessNotWatched;

  /// Freshness line before the first reading has arrived; also under coverageDetailsGaps while this server has no reading this session.
  ///
  /// In en, this message translates to:
  /// **'No data yet'**
  String get coverageFreshnessNoData;

  /// The server header's coverage chip (03 §10.2): the server's execution tier, T0 (kept as written), and that Klabautermann takes readings from this server only while a view has it open, since no monitor set watches it yet. Not about read-only access, which the header shows separately. Opens the coverage sheet.
  ///
  /// In en, this message translates to:
  /// **'T0: sampled only while open'**
  String get coverageServerChip;

  /// Heading of a server's coverage card on its Overview and of the coverage section in the desktop inspector (03 §9.5 item 3).
  ///
  /// In en, this message translates to:
  /// **'Coverage'**
  String get coverageServerTitle;

  /// Under the T0 badge of a server's coverage while the engine samples it.
  ///
  /// In en, this message translates to:
  /// **'Reading this server now, while you have it open.'**
  String get coverageLiveSampling;

  /// Under the T0 badge of a server's coverage while its readings wait for the SSH connection.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the connection to this server.'**
  String get coverageLiveWaiting;

  /// Under the T0 badge of a server's coverage while a phone app is in the background and reading is paused.
  ///
  /// In en, this message translates to:
  /// **'Paused while Klabautermann is in the background.'**
  String get coverageLivePaused;

  /// Under the T0 badge of a server's coverage while no shown panel samples it, such as the Logs or Access tab.
  ///
  /// In en, this message translates to:
  /// **'Not reading this server now: the open panel takes no readings.'**
  String get coverageLiveIdle;

  /// Under the T0 badge of a server's coverage before the engine has said what reading the server is doing.
  ///
  /// In en, this message translates to:
  /// **'Reads this server only while you have it open.'**
  String get coverageLivePolicy;

  /// Heading over a server's session chart in its coverage card: the readings this device took, with hatched bands where it has none.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =1{The last minute on this device} other{The last {minutes} minutes on this device}}'**
  String coverageSessionTitle(int minutes);

  /// Legend and screen-reader name of the session chart's line: the share of time the server's CPUs were busy.
  ///
  /// In en, this message translates to:
  /// **'CPU busy'**
  String get coverageSessionLane;

  /// The session chart's source line (03 §9.5 item 5): where its readings come from.
  ///
  /// In en, this message translates to:
  /// **'Recorded by this device while connected'**
  String get coverageSessionSource;

  /// A server's coverage when its systemd services include a running monitoring agent such as node_exporter or Netdata (03 §9.5 item 3). units lists the running units' names, server data shown as written.
  ///
  /// In en, this message translates to:
  /// **'External monitor running: {units}. It may cover this server while Klabautermann is closed; Klabautermann does not read it.'**
  String coverageMonitorRunning(String units);

  /// A server's coverage when monitoring agents are installed as systemd services but none runs. units lists their names, server data shown as written.
  ///
  /// In en, this message translates to:
  /// **'No external monitor is running. Installed but stopped: {units}.'**
  String coverageMonitorStopped(String units);

  /// A server's coverage when its full systemd service list holds no known monitoring agent. A monitor outside systemd is not seen.
  ///
  /// In en, this message translates to:
  /// **'No external monitor found among this server\'s systemd services.'**
  String get coverageMonitorNone;

  /// A server's coverage while its systemd service list has not arrived yet.
  ///
  /// In en, this message translates to:
  /// **'Looking for an external monitor among this server\'s systemd services.'**
  String get coverageMonitorChecking;

  /// A server's coverage when its systemd service list failed or came back incomplete.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann cannot tell whether an external monitor runs: this server\'s systemd services could not be listed.'**
  String get coverageMonitorUnknown;

  /// Heading in the desktop inspector's coverage section over the recent periods without data, each worded with chartGapSummary or chartGapOngoing.
  ///
  /// In en, this message translates to:
  /// **'Recent gaps'**
  String get coverageDetailsGaps;

  /// Under coverageDetailsGaps when the recent readings have no gap with a known cause: no background pause, lost link or failed reading. The chart's line may still break where no view read the server, which this list does not name.
  ///
  /// In en, this message translates to:
  /// **'No pauses, lost links or failed readings.'**
  String get coverageDetailsNoGaps;

  /// Under the newest gaps listed below coverageDetailsGaps, when the recent readings have more gaps than the inspector lists: how many older ones it leaves out.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 earlier gap not shown.} other{{count} earlier gaps not shown.}}'**
  String coverageDetailsEarlierGaps(int count);

  /// Banner on a phone's server screen after the app returns from the background (03 §9.5 item 6): when the app left for the background and returned, as times of day in the UI locale. It shows only for a server the engine was reading or said it paused; once the server has readings, its charts show the same period as a hatched band.
  ///
  /// In en, this message translates to:
  /// **'Paused {start} to {end} while in background. No data for that period.'**
  String coverageReturnBanner(String start, String end);

  /// Button that hides the return-from-background banner.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get coverageReturnDismiss;

  /// No description provided for @serverTitle.
  ///
  /// In en, this message translates to:
  /// **'{name}'**
  String serverTitle(String name);

  /// No description provided for @workspaceTabOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get workspaceTabOverview;

  /// No description provided for @workspaceTabProcesses.
  ///
  /// In en, this message translates to:
  /// **'Processes'**
  String get workspaceTabProcesses;

  /// No description provided for @workspaceTabServices.
  ///
  /// In en, this message translates to:
  /// **'Services'**
  String get workspaceTabServices;

  /// No description provided for @workspaceTabLogs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get workspaceTabLogs;

  /// No description provided for @workspaceTabJobs.
  ///
  /// In en, this message translates to:
  /// **'Jobs'**
  String get workspaceTabJobs;

  /// No description provided for @workspaceTabDocker.
  ///
  /// In en, this message translates to:
  /// **'Docker'**
  String get workspaceTabDocker;

  /// No description provided for @workspaceTabSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get workspaceTabSystem;

  /// No description provided for @workspaceTabAccess.
  ///
  /// In en, this message translates to:
  /// **'Access'**
  String get workspaceTabAccess;

  /// No description provided for @serverTabMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get serverTabMore;

  /// Title of a server panel a phone opens full-screen from its More list (03 §10.5): panel is the panel's name as its tab reads it (Processes, Services, Jobs or System), and name is the server's display name.
  ///
  /// In en, this message translates to:
  /// **'{panel} on {name}'**
  String serverPanelPageTitle(String panel, String name);

  /// Notice over a phone's fleet list after the server whose screen was open left the fleet, for example removed on another device or left out of a new ssh_config import (SYN-08). The app closed the server's screen and everything opened from it; name is the server's display name.
  ///
  /// In en, this message translates to:
  /// **'{name} is no longer in your fleet, so its screen closed.'**
  String fleetServerLeftNotice(String name);

  /// Button that hides the notice that a server left the fleet.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get fleetServerLeftDismiss;

  /// The Processes tab before the server sent its first process list (PRC-01).
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first process list.'**
  String get processesWaiting;

  /// Why the server's latest process list failed; reason is missing, denied, timeout or error. The last list, if any, stays below with its age.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, missing{The server lacks a tool the process list needs.} denied{The server refused the process list.} timeout{The process list did not finish in time.} other{The process list failed.}}'**
  String processesUnavailable(String reason);

  /// The server lists at most 500 processes (D48); shown is how many the tab lists, total how many the server counted.
  ///
  /// In en, this message translates to:
  /// **'Showing {shown} of {total} processes'**
  String processesShownOf(int shown, int total);

  /// As processesShownOf, when the server did not say how many it counted.
  ///
  /// In en, this message translates to:
  /// **'Showing {shown} processes; the server left others out'**
  String processesShownSome(int shown);

  /// Hint of the Processes tab's filter field, which matches PIDs, names, users and the shown command lines.
  ///
  /// In en, this message translates to:
  /// **'Filter processes'**
  String get processesFilterHint;

  /// Tooltip of the button that empties the Processes tab's filter field.
  ///
  /// In en, this message translates to:
  /// **'Clear filter'**
  String get processesFilterClear;

  /// Label of the phone layout's menu that picks the column the processes are ordered by.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get processesSortBy;

  /// The Processes tab when the server's list holds no process.
  ///
  /// In en, this message translates to:
  /// **'The server listed no processes.'**
  String get processesEmpty;

  /// The Processes tab when its filter matches none of the listed processes.
  ///
  /// In en, this message translates to:
  /// **'No process matches the filter.'**
  String get processesNoMatch;

  /// Processes column header: the process's command line.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get processesColumnCommand;

  /// Processes column header: the process ID.
  ///
  /// In en, this message translates to:
  /// **'PID'**
  String get processesColumnPid;

  /// Processes column header: the user the process runs as.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get processesColumnUser;

  /// Processes column header: the process's share of one CPU since the previous reading.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get processesColumnCpu;

  /// Processes column header: the process's resident memory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get processesColumnMemory;

  /// Processes column header: when the process started.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get processesColumnStarted;

  /// Label of the process ID of a process's parent, in a process's details.
  ///
  /// In en, this message translates to:
  /// **'Parent PID'**
  String get processesParentPid;

  /// Label of a process's run state letter as the kernel reports it (such as R or S), in a process's details.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get processesState;

  /// A process's user when only its numeric user ID is known.
  ///
  /// In en, this message translates to:
  /// **'UID {uid}'**
  String processesUid(int uid);

  /// A process's CPU share; share arrives as a fraction where 1 is one full CPU, so it can exceed 100%.
  ///
  /// In en, this message translates to:
  /// **'{share}'**
  String processesCpu(double share);

  /// When a process started, if on the day of the reading: a time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String processesStartedTime(DateTime time);

  /// When a process started, if before the day of the reading: a date in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{date}'**
  String processesStartedDate(DateTime date);

  /// In place of a command line the server did not give, as for a kernel thread (03 §7.2).
  ///
  /// In en, this message translates to:
  /// **'Command line unavailable'**
  String get processesCommandUnavailable;

  /// A process's kernel name in place of a command line the server did not give.
  ///
  /// In en, this message translates to:
  /// **'{name} (command line unavailable)'**
  String processesCommandUnavailableOf(String name);

  /// What a screen reader says in place of a masked secret in a command line (SAF-07).
  ///
  /// In en, this message translates to:
  /// **'(masked)'**
  String get processesMasked;

  /// One of a process's figures as drawn under its command line in the phone layout's list: the table column's header label, then the value.
  ///
  /// In en, this message translates to:
  /// **'{label}: {value}'**
  String processesFact(String label, String value);

  /// Heading of a process's arguments in its details.
  ///
  /// In en, this message translates to:
  /// **'Command line'**
  String get processesCommandLineTitle;

  /// Note above a process's arguments when some are masked secrets (SAF-07): a reveal is temporary and stays on this device.
  ///
  /// In en, this message translates to:
  /// **'Select a masked argument to show it for {seconds} seconds.'**
  String processesRevealNote(int seconds);

  /// Screen-reader hint of a masked argument, which shows its value for a while when activated.
  ///
  /// In en, this message translates to:
  /// **'Show the masked value'**
  String get processesRevealHint;

  /// Screen-reader hint of a revealed argument, which masks it again when activated.
  ///
  /// In en, this message translates to:
  /// **'Mask again'**
  String get processesHideHint;

  /// Heading of the System tab's section about what the server is: host name, operating system, kernel, architecture and virtualization (SYS-01).
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get systemIdentityTitle;

  /// Heading of the System tab's section with how long the server has been up and when it booted (BOOT-01).
  ///
  /// In en, this message translates to:
  /// **'Uptime'**
  String get systemUptimeTitle;

  /// Heading of the System tab's section with the server's total network throughput (NET-01).
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get systemNetworkTitle;

  /// Heading of the System tab's section with the space and inodes each mounted filesystem uses (DSK-01, DSK-02).
  ///
  /// In en, this message translates to:
  /// **'Disks'**
  String get systemDisksTitle;

  /// Label of the server's static host name in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Host name'**
  String get systemHostname;

  /// Label of the server's operating system and version, as the server names it, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Operating system'**
  String get systemOperatingSystem;

  /// Label of the server's kernel name and release in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Kernel'**
  String get systemKernel;

  /// The server's kernel as the System tab shows it: its name and its release, both as the server reports them.
  ///
  /// In en, this message translates to:
  /// **'{name} {release}'**
  String systemKernelValue(String name, String release);

  /// Label of the server's machine architecture, such as x86_64 or aarch64, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Architecture'**
  String get systemArchitecture;

  /// Label of whether the server runs on bare metal, in a virtual machine or in a container, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Virtualization'**
  String get systemVirtualization;

  /// The System tab's virtualization value when the server detected neither a virtual machine nor a container.
  ///
  /// In en, this message translates to:
  /// **'None detected'**
  String get systemVirtualizationNone;

  /// The System tab's virtualization value for a server in a virtual machine; name is the technology as the server reports it.
  ///
  /// In en, this message translates to:
  /// **'Virtual machine ({name})'**
  String systemVirtualizationMachine(String name);

  /// The System tab's virtualization value for a server that is a container; name is the technology as the server reports it.
  ///
  /// In en, this message translates to:
  /// **'Container ({name})'**
  String systemVirtualizationContainer(String name);

  /// The System tab's virtualization value for a server that is a container of a technology the server did not name.
  ///
  /// In en, this message translates to:
  /// **'Container'**
  String get systemVirtualizationContainerUnnamed;

  /// Note in the System tab's identity section for a container: values the container would read from its host's system files are not shown as its own (SYS-04).
  ///
  /// In en, this message translates to:
  /// **'This server is a container. Figures that would come from its host read as unknown.'**
  String get systemContainerNotice;

  /// A System tab value the server did not report, or that is not shown for a reason given beside it; never shown as zero.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get systemUnknown;

  /// Reason beside an unknown System tab value: in a container, the system file it comes from shows the host's figures instead of the container's (SYS-04).
  ///
  /// In en, this message translates to:
  /// **'Inside this container this figure would be the host\'s, so it is not shown.'**
  String get systemUnknownContainer;

  /// Label of how long the server has been running since it booted, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Up for'**
  String get systemUptime;

  /// How long a server has been up, from one day on: whole days and the hours past them.
  ///
  /// In en, this message translates to:
  /// **'{days, plural, =1{1 day} other{{days} days}}, {hours, plural, =1{1 hour} other{{hours} hours}}'**
  String systemUptimeDays(int days, int hours);

  /// How long a server has been up, from one hour to a day: whole hours and the minutes past them.
  ///
  /// In en, this message translates to:
  /// **'{hours, plural, =1{1 hour} other{{hours} hours}}, {minutes, plural, =1{1 minute} other{{minutes} minutes}}'**
  String systemUptimeHours(int hours, int minutes);

  /// How long a server has been up, under an hour: whole minutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes, plural, =0{Less than a minute} =1{1 minute} other{{minutes} minutes}}'**
  String systemUptimeMinutes(int minutes);

  /// Label of when the server last booted, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Booted'**
  String get systemBooted;

  /// When the server last booted: a date and time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String systemBootedValue(DateTime time);

  /// Label of the server's total receive rate over all its network interfaces, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Receive'**
  String get systemReceive;

  /// Label of the server's total transmit rate over all its network interfaces, in the System tab.
  ///
  /// In en, this message translates to:
  /// **'Transmit'**
  String get systemTransmit;

  /// A System tab section before the server sent its first reading for it.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first reading.'**
  String get systemWaiting;

  /// A System tab section whose reading failed because a command it runs is not installed on the server.
  ///
  /// In en, this message translates to:
  /// **'The server lacks the tool this reading needs.'**
  String get systemUnavailableMissing;

  /// A System tab section whose reading failed because the server denied permission.
  ///
  /// In en, this message translates to:
  /// **'The server refused this reading.'**
  String get systemUnavailableDenied;

  /// A System tab section whose reading the server stopped because it took too long.
  ///
  /// In en, this message translates to:
  /// **'This reading did not finish in time.'**
  String get systemUnavailableTimeout;

  /// A System tab section whose reading failed for another reason; the server's error output may follow.
  ///
  /// In en, this message translates to:
  /// **'This reading failed.'**
  String get systemUnavailableError;

  /// The Disks section when the server stopped the disk usage command because it hung, which a stale network mount causes (DSK-01).
  ///
  /// In en, this message translates to:
  /// **'Disk usage did not finish in time. A network mount (NFS or SMB) that stopped answering is the usual cause.'**
  String get systemDisksTimedOut;

  /// Under systemDisksTimedOut, when an earlier reading listed the mounts: the list below is that reading's, and none of its figures is current. time is when that reading was taken, as a date and time in the UI locale and this device's time zone, since a stale mount can keep failing for days.
  ///
  /// In en, this message translates to:
  /// **'These mounts are from the reading at {time}; their usage is unknown now.'**
  String systemDisksLastListed(DateTime time);

  /// The Disks section on a server without the timeout command, which normally stops a disk usage command that hangs (DSK-01).
  ///
  /// In en, this message translates to:
  /// **'This server has no timeout command, so a network mount that stops answering can stall disk readings.'**
  String get systemDisksNoTimeout;

  /// Checkbox in the Disks section that also lists in-memory and image filesystems such as tmpfs, overlay and squashfs, hidden by default; count is how many there are.
  ///
  /// In en, this message translates to:
  /// **'Show pseudo filesystems ({count})'**
  String systemDisksShowPseudo(int count);

  /// In place of the Disks table when the server's reading listed no filesystem, or only pseudo filesystems while they are hidden.
  ///
  /// In en, this message translates to:
  /// **'No mounts to show.'**
  String get systemDisksEmpty;

  /// Label of the device or source a filesystem is mounted from, such as /dev/sda1 or nas:/export, in a mount's details.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get systemDevice;

  /// Disks table column: where the filesystem is mounted.
  ///
  /// In en, this message translates to:
  /// **'Mount'**
  String get systemColumnMount;

  /// Disks table column: the filesystem type, such as ext4 or nfs4.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get systemColumnType;

  /// Disks table column: the space used out of the filesystem's size.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get systemColumnUsed;

  /// Disks table column: the share of the filesystem's space in use, as df reports it.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get systemColumnUse;

  /// Disks table column: the share of the filesystem's inodes (file entries) in use; a full inode table stops new files like a full disk.
  ///
  /// In en, this message translates to:
  /// **'Inodes'**
  String get systemColumnInodes;

  /// Disks table column, and label in a mount's details, shown after the disk usage command timed out: what is known of the mount's usage now.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get systemColumnUsage;

  /// A Disks table cell: the space used and the filesystem's size, both already formatted with binary units such as GiB.
  ///
  /// In en, this message translates to:
  /// **'{used} of {size}'**
  String systemUsedOf(String used, String size);

  /// A chart's screen-reader summary of one series: what it measures, its current, lowest and highest values (already formatted with their units) and its trend, one of chartTrendRising, chartTrendFalling or chartTrendSteady.
  ///
  /// In en, this message translates to:
  /// **'{label}: now {current}, lowest {lowest}, highest {highest}, {trend}'**
  String chartSeriesSummary(
    String label,
    String current,
    String lowest,
    String highest,
    String trend,
  );

  /// A chart's screen-reader summary of a series that has no sample yet.
  ///
  /// In en, this message translates to:
  /// **'{label}: no data yet'**
  String chartSeriesEmpty(String label);

  /// A chart's screen-reader summary of a series whose every sample is a value the server did not report.
  ///
  /// In en, this message translates to:
  /// **'{label}: unknown'**
  String chartSeriesUnknown(String label);

  /// Shown and read in place of a value the server did not report; never shown as zero.
  ///
  /// In en, this message translates to:
  /// **'unknown'**
  String get chartUnknownValue;

  /// The label on a chart's hatched band for a period without data because Klabautermann was not running (03 §9.5).
  ///
  /// In en, this message translates to:
  /// **'app closed'**
  String get chartGapAppClosed;

  /// The label on a chart's hatched band for a period without data because the app was in the background, where it stops sampling.
  ///
  /// In en, this message translates to:
  /// **'in background'**
  String get chartGapBackground;

  /// The label on a chart's hatched band for a period without data because the connection to the server was down.
  ///
  /// In en, this message translates to:
  /// **'disconnected'**
  String get chartGapDisconnected;

  /// The label on a chart's hatched band for a period without data because the server gave no reading while connected: the reading was lost or the server could not take it.
  ///
  /// In en, this message translates to:
  /// **'reading failed'**
  String get chartGapReadingFailed;

  /// A screen reader's description of a chart's band without data: when it began and ended, and why, one of chartGapAppClosed, chartGapBackground, chartGapDisconnected or chartGapReadingFailed.
  ///
  /// In en, this message translates to:
  /// **'No data from {start} to {end}: {reason}'**
  String chartGapSummary(DateTime start, DateTime end, String reason);

  /// A screen reader's description of a chart's band without data that has not ended: when it began and why, one of chartGapAppClosed, chartGapBackground, chartGapDisconnected or chartGapReadingFailed.
  ///
  /// In en, this message translates to:
  /// **'No data since {start}: {reason}'**
  String chartGapOngoing(DateTime start, String reason);

  /// A time label on a chart's time axis, to the minute, in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String chartTime(DateTime time);

  /// A time label on a chart's time axis, to the second, in the UI locale, for axes whose ticks are less than a minute apart.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String chartTimeWithSeconds(DateTime time);

  /// A series' trend in its screen-reader summary: it has gone up over the chart's window.
  ///
  /// In en, this message translates to:
  /// **'rising'**
  String get chartTrendRising;

  /// A series' trend in its screen-reader summary: it has gone down over the chart's window.
  ///
  /// In en, this message translates to:
  /// **'falling'**
  String get chartTrendFalling;

  /// A series' trend in its screen-reader summary: it has stayed about level over the chart's window.
  ///
  /// In en, this message translates to:
  /// **'steady'**
  String get chartTrendSteady;

  /// A chart value in percent, such as a CPU or memory share; the share arrives as a fraction from 0 to 1 and is formatted in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{share}'**
  String chartPercent(double share);

  /// A bar chart's screen-reader summary, such as a memory breakdown: what it measures, its parts (each a chartBarPart, joined by chartListSeparator) and the total they are part of, already formatted with its unit.
  ///
  /// In en, this message translates to:
  /// **'{label}: {parts} of {total}'**
  String chartBarSummary(String label, String parts, String total);

  /// One part of a bar chart in its legend and screen-reader summary: what the part measures and its value, already formatted with its unit, or chartUnknownValue.
  ///
  /// In en, this message translates to:
  /// **'{label} {value}'**
  String chartBarPart(String label, String value);

  /// Joins the parts of a bar chart's screen-reader summary, such as "CPU 42%, Memory 71%".
  ///
  /// In en, this message translates to:
  /// **', '**
  String get chartListSeparator;

  /// A bar chart part whose value has crossed a threshold, so its colour changed: the part (a chartBarPart) and chartSeverityWarning or chartSeverityCritical.
  ///
  /// In en, this message translates to:
  /// **'{part} ({severity})'**
  String chartWithSeverity(String part, String severity);

  /// A value past its warning threshold, shown in the warning colour with a warning icon.
  ///
  /// In en, this message translates to:
  /// **'warning'**
  String get chartSeverityWarning;

  /// A value past its critical threshold, shown in the critical colour with an error icon.
  ///
  /// In en, this message translates to:
  /// **'critical'**
  String get chartSeverityCritical;

  /// A bar chart's screen-reader summary while its values are stale: no new sample has arrived in time, so the bar is grey and shows the last values the server reported.
  ///
  /// In en, this message translates to:
  /// **'{summary}, stale'**
  String chartStale(String summary);

  /// Access tab: the note above the access rows saying the app only shows and copies fix commands and never runs them (CN-24).
  ///
  /// In en, this message translates to:
  /// **'Klabautermann never runs these fix commands. Copy one and run it yourself on the server.'**
  String get accessNeverRuns;

  /// Access tab: title of the notice explaining which rights equal root on the server (SAF-08).
  ///
  /// In en, this message translates to:
  /// **'Root-equivalent access'**
  String get accessRootEquivalenceTitle;

  /// Access tab: body of the root-equivalence notice (SAF-08).
  ///
  /// In en, this message translates to:
  /// **'Using a rootful Docker or Podman socket, or a broad passwordless sudo rule, gives the same power as root on this server. A rootless engine gives only the power of the user that runs it.'**
  String get accessRootEquivalenceBody;

  /// Access tab and Docker tab: shown in place of an access answer before the server's capability probe has reported.
  ///
  /// In en, this message translates to:
  /// **'Not checked yet. Klabautermann checks access after it connects to this server.'**
  String get accessNotChecked;

  /// Access tab: the reason under each row before the server's capability probe has reported; accessNotChecked explains it once above the rows.
  ///
  /// In en, this message translates to:
  /// **'Not checked yet.'**
  String get accessRowNotChecked;

  /// Access tab: the state word of a row whose right the account has.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get accessStatusOk;

  /// Access tab: the state word of a row whose right the account lacks, as far as the probe could tell.
  ///
  /// In en, this message translates to:
  /// **'Missing'**
  String get accessStatusMissing;

  /// Access tab: the state word of a row the probe could not answer yet.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get accessStatusUnknown;

  /// Access tab row title: whether sudo (or doas) runs without a password for the login account.
  ///
  /// In en, this message translates to:
  /// **'Passwordless sudo'**
  String get accessItemSudo;

  /// Access tab row title: whether the account may read the whole system journal (membership in systemd-journal or a similar group).
  ///
  /// In en, this message translates to:
  /// **'Journal group'**
  String get accessItemJournal;

  /// Access tab row title: whether the account can use a Docker or Podman engine socket.
  ///
  /// In en, this message translates to:
  /// **'Docker socket'**
  String get accessItemDockerSocket;

  /// Access tab row title: whether the SSH server allows forwarding to a Unix socket, which Docker support uses. 'Streamlocal' is OpenSSH's term; keep it.
  ///
  /// In en, this message translates to:
  /// **'Streamlocal forwarding'**
  String get accessItemStreamlocal;

  /// Access tab row title: whether the docker compose plugin is installed.
  ///
  /// In en, this message translates to:
  /// **'Compose plugin'**
  String get accessItemCompose;

  /// Access tab row title: whether the server runs systemd, and which version. 'systemd' is a product name, always lower case.
  ///
  /// In en, this message translates to:
  /// **'systemd version'**
  String get accessItemSystemd;

  /// Access tab row title: which container engines (Docker or Podman, rootful or rootless) the server has.
  ///
  /// In en, this message translates to:
  /// **'Container runtime'**
  String get accessItemRuntime;

  /// Access tab row reason: the part of the capability probe that answers this row failed.
  ///
  /// In en, this message translates to:
  /// **'The server\'s probe could not answer this.'**
  String get accessReasonProbeUnavailable;

  /// Access tab row reason: the login account is root.
  ///
  /// In en, this message translates to:
  /// **'You log in as root, so no elevation or group is needed.'**
  String get accessReasonRootLogin;

  /// Access tab row reason: sudo -n succeeded.
  ///
  /// In en, this message translates to:
  /// **'sudo runs without asking for a password.'**
  String get accessReasonSudoNoPassword;

  /// Access tab row reason: there is no sudo, and doas -n succeeded.
  ///
  /// In en, this message translates to:
  /// **'doas runs without asking for a password. sudo is not installed.'**
  String get accessReasonDoasNoPassword;

  /// Access tab row reason: sudo -n failed; the app deliberately offers no command that would make sudo passwordless.
  ///
  /// In en, this message translates to:
  /// **'sudo asks for a password, or your account may not use it. No fix is offered: a broad passwordless rule equals root.'**
  String get accessReasonSudoNotPasswordless;

  /// Access tab row reason: there is no sudo, and doas wants a password.
  ///
  /// In en, this message translates to:
  /// **'doas asks for a password, which Klabautermann cannot enter. sudo is not installed.'**
  String get accessReasonDoasNotPasswordless;

  /// Access tab row reason: the server has no elevation tool.
  ///
  /// In en, this message translates to:
  /// **'Neither sudo nor doas is installed.'**
  String get accessReasonNoElevationTool;

  /// Access tab row reason: the account is in systemd-journal, adm or wheel.
  ///
  /// In en, this message translates to:
  /// **'You are in a group that can read the whole system journal.'**
  String get accessReasonJournalGroup;

  /// Access tab row reason: journalctl silently limits the account to its own entries.
  ///
  /// In en, this message translates to:
  /// **'The journal shows only your own entries. Members of systemd-journal can read all of them.'**
  String get accessReasonNotInJournalGroup;

  /// Access tab row reason, and why a panel that needs journalctl is hidden: the probe found no journalctl command.
  ///
  /// In en, this message translates to:
  /// **'This server has no journalctl.'**
  String get accessReasonNoJournal;

  /// Access tab row reason: the account can write to a Docker or Podman socket of an engine that runs as root.
  ///
  /// In en, this message translates to:
  /// **'You can use a rootful engine socket.'**
  String get accessReasonRootfulSocket;

  /// Access tab row reason: the only engine sockets the account can write to belong to engines running as a normal user.
  ///
  /// In en, this message translates to:
  /// **'You can use rootless engine sockets only.'**
  String get accessReasonRootlessSocket;

  /// Access tab row reason: engine sockets exist, none writable for the account.
  ///
  /// In en, this message translates to:
  /// **'Engine sockets exist, but your account cannot use any of them.'**
  String get accessReasonSocketNotWritable;

  /// Access tab row reason: none of the known engine socket paths exists.
  ///
  /// In en, this message translates to:
  /// **'No Docker or Podman socket was found.'**
  String get accessReasonNoEngineSocket;

  /// Access tab row reason for streamlocal forwarding and the compose plugin, which the app checks only from the release with Docker support.
  ///
  /// In en, this message translates to:
  /// **'Checked once Docker support arrives.'**
  String get accessReasonPendingDocker;

  /// Access tab row reason: systemd 246 or later.
  ///
  /// In en, this message translates to:
  /// **'Version {version}: unit and timer lists are read in full.'**
  String accessReasonSystemdJson(int version);

  /// Access tab row reason: systemd 239 to 245, which lacks JSON output.
  ///
  /// In en, this message translates to:
  /// **'Version {version}: older than 246, so unit and timer lists are read from text output.'**
  String accessReasonSystemdTextFallback(int version);

  /// Access tab row reason: systemd older than the oldest supported release.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is older than any tested version (239).'**
  String accessReasonSystemdOlderThanTested(int version);

  /// Access tab row reason: systemd is PID 1, but its version line did not parse.
  ///
  /// In en, this message translates to:
  /// **'systemd runs, but its version could not be read.'**
  String get accessReasonSystemdVersionUnparsed;

  /// Access tab row reason, and why a panel that needs systemd is hidden: PID 1 is not systemd.
  ///
  /// In en, this message translates to:
  /// **'This server does not run systemd.'**
  String get accessReasonNotSystemd;

  /// Access tab and Docker tab: introduces the list of engine sockets found.
  ///
  /// In en, this message translates to:
  /// **'Found on this server:'**
  String get accessReasonEnginesDetected;

  /// Access tab and Docker tab: an engine command line tool exists, but no socket.
  ///
  /// In en, this message translates to:
  /// **'A docker or podman command exists, but no engine socket was found.'**
  String get accessReasonEngineCliWithoutSocket;

  /// Access tab and Docker tab: no engine socket and no engine command.
  ///
  /// In en, this message translates to:
  /// **'No Docker or Podman engine was found.'**
  String get accessReasonNoEngine;

  /// Access tab: badge beside a row whose right equals root on the server (SAF-08).
  ///
  /// In en, this message translates to:
  /// **'Root-equivalent'**
  String get accessRootEquivalentBadge;

  /// Access tab: warning shown beside the command that adds the account to the docker group (SAF-08).
  ///
  /// In en, this message translates to:
  /// **'Members of the docker group are root-equivalent. A rootless engine, which equals your user, is the safer choice.'**
  String get accessDockerGroupWarning;

  /// Access tab: note under a fix command on a server without any elevation tool.
  ///
  /// In en, this message translates to:
  /// **'Run this as root: the server has neither sudo nor doas.'**
  String get accessFixRootShell;

  /// Access tab: note under a fix command shown without a sudo or doas prefix because the server's probe did not report which elevation tool, if any, is installed.
  ///
  /// In en, this message translates to:
  /// **'Run this as root. The probe could not tell whether the server has sudo or doas.'**
  String get accessFixElevationUnknown;

  /// Access tab: note under a fix command that adds the account to a group.
  ///
  /// In en, this message translates to:
  /// **'Group changes take effect at your next login.'**
  String get accessFixNextLogin;

  /// Access tab: button that copies a fix command to the clipboard. The app never runs it.
  ///
  /// In en, this message translates to:
  /// **'Copy command'**
  String get accessFixCopy;

  /// Access tab: screen-reader name of the Copy command button; item is the title of the row whose fix it copies. Starts with the button's visible text (accessFixCopy) so voice control finds it by that text.
  ///
  /// In en, this message translates to:
  /// **'Copy command for {item}'**
  String accessFixCopyLabel(String item);

  /// Access tab: confirmation after copying a fix command, reminding that the app has not run it.
  ///
  /// In en, this message translates to:
  /// **'Copied. Run it yourself on the server.'**
  String get accessFixCopied;

  /// Access tab: shown instead of the confirmation when the system refused to put a fix command on the clipboard (on Windows, while another app holds it), so pasting now would paste older text.
  ///
  /// In en, this message translates to:
  /// **'Not copied. The clipboard still holds its earlier text; try again before you paste.'**
  String get accessFixCopyFailed;

  /// Access tab and Docker tab: an engine socket of Docker running as root.
  ///
  /// In en, this message translates to:
  /// **'Docker, rootful'**
  String get accessEngineDockerRootful;

  /// Access tab and Docker tab: an engine socket of Docker running as a normal user.
  ///
  /// In en, this message translates to:
  /// **'Docker, rootless'**
  String get accessEngineDockerRootless;

  /// Access tab and Docker tab: an engine socket of Podman running as root.
  ///
  /// In en, this message translates to:
  /// **'Podman, rootful'**
  String get accessEnginePodmanRootful;

  /// Access tab and Docker tab: an engine socket of Podman running as a normal user.
  ///
  /// In en, this message translates to:
  /// **'Podman, rootless'**
  String get accessEnginePodmanRootless;

  /// Access tab and Docker tab: one engine socket the probe found; engine is one of the accessEngine names, path is the socket's path on the server.
  ///
  /// In en, this message translates to:
  /// **'{engine} at {path}'**
  String accessEngineAt(String engine, String path);

  /// Access tab and Docker tab: the account can write to this rootful engine socket (SAF-08).
  ///
  /// In en, this message translates to:
  /// **'Your account can use it, which is root-equivalent.'**
  String get accessEngineUsableRootful;

  /// Access tab and Docker tab: the account can write to this rootless engine socket (SAF-08).
  ///
  /// In en, this message translates to:
  /// **'Your account can use it, which equals the user that runs it.'**
  String get accessEngineUsableRootless;

  /// Access tab and Docker tab: the account cannot write to this engine socket.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot use it.'**
  String get accessEngineNotUsable;

  /// Access tab and Docker tab: note under a socket at Docker's path, which a podman-docker install may serve.
  ///
  /// In en, this message translates to:
  /// **'Podman can also answer on Docker\'s socket path. Docker support will tell them apart.'**
  String get accessRuntimeAlias;

  /// Shown instead of a server panel that cannot work with this server or account; panel is the panel's tab name.
  ///
  /// In en, this message translates to:
  /// **'{panel} is not available on this server'**
  String accessPanelHiddenTitle(String panel);

  /// Why a panel is hidden: it needs read access to the whole system journal.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot read the whole journal.'**
  String get accessNeedJournalAccess;

  /// Why a panel is hidden: it needs the dmesg command.
  ///
  /// In en, this message translates to:
  /// **'dmesg is not available.'**
  String get accessNeedDmesg;

  /// Why a panel is hidden: it needs the tail command.
  ///
  /// In en, this message translates to:
  /// **'This server has no tail command.'**
  String get accessNeedTail;

  /// Why a panel is hidden: it needs the crontab command.
  ///
  /// In en, this message translates to:
  /// **'This server has no crontab command.'**
  String get accessNeedCrontab;

  /// Button under a hidden panel's reasons and on the Docker tab: shows the Access tab, which lists the account's rights on the server and how to fix them.
  ///
  /// In en, this message translates to:
  /// **'Open Access'**
  String get accessOpen;

  /// Title of the Access screen pushed on phones; name is the server's display name.
  ///
  /// In en, this message translates to:
  /// **'Access on {name}'**
  String accessPageTitle(String name);

  /// A table cell as a screen reader hears it within its row: the column's header label, then the cell's value (A11Y-03).
  ///
  /// In en, this message translates to:
  /// **'{column}: {value}'**
  String tableCellSemantics(String column, String value);

  /// Screen-reader value of the table column header the rows are sorted by, smallest first.
  ///
  /// In en, this message translates to:
  /// **'Sorted ascending'**
  String get tableSortedAscending;

  /// Screen-reader value of the table column header the rows are sorted by, largest first.
  ///
  /// In en, this message translates to:
  /// **'Sorted descending'**
  String get tableSortedDescending;

  /// Screen-reader hint of a table column header that sorts the rows when activated.
  ///
  /// In en, this message translates to:
  /// **'Sort by this column'**
  String get tableSortHint;

  /// Tooltip and screen-reader label of the button at the end of a table row that opens the row's actions.
  ///
  /// In en, this message translates to:
  /// **'Row actions'**
  String get tableRowActions;

  /// Screen-reader name of a log view, the scrolling list of a server's log lines.
  ///
  /// In en, this message translates to:
  /// **'Log'**
  String get logViewLabel;

  /// Button shown while a log view is paused: scrolls to the newest line and keeps it in sight as lines arrive (LOG-02).
  ///
  /// In en, this message translates to:
  /// **'Follow'**
  String get logFollow;

  /// Spoken name of the icon beside a log line logged as an error or worse.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get logLevelError;

  /// Spoken name of the icon beside a log line logged as a warning.
  ///
  /// In en, this message translates to:
  /// **'Warning'**
  String get logLevelWarning;

  /// Spoken name of the icon beside a log line logged as debug output.
  ///
  /// In en, this message translates to:
  /// **'Debug'**
  String get logLevelDebug;

  /// A row in a log view where lines arrived faster than the view could keep and were left out; count is how many.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 line dropped here} other{{count} lines dropped here}}'**
  String logDroppedLines(int count);

  /// Note after a log line too long to keep whole; total is the full line's length.
  ///
  /// In en, this message translates to:
  /// **'[line cut: {total} characters in all]'**
  String logLineCut(int total);

  /// Stands in for a journal message or field value the server did not send because it is larger than 4,096 bytes.
  ///
  /// In en, this message translates to:
  /// **'[not sent: over 4,096 bytes]'**
  String get logJournalNotSent;

  /// Row of a journal entry's expanded fields for a field whose value the server did not send because it is larger than 4,096 bytes; name is the journal field's name as the server sent it, such as CODE_LINE.
  ///
  /// In en, this message translates to:
  /// **'{name} [not sent: over 4,096 bytes]'**
  String logJournalFieldNotSent(String name);

  /// Last row of a journal entry's expanded fields when the log view kept only some of them; count is how many it left out.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more field not kept} other{{count} more fields not kept}}'**
  String logJournalFieldsLeftOut(int count);

  /// Screen-reader hint for activating a journal row: shows all of the entry's journal fields beneath it.
  ///
  /// In en, this message translates to:
  /// **'Show fields'**
  String get logJournalShowFields;

  /// Screen-reader hint for activating a journal row that shows its fields: hides them again.
  ///
  /// In en, this message translates to:
  /// **'Hide fields'**
  String get logJournalHideFields;

  /// Services panel: shown until the server's first list of systemd units arrives.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first list of units…'**
  String get servicesWaiting;

  /// Services panel: the server lacks the systemctl tool, as on a system without systemd.
  ///
  /// In en, this message translates to:
  /// **'This server has no systemctl, so there are no units to list.'**
  String get servicesUnavailableMissing;

  /// Services panel: listing systemd units failed with a permission error.
  ///
  /// In en, this message translates to:
  /// **'The server refused to list its units.'**
  String get servicesUnavailableDenied;

  /// Services panel: the unit listing ran past its time limit on the server.
  ///
  /// In en, this message translates to:
  /// **'Listing units took too long and was stopped.'**
  String get servicesUnavailableTimeout;

  /// Services panel: listing systemd units failed for another reason; the server's error output may follow.
  ///
  /// In en, this message translates to:
  /// **'Listing units failed.'**
  String get servicesUnavailableError;

  /// Services panel notice for old systemd, whose unit list has no JSON output (CN-10).
  ///
  /// In en, this message translates to:
  /// **'This server\'s systemd is older than version 246, so units are read from text. States that could not be read show as unknown.'**
  String get servicesTextFallback;

  /// Label of the Services panel's filter by unit type, such as service or socket.
  ///
  /// In en, this message translates to:
  /// **'Type'**
  String get servicesFilterType;

  /// The unit type filter's choice that shows units of every type.
  ///
  /// In en, this message translates to:
  /// **'All types'**
  String get servicesFilterTypeAll;

  /// Label of the Services panel's filter by a unit's active state, such as active or failed.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get servicesFilterState;

  /// The unit state filter's choice that shows units in every state.
  ///
  /// In en, this message translates to:
  /// **'All states'**
  String get servicesFilterStateAll;

  /// Services panel: the unit list is empty under the chosen type and state filters.
  ///
  /// In en, this message translates to:
  /// **'No units match these filters.'**
  String get servicesEmpty;

  /// Column header of the unit list: the systemd unit's name.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get servicesColumnUnit;

  /// Column header and label: whether systemd loaded the unit's configuration (its load state).
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get servicesColumnLoad;

  /// Column header and label: the unit's high-level state, such as active, inactive or failed (its active state).
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get servicesColumnActive;

  /// Column header and label: the unit's detailed state, such as running or exited (its sub state).
  ///
  /// In en, this message translates to:
  /// **'Sub'**
  String get servicesColumnSub;

  /// Column header of the unit list: the unit's description from its configuration.
  ///
  /// In en, this message translates to:
  /// **'Description'**
  String get servicesColumnDescription;

  /// Heading of the failed units summary (SVC-02); count is how many systemd units failed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No failed units} =1{1 failed unit} other{{count} failed units}}'**
  String servicesFailedCount(int count);

  /// One failed unit in the failed units summary: its name, then its detailed (sub) state as the server reports it, or the word for unknown.
  ///
  /// In en, this message translates to:
  /// **'{unit}: {state}'**
  String servicesFailedUnit(String unit, String state);

  /// Last line of the failed units summary when it lists only some of them; count is how many it leaves out.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{and 1 more} other{and {count} more}}'**
  String servicesFailedMore(int count);

  /// Tooltip of the button that closes a unit's details and returns to the unit list.
  ///
  /// In en, this message translates to:
  /// **'Close unit details'**
  String get servicesUnitClose;

  /// Heading of a unit's recent journal lines on its details (SVC-04), and under the unit's name in the sheet that shows them on a phone.
  ///
  /// In en, this message translates to:
  /// **'Recent log lines'**
  String get servicesLogsTitle;

  /// Button on a unit's details on a phone that opens its recent journal lines in a bottom sheet (SVC-04, PLT-02).
  ///
  /// In en, this message translates to:
  /// **'Show recent log lines'**
  String get servicesLogsShow;

  /// Tooltip of the button that closes the bottom sheet of a unit's recent journal lines on a phone.
  ///
  /// In en, this message translates to:
  /// **'Close log lines'**
  String get servicesLogsClose;

  /// A unit's log lines were requested and the app has no answer yet.
  ///
  /// In en, this message translates to:
  /// **'Asking the server for recent log lines…'**
  String get servicesLogsRequested;

  /// A unit's log read waits until the connection to the server is ready.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the connection to the server…'**
  String get servicesLogsWaitingLink;

  /// A unit's log read waits until the connection has a free session for it.
  ///
  /// In en, this message translates to:
  /// **'Waiting for a free session on the server…'**
  String get servicesLogsWaitingChannel;

  /// A unit's log read waits until the app returns to the foreground.
  ///
  /// In en, this message translates to:
  /// **'Paused while the app is in the background.'**
  String get servicesLogsWaitingBackground;

  /// A unit's log read is running on the server.
  ///
  /// In en, this message translates to:
  /// **'Reading recent log lines…'**
  String get servicesLogsReading;

  /// A unit's log read finished without any journal line.
  ///
  /// In en, this message translates to:
  /// **'The journal holds no lines for this unit.'**
  String get servicesLogsEmpty;

  /// The app's engine cannot read logs yet and refused the request; no log lines are shown.
  ///
  /// In en, this message translates to:
  /// **'Reading unit logs is not available in this version yet.'**
  String get servicesLogsRefused;

  /// The app's engine, which starts once per launch, stopped before answering the unit-log read; no log lines are shown until the app restarts.
  ///
  /// In en, this message translates to:
  /// **'The app\'s engine stopped. Restart the app to read unit logs.'**
  String get servicesLogsEngineStopped;

  /// The app refused to read logs for a unit name that fails its validation.
  ///
  /// In en, this message translates to:
  /// **'This unit\'s name cannot be used to read its logs.'**
  String get servicesLogsInvalid;

  /// A unit's log read failed because the server lacks journalctl.
  ///
  /// In en, this message translates to:
  /// **'This server has no journalctl, so unit logs cannot be read.'**
  String get servicesLogsMissing;

  /// A unit's log read failed with a permission error.
  ///
  /// In en, this message translates to:
  /// **'The server refused to read this unit\'s journal.'**
  String get servicesLogsDenied;

  /// A unit's log read failed for another reason; the server's error output may follow.
  ///
  /// In en, this message translates to:
  /// **'Reading this unit\'s journal failed.'**
  String get servicesLogsFailed;

  /// Label of the Logs panel's source picker, which chooses between the journal, the kernel log and a file; also the title of the phone's source sheet.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get logsPanelSource;

  /// Name of a Logs panel source: the systemd journal, the kernel's messages, or one file on the server.
  ///
  /// In en, this message translates to:
  /// **'{source, select, journal{Journal} kernel{Kernel} other{File}}'**
  String logsPanelSourceName(String source);

  /// Label of the Logs panel's filter field for a systemd unit name.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get logsPanelUnit;

  /// Label of the Logs panel's filter field for a syslog identifier (the program's syslog tag).
  ///
  /// In en, this message translates to:
  /// **'Identifier'**
  String get logsPanelIdentifier;

  /// Label of the Logs panel's priority filter, which shows entries at a syslog priority or more urgent.
  ///
  /// In en, this message translates to:
  /// **'Priority'**
  String get logsPanelPriority;

  /// Priority filter choice that shows entries of every priority.
  ///
  /// In en, this message translates to:
  /// **'Any priority'**
  String get logsPanelPriorityAny;

  /// Priority filter choice: entries at this syslog priority or more urgent ones.
  ///
  /// In en, this message translates to:
  /// **'{level, select, emergency{Emergency} alert{Alert and above} critical{Critical and above} error{Error and above} warning{Warning and above} notice{Notice and above} info{Info and above} other{Debug and above}}'**
  String logsPanelPriorityLevel(String level);

  /// Toggle of the Logs panel's journal filters that shows only entries since the server last started.
  ///
  /// In en, this message translates to:
  /// **'Current boot only'**
  String get logsPanelCurrentBoot;

  /// Label of the Logs panel's time range filter.
  ///
  /// In en, this message translates to:
  /// **'Time range'**
  String get logsPanelTimeRange;

  /// Time range filter choice: how far back entries are shown, counted from when the log opens.
  ///
  /// In en, this message translates to:
  /// **'{range, select, last15Minutes{Last 15 minutes} lastHour{Last hour} last24Hours{Last 24 hours} last7Days{Last 7 days} other{Any time}}'**
  String logsPanelTimeRangeOption(String range);

  /// Label of the Logs panel's field for the file on the server to tail.
  ///
  /// In en, this message translates to:
  /// **'File path'**
  String get logsPanelPath;

  /// Hint in the empty file path field.
  ///
  /// In en, this message translates to:
  /// **'Absolute path, such as /var/log/syslog'**
  String get logsPanelPathHint;

  /// Error under the file path field when the server would refuse the path.
  ///
  /// In en, this message translates to:
  /// **'{problem, select, notAbsolute{Enter an absolute path that starts with /.} notNormalized{Remove the . and .. parts from the path.} other{The path contains a NUL character.}}'**
  String logsPanelPathProblem(String problem);

  /// Tooltip of the button beside the file path field that lists common log files, such as the syslog and web server logs.
  ///
  /// In en, this message translates to:
  /// **'Common paths'**
  String get logsPanelCommonPaths;

  /// Button that reads the log again with the filters or path entered.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get logsPanelApply;

  /// Phone button that opens the Logs panel's filters in a sheet; count is how many filters are set.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Filters} other{Filters ({count})}}'**
  String logsPanelFilters(int count);

  /// Chip that turns following new log entries on and off, naming what the log stream is doing: following, waiting for the server or a free session, waiting for the connection, paused by the user or the app's background, ended, or not available.
  ///
  /// In en, this message translates to:
  /// **'{state, select, live{Live} connecting{Connecting} disconnected{Disconnected} paused{Paused} stopped{Stopped} other{Unavailable}}'**
  String logsPanelLiveState(String state);

  /// Tooltip of the Logs panel's Live chip.
  ///
  /// In en, this message translates to:
  /// **'Follow new entries as the server writes them'**
  String get logsPanelLiveTooltip;

  /// Notice above the journal when the server shows the signed-in account only its own entries. The group names are names on the server and stay as they are.
  ///
  /// In en, this message translates to:
  /// **'Only your own journal entries are shown: your account on this server is not in the systemd-journal, adm or wheel group. The server\'s Access section shows how to add it.'**
  String get logsPanelJournalLimited;

  /// Notice above the kernel log when the server's journal shows the signed-in account only its own entries, which never include kernel messages. The group names are names on the server and stay as they are.
  ///
  /// In en, this message translates to:
  /// **'Kernel messages may be missing: your account on this server is not in the systemd-journal, adm or wheel group, so the journal shows it none. The server\'s Access section shows how to add it.'**
  String get logsPanelKernelLimited;

  /// Status line above the log saying what reading it is doing or why it stopped.
  ///
  /// In en, this message translates to:
  /// **'{status, select, opening{Opening the log…} waitingLink{Waiting for the connection to the server.} waitingChannel{Waiting for a free session on the server.} waitingBackground{Paused while the app is in the background.} gap{Following again. Lines written while it was paused or disconnected may be missing.} loading{Loading entries…} invalid{The engine refused this filter or path.} missing{The server has no such file or log tool.} denied{The server denied access to this log.} failed{Reading the log failed.} rejected{The engine did not open this log.} other{Choose or type the absolute path of a file to tail.}}'**
  String logsPanelStatus(String status);

  /// Button that opens the log again after it stopped or was refused.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get logsPanelRetry;

  /// Shown in place of the log when reading a kernel log, a file or an unfiltered journal finished without any entry, unless the kernel log or journal is limited to the account's own entries.
  ///
  /// In en, this message translates to:
  /// **'This log has no entries.'**
  String get logsPanelEmpty;

  /// Shown in place of the log when reading the journal with filters set finished without any entry.
  ///
  /// In en, this message translates to:
  /// **'No entries match these filters.'**
  String get logsPanelEmptyFiltered;

  /// Shown in place of the log when reading an unfiltered journal or the kernel log finished without any entry while the server shows the signed-in account only its own journal entries.
  ///
  /// In en, this message translates to:
  /// **'No entries are visible to your account.'**
  String get logsPanelEmptyLimited;

  /// Label of the log search field, also its name for screen readers once it holds text; the search covers the entries the panel holds, not the whole log on the server.
  ///
  /// In en, this message translates to:
  /// **'Search loaded entries'**
  String get logsPanelSearchLabel;

  /// Tooltip of the toggle that makes the log search tell upper from lower case.
  ///
  /// In en, this message translates to:
  /// **'Match case'**
  String get logsPanelSearchCase;

  /// How many matches the log search found, before one is selected.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =0{No matches} =1{1 match} other{{total} matches}}'**
  String logsPanelSearchMatches(int total);

  /// Which match of the log search is selected, out of how many.
  ///
  /// In en, this message translates to:
  /// **'{current} of {total}'**
  String logsPanelSearchPosition(int current, int total);

  /// Tooltip of the button that moves to the previous log search match.
  ///
  /// In en, this message translates to:
  /// **'Previous match'**
  String get logsPanelSearchPrevious;

  /// Tooltip of the button that moves to the next log search match.
  ///
  /// In en, this message translates to:
  /// **'Next match'**
  String get logsPanelSearchNext;

  /// The server header's detected container runtime (CN-09), read-only: the engines the probe found, such as "Docker, rootful", joined by overviewHeaderRuntimeSeparator.
  ///
  /// In en, this message translates to:
  /// **'Runtime: {engines}'**
  String overviewHeaderRuntime(String engines);

  /// overviewHeaderRuntime when an engine was found at Docker's socket path: the engine is named from the path alone, and a podman-docker install may serve that path, as the Access tab notes (accessRuntimeAlias).
  ///
  /// In en, this message translates to:
  /// **'Runtime: {engines} (Podman can also answer on Docker\'s socket path)'**
  String overviewHeaderRuntimeDockerPath(String engines);

  /// Between two engines in overviewHeaderRuntime; each engine's own words already hold a comma.
  ///
  /// In en, this message translates to:
  /// **'; '**
  String get overviewHeaderRuntimeSeparator;

  /// The server header's detected container runtime when the probe found no Docker or Podman engine socket.
  ///
  /// In en, this message translates to:
  /// **'Runtime: none found'**
  String get overviewHeaderRuntimeNone;

  /// The server header's detected container runtime when the probe could not tell.
  ///
  /// In en, this message translates to:
  /// **'Runtime: unknown'**
  String get overviewHeaderRuntimeUnknown;

  /// The server header's detected container runtime before the server's capability probe has reported.
  ///
  /// In en, this message translates to:
  /// **'Runtime: not checked yet'**
  String get overviewHeaderRuntimeNotChecked;

  /// The Overview tab before the server sent its first reading.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first reading.'**
  String get overviewWaiting;

  /// Why the Overview tab's latest reading has no values; the values of the last reading, if any, stay shown below it.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, missing{The server lacks a file or tool this reading needs.} denied{The server refused this reading.} timeout{This reading took too long, so the server stopped it.} other{This reading failed on the server.}}'**
  String overviewUnavailable(String reason);

  /// An Overview value the server did not report, or that is not shown for a reason given beside it; never shown as zero.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get overviewUnknown;

  /// Reason in an Overview card whose figures are unknown: in a container, the system file they come from shows the host's figures instead of the container's (SYS-04).
  ///
  /// In en, this message translates to:
  /// **'Inside this container these figures would be the host\'s, so they are not shown.'**
  String get overviewUnknownContainer;

  /// Reason in the Overview's Load card when only the load per core is unknown: in a container, the CPU count would be the host's while the load averages are the container's own (SYS-04).
  ///
  /// In en, this message translates to:
  /// **'Inside this container the core count would be the host\'s, so the load per core is not shown.'**
  String get overviewUnknownContainerLoadPerCore;

  /// Heading of the Overview's CPU card (OV-01), also the name its chart summaries give.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get overviewCpuTitle;

  /// The CPU gauge's part: the share of time the CPUs were busy (not idle or waiting on I/O).
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get overviewCpuBusy;

  /// CPU-01: the share of CPU time spent in user programs.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get overviewCpuUser;

  /// CPU-01: the share of CPU time spent in the kernel.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get overviewCpuSystem;

  /// CPU-01: the share of CPU time spent idle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get overviewCpuIdle;

  /// CPU-02: heading over each core's busy share.
  ///
  /// In en, this message translates to:
  /// **'Per core'**
  String get overviewPerCoreTitle;

  /// Heading of the Overview's load card (CPU-03): the load averages.
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get overviewLoadTitle;

  /// The one-minute load average's label.
  ///
  /// In en, this message translates to:
  /// **'1 min'**
  String get overviewLoad1;

  /// The five-minute load average's label.
  ///
  /// In en, this message translates to:
  /// **'5 min'**
  String get overviewLoad5;

  /// The fifteen-minute load average's label.
  ///
  /// In en, this message translates to:
  /// **'15 min'**
  String get overviewLoad15;

  /// The one-minute load divided by the number of CPUs (CPU-03's core context).
  ///
  /// In en, this message translates to:
  /// **'Per core'**
  String get overviewLoadPerCore;

  /// A load average in the UI locale's number format, with two decimals.
  ///
  /// In en, this message translates to:
  /// **'{load}'**
  String overviewLoadValue(double load);

  /// Heading of the Overview's memory card (MEM-01), also the name its chart summaries give.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get overviewMemoryTitle;

  /// Used memory or swap: for memory, the installed memory less what is available.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get overviewMemoryUsed;

  /// MEM-01: memory the kernel uses as block-device buffers.
  ///
  /// In en, this message translates to:
  /// **'Buffers'**
  String get overviewMemoryBuffers;

  /// MEM-01: memory holding the page cache and reclaimable kernel caches.
  ///
  /// In en, this message translates to:
  /// **'Cache'**
  String get overviewMemoryCache;

  /// MEM-01 and MEM-02: the server's installed memory, or the swap space it has set up.
  ///
  /// In en, this message translates to:
  /// **'Total'**
  String get overviewMemoryTotal;

  /// MEM-01: memory available to new programs without swapping.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get overviewMemoryAvailable;

  /// MEM-01: shared memory, mostly tmpfs, which is part of the cache.
  ///
  /// In en, this message translates to:
  /// **'Shared'**
  String get overviewMemoryShared;

  /// MEM-01: on a server with ZFS, its cache (the ARC) is counted in used memory, so used reads higher than the memory programs hold. ZFS and ARC are kept as written.
  ///
  /// In en, this message translates to:
  /// **'ZFS ARC counted as used'**
  String get overviewMemoryArc;

  /// Heading of the Overview's swap card (MEM-02), also the name its chart summaries give.
  ///
  /// In en, this message translates to:
  /// **'Swap'**
  String get overviewSwapTitle;

  /// The swap card of a server with no swap space.
  ///
  /// In en, this message translates to:
  /// **'No swap is set up.'**
  String get overviewSwapNone;

  /// The Jobs tab before the server's cron jobs or timers have been read.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first reading.'**
  String get jobsWaiting;

  /// The Jobs tab when every source it reads was read and none holds a job: the login user's crontab (crontab -l), /etc/crontab, /etc/cron.d and the cron.<period> directories, and systemd timers. Other users' crontabs are not read. crontab is read; unread when crontab -l gave no clear answer, so the user's own jobs are unknown; or absent on a server without the crontab command. timers is read, or absent on a server that does not run systemd.
  ///
  /// In en, this message translates to:
  /// **'{crontab, select, read{{timers, select, read{No jobs found in your crontab, the system cron files or systemd timers.} other{No jobs found in your crontab or the system cron files.}}} other{{timers, select, read{No jobs found in the system cron files or systemd timers.} other{No jobs found in the system cron files.}}}}'**
  String jobsEmpty(String crontab, String timers);

  /// Above the jobs list in place of a failed timers reading, when the server's probe found systemd not running.
  ///
  /// In en, this message translates to:
  /// **'This server does not run systemd, so it has no timers.'**
  String get jobsNoSystemd;

  /// Why the Jobs tab's latest cron or timers reading has no rows; the rows of the last reading, if any, stay listed below it.
  ///
  /// In en, this message translates to:
  /// **'{source, select, cron{Cron jobs} other{Timers}} could not be read: {reason, select, missing{the server lacks a file or tool this reading needs.} denied{the server refused this reading.} timeout{this reading took too long, so the server stopped it.} other{this reading failed on the server.}}'**
  String jobsUnavailable(String source, String reason);

  /// The Jobs tab when the server's answer to crontab -l for the login user was unclear, unless the server's probe found no crontab command.
  ///
  /// In en, this message translates to:
  /// **'Your own crontab could not be read, so its jobs may be missing.'**
  String get jobsOwnCrontabUnknown;

  /// Above the jobs list: cron run times follow the rules of the server's time zone, named by its IANA name (server data, as written).
  ///
  /// In en, this message translates to:
  /// **'Cron times are in {zone}, the server\'s time zone.'**
  String jobsZoneRules(String zone);

  /// Above the jobs list: cron run times use the UTC offset the server reported, without its zone's DST rules, and why. offset is jobsUtcOffset.
  ///
  /// In en, this message translates to:
  /// **'Cron times are at the server\'s offset now, {offset}, {reason, select, noZoneName{as it reported no time zone name} unknownZone{as this device does not know its time zone} other{as its time zone name and offset disagree}}, so later DST changes do not show.'**
  String jobsZoneFixed(String offset, String reason);

  /// Above the jobs list: a systemd timer's next run is shown at the UTC offset the server reported, since this version receives no offset per run. offset is jobsUtcOffset.
  ///
  /// In en, this message translates to:
  /// **'Timer times are at the server\'s offset now, {offset}; a DST change before a run does not show.'**
  String jobsTimerZone(String offset);

  /// Above the jobs list: before the server has reported its UTC offset, timers' next runs are shown in UTC.
  ///
  /// In en, this message translates to:
  /// **'Timer times are in UTC, as the server\'s offset is not known yet.'**
  String get jobsTimerZoneUtc;

  /// Jobs table column: a cron line's command, a periodic script's name or a timer's unit name, all as the server wrote them.
  ///
  /// In en, this message translates to:
  /// **'Job'**
  String get jobsColumnJob;

  /// Jobs table column and detail label: the crontab, cron directory or systemd timer a job comes from, and the user it runs as where known.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get jobsColumnSource;

  /// Jobs table column and detail label: when a job runs, in words.
  ///
  /// In en, this message translates to:
  /// **'Schedule'**
  String get jobsColumnSchedule;

  /// Jobs table column: a job's next run in the server's time.
  ///
  /// In en, this message translates to:
  /// **'Next run'**
  String get jobsColumnNext;

  /// A job's next run in the jobs table: a date and time on the clock of the server's time zone (or the line's CRON_TZ zone).
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String jobsNextRun(DateTime time);

  /// A cron line's next run in the jobs table when its CRON_TZ names its own zone: time is jobsNextRun, zone the IANA name as written.
  ///
  /// In en, this message translates to:
  /// **'{time} in {zone}'**
  String jobsRunInZone(String time, String zone);

  /// A job's next run in the jobs table with the UTC offset it is shown at (jobsUtcOffset): a systemd timer's at the server's offset now, or UTC before it is known; or, when the row's cron lines follow different time zones, the date and time on the clock of the zone this run follows, then that zone's offset at the run.
  ///
  /// In en, this message translates to:
  /// **'{time} {offset}'**
  String jobsNextRunAtOffset(DateTime time, String offset);

  /// A job's next run in the jobs table when a DST change skips, repeats or nears its time; time is jobsNextRun, jobsRunInZone or jobsNextRunAtOffset, and the job's details say what the change does.
  ///
  /// In en, this message translates to:
  /// **'{time} (DST)'**
  String jobsNextRunDst(String time);

  /// One run in a job's details: the date and time on the zone's clock, then that zone's UTC offset at the run (jobsUtcOffset).
  ///
  /// In en, this message translates to:
  /// **'{time} {offset}'**
  String jobsRunTime(DateTime time, String offset);

  /// A UTC offset: sign is zero, minus or plus, and time the size of the offset in hours and minutes.
  ///
  /// In en, this message translates to:
  /// **'{sign, select, zero{UTC} minus{UTC−{time}} other{UTC+{time}}}'**
  String jobsUtcOffset(String sign, DateTime time);

  /// Source of a job in the login user's own crontab (crontab -l).
  ///
  /// In en, this message translates to:
  /// **'Your crontab'**
  String get jobsSourceOwnCrontab;

  /// Source of a job in a system crontab: the file path, then the user its line names; both are server data.
  ///
  /// In en, this message translates to:
  /// **'{source}, as {user}'**
  String jobsSourceAsUser(String source, String user);

  /// Source of a job that is a systemd timer unit.
  ///
  /// In en, this message translates to:
  /// **'systemd timer'**
  String get jobsSourceTimer;

  /// Schedule of a systemd timer: this version reads no timer's OnCalendar or monotonic triggers or its RandomizedDelaySec, so they are unknown; its next run comes from systemd's own timer list.
  ///
  /// In en, this message translates to:
  /// **'Triggers are not read in this version.'**
  String get jobsTimerTriggersUnread;

  /// Label of a cron line's schedule fields exactly as the crontab writes them, in a job's details.
  ///
  /// In en, this message translates to:
  /// **'As written'**
  String get jobsDetailsWritten;

  /// Label of the unit a systemd timer starts, in its details.
  ///
  /// In en, this message translates to:
  /// **'Starts'**
  String get jobsDetailsStarts;

  /// Heading of a job's upcoming runs in its details.
  ///
  /// In en, this message translates to:
  /// **'Next runs'**
  String get jobsDetailsNextRuns;

  /// A cron schedule in words; schedule joins its field phrases (jobsCronMinute and the others) with jobsPhrasePair.
  ///
  /// In en, this message translates to:
  /// **'Runs {schedule}'**
  String jobsScheduleCron(String schedule);

  /// A cron schedule written as an @ macro (crontab(5)); macro is its name without the @, and other is @hourly.
  ///
  /// In en, this message translates to:
  /// **'{macro, select, reboot{Runs when cron starts} yearly{Runs once a year, at midnight on 1 January} annually{Runs once a year, at midnight on 1 January} monthly{Runs once a month, at midnight on the 1st} weekly{Runs once a week, at midnight on Sunday} daily{Runs every day at midnight} midnight{Runs every day at midnight} other{Runs every hour, on the hour}}'**
  String jobsScheduleCronMacro(String macro);

  /// A cron schedule whose line sets CRON_TZ: the schedule in words, then the zone's IANA name as written.
  ///
  /// In en, this message translates to:
  /// **'{schedule} ({zone} time)'**
  String jobsScheduleInZone(String schedule, String zone);

  /// A systemd timer's OnCalendar trigger: expression is systemd's normalized calendar expression, shown verbatim.
  ///
  /// In en, this message translates to:
  /// **'On calendar {expression}'**
  String jobsScheduleCalendar(String expression);

  /// A systemd timer's monotonic trigger: base names its setting (OnActiveSec, OnBootSec, OnStartupSec, OnUnitActiveSec, and other for OnUnitInactiveSec); span is jobsSpan text.
  ///
  /// In en, this message translates to:
  /// **'{base, select, active{{span} after the timer starts} boot{{span} after boot} startup{{span} after systemd starts} unitActive{{span} after the job last started} other{{span} after the job last finished}}'**
  String jobsScheduleMonotonic(String base, String span);

  /// A cron schedule's minute field in words. shape picks how the field is written: all is *, step is */n where n divides the field's cycle (runs an even interval apart), rangeStep is a-b/n or any other */n (*/45 minutes runs at :00 and :45), value is one value, other is a list (items) of values, ranges (jobsCronRange) and steps (jobsCronItemStep). step is n; first and last are the range ends.
  ///
  /// In en, this message translates to:
  /// **'{shape, select, all{every minute} step{every {step} minutes} rangeStep{every {step} minutes from minute {first} to {last}} value{at minute {items}} other{at minutes {items}}}'**
  String jobsCronMinute(
    String shape,
    String items,
    int step,
    String first,
    String last,
  );

  /// A cron schedule's hour field in words, hours counted 0 to 23. shape picks how the field is written: all is *, step is */n where n divides the field's cycle (runs an even interval apart), rangeStep is a-b/n or any other */n (*/45 minutes runs at :00 and :45), value is one value, other is a list (items) of values, ranges (jobsCronRange) and steps (jobsCronItemStep). step is n; first and last are the range ends.
  ///
  /// In en, this message translates to:
  /// **'{shape, select, all{every hour} step{every {step} hours} rangeStep{every {step} hours from hour {first} to {last}} value{during hour {items}} other{during hours {items}}}'**
  String jobsCronHour(
    String shape,
    String items,
    int step,
    String first,
    String last,
  );

  /// A cron schedule's day-of-month field in words; never all, which says nothing. shape picks how the field is written: all is *, rangeStep is a-b/n or */n (a month's length varies, so no step is even), value is one value, other is a list (items) of values, ranges (jobsCronRange) and steps (jobsCronItemStep). step is n; first and last are the range ends.
  ///
  /// In en, this message translates to:
  /// **'{shape, select, rangeStep{every {step} days of the month from day {first} to {last}} value{on day {items} of the month} other{on days {items} of the month}}'**
  String jobsCronDayOfMonth(
    String shape,
    String items,
    int step,
    String first,
    String last,
  );

  /// A cron schedule's month field in words, months by name; never all. shape picks how the field is written: all is *, step is */n where n divides the field's cycle (runs an even interval apart), rangeStep is a-b/n or any other */n (*/45 minutes runs at :00 and :45), value is one value, other is a list (items) of values, ranges (jobsCronRange) and steps (jobsCronItemStep). step is n; first and last are the range ends.
  ///
  /// In en, this message translates to:
  /// **'{shape, select, step{every {step} months} rangeStep{every {step} months from {first} to {last}} other{in {items}}}'**
  String jobsCronMonth(
    String shape,
    String items,
    int step,
    String first,
    String last,
  );

  /// A cron schedule's day-of-week field in words, days by name; never all. shape picks how the field is written: all is *, step is */n where n divides the field's cycle (runs an even interval apart), rangeStep is a-b/n or any other */n (*/45 minutes runs at :00 and :45), value is one value, other is a list (items) of values, ranges (jobsCronRange) and steps (jobsCronItemStep). step is n; first and last are the range ends.
  ///
  /// In en, this message translates to:
  /// **'{shape, select, step{every {step} days of the week} rangeStep{every {step} days of the week from {first} to {last}} other{on {items}}}'**
  String jobsCronDayOfWeek(
    String shape,
    String items,
    int step,
    String first,
    String last,
  );

  /// A cron schedule's stepped hour field (*/n or a-b/n) beside a minute field that itself repeats, such as every 15 minutes: the hours it runs in, counted 0 to 23, so it does not read as a second schedule. first and last are the range ends, step is n.
  ///
  /// In en, this message translates to:
  /// **'during hours {first} to {last} in steps of {step}'**
  String jobsCronHoursStepped(String first, String last, int step);

  /// A cron schedule's minute and hour fields as clock times when both hold single values only; times is a list (jobsListPair, jobsListMore).
  ///
  /// In en, this message translates to:
  /// **'at {times}'**
  String jobsCronTimes(String times);

  /// A range item in a cron field list, as in minutes 0 to 30 or Monday to Friday.
  ///
  /// In en, this message translates to:
  /// **'{first} to {last}'**
  String jobsCronRange(String first, String last);

  /// A step item in a cron field list, as in at minutes 5 and every 10 from 20 to 59.
  ///
  /// In en, this message translates to:
  /// **'every {step} from {first} to {last}'**
  String jobsCronItemStep(int step, String first, String last);

  /// Both day fields of a cron schedule are restricted, so a day matching either runs the job (crontab(5)); dom is jobsCronDayOfMonth, dow jobsCronDayOfWeek.
  ///
  /// In en, this message translates to:
  /// **'{dom} or {dow}'**
  String jobsCronDaysEither(String dom, String dow);

  /// One day field of a cron schedule starts with * but steps, so a day must match both (crontab(5)); dom is jobsCronDayOfMonth, dow jobsCronDayOfWeek.
  ///
  /// In en, this message translates to:
  /// **'{dom}, but only {dow}'**
  String jobsCronDaysBoth(String dom, String dow);

  /// Joins two phrases of one schedule in words, such as its times and its days.
  ///
  /// In en, this message translates to:
  /// **'{first}, {second}'**
  String jobsPhrasePair(String first, String second);

  /// The last two items of a list in a schedule in words.
  ///
  /// In en, this message translates to:
  /// **'{first} and {second}'**
  String jobsListPair(String first, String second);

  /// An item of a list in a schedule in words before the rest of the list.
  ///
  /// In en, this message translates to:
  /// **'{first}, {rest}'**
  String jobsListMore(String first, String rest);

  /// Whole days in a systemd time span, such as a timer trigger or its random delay.
  ///
  /// In en, this message translates to:
  /// **'{days} d'**
  String jobsSpanDays(int days);

  /// Hours in a systemd time span.
  ///
  /// In en, this message translates to:
  /// **'{hours} h'**
  String jobsSpanHours(int hours);

  /// Minutes in a systemd time span.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String jobsSpanMinutes(int minutes);

  /// Seconds, with any fraction, in a systemd time span.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String jobsSpanSeconds(num seconds);

  /// Joins the units of a systemd time span, largest first, as in 1 h 30 min.
  ///
  /// In en, this message translates to:
  /// **'{first} {second}'**
  String jobsSpanPair(String first, String second);

  /// Why a job lists no next runs (03 §7.7); reason is the engine's JobRunsUnknown name, and other is noDriver. limit is how many cron lines a reading works out runs for, and years how far ahead it looks.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, reboot{Runs when cron starts, not at a time.} unparsed{The schedule does not parse, so its runs are unknown.} timeZoneUnresolved{This device does not know the CRON_TZ zone, so its runs are unknown.} serverZoneUnknown{The server\'s time zone is not known yet, so its runs are unknown.} noRunInHorizon{No run falls in the next {years} years.} notEvaluated{Runs are worked out for the first {limit} cron lines only.} anacron{anacron runs this directory; its timing is not shown in this version.} other{No cron line runs this directory.}}'**
  String jobsRunsUnknown(String reason, int limit, int years);

  /// A job's next-run cell in the jobs table when it lists no runs: jobsRunsUnknown cut short to fit the column, which stays at phone width. reason is the engine's JobRunsUnknown name, and other is noDriver; years is how far ahead the engine looks. The job's details give the full reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, reboot{At cron start} unparsed{Unreadable schedule} timeZoneUnresolved{Zone not known} serverZoneUnknown{Zone not known yet} noRunInHorizon{None in {years} years} notEvaluated{Not worked out} anacron{Timed by anacron} other{Not run}}'**
  String jobsNextRunUnknown(String reason, int years);

  /// Beside a cron run that a DST change skips: time is the clock time the line was written for; the run time shown is the change.
  ///
  /// In en, this message translates to:
  /// **'{time} does not occur that day because of the DST change, so the job runs at the change.'**
  String jobsRunGap(DateTime time);

  /// Beside a cron run whose clock time a DST change repeats; time is that clock time.
  ///
  /// In en, this message translates to:
  /// **'{time} occurs twice at this DST change; the job runs at the first only.'**
  String jobsRunOverlap(DateTime time);

  /// Beside a cron run near a DST change: this device's zone rules may place the change elsewhere than the server's, which cron follows.
  ///
  /// In en, this message translates to:
  /// **'Within an hour of a DST change: the server\'s own zone data may move this run by an hour.'**
  String get jobsRunNearTransition;

  /// Beside a systemd timer's run times when its RandomizedDelaySec is set; span is jobsSpan text.
  ///
  /// In en, this message translates to:
  /// **'Each run starts up to {span} late, at random (RandomizedDelaySec).'**
  String jobsTimerRandomDelay(String span);

  /// Under a systemd timer's one run in its details when no calendar trigger's runs were read: the next run comes from systemd's timer list, which gives one per timer, so the list is not complete.
  ///
  /// In en, this message translates to:
  /// **'systemd\'s timer list gives only the next run, so later runs are not shown.'**
  String get jobsTimerOneRun;

  /// Under an OnCalendar trigger's run on a server whose systemd predates 242, which cannot list more than one.
  ///
  /// In en, this message translates to:
  /// **'systemd before version 242 lists only the next run, so later runs are not shown.'**
  String get jobsCalendarOneRun;

  /// Title of the review shown before a server's or jump host's first-seen host key is trusted (03 §4.6).
  ///
  /// In en, this message translates to:
  /// **'Unknown host key'**
  String get hostKeyUnknownTitle;

  /// Title of the review shown when a server presents a key other than the one trusted before. In capitals on purpose, as an alarm, as in Séance and Poltergeist.
  ///
  /// In en, this message translates to:
  /// **'HOST KEY CHANGED'**
  String get hostKeyChangedTitle;

  /// Warning at the top of the changed-key review; host is the server's host name or address as configured.
  ///
  /// In en, this message translates to:
  /// **'The key for {host} does not match the one you previously trusted. This can mean a man-in-the-middle attack. Only continue if you know why the key changed.'**
  String hostKeyChangedWarning(String host);

  /// The machine a prompt comes from: the server or one of its jump hosts. An IPv6 host arrives in brackets.
  ///
  /// In en, this message translates to:
  /// **'{host}:{port}'**
  String promptEndpoint(String host, int port);

  /// The machine and account a keyboard-interactive prompt comes from, in ssh's user@host notation. An IPv6 host arrives in brackets.
  ///
  /// In en, this message translates to:
  /// **'{user}@{host}:{port}'**
  String promptEndpointWithUser(String user, String host, int port);

  /// Label over a first-seen key's type and SHA-256 fingerprint.
  ///
  /// In en, this message translates to:
  /// **'Fingerprint'**
  String get hostKeyFingerprintLabel;

  /// Label over the key the server presents now, in the changed-key review.
  ///
  /// In en, this message translates to:
  /// **'New key'**
  String get hostKeyNewKeyLabel;

  /// Label over the key trusted before, in the changed-key review.
  ///
  /// In en, this message translates to:
  /// **'Previously trusted'**
  String get hostKeyPreviousLabel;

  /// Declines the host key; the connect then fails.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get hostKeyCancel;

  /// Trusts a first-seen host key and goes on connecting.
  ///
  /// In en, this message translates to:
  /// **'Trust and connect'**
  String get hostKeyTrustConnect;

  /// Trusts the changed key in place of the one trusted before, after the review.
  ///
  /// In en, this message translates to:
  /// **'Trust the new key'**
  String get hostKeyTrustNewKey;

  /// Title of the dialog with a server's keyboard-interactive questions (RFC 4256), such as a password and a one-time code.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get keyboardTitle;

  /// Label over the machine and account the questions come from, which the app knows, apart from the server's own words below it.
  ///
  /// In en, this message translates to:
  /// **'Request from'**
  String get keyboardRequestFrom;

  /// Label over the name and instruction the server sent with its questions, shown as the server sent them.
  ///
  /// In en, this message translates to:
  /// **'Server message'**
  String get keyboardServerMessage;

  /// Tooltip of the button that reveals a masked answer.
  ///
  /// In en, this message translates to:
  /// **'Show answer'**
  String get keyboardShowAnswer;

  /// Tooltip of the button that masks a revealed answer again.
  ///
  /// In en, this message translates to:
  /// **'Hide answer'**
  String get keyboardHideAnswer;

  /// Declines the questions; the connect then fails.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get keyboardCancel;

  /// Sends the answers to the server.
  ///
  /// In en, this message translates to:
  /// **'Submit'**
  String get keyboardSubmit;

  /// Banner on a server's workspace or screen when the engine cannot connect it because no login name is known (03 §10.1, D61): the imported SSH config names no User for the server or one of its ProxyJump hosts, and the USER and USERNAME environment variables are unset. The user fixes it by adding a User line and importing again.
  ///
  /// In en, this message translates to:
  /// **'You can\'t connect to this server yet: your SSH config names no user for it or for a jump host it goes through, and your login name could not be read from this device. Add a User line to your SSH config, then import it again.'**
  String get connectRejectedNoLoginName;

  /// Banner on a server's workspace or screen when the engine cannot connect it because the saved import predates the format that keeps sign-in and jump-host details (03 §4.10, schema 1 or 2; D61). A new import of the SSH config fixes it.
  ///
  /// In en, this message translates to:
  /// **'You can\'t connect to this server yet: it comes from an earlier import that kept only its address. Import your SSH config again to connect.'**
  String get connectRejectedAddressOnly;

  /// Heading of the accessibility settings on the General settings tab.
  ///
  /// In en, this message translates to:
  /// **'Accessibility'**
  String get settingsAccessibilityTitle;

  /// Switch on the General settings tab (A11Y-15): whether screen readers hear a server's values cross a warning or critical level.
  ///
  /// In en, this message translates to:
  /// **'Announce threshold changes'**
  String get settingsAnnounceBands;

  /// Explanation under the threshold announcement switch on the General settings tab (A11Y-15).
  ///
  /// In en, this message translates to:
  /// **'While a server\'s Overview shows, your screen reader hears when CPU, memory or a disk crosses into or out of its warning or critical level. Values that refresh every few seconds are never read out.'**
  String get settingsAnnounceBandsDetail;

  /// Toast when the threshold announcement switch applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The setting changed, but it could not be saved, so it will not be kept after a restart.'**
  String get settingsAnnounceNotSaved;

  /// Toast when the app did not take a change of the threshold announcement switch.
  ///
  /// In en, this message translates to:
  /// **'The setting could not be changed.'**
  String get settingsAnnounceNotChanged;

  /// Screen-reader announcement (A11Y-15) when a value on a server's Overview has crossed into the warning or critical band, or back below the warning level; metric names the value (CPU, Memory, Disk /var), value is its percentage.
  ///
  /// In en, this message translates to:
  /// **'{metric} {value}: {band, select, warning{warning level} critical{critical level} other{back to normal}}'**
  String overviewBandAnnouncement(String metric, String value, String band);

  /// A mount's space use as a threshold announcement names it; mount is the mount point, server data such as /var.
  ///
  /// In en, this message translates to:
  /// **'Disk {mount}'**
  String overviewBandDisk(String mount);

  /// A mount's inode use as a threshold announcement names it; mount is the mount point, server data such as /var.
  ///
  /// In en, this message translates to:
  /// **'Inodes on {mount}'**
  String overviewBandInodes(String mount);

  /// Heading of the Overview's health card (OV-02): failed units and full disks.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get overviewHealthTitle;

  /// The health card before the server sent its list of failed systemd units.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first check of failed units.'**
  String get overviewHealthUnitsWaiting;

  /// The health card when the server could not list its failed systemd units this time; the list from the check before, if any, stays shown below it. systemctl is a command name, kept as written.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, missing{The last check of failed units could not run: this server lacks systemctl.} denied{The server refused the last check of failed units.} timeout{The last check of failed units took too long.} other{The last check of failed units failed.}}'**
  String overviewHealthUnitsCheckFailed(String reason);

  /// The Overview's health and Disks cards before the server sent its first disk usage reading.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first disk reading.'**
  String get overviewDisksWaiting;

  /// The health card when the latest disk usage reading failed; df is a command name, kept as written.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, missing{Disk use is unknown: this server lacks df.} denied{Disk use is unknown: the server refused the reading.} timeout{Disk use is unknown: the reading did not finish in time.} other{Disk use is unknown: the reading failed.}}'**
  String overviewHealthDisksUnknown(String reason);

  /// The health card when every listed mount is below the warning level; level is that level as a percentage, such as 80%.
  ///
  /// In en, this message translates to:
  /// **'No disk has {level} or more of its space or inodes used.'**
  String overviewHealthDisksOk(String level);

  /// A health card line for a mount whose space use reached a level; mount is the mount point (server data), percent its use, and band the level it reached.
  ///
  /// In en, this message translates to:
  /// **'{mount}: {percent} of its space used, {band, select, critical{critical} other{warning}}'**
  String overviewHealthDiskSpace(String mount, String percent, String band);

  /// A health card line for a mount whose inode use reached a level; mount is the mount point (server data), percent its inode use, and band the level it reached.
  ///
  /// In en, this message translates to:
  /// **'{mount}: {percent} of its inodes used, {band, select, critical{critical} other{warning}}'**
  String overviewHealthDiskInodes(String mount, String percent, String band);

  /// The health card's link to the threshold announcement switch in Settings (A11Y-15), with the switch's state.
  ///
  /// In en, this message translates to:
  /// **'{state, select, on{Threshold announcements: on} other{Threshold announcements: off}}'**
  String overviewHealthAnnouncements(String state);

  /// Screen reader hint on the health card's threshold announcement link: activating it opens Settings, where the switch is, rather than switching announcements on the spot.
  ///
  /// In en, this message translates to:
  /// **'Opens Settings'**
  String get overviewHealthAnnouncementsHint;

  /// A mount's size in the Overview's Disks card.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get overviewDiskSize;

  /// Under the Overview's Disks card when it lists only the first mounts; the System tab lists them all.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more mount is on the System tab.} other{{count} more mounts are on the System tab.}}'**
  String overviewDisksMore(int count);

  /// Heading of the Overview's card with the server's operating system, kernel, uptime and boot time.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get overviewHostTitle;

  /// The Overview's Host card before the server sent its operating system and kernel.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the operating system and kernel.'**
  String get overviewHostWaiting;

  /// Tooltip of the sync control in the fleet rail and on phones while this device is not signed in to the Séance sync account; selecting it opens the sign-in. Also told when a sync is asked for before signing in.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your Séance account to list its servers'**
  String get syncSignInTooltip;

  /// Tooltip of the sync control once signed in; selecting it pulls the account's latest servers.
  ///
  /// In en, this message translates to:
  /// **'Synchronize with {host} as {username}'**
  String syncNowTooltip(String username, String host);

  /// Title of the sync sign-in's first step (03 §4.3 step 1).
  ///
  /// In en, this message translates to:
  /// **'Sign in to your Séance account'**
  String get syncSignInTitle;

  /// Explains where the server list comes from, on the sign-in's first step. Séance is the sibling app whose sync account holds the servers.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann lists the servers you keep in Séance. Sign in with the server address, account name, password and encryption passphrase you use in Séance.'**
  String get syncSignInBody;

  /// Label of the sync server's address field, for example https://sync.example.com.
  ///
  /// In en, this message translates to:
  /// **'Server address'**
  String get syncServerAddress;

  /// Label of the sync account's user name field.
  ///
  /// In en, this message translates to:
  /// **'Account name'**
  String get syncAccountName;

  /// Label of the sync account's password field.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get syncPassword;

  /// Label of the field for the passphrase that encrypts the account's records.
  ///
  /// In en, this message translates to:
  /// **'Encryption passphrase'**
  String get syncPassphrase;

  /// Helper text under the encryption passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Often the same as your password.'**
  String get syncPassphraseHelper;

  /// Title of the sign-in's second step, the fleet assertion and disclosures (03 §4.3 step 2).
  ///
  /// In en, this message translates to:
  /// **'Before you sign in'**
  String get syncConfirmTitle;

  /// Checkbox the user must tick before signing in; the version number stays literal.
  ///
  /// In en, this message translates to:
  /// **'Every device that uses this account runs Séance 0.9.0 or later.'**
  String get syncFleetAssertion;

  /// Why the fleet assertion matters, under its checkbox.
  ///
  /// In en, this message translates to:
  /// **'Older Séance releases can mistake records from other apps for servers.'**
  String get syncFleetAssertionDetail;

  /// Disclosure on the sign-in's second step: the account key decrypts every app's records. Séance and Poltergeist are the sibling apps.
  ///
  /// In en, this message translates to:
  /// **'Your encryption passphrase opens the records of every app on this account, Séance and Poltergeist included.'**
  String get syncDisclosureAccountKey;

  /// Disclosure on the sign-in's second step: the app is pull-only and writes nothing to the account.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann only reads this account. It publishes nothing: no servers, host keys or passwords.'**
  String get syncDisclosurePullOnly;

  /// The button that sends the sign-in, enabled once the fleet assertion is ticked.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get syncSignInAction;

  /// Toast after a successful sign-in.
  ///
  /// In en, this message translates to:
  /// **'Signed in. Your Séance servers are now in the fleet.'**
  String get syncSignedIn;

  /// Toast after a sign-in or sync in which no record could be decrypted to prove the passphrase: it may be wrong, or the account holds nothing yet.
  ///
  /// In en, this message translates to:
  /// **'No record on the account has confirmed your encryption passphrase yet. If servers are missing, sign in again with the passphrase you use in Séance.'**
  String get syncPassphraseUnverified;

  /// Sign-in error: the server address is missing or not a web address.
  ///
  /// In en, this message translates to:
  /// **'Enter the server address, starting with https:// or http://.'**
  String get syncValidationServerAddress;

  /// Sign-in error: the server address contains a user name or password.
  ///
  /// In en, this message translates to:
  /// **'Leave your account name and password out of the server address.'**
  String get syncValidationUrlCredentials;

  /// Sign-in error: the account name is empty.
  ///
  /// In en, this message translates to:
  /// **'Enter your account name.'**
  String get syncValidationAccountName;

  /// Sign-in error: the password is empty.
  ///
  /// In en, this message translates to:
  /// **'Enter your password.'**
  String get syncValidationPassword;

  /// Sign-in error: the encryption passphrase is empty.
  ///
  /// In en, this message translates to:
  /// **'Enter your encryption passphrase.'**
  String get syncValidationPassphrase;

  /// Sync error: the instance lock could not be taken, so the app signs in and syncs nothing.
  ///
  /// In en, this message translates to:
  /// **'Sync is off because Klabautermann could not check whether another copy of it is running.'**
  String get syncFailedDirectoryShared;

  /// Sync error: settings.json gave no device id this session.
  ///
  /// In en, this message translates to:
  /// **'Sync is off because this device\'s settings file could not be read or saved.'**
  String get syncFailedNoDeviceId;

  /// Sync error: signing in to a second account while one is signed in.
  ///
  /// In en, this message translates to:
  /// **'This device is already signed in to another account.'**
  String get syncFailedOtherAccount;

  /// Sign-in error: the server offered key derivation parameters below the suite's minimum (a possible downgrade attack).
  ///
  /// In en, this message translates to:
  /// **'The server asked for weaker password protection than Klabautermann accepts, so nothing was sent. The server may have been tampered with.'**
  String get syncFailedKdfDowngrade;

  /// Sign-in error: the server refused the login.
  ///
  /// In en, this message translates to:
  /// **'The server did not accept this account name and password.'**
  String get syncFailedCredentials;

  /// Sync error: the server rejected the stored session token.
  ///
  /// In en, this message translates to:
  /// **'The server no longer accepts this device\'s sign-in. Sign in again.'**
  String get syncFailedSession;

  /// Sync error: the server did not answer.
  ///
  /// In en, this message translates to:
  /// **'The sync server could not be reached. Check the address and your connection.'**
  String get syncFailedUnreachable;

  /// Sync error: the server answered with an error.
  ///
  /// In en, this message translates to:
  /// **'The sync server reported an error. Try again later.'**
  String get syncFailedServer;

  /// Sync error: the OS keystore refused to store or read the sync token or vault key.
  ///
  /// In en, this message translates to:
  /// **'The system keychain could not store or hand over the sync keys. Unlock it and try again.'**
  String get syncFailedKeystore;

  /// Sync error: a sync state file is left as it is this session.
  ///
  /// In en, this message translates to:
  /// **'A sync file could not be saved, so the sign-in was not kept.'**
  String get syncFailedStore;

  /// Sync error with no more specific cause.
  ///
  /// In en, this message translates to:
  /// **'Sync failed.'**
  String get syncFailed;

  /// Startup notice: a sync state file was damaged and renamed aside; for the enrollment file the device then reads as not signed in.
  ///
  /// In en, this message translates to:
  /// **'The sync file {fileName} could not be read and was cleared. The old file is kept as {keptAs}.'**
  String syncFileRecovered(String fileName, String keptAs);

  /// Startup notice: a sync state file could not be read or renamed aside, so it is not written this session.
  ///
  /// In en, this message translates to:
  /// **'The sync file {fileName} could not be read, so it was left as it is. Sync changes will not be kept after a restart.'**
  String syncFileLeftAsIs(String fileName);

  /// Startup notice: a newer app version wrote a sync state file, so this version does not write it.
  ///
  /// In en, this message translates to:
  /// **'The sync file {fileName} was saved by a newer version of Klabautermann. Sync changes will not be kept after a restart.'**
  String syncFileNewer(String fileName);

  /// The server header's Docker transport label (03 §5.9, E4) before the server is connected and its capability check has answered.
  ///
  /// In en, this message translates to:
  /// **'Engine API: waiting for the connection'**
  String get dockerTransportWaiting;

  /// The server header's Docker transport label (03 §5.9, E4) while Klabautermann tries the routes to the engine socket and agrees on an API version.
  ///
  /// In en, this message translates to:
  /// **'Engine API: looking for a route'**
  String get dockerTransportResolving;

  /// The server header's Docker transport label (03 §5.9, E4) for rank 1: SSH forwards the engine socket. Keep the wording of 03 §5.9.
  ///
  /// In en, this message translates to:
  /// **'Engine API via SSH socket forward'**
  String get dockerTransportSocketForward;

  /// The server header's Docker transport label (03 §5.9, E4) for rank 2: the engine CLI relays each connection over its own SSH session. "docker" is the command name; keep the wording of 03 §5.9.
  ///
  /// In en, this message translates to:
  /// **'Engine API via docker CLI relay (limited streams)'**
  String get dockerTransportCliRelay;

  /// The server header's Docker transport label (03 §5.9, E4) for rank 4: socat or nc relays each connection. "socat" is the command name; keep the wording of 03 §5.9.
  ///
  /// In en, this message translates to:
  /// **'Engine API via socat relay'**
  String get dockerTransportSocatRelay;

  /// The server header's Docker transport label (03 §5.9, E4) when socket forwarding is refused and the server has no docker, podman, socat or nc to relay through.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: forwarding is off and there is no relay'**
  String get dockerTransportNoRelay;

  /// The server header's Docker transport label (03 §5.9, E4) when the account cannot use the engine socket but sudo exists; admin mode arrives later.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: the socket needs admin mode'**
  String get dockerTransportNeedsAdminMode;

  /// The server header's Docker transport label (03 §5.9, E4) when the account cannot use the engine socket and the server has no sudo.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: your account cannot use the socket'**
  String get dockerTransportSocketDenied;

  /// The server header's Docker transport label (03 §5.9, E4) when the command that checks the engine socket failed or answered something unreadable.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: the socket check failed'**
  String get dockerTransportProbeFailed;

  /// The server header's Docker transport label (03 §5.9, E4) when the server has no Docker or Podman socket.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: no engine socket found'**
  String get dockerTransportNoSocket;

  /// The server header's Docker transport label (03 §5.9, E4) when the capability check has not reported the server's engine sockets.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: the sockets were not checked'**
  String get dockerTransportSocketsUnknown;

  /// The server header's Docker transport label (03 §5.9, E4) when routes to the engine socket opened but the engine answered over none of them.
  ///
  /// In en, this message translates to:
  /// **'Engine API: the engine did not answer'**
  String get dockerTransportUnreachable;

  /// The server header's Docker transport label (03 §5.9, E4) when the engine offers no API version this app can use.
  ///
  /// In en, this message translates to:
  /// **'Engine API: the engine\'s API version is not supported'**
  String get dockerTransportUnsupported;

  /// The server header's Docker transport label (03 §5.9, E4) when the SSH connection failed while the routes were tried.
  ///
  /// In en, this message translates to:
  /// **'Engine API: the connection failed while looking for a route'**
  String get dockerTransportLinkError;

  /// Server header: the server allows few SSH sessions, so Docker shares them sparingly (03 §5.2).
  ///
  /// In en, this message translates to:
  /// **'Low-session mode'**
  String get dockerLowSession;

  /// Server header badge (SAF-08, 03 §8.4): the engine socket in use belongs to a rootful engine, so using it equals root on the server.
  ///
  /// In en, this message translates to:
  /// **'Rootful socket: root-equivalent'**
  String get dockerBadgeRootfulSocket;

  /// Server header badge (SAF-08, 03 §8.4): the engine in use runs rootless, so using it equals the account that runs it.
  ///
  /// In en, this message translates to:
  /// **'Rootless engine: equals user {user}'**
  String dockerBadgeRootlessEngine(String user);

  /// dockerBadgeRootlessEngine when the capability check did not name the login user.
  ///
  /// In en, this message translates to:
  /// **'Rootless engine: equals your login user'**
  String get dockerBadgeRootlessEngineLogin;

  /// Server header badge (SAF-08): a socket path Klabautermann cannot classify, treated as root-equivalent.
  ///
  /// In en, this message translates to:
  /// **'Custom socket: root-equivalent'**
  String get dockerBadgeCustomSocket;

  /// The engine in use when its mode is unknown, as on a custom socket path.
  ///
  /// In en, this message translates to:
  /// **'Docker'**
  String get dockerRuntimeDocker;

  /// The engine in use when its mode is unknown, as on a custom socket path.
  ///
  /// In en, this message translates to:
  /// **'Podman'**
  String get dockerRuntimePodman;

  /// Docker tab, shown instead of its panels until the server is connected and its capability check has answered.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the connection'**
  String get dockerGateWaitingTitle;

  /// Body under dockerGateWaitingTitle.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann looks for the Docker engine once it is connected to this server and knows what the server offers.'**
  String get dockerGateWaitingBody;

  /// Docker tab, shown instead of its panels while Klabautermann finds a route to the engine socket.
  ///
  /// In en, this message translates to:
  /// **'Looking for the Docker engine'**
  String get dockerGateResolvingTitle;

  /// Body under dockerGateResolvingTitle.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann is finding a way to reach the engine socket and agreeing on an API version with the engine.'**
  String get dockerGateResolvingBody;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: forwarding refused and no relay. Command names stay as they are.
  ///
  /// In en, this message translates to:
  /// **'Socket forwarding is off on this server, and it has nothing to relay through: no docker or podman command, no socat and no nc.'**
  String get dockerGateNoRelay;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the account cannot use the socket, but sudo exists.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot use the engine socket. Reaching it through sudo needs admin mode, which arrives in a later milestone.'**
  String get dockerGateNeedsAdminMode;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the account cannot use the socket and there is no sudo.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot use the engine socket, and this server has no sudo. The Access tab shows how access is granted.'**
  String get dockerGateSocketDenied;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the socket check failed.
  ///
  /// In en, this message translates to:
  /// **'Checking the engine socket failed, so Klabautermann cannot tell how to reach it.'**
  String get dockerGateProbeFailed;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: no engine socket.
  ///
  /// In en, this message translates to:
  /// **'No Docker or Podman socket was found on this server.'**
  String get dockerGateNoSocket;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the sockets were not checked.
  ///
  /// In en, this message translates to:
  /// **'The server\'s capability check has not reported its engine sockets.'**
  String get dockerGateSocketsUnknown;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the engine did not answer.
  ///
  /// In en, this message translates to:
  /// **'A route to the engine socket opened, but the engine did not answer over it.'**
  String get dockerGateUnreachable;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the engine is too old. 1.41 is the Docker API version.
  ///
  /// In en, this message translates to:
  /// **'The engine\'s newest API version is older than 1.41, the oldest Klabautermann supports.'**
  String get dockerGateBelowClientFloor;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the engine is too new for this app.
  ///
  /// In en, this message translates to:
  /// **'The engine only accepts API versions newer than Klabautermann supports.'**
  String get dockerGateBelowServerMinimum;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: no readable API version.
  ///
  /// In en, this message translates to:
  /// **'The engine did not report an API version Klabautermann can read.'**
  String get dockerGateApiVersionUnknown;

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the SSH connection failed meanwhile.
  ///
  /// In en, this message translates to:
  /// **'The connection to this server failed while Klabautermann looked for the engine.'**
  String get dockerGateLinkError;

  /// Docker tab: asks again for the Docker endpoint or the engine details after a failure.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get dockerRetry;

  /// Docker tab: the sub-tab listing containers.
  ///
  /// In en, this message translates to:
  /// **'Containers'**
  String get dockerTabContainers;

  /// Docker tab: the sub-tab listing images.
  ///
  /// In en, this message translates to:
  /// **'Images'**
  String get dockerTabImages;

  /// Docker tab: the sub-tab listing compose stacks.
  ///
  /// In en, this message translates to:
  /// **'Stacks'**
  String get dockerTabStacks;

  /// Docker tab: heading of the strip with the engine's runtime, API version, version and operating system (DKE-01).
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get dockerEngineHeading;

  /// Docker tab engine strip: the Docker API version the app negotiated with the engine.
  ///
  /// In en, this message translates to:
  /// **'API {version}'**
  String dockerEngineApi(String version);

  /// Docker tab engine strip: the engine's product name and version.
  ///
  /// In en, this message translates to:
  /// **'{name} {version}'**
  String dockerEngineVersion(String name, String version);

  /// Docker tab engine strip: the engine did not report its version.
  ///
  /// In en, this message translates to:
  /// **'{name}, version unknown'**
  String dockerEngineVersionUnknown(String name);

  /// Docker tab engine strip: the engine host's operating system and architecture.
  ///
  /// In en, this message translates to:
  /// **'{os} on {architecture}'**
  String dockerEngineOs(String os, String architecture);

  /// Docker tab engine strip: the engine did not report its host's operating system.
  ///
  /// In en, this message translates to:
  /// **'Operating system unknown'**
  String get dockerEngineOsUnknown;

  /// Docker tab engine strip: while the engine's details are read.
  ///
  /// In en, this message translates to:
  /// **'Reading the engine details…'**
  String get dockerEngineReading;

  /// Docker tab engine strip: reading the engine's details failed.
  ///
  /// In en, this message translates to:
  /// **'The engine details could not be read.'**
  String get dockerEngineReadFailed;

  /// Docker tab: dismisses the root-equivalence notice on this device.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get dockerNoticeDismiss;

  /// Toast: dismissing the Docker tab's root-equivalence notice could not be saved.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not save that you dismissed the root-equivalence note, so it shows again after a restart.'**
  String get dockerNoticeNotSaved;

  /// Containers table column: the container's name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get dockerContainersColumnName;

  /// Containers table column: the container's state, such as running or exited.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get dockerContainersColumnState;

  /// Containers table column: the container's health check status (CTR-04).
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get dockerContainersColumnHealth;

  /// Containers table column: the engine's own status text, such as "Up 3 hours" or "Exited (0) 2 days ago", which gives the uptime. Server data, never translated.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get dockerContainersColumnStatus;

  /// Containers table column: the image the container runs.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get dockerContainersColumnImage;

  /// Containers table column: the container's published and exposed ports.
  ///
  /// In en, this message translates to:
  /// **'Ports'**
  String get dockerContainersColumnPorts;

  /// Containers table column: the compose project the container belongs to, or a Swarm task's service.
  ///
  /// In en, this message translates to:
  /// **'Stack'**
  String get dockerContainersColumnStack;

  /// Containers table column: the container's CPU share from its list stats (CST-01).
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get dockerContainersColumnCpu;

  /// Containers table column: the memory the container uses, from its list stats (CST-01).
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get dockerContainersColumnMemory;

  /// A container's state in words. state is the Engine API's state name; a state outside this list shows as the engine gave it instead.
  ///
  /// In en, this message translates to:
  /// **'{state, select, created{Created} running{Running} paused{Paused} restarting{Restarting} removing{Removing} exited{Exited} dead{Dead} other{Unknown}}'**
  String dockerContainerState(String state);

  /// A container's health check status (CTR-04), beside an icon.
  ///
  /// In en, this message translates to:
  /// **'{health, select, healthy{Healthy} unhealthy{Unhealthy} starting{Starting} other{No health check}}'**
  String dockerContainerHealth(String health);

  /// A container's CPU share; share arrives as a fraction where 1 is one full CPU, so it can exceed 100%.
  ///
  /// In en, this message translates to:
  /// **'{share}'**
  String dockerContainersCpu(double share);

  /// What a screen reader hears for a container's CPU or memory figure whose stats are old; the screen shows it grey beside a history icon.
  ///
  /// In en, this message translates to:
  /// **'{value}, stale'**
  String dockerContainersStale(String value);

  /// The Stack column for a Swarm task: the Swarm service its name belongs to.
  ///
  /// In en, this message translates to:
  /// **'{service} (Swarm)'**
  String dockerContainersSwarmService(String service);

  /// Containers list: the heading of the containers that belong to no compose project.
  ///
  /// In en, this message translates to:
  /// **'Not in a stack'**
  String get dockerContainersNoStack;

  /// Containers list: a compose project heading's counts of the containers shown and of those running.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 container} other{{count} containers}}, {up} running'**
  String dockerContainersGroupSummary(int count, int up);

  /// Containers list: the search field's hint.
  ///
  /// In en, this message translates to:
  /// **'Search by name, image or ID'**
  String get dockerContainersSearchHint;

  /// Containers list: tooltip of the button that clears the search.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get dockerContainersSearchClear;

  /// Containers list: a toggle that hides stopped containers.
  ///
  /// In en, this message translates to:
  /// **'Running only'**
  String get dockerContainersRunningOnly;

  /// Containers list on a phone: the label before the sort menu.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get dockerContainersSortBy;

  /// Containers list on a phone: one figure of a container, after its column's name.
  ///
  /// In en, this message translates to:
  /// **'{label}: {value}'**
  String dockerContainersFact(String label, String value);

  /// Containers list: while the first list is read.
  ///
  /// In en, this message translates to:
  /// **'Reading the containers…'**
  String get dockerContainersReading;

  /// Containers list: the engine listed none.
  ///
  /// In en, this message translates to:
  /// **'This engine has no containers.'**
  String get dockerContainersEmpty;

  /// Containers list: Running only hides every container.
  ///
  /// In en, this message translates to:
  /// **'No container is running. Turn off Running only to see the stopped ones.'**
  String get dockerContainersNoneRunning;

  /// Containers list: the search matches none.
  ///
  /// In en, this message translates to:
  /// **'No container matches the search.'**
  String get dockerContainersNoMatch;

  /// Containers list: why the list could not be read. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} daemonError{The engine refused or failed to list the containers.} connectionFailed{The connection to the engine failed while listing the containers.} other{The containers could not be listed.}}'**
  String dockerContainersFailed(String reason);

  /// Containers list: under a failed read, the list it keeps is older.
  ///
  /// In en, this message translates to:
  /// **'The list below is the last one read.'**
  String get dockerContainersKept;

  /// Containers list: the latest stats round failed.
  ///
  /// In en, this message translates to:
  /// **'The CPU and memory figures could not be read, so the ones shown may be old.'**
  String get dockerContainersStatsFailed;

  /// Containers list: the server's link has a session limit (03 §5.2) on the SSH socket forward.
  ///
  /// In en, this message translates to:
  /// **'Low-session mode: stats are read one container at a time, so they update more slowly.'**
  String get dockerContainersLowSession;

  /// Containers list: the server's link has a session limit (03 §5.2) on a relay route.
  ///
  /// In en, this message translates to:
  /// **'Low-session mode: the list is read again every 15 seconds instead of following engine events, and stats are read one container at a time.'**
  String get dockerContainersLowSessionRelay;
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
