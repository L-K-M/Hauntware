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

  /// The app's title, with the preview label until v1 (04 §12.3): the task switcher, the About dialog and the about row on the General settings tab. Klabautermann is the display name, an identity: never translated.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann (preview)'**
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

  /// Fleet list section header over the synced servers pinned to the top on this device (03 §10.3); drawn in caps.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get fleetSectionPinned;

  /// Fleet list section header over the servers imported from this device's SSH config (FL-02), listed apart from the synced servers and their groups; drawn in caps.
  ///
  /// In en, this message translates to:
  /// **'Imported'**
  String get fleetSectionImported;

  /// A synced fleet row's menu verb that lists the server under the Pinned section on this device.
  ///
  /// In en, this message translates to:
  /// **'Pin to top'**
  String get fleetRowPin;

  /// A pinned fleet row's menu verb that returns the server to its section.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get fleetRowUnpin;

  /// Top toast when pinning or unpinning a server could not be written to the device's settings file; the change holds for this session.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not save your pinned servers, so the change lasts only until it quits.'**
  String get fleetPinNotSaved;

  /// A fleet row's menu verb that adds the server to this device's monitor set (FL-21): Klabautermann then reads it continuously while open and its row shows CPU, memory and disk. Disabled for a server that cannot be monitored.
  ///
  /// In en, this message translates to:
  /// **'Monitor'**
  String get fleetRowMonitor;

  /// A monitored fleet row's menu verb that takes the server out of this device's monitor set (FL-21); it is then read only while a view has it open.
  ///
  /// In en, this message translates to:
  /// **'Stop monitoring'**
  String get fleetRowStopMonitoring;

  /// Top toast when the user asks to monitor a server while the monitor set (FL-21) is full; limit is the most servers it holds.
  ///
  /// In en, this message translates to:
  /// **'You can monitor up to {limit} servers on this device. Stop monitoring one first.'**
  String monitorSetFull(int limit);

  /// Top toast when a monitor set change applied but could not be written to the device's settings file; the change holds for this session.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not save your monitored servers, so the change lasts only until it quits.'**
  String get monitorSetNotSaved;

  /// Top toast when the app did not take a monitor set change, such as one from the settings window that the app refused.
  ///
  /// In en, this message translates to:
  /// **'The monitored servers could not be changed.'**
  String get monitorSetNotChanged;

  /// Why a synced server cannot join the monitor set (FL-21): this device has not confirmed its endpoint, or a sync changed it since (SAF-09).
  ///
  /// In en, this message translates to:
  /// **'Confirm this server\'s endpoint to monitor it.'**
  String get monitorIneligibleEndpoint;

  /// Why a server cannot join the monitor set (FL-21): its sign-in needs the user's answer, and continuous reading never asks.
  ///
  /// In en, this message translates to:
  /// **'Signs in with a password or a stored key, which asks you first, so it is read only while you have it open.'**
  String get monitorIneligibleCredentials;

  /// Why an imported server cannot join the monitor set (FL-21): it came from an older import, whose sign-in Klabautermann does not know until the next import.
  ///
  /// In en, this message translates to:
  /// **'Import your ssh_config again to monitor this server.'**
  String get monitorIneligibleUnknown;

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

  /// Title of the Help menu (Linux and Windows, where it holds About Klabautermann).
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get menuHelp;

  /// The menu command that opens the About dialog: first in the macOS application menu, in the Help menu on Linux and Windows. Klabautermann is the display name: never translated.
  ///
  /// In en, this message translates to:
  /// **'About Klabautermann'**
  String get aboutCommand;

  /// The running build's version in the About dialog and the about row on the General settings tab.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String aboutVersion(String version);

  /// In place of aboutVersion when the platform could not tell the app's version.
  ///
  /// In en, this message translates to:
  /// **'Version unknown'**
  String get aboutVersionUnknown;

  /// The app's licence line in the About dialog: the Unlicense covers only the app's own code, and View licenses is the dialog's button. Klabautermann and Unlicense are names: never translated.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann\'s own code is public domain (Unlicense). It includes third-party components that keep their own licenses, listed under View licenses.'**
  String get aboutLicence;

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

  /// Overview (OV-07): the heading of the card ranking the busiest processes and containers.
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get topListsTitle;

  /// Overview top lists (OV-07): what the lists rank by, in the card's picker.
  ///
  /// In en, this message translates to:
  /// **'{measure, select, cpu{CPU} other{Memory}}'**
  String topListsMeasure(String measure);

  /// Overview top lists (OV-07): opens the card, which then reads the process list and container stats while the Overview shows.
  ///
  /// In en, this message translates to:
  /// **'Show the busiest processes and containers'**
  String get topListsShow;

  /// Overview top lists (OV-07): closes the card, which then reads nothing.
  ///
  /// In en, this message translates to:
  /// **'Hide'**
  String get topListsHide;

  /// Overview top lists (OV-07): one process, its name and id.
  ///
  /// In en, this message translates to:
  /// **'{name} ({pid})'**
  String topListsProcess(String name, int pid);

  /// Overview top lists (OV-07): a CPU share, already rounded to one decimal.
  ///
  /// In en, this message translates to:
  /// **'{value} %'**
  String topListsPercent(String value);

  /// Overview top lists (OV-07): the heading of the busiest processes.
  ///
  /// In en, this message translates to:
  /// **'Processes'**
  String get topListsProcesses;

  /// Overview top lists (OV-07): the heading of the busiest containers, shown where the Docker engine answers.
  ///
  /// In en, this message translates to:
  /// **'Containers'**
  String get topListsContainers;

  /// Overview top lists (OV-07): shown until the first process list or container stats arrive.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the first reading…'**
  String get topListsWaiting;

  /// Overview top lists (OV-07): shown when no process or container reported the figure, as before a second CPU reading.
  ///
  /// In en, this message translates to:
  /// **'Nothing to rank yet.'**
  String get topListsEmpty;

  /// Overview (OV-08): the heading of the quick actions card.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get quickActionsTitle;

  /// Overview quick actions (OV-08): opens the server's files in Poltergeist.
  ///
  /// In en, this message translates to:
  /// **'Browse files in Poltergeist'**
  String get quickActionsFiles;

  /// Overview quick actions (OV-08): restarts a service pinned from its page in the Services tab.
  ///
  /// In en, this message translates to:
  /// **'Restart {unit}'**
  String quickActionsRestart(String unit);

  /// Overview quick actions (OV-08): reboots the server, through the same preview as the System tab.
  ///
  /// In en, this message translates to:
  /// **'Reboot'**
  String get quickActionsReboot;

  /// A unit's page (OV-08): tooltip of the pin that adds a restart button for the unit to the Overview.
  ///
  /// In en, this message translates to:
  /// **'Pin to the Overview\'s quick actions'**
  String get quickActionsPin;

  /// A unit's page (OV-08): tooltip of the pin while the unit is pinned.
  ///
  /// In en, this message translates to:
  /// **'Unpin from the Overview\'s quick actions'**
  String get quickActionsUnpin;

  /// A unit's page (OV-08): tooltip of the disabled pin when the server holds as many pins as it takes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{One service is already pinned, the most this server takes} other{{count} services are already pinned, the most this server takes}}'**
  String quickActionsPinFull(int count);

  /// A unit's page (OV-08): toast when a pin applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The pin changed but could not be saved. It lasts until Klabautermann quits.'**
  String get quickActionsPinNotSaved;

  /// The fleet board (FL-08): the label before its layout picker, shown in the desktop workspace while no server is open.
  ///
  /// In en, this message translates to:
  /// **'Layout'**
  String get fleetDensityLabel;

  /// The fleet board (FL-08): one layout in its picker. Auto shows cards for a small fleet and a grid for a large one; Tree is the connection tree (FL-11); Rows leaves the rail's rows alone.
  ///
  /// In en, this message translates to:
  /// **'{density, select, auto{Auto} cards{Cards} grid{Grid} tree{Tree} other{Rows}}'**
  String fleetDensity(String density);

  /// The fleet board: toast when the picked layout applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The layout changed but could not be saved. It lasts until Klabautermann quits.'**
  String get fleetDensityNotSaved;

  /// Connection tree (FL-11): tooltip of a server node's button that opens the server's workspace.
  ///
  /// In en, this message translates to:
  /// **'Open {server}'**
  String fleetTreeOpenServer(String server);

  /// Connection tree (FL-11): under an opened server node until its container list arrives.
  ///
  /// In en, this message translates to:
  /// **'Reading containers…'**
  String get fleetTreeReading;

  /// Connection tree (FL-11): under an opened server node when its container list failed before any was read.
  ///
  /// In en, this message translates to:
  /// **'The containers could not be read. The Docker tab says why.'**
  String get fleetTreeReadFailed;

  /// Connection tree (FL-11): under an opened server node when the Docker endpoint search failed.
  ///
  /// In en, this message translates to:
  /// **'No Docker engine answers on this server.'**
  String get fleetTreeNoDocker;

  /// Connection tree (FL-11): under an opened server node whose engine lists no container.
  ///
  /// In en, this message translates to:
  /// **'No containers.'**
  String get fleetTreeNoContainers;

  /// Connection tree (FL-11): a compose stack node's subtitle, its running containers out of all.
  ///
  /// In en, this message translates to:
  /// **'{up} of {total} running'**
  String fleetTreeStackUp(int up, int total);

  /// A fleet board card: one pressure bar cell's share in figures, e.g. 'CPU 23 %'. label is fleetRowCpu, fleetRowMemory or fleetRowDisk.
  ///
  /// In en, this message translates to:
  /// **'{label} {percent} %'**
  String fleetTileShare(String label, int percent);

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

  /// Shown beside the fleet list on a tablet while no server is selected.
  ///
  /// In en, this message translates to:
  /// **'Choose a server to see it here.'**
  String get fleetSplitChooseServer;

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

  /// Processes tab: the toggle that shows each process under its parent (PRC-03).
  ///
  /// In en, this message translates to:
  /// **'Tree'**
  String get processesTree;

  /// Processes tab: the badge beside a process in a flagged run state (PRC-06): a zombie (state Z) or in uninterruptible sleep (state D). Lower case, as a label beside the command.
  ///
  /// In en, this message translates to:
  /// **'{flag, select, zombie{zombie} uninterruptible{waiting on I/O} other{flagged}}'**
  String processesFlag(String flag);

  /// Processes tab: how many processes a run state flag marks (PRC-06), above the list.
  ///
  /// In en, this message translates to:
  /// **'{flag, select, zombie{{count, plural, =1{1 zombie process} other{{count} zombie processes}}} uninterruptible{{count, plural, =1{1 process waiting on I/O it cannot be interrupted from} other{{count} processes waiting on I/O they cannot be interrupted from}}} other{{count, plural, =1{1 flagged process} other{{count} flagged processes}}}}'**
  String processesFlagCount(String flag, int count);

  /// Processes tab: what joins the flag counts above the list.
  ///
  /// In en, this message translates to:
  /// **'; '**
  String get processesFlagSeparator;

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

  /// Heading of the facts a process's details read from the server (PRC-04, PRC-05).
  ///
  /// In en, this message translates to:
  /// **'Details'**
  String get processesDetailTitle;

  /// Shown while a process's details are read from the server.
  ///
  /// In en, this message translates to:
  /// **'Reading details…'**
  String get processesDetailReading;

  /// Button that reads a process's details from the server again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get processesDetailReadAgain;

  /// Shown when a process's details could not be read.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server denied reading this process.} missing{The server lacks a tool this read needs.} other{Reading this process\'s details failed.}}'**
  String processesDetailFailed(String failure);

  /// Shown when a process ended before its details were read: it exited, or its PID was reused by another process.
  ///
  /// In en, this message translates to:
  /// **'{end, select, gone{This process has exited.} reused{Its process ID now belongs to another process, so nothing was read.} other{This process has ended.}}'**
  String processesDetailEnded(String end);

  /// Shown in a process's details when the reading has no start time, which the read needs to make sure it reads the same process.
  ///
  /// In en, this message translates to:
  /// **'The server did not report when this process started, so its details are not read.'**
  String get processesDetailNoStart;

  /// Label of the systemd unit a process runs in.
  ///
  /// In en, this message translates to:
  /// **'Unit'**
  String get processesDetailUnit;

  /// Value of a process's unit when it runs outside any systemd unit.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get processesDetailNoUnit;

  /// Label of the container a process runs in.
  ///
  /// In en, this message translates to:
  /// **'Container'**
  String get processesDetailContainer;

  /// The container a process runs in: its runtime and short ID.
  ///
  /// In en, this message translates to:
  /// **'{runtime, select, docker{Docker} podman{Podman} containerd{containerd} crio{CRI-O} other{Container}} {id}'**
  String processesDetailContainerValue(String runtime, String id);

  /// Label of a process's working directory.
  ///
  /// In en, this message translates to:
  /// **'Working directory'**
  String get processesDetailCwd;

  /// Value of a process fact the login user may not read.
  ///
  /// In en, this message translates to:
  /// **'Not readable as this user'**
  String get processesDetailNotReadable;

  /// Label of a process's thread count.
  ///
  /// In en, this message translates to:
  /// **'Threads'**
  String get processesDetailThreads;

  /// Label of how much of a process's memory is swapped out.
  ///
  /// In en, this message translates to:
  /// **'Swap'**
  String get processesDetailSwap;

  /// Label of a process's context switch counts.
  ///
  /// In en, this message translates to:
  /// **'Context switches'**
  String get processesDetailSwitches;

  /// A process's voluntary and involuntary context switches.
  ///
  /// In en, this message translates to:
  /// **'{voluntary} voluntary, {involuntary} involuntary'**
  String processesDetailSwitchesValue(int voluntary, int involuntary);

  /// Label of how many files a process holds open.
  ///
  /// In en, this message translates to:
  /// **'Open files'**
  String get processesDetailOpenFiles;

  /// How many files a process holds open, out of its soft limit.
  ///
  /// In en, this message translates to:
  /// **'{count} of {limit}'**
  String processesDetailOpenFilesOf(int count, int limit);

  /// Label of the most processes the process's user may run (its soft limit).
  ///
  /// In en, this message translates to:
  /// **'Process limit'**
  String get processesDetailProcessLimit;

  /// Value of a limit the process does not have.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get processesDetailUnlimited;

  /// Heading of a process's environment variables in its details.
  ///
  /// In en, this message translates to:
  /// **'Environment'**
  String get processesEnvironmentTitle;

  /// Shown when a process has no environment variables.
  ///
  /// In en, this message translates to:
  /// **'No environment variables.'**
  String get processesEnvironmentNone;

  /// Shown when the login user may not read a process's environment.
  ///
  /// In en, this message translates to:
  /// **'The environment is not readable as this user.'**
  String get processesEnvironmentDenied;

  /// Shown under a process's environment when it was cut at the read's limit.
  ///
  /// In en, this message translates to:
  /// **'Only the first {count} variables were read.'**
  String processesEnvironmentCapped(int count);

  /// Screen-reader label of one of a process's environment variables: its name and its value, or the value's mask in words.
  ///
  /// In en, this message translates to:
  /// **'{name}: {value}'**
  String processesEnvironmentEntry(String name, String value);

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

  /// Heading of the System tab's MEM-03 section: processes the kernel's OOM killer ended since boot.
  ///
  /// In en, this message translates to:
  /// **'Out-of-memory kills'**
  String get systemOomTitle;

  /// The OOM kills section while its read runs.
  ///
  /// In en, this message translates to:
  /// **'Reading the kernel\'s out-of-memory kills.'**
  String get systemOomReading;

  /// The OOM kills section when its read failed; failure is noLink, denied, missing or failed.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected, so the out-of-memory kills cannot be read.} denied{The server refused the out-of-memory read.} missing{The server lacks a tool the out-of-memory read needs.} other{The out-of-memory kills could not be read.}}'**
  String systemOomFailed(String failure);

  /// How many processes the kernel's OOM killer ended since boot, from /proc/vmstat.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No process was killed for lack of memory since boot.} =1{1 process was killed for lack of memory since boot.} other{{count} processes were killed for lack of memory since boot.}}'**
  String systemOomCount(int count);

  /// The OOM kills section on a kernel without the oom_kill counter in /proc/vmstat.
  ///
  /// In en, this message translates to:
  /// **'This kernel does not count out-of-memory kills (Linux 4.13 and later do).'**
  String get systemOomCountUnknown;

  /// The OOM kills section when neither the journal's kernel lines nor dmesg gave any line to the login user.
  ///
  /// In en, this message translates to:
  /// **'Your login may not read the kernel log, so the killed processes cannot be named. Membership in the adm or systemd-journal group, or sudo, gives access.'**
  String get systemOomLogDenied;

  /// A killed process: its command name and process ID.
  ///
  /// In en, this message translates to:
  /// **'{command} (PID {pid})'**
  String systemOomProcess(String command, int pid);

  /// When a process was killed, from the journal: a date and time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'Killed {time}'**
  String systemOomKilledAt(DateTime time);

  /// When a process was killed, from dmesg, which counts from boot; time is a span such as "3 days, 4 hours".
  ///
  /// In en, this message translates to:
  /// **'Killed {time} after boot'**
  String systemOomAfterBoot(String time);

  /// How much anonymous memory (anon-rss) a killed process held, in binary units.
  ///
  /// In en, this message translates to:
  /// **'{size} of its own memory when killed'**
  String systemOomMemory(String size);

  /// Shown under a kill the kernel made because a memory cgroup reached its limit.
  ///
  /// In en, this message translates to:
  /// **'A memory limit ran out, such as a container\'s, not the server\'s memory.'**
  String get systemOomCgroupLimit;

  /// Opens the current boot's kernel log lines of the OOM reports.
  ///
  /// In en, this message translates to:
  /// **'Show in kernel log'**
  String get systemOomShowLog;

  /// Reads the OOM kills again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemOomReadAgain;

  /// Heading of the sheet with the current boot's kernel log lines of OOM reports.
  ///
  /// In en, this message translates to:
  /// **'Out-of-memory reports'**
  String get systemOomLogTitle;

  /// Tooltip of the button that closes the OOM reports sheet.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get systemOomLogClose;

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

  /// System tab: the section of each whole disk's I/O rates since the previous reading (DSK-03, DSK-04).
  ///
  /// In en, this message translates to:
  /// **'Disk activity'**
  String get systemDiskActivityTitle;

  /// System tab, Disk activity: a rate needs two readings, and only one has arrived.
  ///
  /// In en, this message translates to:
  /// **'Rates show from the second reading.'**
  String get systemDiskActivityWaiting;

  /// System tab, Disk activity: the server reports no whole disk that ever did I/O (loop, RAM and partition devices are left out).
  ///
  /// In en, this message translates to:
  /// **'No disk has done any I/O yet.'**
  String get systemDiskActivityEmpty;

  /// Disk activity column: bytes read per second.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get systemDiskRead;

  /// Disk activity column: bytes written per second.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get systemDiskWrite;

  /// Disk activity column: completed read requests per second (read IOPS).
  ///
  /// In en, this message translates to:
  /// **'Reads/s'**
  String get systemDiskReadsPerSecond;

  /// Disk activity column: completed write requests per second (write IOPS).
  ///
  /// In en, this message translates to:
  /// **'Writes/s'**
  String get systemDiskWritesPerSecond;

  /// Disk activity column: the mean time a read took, queueing included (iostat's r_await).
  ///
  /// In en, this message translates to:
  /// **'Read wait'**
  String get systemDiskReadAwait;

  /// Disk activity column: the mean time a write took, queueing included (iostat's w_await).
  ///
  /// In en, this message translates to:
  /// **'Write wait'**
  String get systemDiskWriteAwait;

  /// Disk activity column: the share of the interval the disk had any request in flight (iostat's %util).
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get systemDiskBusy;

  /// Disk activity: a whole number of requests per second, in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String systemDiskOperations(int count);

  /// Disk activity: a mean request time in milliseconds with one decimal, in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{ms} ms'**
  String systemDiskMilliseconds(double ms);

  /// System tab: the section of the host's temperature sensors (HW-01). It is hidden where the host has none, as VMs and containers usually do.
  ///
  /// In en, this message translates to:
  /// **'Temperatures'**
  String get systemTemperaturesTitle;

  /// Temperatures table: column of the sensor's name.
  ///
  /// In en, this message translates to:
  /// **'Sensor'**
  String get systemTemperatureSensor;

  /// Temperatures table: a sensor named by its chip (coretemp, nvme, k10temp) and the chip's label for it (Package id 0, Composite). Both are the kernel's technical names.
  ///
  /// In en, this message translates to:
  /// **'{chip}: {label}'**
  String systemTemperatureSensorName(String chip, String label);

  /// Temperatures table: column of the sensor's current reading.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get systemTemperatureReading;

  /// Temperatures table: column of the temperature the chip calls high for the sensor (its max limit).
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get systemTemperatureHigh;

  /// Temperatures table: column of the temperature the chip calls critical for the sensor.
  ///
  /// In en, this message translates to:
  /// **'Critical'**
  String get systemTemperatureCritical;

  /// A temperature in degrees Celsius, as a whole number in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{celsius} °C'**
  String systemTemperatureCelsius(double celsius);

  /// System tab: the section of the host's GPUs (HW-03). It is hidden where the host has none the app can read.
  ///
  /// In en, this message translates to:
  /// **'GPUs'**
  String get systemGpusTitle;

  /// GPUs table: column of the GPU's name, or its device name (card1, nvidia0) where the driver reports no product name.
  ///
  /// In en, this message translates to:
  /// **'GPU'**
  String get systemGpuColumn;

  /// GPUs table: column of the share of time the GPU was busy.
  ///
  /// In en, this message translates to:
  /// **'Busy'**
  String get systemGpuBusy;

  /// GPUs table: column of the GPU's own memory (VRAM) in use, of its total.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get systemGpuMemory;

  /// GPUs table: column of the GPU's current power draw.
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get systemGpuPower;

  /// A power draw in watts, as a whole number in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{watts} W'**
  String systemGpuWatts(double watts);

  /// System tab, GPUs: nvidia-smi ran and failed, as when its driver is not loaded; message is the tool's own first line, untranslated.
  ///
  /// In en, this message translates to:
  /// **'nvidia-smi is installed but failed: {message}'**
  String systemGpuNvidiaFailed(String message);

  /// System tab: the section of the running kernel against the installed ones (BOOT-03) and the boot timeline (BOOT-02).
  ///
  /// In en, this message translates to:
  /// **'Boots'**
  String get systemBootsTitle;

  /// A mount's details sheet, while it reads the mount's source and options (DSK-05).
  ///
  /// In en, this message translates to:
  /// **'Reading mount options…'**
  String get systemMountReading;

  /// A mount's details sheet when its source and options could not be read.
  ///
  /// In en, this message translates to:
  /// **'Mount options could not be read. {failure, select, noLink{Not connected to the server.} denied{The server denied the read.} missing{The server lacks a tool this read needs.} other{The read failed.}}'**
  String systemMountFailed(String failure);

  /// A mount's details sheet when the mount read no longer lists the mount point.
  ///
  /// In en, this message translates to:
  /// **'Nothing is mounted here any more.'**
  String get systemMountGone;

  /// Label of the device, share or image a filesystem is mounted from.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get systemMountSource;

  /// Label of a mount's options, such as rw and relatime.
  ///
  /// In en, this message translates to:
  /// **'Options'**
  String get systemMountOptions;

  /// A mount's details sheet when the filesystem is mounted read-only.
  ///
  /// In en, this message translates to:
  /// **'Mounted read-only'**
  String get systemMountReadOnly;

  /// Heading of the System tab's swap devices section (DSK-14).
  ///
  /// In en, this message translates to:
  /// **'Swap'**
  String get systemSwapTitle;

  /// The swap section while it reads the swap devices.
  ///
  /// In en, this message translates to:
  /// **'Reading swap devices…'**
  String get systemSwapReading;

  /// The swap section when the server uses no swap.
  ///
  /// In en, this message translates to:
  /// **'No swap devices are in use.'**
  String get systemSwapNone;

  /// The swap section when the swap devices could not be read.
  ///
  /// In en, this message translates to:
  /// **'Swap devices could not be read. {failure, select, noLink{Not connected to the server.} denied{The server denied the read.} missing{The server lacks a tool this read needs.} other{The read failed.}}'**
  String systemSwapFailed(String failure);

  /// How much of a swap device is used, out of its size.
  ///
  /// In en, this message translates to:
  /// **'{used} used of {size}'**
  String systemSwapUsage(String used, String size);

  /// What a swap device is (a disk partition or a file) and its priority; higher is used first.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, partition{Partition} file{File} other{Swap device}}, priority {priority}'**
  String systemSwapDetail(String kind, int priority);

  /// Button that reads the swap devices again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemSwapReadAgain;

  /// System tab, Boots: shown while the first read runs.
  ///
  /// In en, this message translates to:
  /// **'Reading kernels and boots…'**
  String get systemBootsReading;

  /// System tab, Boots: the button that reads the kernels and boots again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemBootsReadAgain;

  /// System tab, Boots: the release of the kernel the server runs, as uname -r prints it.
  ///
  /// In en, this message translates to:
  /// **'Running kernel {release}'**
  String systemKernelRunning(String release);

  /// System tab, Boots: whether a reboot would load a newer kernel (BOOT-03), by state.
  ///
  /// In en, this message translates to:
  /// **'{state, select, current{This is the newest kernel installed.} newerInstalled{Kernel {newest} is installed. A reboot loads it.} runningRemoved{The running kernel\'s modules were removed, as an upgrade does. A reboot loads {newest}.} other{Whether a newer kernel is installed is unknown: no module directory was found, as in a container.}}'**
  String systemKernelState(String state, String newest);

  /// System tab, Boots: why the kernel check read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server refused the kernel check.} missing{The server lacks the tools the kernel check runs.} other{The kernel check failed.}}'**
  String systemKernelFailed(String failure);

  /// System tab: the heading of the processor section (CPU-07).
  ///
  /// In en, this message translates to:
  /// **'Processor'**
  String get systemProcessorTitle;

  /// System tab, Processor: shown while the processor is read.
  ///
  /// In en, this message translates to:
  /// **'Reading the processor…'**
  String get systemProcessorReading;

  /// System tab, Processor: the button that reads the processor again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemProcessorReadAgain;

  /// System tab, Processor: the label of the processor's model name, or its vendor where the server names no model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get systemProcessorModel;

  /// System tab, Processor: why the model is unknown after a read that succeeded.
  ///
  /// In en, this message translates to:
  /// **'This processor does not report a model name, as is common on ARM boards.'**
  String get systemProcessorNoModel;

  /// System tab, Processor: the label of the number of physical processor packages.
  ///
  /// In en, this message translates to:
  /// **'Sockets'**
  String get systemProcessorSockets;

  /// System tab, Processor: the label of the number of physical cores across all sockets.
  ///
  /// In en, this message translates to:
  /// **'Cores'**
  String get systemProcessorCores;

  /// System tab, Processor: the label of how many hardware threads one core runs; 2 with simultaneous multithreading.
  ///
  /// In en, this message translates to:
  /// **'Threads per core'**
  String get systemProcessorThreadsPerCore;

  /// System tab, Processor: the label of how many CPUs the kernel counts.
  ///
  /// In en, this message translates to:
  /// **'Logical CPUs'**
  String get systemProcessorLogical;

  /// System tab, Processor: the label of how many CPUs the login's processes may run on: fewer than the logical CPUs when the processes are pinned to some of them, as in a container given a CPU set. A CPU time quota does not lower it.
  ///
  /// In en, this message translates to:
  /// **'Usable CPUs'**
  String get systemProcessorUsable;

  /// System tab, Processor: why the processor read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server refused the processor read.} missing{The server lacks the tools the processor read runs.} other{The processor read failed.}}'**
  String systemProcessorFailed(String failure);

  /// System tab: the heading of the listening ports section (NET-04).
  ///
  /// In en, this message translates to:
  /// **'Listening ports'**
  String get systemPortsTitle;

  /// System tab, Listening ports: shown while the ports are read.
  ///
  /// In en, this message translates to:
  /// **'Reading the listening ports…'**
  String get systemPortsReading;

  /// System tab, Listening ports: the button that reads the ports again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemPortsReadAgain;

  /// System tab, Listening ports: why the port read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server refused the port read.} missing{The server lacks the tools the port read runs.} other{The port read failed.}}'**
  String systemPortsFailed(String failure);

  /// System tab, Listening ports: shown when neither listing tool is installed. ss and netstat are command names, never translated.
  ///
  /// In en, this message translates to:
  /// **'The server has neither ss nor netstat, so its ports cannot be listed.'**
  String get systemPortsNoTool;

  /// System tab, Listening ports: shown when the login user could not see which process holds some sockets.
  ///
  /// In en, this message translates to:
  /// **'Some ports belong to other users\' processes, whose names only root may see.'**
  String get systemPortsHidden;

  /// System tab, Listening ports: shown when no socket listens.
  ///
  /// In en, this message translates to:
  /// **'Nothing listens on this server.'**
  String get systemPortsNone;

  /// System tab, Listening ports: a port that accepts connections on all of the server's addresses.
  ///
  /// In en, this message translates to:
  /// **'{protocol, select, tcp{TCP} udp{UDP} other{{protocol}}} {port} on every address'**
  String systemPortsEvery(String protocol, int port);

  /// System tab, Listening ports: a port that accepts connections only on the listed addresses, such as 127.0.0.1.
  ///
  /// In en, this message translates to:
  /// **'{protocol, select, tcp{TCP} udp{UDP} other{{protocol}}} {port} on {addresses}'**
  String systemPortsOn(String protocol, int port, String addresses);

  /// System tab, Listening ports: a process holding the port, by its command name and process ID.
  ///
  /// In en, this message translates to:
  /// **'{name} (PID {pid})'**
  String systemPortsProcess(String name, int pid);

  /// System tab, Listening ports: shown under a port whose process the login user may not see.
  ///
  /// In en, this message translates to:
  /// **'Held by another user\'s process'**
  String get systemPortsOwnerHidden;

  /// System tab, Listening ports: the systemd unit the process runs in, such as nginx.service.
  ///
  /// In en, this message translates to:
  /// **'Unit {unit}'**
  String systemPortsUnit(String unit);

  /// System tab, Listening ports: the container the process runs in, by its short ID.
  ///
  /// In en, this message translates to:
  /// **'Container {id}'**
  String systemPortsContainer(String id);

  /// System tab: the heading of the network interfaces section (NET-02, NET-03).
  ///
  /// In en, this message translates to:
  /// **'Interfaces'**
  String get systemNetInterfacesTitle;

  /// System tab, Interfaces: shown while the interfaces are read.
  ///
  /// In en, this message translates to:
  /// **'Reading the network interfaces…'**
  String get systemNetReading;

  /// System tab, Interfaces: the button that reads the interfaces again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemNetReadAgain;

  /// System tab, Interfaces: why the interface read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server refused the interface read.} missing{The server lacks the tools the interface read runs.} other{The interface read failed.}}'**
  String systemNetFailed(String failure);

  /// System tab, Interfaces: shown when the server could not list the interfaces' IP addresses.
  ///
  /// In en, this message translates to:
  /// **'The server has no ip command that lists addresses, so none are shown.'**
  String get systemNetNoAddresses;

  /// System tab, Interfaces: the checkbox that also lists the loopback and software interfaces without a routable address, such as containers' veth pairs; count is how many it adds.
  ///
  /// In en, this message translates to:
  /// **'Show loopback and virtual interfaces ({count})'**
  String systemNetShowAll(int count);

  /// System tab, Interfaces: shown when the read found no interface.
  ///
  /// In en, this message translates to:
  /// **'The server lists no network interfaces.'**
  String get systemNetNone;

  /// System tab, Interfaces: an interface's name and its operational state. name is the interface's name on the server, never translated.
  ///
  /// In en, this message translates to:
  /// **'{name}: {state, select, up{up} down{down} dormant{dormant} lowerLayerDown{lower layer down} notPresent{not present} testing{testing} other{state not reported}}'**
  String systemNetInterface(String name, String state);

  /// System tab, Interfaces: an IP address with its prefix length in CIDR notation.
  ///
  /// In en, this message translates to:
  /// **'{address}/{prefix}'**
  String systemNetAddress(String address, int prefix);

  /// System tab, Interfaces: the interface's maximum transmission unit in bytes.
  ///
  /// In en, this message translates to:
  /// **'MTU {mtu}'**
  String systemNetMtu(int mtu);

  /// System tab, Interfaces: the negotiated link speed in megabits per second.
  ///
  /// In en, this message translates to:
  /// **'Link speed {speed} Mb/s'**
  String systemNetSpeedMbps(int speed);

  /// System tab, Interfaces: the negotiated link speed in gigabits per second, such as 2.5.
  ///
  /// In en, this message translates to:
  /// **'Link speed {speed} Gb/s'**
  String systemNetSpeedGbps(double speed);

  /// System tab, Interfaces: the interface's current receive and transmit rates, already formatted.
  ///
  /// In en, this message translates to:
  /// **'Receiving {rx}, sending {tx}'**
  String systemNetRates(String rx, String tx);

  /// System tab, Interfaces: the interface's receive and transmit errors and dropped packets, counted since it came up.
  ///
  /// In en, this message translates to:
  /// **'Errors: {rxErrors} in, {txErrors} out. Dropped: {rxDropped} in, {txDropped} out.'**
  String systemNetErrors(
    int rxErrors,
    int txErrors,
    int rxDropped,
    int txDropped,
  );

  /// System tab, Interfaces: the heading over the socket counts (NET-03).
  ///
  /// In en, this message translates to:
  /// **'Connections'**
  String get systemNetConnectionsTitle;

  /// System tab, Interfaces: shown when /proc/net gave no socket counts.
  ///
  /// In en, this message translates to:
  /// **'The server\'s socket counts could not be read.'**
  String get systemNetConnectionsUnknown;

  /// System tab, Interfaces: the label of the number of established TCP connections.
  ///
  /// In en, this message translates to:
  /// **'TCP established'**
  String get systemNetTcpEstablished;

  /// System tab, Interfaces: the label of the number of TCP sockets listening for connections.
  ///
  /// In en, this message translates to:
  /// **'TCP listening'**
  String get systemNetTcpListening;

  /// System tab, Interfaces: the label of the number of closed TCP connections the kernel still holds in TIME-WAIT.
  ///
  /// In en, this message translates to:
  /// **'TCP time wait'**
  String get systemNetTcpTimeWait;

  /// System tab, Interfaces: the label of the number of TCP connections the peer closed and the local program has not; many point to a program leaking connections.
  ///
  /// In en, this message translates to:
  /// **'TCP close wait'**
  String get systemNetTcpCloseWait;

  /// System tab, Interfaces: the label of the number of TCP sockets opening or closing.
  ///
  /// In en, this message translates to:
  /// **'TCP in other states'**
  String get systemNetTcpOther;

  /// System tab, Interfaces: the label of the number of UDP sockets in use.
  ///
  /// In en, this message translates to:
  /// **'UDP sockets'**
  String get systemNetUdp;

  /// System tab, Interfaces: the label of the number of sockets of every kind in use.
  ///
  /// In en, this message translates to:
  /// **'All sockets'**
  String get systemNetSocketsUsed;

  /// System tab, Boots: the heading over the list of boots, newest first (BOOT-02).
  ///
  /// In en, this message translates to:
  /// **'Boot timeline'**
  String get systemBootsTimelineTitle;

  /// System tab, Boots: the current boot in the timeline.
  ///
  /// In en, this message translates to:
  /// **'This boot'**
  String get systemBootsCurrent;

  /// System tab, Boots: when a boot's journal starts and how long it ran until its last entry, under its name.
  ///
  /// In en, this message translates to:
  /// **'Started {start}, ran {duration}'**
  String systemBootsSpan(String start, String duration);

  /// System tab, Boots: how an earlier boot ended (BOOT-02), by kind.
  ///
  /// In en, this message translates to:
  /// **'{end, select, clean{Shut down cleanly} unclean{Ended without a shutdown: a crash, power loss or hard reset} other{How it ended is unknown: its journal is not readable as this user}}'**
  String systemBootEnd(String end);

  /// System tab, Boots: shown when journalctl lists no boots.
  ///
  /// In en, this message translates to:
  /// **'The journal lists no boots.'**
  String get systemBootsNone;

  /// System tab, Boots: how many older boots the timeline leaves out; the Logs panel's boot picker lists every boot.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 earlier boot is not listed.} other{{count} earlier boots are not listed.}}'**
  String systemBootsNotListed(int count);

  /// System tab, Boots: shown under the timeline when reading the boots' ends failed.
  ///
  /// In en, this message translates to:
  /// **'How the earlier boots ended could not be read.'**
  String get systemBootEndsUnknown;

  /// System tab: the section of each drive's SMART health (HW-04), read on request in admin mode.
  ///
  /// In en, this message translates to:
  /// **'Drive health'**
  String get systemDriveHealthTitle;

  /// System tab, Drive health: shown while admin mode is off for the server.
  ///
  /// In en, this message translates to:
  /// **'Turn on admin mode to read drive health: smartctl needs the drives\' device nodes.'**
  String get systemDriveHealthAdminNeeded;

  /// System tab, Drive health: the button that reads every drive's SMART health. Drives that are spun down are left asleep.
  ///
  /// In en, this message translates to:
  /// **'Read drive health'**
  String get systemDriveHealthRead;

  /// System tab, Drive health: the button that reads every drive's health again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemDriveHealthReadAgain;

  /// System tab, Drive health: shown while the read runs.
  ///
  /// In en, this message translates to:
  /// **'Reading drive health…'**
  String get systemDriveHealthReading;

  /// System tab, Drive health: why a read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{The server is not connected, so drive health could not be read.} adminRequired{Admin mode ended before drive health was read.} elevationRefused{Elevation was refused, so drive health was not read.} missing{smartmontools is not installed on this server.} unreadable{smartctl did not answer as smartmontools 7.0 or later does.} transport{The connection failed while drive health was read.} other{Drive health could not be read.}}'**
  String systemDriveHealthFailed(String reason);

  /// System tab, Drive health: the read found no drive, as in a VM without passed-through disks.
  ///
  /// In en, this message translates to:
  /// **'No drive answered smartctl\'s scan.'**
  String get systemDriveHealthNone;

  /// System tab, Drive health: drives past the read's limit, which were not read.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more drive was not read.} other{{count} more drives were not read.}}'**
  String systemDriveHealthNotRead(int count);

  /// System tab: the heading of the firewall section (NET-06).
  ///
  /// In en, this message translates to:
  /// **'Firewall'**
  String get systemFirewallTitle;

  /// System tab, Firewall: why the read waits for admin mode.
  ///
  /// In en, this message translates to:
  /// **'Turn on admin mode to read the firewall: every firewall tool needs root to list its rules.'**
  String get systemFirewallAdminNeeded;

  /// System tab, Firewall: the button that reads the rules.
  ///
  /// In en, this message translates to:
  /// **'Read firewall rules'**
  String get systemFirewallRead;

  /// System tab, Firewall: the button that reads the rules again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemFirewallReadAgain;

  /// System tab, Firewall: shown while the rules are read.
  ///
  /// In en, this message translates to:
  /// **'Reading the firewall rules…'**
  String get systemFirewallReading;

  /// System tab, Firewall: why a read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{The server is not connected, so the firewall could not be read.} adminRequired{Admin mode ended before the firewall was read.} elevationRefused{Elevation was refused, so the firewall was not read.} unreadable{The firewall tools answered in a way this app cannot read.} transport{The connection failed while the firewall was read.} other{The firewall could not be read.}}'**
  String systemFirewallFailed(String reason);

  /// System tab, Firewall: the read found no firewall tool.
  ///
  /// In en, this message translates to:
  /// **'No firewall tool was found on this server: none of ufw, firewalld, nft or iptables is installed.'**
  String get systemFirewallNoTool;

  /// System tab, Firewall: the heading of ufw's rules; a product name.
  ///
  /// In en, this message translates to:
  /// **'ufw'**
  String get systemFirewallUfw;

  /// System tab, Firewall: the heading of firewalld's zones; a product name.
  ///
  /// In en, this message translates to:
  /// **'firewalld'**
  String get systemFirewallFirewalld;

  /// System tab, Firewall: the heading of the nftables chains; a product name.
  ///
  /// In en, this message translates to:
  /// **'nftables'**
  String get systemFirewallNftables;

  /// System tab, Firewall: the heading of the IPv4 iptables chains.
  ///
  /// In en, this message translates to:
  /// **'iptables (IPv4)'**
  String get systemFirewallIptables;

  /// System tab, Firewall: the heading of the IPv6 iptables chains.
  ///
  /// In en, this message translates to:
  /// **'ip6tables (IPv6)'**
  String get systemFirewallIp6tables;

  /// System tab, Firewall: whether ufw is enabled.
  ///
  /// In en, this message translates to:
  /// **'{active, select, true{Active} other{Inactive: ufw filters nothing}}'**
  String systemFirewallActive(String active);

  /// System tab, Firewall: whether firewalld runs.
  ///
  /// In en, this message translates to:
  /// **'{running, select, true{Running} other{Not running}}'**
  String systemFirewallRunning(String running);

  /// System tab, Firewall: ufw's default policy per direction, each as ufw names it (deny, allow, reject, disabled).
  ///
  /// In en, this message translates to:
  /// **'By default: incoming {incoming}, outgoing {outgoing}, routed {routed}'**
  String systemFirewallUfwDefaults(
    String incoming,
    String outgoing,
    String routed,
  );

  /// System tab, Firewall: one ufw rule, its parts as ufw prints them, such as 22/tcp: ALLOW IN from Anywhere.
  ///
  /// In en, this message translates to:
  /// **'{to}: {action} from {from}'**
  String systemFirewallUfwRule(String to, String action, String from);

  /// System tab, Firewall: a tool that holds no rules.
  ///
  /// In en, this message translates to:
  /// **'No rules.'**
  String get systemFirewallNoRules;

  /// System tab, Firewall: the firewalld zone new interfaces join.
  ///
  /// In en, this message translates to:
  /// **'{zone} (default zone)'**
  String systemFirewallZoneDefault(String zone);

  /// System tab, Firewall: the interfaces bound to a firewalld zone.
  ///
  /// In en, this message translates to:
  /// **'Interfaces: {interfaces}'**
  String systemFirewallZoneInterfaces(String interfaces);

  /// System tab, Firewall: the source addresses bound to a firewalld zone.
  ///
  /// In en, this message translates to:
  /// **'Sources: {sources}'**
  String systemFirewallZoneSources(String sources);

  /// System tab, Firewall: the services a firewalld zone lets in.
  ///
  /// In en, this message translates to:
  /// **'Services allowed: {services}'**
  String systemFirewallZoneServices(String services);

  /// System tab, Firewall: the ports a firewalld zone lets in beside its services.
  ///
  /// In en, this message translates to:
  /// **'Ports allowed: {ports}'**
  String systemFirewallZonePorts(String ports);

  /// System tab, Firewall: a firewalld zone that allows no service.
  ///
  /// In en, this message translates to:
  /// **'none'**
  String get systemFirewallNone;

  /// System tab, Firewall: zones that apply to no traffic, not listed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 other zone has no interface or source.} other{{count} other zones have no interface or source.}}'**
  String systemFirewallZonesIdle(int count);

  /// System tab, Firewall: one chain, named by its family, table and name, with its default policy as the tool prints it (accept, drop) and how many rules it holds.
  ///
  /// In en, this message translates to:
  /// **'{chain}: policy {policy}, {rules, plural, =0{no rules} =1{1 rule} other{{rules} rules}}'**
  String systemFirewallChain(String chain, String policy, int rules);

  /// System tab, Firewall: a chain without a default policy, which only other chains jump to.
  ///
  /// In en, this message translates to:
  /// **'none'**
  String get systemFirewallNoPolicy;

  /// System tab: the heading of the SSH server section (SEC-01).
  ///
  /// In en, this message translates to:
  /// **'SSH server'**
  String get systemSshdTitle;

  /// System tab, SSH server: why the read waits for admin mode.
  ///
  /// In en, this message translates to:
  /// **'Turn on admin mode to read the SSH server\'s settings: sshd needs root to print them.'**
  String get systemSshdAdminNeeded;

  /// System tab, SSH server: the button that reads the settings.
  ///
  /// In en, this message translates to:
  /// **'Read SSH server settings'**
  String get systemSshdRead;

  /// System tab, SSH server: the button that reads the settings again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemSshdReadAgain;

  /// System tab, SSH server: shown while the settings are read.
  ///
  /// In en, this message translates to:
  /// **'Reading the SSH server\'s settings…'**
  String get systemSshdReading;

  /// System tab, SSH server: why a read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{The server is not connected, so the SSH server\'s settings could not be read.} adminRequired{Admin mode ended before the SSH server\'s settings were read.} elevationRefused{Elevation was refused, so the SSH server\'s settings were not read.} missing{No sshd was found on this server.} refused{sshd refused to print its settings, as for an error in its configuration.} unreadable{sshd\'s settings could not be read.} transport{The connection failed while the SSH server\'s settings were read.} other{The SSH server\'s settings could not be read.}}'**
  String systemSshdFailed(String reason);

  /// System tab, SSH server: the settings apply the Match blocks for the user and the device's address, but not those for the server's local address and port.
  ///
  /// In en, this message translates to:
  /// **'Match blocks for the server\'s own address or port are not applied: this sshd is too old to be told them.'**
  String get systemSshdMatchRemote;

  /// System tab, SSH server: the settings ignore every Match block in the configuration.
  ///
  /// In en, this message translates to:
  /// **'No Match blocks are applied: these are sshd\'s settings before any Match block, as the read could not name this connection.'**
  String get systemSshdMatchNone;

  /// System tab, SSH server: the label of the ports sshd listens on.
  ///
  /// In en, this message translates to:
  /// **'Ports'**
  String get systemSshdPorts;

  /// System tab, SSH server: the label of the addresses and ports sshd listens on.
  ///
  /// In en, this message translates to:
  /// **'Listens on'**
  String get systemSshdListen;

  /// System tab, SSH server: the label of whether root may log in (PermitRootLogin).
  ///
  /// In en, this message translates to:
  /// **'Root login'**
  String get systemSshdRootLogin;

  /// System tab, SSH server: whether root may log in.
  ///
  /// In en, this message translates to:
  /// **'{value, select, yes{Allowed} no{Not allowed} keysOnly{With a key only} forcedCommandsOnly{Forced commands only} other{Unknown}}'**
  String systemSshdRoot(String value);

  /// System tab, SSH server: the label of whether passwords are accepted (PasswordAuthentication).
  ///
  /// In en, this message translates to:
  /// **'Password login'**
  String get systemSshdPassword;

  /// System tab, SSH server: the label of whether keyboard-interactive login is accepted, as for one-time codes (KbdInteractiveAuthentication).
  ///
  /// In en, this message translates to:
  /// **'Keyboard-interactive login'**
  String get systemSshdKeyboard;

  /// System tab, SSH server: the label of whether public keys are accepted (PubkeyAuthentication).
  ///
  /// In en, this message translates to:
  /// **'Key login'**
  String get systemSshdPubkey;

  /// System tab, SSH server: whether a login method is accepted.
  ///
  /// In en, this message translates to:
  /// **'{state, select, true{On} false{Off} other{Unknown}}'**
  String systemSshdEnabled(String state);

  /// System tab, SSH server: the label of the login methods every login must pass, in sshd's notation (AuthenticationMethods).
  ///
  /// In en, this message translates to:
  /// **'Required login methods'**
  String get systemSshdMethods;

  /// System tab, SSH server: the label of the server's host key types.
  ///
  /// In en, this message translates to:
  /// **'Host keys'**
  String get systemSshdHostKeys;

  /// System tab, SSH server: the label of the user key types sshd accepts (PubkeyAcceptedAlgorithms).
  ///
  /// In en, this message translates to:
  /// **'Accepted user key types'**
  String get systemSshdUserKeys;

  /// System tab, SSH server: the label of how many sessions one connection may open at once (MaxSessions); the app needs several.
  ///
  /// In en, this message translates to:
  /// **'Sessions per connection'**
  String get systemSshdMaxSessions;

  /// System tab, SSH server: the label of whether ports may be forwarded (AllowTcpForwarding).
  ///
  /// In en, this message translates to:
  /// **'TCP forwarding'**
  String get systemSshdTcpForwarding;

  /// System tab, SSH server: the label of whether Unix sockets may be forwarded (AllowStreamLocalForwarding).
  ///
  /// In en, this message translates to:
  /// **'Socket forwarding'**
  String get systemSshdSocketForwarding;

  /// System tab, SSH server: whether forwarding is allowed, and in which direction.
  ///
  /// In en, this message translates to:
  /// **'{value, select, all{Allowed} local{Local only} remote{Remote only} no{Off} other{Unknown}}'**
  String systemSshdForwarding(String value);

  /// System tab, SSH server: the label of where forwarded connections may go, in sshd's notation (PermitOpen); any means anywhere.
  ///
  /// In en, this message translates to:
  /// **'Forwarding targets'**
  String get systemSshdPermitOpen;

  /// System tab, SSH server: the label of whether sshd lets the app reach Docker's socket by forwarding it.
  ///
  /// In en, this message translates to:
  /// **'Docker over SSH'**
  String get systemSshdDocker;

  /// System tab, SSH server: no sshd setting blocks the forwarding of Docker's socket.
  ///
  /// In en, this message translates to:
  /// **'Not blocked by sshd\'s settings'**
  String get systemSshdDockerAllowed;

  /// System tab, SSH server: the sshd settings that block the forwarding of Docker's socket; settings lists their names as in sshd_config.
  ///
  /// In en, this message translates to:
  /// **'Blocked by {settings}'**
  String systemSshdDockerBlocked(String settings);

  /// System tab, SSH server: why Docker may still be blocked when no setting blocks it.
  ///
  /// In en, this message translates to:
  /// **'A key\'s options in authorized_keys, such as restrict, can block it too; sshd does not show those.'**
  String get systemSshdDockerNote;

  /// System tab: the heading of the section that checks the TLS certificates of endpoints the user lists (CRT-01).
  ///
  /// In en, this message translates to:
  /// **'Certificates'**
  String get systemCertificatesTitle;

  /// System tab, Certificates: shown while the server has no endpoints listed.
  ///
  /// In en, this message translates to:
  /// **'List the host names and ports whose certificates this device should check, such as this server\'s web sites.'**
  String get systemCertificatesNone;

  /// System tab, Certificates: the list was changed but writing settings.json failed.
  ///
  /// In en, this message translates to:
  /// **'The endpoints could not be saved on this device; they are kept until the app quits.'**
  String get systemCertificatesNotSaved;

  /// System tab, Certificates: the button that checks every listed endpoint again.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get systemCertificatesCheck;

  /// System tab, Certificates: the button that opens the list of endpoints to check.
  ///
  /// In en, this message translates to:
  /// **'Edit endpoints…'**
  String get systemCertificatesEdit;

  /// System tab, Certificates: an endpoint's line while its check runs.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get systemCertificatesChecking;

  /// System tab, Certificates: an endpoint's line before any check answered, as after the engine stopped.
  ///
  /// In en, this message translates to:
  /// **'Not checked yet'**
  String get systemCertificatesNotChecked;

  /// System tab, Certificates: why an endpoint's check read no certificate, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, lookup{The host name did not resolve from this device.} connect{This device could not connect.} timeout{No answer within 10 seconds.} handshake{The endpoint answered, but not with TLS.} other{The check failed.}}'**
  String systemCertificatesFailed(String reason);

  /// System tab, Certificates: when an endpoint's certificate expires and how many whole days are left.
  ///
  /// In en, this message translates to:
  /// **'Expires {date}, {days, plural, =0{today} =1{in 1 day} other{in {days} days}}'**
  String systemCertificatesExpires(DateTime date, int days);

  /// System tab, Certificates: an endpoint presents a certificate that has expired.
  ///
  /// In en, this message translates to:
  /// **'Expired {date}'**
  String systemCertificatesExpired(DateTime date);

  /// System tab, Certificates: the device's trust store rejected the certificate.
  ///
  /// In en, this message translates to:
  /// **'This device does not trust this certificate for the host name: it may be self-signed, expired or issued for another name.'**
  String get systemCertificatesUntrusted;

  /// System tab, Certificates: who issued an endpoint's certificate, as the certificate names it.
  ///
  /// In en, this message translates to:
  /// **'Issued by {issuer}'**
  String systemCertificatesIssuer(String issuer);

  /// System tab, Certificates: the title of the dialog that lists the endpoints.
  ///
  /// In en, this message translates to:
  /// **'Endpoints to check'**
  String get systemCertificatesEditTitle;

  /// System tab, Certificates: how to list endpoints.
  ///
  /// In en, this message translates to:
  /// **'One per line: a host name or address, with :port for a port other than 443. At most {max}.'**
  String systemCertificatesHelper(int max);

  /// System tab, Certificates: why the list was not taken, by problem.
  ///
  /// In en, this message translates to:
  /// **'{problem, select, notEndpoint{Each line needs a host name or address, with an optional :port.} tooMany{List at most {max} endpoints.} other{These endpoints cannot be checked.}}'**
  String systemCertificatesProblem(String problem, int max);

  /// System tab, Certificates: closes the endpoints dialog without changes.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get systemCertificatesCancel;

  /// System tab, Certificates: keeps the listed endpoints and checks them.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get systemCertificatesSave;

  /// System tab: heading of the section listing the server's accounts and who is logged in (ACC-01, ACC-02).
  ///
  /// In en, this message translates to:
  /// **'Users'**
  String get systemAccountsTitle;

  /// System tab, Users: column of the account's name.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get systemAccountsColumn;

  /// System tab, Users: column of the account's numeric user ID.
  ///
  /// In en, this message translates to:
  /// **'UID'**
  String get systemAccountsUid;

  /// System tab, Users: column saying why the account can become root, empty for most accounts.
  ///
  /// In en, this message translates to:
  /// **'Root access'**
  String get systemAccountsRoot;

  /// System tab, Users: column of the account's groups, its primary group first.
  ///
  /// In en, this message translates to:
  /// **'Groups'**
  String get systemAccountsGroups;

  /// System tab, Users: column of the account's login shell.
  ///
  /// In en, this message translates to:
  /// **'Shell'**
  String get systemAccountsShell;

  /// System tab, Users: one reason the account can become root; reason is the engine's RootEquivalence name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, uidZero{UID 0} adminGroup{sudo, wheel or admin group} dockerGroup{docker group} other{Can become root}}'**
  String systemAccountsRootReason(String reason);

  /// System tab, Users: why a read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{The server is not connected, so its accounts could not be read.} unreadable{The server\'s answer could not be read as its accounts.} transport{The connection failed while the accounts were read.} other{The accounts could not be read.}}'**
  String systemAccountsFailed(String reason);

  /// System tab, Users: shown while the first read runs.
  ///
  /// In en, this message translates to:
  /// **'Reading accounts…'**
  String get systemAccountsReading;

  /// System tab, Users: accounts past the read's limit, as on a host whose directory lists thousands.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more account is not listed.} other{{count} more accounts are not listed.}}'**
  String systemAccountsNotListed(int count);

  /// System tab, Users: button that lists the accounts without a login shell or below the people's UID range, hidden by default.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Show 1 service account} other{Show {count} service accounts}}'**
  String systemAccountsShowSystem(int count);

  /// System tab, Users: button that hides the service accounts again.
  ///
  /// In en, this message translates to:
  /// **'Hide service accounts'**
  String get systemAccountsHideSystem;

  /// System tab, Users: heading of the list of current logins.
  ///
  /// In en, this message translates to:
  /// **'Logged in'**
  String get systemAccountsSessionsTitle;

  /// System tab, Users: the server lists no login.
  ///
  /// In en, this message translates to:
  /// **'No one is logged in.'**
  String get systemAccountsSessionsNone;

  /// System tab, Users: the server's who printed lines the app could not parse, as BusyBox's.
  ///
  /// In en, this message translates to:
  /// **'Who is logged in is unknown: this server\'s who prints a format the app does not read.'**
  String get systemAccountsSessionsUnknown;

  /// System tab, Users: a local login; since is when it began, in this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{user} on {line}, since {since}'**
  String systemAccountsSessionLocal(String user, String line, DateTime since);

  /// System tab, Users: a remote login with the host or address it came from; since is when it began, in this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{user} on {line} from {from}, since {since}'**
  String systemAccountsSessionRemote(
    String user,
    String line,
    String from,
    DateTime since,
  );

  /// System tab, Users: button that reads the accounts and logins again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get systemAccountsReadAgain;

  /// Drive health table: column of the drive's model, or its device where it reports none.
  ///
  /// In en, this message translates to:
  /// **'Drive'**
  String get systemDriveColumn;

  /// Drive health table: column of the drive's device node, such as /dev/sda.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get systemDriveDevice;

  /// Drive health table: column of the drive's health verdict.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get systemDriveHealth;

  /// Drive health table: a drive's health. Passed: its own assessment passed. Warning: it passed, but shows wear or damage. Failing: its own assessment failed. Asleep: it was spun down and was left asleep.
  ///
  /// In en, this message translates to:
  /// **'{verdict, select, passed{Passed} warning{Warning} failing{Failing} asleep{Asleep} other{Unknown}}'**
  String systemDriveVerdict(String verdict);

  /// Drive health table: column of an NVMe drive's endurance used, as a percentage that may pass 100.
  ///
  /// In en, this message translates to:
  /// **'Wear'**
  String get systemDriveWear;

  /// Drive health table: column of an ATA drive's reallocated, pending and uncorrectable sectors, summed.
  ///
  /// In en, this message translates to:
  /// **'Bad sectors'**
  String get systemDriveBadSectors;

  /// Drive health table: a drive's bad sectors, a whole number in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String systemDriveBadSectorCount(int count);

  /// Drive health table: column of how long the drive has been powered on over its life.
  ///
  /// In en, this message translates to:
  /// **'Powered on'**
  String get systemDrivePowerOn;

  /// Drive health table: a number of hours in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'{hours} h'**
  String systemDriveHours(int hours);

  /// System tab: the section of the server's time zone, time sync and clock against this device's (SYS-02, CN-17).
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get systemTimeTitle;

  /// System tab, Time: label of the server's time zone, an IANA name such as Europe/Berlin or its UTC offset.
  ///
  /// In en, this message translates to:
  /// **'Time zone'**
  String get systemTimeZone;

  /// System tab, Time: label of whether the server keeps its clock in sync over NTP.
  ///
  /// In en, this message translates to:
  /// **'Time sync'**
  String get systemTimeSync;

  /// System tab, Time sync: the kernel clock is in sync.
  ///
  /// In en, this message translates to:
  /// **'Synchronized'**
  String get systemTimeSynced;

  /// System tab, Time sync: a sync service is on but the clock is not in sync yet.
  ///
  /// In en, this message translates to:
  /// **'Not synchronized'**
  String get systemTimeNotSynced;

  /// System tab, Time sync: no time sync service is enabled.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get systemTimeSyncOff;

  /// System tab, Time: label of how far the server's clock is from this device's.
  ///
  /// In en, this message translates to:
  /// **'Clock'**
  String get systemClock;

  /// System tab, Time: the server's clock is within about a second of this device's.
  ///
  /// In en, this message translates to:
  /// **'In step with this device'**
  String get systemClockInStep;

  /// System tab, Time: the server's clock is ahead of this device's by amount, such as '3 seconds'.
  ///
  /// In en, this message translates to:
  /// **'{amount} ahead of this device'**
  String systemClockAhead(String amount);

  /// System tab, Time: the server's clock is behind this device's by amount, such as '2 minutes'.
  ///
  /// In en, this message translates to:
  /// **'{amount} behind this device'**
  String systemClockBehind(String amount);

  /// A clock difference in seconds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 second} other{{count} seconds}}'**
  String systemClockSeconds(int count);

  /// A clock difference in minutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute} other{{count} minutes}}'**
  String systemClockMinutes(int count);

  /// A clock difference in hours.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour} other{{count} hours}}'**
  String systemClockHours(int count);

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

  /// A value past its careful threshold (OV-11), below warning: shown with an info icon in the usual colour.
  ///
  /// In en, this message translates to:
  /// **'careful'**
  String get chartSeverityCareful;

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

  /// Access tab row title: whether the SSH server allows forwarding to a Unix socket, which the Docker tab uses. 'Streamlocal' is OpenSSH's term; keep it.
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

  /// Access tab row reason for streamlocal forwarding before the engine has looked for the server's Docker endpoint (no connection yet, or still looking).
  ///
  /// In en, this message translates to:
  /// **'Checked when Klabautermann looks for this server\'s Docker engine, after it connects.'**
  String get accessReasonDockerEndpointPending;

  /// Access tab row reason: the SSH server forwards the Docker engine's Unix socket (streamlocal, transport rank 1).
  ///
  /// In en, this message translates to:
  /// **'The SSH server forwards the engine socket, the fastest route to Docker.'**
  String get accessReasonStreamlocalAllowed;

  /// Access tab row reason: the SSH server refused to forward a socket the account can use. AllowStreamLocalForwarding and DisableForwarding are sshd_config option names; keep them.
  ///
  /// In en, this message translates to:
  /// **'The SSH server refused to forward the engine socket (AllowStreamLocalForwarding or DisableForwarding in its sshd_config). Docker goes through a slower relay on the server when it has one.'**
  String get accessReasonStreamlocalDisabled;

  /// Access tab row reason: the SSH server could not open the engine socket because the login account may not use it; 'Docker socket' is the accessItemDockerSocket row title.
  ///
  /// In en, this message translates to:
  /// **'The SSH server could not open the engine socket as your account, which cannot use it. The Docker socket row shows how access is granted.'**
  String get accessReasonStreamlocalSocketDenied;

  /// Access tab row reason: the Docker endpoint failed before any socket could be tried (none found, the check failed, or the engine did not answer).
  ///
  /// In en, this message translates to:
  /// **'Not tested: no engine socket could be tried. The Docker tab says why.'**
  String get accessReasonStreamlocalUntested;

  /// Access tab row reason: the docker compose plugin is installed; version is its version as it printed it, such as 2.29.7.
  ///
  /// In en, this message translates to:
  /// **'Version {version}.'**
  String accessReasonComposePlugin(String version);

  /// Access tab row reason: only the standalone docker-compose binary (Compose v2) is installed; version is its version.
  ///
  /// In en, this message translates to:
  /// **'Only the standalone docker-compose {version} is installed. Stacks show read-only and their sources are not verified.'**
  String accessReasonComposeStandaloneOnly(String version);

  /// Access tab row reason: only the Python Compose v1 binary is installed; version is its version, such as 1.29.2.
  ///
  /// In en, this message translates to:
  /// **'Only Compose v1 ({version}) is installed, unmaintained since 2023. Stacks show read-only.'**
  String accessReasonComposeLegacyOnly(String version);

  /// Access tab row reason: no compose command was found on the server. Both are command names; keep them.
  ///
  /// In en, this message translates to:
  /// **'Neither docker compose nor docker-compose is installed.'**
  String get accessReasonNoCompose;

  /// Access tab row reason for the compose plugin before the Docker endpoint is ready.
  ///
  /// In en, this message translates to:
  /// **'Checked once Klabautermann reaches this server\'s Docker engine.'**
  String get accessReasonComposeNotChecked;

  /// Access tab row reason: the command that looks for the compose plugin failed.
  ///
  /// In en, this message translates to:
  /// **'The check for docker compose failed on this server.'**
  String get accessReasonComposeCheckFailed;

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

  /// Access tab runtime row reason: the user chose this server's Docker engine socket in the Docker tab (CN-09); path is the socket's path on the server.
  ///
  /// In en, this message translates to:
  /// **'Chosen manually on this device: {path}'**
  String accessReasonRuntimeChosen(String path);

  /// Access tab runtime row reason: the socket the user chose is not the one in use; path is the chosen socket's path on the server.
  ///
  /// In en, this message translates to:
  /// **'{path} was chosen on this device, but Docker does not use it: it did not answer, so another socket or none is in use.'**
  String accessReasonRuntimeChosenUnavailable(String path);

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
  /// **'Podman can also answer on Docker\'s socket path. Once connected, the server header names the engine that answers.'**
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

  /// Spoken name of the stdout or stderr mark at the start of a container's log line, after its time (CTX-01); the screen shows the stream's technical name.
  ///
  /// In en, this message translates to:
  /// **'{stream, select, stderr{standard error} other{standard output}}'**
  String logContainerStream(String stream);

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

  /// Tooltip and title of the Logs panel's boot picker, which chooses the server start whose journal or kernel entries are shown.
  ///
  /// In en, this message translates to:
  /// **'Boot'**
  String get logsPanelBoot;

  /// The boot picker's choice: every boot the journal keeps, or only the one since the server last started.
  ///
  /// In en, this message translates to:
  /// **'{choice, select, all{All boots} current{This boot} other{Boot}}'**
  String logsPanelBootChoice(String choice);

  /// A past boot in the boot picker, counted back from the current one.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Previous boot} other{{count} boots ago}}'**
  String logsPanelBootPast(int count);

  /// When a boot's first and last journal entries were written, under its name in the boot picker.
  ///
  /// In en, this message translates to:
  /// **'{start} to {end}'**
  String logsPanelBootSpan(String start, String end);

  /// Shown in the boot picker while the server lists its boots.
  ///
  /// In en, this message translates to:
  /// **'Reading the server\'s boots…'**
  String get logsPanelBootsLoading;

  /// Shown in the boot picker when the server's boots could not be listed.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server denied access to its boot list.} missing{The server has no journal to list boots from.} other{Reading the server\'s boots failed.}}'**
  String logsPanelBootsFailed(String failure);

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

  /// Button beside the file path field that lists the server's log files under /var/log (LOG-08).
  ///
  /// In en, this message translates to:
  /// **'Browse /var/log'**
  String get logsPanelBrowseFiles;

  /// Title of the sheet listing the server's log files under /var/log.
  ///
  /// In en, this message translates to:
  /// **'Files in /var/log'**
  String get logsPanelFiles;

  /// Label of the field that narrows the /var/log listing to paths containing its text.
  ///
  /// In en, this message translates to:
  /// **'Filter by name'**
  String get logsPanelFilesFilter;

  /// Shown in the /var/log browser while the server lists its files.
  ///
  /// In en, this message translates to:
  /// **'Listing the server\'s log files…'**
  String get logsPanelFilesLoading;

  /// Shown in the /var/log browser when the server's files could not be listed.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Not connected to the server.} denied{The server denied access to /var/log.} missing{The server cannot list /var/log.} other{Listing the server\'s log files failed.}}'**
  String logsPanelFilesFailed(String failure);

  /// Shown in the /var/log browser when the listing is empty.
  ///
  /// In en, this message translates to:
  /// **'The server has no files under /var/log.'**
  String get logsPanelFilesEmpty;

  /// Shown in the /var/log browser when the filter matches no file.
  ///
  /// In en, this message translates to:
  /// **'No file path contains this text.'**
  String get logsPanelFilesNoMatch;

  /// Under a file's path in the /var/log browser: its size and when it last changed.
  ///
  /// In en, this message translates to:
  /// **'{size}, changed {modified}'**
  String logsPanelFileDetails(String size, String modified);

  /// Under a rotated .gz or .xz file in the /var/log browser.
  ///
  /// In en, this message translates to:
  /// **'Compressed: reads its last lines, without following'**
  String get logsPanelFileCompressed;

  /// Under a file in the /var/log browser that the server account may not read.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot read it; admin mode can'**
  String get logsPanelFileUnreadable;

  /// Tooltip of the Logs panel's button that exports the lines it holds (LOG-10).
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get logsExport;

  /// Title of the log export sheet.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Export 1 line} other{Export {count} lines}}'**
  String logsExportTitle(int count);

  /// Switch in the log export sheet that turns off redaction.
  ///
  /// In en, this message translates to:
  /// **'Include secrets'**
  String get logsExportIncludeSecrets;

  /// Under the Include secrets switch while it is off.
  ///
  /// In en, this message translates to:
  /// **'Passwords, tokens and keys are replaced before the lines leave the app.'**
  String get logsExportSecretsRedacted;

  /// Under the Include secrets switch while it is on.
  ///
  /// In en, this message translates to:
  /// **'The lines leave the app as they are, secrets included.'**
  String get logsExportSecretsIncluded;

  /// A button in the log export sheet: copy to the clipboard, save to a file, or open the share sheet.
  ///
  /// In en, this message translates to:
  /// **'{target, select, copy{Copy} save{Save…} other{Share…}}'**
  String logsExportAction(String target);

  /// Toast after the log export copied or saved the lines.
  ///
  /// In en, this message translates to:
  /// **'{target, select, copy{Copied the lines.} other{Saved the lines.}}'**
  String logsExportDone(String target);

  /// Toast when the log export failed.
  ///
  /// In en, this message translates to:
  /// **'{target, select, copy{The lines could not be copied.} save{The lines could not be saved.} other{The lines could not be shared.}}'**
  String logsExportFailed(String target);

  /// Toast when the engine could not redact the lines; the export never falls back to the unredacted text.
  ///
  /// In en, this message translates to:
  /// **'The lines could not be redacted, so nothing was exported.'**
  String get logsExportNotRedacted;

  /// The suggested file name for a saved log export. Keep it a valid file name.
  ///
  /// In en, this message translates to:
  /// **'{source, select, journal{journal} kernel{kernel} other{log}}.log'**
  String logsExportFileName(String source);

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

  /// Tooltip of the Logs panel's Live chip while it is off because a past boot is shown.
  ///
  /// In en, this message translates to:
  /// **'A past boot has no new entries to follow'**
  String get logsPanelLivePastBoot;

  /// Tooltip of the Logs panel's Live chip while it is off because a compressed rotated file is shown.
  ///
  /// In en, this message translates to:
  /// **'A compressed file has no new lines to follow'**
  String get logsPanelLiveCompressed;

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
  /// **'{status, select, opening{Opening the log…} waitingLink{Waiting for the connection to the server.} waitingChannel{Waiting for a free session on the server.} waitingBackground{Paused while the app is in the background.} gap{Following again. Lines written while it was paused or disconnected may be missing.} loading{Loading entries…} invalid{The engine refused this filter or path.} missing{The server has no such file or log tool.} denied{The server denied access to this log.} failed{Reading the log failed.} rejected{The engine did not open this log.} searchUnsupported{This server\'s journal cannot search. Clear the server search to read the log.} other{Choose or type the absolute path of a file to tail.}}'**
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

  /// Tooltip of the toggle that makes the log search read its text as a regular expression.
  ///
  /// In en, this message translates to:
  /// **'Regular expression'**
  String get logsPanelSearchRegex;

  /// Error under the log search field when its text, read as a regular expression, does not compile.
  ///
  /// In en, this message translates to:
  /// **'Not a valid regular expression'**
  String get logsPanelSearchInvalid;

  /// Tooltip of the button that reads only the journal entries matching the search, matched by the server, rather than searching the entries already shown.
  ///
  /// In en, this message translates to:
  /// **'Search the whole journal on the server'**
  String get logsPanelSearchServer;

  /// Chip above the log while the server reads only the journal entries matching a pattern; the pattern is shown as sent.
  ///
  /// In en, this message translates to:
  /// **'Server search: {pattern}'**
  String logsPanelServerMatch(String pattern);

  /// Tooltip of the button on the server-search chip that reads the whole journal again.
  ///
  /// In en, this message translates to:
  /// **'Clear the server search'**
  String get logsPanelServerMatchClear;

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

  /// CPU-04: the share of CPU time cores sat idle while tasks waited for storage (iowait).
  ///
  /// In en, this message translates to:
  /// **'I/O wait'**
  String get overviewCpuIowait;

  /// CPU-04: the share of CPU time the hypervisor gave to other guests (steal).
  ///
  /// In en, this message translates to:
  /// **'Steal'**
  String get overviewCpuSteal;

  /// CPU-04: the share of CPU time spent handling hardware interrupts (irq).
  ///
  /// In en, this message translates to:
  /// **'IRQ'**
  String get overviewCpuIrq;

  /// CPU-04: the share of CPU time spent on deferred interrupt work such as network packets (softirq).
  ///
  /// In en, this message translates to:
  /// **'Soft IRQ'**
  String get overviewCpuSoftirq;

  /// CPU-04's hint when steal reaches 10 % of CPU time. percent is the steal share, such as "25%".
  ///
  /// In en, this message translates to:
  /// **'Steal {percent}: the host running this virtual machine gives its CPU time to other guests, often a noisy neighbour on a VPS. Programs here run slower than the busy figure suggests.'**
  String overviewCpuHintSteal(String percent);

  /// CPU-04's hint when iowait reaches 10 % of CPU time; the kernel documentation calls iowait unreliable. percent is the iowait share, such as "25%".
  ///
  /// In en, this message translates to:
  /// **'I/O wait {percent}: cores sat idle while tasks waited for storage. The kernel calls this figure unreliable, so check disk latency before blaming the disks.'**
  String overviewCpuHintIowait(String percent);

  /// CPU-04's hint when hardware and soft interrupts together reach 10 % of CPU time. percent is their share, such as "25%".
  ///
  /// In en, this message translates to:
  /// **'Interrupts {percent}: the CPUs spend this much handling devices, often heavy network traffic.'**
  String overviewCpuHintInterrupts(String percent);

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

  /// Overview: the heading of TRI-02's card, what in the latest reading slows the server.
  ///
  /// In en, this message translates to:
  /// **'Why is it slow?'**
  String get overviewSlowTitle;

  /// Overview, Why is it slow: no signal in the latest reading.
  ///
  /// In en, this message translates to:
  /// **'Nothing in the latest reading points to a slowdown.'**
  String get overviewSlowNone;

  /// Overview, Why is it slow: PSI cpu some over 10 s reached 20 %. percent is the share, such as "35%".
  ///
  /// In en, this message translates to:
  /// **'Tasks waited for a CPU {percent} of the last 10 seconds: the processor is the bottleneck.'**
  String overviewSlowCpuWait(String percent);

  /// Overview, Why is it slow: without PSI, the load per core reached 1.5.
  ///
  /// In en, this message translates to:
  /// **'The load is {load} per core: more tasks want to run than there are cores.'**
  String overviewSlowLoadHigh(double load);

  /// Overview, Why is it slow: steal reached 10 % of CPU time. percent is the share, such as "25%".
  ///
  /// In en, this message translates to:
  /// **'The hypervisor gave {percent} of the CPU time to other guests.'**
  String overviewSlowSteal(String percent);

  /// Overview, Why is it slow: PSI io some over 10 s reached 10 %. percent is the share, such as "25%".
  ///
  /// In en, this message translates to:
  /// **'Tasks stalled on storage {percent} of the last 10 seconds: the disks are the bottleneck.'**
  String overviewSlowIoStall(String percent);

  /// Overview, Why is it slow: without PSI, iowait reached 10 % of CPU time. percent is the share, such as "25%".
  ///
  /// In en, this message translates to:
  /// **'Cores sat idle {percent} of the time waiting for storage.'**
  String overviewSlowIowait(String percent);

  /// Overview, Why is it slow: a disk's mean time per request reached 50 ms. device is the disk's kernel name, such as sda.
  ///
  /// In en, this message translates to:
  /// **'{device} takes {ms} ms per request: it is slow or saturated.'**
  String overviewSlowSlowDisk(String device, int ms);

  /// Overview, Why is it slow: a disk was busy 90 % of the time. device is the disk's kernel name; percent the share, such as "95%".
  ///
  /// In en, this message translates to:
  /// **'{device} is busy {percent} of the time: requests queue behind each other.'**
  String overviewSlowBusyDisk(String device, String percent);

  /// Overview, Why is it slow: PSI memory some over 10 s reached 5 %. percent is the share, such as "12%".
  ///
  /// In en, this message translates to:
  /// **'Tasks stalled waiting for memory {percent} of the last 10 seconds: the server is short of RAM.'**
  String overviewSlowMemoryStall(String percent);

  /// Overview, Why is it slow: swap is half full while under 10 % of memory is available. percent is swap's used share, such as "80%".
  ///
  /// In en, this message translates to:
  /// **'Swap is {percent} full and little memory is free: the server pages to disk.'**
  String overviewSlowSwapHeavy(String percent);

  /// Overview, Why is it slow: where to look next, under the signals.
  ///
  /// In en, this message translates to:
  /// **'Processes sorts what runs by CPU and memory; System lists recent out-of-memory kills.'**
  String get overviewSlowWhere;

  /// Heading of the Overview's pressure card (CPU-05, MEM-04): Linux pressure stall information.
  ///
  /// In en, this message translates to:
  /// **'Pressure'**
  String get overviewPressureTitle;

  /// Explains the pressure card's figures and their order.
  ///
  /// In en, this message translates to:
  /// **'Share of time tasks stalled, over the last 10 s, 1 min and 5 min. \"Some\" counts time at least one task waited, \"full\" time all of them did.'**
  String get overviewPressureCaption;

  /// The pressure card when the server has no /proc/pressure files; their absence is normal.
  ///
  /// In en, this message translates to:
  /// **'This kernel reports no pressure figures. That is normal before Linux 4.20 or with PSI turned off.'**
  String get overviewPressureNone;

  /// The resource name in a pressure figure's label, for /proc/pressure/cpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get overviewPressureCpu;

  /// The resource name in a pressure figure's label, for /proc/pressure/memory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get overviewPressureMemory;

  /// The resource name in a pressure figure's label, for /proc/pressure/io.
  ///
  /// In en, this message translates to:
  /// **'I/O'**
  String get overviewPressureIo;

  /// Label of a pressure figure: the share of time at least one task stalled on resource (CPU, Memory or I/O).
  ///
  /// In en, this message translates to:
  /// **'{resource}, some'**
  String overviewPressureSome(String resource);

  /// Label of a pressure figure: the share of time all tasks stalled on resource (CPU, Memory or I/O).
  ///
  /// In en, this message translates to:
  /// **'{resource}, full'**
  String overviewPressureFull(String resource);

  /// A pressure figure's three averages in percent with the kernel's two decimals, over 10 s, 1 min and 5 min, in that order.
  ///
  /// In en, this message translates to:
  /// **'{avg10}% · {avg60}% · {avg300}%'**
  String overviewPressureValue(double avg10, double avg60, double avg300);

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
  /// **'{reason, select, reboot{Runs when cron starts, not at a time.} unparsed{The schedule does not parse, so its runs are unknown.} timeZoneUnresolved{This device does not know the CRON_TZ zone, so its runs are unknown.} serverZoneUnknown{The server\'s time zone is not known yet, so its runs are unknown.} noRunInHorizon{No run falls in the next {years} years.} notEvaluated{Runs are worked out for the first {limit} cron lines only.} anacron{anacron runs this directory; its timing is not shown in this version.} paused{Paused: cron skips this job until it is resumed.} other{No cron line runs this directory.}}'**
  String jobsRunsUnknown(String reason, int limit, int years);

  /// A job's next-run cell in the jobs table when it lists no runs: jobsRunsUnknown cut short to fit the column, which stays at phone width. reason is the engine's JobRunsUnknown name, and other is noDriver; years is how far ahead the engine looks. The job's details give the full reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, reboot{At cron start} unparsed{Unreadable schedule} timeZoneUnresolved{Zone not known} serverZoneUnknown{Zone not known yet} noRunInHorizon{None in {years} years} notEvaluated{Not worked out} anacron{Timed by anacron} paused{Paused} other{Not run}}'**
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

  /// Banner on a server's workspace or screen when the engine will not connect a synced server because its endpoint (host, port, user, jump route) is not confirmed on this device or changed since (03 §4.7, SAF-09). The user confirms it from the notice over the fleet list, whose button is endpointsReview.
  ///
  /// In en, this message translates to:
  /// **'You can\'t connect to this server yet: its address comes from your sync account and isn\'t confirmed on this device, or it changed since you confirmed it. Choose Review over the server list to check and confirm it.'**
  String get connectRejectedEndpointNotConfirmed;

  /// Notice over the fleet list while synced servers wait for endpoint confirmation on this device (03 §4.3 step 3, SAF-09): new from the sync account, or changed since they were confirmed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{{count} synced server waits for you to confirm its address.} other{{count} synced servers wait for you to confirm their addresses.}}'**
  String endpointsPendingNotice(int count);

  /// Button on endpointsPendingNotice that opens the endpoint confirmation list.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get endpointsReview;

  /// Title of the endpoint confirmation list (03 §4.3 step 3).
  ///
  /// In en, this message translates to:
  /// **'Confirm server addresses'**
  String get endpointsTitle;

  /// Explanation at the top of the endpoint confirmation list (SAF-09): any device on the account can rewrite a server's address, and a background connect would then hand a credential to the new host.
  ///
  /// In en, this message translates to:
  /// **'These servers come from your sync account. Klabautermann connects only to addresses you confirm on this device, so an address changed on another device cannot receive your sign-in unnoticed. Check each host, port, user and jump route before you confirm it.'**
  String get endpointsBody;

  /// Label of the search field of the endpoint confirmation list; it matches names, users and addresses.
  ///
  /// In en, this message translates to:
  /// **'Search servers'**
  String get endpointsSearch;

  /// Line of an endpoint confirmation row naming the jump hosts the server is reached through, first hop first.
  ///
  /// In en, this message translates to:
  /// **'via {route}'**
  String endpointsRoute(String route);

  /// Between the jump hosts in endpointsRoute, from the first hop towards the server.
  ///
  /// In en, this message translates to:
  /// **' → '**
  String get endpointsRouteSeparator;

  /// Line of an endpoint confirmation row whose server, or a jump host it goes through, was changed by a sync after this device confirmed it (03 §4.7).
  ///
  /// In en, this message translates to:
  /// **'Changed since you confirmed it'**
  String get endpointsChanged;

  /// Shown in place of the rows when the search of the endpoint confirmation list matches no server.
  ///
  /// In en, this message translates to:
  /// **'No servers match your search.'**
  String get endpointsNoMatch;

  /// Shown in place of the rows when no synced server waits for confirmation any more.
  ///
  /// In en, this message translates to:
  /// **'Every synced server\'s address is confirmed on this device.'**
  String get endpointsNoneLeft;

  /// Button of the endpoint confirmation list that confirms every row the search shows, whatever its toggle.
  ///
  /// In en, this message translates to:
  /// **'Confirm all shown'**
  String get endpointsConfirmAllShown;

  /// Main button of the endpoint confirmation list: confirms the rows whose toggles are on; disabled while none is.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Confirm selected} one{Confirm {count} server} other{Confirm {count} servers}}'**
  String endpointsConfirmSelected(int count);

  /// Toast after the confirmed servers left the list; Klabautermann may now connect to them.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Confirmed {count} server address.} other{Confirmed {count} server addresses.}}'**
  String endpointsConfirmed(int count);

  /// Under the endpoint confirmation list when a confirmed server stays listed because a jump host on its route changed and needs its own confirmation (D64).
  ///
  /// In en, this message translates to:
  /// **'Some servers still need confirming: confirm the jump hosts they go through too.'**
  String get endpointsStillPending;

  /// Under the endpoint confirmation list when the engine could not save the confirmation or stopped before answering.
  ///
  /// In en, this message translates to:
  /// **'The confirmation could not be saved on this device, so these servers stay unconfirmed. Try again.'**
  String get endpointsFailed;

  /// Heading of the accessibility settings on the General settings tab.
  ///
  /// In en, this message translates to:
  /// **'Accessibility'**
  String get settingsAccessibilityTitle;

  /// Settings, General: the heading of the polling budget section (SAF-19).
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get settingsCadenceTitle;

  /// Settings, General: the label beside the polling budget's preset menu (SAF-19).
  ///
  /// In en, this message translates to:
  /// **'How often servers are read'**
  String get settingsCadenceLabel;

  /// Settings, General: a polling budget preset in its menu.
  ///
  /// In en, this message translates to:
  /// **'{preset, select, automatic{Automatic} desktop{Desktop} phone{Phone} other{Cellular saver}}'**
  String settingsCadencePreset(String preset);

  /// Settings, General: what the chosen polling budget preset reads how often (03 §6.4).
  ///
  /// In en, this message translates to:
  /// **'{preset, select, automatic{Desktop rates on a computer, phone rates on a phone or tablet.} desktop{Fleet rows every 5 s, the open server every 2 s.} phone{Fleet rows every 10 s, the open server every 3 s, to save battery.} other{Fleet rows every 30 s, the open server every 10 s; timers, cron jobs, temperatures, GPUs and disk health are read once when you open them.}}'**
  String settingsCadenceDetail(String preset);

  /// Settings, General: toast when the polling budget applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The refresh rate changed but could not be saved. It lasts until Klabautermann quits.'**
  String get settingsCadenceNotSaved;

  /// Settings, General: toast when the polling budget change failed.
  ///
  /// In en, this message translates to:
  /// **'The refresh rate could not be changed.'**
  String get settingsCadenceNotChanged;

  /// Settings, Servers: the heading of the per-server polling caps (SAF-19).
  ///
  /// In en, this message translates to:
  /// **'Refresh limits'**
  String get settingsCadenceCapsTitle;

  /// Settings, Servers: what a per-server polling cap does (SAF-19, 03 §6.4).
  ///
  /// In en, this message translates to:
  /// **'Read a server no more often than the chosen rate, for example one on a metered link. A limit never makes a server refresh faster than the rate in General.'**
  String get settingsCadenceCapsDetail;

  /// Settings, Servers: the menu choice that lifts a server's polling cap.
  ///
  /// In en, this message translates to:
  /// **'No limit'**
  String get settingsCadenceNoCap;

  /// Settings, Servers: toast when a server's polling cap applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The refresh limit changed but could not be saved. It lasts until Klabautermann quits.'**
  String get settingsCadenceCapNotSaved;

  /// Settings, Servers: toast when a server's polling cap change failed.
  ///
  /// In en, this message translates to:
  /// **'The refresh limit could not be changed.'**
  String get settingsCadenceCapNotChanged;

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

  /// Settings, General: label of the log text size picker (A11Y-12).
  ///
  /// In en, this message translates to:
  /// **'Log text size'**
  String get settingsLogTextSize;

  /// Settings, General: explanation under the log text size picker (A11Y-12).
  ///
  /// In en, this message translates to:
  /// **'How large every log\'s lines are drawn, before your system\'s text size applies.'**
  String get settingsLogTextSizeDetail;

  /// Settings, General: one log text size in the picker, in logical pixels.
  ///
  /// In en, this message translates to:
  /// **'{size} px'**
  String settingsLogTextSizeValue(int size);

  /// Settings, General: switch that makes every log wrap long lines instead of cutting them (A11Y-12).
  ///
  /// In en, this message translates to:
  /// **'Wrap long log lines'**
  String get settingsLogWrap;

  /// Settings, General: explanation under the log wrap switch (A11Y-12).
  ///
  /// In en, this message translates to:
  /// **'Show each line in full on as many rows as it needs, instead of cutting it at the edge.'**
  String get settingsLogWrapDetail;

  /// Settings, General: toast when the log text size or wrapping applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The log display changed but could not be saved. It lasts until Klabautermann quits.'**
  String get settingsLogDisplayNotSaved;

  /// Settings, General: toast when the log text size or wrapping change failed.
  ///
  /// In en, this message translates to:
  /// **'The log display could not be changed.'**
  String get settingsLogDisplayNotChanged;

  /// Settings, General: switch that shows the times a server reports in that server's time zone instead of this device's (A11Y-07).
  ///
  /// In en, this message translates to:
  /// **'Show server times in the server\'s zone'**
  String get settingsServerTimes;

  /// Settings, General: explanation under the server times switch (A11Y-07).
  ///
  /// In en, this message translates to:
  /// **'Times on a server\'s screens use the zone it reported when it connected. Until then, and with this off, they use this device\'s zone.'**
  String get settingsServerTimesDetail;

  /// Settings, General: toast when the server times switch applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The time display changed but could not be saved. It lasts until Klabautermann quits.'**
  String get settingsServerTimesNotSaved;

  /// Settings, General: toast when the server times switch failed to change.
  ///
  /// In en, this message translates to:
  /// **'The time display could not be changed.'**
  String get settingsServerTimesNotChanged;

  /// Settings, Alerts: the heading of OV-11's threshold levels.
  ///
  /// In en, this message translates to:
  /// **'Usage bands'**
  String get settingsThresholdsTitle;

  /// Settings, Alerts: what the usage bands do.
  ///
  /// In en, this message translates to:
  /// **'The levels the fleet rows, the Overview and its health card judge each metric by. Careful shows an info icon, warning and critical also take their colour, and only warning and critical are announced.'**
  String get settingsThresholdsDetail;

  /// Settings, Alerts, threshold dialog: the careful level's field label.
  ///
  /// In en, this message translates to:
  /// **'Careful from'**
  String get settingsThresholdCareful;

  /// Settings, Alerts, threshold dialog: the warning level's field label.
  ///
  /// In en, this message translates to:
  /// **'Warning from'**
  String get settingsThresholdWarning;

  /// Settings, Alerts, threshold dialog: the critical level's field label.
  ///
  /// In en, this message translates to:
  /// **'Critical from'**
  String get settingsThresholdCritical;

  /// Settings, Alerts, threshold dialog: the unit after each level's number.
  ///
  /// In en, this message translates to:
  /// **'%'**
  String get settingsThresholdPercentSuffix;

  /// Settings, Alerts, threshold dialog: why the levels typed cannot be saved.
  ///
  /// In en, this message translates to:
  /// **'Each level must be a whole percent from 1 to 100, and each one higher than the one before.'**
  String get settingsThresholdsInvalid;

  /// Settings, Alerts, threshold dialog: fills in the default levels (70, 80 and 90 %).
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get settingsThresholdDefault;

  /// Settings, Alerts, threshold dialog: closes it without a change.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsThresholdCancel;

  /// Settings, Alerts, threshold dialog: applies the levels typed.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get settingsThresholdSave;

  /// Settings, Alerts: toast when new levels applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The levels changed but could not be saved. They last until Klabautermann quits.'**
  String get settingsThresholdsNotSaved;

  /// Settings, Alerts: toast when the levels change failed.
  ///
  /// In en, this message translates to:
  /// **'The levels could not be changed.'**
  String get settingsThresholdsNotChanged;

  /// Settings, Alerts: a metric whose usage bands are set (OV-11); disk covers space and inodes.
  ///
  /// In en, this message translates to:
  /// **'{metric, select, cpu{CPU} memory{Memory} other{Disk}}'**
  String settingsThresholdMetric(String metric);

  /// Settings, Alerts: a metric's three levels, each a formatted percent (chartPercent).
  ///
  /// In en, this message translates to:
  /// **'Careful from {careful}, warning from {warning}, critical from {critical}'**
  String settingsThresholdLevels(
    String careful,
    String warning,
    String critical,
  );

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

  /// App lock screen (SAF-20): its heading, shown over the whole app while the app lock is engaged.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann is locked'**
  String get appLockTitle;

  /// App lock screen: what unlocking asks for, and that open links are not closed by the lock.
  ///
  /// In en, this message translates to:
  /// **'Unlock with this device\'s passcode, PIN or biometrics. Connections already open keep running.'**
  String get appLockDetail;

  /// The desktop settings window while the app is locked, under the title that it is locked.
  ///
  /// In en, this message translates to:
  /// **'Unlock it in its main window to change settings.'**
  String get settingsWindowLocked;

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
  /// **'Unlock Klabautermann'**
  String get appLockReason;

  /// Settings > Safety: the heading over the app lock switch (SAF-20).
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get settingsAppLockTitle;

  /// Settings > Safety: the app lock switch.
  ///
  /// In en, this message translates to:
  /// **'Require device authentication'**
  String get settingsAppLock;

  /// Settings > Safety: what the app lock switch does.
  ///
  /// In en, this message translates to:
  /// **'Ask for this device\'s passcode, PIN or biometrics when Klabautermann opens and after {minutes, plural, =1{1 minute} other{{minutes} minutes}} in the background. Locking turns admin mode off on every server.'**
  String settingsAppLockDetail(int minutes);

  /// Settings > Safety: why the app lock switch is off and disabled on Linux.
  ///
  /// In en, this message translates to:
  /// **'This platform has no device authentication Klabautermann can ask for.'**
  String get settingsAppLockUnsupported;

  /// Settings > Safety: why the app lock switch cannot be turned on right now.
  ///
  /// In en, this message translates to:
  /// **'Set up a passcode, PIN or biometrics on this device to use the app lock.'**
  String get settingsAppLockUnavailable;

  /// Settings > Safety: a toast after turning the app lock on or off did not take effect, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notAuthenticated{The app lock did not change: authentication failed or was cancelled.} unavailable{The app lock did not change: this device has no authentication to ask for.} notSaved{The app lock did not change: the setting could not be saved.} other{The app lock did not change.}}'**
  String settingsAppLockNotChanged(String reason);

  /// Section heading on the Sync settings tab over the sync passwords switch (SYN-02).
  ///
  /// In en, this message translates to:
  /// **'Passwords and keys'**
  String get settingsSyncSecretsTitle;

  /// Switch on the Sync settings tab (SYN-02): whether passwords and keys other devices synced are added to this device's vault. Séance's wording.
  ///
  /// In en, this message translates to:
  /// **'Sync saved passwords & keys'**
  String get settingsSyncSecrets;

  /// Explanation under the sync passwords switch, Séance's subtitle.
  ///
  /// In en, this message translates to:
  /// **'Only includes servers where credential sync is also enabled.'**
  String get settingsSyncSecretsDetail;

  /// Toast when the sync passwords switch applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The setting changed, but it could not be saved, so it will not be kept after a restart.'**
  String get settingsSyncSecretsNotSaved;

  /// Toast when the app did not take a change of the sync passwords switch.
  ///
  /// In en, this message translates to:
  /// **'The setting could not be changed.'**
  String get settingsSyncSecretsNotChanged;

  /// Heading of the Sync tab's host key sharing section, shown once a Séance release with the shared host key fix is named.
  ///
  /// In en, this message translates to:
  /// **'Host keys'**
  String get settingsPinPublicationTitle;

  /// Switch asserting that every device on the account runs a Séance release that checks shared host keys; while on, host keys the user confirms are shared.
  ///
  /// In en, this message translates to:
  /// **'Every device runs Séance {release} or later'**
  String settingsPinPublication(String release);

  /// Settings, Sync: heading of the account size view (SYN-09).
  ///
  /// In en, this message translates to:
  /// **'Account size'**
  String get settingsAccountSizeTitle;

  /// Settings, Sync: how much of their budget Klabautermann's synced records use (SYN-09).
  ///
  /// In en, this message translates to:
  /// **'Klabautermann\'s records take {used} of their {budget} in the sync account.'**
  String settingsAccountSizeUsed(String used, String budget);

  /// Settings, Sync: warning once Klabautermann's records take 80 % of their budget (SYN-09).
  ///
  /// In en, this message translates to:
  /// **'They are close to the limit. Remove alert rules or server preferences you no longer need.'**
  String get settingsAccountSizeWarn;

  /// Settings, Sync: warning once Klabautermann's records take their whole budget (SYN-09).
  ///
  /// In en, this message translates to:
  /// **'They have reached the limit, so new changes may not sync. Remove alert rules or server preferences you no longer need.'**
  String get settingsAccountSizeFull;

  /// Settings, Sync: explanation above the account size view's rows (SYN-09).
  ///
  /// In en, this message translates to:
  /// **'Every kind of record in the account, as this device last pulled it. The account is shared with Séance, so its records count too.'**
  String get settingsAccountSizeDetail;

  /// Settings, Sync: one record prefix's count and size in the account size view (SYN-09).
  ///
  /// In en, this message translates to:
  /// **'{records, plural, =1{1 record} other{{records} records}}, {size}'**
  String settingsAccountSizeRow(int records, String size);

  /// What the host key sharing switch does, under it.
  ///
  /// In en, this message translates to:
  /// **'While on, host keys you confirm are shared with your other devices, so they can check a server the first time they connect. Turning it off stops sharing; keys already shared stay.'**
  String get settingsPinPublicationDetail;

  /// Toast when the engine did not take or keep a change of the host key sharing switch.
  ///
  /// In en, this message translates to:
  /// **'The host key setting could not be changed.'**
  String get settingsPinPublicationNotChanged;

  /// Heading of the about row on the General settings tab, which shows the app's title and version and opens the About dialog.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAboutTitle;

  /// Heading of the monitor set's switches (FL-21) on the Servers settings tab.
  ///
  /// In en, this message translates to:
  /// **'Monitoring'**
  String get settingsMonitorTitle;

  /// Explanation above the monitor set's switches on the Servers settings tab (FL-21); limit is the most servers the set holds.
  ///
  /// In en, this message translates to:
  /// **'Monitored servers are read continuously while Klabautermann is open, and their rows show CPU, memory and disk. A server can be monitored once its endpoint is confirmed and it signs in with an SSH agent or a key file, without asking you. Up to {limit} servers.'**
  String settingsMonitorDetail(int limit);

  /// How many servers the monitor set holds (FL-21) out of the most it can, above its switches on the Servers settings tab.
  ///
  /// In en, this message translates to:
  /// **'{monitored} of {limit} servers monitored'**
  String settingsMonitorCount(int monitored, int limit);

  /// The Servers settings tab's monitor set section while the fleet has no servers.
  ///
  /// In en, this message translates to:
  /// **'No servers yet. Servers you sync or import show here.'**
  String get settingsMonitorEmpty;

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

  /// The health card's heading over the unhealthy containers (OV-02), on a server with a Docker endpoint; count is how many containers report an unhealthy health check.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No unhealthy containers} =1{1 unhealthy container} other{{count} unhealthy containers}}'**
  String overviewHealthContainersUnhealthy(int count);

  /// One unhealthy container in the health card: its name, or its short ID when it has none, and the engine's status text, such as 'Up 2 hours (unhealthy)'.
  ///
  /// In en, this message translates to:
  /// **'{name}: {status}'**
  String overviewHealthContainer(String name, String status);

  /// Heading of the Overview's Docker summary card (OV-05).
  ///
  /// In en, this message translates to:
  /// **'Docker'**
  String get overviewDockerTitle;

  /// The Docker card before the first container and image lists arrived.
  ///
  /// In en, this message translates to:
  /// **'Reading the containers and images.'**
  String get overviewDockerReading;

  /// The Docker card once the server's Docker endpoint is no longer ready: the figures below are the last ones read. time is the older of the two lists' read times, as a date and time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'These figures are from {time}. The Docker engine cannot be reached now, so they may be out of date.'**
  String overviewDockerStale(DateTime time);

  /// The Docker card: why the container or image list could not be read; the figures below, if any, are from the last lists read. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} daemonError{The engine refused or failed to list the containers or images.} connectionFailed{The connection to the engine failed while listing the containers or images.} other{The containers or images could not be listed.}}'**
  String overviewDockerListFailed(String reason);

  /// A count in the Docker card, in the UI locale's number format.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String overviewDockerCount(int count);

  /// Docker card: how many containers are running.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get overviewDockerRunning;

  /// Docker card: how many containers are paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get overviewDockerPaused;

  /// Docker card: how many containers are neither running nor paused (created, restarting, exited, dead), as docker info counts them.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get overviewDockerStopped;

  /// Docker card: how many containers report an unhealthy health check.
  ///
  /// In en, this message translates to:
  /// **'Unhealthy'**
  String get overviewDockerUnhealthy;

  /// Docker card: how many images the engine has.
  ///
  /// In en, this message translates to:
  /// **'Images'**
  String get overviewDockerImages;

  /// Docker card: how many images at least one container, running or not, was created from.
  ///
  /// In en, this message translates to:
  /// **'Images in use'**
  String get overviewDockerImagesInUse;

  /// Docker card: how many images have no tag (Docker's dangling images).
  ///
  /// In en, this message translates to:
  /// **'Dangling images'**
  String get overviewDockerDangling;

  /// Docker card: the space that removing unused images, containers, volumes and build cache would free, from the engine's disk use report.
  ///
  /// In en, this message translates to:
  /// **'Reclaimable space'**
  String get overviewDockerReclaimable;

  /// Docker card: the reclaimable space before the reader asked for it to be measured.
  ///
  /// In en, this message translates to:
  /// **'Not measured'**
  String get overviewDockerNotMeasured;

  /// Docker card: under the reclaimable space before it was measured, why it is not measured on its own.
  ///
  /// In en, this message translates to:
  /// **'Measuring asks the engine to add up every image, container, volume and build cache, which can take a while on large hosts.'**
  String get overviewDockerMeasureNote;

  /// Docker card: button that asks the engine for its disk use report (/system/df) to show the reclaimable space.
  ///
  /// In en, this message translates to:
  /// **'Measure disk use'**
  String get overviewDockerMeasure;

  /// Docker card: the measure button once a measurement is shown.
  ///
  /// In en, this message translates to:
  /// **'Measure again'**
  String get overviewDockerMeasureAgain;

  /// Docker card: beside a progress indicator while the disk use report is read.
  ///
  /// In en, this message translates to:
  /// **'Measuring disk use. This can take a while on large hosts.'**
  String get overviewDockerMeasuring;

  /// Docker card: when the reclaimable space shown was measured, as a date and time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'Measured at {time}.'**
  String overviewDockerMeasured(DateTime time);

  /// Docker card: why the last disk use measurement failed; a reclaimable space shown is from the measurement before. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, linkUnavailable{Disk use could not be measured: the server is not connected.} profileUnknown{Disk use could not be measured: the server has not been checked yet.} endpointUnavailable{Disk use could not be measured: the Docker engine cannot be reached.} daemonError{The engine refused or failed to measure its disk use.} connectionFailed{The connection to the engine failed or timed out while measuring disk use.} cancelled{The measurement stopped because the connection to the engine changed. Measure again to retry.} other{Disk use could not be measured.}}'**
  String overviewDockerMeasureFailed(String reason);

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

  /// Optional checkbox at sign-in asserting the release that checks shared host keys; ticked, host keys the user confirms are shared.
  ///
  /// In en, this message translates to:
  /// **'Every device on this account runs Séance {release} or later'**
  String syncPinPublicationAssertion(String release);

  /// Why the host key assertion matters, under its checkbox.
  ///
  /// In en, this message translates to:
  /// **'Then host keys you confirm are shared with them. Older releases accept a shared key without checking it.'**
  String get syncPinPublicationAssertionDetail;

  /// Disclosure on the sign-in's second step: the account key decrypts every app's records. Séance and Poltergeist are the sibling apps.
  ///
  /// In en, this message translates to:
  /// **'Your encryption passphrase opens the records of every app on this account, Séance and Poltergeist included.'**
  String get syncDisclosureAccountKey;

  /// Disclosure on the sign-in's second step: what the app writes to the account, and what it does not.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann publishes only the servers you add, edit or delete here, with their passwords or keys when you let them sync, and each server\'s read-only switch and marks. It publishes no host keys.'**
  String get syncDisclosure;

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

  /// Switch on the Safety settings tab (SAF-06): global read-only.
  ///
  /// In en, this message translates to:
  /// **'Read-only everywhere'**
  String get settingsSafetyReadOnly;

  /// Explanation under the global read-only switch on the Safety settings tab.
  ///
  /// In en, this message translates to:
  /// **'While this is on, no server takes an action and every action is hidden. Monitoring, logs and other reads work as before, so it is safe for screen sharing.'**
  String get settingsSafetyReadOnlyDetail;

  /// Label above the admin mode expiry choices on the Safety settings tab (SAF-02).
  ///
  /// In en, this message translates to:
  /// **'Admin mode ends after'**
  String get settingsSafetyAdminExpiry;

  /// One admin mode expiry choice on the Safety settings tab; minutes is 5, 15, 30 or 60.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String settingsSafetyAdminExpiryMinutes(int minutes);

  /// Explanation under the admin mode expiry choices on the Safety settings tab.
  ///
  /// In en, this message translates to:
  /// **'Admin mode turns off after this long without an action. It also turns off when the link drops, and on a phone when Klabautermann goes to the background.'**
  String get settingsSafetyAdminExpiryDetail;

  /// Heading of the user's protected marks on the Safety settings tab (SAF-22).
  ///
  /// In en, this message translates to:
  /// **'Marked protected'**
  String get settingsSafetyMarksTitle;

  /// Explanation under the protected marks heading on the Safety settings tab.
  ///
  /// In en, this message translates to:
  /// **'An action on a target you marked protected asks you to type its name first. Marks stay on this device.'**
  String get settingsSafetyMarksDetail;

  /// Shown on the Safety settings tab when the user marked no target protected.
  ///
  /// In en, this message translates to:
  /// **'You have not marked anything protected.'**
  String get settingsSafetyMarksEmpty;

  /// One protected mark on the Safety settings tab: the marked unit, container or stack name, and the server's name.
  ///
  /// In en, this message translates to:
  /// **'{target} on {server}'**
  String settingsSafetyMark(String target, String server);

  /// Tooltip and screen reader label of the button that removes one protected mark on the Safety settings tab.
  ///
  /// In en, this message translates to:
  /// **'Remove the mark on {target}'**
  String settingsSafetyMarkRemove(String target);

  /// Toast when a safety setting applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The setting changed, but it could not be saved, so it will not be kept after a restart.'**
  String get settingsSafetyNotSaved;

  /// Toast when the app did not take a change of a safety setting.
  ///
  /// In en, this message translates to:
  /// **'The setting could not be changed.'**
  String get settingsSafetyNotChanged;

  /// Tooltip and screen reader label of the server header's safety menu button, which holds the Allow actions and Read-only switches.
  ///
  /// In en, this message translates to:
  /// **'Safety'**
  String get serverSafetyMenu;

  /// Switch in the server header's safety menu (SAF-01): management, off by default. While off, Klabautermann only reads the server.
  ///
  /// In en, this message translates to:
  /// **'Allow actions'**
  String get serverAllowActions;

  /// Switch in the server header's safety menu (SAF-06): hides every action on this server.
  ///
  /// In en, this message translates to:
  /// **'Read-only'**
  String get serverReadOnly;

  /// Switch in the server header's safety menu (SAF-13): after each action, write one line naming the action, its target and this device to the server's system log.
  ///
  /// In en, this message translates to:
  /// **'Log actions on the server'**
  String get serverHostAuditLine;

  /// Notice in the server header while management is off for the server (03 §4.3 step 5, SAF-01).
  ///
  /// In en, this message translates to:
  /// **'Observe only: Klabautermann reads this server and changes nothing. To act on it, turn on Allow actions in the Safety menu.'**
  String get serverObserveOnly;

  /// Notice in the server header while the server, or every server, is read-only (SAF-06).
  ///
  /// In en, this message translates to:
  /// **'Read-only: actions on this server are hidden.'**
  String get serverReadOnlyNotice;

  /// Title of the login password dialog shown on connect when the vault holds no password for the server (03 §4.5); label is the server's name.
  ///
  /// In en, this message translates to:
  /// **'Password for {label}'**
  String credentialTitle(String label);

  /// Line under the login password dialog's title when the password can be saved in the vault.
  ///
  /// In en, this message translates to:
  /// **'Saved only if you choose to: on this device, in its encrypted vault, and used for this server from now on.'**
  String get credentialExplanation;

  /// Label of the password field in the login password dialog.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get credentialPassword;

  /// Checkbox in the login password dialog that keeps the password in this device's vault once the server accepts it.
  ///
  /// In en, this message translates to:
  /// **'Save in vault'**
  String get credentialSaveInVault;

  /// Button that closes the login password dialog without connecting.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get credentialCancel;

  /// Button that connects with the typed password.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get credentialConnect;

  /// Title of the admin mode password dialog (SAF-02); host is the server's address.
  ///
  /// In en, this message translates to:
  /// **'Admin password for {host}'**
  String elevationTitle(String host);

  /// Explanation in the admin mode password dialog; user is the login account sudo runs for.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann asks sudo for root as {user} with this password. It is kept in memory only while admin mode is on, and never saved.'**
  String elevationDetail(String user);

  /// Shown in the admin mode password dialog when sudo refused the previous password.
  ///
  /// In en, this message translates to:
  /// **'That password did not work. Try again.'**
  String get elevationRetry;

  /// Label of the password field in the admin mode password dialog.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get elevationPassword;

  /// Button that closes the admin mode password dialog without turning admin mode on.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get elevationCancel;

  /// Button that sends the password and turns admin mode on.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get elevationTurnOn;

  /// Label of the server header's admin mode chip while admin mode is off (SAF-02).
  ///
  /// In en, this message translates to:
  /// **'Admin mode'**
  String get adminChipOff;

  /// Label of the admin mode chip while the engine detects how to elevate, waits for the password or checks it.
  ///
  /// In en, this message translates to:
  /// **'Turning on admin mode'**
  String get adminChipStarting;

  /// Label of the admin mode chip while it is on; time is when inactivity ends it.
  ///
  /// In en, this message translates to:
  /// **'Admin mode until {time}'**
  String adminChipOn(String time);

  /// Tooltip of the disabled admin mode chip while the server or every server is read-only (SAF-06).
  ///
  /// In en, this message translates to:
  /// **'Admin mode is not available while the server is read-only.'**
  String get adminChipReadOnly;

  /// Notice in the server header while admin mode is on.
  ///
  /// In en, this message translates to:
  /// **'Admin mode is on: actions you confirm here run as root.'**
  String get adminOnNotice;

  /// Notice in the server header when admin mode could not start; reason is the engine's AdminFailure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, observeOnly{Admin mode needs Allow actions turned on for this server.} readOnly{Admin mode is not available while this server is read-only.} noLink{Admin mode needs a connection to this server.} notProbed{Klabautermann has not checked this server yet. Try admin mode again in a moment.} unavailable{This server offers no way to become root that Klabautermann can use.} ttyRequired{This server lets you become root only from a terminal, so admin mode is not available.} notInSudoers{Your account on this server may not use sudo.} wrongPassword{The password was refused three times, so admin mode stayed off.} cancelled{Admin mode stayed off because no password was given.} other{Admin mode could not be turned on.}}'**
  String adminFailure(String reason);

  /// Notice in the server header after admin mode ended; reason is the engine's AdminEnd name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, inactivity{Admin mode ended after a while without an action.} background{Admin mode ended when Klabautermann went to the background.} linkLost{Admin mode ended when the connection dropped.} serverRemoved{Admin mode ended because the server changed.} other{Admin mode ended.}}'**
  String adminEnded(String reason);

  /// Title of the action preview (SAF-04), which shows exactly what will run before the user confirms.
  ///
  /// In en, this message translates to:
  /// **'Review before it runs'**
  String get actionPreviewTitle;

  /// Line naming the target in the action preview; target is the unit, process, container, image or stack name.
  ///
  /// In en, this message translates to:
  /// **'Target: {target}'**
  String actionPreviewTarget(String target);

  /// Heading above the exact commands and API requests in the action preview.
  ///
  /// In en, this message translates to:
  /// **'What will run'**
  String get actionPreviewSteps;

  /// Action preview: copies the exact commands the action runs, to read or script; copying runs nothing (AUT-02).
  ///
  /// In en, this message translates to:
  /// **'Copy as commands'**
  String get actionPreviewCopyCommands;

  /// Copied action commands: a shell comment above a command that reads an edit's new content on stdin. Keep the leading # so the line stays a comment.
  ///
  /// In en, this message translates to:
  /// **'# The next command reads {size} of new content on stdin.'**
  String actionPreviewCommandsStdin(String size);

  /// Copied action commands: a shell comment naming a Docker Engine API request the action sends, which a shell cannot run as it stands. Keep the leading # so the line stays a comment.
  ///
  /// In en, this message translates to:
  /// **'# Docker Engine API: {request}'**
  String actionPreviewCommandsApi(String request);

  /// Action preview: the commands are on the clipboard; the action itself has not run.
  ///
  /// In en, this message translates to:
  /// **'Copied. Nothing ran.'**
  String get actionPreviewCommandsCopied;

  /// Action preview: the clipboard refused the commands, so pasting now would paste something else.
  ///
  /// In en, this message translates to:
  /// **'Not copied. The clipboard still holds its earlier text.'**
  String get actionPreviewCommandsNotCopied;

  /// Badge on a step that runs as root through admin mode (SAF-03). Lowercase on purpose: the account name.
  ///
  /// In en, this message translates to:
  /// **'root'**
  String get actionPreviewRoot;

  /// Tooltip and screen reader label of the root badge on a step in the action preview.
  ///
  /// In en, this message translates to:
  /// **'This step runs as root through admin mode.'**
  String get actionPreviewRootDetail;

  /// Line naming who runs the steps; identity is an account name such as root or deploy.
  ///
  /// In en, this message translates to:
  /// **'Runs as {identity}'**
  String actionPreviewRunner(String identity);

  /// Line naming who runs the steps and through which container engine.
  ///
  /// In en, this message translates to:
  /// **'Runs as {identity} through {engine}'**
  String actionPreviewRunnerEngine(String identity, String engine);

  /// Line saying which credentials the run uses; credentials is the engine's RunnerCredentials name.
  ///
  /// In en, this message translates to:
  /// **'{credentials, select, session{Signs in with this connection\'s own sign-in.} adminPassword{Uses the admin mode password.} passwordless{Needs no password.} other{}}'**
  String actionPreviewCredentials(String credentials);

  /// Heading above the host writes the action causes (03 §8.11).
  ///
  /// In en, this message translates to:
  /// **'What it leaves on the server'**
  String get actionPreviewHostWrites;

  /// One host write in the action preview; row is the engine's HostWriteRow name.
  ///
  /// In en, this message translates to:
  /// **'{row, select, userOperationRecords{An operation record in your home directory} rootOperationRecords{An operation record under /var/lib/klabautermann} transientUnit{A transient systemd unit, gone when it ends} engineState{The container engine\'s own state} loginRecords{Login records, as every SSH command leaves} editTarget{The file or crontab you edited} editTempFile{A temporary copy beside the file, renamed over it or removed} userBackups{A backup in your Klabautermann backups folder} rootBackups{A backup under /var/lib/klabautermann/backups} footprintManifest{The list of what Klabautermann keeps on the server} packageLists{The package manager\'s cached package lists} auditSyslog{One line in the system log naming this action and this device} other{A change on the server}}'**
  String actionPreviewHostWrite(String row);

  /// The action's impact in the preview; kind is the engine's ImpactKind name and count a number of containers.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, dropsSession{This can drop your connection to the server.} stopsContainers{This stops {count} running containers.} removesVolumes{This deletes the container\'s volumes and the data in them.} forcesImageInUse{{count} containers still use this image.} deletesVolumeData{This deletes the volume and the data in it.} interruptsTarget{This interrupts what the target is doing.} restartsHost{This restarts the server: everything on it stops, and the connection drops until it is back.} stopsHost{This turns the server off: everything on it stops, and it stays off until someone starts it.} other{}}'**
  String actionPreviewImpact(String kind, int count);

  /// Why the target is protected (SAF-22); reason is the engine's ProtectedReason name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, builtIn{Protected: Klabautermann always protects this target.} sessionPath{Protected: your connection to the server runs through it.} publishesSessionPort{Protected: it publishes the SSH port or a VPN port.} userMarked{Protected: you marked it protected.} other{Protected.}}'**
  String actionPreviewProtected(String reason);

  /// Notice in the action preview when another tool manages the container or stack (03 §8.7).
  ///
  /// In en, this message translates to:
  /// **'Managed by {manager}. Acting on it here can conflict with {manager}.'**
  String actionPreviewOwnership(String manager);

  /// Preview note for an operation that runs detached on the server (03 §7.17).
  ///
  /// In en, this message translates to:
  /// **'Runs on the server and continues if you leave or the connection drops. Its result shows under Operations.'**
  String get actionPreviewDetached;

  /// Preview note for a detached operation on iOS, where the app does not run in the background (03 §7.17).
  ///
  /// In en, this message translates to:
  /// **'Runs on the server and continues if you leave the app or the connection drops. Its result shows under Operations when you come back.'**
  String get actionPreviewDetachedIos;

  /// Heading above what a prune removes (DKE-05).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Removes 1 object} other{Removes {count} objects}}'**
  String actionPreviewPruneRemoves(int count);

  /// Under a prune's heading: the disk space it frees, as the engine reports it (DKE-05).
  ///
  /// In en, this message translates to:
  /// **'Frees {size}'**
  String actionPreviewPruneFrees(String size);

  /// One object a prune removes, with its size (DKE-05).
  ///
  /// In en, this message translates to:
  /// **'{name} ({size})'**
  String actionPreviewPruneItem(String name, String size);

  /// Heading above what a prune leaves, each with why (DKE-05's exemption labels).
  ///
  /// In en, this message translates to:
  /// **'Kept'**
  String get actionPreviewPruneKeeps;

  /// One object a prune leaves and why (DKE-05).
  ///
  /// In en, this message translates to:
  /// **'{name}: {reason, select, inUse{in use} builtin{the engine\'s own} other{kept}}'**
  String actionPreviewPruneKept(String name, String reason);

  /// Heading above a redeploy's orphan containers (STK-06).
  ///
  /// In en, this message translates to:
  /// **'Containers the stack\'s files no longer name'**
  String get actionPreviewOrphans;

  /// Switch in a redeploy preview that plans it again with --remove-orphans, which needs the typed confirmation (STK-06).
  ///
  /// In en, this message translates to:
  /// **'Also remove these containers'**
  String get actionPreviewRemoveOrphans;

  /// A warning in the action preview; warning is the engine's PlanWarning name.
  ///
  /// In en, this message translates to:
  /// **'{warning, select, profileGatedServices{Some running services are enabled only by a compose profile, which Klabautermann cannot see. The redeploy leaves them as they are.} profilesUnknown{The compose CLI could not list every profile\'s services, so some of these containers may belong to a service a profile enables.} mayDieAtLogout{This server ends your processes when you log out, which can stop the operation before it finishes.} unitNotVerified{This server\'s systemd is not known to be version 250 or later, so the unit file is not checked before it is replaced.} other{}}'**
  String actionPreviewWarning(String warning);

  /// Toast when a detached operation started on the server; its result shows under Operations.
  ///
  /// In en, this message translates to:
  /// **'Started on the server: {target}'**
  String actionStartedOnServer(String target);

  /// Heading above the danger findings in the action preview (AI-01).
  ///
  /// In en, this message translates to:
  /// **'Warnings'**
  String get actionPreviewDanger;

  /// One danger finding in the action preview (AI-01): its severity, then the linter's explanation.
  ///
  /// In en, this message translates to:
  /// **'{severity, select, critical{Critical} other{Warning}}: {explanation}'**
  String actionPreviewFinding(String severity, String explanation);

  /// Confirmation line for an action that needs an acknowledgement (SAF-05 tier 1).
  ///
  /// In en, this message translates to:
  /// **'This acts on {target}.'**
  String actionConfirmNames(String target);

  /// Label of the field where the user types the target's name to confirm a protected or irreversible action (SAF-05 tier 2).
  ///
  /// In en, this message translates to:
  /// **'Type {target} to confirm'**
  String actionConfirmType(String target);

  /// Button that runs the previewed action.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get actionConfirmRun;

  /// Button that closes the action preview without running anything.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionConfirmCancel;

  /// Toast when a confirmed action starts.
  ///
  /// In en, this message translates to:
  /// **'Running on {target}'**
  String actionRunning(String target);

  /// Toast when an action finished successfully.
  ///
  /// In en, this message translates to:
  /// **'Done: {target}'**
  String actionSucceeded(String target);

  /// Toast when an action failed; failure is the engine's ActionFailure name.
  ///
  /// In en, this message translates to:
  /// **'{target} did not finish: {failure, select, noLink{there is no connection to the server.} revalidation{the target changed since the preview.} elevationRefused{admin mode refused the step.} stepFailed{a step failed.} transport{the connection failed during the run.} unsupportedStep{this version cannot run one of its steps.} adminRequired{it needs admin mode.} launchFailed{its operation could not be started on the server.} other{it failed.}}'**
  String actionFailed(String target, String failure);

  /// Toast when an action failed without a typed reason.
  ///
  /// In en, this message translates to:
  /// **'{target} did not finish.'**
  String actionFailedPlain(String target);

  /// Toast when an action was cancelled.
  ///
  /// In en, this message translates to:
  /// **'{target} was cancelled.'**
  String actionCancelled(String target);

  /// Toast when the engine refused to plan or run an action; reason is the engine's ActionRefusalReason name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notImplemented{This action is not available yet.} unknownPlan{The preview is out of date. Open it again.} expiredPlan{The preview is out of date. Open it again.} stalePlan{The connection changed since the preview. Open it again.} confirmationMismatch{The confirmation did not match.} observeOnly{Turn on Allow actions for this server first.} readOnly{The server is read-only.} adminRequired{Turn on admin mode first.} invalidTarget{This target cannot be acted on.} targetChanged{The target changed. Look again before acting.} noLink{Connect to the server first.} engineUnavailable{The server\'s container engine cannot be reached.} imageInUse{Containers use this image. Remove them first, or force the removal.} volumeInUse{A container mounts this volume. Remove the container first.} volumeExists{A volume with this name already exists.} networkInUse{A container is on this network. Stop or disconnect it first.} builtinNetwork{This is one of the engine\'s own networks, which stay.} nothingToPrune{There is nothing to prune.} dependencyCycle{The stack\'s services depend on each other in a loop, so there is no order to act in.} stackManaged{A manager deploys this stack. Redeploy it there.} stackUnverified{The stack\'s files are not verified as its source, so it cannot be redeployed from them.} legacyComposeOnly{Only the legacy docker-compose is installed, which Klabautermann does not run.} sudoRightMissing{This needs root, and your sudo rule allows only docker.} other{The action was refused.}}'**
  String actionRefused(String reason);

  /// Process action (PRC-02): sends SIGTERM, asking the process to end.
  ///
  /// In en, this message translates to:
  /// **'Terminate'**
  String get processTerminate;

  /// Process action (PRC-02): sends SIGKILL, ending the process at once.
  ///
  /// In en, this message translates to:
  /// **'Kill'**
  String get processKill;

  /// Process action menu holding every other signal (PRC-02).
  ///
  /// In en, this message translates to:
  /// **'Send signal'**
  String get processSendSignal;

  /// A signal's name in the Send signal menu; name is its kill -s name such as HUP.
  ///
  /// In en, this message translates to:
  /// **'SIG{name}'**
  String processSignalName(String name);

  /// Unit action (SVC-03).
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get unitStart;

  /// Unit action (SVC-03).
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get unitStop;

  /// Unit action (SVC-03).
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get unitRestart;

  /// Unit action (SVC-03): reloads the unit's configuration.
  ///
  /// In en, this message translates to:
  /// **'Reload'**
  String get unitReload;

  /// Button where something needs root (SAF-02): asks the engine to turn admin mode on for this server, as the header's chip does.
  ///
  /// In en, this message translates to:
  /// **'Turn on admin mode'**
  String get adminTurnOn;

  /// Container action (CTR-02).
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get dockerContainerStart;

  /// Container action (CTR-02).
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get dockerContainerStop;

  /// Container action (CTR-02).
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get dockerContainerRestart;

  /// Container action (CTR-05): freezes the container's processes.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get dockerContainerPause;

  /// Container action (CTR-05): resumes a paused container.
  ///
  /// In en, this message translates to:
  /// **'Unpause'**
  String get dockerContainerUnpause;

  /// Container action (CTR-05): sends the engine's default signal, SIGKILL.
  ///
  /// In en, this message translates to:
  /// **'Kill'**
  String get dockerContainerKill;

  /// Container action (CTR-06), offered once the container has stopped.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get dockerContainerRemove;

  /// Container action (CTR-06): also removes the container's anonymous volumes, behind the typed confirmation.
  ///
  /// In en, this message translates to:
  /// **'Remove with volumes'**
  String get dockerContainerRemoveVolumes;

  /// Image action (IMG-02) for an image no container uses.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get dockerImageRemove;

  /// Image action (IMG-02) for an image containers use, behind the typed confirmation.
  ///
  /// In en, this message translates to:
  /// **'Force remove'**
  String get dockerImageForceRemove;

  /// Stack action (STK-03): starts the project's containers in dependency order.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get dockerStackStart;

  /// Stack action (STK-03): stops the project's containers in reverse dependency order.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get dockerStackStop;

  /// Stack action (STK-03).
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get dockerStackRestart;

  /// Tooltip of the button that opens a container's or image's actions in the phone list.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get dockerActions;

  /// A jobs table cell as a screen reader hears it: the job's name, then a badge such as jobsPaused.
  ///
  /// In en, this message translates to:
  /// **'{text}, {badge}'**
  String jobsBadged(String text, String badge);

  /// Screen-reader name of the icon on a paused cron line's row (JOB-07).
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get jobsPaused;

  /// Note in a paused cron line's details (JOB-07).
  ///
  /// In en, this message translates to:
  /// **'Paused: cron skips this line until it is resumed.'**
  String get jobsPausedDetail;

  /// Screen-reader name of the icon on a cron line another manager owns (JOB-09); manager is the engine's CrontabManager name.
  ///
  /// In en, this message translates to:
  /// **'{manager, select, dokku{Managed by Dokku} coolify{Managed by Coolify} dokploy{Managed by Dokploy} runtipi{Managed by Runtipi} other{Managed by another tool}}'**
  String jobsManagedBy(String manager);

  /// Note in the details of a cron line another manager owns (JOB-09); manager is the engine's CrontabManager name.
  ///
  /// In en, this message translates to:
  /// **'{manager, select, dokku{Dokku} coolify{Coolify} dokploy{Dokploy} runtipi{Runtipi} other{Another tool}} manages this line. Change it there; a change here may be overwritten.'**
  String jobsManagedDetail(String manager);

  /// Label of a job's last run in its details (JOB-05).
  ///
  /// In en, this message translates to:
  /// **'Last run'**
  String get jobsLastRun;

  /// A job's last run while it is being read.
  ///
  /// In en, this message translates to:
  /// **'Reading…'**
  String get jobsLastRunReading;

  /// A timer's last run when it never triggered.
  ///
  /// In en, this message translates to:
  /// **'Never triggered.'**
  String get jobsLastRunNever;

  /// Note under a timer's last run when its service succeeded.
  ///
  /// In en, this message translates to:
  /// **'It succeeded.'**
  String get jobsLastRunSucceeded;

  /// Note under a timer's last run when its service failed; result is systemd's Result word, such as exit-code.
  ///
  /// In en, this message translates to:
  /// **'It ended as {result}, exit status {status}.'**
  String jobsLastRunExited(String result, int status);

  /// Note under a timer's last run when its service ended without an exit status; result is systemd's Result word.
  ///
  /// In en, this message translates to:
  /// **'It ended as {result}.'**
  String jobsLastRunEnded(String result);

  /// Note under a cron line's last run (JOB-05).
  ///
  /// In en, this message translates to:
  /// **'When cron started it; cron logs no exit status.'**
  String get jobsLastRunNoStatus;

  /// A cron line's last run when the log holds no start of it.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{cron logged no job starts that can be read.} =1{Not among the 1 newest job start cron logged.} other{Not among the {count} newest job starts cron logged.}}'**
  String jobsLastRunNotLogged(int count);

  /// A job's last run when its read failed; failure is the engine's JobHistoryFailure name.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Connect to the server to read the last run.} invalidTarget{This job\'s last run cannot be read.} other{The last run could not be read.}}'**
  String jobsLastRunFailed(String failure);

  /// Status in a cron line's run output sheet while it runs (JOB-19).
  ///
  /// In en, this message translates to:
  /// **'Running…'**
  String get jobsCronRunRunning;

  /// Status in a cron line's run output sheet when the command succeeded.
  ///
  /// In en, this message translates to:
  /// **'It finished with exit status 0.'**
  String get jobsCronRunSucceeded;

  /// Status in a cron line's run output sheet when the command exited non-zero.
  ///
  /// In en, this message translates to:
  /// **'It finished with exit status {status}.'**
  String jobsCronRunExited(int status);

  /// A cron line's run output when the command printed nothing.
  ///
  /// In en, this message translates to:
  /// **'It printed nothing.'**
  String get jobsCronRunNoOutput;

  /// Note under a cron line's run output when the engine capped it.
  ///
  /// In en, this message translates to:
  /// **'The output was longer than this; the rest was dropped.'**
  String get jobsCronRunTruncated;

  /// Timer action (JOB-08): starts the unit the timer activates now.
  ///
  /// In en, this message translates to:
  /// **'Run now'**
  String get jobsRunNow;

  /// Cron line action (JOB-07): comments the line out, through an edit of the crontab, so cron skips it until it is resumed.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get jobsPause;

  /// Paused cron line action (JOB-07): restores the line Pause commented out, through an edit of the crontab.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get jobsResume;

  /// Toast when Pause or Resume reads the crontab and the line has changed or gone since the Jobs tab read it (JOB-07).
  ///
  /// In en, this message translates to:
  /// **'The crontab no longer holds this line as shown. Wait for the next reading and try again.'**
  String get jobsPauseLineChanged;

  /// Title of the sheet that follows a timer run's journal; unit is the service the timer started.
  ///
  /// In en, this message translates to:
  /// **'Output of {unit}'**
  String jobsRunOutputTitle(String unit);

  /// Tooltip and screen reader label of the button that closes the run output sheet.
  ///
  /// In en, this message translates to:
  /// **'Close output'**
  String get jobsRunOutputClose;

  /// A job's source when it is another user's crontab, read in admin mode (JOB-03); user is the account name.
  ///
  /// In en, this message translates to:
  /// **'{user}\'s crontab'**
  String jobsSourceUserCrontab(String user);

  /// Choice on the Jobs tab's source switch: the login user's crontab, the system crontabs and the timers (the cron and timers streams).
  ///
  /// In en, this message translates to:
  /// **'Yours and the system\'s'**
  String get jobsSourceMine;

  /// Choice on the Jobs tab's source switch, in admin mode: every other user's crontab, read-only (JOB-03).
  ///
  /// In en, this message translates to:
  /// **'Other users'**
  String get jobsSourceOtherUsers;

  /// Notice while the other users' crontabs are being read.
  ///
  /// In en, this message translates to:
  /// **'Reading other users\' crontabs.'**
  String get jobsOtherUsersReading;

  /// Button that reads the other users' crontabs again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get jobsOtherUsersRefresh;

  /// Shown when the spool holds no other user's crontab.
  ///
  /// In en, this message translates to:
  /// **'No other user has a crontab.'**
  String get jobsOtherUsersEmpty;

  /// Notice when the other users' crontabs could not be read; failure is the engine's UserCrontabsFailure name.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Other users\' crontabs need a connection to the server.} adminRequired{Other users\' crontabs need admin mode.} elevationRefused{Admin mode could not read the crontabs.} noSpool{This server keeps no crontab spool.} spoolDenied{Even admin mode may not list the crontab spool.} unreadable{The crontab spool could not be read.} transport{The connection failed while reading.} other{Other users\' crontabs could not be read.}}'**
  String jobsOtherUsersFailure(String failure);

  /// Notice naming the users whose crontab could not be read; users is a comma-separated list of account names.
  ///
  /// In en, this message translates to:
  /// **'Could not read the crontab of {users}.'**
  String jobsOtherUsersUnreadable(String users);

  /// Notice when the spool lists more users than one read takes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 more user\'s crontab was not read.} other{{count} more users\' crontabs were not read.}}'**
  String jobsOtherUsersNotRead(int count);

  /// Notice under the other users' crontabs (03 §8.9).
  ///
  /// In en, this message translates to:
  /// **'Commands are masked where they look like they hold secrets.'**
  String get jobsOtherUsersMasked;

  /// Item in the server header's Safety menu that opens the server's activity log (SAF-11).
  ///
  /// In en, this message translates to:
  /// **'Activity'**
  String get activityMenu;

  /// Title of the activity log page; server is the server's name.
  ///
  /// In en, this message translates to:
  /// **'Activity on {server}'**
  String activityTitle(String server);

  /// Explanation at the top of the activity log page (03 §8.10).
  ///
  /// In en, this message translates to:
  /// **'Every action this device ran on the server, newest first. Records are kept for 90 days and never synced. Commands are stored with secrets removed.'**
  String get activityDetail;

  /// Notice on the activity log page when the audit log is kept in memory only.
  ///
  /// In en, this message translates to:
  /// **'Another Klabautermann window has the settings folder, so this log lasts only until this window closes.'**
  String get activityInMemory;

  /// Column of the activity log: when the run ended.
  ///
  /// In en, this message translates to:
  /// **'Time'**
  String get activityColumnTime;

  /// Column of the activity log: the unit, process, container or other target.
  ///
  /// In en, this message translates to:
  /// **'Target'**
  String get activityColumnTarget;

  /// Column of the activity log: what was done.
  ///
  /// In en, this message translates to:
  /// **'Action'**
  String get activityColumnAction;

  /// Column of the activity log: how the run was confirmed.
  ///
  /// In en, this message translates to:
  /// **'Confirmation'**
  String get activityColumnTier;

  /// Column of the activity log: how the run ended.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get activityColumnResult;

  /// An activity log row's action; action is the engine's intent type name.
  ///
  /// In en, this message translates to:
  /// **'{action, select, KillProcess{Signal} UnitAction{Unit action} StartTimer{Run timer now} RefreshPackageLists{Refresh package lists} PowerAction{Reboot or shut down} ContainerAction{Container action} RemoveContainer{Remove container} ContainerBulkAction{Containers action} RemoveImage{Remove image} CreateVolume{Create volume} RemoveVolume{Remove volume} RemoveNetwork{Remove network} PruneDocker{Prune} PullImage{Pull image} StackAction{Stack action} RedeployStack{Redeploy stack} ContainerExec{Run command} ContainerShell{Container shell} EditFile{Edit} KeepLastBackups{Keep recent backups} RemoveBackups{Remove backups} other{Action}}'**
  String activityAction(String action);

  /// An activity log row's confirmation; tier is the engine's ConfirmationTier name.
  ///
  /// In en, this message translates to:
  /// **'{tier, select, none{None} acknowledge{Confirmed} typedPhrase{Name typed} other{}}'**
  String activityTier(String tier);

  /// An activity log row's result; outcome is the engine's ActionOutcome name.
  ///
  /// In en, this message translates to:
  /// **'{outcome, select, succeeded{Done} failed{Failed} cancelled{Cancelled} other{}}'**
  String activityResult(String outcome);

  /// Why a run failed, in the activity record's details; failure is the engine's ActionFailure name.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{No connection to the server.} revalidation{The target changed since the preview.} elevationRefused{Admin mode refused the step.} stepFailed{A step failed.} transport{The connection failed during the run.} unsupportedStep{This version could not run a step.} adminRequired{It needed admin mode.} launchFailed{Its operation could not be started on the server.} other{It failed.}}'**
  String activityFailure(String failure);

  /// A failed step's exit status in an activity record's details.
  ///
  /// In en, this message translates to:
  /// **'Exit status {code}'**
  String activityExitCode(int code);

  /// A failed Docker step's HTTP status in an activity record's details.
  ///
  /// In en, this message translates to:
  /// **'Engine answered HTTP {status}'**
  String activityHttpStatus(int status);

  /// Heading above an activity record's steps, secrets removed.
  ///
  /// In en, this message translates to:
  /// **'What ran'**
  String get activitySteps;

  /// Shown in the activity table while the log is read.
  ///
  /// In en, this message translates to:
  /// **'Reading the log.'**
  String get activityReading;

  /// Shown when the activity log is empty.
  ///
  /// In en, this message translates to:
  /// **'Nothing has run on this server from this device.'**
  String get activityEmpty;

  /// Button that reads the next page of older activity records.
  ///
  /// In en, this message translates to:
  /// **'Show older'**
  String get activityOlder;

  /// Tooltip and screen reader label of the button that copies the activity log as JSON, secrets already removed.
  ///
  /// In en, this message translates to:
  /// **'Copy the log'**
  String get activityCopy;

  /// Toast after the activity log was copied.
  ///
  /// In en, this message translates to:
  /// **'The log is on the clipboard, with secrets removed.'**
  String get activityCopied;

  /// Toast when the clipboard refused the activity log.
  ///
  /// In en, this message translates to:
  /// **'Not copied. Try again.'**
  String get activityNotCopied;

  /// An activity log row's time: its local date, then its time of day, both formatted by the locale.
  ///
  /// In en, this message translates to:
  /// **'{date} {time}'**
  String activityTime(String date, String time);

  /// Server header chip while detached operations run on the server (03 §7.17); count is how many.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 operation running} other{{count} operations running}}'**
  String detachedChipRunning(int count);

  /// Server header chip when detached operations ended and their results wait to be seen; count is how many.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 operation result} other{{count} operation results}}'**
  String detachedChipResults(int count);

  /// Title of the sheet listing a server's detached operations; server is its display name.
  ///
  /// In en, this message translates to:
  /// **'Operations on {server}'**
  String detachedSheetTitle(String server);

  /// Notice in the operations sheet when a directory was denied or its listing was cut short.
  ///
  /// In en, this message translates to:
  /// **'Some operations may be missing: an operation folder on the server could not be read.'**
  String get detachedIncomplete;

  /// The operations sheet when the server has none.
  ///
  /// In en, this message translates to:
  /// **'No operations.'**
  String get detachedEmpty;

  /// Under an operation another device started, whose action this device does not know.
  ///
  /// In en, this message translates to:
  /// **'Started on another device.'**
  String get detachedLaunchedElsewhere;

  /// An operation's name when another device started it; id is its 16-character id.
  ///
  /// In en, this message translates to:
  /// **'Operation {id}'**
  String detachedUnnamed(String id);

  /// An operation's name: the worded action and the target it acts on.
  ///
  /// In en, this message translates to:
  /// **'{action}: {target}'**
  String detachedName(String action, String target);

  /// A running operation's state; time is when it started, in local time.
  ///
  /// In en, this message translates to:
  /// **'Running since {time}.'**
  String detachedRunningSince(String time);

  /// A running operation's state when its start time is unknown.
  ///
  /// In en, this message translates to:
  /// **'Running.'**
  String get detachedRunning;

  /// An operation that ended with exit status 0.
  ///
  /// In en, this message translates to:
  /// **'Finished.'**
  String get detachedSucceeded;

  /// An operation that ended with a non-zero exit status; code is that status.
  ///
  /// In en, this message translates to:
  /// **'Failed with exit status {code}.'**
  String detachedFailed(int code);

  /// An operation whose runner ended without recording a result.
  ///
  /// In en, this message translates to:
  /// **'Stopped before it finished, for example by a logout or a restart.'**
  String get detachedLost;

  /// An operation whose state the engine could not determine.
  ///
  /// In en, this message translates to:
  /// **'Its state could not be read.'**
  String get detachedUnknown;

  /// Button that opens an operation's output, followed live.
  ///
  /// In en, this message translates to:
  /// **'Show output'**
  String get detachedShowOutput;

  /// Button that acknowledges an ended operation's result, which deletes its files.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get detachedAcknowledge;

  /// Under an acknowledged operation of the root directory, whose files only admin mode can delete.
  ///
  /// In en, this message translates to:
  /// **'Cleared. Its files are deleted once admin mode is on.'**
  String get detachedCleanupWaits;

  /// Title of the sheet following an operation's output; name is the operation's name.
  ///
  /// In en, this message translates to:
  /// **'Output of {name}'**
  String detachedOutputTitle(String name);

  /// Tooltip and screen reader label of the button that closes an operation's output sheet.
  ///
  /// In en, this message translates to:
  /// **'Close output'**
  String get detachedOutputClose;

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

  /// The server header's Docker transport label (03 §5.9, E4) for rank 3: in admin mode, sudo runs the engine CLI's relay as root because the account cannot use the socket. "sudo" is the command name; keep the wording of 03 §5.9.
  ///
  /// In en, this message translates to:
  /// **'Engine API via sudo relay (root-equivalent)'**
  String get dockerTransportSudoRelay;

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

  /// The server header's Docker transport label (03 §5.9, E4) when the account cannot use the engine socket but sudo exists, and admin mode is off.
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

  /// The server header's Docker transport label (03 §5.9, E4) when the socket path chosen for the server is not an absolute path.
  ///
  /// In en, this message translates to:
  /// **'No Engine API route: the chosen socket path is not valid'**
  String get dockerTransportInvalidChoice;

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

  /// Server header badge (SAF-08, 03 §8.4): the engine is reached through the sudo relay, which runs as root, so using it equals root on the server.
  ///
  /// In en, this message translates to:
  /// **'Sudo relay: root-equivalent'**
  String get dockerBadgeSudoRelay;

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

  /// Docker tab, shown instead of its panels when Docker cannot be reached, under accessPanelHiddenTitle: the account cannot use the socket, but sudo exists. A Turn on admin mode button follows it.
  ///
  /// In en, this message translates to:
  /// **'Your account cannot use the engine socket. Turn on admin mode to reach it through sudo.'**
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

  /// Docker tab, shown instead of its panels under accessPanelHiddenTitle: the chosen socket path is not valid; the socket picker follows below.
  ///
  /// In en, this message translates to:
  /// **'The socket path chosen for this server is not a valid absolute path. Choose another socket below.'**
  String get dockerGateInvalidChoice;

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

  /// Docker tab: the sub-tab listing volumes.
  ///
  /// In en, this message translates to:
  /// **'Volumes'**
  String get dockerTabVolumes;

  /// Docker tab: the sub-tab listing networks.
  ///
  /// In en, this message translates to:
  /// **'Networks'**
  String get dockerTabNetworks;

  /// Docker tab: the sub-tab with the engine's events timeline (DKE-03).
  ///
  /// In en, this message translates to:
  /// **'Events'**
  String get dockerTabEvents;

  /// Docker tab, Events: what the timeline covers.
  ///
  /// In en, this message translates to:
  /// **'Events show from when Klabautermann started following them. The engine keeps only a limited buffer, so events while the stream was lost may be missing.'**
  String get dockerEventsBuffer;

  /// Docker tab, Events: shown before the watch delivered the timeline.
  ///
  /// In en, this message translates to:
  /// **'Waiting for the events stream…'**
  String get dockerEventsWaiting;

  /// Docker tab, Events: why the watch failed, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} connectionFailed{The connection to the engine failed while following its events.} other{The engine\'s events could not be followed.}}'**
  String dockerEventsFailed(String reason);

  /// Docker tab, Events: the filter chip that shows every event type.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get dockerEventsAll;

  /// Docker tab, Events: a filter chip for one event type.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, container{Containers} image{Images} volume{Volumes} network{Networks} other{Other}}'**
  String dockerEventsKind(String kind);

  /// Docker tab, Events: the search field's hint.
  ///
  /// In en, this message translates to:
  /// **'Search by name, action or image'**
  String get dockerEventsSearch;

  /// Docker tab, Events: the timeline holds no event.
  ///
  /// In en, this message translates to:
  /// **'No events yet. They appear here as the engine reports them.'**
  String get dockerEventsNone;

  /// Docker tab, Events: the filter or search hides every event.
  ///
  /// In en, this message translates to:
  /// **'No event matches the filter.'**
  String get dockerEventsNoMatch;

  /// Docker tab, Events: one event, what it happened to and the engine's action as it names it (start, die, health_status: unhealthy, pull).
  ///
  /// In en, this message translates to:
  /// **'{name}: {action}'**
  String dockerEventsLine(String name, String action);

  /// Docker tab, Events: a container event's image.
  ///
  /// In en, this message translates to:
  /// **'image {image}'**
  String dockerEventsImage(String image);

  /// Docker tab, Events: the code a container exited with.
  ///
  /// In en, this message translates to:
  /// **'exit code {code}'**
  String dockerEventsExitCode(int code);

  /// Docker tab, Events: a span while the events stream was lost; from and until are times of day.
  ///
  /// In en, this message translates to:
  /// **'{resumed, select, true{Not followed from {from} to {until}. The engine sent the events it still held, so some may be missing.} other{Not followed from {from} to {until}. Events in this span are not shown.}}'**
  String dockerEventsGap(String from, String until, String resumed);

  /// Docker tab: the sub-tab listing compose stacks.
  ///
  /// In en, this message translates to:
  /// **'Stacks'**
  String get dockerTabStacks;

  /// Docker tab, engine strip: a rootless engine whose user has linger off (DKE-11).
  ///
  /// In en, this message translates to:
  /// **'This rootless engine runs under your user, and linger is off: its containers stop when your last session on the server ends. Turn linger on with loginctl enable-linger to keep them running.'**
  String get dockerEngineLingerOff;

  /// Docker tab: the sub-tab with the containers' security review (DKE-06, DKE-07).
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get dockerTabReview;

  /// Docker Review sub-tab: what a review does, above its button.
  ///
  /// In en, this message translates to:
  /// **'Reads each container\'s configuration and flags settings that give a container power over the host, expose a database, or let its logs fill the disk. Each container is read once per review.'**
  String get dockerReviewIntro;

  /// Docker Review sub-tab: the button that starts the first review.
  ///
  /// In en, this message translates to:
  /// **'Review containers'**
  String get dockerReviewRun;

  /// Docker Review sub-tab: the button that reviews again after a review.
  ///
  /// In en, this message translates to:
  /// **'Review again'**
  String get dockerReviewAgain;

  /// Docker Review sub-tab: while each container is read.
  ///
  /// In en, this message translates to:
  /// **'Reading each container\'s configuration…'**
  String get dockerReviewReading;

  /// Docker Review sub-tab: no container carries a finding.
  ///
  /// In en, this message translates to:
  /// **'{total, plural, =0{The engine has no containers to review.} =1{The one container carries no finding.} other{None of the {total} containers carries a finding.}}'**
  String dockerReviewNone(int total);

  /// Docker Review sub-tab: how many containers carry findings, of all read.
  ///
  /// In en, this message translates to:
  /// **'Containers with findings: {flagged} of {total}'**
  String dockerReviewFlagged(int flagged, int total);

  /// Docker Review sub-tab: containers past the review's cap, which were not read.
  ///
  /// In en, this message translates to:
  /// **'{omitted, plural, =1{1 more container was not read: a review reads at most {max}.} other{{omitted} more containers were not read: a review reads at most {max}.}}'**
  String dockerReviewOmitted(int omitted, int max);

  /// Docker Review sub-tab: containers whose inspect the engine refused, which the review leaves out.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{The engine refused to inspect 1 container, so it is not reviewed.} other{The engine refused to inspect {count} containers, so they are not reviewed.}}'**
  String dockerReviewUnreadable(int count);

  /// Docker Review sub-tab: a container's heading when it belongs to a compose stack.
  ///
  /// In en, this message translates to:
  /// **'{name} in {stack}'**
  String dockerReviewContainerInStack(String name, String stack);

  /// Docker Review sub-tab: one finding's heading, its level then what it is.
  ///
  /// In en, this message translates to:
  /// **'{level}: {risk}'**
  String dockerReviewFinding(String level, String risk);

  /// Docker Review sub-tab: a finding's severity, by ContainerRiskLevel name.
  ///
  /// In en, this message translates to:
  /// **'{level, select, high{High} medium{Medium} low{Low} other{Finding}}'**
  String dockerReviewLevel(String level);

  /// Docker Review sub-tab: what a finding is, by ContainerRisk name.
  ///
  /// In en, this message translates to:
  /// **'{risk, select, privileged{Privileged} socketMount{Engine socket mounted} hostNetwork{Host network} hostPid{Host processes visible} addedCapabilities{Added capabilities} databasePublished{Database on every address} rootUser{Runs as root} logsUnrotated{Logs never rotate} latestTag{Floating image tag} noHealthcheck{No health check} noRestartPolicy{No restart policy} other{Finding}}'**
  String dockerReviewRisk(String risk);

  /// Docker Review sub-tab: why a finding matters, by ContainerRisk name.
  ///
  /// In en, this message translates to:
  /// **'{risk, select, privileged{It has every device and capability of the host, so a break-in reaches the host.} socketMount{Whoever controls the container controls the engine, which is root on the host.} hostNetwork{It shares the host\'s network and reaches every service listening on it.} hostPid{It sees, and can signal, every process on the host.} addedCapabilities{It holds capabilities beyond the engine\'s default set.} databasePublished{Its database port is published on every address, not only on localhost or a private network.} rootUser{Its processes run as root, and the engine maps root to root on the host.} logsUnrotated{It logs with json-file and no max-size, so its log file grows until the disk is full.} latestTag{A new pull can bring a different image. Pin a version or a digest.} noHealthcheck{The engine cannot tell when it stops working while it still runs.} noRestartPolicy{It stays stopped after a crash or a reboot.} other{It may put the host at risk.}}'**
  String dockerReviewRiskWhy(String risk);

  /// Docker Review sub-tab: the heading over other managers and monitors found among the containers (DKE-17).
  ///
  /// In en, this message translates to:
  /// **'Other tools on this host'**
  String get dockerReviewToolsHeading;

  /// Docker Review sub-tab: another tool's product name, by HostTool name. Product names stay as their makers spell them.
  ///
  /// In en, this message translates to:
  /// **'{tool, select, portainer{Portainer} dockhand{Dockhand} dockge{Dockge} dozzle{Dozzle} beszel{Beszel} uptimeKuma{Uptime Kuma} netdata{Netdata} wud{What\'s Up Docker} other{Another tool}}'**
  String dockerReviewTool(String tool);

  /// Docker Review sub-tab: the container another tool runs in, and its state as the Containers sub-tab words it.
  ///
  /// In en, this message translates to:
  /// **'Container {name}, {state}'**
  String dockerReviewToolContainer(String name, String state);

  /// Docker Review sub-tab: the container another tool runs in, when the list gives no state.
  ///
  /// In en, this message translates to:
  /// **'Container {name}'**
  String dockerReviewToolContainerName(String name);

  /// Docker Review sub-tab: another tool's container publishes no port.
  ///
  /// In en, this message translates to:
  /// **'It publishes no port.'**
  String get dockerReviewToolNoPorts;

  /// Docker Review sub-tab: why the review failed, by DockerQueryFailure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notInFleet{This server is no longer in the fleet.} linkUnavailable{There is no connection to this server.} profileUnknown{The server\'s capability check has not answered yet.} endpointUnavailable{The Docker engine cannot be reached.} tooManyQueries{This server already has as many Docker reads waiting as Klabautermann allows.} daemonError{The engine refused or failed to list or inspect the containers.} connectionFailed{The connection to the engine failed during the review.} cancelled{The review stopped before it finished.} other{The containers could not be reviewed.}}'**
  String dockerReviewFailed(String reason);

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

  /// Docker tab: label beside the picker that chooses which engine socket the app uses for this server (CN-09).
  ///
  /// In en, this message translates to:
  /// **'Socket'**
  String get dockerSocketLabel;

  /// Docker socket picker option: the app finds the engine socket itself.
  ///
  /// In en, this message translates to:
  /// **'Find automatically'**
  String get dockerSocketAutomatic;

  /// Docker socket picker option: the custom socket path chosen for this server.
  ///
  /// In en, this message translates to:
  /// **'Custom: {path}'**
  String dockerSocketCustomCurrent(String path);

  /// Docker socket picker option that opens a dialog to type a socket path.
  ///
  /// In en, this message translates to:
  /// **'Custom path…'**
  String get dockerSocketCustomAction;

  /// Docker tab, under the socket picker: the chosen socket is not the one in use; path is the chosen socket.
  ///
  /// In en, this message translates to:
  /// **'{path} was chosen but did not answer, so the sockets found are tried instead.'**
  String dockerSocketNotInUse(String path);

  /// Toast when the socket choice could not be written to the device settings.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann could not save the socket choice, so it applies only until Klabautermann quits.'**
  String get dockerSocketNotSaved;

  /// Title of the dialog that takes a custom Docker engine socket path.
  ///
  /// In en, this message translates to:
  /// **'Custom engine socket'**
  String get dockerSocketCustomTitle;

  /// Body of the custom socket dialog.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann tries this socket first. If it does not answer, the sockets it finds are tried instead.'**
  String get dockerSocketCustomBody;

  /// Label of the custom socket dialog's text field.
  ///
  /// In en, this message translates to:
  /// **'Socket path'**
  String get dockerSocketCustomField;

  /// Hint in the custom socket dialog's field: an example socket path on a Linux server. Keep it as is.
  ///
  /// In en, this message translates to:
  /// **'/run/user/1000/docker.sock'**
  String get dockerSocketCustomHint;

  /// Custom socket dialog button that applies the typed path.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get dockerSocketCustomUse;

  /// Custom socket dialog button that closes it without a change.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dockerSocketCustomCancel;

  /// Custom socket dialog error: the typed path does not start with a slash.
  ///
  /// In en, this message translates to:
  /// **'Enter an absolute path, starting with /.'**
  String get dockerSocketPathNotAbsolute;

  /// Custom socket dialog error: the typed path holds a line break or a NUL character.
  ///
  /// In en, this message translates to:
  /// **'The path cannot contain line breaks or NUL characters.'**
  String get dockerSocketPathUnsafe;

  /// Appearance tab: heading of the preset grid.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get appearanceThemeTitle;

  /// Appearance tab: title of the theme help dialog.
  ///
  /// In en, this message translates to:
  /// **'Themes'**
  String get appearanceThemeHelpTitle;

  /// Appearance tab: body of the theme help dialog.
  ///
  /// In en, this message translates to:
  /// **'A theme is kept on this device only and never syncs. To use one elsewhere, copy it here and paste it into Klabautermann on the other device.'**
  String get appearanceThemeHelp;

  /// Appearance tab: small print under the preset grid.
  ///
  /// In en, this message translates to:
  /// **'Picking a theme copies its colours here. It is a starting point, not a mode, so everything below stays yours to change.'**
  String get appearanceThemeFootnote;

  /// Appearance tab: tooltip of a preset tile.
  ///
  /// In en, this message translates to:
  /// **'Use the {name} theme'**
  String appearancePresetTooltip(String name);

  /// Appearance tab: heading of the light/dark mode section.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get appearanceModeTitle;

  /// Appearance tab: line above the mode switch.
  ///
  /// In en, this message translates to:
  /// **'Automatic colours follow'**
  String get appearanceModeLead;

  /// Appearance tab: note when a dark palette sets its own surface.
  ///
  /// In en, this message translates to:
  /// **'This theme has its own surface, so it is always dark. Set Surface to Automatic to choose a mode.'**
  String get appearanceOwnSurfaceDark;

  /// Appearance tab: note when a light palette sets its own surface.
  ///
  /// In en, this message translates to:
  /// **'This theme has its own surface, so it is always light. Set Surface to Automatic to choose a mode.'**
  String get appearanceOwnSurfaceLight;

  /// Appearance tab: heading of the colour slots.
  ///
  /// In en, this message translates to:
  /// **'Colours'**
  String get appearanceColoursTitle;

  /// Appearance tab: title of the colours help dialog.
  ///
  /// In en, this message translates to:
  /// **'Automatic colours'**
  String get appearanceColoursHelpTitle;

  /// Appearance tab: body of the colours help dialog.
  ///
  /// In en, this message translates to:
  /// **'Automatic colours are the light or dark neutrals Klabautermann ships with, as the mode picks them. Once you give the theme a surface of its own, they are mixed from that surface and the text instead. Lines and the selection may be translucent.'**
  String get appearanceColoursHelp;

  /// Appearance tab: the accent colour row.
  ///
  /// In en, this message translates to:
  /// **'Accent'**
  String get appearanceAccent;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Surface'**
  String get appearanceSlotSurface;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Sidebar'**
  String get appearanceSlotSidebar;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Headers and bars'**
  String get appearanceSlotRaised;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get appearanceSlotText;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Secondary text'**
  String get appearanceSlotSecondaryText;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Lines'**
  String get appearanceSlotHairline;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Selection'**
  String get appearanceSlotSelection;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get appearanceSlotOnline;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get appearanceSlotOffline;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get appearanceSlotConnecting;

  /// Appearance tab: name of a colour slot.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get appearanceSlotUnknown;

  /// Appearance tab: heading of the status colour slots.
  ///
  /// In en, this message translates to:
  /// **'Status colours'**
  String get appearanceStatusTitle;

  /// Appearance tab: small print under the status colours.
  ///
  /// In en, this message translates to:
  /// **'Each status also keeps its own shape and its name, so these colours never have to say it alone.'**
  String get appearanceStatusFootnote;

  /// Appearance tab: checkbox beside a colour that follows the mode.
  ///
  /// In en, this message translates to:
  /// **'Automatic'**
  String get appearanceAutomatic;

  /// Appearance tab: screen reader label of a colour's Automatic checkbox.
  ///
  /// In en, this message translates to:
  /// **'{label}: Automatic'**
  String appearanceAutomaticSemantics(String label);

  /// Appearance tab: tooltip of a colour swatch.
  ///
  /// In en, this message translates to:
  /// **'Choose the {label} colour'**
  String appearanceChooseColour(String label);

  /// Appearance tab: tooltip of an Automatic colour's swatch.
  ///
  /// In en, this message translates to:
  /// **'Choose a {label} colour (now Automatic)'**
  String appearanceChooseAutomaticColour(String label);

  /// Appearance tab: heading of the font and corner controls.
  ///
  /// In en, this message translates to:
  /// **'Shape and type'**
  String get appearanceShapeTitle;

  /// Appearance tab: label of the interface font field.
  ///
  /// In en, this message translates to:
  /// **'Interface font'**
  String get appearanceInterfaceFont;

  /// Appearance tab: hint of the empty interface font field.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get appearanceInterfaceFontHint;

  /// Appearance tab: helper text under the interface font field.
  ///
  /// In en, this message translates to:
  /// **'Logs and commands keep their monospace font.'**
  String get appearanceInterfaceFontHelper;

  /// Appearance tab: label of the corner slider.
  ///
  /// In en, this message translates to:
  /// **'Corners'**
  String get appearanceCorners;

  /// Appearance tab: corner slider value at no rounding.
  ///
  /// In en, this message translates to:
  /// **'Square'**
  String get appearanceCornersSquare;

  /// Appearance tab: corner slider value as a percentage.
  ///
  /// In en, this message translates to:
  /// **'{percent}%'**
  String appearanceCornersPercent(int percent);

  /// Appearance tab: screen reader value of the corner slider.
  ///
  /// In en, this message translates to:
  /// **'Corners {label}'**
  String appearanceCornersSemantics(String label);

  /// Appearance tab: heading of copy and paste.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get appearanceShareTitle;

  /// Appearance tab: button that copies the theme as text.
  ///
  /// In en, this message translates to:
  /// **'Copy theme'**
  String get appearanceCopyTheme;

  /// Appearance tab: button that pastes a theme.
  ///
  /// In en, this message translates to:
  /// **'Paste theme'**
  String get appearancePasteTheme;

  /// Appearance tab: small print under copy and paste.
  ///
  /// In en, this message translates to:
  /// **'Copies the theme as text you can keep or send. Pasting reads what it can and leaves everything else at the default.'**
  String get appearanceShareFootnote;

  /// Appearance tab: toast after Copy theme.
  ///
  /// In en, this message translates to:
  /// **'Theme copied.'**
  String get appearanceThemeCopied;

  /// Appearance tab: toast when the clipboard holds no theme.
  ///
  /// In en, this message translates to:
  /// **'The clipboard does not hold a theme. Copy one with Copy theme first.'**
  String get appearancePasteNotATheme;

  /// Appearance tab: heading of the reset control.
  ///
  /// In en, this message translates to:
  /// **'Start over'**
  String get appearanceStartOverTitle;

  /// Appearance tab: button that resets the theme to the initial preset.
  ///
  /// In en, this message translates to:
  /// **'Reset to {name}'**
  String appearanceResetButton(String name);

  /// Appearance tab: status beside the reset button when no preset matches.
  ///
  /// In en, this message translates to:
  /// **'Using your own colours.'**
  String get appearanceUsingOwnColours;

  /// Appearance tab: status beside the reset button when a preset matches.
  ///
  /// In en, this message translates to:
  /// **'Using {name}.'**
  String appearanceUsingPreset(String name);

  /// Appearance tab: title of the reset confirmation.
  ///
  /// In en, this message translates to:
  /// **'Reset the theme?'**
  String get appearanceResetTitle;

  /// Appearance tab: body of the reset confirmation.
  ///
  /// In en, this message translates to:
  /// **'Every colour, the font and the corners go back to the {name} theme. The mode stays as it is.'**
  String appearanceResetBody(String name);

  /// Appearance tab: cancels the reset.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get appearanceCancel;

  /// Appearance tab: confirms the reset.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get appearanceReset;

  /// Appearance tab: tooltip of a section's help button.
  ///
  /// In en, this message translates to:
  /// **'About {title}'**
  String appearanceAbout(String title);

  /// Appearance tab: closes a section's help dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get appearanceClose;

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

  /// Containers table column: bytes received and sent since the container started, from its list stats (CTR-08).
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get dockerContainersColumnNetwork;

  /// Containers table column: bytes read from and written to disk since the container started (CTR-08).
  ///
  /// In en, this message translates to:
  /// **'Block I/O'**
  String get dockerContainersColumnBlockIo;

  /// Containers table column: the processes and threads in the container (CTR-08).
  ///
  /// In en, this message translates to:
  /// **'PIDs'**
  String get dockerContainersColumnPids;

  /// Containers table column: the container's first address on a network (CTR-08).
  ///
  /// In en, this message translates to:
  /// **'IP'**
  String get dockerContainersColumnIp;

  /// Containers table column: how long ago a running container started, read from its status (CTR-08).
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get dockerContainersColumnStarted;

  /// Containers table: two byte totals, received then sent, or read then written, as docker stats shows them.
  ///
  /// In en, this message translates to:
  /// **'{first} / {second}'**
  String dockerContainersIo(String first, String second);

  /// Containers tab: the button that opens the column chooser (CTR-08).
  ///
  /// In en, this message translates to:
  /// **'Columns'**
  String get dockerContainersColumns;

  /// Column chooser: its title.
  ///
  /// In en, this message translates to:
  /// **'Columns'**
  String get dockerContainersColumnsTitle;

  /// Column chooser: the tooltip on a column's drag handle.
  ///
  /// In en, this message translates to:
  /// **'Drag to reorder'**
  String get dockerContainersColumnsDrag;

  /// Column chooser: puts back the default columns.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get dockerContainersColumnsReset;

  /// Column chooser: closes it without a change.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dockerContainersColumnsCancel;

  /// Column chooser: shows the checked columns in their order.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get dockerContainersColumnsDone;

  /// Containers tab: the chosen columns show, but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The columns could not be saved. They stay until Klabautermann quits.'**
  String get dockerContainersColumnsNotSaved;

  /// Containers tab: the chip that lists the running containers in one list, the busiest first (CST-05).
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get dockerContainersTop;

  /// Containers tab: the Top chip's tooltip.
  ///
  /// In en, this message translates to:
  /// **'Running containers in one list, the busiest first'**
  String get dockerContainersTopTooltip;

  /// Containers table: a container's memory near its limit (CST-04), after a warning icon, in place of the bytes. share is the used share of the limit.
  ///
  /// In en, this message translates to:
  /// **'{share} of limit'**
  String dockerContainersMemoryRisk(double share);

  /// Container details: the usage charts' heading (CST-03).
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get dockerUsageTitle;

  /// Container details: where the usage charts' samples come from, as the chart legend names it.
  ///
  /// In en, this message translates to:
  /// **'Read every 5 s while these details show'**
  String get dockerUsageSource;

  /// Container details: the usage charts have no reading yet.
  ///
  /// In en, this message translates to:
  /// **'The first reading comes within a few seconds.'**
  String get dockerUsageWaiting;

  /// Container details: a container's memory at or above 90% of its limit (CST-04).
  ///
  /// In en, this message translates to:
  /// **'Memory is at {share} of its limit ({used} of {limit}); near the limit the kernel may kill it (OOM).'**
  String dockerUsageMemoryRisk(double share, String used, String limit);

  /// Container details: the CPU chart's title and series.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get dockerUsageCpu;

  /// Container details: the memory chart's title.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get dockerUsageMemory;

  /// Container details: the memory chart's used series.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get dockerUsageMemoryUsed;

  /// Container details: the memory chart's limit series.
  ///
  /// In en, this message translates to:
  /// **'Limit'**
  String get dockerUsageMemoryLimit;

  /// Container details: the network chart's title.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get dockerUsageNetwork;

  /// Container details: the network chart's received series.
  ///
  /// In en, this message translates to:
  /// **'In'**
  String get dockerUsageNetworkIn;

  /// Container details: the network chart's sent series.
  ///
  /// In en, this message translates to:
  /// **'Out'**
  String get dockerUsageNetworkOut;

  /// Container details: the block I/O chart's title.
  ///
  /// In en, this message translates to:
  /// **'Block I/O'**
  String get dockerUsageBlockIo;

  /// Container details: the block I/O chart's read series.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get dockerUsageBlockRead;

  /// Container details: the block I/O chart's written series.
  ///
  /// In en, this message translates to:
  /// **'Written'**
  String get dockerUsageBlockWrite;

  /// Container details: the PIDs chart's title and series.
  ///
  /// In en, this message translates to:
  /// **'PIDs'**
  String get dockerUsagePids;

  /// Containers tab: the chip that puts a checkbox on each row and heading, to act on several containers at once (CTR-07).
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get dockerContainersSelect;

  /// Containers table: the checkbox column's name, which a screen reader says before each row's selection.
  ///
  /// In en, this message translates to:
  /// **'Selection'**
  String get dockerContainersColumnSelect;

  /// Containers table: whether a row is selected, as a screen reader hears its checkbox cell. selected is true or false.
  ///
  /// In en, this message translates to:
  /// **'{selected, select, true{Selected} other{Not selected}}'**
  String dockerContainersRowSelected(String selected);

  /// Containers table: the row action that selects the container.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get dockerContainersSelectOne;

  /// Containers table: the row action that clears the container's selection.
  ///
  /// In en, this message translates to:
  /// **'Deselect'**
  String get dockerContainersDeselect;

  /// Containers tab: the action on a compose project's heading that selects every container under it.
  ///
  /// In en, this message translates to:
  /// **'Select its containers'**
  String get dockerContainersSelectProject;

  /// Containers tab: the action on a compose project's heading that clears the selection of every container under it.
  ///
  /// In en, this message translates to:
  /// **'Deselect its containers'**
  String get dockerContainersDeselectProject;

  /// Containers tab: a heading's counts with how many of its containers are selected, as a screen reader hears it. summary is dockerContainersGroupSummary's text; selection is all, some or none.
  ///
  /// In en, this message translates to:
  /// **'{summary}, {selection, select, all{all selected} some{some selected} other{none selected}}'**
  String dockerContainersGroupSelection(String summary, String selection);

  /// Containers tab: how many containers are selected, at the start of the bulk bar (CTR-07).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{None selected} =1{1 selected} other{{count} selected}}'**
  String dockerContainersSelectedCount(int count);

  /// Containers tab: a bulk bar button, with how many of the selected containers the verb takes; a stopped container takes no stop. verb is start, stop, restart or remove.
  ///
  /// In en, this message translates to:
  /// **'{verb, select, start{Start} stop{Stop} restart{Restart} remove{Remove} other{Act}} ({count})'**
  String dockerContainersBulkVerb(String verb, int count);

  /// Containers tab: the bulk bar button that selects every container the search and filters show.
  ///
  /// In en, this message translates to:
  /// **'Select all shown'**
  String get dockerContainersSelectAll;

  /// Containers tab: the bulk bar button that clears the selection.
  ///
  /// In en, this message translates to:
  /// **'Clear selection'**
  String get dockerContainersSelectNone;

  /// Containers tab: why the bulk buttons are off when too many containers are selected.
  ///
  /// In en, this message translates to:
  /// **'Select at most {max} containers to act on them at once.'**
  String dockerContainersBulkMax(int max);

  /// A container's state in words. state is the Engine API's state name; a state outside this list shows as the engine gave it instead.
  ///
  /// In en, this message translates to:
  /// **'{state, select, created{Created} running{Running} paused{Paused} restarting{Restarting} removing{Removing} exited{Exited} dead{Dead} other{Unknown}}'**
  String dockerContainerState(String state);

  /// Containers list: a container's state with its flag (CTR-09), as a screen reader hears the state cell. state is dockerContainerState's text; flag is restartLoop (the daemon is restarting it after it exited) or failed (it exited with a code a stop does not leave).
  ///
  /// In en, this message translates to:
  /// **'{state} ({flag, select, restartLoop{restart loop} failed{failed} other{flagged}})'**
  String dockerContainerStateFlagged(String state, String flag);

  /// Containers list: the tooltip on a flagged container's state (CTR-09). flag is restartLoop or failed; code is the exit code in the container's status, which only failed shows.
  ///
  /// In en, this message translates to:
  /// **'{flag, select, restartLoop{The engine is starting it again after it exited, as a restart policy does in a loop. The details show how often it restarted.} failed{Its last run exited with code {code}, which a stop does not leave.} other{Exit code {code}}}'**
  String dockerContainerFlagTooltip(String flag, int code);

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

  /// Images table column: the image's tags, each repository:tag (IMG-01).
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get dockerImagesColumnTags;

  /// Images table column: the image's short ID, as docker images prints it.
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get dockerImagesColumnId;

  /// Images table column: the image's size in IEC units.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get dockerImagesColumnSize;

  /// Images table column: how long ago the image was created, and its date.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get dockerImagesColumnCreated;

  /// Images table column: whether any container, running or not, was created from the image.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get dockerImagesColumnUse;

  /// Images table column: whether the image's registry has a newer digest for its tag (IMG-05).
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get dockerImagesColumnUpdate;

  /// Images list: the badge of a dangling image, one without a tag, which docker images shows as <none>.
  ///
  /// In en, this message translates to:
  /// **'Dangling'**
  String get dockerImagesDangling;

  /// Images list: what a screen reader hears, and a phone row shows, for an image containers were created from, running or not.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{In use by 1 container} other{In use by {count} containers}}'**
  String dockerImagesInUse(int count);

  /// Images table: the Use cell of an image containers were created from, with how many, beside a link icon.
  ///
  /// In en, this message translates to:
  /// **'In use ({count})'**
  String dockerImagesInUseShort(int count);

  /// Images list: no container was created from the image.
  ///
  /// In en, this message translates to:
  /// **'Unused'**
  String get dockerImagesUnused;

  /// Images list: when the image was created, as an age and a date, as a screen reader hears it and a phone row shows it.
  ///
  /// In en, this message translates to:
  /// **'{age}, {date}'**
  String dockerImagesCreated(String age, String date);

  /// Images list: the date an image was created, in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{date}'**
  String dockerImagesDate(DateTime date);

  /// Images list: an image created under a minute ago.
  ///
  /// In en, this message translates to:
  /// **'Less than a minute ago'**
  String get dockerImagesAgeNow;

  /// Images list: an image's age under an hour.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String dockerImagesAgeMinutes(int count);

  /// Images list: an image's age under two days.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String dockerImagesAgeHours(int count);

  /// Images list: an image's age under two weeks.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String dockerImagesAgeDays(int count);

  /// Images list: an image's age under two months.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 week ago} other{{count} weeks ago}}'**
  String dockerImagesAgeWeeks(int count);

  /// Images list: an image's age under two years, a month counted as 30 days.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 month ago} other{{count} months ago}}'**
  String dockerImagesAgeMonths(int count);

  /// Images list: an image's age of two years or more, a year counted as 365 days.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 year ago} other{{count} years ago}}'**
  String dockerImagesAgeYears(int count);

  /// Images list: a filter choice that lists every image.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get dockerImagesFilterAll;

  /// Images list: a filter choice that lists only the images no container was created from.
  ///
  /// In en, this message translates to:
  /// **'Unused'**
  String get dockerImagesFilterUnused;

  /// Images list: a filter choice that lists only the dangling images, those without a tag.
  ///
  /// In en, this message translates to:
  /// **'Dangling'**
  String get dockerImagesFilterDangling;

  /// Images list: the search field's hint.
  ///
  /// In en, this message translates to:
  /// **'Search by tag or ID'**
  String get dockerImagesSearchHint;

  /// Images list: tooltip of the button that clears the search.
  ///
  /// In en, this message translates to:
  /// **'Clear search'**
  String get dockerImagesSearchClear;

  /// Images list on a phone: the label before the sort menu.
  ///
  /// In en, this message translates to:
  /// **'Sort by'**
  String get dockerImagesSortBy;

  /// Images list on a phone: one figure of an image, after its column's name.
  ///
  /// In en, this message translates to:
  /// **'{label}: {value}'**
  String dockerImagesFact(String label, String value);

  /// Images list: the first list has not arrived yet.
  ///
  /// In en, this message translates to:
  /// **'Reading the images…'**
  String get dockerImagesReading;

  /// Images list: the engine listed none.
  ///
  /// In en, this message translates to:
  /// **'This engine has no images.'**
  String get dockerImagesEmpty;

  /// Images list: the search matches none.
  ///
  /// In en, this message translates to:
  /// **'No image matches the search.'**
  String get dockerImagesNoMatch;

  /// Images list: the Unused filter hides every image.
  ///
  /// In en, this message translates to:
  /// **'Every image is in use by a container.'**
  String get dockerImagesNoneUnused;

  /// Images list: the Dangling filter hides every image.
  ///
  /// In en, this message translates to:
  /// **'No image is dangling.'**
  String get dockerImagesNoneDangling;

  /// Images list: a filter choice that lists only the images whose registry has a newer digest.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get dockerImagesFilterUpdates;

  /// Images list: the Updates filter hides every image.
  ///
  /// In en, this message translates to:
  /// **'No image has an update.'**
  String get dockerImagesNoneUpdates;

  /// Images list: the button that asks every tag's registry again, even within the six hours a check is kept.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get dockerImagesUpdatesCheck;

  /// Images list: the update check button while a check runs.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get dockerImagesUpdatesChecking;

  /// Images list: why the update check could not run. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, connectionFailed{The update check could not run on the server.} endpointUnavailable{The update check needs the Docker engine, which is not reachable.} daemonError{The engine refused or failed to list the images for the update check.} other{The update check failed.}}'**
  String dockerImagesUpdatesFailed(String reason);

  /// Images list: the server has no curl for the update check; the button after it asks the Docker engine instead, at the cost it names.
  ///
  /// In en, this message translates to:
  /// **'This server has no curl, so no registry was asked. The engine can ask instead, but each tag it checks spends one of Docker Hub\'s pulls for the server\'s address.'**
  String get dockerImagesUpdatesNoCurl;

  /// Images list: the button that runs the update check through the Docker engine, spending a Docker Hub pull per tag.
  ///
  /// In en, this message translates to:
  /// **'Check through the engine'**
  String get dockerImagesUpdatesThroughDaemon;

  /// Images list: Docker Hub refused the update check for the server's address; time is when the check asks again.
  ///
  /// In en, this message translates to:
  /// **'Docker Hub\'s limit for this server\'s address is used up. Those images are checked again after {time}.'**
  String dockerImagesUpdatesRateLimited(String time);

  /// Images list: the update check has not read this image's registry yet, or the image has no tag.
  ///
  /// In en, this message translates to:
  /// **'Not checked'**
  String get dockerImagesUpdateNotChecked;

  /// Images list: the registry has a newer digest for one of the image's tags.
  ///
  /// In en, this message translates to:
  /// **'Update available'**
  String get dockerImagesUpdateAvailable;

  /// Images list: the registry's digest for each of the image's tags matches the local one.
  ///
  /// In en, this message translates to:
  /// **'Current'**
  String get dockerImagesUpdateCurrent;

  /// Images list: the update check could not compare one of the image's tags; the tooltip says why.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get dockerImagesUpdateUndecided;

  /// Images list: the update check could not compare one of the image's tags, and why.
  ///
  /// In en, this message translates to:
  /// **'Unknown: {reason}'**
  String dockerImagesUpdateUnknown(String reason);

  /// Images list: why the update check could not compare a tag. issue is the check's issue name.
  ///
  /// In en, this message translates to:
  /// **'{issue, select, noResult{the registry did not answer} unauthorized{the registry wants credentials the server\'s Docker CLI does not have} notFound{the registry does not know this tag} rateLimited{Docker Hub\'s limit for the server\'s address is used up} noDigest{this registry does not say which digest it holds} noLocalDigest{this image was not pulled from the registry} other{the registry refused the check}}'**
  String dockerImagesUpdateWhy(String issue);

  /// Images list: why the update check could not compare a tag from a registry that wants credentials.
  ///
  /// In en, this message translates to:
  /// **'the registry wants credentials, and the server\'s Docker CLI has no buildx plugin to read them'**
  String get dockerImagesUpdateWhyNoBuildx;

  /// Images list: why the list could not be read. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} daemonError{The engine refused or failed to list the images.} connectionFailed{The connection to the engine failed while listing the images.} other{The images could not be listed.}}'**
  String dockerImagesFailed(String reason);

  /// Images list: under a failed read, the list it keeps is older.
  ///
  /// In en, this message translates to:
  /// **'The list below is the last one read.'**
  String get dockerImagesKept;

  /// Images list: below Docker API 1.51 the image list carries no container count, and the container list it is computed from failed.
  ///
  /// In en, this message translates to:
  /// **'Which images are in use is unknown: this engine\'s API reports no count, and the containers could not be listed.'**
  String get dockerImagesUseUnknown;

  /// Image history sheet title (IMG-04): the image's tags, or its short id when it has none.
  ///
  /// In en, this message translates to:
  /// **'{image}: history'**
  String dockerImageHistoryTitle(String image);

  /// Image history sheet: shown while the engine reads the image's layers.
  ///
  /// In en, this message translates to:
  /// **'Reading the image\'s history…'**
  String get dockerImageHistoryReading;

  /// Image history sheet: the daemon answered with an empty history.
  ///
  /// In en, this message translates to:
  /// **'The engine reports no layers for this image.'**
  String get dockerImageHistoryEmpty;

  /// Image history sheet: how many layer instructions the engine masked, since build arguments can hold secrets.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 instruction holds masked values. Reveal values shows them for {seconds} seconds.} other{{count} instructions hold masked values. Reveal values shows them for {seconds} seconds.}}'**
  String dockerImageHistoryMasked(int count, int seconds);

  /// Image history sheet: a layer whose CreatedBy is empty, as for an imported base layer.
  ///
  /// In en, this message translates to:
  /// **'No instruction recorded'**
  String get dockerImageHistoryNoInstruction;

  /// Image history sheet: the label before a layer's comment, such as the builder that made it.
  ///
  /// In en, this message translates to:
  /// **'Comment'**
  String get dockerImageHistoryComment;

  /// Container details: the section of web pages the container's labels point at (CTR-11).
  ///
  /// In en, this message translates to:
  /// **'Links'**
  String get dockerLinksTitle;

  /// Container details, Links: where a link came from, under its address.
  ///
  /// In en, this message translates to:
  /// **'{source, select, dockhand{From a Dockhand label} dozzle{From a Dozzle label} traefik{A Traefik route} caddy{A Caddy site} other{From a label}}'**
  String dockerLinksFrom(String source);

  /// Container details, Links: where a link came from, for one container port.
  ///
  /// In en, this message translates to:
  /// **'{source, select, dockhand{From a Dockhand label, port {port}} other{From a label, port {port}}}'**
  String dockerLinksFromPort(String source, String port);

  /// Container details, Links: the tooltip and screen-reader label of the button that opens a link.
  ///
  /// In en, this message translates to:
  /// **'Open {name} in the browser'**
  String dockerLinksOpen(String name);

  /// Container details, Links: shown when the system refused to open a link.
  ///
  /// In en, this message translates to:
  /// **'The link could not be opened in a browser.'**
  String get dockerLinksNotOpened;

  /// Container details: the section listing the processes running inside the container (CTR-10).
  ///
  /// In en, this message translates to:
  /// **'Processes'**
  String get dockerProcessesTitle;

  /// Container details, Processes: shown while the container is stopped.
  ///
  /// In en, this message translates to:
  /// **'The container is not running, so it has no processes.'**
  String get dockerProcessesStopped;

  /// Container details, Processes: shown while the processes are read.
  ///
  /// In en, this message translates to:
  /// **'Reading processes…'**
  String get dockerProcessesReading;

  /// Container details, Processes: the button that reads the container's processes again.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get dockerProcessesReadAgain;

  /// Container details, Processes: shown when the read lists no process.
  ///
  /// In en, this message translates to:
  /// **'The engine lists no processes for this container.'**
  String get dockerProcessesNone;

  /// Container details, Processes: how many processes the container runs.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 process} other{{count} processes}}'**
  String dockerProcessesCount(int count);

  /// Container details, Processes: why the read failed, by DockerQueryFailure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notInFleet{This server is no longer in the fleet.} linkUnavailable{There is no connection to this server.} profileUnknown{The server\'s capability check has not answered yet.} endpointUnavailable{The Docker engine cannot be reached.} tooManyQueries{This server already has as many Docker reads waiting as Klabautermann allows.} notFound{The engine no longer has this container.} daemonError{The engine refused or failed to list the container\'s processes.} connectionFailed{The connection to the engine failed while reading the processes.} cancelled{The read stopped before it ran.} other{The container\'s processes could not be read.}}'**
  String dockerProcessesFailed(String reason);

  /// Image history sheet: why the history read failed, by DockerQueryFailure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notInFleet{This server is no longer in the fleet.} linkUnavailable{There is no connection to this server.} profileUnknown{The server\'s capability check has not answered yet.} endpointUnavailable{The Docker engine cannot be reached.} tooManyQueries{This server already has as many Docker reads waiting as Klabautermann allows.} notFound{The engine no longer has this image.} daemonError{The engine refused or failed to read the image\'s history.} connectionFailed{The connection to the engine failed while reading the history.} cancelled{The read stopped before it ran.} other{The image\'s history could not be read.}}'**
  String dockerImageHistoryFailed(String reason);

  /// Images list: the server's link has a session limit (03 §5.2) on a relay route.
  ///
  /// In en, this message translates to:
  /// **'Low-session mode: the list is read again every 15 seconds instead of following engine events.'**
  String get dockerImagesLowSessionRelay;

  /// Volumes list: the column of volume names.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get dockerVolumesColumnName;

  /// Volumes list: the column of volume drivers, such as local.
  ///
  /// In en, this message translates to:
  /// **'Driver'**
  String get dockerVolumesColumnDriver;

  /// Volumes list: what a screen reader hears, and a phone row shows, for a volume containers mount, running or not.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Mounted by 1 container} other{Mounted by {count} containers}}'**
  String dockerVolumesInUse(int count);

  /// Volumes list: the search field's hint.
  ///
  /// In en, this message translates to:
  /// **'Search by name or driver'**
  String get dockerVolumesSearchHint;

  /// Volumes list: shown until the first list arrives.
  ///
  /// In en, this message translates to:
  /// **'Reading the volumes…'**
  String get dockerVolumesReading;

  /// Volumes list: the engine listed none.
  ///
  /// In en, this message translates to:
  /// **'This engine has no volumes.'**
  String get dockerVolumesEmpty;

  /// Volumes list: the search hides every volume.
  ///
  /// In en, this message translates to:
  /// **'No volume matches the search.'**
  String get dockerVolumesNoMatch;

  /// Volumes list: the Unused filter hides every volume.
  ///
  /// In en, this message translates to:
  /// **'Every volume is mounted by a container.'**
  String get dockerVolumesNoneUnused;

  /// Volumes list: why the list could not be read. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} daemonError{The engine refused or failed to list the volumes.} connectionFailed{The connection to the engine failed while listing the volumes.} other{The volumes could not be listed.}}'**
  String dockerVolumesFailed(String reason);

  /// Volumes list: the volume list carries no use count, and the container list it is computed from failed.
  ///
  /// In en, this message translates to:
  /// **'Which volumes are in use is unknown: the containers, whose mounts tell, could not be listed.'**
  String get dockerVolumesUseUnknown;

  /// Images list: the button over the list that opens the pull sheet (IMG-03).
  ///
  /// In en, this message translates to:
  /// **'Pull image…'**
  String get dockerPullOpen;

  /// Pull sheet: its title (IMG-03).
  ///
  /// In en, this message translates to:
  /// **'Pull an image'**
  String get dockerPullTitle;

  /// Pull sheet: the label of the image reference field.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get dockerPullReference;

  /// Pull sheet: example references in the empty field. A name without a tag pulls latest.
  ///
  /// In en, this message translates to:
  /// **'nginx:1.27 or registry.example.com/app:2'**
  String get dockerPullReferenceHint;

  /// Pull sheet: the button that plans the pull and shows its preview.
  ///
  /// In en, this message translates to:
  /// **'Pull'**
  String get dockerPullStart;

  /// Pull sheet: the button that stops a running pull.
  ///
  /// In en, this message translates to:
  /// **'Stop pull'**
  String get dockerPullCancel;

  /// Pull sheet: while a pull runs, by route. An engine pull stops when the sheet closes; the host's docker pull ends with its connection (03 §7.14).
  ///
  /// In en, this message translates to:
  /// **'{route, select, engine{Pulling. Closing this sheet stops the pull.} host{Pulling on the server. Losing the connection stops the pull.} other{Starting the pull on the server.}}'**
  String dockerPullRunning(String route);

  /// Pull sheet: the choice of how to pull (IMG-03, REG-01).
  ///
  /// In en, this message translates to:
  /// **'{route, select, engine{Engine} host{Server\'s login} other{Detached}}'**
  String dockerPullRoute(String route);

  /// Pull sheet: under the route choice, what the chosen route does (03 §7.14, REG-01).
  ///
  /// In en, this message translates to:
  /// **'{route, select, engine{The engine pulls anonymously and shows each layer. Closing the sheet stops it.} host{The server\'s docker pull uses its own docker login, for private registries. The output shows at the end.} other{The server\'s docker pull runs on its own and keeps running when you leave. Follow it under Operations.}}'**
  String dockerPullRouteNote(String route);

  /// Pull sheet: a detached pull launched; its log follows it (03 §7.17).
  ///
  /// In en, this message translates to:
  /// **'The pull of {target} started on the server.'**
  String dockerPullDetached(String target);

  /// Pull sheet: one layer's status with the bytes done of its total.
  ///
  /// In en, this message translates to:
  /// **'{status}: {current} of {total}'**
  String dockerPullLayerBytes(String status, String current, String total);

  /// Images list: the button over the list that opens the menu of prunes (DKE-05, IMG-06).
  ///
  /// In en, this message translates to:
  /// **'Prune…'**
  String get dockerPrune;

  /// A prune's button or menu row, which opens its preview (DKE-05, IMG-06).
  ///
  /// In en, this message translates to:
  /// **'{kind, select, containers{Prune stopped containers…} images{Prune dangling images…} imagesAll{Prune all unused images…} volumes{Prune unused volumes…} networks{Prune unused networks…} buildCache{Prune the build cache…} other{Prune…}}'**
  String dockerPruneChoice(String kind);

  /// Volumes list: the button over the list that opens the create dialog (VOL-02).
  ///
  /// In en, this message translates to:
  /// **'Create volume…'**
  String get dockerVolumeCreate;

  /// Create volume dialog: its title.
  ///
  /// In en, this message translates to:
  /// **'Create a volume'**
  String get dockerVolumeCreateTitle;

  /// Create volume dialog: the button that goes on to the action preview.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get dockerVolumeCreateSubmit;

  /// Create volume dialog: the driver field's hint, Docker's default driver name, used when the field is left empty.
  ///
  /// In en, this message translates to:
  /// **'local'**
  String get dockerVolumeDriverHint;

  /// Create volume dialog: the name field is empty.
  ///
  /// In en, this message translates to:
  /// **'Enter a name.'**
  String get dockerVolumeNameRequired;

  /// Create volume dialog: a name Docker would refuse.
  ///
  /// In en, this message translates to:
  /// **'Use letters, digits, \'_\', \'.\' and \'-\', starting with a letter or digit, at least two characters.'**
  String get dockerVolumeNameInvalid;

  /// Volumes list: the row action that removes a volume and its data, behind a typed confirmation.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get dockerVolumeRemove;

  /// Networks list: the column of network scopes, such as local or swarm.
  ///
  /// In en, this message translates to:
  /// **'Scope'**
  String get dockerNetworksColumnScope;

  /// Networks list: the column of each network's first configured subnet.
  ///
  /// In en, this message translates to:
  /// **'Subnet'**
  String get dockerNetworksColumnSubnet;

  /// Networks list: the column of the gateway of each network's first configured subnet.
  ///
  /// In en, this message translates to:
  /// **'Gateway'**
  String get dockerNetworksColumnGateway;

  /// Networks list: a network with no subnet or gateway configured, such as host or none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get dockerNetworksNoSubnet;

  /// Networks list: the badge on the engine's own networks (bridge, host, none), which cannot be removed.
  ///
  /// In en, this message translates to:
  /// **'Built-in'**
  String get dockerNetworksBuiltin;

  /// Networks list: what a screen reader hears for a built-in network's name.
  ///
  /// In en, this message translates to:
  /// **'{name}, built-in'**
  String dockerNetworksBuiltinName(String name);

  /// Networks list: what a screen reader hears, and a phone row shows, for a network running containers are on.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 container on it} other{{count} containers on it}}'**
  String dockerNetworksInUse(int count);

  /// Networks list: the search field's hint.
  ///
  /// In en, this message translates to:
  /// **'Search by name, driver or subnet'**
  String get dockerNetworksSearchHint;

  /// Networks list: shown until the first list arrives.
  ///
  /// In en, this message translates to:
  /// **'Reading the networks…'**
  String get dockerNetworksReading;

  /// Networks list: the engine listed none.
  ///
  /// In en, this message translates to:
  /// **'This engine has no networks.'**
  String get dockerNetworksEmpty;

  /// Networks list: the search hides every network.
  ///
  /// In en, this message translates to:
  /// **'No network matches the search.'**
  String get dockerNetworksNoMatch;

  /// Networks list: the Unused filter hides every network; built-in networks never count as unused.
  ///
  /// In en, this message translates to:
  /// **'Every network you made has a container on it.'**
  String get dockerNetworksNoneUnused;

  /// Networks list: why the list could not be read. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} daemonError{The engine refused or failed to list the networks.} connectionFailed{The connection to the engine failed while listing the networks.} other{The networks could not be listed.}}'**
  String dockerNetworksFailed(String reason);

  /// Networks list: the network list names no containers, and the container list it is computed from failed.
  ///
  /// In en, this message translates to:
  /// **'Which networks are in use is unknown: the containers, which name their networks, could not be listed.'**
  String get dockerNetworksUseUnknown;

  /// Networks list: the row action that removes a network no container is on.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get dockerNetworkRemove;

  /// Tooltip of the button that closes a container's details in the desktop inspector (03 §10.2).
  ///
  /// In en, this message translates to:
  /// **'Close the container details'**
  String get dockerDetailsClose;

  /// Container details: the inspect read (CTR-03) has not answered yet.
  ///
  /// In en, this message translates to:
  /// **'Reading the container details…'**
  String get dockerDetailsReading;

  /// Container details: why the inspect read failed. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notInFleet{This server is no longer in the fleet.} linkUnavailable{There is no connection to this server.} profileUnknown{The server\'s capability check has not answered yet.} endpointUnavailable{The Docker engine cannot be reached.} tooManyQueries{This server already has as many Docker reads waiting as Klabautermann allows.} daemonError{The engine refused or failed to inspect the container.} connectionFailed{The connection to the engine failed while inspecting the container.} cancelled{The read stopped before it ran.} other{The container details could not be read.}}'**
  String dockerDetailsFailed(String reason);

  /// Container details: shown under a failure or a removal, above the details read before.
  ///
  /// In en, this message translates to:
  /// **'The details below are the last ones read.'**
  String get dockerDetailsKept;

  /// Container details: the container is gone from the engine (its inspect found nothing, or the list no longer has it).
  ///
  /// In en, this message translates to:
  /// **'This container was removed.'**
  String get dockerDetailsRemoved;

  /// Container details: the managed-by badge (DKE-10). manager is the product name of the tool that owns the container, such as Coolify or Portainer, never translated.
  ///
  /// In en, this message translates to:
  /// **'Managed by {manager}'**
  String dockerDetailsManagedBy(String manager);

  /// Container details: under the managed-by badge. manager is the owning tool's product name; label is the container label that marks the ownership, server data.
  ///
  /// In en, this message translates to:
  /// **'Changes made outside {manager} can be overwritten by it. The label {label} marks it.'**
  String dockerDetailsManagedByNote(String manager, String label);

  /// Container details: the heading of TRI-04's diagnosis, what the container's state says went wrong.
  ///
  /// In en, this message translates to:
  /// **'Diagnosis'**
  String get dockerDiagnosisTitle;

  /// Container details, Diagnosis: what went wrong, by ContainerDiagnosisKind name.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, oomLimit{Out of memory} oomHost{Out of memory on the host} killed{Killed} segfault{Crashed} notExecutable{Command not executable} commandNotFound{Command not found} runtimeError{The engine could not start it} exitedWithError{Exited with an error} exitsAtOnce{Exits right after starting} restartLoop{Restart loop} unhealthy{Health check failing} other{Something went wrong}}'**
  String dockerDiagnosisKind(String kind);

  /// Container details, Diagnosis: what the finding means and where to look, by ContainerDiagnosisKind name.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, oomLimit{The kernel stopped it, most likely for going over its memory limit. Raise the limit or find what keeps growing.} oomHost{The kernel stopped it while the host ran out of memory. It has no memory limit of its own.} killed{It ended with SIGKILL (exit code 137) without running out of memory: a docker kill, a stop that ran past its timeout, or another process.} segfault{It ended with a segmentation fault (exit code 139), a crash inside the program.} notExecutable{Exit code 126: the command exists but cannot run. Check its permissions and its interpreter line.} commandNotFound{Exit code 127: the entrypoint or command names a program the image does not have.} runtimeError{The engine reported this error for it:} exitedWithError{Its process ended with an error. Its last log lines usually say why.} exitsAtOnce{It exited with code 0 and its restart policy starts it again: its main process does not stay in the foreground.} restartLoop{Its restart policy has started it again after each exit since it was last started by hand. Its logs show what each run ended with.} unhealthy{Its health check keeps failing. Health checks shows what each check printed.} other{Its state says something went wrong.}}'**
  String dockerDiagnosisWhy(String kind);

  /// Container details, Diagnosis: the memory limit an out-of-memory container went over.
  ///
  /// In en, this message translates to:
  /// **'Memory limit: {limit}'**
  String dockerDiagnosisMemoryLimit(String limit);

  /// Container details, Diagnosis: the exit code of a container that exited with an error.
  ///
  /// In en, this message translates to:
  /// **'Exit code: {code}'**
  String dockerDiagnosisExitCode(int code);

  /// Container details, Diagnosis: how often the restart policy has started the container again.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Restarting now} =1{Restarted once} other{Restarted {count} times}}'**
  String dockerDiagnosisRestarts(int count);

  /// Container details: heading of the section with the container's state, health, restart policy, image and times.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get dockerDetailsOverview;

  /// Container details: label of the container's short ID.
  ///
  /// In en, this message translates to:
  /// **'ID'**
  String get dockerDetailsId;

  /// Container details: a stopped container's state with the exit code of its last run.
  ///
  /// In en, this message translates to:
  /// **'{state}, exit code {code}'**
  String dockerDetailsStateExited(String state, int code);

  /// Container details: the kernel's out-of-memory killer stopped the container's process.
  ///
  /// In en, this message translates to:
  /// **'Its last run was stopped for running out of memory.'**
  String get dockerDetailsOomKilled;

  /// Container details: the engine's State.Error is set; the engine's own text follows, untranslated.
  ///
  /// In en, this message translates to:
  /// **'The engine reported an error for this container.'**
  String get dockerDetailsStateError;

  /// Container details: how many health checks failed in a row (CTR-04).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 failed check in a row} other{{count} failed checks in a row}}'**
  String dockerDetailsHealthStreak(int count);

  /// Container details: label of the container's restart policy.
  ///
  /// In en, this message translates to:
  /// **'Restart policy'**
  String get dockerDetailsRestartPolicy;

  /// Container details: a restart policy in words. policy is the policy's name.
  ///
  /// In en, this message translates to:
  /// **'{policy, select, no{Never restart} always{Always restart} unlessStopped{Restart unless stopped} onFailure{Restart on failure} other{Unknown}}'**
  String dockerDetailsRestartPolicyName(String policy);

  /// Container details: the on-failure restart policy with its retry limit.
  ///
  /// In en, this message translates to:
  /// **'{policy}, at most {count, plural, =1{once} other{{count} times}}'**
  String dockerDetailsRestartPolicyRetries(String policy, int count);

  /// Container details: label of how many times the engine restarted the container.
  ///
  /// In en, this message translates to:
  /// **'Restarts'**
  String get dockerDetailsRestarts;

  /// Container details: label of the short ID of the image the container runs.
  ///
  /// In en, this message translates to:
  /// **'Image ID'**
  String get dockerDetailsImageId;

  /// Container details: label of when the container was created.
  ///
  /// In en, this message translates to:
  /// **'Created'**
  String get dockerDetailsCreated;

  /// Container details: label of when the container last started.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get dockerDetailsStarted;

  /// Container details: label of when the container's last run ended.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get dockerDetailsFinished;

  /// Container details: a date and time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String dockerDetailsTime(DateTime time);

  /// Container details: heading of the last health-check results (CTR-04).
  ///
  /// In en, this message translates to:
  /// **'Health checks'**
  String get dockerDetailsHealthTitle;

  /// Container details: the container has a health check but no results yet.
  ///
  /// In en, this message translates to:
  /// **'No health check has run yet.'**
  String get dockerDetailsHealthEmpty;

  /// Container details: one health-check result: its exit code and when it ended.
  ///
  /// In en, this message translates to:
  /// **'Exit code {code}, {time}'**
  String dockerDetailsHealthCheck(String code, DateTime time);

  /// Container details: one health-check result whose end time is unknown.
  ///
  /// In en, this message translates to:
  /// **'Exit code {code}'**
  String dockerDetailsHealthCheckUntimed(String code);

  /// Container details: a health check that printed nothing.
  ///
  /// In en, this message translates to:
  /// **'No output'**
  String get dockerDetailsHealthNoOutput;

  /// Container details: shown when some values are masked secrets (SAF-07): a reveal is temporary and stays on this device.
  ///
  /// In en, this message translates to:
  /// **'Select a masked value to show it for {seconds} seconds.'**
  String dockerDetailsRevealNote(int seconds);

  /// What a screen reader says in place of a masked secret in a container's details (SAF-07).
  ///
  /// In en, this message translates to:
  /// **'(masked)'**
  String get dockerDetailsMasked;

  /// Screen-reader hint of a masked value in a container's details, which shows it for a while when activated.
  ///
  /// In en, this message translates to:
  /// **'Show the masked value'**
  String get dockerDetailsRevealHint;

  /// Screen-reader hint of a revealed value in a container's details, which masks it again when activated.
  ///
  /// In en, this message translates to:
  /// **'Mask again'**
  String get dockerDetailsHideHint;

  /// Container details: what a screen reader says for one environment variable or label: its name, then its value or "(masked)".
  ///
  /// In en, this message translates to:
  /// **'{name}: {value}'**
  String dockerDetailsEntry(String name, String value);

  /// Container details: heading of the container's entrypoint and command (Docker's ENTRYPOINT and CMD).
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get dockerDetailsCommandTitle;

  /// Container details: label of the container's entrypoint (Docker's ENTRYPOINT).
  ///
  /// In en, this message translates to:
  /// **'Entrypoint'**
  String get dockerDetailsEntrypoint;

  /// Container details: label of the command the entrypoint is given (Docker's CMD).
  ///
  /// In en, this message translates to:
  /// **'Arguments'**
  String get dockerDetailsCmd;

  /// Container details: an entrypoint or argument list that is empty.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get dockerDetailsNone;

  /// Container details: heading of the container's environment variables.
  ///
  /// In en, this message translates to:
  /// **'Environment'**
  String get dockerDetailsEnvTitle;

  /// Container details: the container has no environment variables.
  ///
  /// In en, this message translates to:
  /// **'No environment variables.'**
  String get dockerDetailsEnvEmpty;

  /// Container details: heading of the container's labels.
  ///
  /// In en, this message translates to:
  /// **'Labels'**
  String get dockerDetailsLabelsTitle;

  /// Container details: the container has no labels.
  ///
  /// In en, this message translates to:
  /// **'No labels.'**
  String get dockerDetailsLabelsEmpty;

  /// Container details: heading of the container's mounts.
  ///
  /// In en, this message translates to:
  /// **'Mounts'**
  String get dockerDetailsMountsTitle;

  /// Container details: the container has no mounts.
  ///
  /// In en, this message translates to:
  /// **'No mounts.'**
  String get dockerDetailsMountsEmpty;

  /// Container details: a mount's type in words. type is the Engine API's mount type.
  ///
  /// In en, this message translates to:
  /// **'{type, select, bind{Bind mount} volume{Volume} tmpfs{Memory (tmpfs)} npipe{Named pipe} cluster{Cluster volume} image{Image} other{Mount}}'**
  String dockerDetailsMountKind(String type);

  /// Container details: a mount the container cannot write to, after the mount's type.
  ///
  /// In en, this message translates to:
  /// **'read-only'**
  String get dockerDetailsMountReadOnly;

  /// Container details: a mount the container can write to, after the mount's type.
  ///
  /// In en, this message translates to:
  /// **'read-write'**
  String get dockerDetailsMountReadWrite;

  /// Container details: a mount's type and whether it is writable.
  ///
  /// In en, this message translates to:
  /// **'{kind}, {access}'**
  String dockerDetailsMountSummary(String kind, String access);

  /// Container details: the container lists no ports.
  ///
  /// In en, this message translates to:
  /// **'No published or exposed ports.'**
  String get dockerDetailsPortsEmpty;

  /// Container details: heading of the networks the container is attached to.
  ///
  /// In en, this message translates to:
  /// **'Networks'**
  String get dockerDetailsNetworksTitle;

  /// Container details: label of the container's network mode, such as bridge or host, as the engine names it.
  ///
  /// In en, this message translates to:
  /// **'Network mode'**
  String get dockerDetailsNetworkMode;

  /// Container details: the container is attached to no network.
  ///
  /// In en, this message translates to:
  /// **'Not attached to a network.'**
  String get dockerDetailsNetworksEmpty;

  /// Container details: label of the container's address on one network.
  ///
  /// In en, this message translates to:
  /// **'IP address'**
  String get dockerDetailsIpAddress;

  /// Container details: label of a network's gateway address.
  ///
  /// In en, this message translates to:
  /// **'Gateway'**
  String get dockerDetailsGateway;

  /// Container details: label of the container's names on one network.
  ///
  /// In en, this message translates to:
  /// **'Aliases'**
  String get dockerDetailsAliases;

  /// Container details: title of the expandable inspect output in JSON (CTR-03).
  ///
  /// In en, this message translates to:
  /// **'Raw JSON'**
  String get dockerDetailsRawTitle;

  /// Container details: under the raw JSON's title; the JSON never shows a secret, even one revealed above (SAF-07).
  ///
  /// In en, this message translates to:
  /// **'Masked values stay masked here.'**
  String get dockerDetailsRawNote;

  /// Tooltip of the button on a container's details, and the container row's menu item, that opens the container's logs (CTX-01).
  ///
  /// In en, this message translates to:
  /// **'Show logs'**
  String get dockerLogsShow;

  /// Tooltip of the button on a container's details that opens the one-off command sheet (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Run a command'**
  String get dockerCommandOpen;

  /// Title of the one-off command sheet (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Run a command in {container}'**
  String dockerCommandTitle(String container);

  /// Label of the one-off command's field (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get dockerCommandLabel;

  /// Helper under the command field: the words run as typed, without a shell expanding them (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Runs without a shell or terminal. Quote words as in a shell; for pipes and variables, run sh -c \'…\'.'**
  String get dockerCommandHelper;

  /// Error under the command field when it is empty, a quote is left open or it ends with a backslash (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Enter a complete command: close any open quote and remove a trailing backslash.'**
  String get dockerCommandUnparsed;

  /// Button that plans the one-off command, shows its preview and runs it once confirmed (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get dockerCommandRun;

  /// Status of the one-off command sheet while the command runs (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Running…'**
  String get dockerCommandRunning;

  /// Label over the command's standard output (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get dockerCommandStdout;

  /// Label over the command's standard error (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'Errors'**
  String get dockerCommandStderr;

  /// Shown when the finished command wrote nothing to stdout or stderr (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'The command printed nothing.'**
  String get dockerCommandNoOutput;

  /// Shown when the command's output exceeded the kept maximum (CTX-08).
  ///
  /// In en, this message translates to:
  /// **'The output was longer than 1 MiB; the rest was dropped.'**
  String get dockerCommandTruncated;

  /// Tooltip of the button on a container's details that opens a shell in the container (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Open a shell'**
  String get dockerShellOpen;

  /// Tooltip of the inspector button that swaps a container shell back for the container's details, closing the shell (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Show details'**
  String get dockerShellHide;

  /// Tooltip of the desktop workspace's button that opens the bottom dock, with the server's logs when it holds nothing of the server yet (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Show the dock'**
  String get dockShow;

  /// Tooltip of the button that collapses the desktop workspace's bottom dock to its tabs (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Hide the dock'**
  String get dockHide;

  /// Screen-reader label of the bottom dock's top edge, which a drag or the arrow keys resize (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Dock height. Use the up and down arrow keys to resize it.'**
  String get dockResize;

  /// Bottom dock: the tab of the server's journal, followed as the Logs tab reads it (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get dockLogs;

  /// Bottom dock: the tab of a run's output, named for the unit, cron line or snippet that ran (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Output: {name}'**
  String dockRunOutput(String name);

  /// Bottom dock: the tab of a shell in a container (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Shell: {container}'**
  String dockShell(String container);

  /// Tooltip of the button on a bottom dock tab that closes it, ending its follow or shell (OV-10).
  ///
  /// In en, this message translates to:
  /// **'Close {name}'**
  String dockClose(String name);

  /// Title of the page that shows a shell in a container (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Shell in {container}'**
  String dockerShellTitle(String container);

  /// Label of the field that picks the shell program to run in a container (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Shell'**
  String get dockerShellShellLabel;

  /// Hint and menu item of the shell field when no shell is chosen: the engine runs /bin/bash where the container has it, otherwise /bin/sh (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Automatic: /bin/bash, then /bin/sh'**
  String get dockerShellShellAuto;

  /// Label of the field naming the user a container shell runs as (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get dockerShellUserLabel;

  /// Hint of the empty user field: the shell runs as the container's configured user (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'The container\'s user'**
  String get dockerShellUserHint;

  /// Button that opens the shell in the container with the chosen shell and user (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Open shell'**
  String get dockerShellStart;

  /// Status above a container shell while the engine starts it (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Opening the shell…'**
  String get dockerShellOpening;

  /// Status above a running container shell, naming the command the exec runs (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Running {command}'**
  String dockerShellRunning(String command);

  /// Status above a container shell that ended or never started, by the engine's reason (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'{reason, select, exited{The shell exited.} closed{The shell was closed.} observeOnly{Management is off for this server, so no shell opens.} readOnly{Read-only mode is on, so no shell opens.} notInFleet{This server is no longer in the fleet.} endpointUnavailable{The server\'s Docker endpoint could not be reached.} noChannel{No session channel was free on the server. Close another view or shell and try again.} tooMany{This server already has the most shells open. Close one first.} refused{The container is gone, or Docker refused the shell.} linkLost{The connection to the server was lost.} adminEnded{Admin mode ended, and the shell with it.} failed{The shell failed.} other{The engine stopped, and the shell with it.}}'**
  String dockerShellEnded(String reason);

  /// Follows the ended status when the shell reported its exit code (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Exit code {code}.'**
  String dockerShellExitCode(int code);

  /// Button that opens the container shell again with the same shell and user after it ended (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Open again'**
  String get dockerShellReopen;

  /// Button that goes back to the shell and user fields after a container shell ended (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Change shell'**
  String get dockerShellChange;

  /// Tooltip of the button that ends a running container shell (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Close the shell'**
  String get dockerShellClose;

  /// Context menu item that copies the selected terminal text (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get dockerShellCopy;

  /// Button tooltip and context menu item that pastes the clipboard into a container shell, checked first when it has several lines (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get dockerShellPaste;

  /// Title of the dialog that asks before pasting several lines into a container shell (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, one{Paste 1 line?} other{Paste {count} lines?}}'**
  String dockerShellPasteTitle(int count);

  /// Body of the paste dialog when the danger linter flagged lines (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Some of these lines look dangerous. Each line runs as you paste it.'**
  String get dockerShellPasteFindings;

  /// Body of the paste dialog when the danger check failed: unknown, not clean (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'These lines could not be checked. Each line runs as you paste it.'**
  String get dockerShellPasteUnchecked;

  /// One danger finding in the paste dialog: the pasted line it is on and the linter's explanation (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Line {line}: {explanation}'**
  String dockerShellPasteFinding(int line, String explanation);

  /// Paste dialog button that pastes every line (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Paste all'**
  String get dockerShellPasteAll;

  /// Paste dialog button that pastes the first line without its line break (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'First line only'**
  String get dockerShellPasteFirstLine;

  /// Paste dialog button that pastes nothing (CTX-07).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dockerShellPasteCancel;

  /// Under a container's name above its logs, in the Docker tab's log pane on desktops and in the bottom sheet on phones.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get dockerLogsTitle;

  /// Tooltip of the button that closes a container's logs.
  ///
  /// In en, this message translates to:
  /// **'Close logs'**
  String get dockerLogsClose;

  /// Shown in place of a container's logs when reading them ended without a line.
  ///
  /// In en, this message translates to:
  /// **'This container has no log lines.'**
  String get dockerLogsEmpty;

  /// Container logs time range menu: opens a dialog to pick the range's start and end date and time.
  ///
  /// In en, this message translates to:
  /// **'Choose start and end…'**
  String get dockerLogsRangeChoose;

  /// Container logs time range button when a start and end were chosen.
  ///
  /// In en, this message translates to:
  /// **'{since} to {until}'**
  String dockerLogsRangeBetween(String since, String until);

  /// Title of the dialog that picks a container log time range's start and end.
  ///
  /// In en, this message translates to:
  /// **'Time range'**
  String get dockerLogsRangeTitle;

  /// Container log time range dialog: the range's start, a date and time.
  ///
  /// In en, this message translates to:
  /// **'From'**
  String get dockerLogsRangeFrom;

  /// Container log time range dialog: the range's end, a date and time.
  ///
  /// In en, this message translates to:
  /// **'To'**
  String get dockerLogsRangeTo;

  /// Container log time range dialog: why Apply is off.
  ///
  /// In en, this message translates to:
  /// **'The start must come before the end.'**
  String get dockerLogsRangeOrder;

  /// Closes the container log time range dialog without changing the range.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dockerLogsRangeCancel;

  /// Reads the container's logs in the chosen time range.
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get dockerLogsRangeApply;

  /// The suggested file name for a container's saved log export: the container's name. Keep it a valid file name.
  ///
  /// In en, this message translates to:
  /// **'{container}.log'**
  String dockerLogsExportFileName(String container);

  /// Stack overview: opens the logs of all the stack's containers, merged by time.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get dockerStackLogsOpen;

  /// Title of a stack's merged logs page.
  ///
  /// In en, this message translates to:
  /// **'{project} logs'**
  String dockerStackLogsTitle(String project);

  /// Stack logs page: the stack has no containers to read.
  ///
  /// In en, this message translates to:
  /// **'This stack has no containers, so it has no logs.'**
  String get dockerStackLogsNone;

  /// Stack logs page: only the first containers' logs are read.
  ///
  /// In en, this message translates to:
  /// **'{shown} containers\' logs are read at once, as each holds a connection to the server. {omitted, plural, =1{1 more is not shown.} other{{omitted} more are not shown.}}'**
  String dockerStackLogsOmitted(int shown, int omitted);

  /// Stack logs page: a container's filter chip while its log stream is not running.
  ///
  /// In en, this message translates to:
  /// **'{container}: {state, select, waiting{waiting} ended{stopped reading} refused{refused} other{opening}}'**
  String dockerStackLogsState(String container, String state);

  /// Tooltip of the off Live chip while a container's logs read a range with a chosen end.
  ///
  /// In en, this message translates to:
  /// **'A range with an end has no new lines to follow.'**
  String get dockerLogsLiveRange;

  /// Shown in place of a container's logs when its logging driver keeps no logs the engine can read back (CTX-01): the none driver; on Podman, a driver other than json-file, k8s-file and journald; on Docker, a remote driver with Docker's dual-logging cache disabled; or a driver the engine could not name. driver is the driver's name as Docker reports it, such as splunk; driver and cache names stay as they are.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, none{This container keeps no logs: driver none.} podman{Podman cannot read this container\'s logs: driver {driver}. Podman reads only the json-file, k8s-file and journald drivers.} cacheDisabled{Docker cannot read this container\'s logs: driver {driver}, cache disabled. Docker reads another driver\'s logs only through its local cache.} other{Docker cannot read this container\'s logs: its logging driver keeps none it can read.}}'**
  String dockerLogsDriverUnreadable(String reason, String driver);

  /// Stacks list: shown until the first list arrives.
  ///
  /// In en, this message translates to:
  /// **'Reading the stacks…'**
  String get dockerStacksReading;

  /// Stacks list: why the list could not be read. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, tooManyQueries{This server already has as many Docker watches open as Klabautermann allows.} daemonError{The engine refused or failed to list the containers the stacks are read from.} connectionFailed{The connection to the engine failed while listing the stacks.} other{The stacks could not be listed.}}'**
  String dockerStacksFailed(String reason);

  /// Stacks list: under a failed read, the list it keeps is older.
  ///
  /// In en, this message translates to:
  /// **'The list below is the last one read.'**
  String get dockerStacksKept;

  /// Stacks list: the engine has no container that docker compose created (STK-01).
  ///
  /// In en, this message translates to:
  /// **'This engine runs no compose stacks.'**
  String get dockerStacksEmpty;

  /// Stacks list: the server's link has a session limit (03 §5.2) on a relay route, where the list polls.
  ///
  /// In en, this message translates to:
  /// **'Low-session mode: the stacks are read again every 15 seconds instead of following engine events.'**
  String get dockerStacksLowSessionRelay;

  /// Stacks list: the label before the compose command-line tools found on the host (STK-05).
  ///
  /// In en, this message translates to:
  /// **'Compose CLI'**
  String get dockerStacksCliLabel;

  /// Stacks list: the compose plugin found on the host and its version (STK-05). The product name stays as it is.
  ///
  /// In en, this message translates to:
  /// **'Docker Compose {version}'**
  String dockerStacksCliPlugin(String version);

  /// Stacks list: the standalone docker-compose binary found on the host and its version (STK-05), which Klabautermann only reads with. legacy is true for the Python Compose v1, unmaintained since 2023. The command name stays as it is.
  ///
  /// In en, this message translates to:
  /// **'{legacy, select, true{docker-compose {version} (Compose v1, unmaintained): read-only} other{docker-compose {version} (standalone): read-only}}'**
  String dockerStacksCliStandalone(String legacy, String version);

  /// Stacks list: after the Compose CLI label, the host has neither the compose plugin nor docker-compose (STK-05).
  ///
  /// In en, this message translates to:
  /// **'None found, so no stack\'s source can be verified.'**
  String get dockerStacksCliNone;

  /// Stacks: the chip saying whether a stack's compose files on the host are its source (STK-01). verdict is verifying, waiting (the check waits for a free SSH session channel on a server whose session limit the samplers fill), verified, notOnHost or unverified.
  ///
  /// In en, this message translates to:
  /// **'{verdict, select, verifying{Checking source…} waiting{Waiting for a channel} verified{Verified source} notOnHost{Source not on host} other{Unverified source}}'**
  String dockerStackVerdict(String verdict);

  /// Stacks: the chip of a stack whose compose files are missing from the host, deployed by a manager that runs compose in its own container (STK-01, Dockge's rule). manager is the product name, never translated.
  ///
  /// In en, this message translates to:
  /// **'Source not on host (deployed by {manager})'**
  String dockerStackNotOnHostDeployedBy(String manager);

  /// Stacks: the chip of a stack whose files are not its verified source, with why (STK-01). reason is the engine's reason name. docker-compose and compose config stay as they are.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noSourceLabels{Unverified source: no compose files recorded} unsafeLabels{Unverified source: unsafe names in the labels} noHashLabels{Unverified source: a service has no config hash} noComposeCli{Unverified source: no compose CLI} standaloneComposeOnly{Unverified source: standalone docker-compose only} cliCouldNotHash{Unverified source: the compose CLI cannot hash} configFailed{Unverified source: compose config failed} hashMismatch{Unverified source: the files changed since the deploy} checkFailed{Unverified source: the check could not run} other{Unverified source}}'**
  String dockerStackUnverified(String reason);

  /// Stack overview: under the verdict chip, what it means (STK-01). verdict is verifying, verified, notOnHost or unverified.
  ///
  /// In en, this message translates to:
  /// **'{verdict, select, verifying{Klabautermann is checking the compose files on the host against the running containers.} verified{The compose files on the host are the ones these containers were deployed from.} notOnHost{A compose file the containers name is not on the host. A manager that runs compose in its own container records paths inside that container.} other{The compose files on the host could not be matched to the ones these containers were deployed from, so they are not treated as the stack\'s source.}}'**
  String dockerStackVerdictNote(String verdict);

  /// Stacks: the badge of a stack another tool owns (STK-10, DKE-10). manager is the product name, such as Coolify, never translated.
  ///
  /// In en, this message translates to:
  /// **'Managed by {manager}: read-only'**
  String dockerStackManagedBy(String manager);

  /// Stack overview: under the managed-by badge. manager is the owning tool's product name; label is the container label that marks the ownership, server data.
  ///
  /// In en, this message translates to:
  /// **'Changes made outside {manager} can be overwritten by it, so Klabautermann treats this stack as read-only. The label {label} marks it.'**
  String dockerStackManagedByNote(String manager, String label);

  /// Stacks: how many compose services a stack has (STK-02).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 service} other{{count} services}}'**
  String dockerStackServices(int count);

  /// Stacks: how many of a stack's containers run, paused and restarting ones included, as docker ps lists them.
  ///
  /// In en, this message translates to:
  /// **'{up} of {total} running'**
  String dockerStackRunning(int up, int total);

  /// Stacks: how many of a stack's containers report an unhealthy health check, beside an error icon.
  ///
  /// In en, this message translates to:
  /// **'{count} unhealthy'**
  String dockerStackUnhealthy(int count);

  /// Screen-reader hint of a stack's row on a phone, which opens its overview on a page of its own.
  ///
  /// In en, this message translates to:
  /// **'Show the stack\'s overview'**
  String get dockerStackOpenHint;

  /// Stack overview: the heading over where the stack's compose files are, as its labels record them.
  ///
  /// In en, this message translates to:
  /// **'Source'**
  String get dockerStackSource;

  /// Stack overview: the directory docker compose ran in, as the stack's labels record it.
  ///
  /// In en, this message translates to:
  /// **'Working directory'**
  String get dockerStackWorkingDir;

  /// Stack overview: the compose files the stack was deployed from, as its labels record them.
  ///
  /// In en, this message translates to:
  /// **'Compose files'**
  String get dockerStackConfigFiles;

  /// Stack overview: the environment files the stack was deployed with, as its labels record them.
  ///
  /// In en, this message translates to:
  /// **'Environment files'**
  String get dockerStackEnvFiles;

  /// Stack overview: the label over the compose version the containers were created with.
  ///
  /// In en, this message translates to:
  /// **'Deployed with Compose'**
  String get dockerStackComposeVersion;

  /// Stack overview: the stack's labels record no such file or directory.
  ///
  /// In en, this message translates to:
  /// **'None recorded'**
  String get dockerStackNoneRecorded;

  /// Stack overview: the heading over the stack's services and their containers (STK-02).
  ///
  /// In en, this message translates to:
  /// **'Services'**
  String get dockerStackServicesHeading;

  /// Stack overview: beside a service whose containers docker compose run created, which start and stop skip (STK-03).
  ///
  /// In en, this message translates to:
  /// **'one-off'**
  String get dockerStackOneOff;

  /// Stack overview: a container's published ports, as docker ps lists them; ports is server data.
  ///
  /// In en, this message translates to:
  /// **'Ports {ports}'**
  String dockerStackPorts(String ports);

  /// Screen-reader hint of a container in a stack's overview, which opens its details.
  ///
  /// In en, this message translates to:
  /// **'Show the container\'s details'**
  String get dockerStackOpenContainerHint;

  /// Stack overview: the stack left the list, as its last container was removed.
  ///
  /// In en, this message translates to:
  /// **'This stack has no containers any more.'**
  String get dockerStackGone;

  /// Stack overview: opens the verified stack's compose and environment files, read-only (STK-04).
  ///
  /// In en, this message translates to:
  /// **'View files'**
  String get dockerStackFilesView;

  /// Stack overview: in place of the files button, for a stack whose source is not verified (STK-04: verified sources only).
  ///
  /// In en, this message translates to:
  /// **'Its files show only once its source is verified.'**
  String get dockerStackFilesUnverified;

  /// The stack file view's title. project is the compose project's name, server data.
  ///
  /// In en, this message translates to:
  /// **'{project}: files'**
  String dockerStackFileTitle(String project);

  /// Tooltip of the button that closes the stack file view on the desktop.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get dockerStackFileClose;

  /// Stack file view: shown while the file is read. file is the file's name, such as compose.yaml.
  ///
  /// In en, this message translates to:
  /// **'Reading {file}…'**
  String dockerStackFileReading(String file);

  /// Stack file view: what a screen reader hears for the file's text, which cannot be edited. file is the file's name.
  ///
  /// In en, this message translates to:
  /// **'{file}, read-only'**
  String dockerStackFileEditorLabel(String file);

  /// Stack file view: secrets in the file show as asterisks (SAF-07); a reveal is temporary and stays on this device.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 value is masked. Reveal values shows it for {seconds} seconds.} other{{count} values are masked. Reveal values shows them for {seconds} seconds.}}'**
  String dockerStackFileMasked(int count, int seconds);

  /// Stack file view: shows the masked values for a while.
  ///
  /// In en, this message translates to:
  /// **'Reveal values'**
  String get dockerStackFileReveal;

  /// Stack file view: masks the revealed values again before their time is up.
  ///
  /// In en, this message translates to:
  /// **'Hide values'**
  String get dockerStackFileHide;

  /// Stack file view: the file is larger than Klabautermann reads (M11). size and limit are sizes in IEC units.
  ///
  /// In en, this message translates to:
  /// **'This file is {size}, so only its complete lines within the first {limit} show.'**
  String dockerStackFileTruncated(String size, String limit);

  /// Stack file view: why the engine read no file (STK-04). reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, unknownStack{No container belongs to this stack any more.} notVerified{This stack\'s source is no longer verified, so its files do not show.} notStackFile{This path is none of the stack\'s files.} notFound{There is no file at this path on the host.} permissionDenied{Your account cannot read this file. Admin mode reads it through sudo.} notRegularFile{This path is a link, a directory or another special file, which is not read.} readFailed{The file could not be read, or it changed while it was read.} other{The file could not be read.}}'**
  String dockerStackFileFailed(String reason);

  /// Stack file view: why the read could not run. reason is the engine's failure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, notInFleet{This server is no longer in the fleet.} linkUnavailable{There is no connection to this server.} profileUnknown{The server\'s capability check has not answered yet.} endpointUnavailable{The Docker engine cannot be reached.} tooManyQueries{This server already has as many Docker reads waiting as Klabautermann allows.} daemonError{The engine refused or failed to list the stack\'s containers.} connectionFailed{The connection to the engine failed while reading the file.} cancelled{The read stopped before it ran.} other{The file could not be read.}}'**
  String dockerStackFileQueryFailed(String reason);

  /// Remote editor: closes the editor dialog; asks first when changes are not saved.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get editClose;

  /// Remote editor: the title for a file (SAF-12). name is the file name.
  ///
  /// In en, this message translates to:
  /// **'Edit {name}'**
  String editTitleFile(String name);

  /// Remote editor: the title for the login user's crontab (JOB-04).
  ///
  /// In en, this message translates to:
  /// **'Edit your crontab'**
  String get editTitleOwnCrontab;

  /// Remote editor: the title for another account's crontab (JOB-06). user is the account name.
  ///
  /// In en, this message translates to:
  /// **'Edit {user}\'s crontab'**
  String editTitleCrontab(String user);

  /// Remote editor: reads the file again after a failed read.
  ///
  /// In en, this message translates to:
  /// **'Read again'**
  String get editRetry;

  /// Remote editor: shown while the engine reads the file.
  ///
  /// In en, this message translates to:
  /// **'Reading the file…'**
  String get editReading;

  /// Remote editor: why the engine read nothing. reason is the engine's EditReadFailure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{There is no connection to this server.} invalidTarget{Klabautermann does not edit this path.} notFound{There is no file at this path on the host.} adminRequired{Only root can read this file. Turn on admin mode to edit it.} tooLarge{This file is too large for the editor.} notText{This file is not text.} stackUnverified{This stack\'s files are not its verified source, so Klabautermann does not edit them.} failed{The file could not be read.} other{The file could not be read.}}'**
  String editReadFailed(String reason);

  /// Remote editor: chip on a file only root may write; saving it runs through admin mode.
  ///
  /// In en, this message translates to:
  /// **'Root\'s file'**
  String get editRootFile;

  /// Remote editor: shown while the text differs from the server's.
  ///
  /// In en, this message translates to:
  /// **'Not saved'**
  String get editUnsaved;

  /// Remote editor: accessibility label of the editor. path is the file being edited.
  ///
  /// In en, this message translates to:
  /// **'Editor for {path}'**
  String editEditorLabel(String path);

  /// Remote editor: drops the changes for the server's text.
  ///
  /// In en, this message translates to:
  /// **'Discard changes'**
  String get editDiscard;

  /// Remote editor: shows the diff and the format checks before saving.
  ///
  /// In en, this message translates to:
  /// **'Review changes'**
  String get editReview;

  /// Remote editor: title of the confirmation before changes are dropped.
  ///
  /// In en, this message translates to:
  /// **'Discard your changes?'**
  String get editDiscardTitle;

  /// Remote editor: body of the confirmation before changes are dropped.
  ///
  /// In en, this message translates to:
  /// **'Your changes are not saved to the server and will be lost.'**
  String get editDiscardBody;

  /// Remote editor: closes a dialog and returns to the editor.
  ///
  /// In en, this message translates to:
  /// **'Keep editing'**
  String get editKeepEditing;

  /// Remote editor: title of the conflict sheet, when the file changed since it was read.
  ///
  /// In en, this message translates to:
  /// **'The file changed on the server'**
  String get editConflictTitle;

  /// Remote editor: body of the conflict sheet.
  ///
  /// In en, this message translates to:
  /// **'It changed since you opened it, so your save did not run. Your changes are still here.'**
  String get editConflictBody;

  /// Remote editor: conflict sheet; replaces the user's text with the server's.
  ///
  /// In en, this message translates to:
  /// **'Discard mine'**
  String get editConflictDiscard;

  /// Remote editor: conflict sheet; reads the server's text and reviews the user's text against it.
  ///
  /// In en, this message translates to:
  /// **'Reload and compare'**
  String get editConflictCompare;

  /// Remote editor review: one format problem. line is 1-based; kind is the TextProblemKind name; subject is the key, tag or parser detail, or empty.
  ///
  /// In en, this message translates to:
  /// **'{line, plural, other{Line {line}}}: {kind, select, syntaxError{does not parse} duplicateKey{key set again} duplicateTable{table declared again} duplicateAttribute{attribute given twice} jsonComment{comment in JSON} jsonTrailingComma{trailing comma in JSON} unterminatedQuote{quote never closed} tabIndentation{tab indentation} mismatchedClosingTag{closing tag does not match} unclosedElement{element never closed} unexpectedClosingTag{closing tag without an open element} mergeConflict{merge conflict marker} other{problem}} {subject}'**
  String editProblem(int line, String kind, String subject);

  /// Remote editor review: plans the save, whose preview shows every step before it runs.
  ///
  /// In en, this message translates to:
  /// **'Save to server'**
  String get editSave;

  /// Remote editor review: saves although the format checks found problems.
  ///
  /// In en, this message translates to:
  /// **'Save anyway'**
  String get editSaveAnyway;

  /// Remote editor review: shown while the diff is computed.
  ///
  /// In en, this message translates to:
  /// **'Comparing…'**
  String get editDiffing;

  /// Remote editor review: why no diff shows. status is the UnifiedDiffStatus name.
  ///
  /// In en, this message translates to:
  /// **'{status, select, identical{Your text is the same as the server\'s.} tooLarge{The change is too large to show as a diff.} timedOut{The comparison took too long to show.} failed{The comparison failed.} other{The change cannot be shown.}}'**
  String editDiffStatus(String status);

  /// Remote editor review: accessibility label of the diff.
  ///
  /// In en, this message translates to:
  /// **'Changes to the file'**
  String get editDiffLabel;

  /// Tooltip of a compose service's action menu on the stack overview (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Actions for {service}'**
  String dockerStackServiceActions(String service);

  /// Service menu item that pulls the service's image (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Pull image'**
  String get dockerStackServicePull;

  /// Service menu item that recreates the service's containers even when unchanged (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Recreate'**
  String get dockerStackServiceRecreate;

  /// Service menu item, and the scale dialog's confirm button, that sets the service's container count (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Scale'**
  String get dockerStackServiceScale;

  /// Title of the dialog that asks how many containers a service runs (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Scale {service}'**
  String dockerStackScaleTitle(String service);

  /// Label of the scale dialog's container count field (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Containers'**
  String get dockerStackScaleLabel;

  /// Error under the scale dialog's field when it is not a whole number in range (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Enter a number from 0 to {max}.'**
  String dockerStackScaleRange(int max);

  /// Scale dialog button that scales nothing (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dockerStackScaleCancel;

  /// Stack overview button that takes the whole stack down, its containers and networks but never its volumes; the preview asks for the typed confirmation (STK-23).
  ///
  /// In en, this message translates to:
  /// **'Down'**
  String get dockerStackDown;

  /// Label over the profiles a verified stack's compose files name (STK-09).
  ///
  /// In en, this message translates to:
  /// **'Profiles'**
  String get dockerStackProfiles;

  /// Shown under Profiles while the engine lists them (STK-09).
  ///
  /// In en, this message translates to:
  /// **'Reading…'**
  String get dockerStackProfilesReading;

  /// Shown under Profiles when compose could not list them (STK-09).
  ///
  /// In en, this message translates to:
  /// **'The profiles could not be listed.'**
  String get dockerStackProfilesFailed;

  /// Heading of the section listing compose files found in the chosen folders that no running or stopped stack accounts for (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Stacks without containers'**
  String get dockerStacksUnlisted;

  /// Shown when no scan folders are chosen for this server (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Name the folders your stacks live in, such as /opt/stacks, to find stacks that have no containers.'**
  String get dockerStackFoldersNone;

  /// The scan folders chosen for this server (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Folders: {folders}'**
  String dockerStackFoldersList(String folders);

  /// Button that opens the dialog naming the folders to scan for stacks (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Choose folders'**
  String get dockerStackFoldersChoose;

  /// Button that scans the chosen folders again (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Scan again'**
  String get dockerStackFoldersScanAgain;

  /// Shown while the folders are scanned (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Scanning the folders…'**
  String get dockerStackFoldersScanning;

  /// Shown when the scan could not run (STK-08).
  ///
  /// In en, this message translates to:
  /// **'The folders could not be scanned.'**
  String get dockerStackFoldersScanFailed;

  /// Shown when the scan found no compose file that a listed stack does not account for (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Every stack in these folders has containers.'**
  String get dockerStackFoldersNoneFound;

  /// Shown under the scan's results when a folder could not be read (STK-08).
  ///
  /// In en, this message translates to:
  /// **'A folder could not be read, so some stacks may be missing.'**
  String get dockerStackFoldersIncomplete;

  /// Title of the dialog naming the folders to scan for stacks on this server (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Stack folders'**
  String get dockerStackFoldersTitle;

  /// Helper under the stack folders field (STK-08).
  ///
  /// In en, this message translates to:
  /// **'One absolute path per line, at most {max}. The folders and the folders right below them are searched for compose files. Kept on this device.'**
  String dockerStackFoldersHelper(int max);

  /// Error under the stack folders field (STK-08).
  ///
  /// In en, this message translates to:
  /// **'{problem, select, notAbsolute{Each folder must be an absolute path, such as /opt/stacks.} tooMany{Name at most {max} folders.} other{These folders cannot be scanned.}}'**
  String dockerStackFoldersProblem(String problem, int max);

  /// Stack folders dialog button that keeps the folders as they were (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get dockerStackFoldersCancel;

  /// Stack folders dialog button that keeps the folders on this device and scans them (STK-08).
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get dockerStackFoldersSave;

  /// Toast when settings.json could not be written; the folders hold in memory (STK-08).
  ///
  /// In en, this message translates to:
  /// **'The folders could not be saved on this device. They apply until the app quits.'**
  String get dockerStackFoldersNotSaved;

  /// Stack file view: opens the file shown in the editor (STK-07).
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get dockerStackFileEdit;

  /// Jobs tab: opens the login user's crontab in the editor (JOB-04).
  ///
  /// In en, this message translates to:
  /// **'Edit your crontab'**
  String get jobsEditOwnCrontab;

  /// Remote editor review: the diff's label for the server's text. path is the file.
  ///
  /// In en, this message translates to:
  /// **'{path} (server)'**
  String editDiffServerLabel(String path);

  /// Remote editor review: the diff's label for the user's text. path is the file.
  ///
  /// In en, this message translates to:
  /// **'{path} (yours)'**
  String editDiffYourLabel(String path);

  /// Server Safety menu: opens what Klabautermann keeps on the server (SAF-14).
  ///
  /// In en, this message translates to:
  /// **'Footprint'**
  String get footprintMenu;

  /// Server Safety menu: reads each collector once and offers the raw output for a bug report (CN-18).
  ///
  /// In en, this message translates to:
  /// **'Diagnostic bundle…'**
  String get diagnosticsMenu;

  /// Diagnostic bundle sheet: shown while the server's collectors are read.
  ///
  /// In en, this message translates to:
  /// **'Reading each collector once…'**
  String get diagnosticsReading;

  /// Diagnostic bundle sheet: its title, with the server's name and how many collector sections the bundle holds.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic bundle for {server}: {count, plural, =1{1 section} other{{count} sections}}'**
  String diagnosticsTitle(String server, int count);

  /// Diagnostic bundle sheet: what the bundle holds and why to check it before sharing.
  ///
  /// In en, this message translates to:
  /// **'The raw output of each collector, for a parser bug report. It names this server\'s processes, units, mounts and paths, so read it before you share it.'**
  String get diagnosticsHint;

  /// Diagnostic bundle sheet: the collectors whose sampler did not answer in time, by their wire names, which are not translated.
  ///
  /// In en, this message translates to:
  /// **'No answer from: {collectors}'**
  String diagnosticsMissing(String collectors);

  /// Diagnostic bundle sheet: why no bundle was read.
  ///
  /// In en, this message translates to:
  /// **'{failure, select, noLink{Klabautermann is not reading this server right now, so its collectors cannot be read. Open the server while it is connected and try again.} other{The collectors could not be read.}}'**
  String diagnosticsFailed(String failure);

  /// The suggested file name for a saved diagnostic bundle. Keep it a valid file name.
  ///
  /// In en, this message translates to:
  /// **'diagnostics.txt'**
  String get diagnosticsFileName;

  /// Footprint page title. server is the server's name.
  ///
  /// In en, this message translates to:
  /// **'Footprint on {server}'**
  String footprintTitle(String server);

  /// Footprint page: asks the engine to verify the footprint again.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get footprintVerify;

  /// Footprint page: shown until the engine answers.
  ///
  /// In en, this message translates to:
  /// **'Checking what Klabautermann keeps on this server…'**
  String get footprintChecking;

  /// Footprint page: the engine refused the check, as for a server with no connection.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann cannot check what it keeps on this server without a connection. Connect, then check again.'**
  String get footprintUnavailable;

  /// Footprint page: root's part is not read without admin mode.
  ///
  /// In en, this message translates to:
  /// **'Root\'s backups and manifest are checked in admin mode.'**
  String get footprintRootUnchecked;

  /// Footprint page: one problem the check found, in the engine's words.
  ///
  /// In en, this message translates to:
  /// **'The check reported: {warning}'**
  String footprintWarning(String warning);

  /// Footprint page: no manifest rows and no backups.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann keeps nothing on this server.'**
  String get footprintNone;

  /// Footprint page: a scope's heading. scope is the FootprintScope name.
  ///
  /// In en, this message translates to:
  /// **'{scope, select, user{Your account} root{Root} other{Other}}'**
  String footprintScope(String scope);

  /// Footprint page: a manifest row's kind and whether it is on the host. kind is the FootprintKind name; present is true or false.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, backupDirectory{Backup directory} backupIndex{Backup index} other{File}} · {present, select, true{present} other{missing on the host}}'**
  String footprintFile(String kind, String present);

  /// Footprint page: removes older backups (Q11, tier 1).
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Keep only the newest backup of each file} other{Keep the newest {count} backups of each file}}'**
  String footprintKeepLast(int count);

  /// Footprint page: removes every backup of one file (Q11, typed confirmation).
  ///
  /// In en, this message translates to:
  /// **'Remove all backups'**
  String get footprintRemoveAll;

  /// Footprint page: the heading of a crontab's backups. user is the account.
  ///
  /// In en, this message translates to:
  /// **'{user}\'s crontab'**
  String footprintCrontabSource(String user);

  /// Footprint page: a backup's short hash and whether it still has the recorded content. status is the FootprintBackupStatus name.
  ///
  /// In en, this message translates to:
  /// **'{hash} · {status, select, intact{unchanged} modified{changed on the host since it was recorded} missing{missing on the host} other{unknown}}'**
  String footprintBackup(String hash, String status);

  /// Footprint page: opens the file's editor with this backup as the new text, to review and save.
  ///
  /// In en, this message translates to:
  /// **'Restore…'**
  String get footprintRestore;

  /// Footprint page: the backup read back does not have its recorded hash.
  ///
  /// In en, this message translates to:
  /// **'The backup changed since it was checked, so it was not opened.'**
  String get footprintRestoreChanged;

  /// Unit action (SVC-05): starts the unit at boot.
  ///
  /// In en, this message translates to:
  /// **'Enable'**
  String get unitEnable;

  /// Unit action (SVC-05): stops starting the unit at boot.
  ///
  /// In en, this message translates to:
  /// **'Disable'**
  String get unitDisable;

  /// Unit action (SVC-06): prevents the unit from being started at all.
  ///
  /// In en, this message translates to:
  /// **'Mask'**
  String get unitMask;

  /// Unit action (SVC-06): lets a masked unit start again.
  ///
  /// In en, this message translates to:
  /// **'Unmask'**
  String get unitUnmask;

  /// Unit action (SVC-06): clears the unit's failed state.
  ///
  /// In en, this message translates to:
  /// **'Reset failed state'**
  String get unitResetFailed;

  /// Unit page and row menu: the v1 unit actions (SVC-05, SVC-06).
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get unitMoreActions;

  /// Unit page: why a unit read found nothing. reason is the engine's UnitQueryFailure name.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{There is no connection to this server.} invalidUnit{This is not a unit name.} notFound{The manager has no such unit.} managerUnavailable{Your user manager cannot be reached: you need a login session or lingering.} failed{The read failed.} other{The read failed.}}'**
  String unitQueryFailed(String reason);

  /// Unit page: the unit's current memory use.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get unitResourcesMemory;

  /// Unit page: the CPU time the unit used.
  ///
  /// In en, this message translates to:
  /// **'CPU time'**
  String get unitResourcesCpu;

  /// Unit page: CPU time in seconds. seconds is formatted with one decimal.
  ///
  /// In en, this message translates to:
  /// **'{seconds} s'**
  String unitResourcesCpuSeconds(String seconds);

  /// Unit page: the unit's current tasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get unitResourcesTasks;

  /// Unit page: how often systemd restarted the unit.
  ///
  /// In en, this message translates to:
  /// **'Restarts'**
  String get unitResourcesRestarts;

  /// Unit page: the unit's main process ID.
  ///
  /// In en, this message translates to:
  /// **'Main PID'**
  String get unitResourcesMainPid;

  /// Unit page: when the unit last became active.
  ///
  /// In en, this message translates to:
  /// **'Active since'**
  String get unitResourcesActiveSince;

  /// Unit page: opens the unit file and its drop-ins (SVC-07).
  ///
  /// In en, this message translates to:
  /// **'Show unit file'**
  String get unitFileShow;

  /// Unit file view title. unit is the unit name.
  ///
  /// In en, this message translates to:
  /// **'{unit} file'**
  String unitFileTitle(String unit);

  /// Unit file view: closes the dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get unitFileClose;

  /// Unit file view: shown while the file is read.
  ///
  /// In en, this message translates to:
  /// **'Reading the unit file…'**
  String get unitFileReading;

  /// Unit file view: how many values the engine masked, and how long a reveal lasts.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 value is masked.} other{{count} values are masked.}} Reveal shows them for {seconds} seconds.'**
  String unitFileMasked(int count, int seconds);

  /// Unit file view: shows the masked values for a while.
  ///
  /// In en, this message translates to:
  /// **'Reveal values'**
  String get unitFileReveal;

  /// Unit file view: masks the revealed values again.
  ///
  /// In en, this message translates to:
  /// **'Hide values'**
  String get unitFileHide;

  /// Unit file view: accessibility label of the read-only editor.
  ///
  /// In en, this message translates to:
  /// **'File of {unit}'**
  String unitFileEditorLabel(String unit);

  /// Services tab: lists the system manager's units.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get servicesScopeSystem;

  /// Services tab: lists the login user's own units (SVC-09).
  ///
  /// In en, this message translates to:
  /// **'Yours'**
  String get servicesScopeUser;

  /// Unit page of a user unit: its journal lines are not read (SVC-09).
  ///
  /// In en, this message translates to:
  /// **'The logs of your own units are not shown here yet.'**
  String get servicesUserLogsAbsent;

  /// Services tab, Yours: the user manager could not be reached (SVC-09).
  ///
  /// In en, this message translates to:
  /// **'Your own units could not be read. Your user manager runs only while you are logged in, or with lingering enabled.'**
  String get servicesUserUnavailable;

  /// Title of the server editor for a new server.
  ///
  /// In en, this message translates to:
  /// **'Add server'**
  String get serverEditorAddTitle;

  /// Title of the server editor for an existing server.
  ///
  /// In en, this message translates to:
  /// **'Edit server'**
  String get serverEditorEditTitle;

  /// Label of the server-name field.
  ///
  /// In en, this message translates to:
  /// **'Label'**
  String get serverEditorLabel;

  /// Label of the hostname field.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get serverEditorHost;

  /// Label of the port field.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get serverEditorPort;

  /// Label of the username field.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get serverEditorUsername;

  /// Label of the auth-method dropdown.
  ///
  /// In en, this message translates to:
  /// **'Authentication'**
  String get serverEditorAuthentication;

  /// Auth-method choice: the system ssh-agent.
  ///
  /// In en, this message translates to:
  /// **'ssh-agent'**
  String get serverEditorAuthAgent;

  /// Auth-method choice: a stored password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get serverEditorAuthPassword;

  /// Auth-method choice: a private key, pasted or referenced.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get serverEditorAuthPrivateKey;

  /// Explainer under the ssh-agent auth choice.
  ///
  /// In en, this message translates to:
  /// **'Keys are provided by your ssh-agent; nothing is stored.'**
  String get serverEditorAgentInfo;

  /// Label of the password field.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get serverEditorPasswordLabel;

  /// Title of the switch that keeps the private key on disk rather than storing it.
  ///
  /// In en, this message translates to:
  /// **'Reference a key file on disk'**
  String get serverEditorReferenceKeyTitle;

  /// Subtitle of the reference-key switch.
  ///
  /// In en, this message translates to:
  /// **'Don\'t store the key — read it at connect'**
  String get serverEditorReferenceKeySubtitle;

  /// Placeholder in the identity-file path field — a conventional key path, not a default.
  ///
  /// In en, this message translates to:
  /// **'~/.ssh/id_ed25519'**
  String get serverEditorIdentityFileHint;

  /// Label of the referenced-key path field.
  ///
  /// In en, this message translates to:
  /// **'Identity file path'**
  String get serverEditorIdentityFilePath;

  /// Button beside the identity-file path field that opens the file picker.
  ///
  /// In en, this message translates to:
  /// **'Browse…'**
  String get serverEditorBrowse;

  /// Label of the paste-a-key field.
  ///
  /// In en, this message translates to:
  /// **'Private key (PEM/OpenSSH)'**
  String get serverEditorPrivateKeyPem;

  /// Label of the key-passphrase field.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase (optional)'**
  String get serverEditorKeyPassphrase;

  /// Label of the start-folder field: the remote folder a Poltergeist pane opens when it connects to this server. Klabautermann keeps the value but does not show the field.
  ///
  /// In en, this message translates to:
  /// **'Start folder (optional)'**
  String get serverEditorStartDirectory;

  /// Hint inside the start-folder field, which Klabautermann does not show.
  ///
  /// In en, this message translates to:
  /// **'e.g. ~/sites or /var/www'**
  String get serverEditorStartDirectoryHint;

  /// Explainer under the start-folder field, which Klabautermann does not show.
  ///
  /// In en, this message translates to:
  /// **'Opens when you connect to this server. A relative path starts in your home folder. Blank opens your home folder.'**
  String get serverEditorStartDirectoryNote;

  /// Validation error when the start folder contains control characters or names another user's home (~name). The field is hidden in Klabautermann.
  ///
  /// In en, this message translates to:
  /// **'Use an absolute path such as /var/www, or one in your own home such as ~/sites.'**
  String get serverEditorStartDirectoryInvalid;

  /// Label of the login-script field: a command Séance types into the server's shell after connecting. Klabautermann stores and syncs it but never runs it.
  ///
  /// In en, this message translates to:
  /// **'Login script (optional)'**
  String get serverEditorLoginScript;

  /// Hint inside the login-script field.
  ///
  /// In en, this message translates to:
  /// **'e.g. cd ~/work && tmux attach -t work || tmux new -s work'**
  String get serverEditorLoginScriptHint;

  /// Explainer under the login-script field: Séance runs the script, Klabautermann only keeps it.
  ///
  /// In en, this message translates to:
  /// **'Séance runs this as if typed at the prompt right after connecting. Klabautermann keeps it with the server and never runs it. Keep secrets out of it. Blank for none.'**
  String get serverEditorLoginScriptNote;

  /// Heading of the group/colour/mark section.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get serverEditorAppearance;

  /// Label of the group-name field.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get serverEditorGroup;

  /// Hint inside the group-name field.
  ///
  /// In en, this message translates to:
  /// **'Production, Home lab, … — blank for none'**
  String get serverEditorGroupHint;

  /// Heading of the accent-colour row.
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get serverEditorColour;

  /// Heading of the mark row (glyph, emoji or imported image).
  ///
  /// In en, this message translates to:
  /// **'Mark'**
  String get serverEditorMark;

  /// Button that opens the mark picker.
  ///
  /// In en, this message translates to:
  /// **'Choose…'**
  String get serverEditorChooseMark;

  /// Tooltip of the button that resets the mark to the default glyph.
  ///
  /// In en, this message translates to:
  /// **'Use the default mark'**
  String get serverEditorDefaultMarkTooltip;

  /// Title of the per-server credential-sync switch.
  ///
  /// In en, this message translates to:
  /// **'Allow this credential to sync'**
  String get serverEditorSyncSecretTitle;

  /// Subtitle of the credential-sync switch while the server is excluded.
  ///
  /// In en, this message translates to:
  /// **'Not used while this server is excluded from sync.'**
  String get serverEditorSyncSecretExcluded;

  /// Subtitle of the credential-sync switch.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encrypted. Also needs sync set up with \"Sync saved passwords & keys\" enabled.'**
  String get serverEditorSyncSecretSubtitle;

  /// Title of the whole-server sync-exclusion switch.
  ///
  /// In en, this message translates to:
  /// **'Exclude from sync'**
  String get serverEditorExcludeTitle;

  /// Subtitle of the exclusion switch while it is on.
  ///
  /// In en, this message translates to:
  /// **'Kept on this device only. A copy that synced earlier is removed from the sync server and from your other devices.'**
  String get serverEditorExcludeOnSubtitle;

  /// Subtitle of the exclusion switch while it is off.
  ///
  /// In en, this message translates to:
  /// **'Keep this server on this device only — never upload it.'**
  String get serverEditorExcludeOffSubtitle;

  /// Button that authenticates against the form's draft values without saving.
  ///
  /// In en, this message translates to:
  /// **'Test connection'**
  String get serverEditorTest;

  /// Label of the test button while a test runs.
  ///
  /// In en, this message translates to:
  /// **'Testing…'**
  String get serverEditorTesting;

  /// Screen-reader label of the spinner while a connection test runs.
  ///
  /// In en, this message translates to:
  /// **'Testing connection'**
  String get serverEditorTestingSemantic;

  /// Closes the server editor without saving.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverEditorCancel;

  /// Saves the server and closes the editor.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get serverEditorSave;

  /// Small print under the test button.
  ///
  /// In en, this message translates to:
  /// **'Testing authenticates without opening a shell or running the login script. A host key you approve here is trusted for the test only — the first real connection asks again.'**
  String get serverEditorTestDisclaimer;

  /// Validator message under a blank required field.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get serverEditorRequired;

  /// Validator message under an out-of-range port.
  ///
  /// In en, this message translates to:
  /// **'1–65535'**
  String get serverEditorPortRange;

  /// Headline of the inline report when the test itself failed (not the host's answer).
  ///
  /// In en, this message translates to:
  /// **'Could not test the connection.'**
  String get serverEditorTestFailedSummary;

  /// Toast when saving the server failed. {error} is the failure detail.
  ///
  /// In en, this message translates to:
  /// **'Could not save: {error}'**
  String serverEditorSaveFailed(String error);

  /// Title of the confirmation shown before excluding a synced server.
  ///
  /// In en, this message translates to:
  /// **'Exclude from sync?'**
  String get serverEditorExcludeConfirmTitle;

  /// Body of the exclusion confirmation.
  ///
  /// In en, this message translates to:
  /// **'If this server synced earlier, it is removed from the sync server and from your other devices, along with any credential that synced with it. This device keeps its copy.'**
  String get serverEditorExcludeConfirmBody;

  /// Declines the exclusion confirmation.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverEditorExcludeConfirmCancel;

  /// Confirms the exclusion.
  ///
  /// In en, this message translates to:
  /// **'Exclude'**
  String get serverEditorExcludeConfirmAction;

  /// Tooltip of the spectrum swatch that opens the custom colour picker.
  ///
  /// In en, this message translates to:
  /// **'Custom colour…'**
  String get serverEditorCustomColour;

  /// Tooltip of the custom-colour swatch once a colour is chosen. {hex} is the stored #RRGGBB string.
  ///
  /// In en, this message translates to:
  /// **'Custom colour ({hex})'**
  String serverEditorCustomColourValue(String hex);

  /// Title of the mark picker dialog.
  ///
  /// In en, this message translates to:
  /// **'Server mark'**
  String get serverMarkPickerTitle;

  /// Tab of the mark picker listing the built-in glyphs.
  ///
  /// In en, this message translates to:
  /// **'Icons'**
  String get serverMarkPickerIconsTab;

  /// Tab of the mark picker for an emoji mark.
  ///
  /// In en, this message translates to:
  /// **'Emoji'**
  String get serverMarkPickerEmojiTab;

  /// Tab of the mark picker for an imported image.
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get serverMarkPickerImageTab;

  /// Dismisses the mark picker without choosing.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverMarkPickerCancel;

  /// Hint inside the icon-tab search field.
  ///
  /// In en, this message translates to:
  /// **'Search icons — try k8s, psql, prod…'**
  String get serverMarkPickerSearchHint;

  /// Empty state of the icon search.
  ///
  /// In en, this message translates to:
  /// **'No icon matches.'**
  String get serverMarkPickerNoMatch;

  /// Heading of the no-mark icon section.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get serverMarkPickerDefault;

  /// How to reach the OS emoji picker on macOS.
  ///
  /// In en, this message translates to:
  /// **'Press Control-Command-Space for the system emoji picker.'**
  String get serverMarkPickerEmojiHintMacOS;

  /// How to reach the OS emoji picker on Windows.
  ///
  /// In en, this message translates to:
  /// **'Press Windows-. for the system emoji picker.'**
  String get serverMarkPickerEmojiHintWindows;

  /// How to reach the OS emoji picker on Linux.
  ///
  /// In en, this message translates to:
  /// **'Your desktop may offer an emoji picker with Control-Shift-E or Control-.'**
  String get serverMarkPickerEmojiHintLinux;

  /// How to reach the emoji input on platforms without a picker chord (mobile).
  ///
  /// In en, this message translates to:
  /// **'Switch your keyboard to emoji.'**
  String get serverMarkPickerEmojiHintOther;

  /// Label of the free-text emoji field.
  ///
  /// In en, this message translates to:
  /// **'Any emoji'**
  String get serverMarkPickerAnyEmoji;

  /// Error under the emoji field when it holds text that is not a single emoji.
  ///
  /// In en, this message translates to:
  /// **'One emoji, please.'**
  String get serverMarkPickerOneEmoji;

  /// Button that confirms the typed emoji.
  ///
  /// In en, this message translates to:
  /// **'Use'**
  String get serverMarkPickerUse;

  /// Caveat under the emoji grid explaining cross-device rendering and the glyph fallback.
  ///
  /// In en, this message translates to:
  /// **'An emoji is drawn with the system’s own emoji font, so a device without one shows a box — the icon chosen under Icons is what it falls back to there.'**
  String get serverMarkPickerEmojiFontNote;

  /// Error shown when the picked image file could not be read.
  ///
  /// In en, this message translates to:
  /// **'That file could not be opened. Try another.'**
  String get serverMarkPickerOpenFailed;

  /// Error shown when the picked image exceeds the decode bound.
  ///
  /// In en, this message translates to:
  /// **'That file is too big to read. Crop or export it smaller first.'**
  String get serverMarkPickerTooLarge;

  /// Error shown when the picked file is not a decodable image.
  ///
  /// In en, this message translates to:
  /// **'That file could not be read as an image.'**
  String get serverMarkPickerUndecodable;

  /// Error shown when the picked image could not be re-encoded.
  ///
  /// In en, this message translates to:
  /// **'That image could not be prepared. Try again, or pick another.'**
  String get serverMarkPickerEncodeFailed;

  /// Error shown when the re-encoded image still exceeds the record-size bound.
  ///
  /// In en, this message translates to:
  /// **'That image would not fit in a server record even at badge size. Try a simpler picture — a logo rather than a photograph.'**
  String get serverMarkPickerIncompressible;

  /// Caption beside the badge on the image tab when no image is set.
  ///
  /// In en, this message translates to:
  /// **'No image on this server yet.'**
  String get serverMarkPickerNoImage;

  /// Caption beside the badge on the image tab when an image is set.
  ///
  /// In en, this message translates to:
  /// **'This server carries an image.'**
  String get serverMarkPickerHasImage;

  /// Button that imports an image when none is set.
  ///
  /// In en, this message translates to:
  /// **'Choose image…'**
  String get serverMarkPickerChooseImage;

  /// Button that imports an image when one is already set.
  ///
  /// In en, this message translates to:
  /// **'Replace image…'**
  String get serverMarkPickerReplaceImage;

  /// Button that reverts the mark to the image's fallback glyph.
  ///
  /// In en, this message translates to:
  /// **'Remove image'**
  String get serverMarkPickerRemoveImage;

  /// Readable list of accepted image formats (SVG excluded on iOS, which gets the photo picker).
  ///
  /// In en, this message translates to:
  /// **'PNG, JPEG, WebP or SVG'**
  String get serverMarkPickerImageFormats;

  /// Readable list of accepted image formats on iOS.
  ///
  /// In en, this message translates to:
  /// **'PNG, JPEG or WebP'**
  String get serverMarkPickerImageFormatsIos;

  /// Explainer at the bottom of the image tab. {formats} is the accepted-format list; {side} is the stored edge length in pixels.
  ///
  /// In en, this message translates to:
  /// **'{formats}. The image is cropped square, stored at {side} pixels, and travels inside this server’s own settings — so it reaches your other devices with everything else about the server, and never arrives without it. Anything larger than a badge can show would only be paid for on every sync. A transparent image shows the server’s colour through it.'**
  String serverMarkPickerImageExplanation(String formats, int side);

  /// Title of the custom colour picker dialog.
  ///
  /// In en, this message translates to:
  /// **'Custom colour'**
  String get serverColorPickerTitle;

  /// Label of the hex-digits field.
  ///
  /// In en, this message translates to:
  /// **'Hex'**
  String get colorPickerHexLabel;

  /// Error under the hex field when it does not hold six hex digits.
  ///
  /// In en, this message translates to:
  /// **'Six hex digits'**
  String get colorPickerHexError;

  /// Label of the hue slider.
  ///
  /// In en, this message translates to:
  /// **'Hue'**
  String get colorPickerHue;

  /// Label of the saturation slider.
  ///
  /// In en, this message translates to:
  /// **'Saturation'**
  String get colorPickerSaturation;

  /// Label of the brightness slider.
  ///
  /// In en, this message translates to:
  /// **'Brightness'**
  String get colorPickerBrightness;

  /// Screen-reader value of the hue slider.
  ///
  /// In en, this message translates to:
  /// **'{degrees} degrees'**
  String colorPickerDegrees(int degrees);

  /// Screen-reader value of the saturation, brightness and opacity sliders.
  ///
  /// In en, this message translates to:
  /// **'{percent} percent'**
  String colorPickerPercent(int percent);

  /// Small print under the colour sliders.
  ///
  /// In en, this message translates to:
  /// **'Drawn as picked, with the mark kept legible on it in both themes. Devices running an older version show the nearest of the named colours instead.'**
  String get serverColorPickerHint;

  /// Label of the opacity slider, shown for colours that may be translucent (a theme's lines and selection).
  ///
  /// In en, this message translates to:
  /// **'Opacity'**
  String get colorPickerOpacity;

  /// Error under the hex field of a picker that takes opacity, when it holds neither six nor eight hex digits.
  ///
  /// In en, this message translates to:
  /// **'Six or eight hex digits'**
  String get colorPickerHexErrorAlpha;

  /// Dismisses the colour picker without choosing.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get colorPickerCancel;

  /// Confirms the picked colour.
  ///
  /// In en, this message translates to:
  /// **'Use colour'**
  String get colorPickerUse;

  /// A synced fleet row's menu verb that opens the server editor on it (FL-03). Shown only while a sync account is enrolled; ssh_config imports have no such verb.
  ///
  /// In en, this message translates to:
  /// **'Edit…'**
  String get fleetRowEdit;

  /// A synced fleet row's menu verb that asks before deleting the server from the sync account (FL-03). Shown only while a sync account is enrolled.
  ///
  /// In en, this message translates to:
  /// **'Delete…'**
  String get fleetRowDelete;

  /// Title of the confirmation before a server is deleted from the sync account; names the server.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String serverDeleteTitle(String name);

  /// Body of the delete confirmation: what deleting a synced server does on other devices.
  ///
  /// In en, this message translates to:
  /// **'The server leaves your sync account, and with it every device that syncs it. Its saved password or key goes too, unless another server uses it.'**
  String get serverDeleteBody;

  /// The delete confirmation's button that keeps the server.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get serverDeleteCancel;

  /// The delete confirmation's button that deletes the server.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get serverDeleteAction;

  /// Toast when the editor is opened on a server a sync removed in the meantime.
  ///
  /// In en, this message translates to:
  /// **'This server is no longer in your account.'**
  String get serverEditGone;

  /// Toast, and the editor's save error, when the engine stopped before it answered a server edit.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann\'s engine stopped, so nothing was saved. Restart Klabautermann and try again.'**
  String get serverEditEngineStopped;

  /// Why the engine refused to save or delete a server (03 §4.4): shown as a toast, or in the editor after its Could not save prefix. reason is the engine's CatalogWriteFailure; detail is its own words, used for other only.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, directoryShared{Another Klabautermann may be using this device\'s data folder, so nothing was saved.} notEnrolled{Sign in to your sync account to edit servers.} keystoreUnavailable{Your account key could not be read from the system keystore, so nothing was saved.} unknownTarget{This server is no longer in your account.} invalidDraft{A field is missing or out of range.} tooMany{Your account holds as many servers as it can.} tooLarge{This server is too large to save. Try a smaller image for its mark.} storeUnavailable{Klabautermann\'s sync files could not be written this session, so nothing was saved.} other{Nothing was saved: {detail}}}'**
  String serverEditRefused(String reason, String detail);

  /// Heading on the Servers settings tab over adding a synced server (FL-03). Shown only while a sync account is enrolled.
  ///
  /// In en, this message translates to:
  /// **'Servers in your account'**
  String get settingsServersAccountTitle;

  /// Explanation under the heading on the Servers settings tab.
  ///
  /// In en, this message translates to:
  /// **'Add a server to your sync account here. To edit or delete one, open its menu in the server list.'**
  String get settingsServersAccountDetail;

  /// The server header's button that opens this server's terminal in the Séance app through a seance:// link (X-03). Shown only where Séance can receive the link.
  ///
  /// In en, this message translates to:
  /// **'Open terminal in Séance'**
  String get handOffOpenInSeance;

  /// Toast when the operating system refused to open the seance:// link for the server header's Open terminal in Séance button.
  ///
  /// In en, this message translates to:
  /// **'Séance did not open the link.'**
  String get handOffSeanceNotOpened;

  /// Hand-off (X-04): opens Séance on this server with a cd to this folder typed at the prompt, which the user runs.
  ///
  /// In en, this message translates to:
  /// **'Open terminal here'**
  String get handOffOpenTerminalHere;

  /// Hand-off (X-04, X-10): opens this folder or file on this server in Poltergeist, the suite's file transfer app.
  ///
  /// In en, this message translates to:
  /// **'Open in Poltergeist'**
  String get handOffOpenInPoltergeist;

  /// Toast when the operating system refused to open a poltergeist:// hand-off link.
  ///
  /// In en, this message translates to:
  /// **'Poltergeist did not open the link.'**
  String get handOffPoltergeistNotOpened;

  /// Heading of the device name on the General settings tab (M5 plan Q6).
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get settingsDeviceTitle;

  /// Label of the device name field on the General settings tab.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get settingsDeviceName;

  /// Helper text under the device name field (SAF-13): the name appears in host logs.
  ///
  /// In en, this message translates to:
  /// **'Servers\' system logs name this device beside each action you take there. Leave it blank for the default.'**
  String get settingsDeviceNameDetail;

  /// Toast when the device name applied but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The device name changed, but it could not be saved, so it will not be kept after a restart.'**
  String get settingsDeviceNameNotSaved;

  /// Toast when the app did not take a change of the device name.
  ///
  /// In en, this message translates to:
  /// **'The device name could not be changed.'**
  String get settingsDeviceNameNotChanged;

  /// Headline of the inline report when the server accepted the test's sign-in.
  ///
  /// In en, this message translates to:
  /// **'Connection test succeeded'**
  String get serverEditorTestSucceeded;

  /// Headline of the inline report when the server or the network refused the test.
  ///
  /// In en, this message translates to:
  /// **'Connection test failed'**
  String get serverEditorTestFailed;

  /// Title of the collapsible SSH transcript under a connection test's report.
  ///
  /// In en, this message translates to:
  /// **'Connection log'**
  String get connectionLogTitle;

  /// Button that copies the connection log.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get connectionLogCopy;

  /// Toast after the connection log was copied.
  ///
  /// In en, this message translates to:
  /// **'Log copied'**
  String get connectionLogCopied;

  /// Toast when copying the connection log failed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy the log'**
  String get connectionLogCopyFailed;

  /// Shown in place of an empty connection log.
  ///
  /// In en, this message translates to:
  /// **'(no log captured)'**
  String get connectionLogEmpty;

  /// A synced fleet row's menu verb that copies the server as a new one, with a copy of its credential (FL-03). Shown only while a sync account is enrolled.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get fleetRowDuplicate;

  /// Toast after a server was duplicated; the copy appears in the list as "<name> copy".
  ///
  /// In en, this message translates to:
  /// **'Copied {name}'**
  String serverDuplicated(String name);

  /// Button under the pasted private key that reads a key file into it, so the key is stored in the app's vault.
  ///
  /// In en, this message translates to:
  /// **'Import from file…'**
  String get serverEditorImportKeyFile;

  /// Toast when a picked key file is too large or not text.
  ///
  /// In en, this message translates to:
  /// **'Could not read that file as a key.'**
  String get serverEditorKeyFileImportFailed;

  /// Title of the in-app alert center (ALR-01), which lists the alerts the user's rules raised.
  ///
  /// In en, this message translates to:
  /// **'Alerts'**
  String get alertsTitle;

  /// The coverage limit (Y3) the alert notice and the alert center state: rules are evaluated only on this device and only while the app runs.
  ///
  /// In en, this message translates to:
  /// **'Evaluated on this device while Klabautermann is open.'**
  String get alertsCoverage;

  /// The fleet list's alert notice while rules have raised alerts; count is how many are raised.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 alert is active} other{{count} alerts are active}}'**
  String alertsNoticeActive(int count);

  /// The fleet list's alert notice when alerts were raised and cleared since the user last opened the alert center, and none is raised now.
  ///
  /// In en, this message translates to:
  /// **'Every alert has cleared since you last looked.'**
  String get alertsNoticeCleared;

  /// Button on the fleet list's alert notice that opens the alert center.
  ///
  /// In en, this message translates to:
  /// **'Show alerts'**
  String get alertsShow;

  /// Alert center heading over the alerts raised now.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get alertsActiveHeading;

  /// Alert center line under the Active heading when no alert is raised.
  ///
  /// In en, this message translates to:
  /// **'No alert is active.'**
  String get alertsNoneActive;

  /// Alert center heading over the latest raises and clears since the app started.
  ///
  /// In en, this message translates to:
  /// **'Earlier'**
  String get alertsHistoryHeading;

  /// A fleet row's alert count (ALR-02), in its tooltip and screen-reader label; count is how many alerts are raised for that server.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 alert} other{{count} alerts}}'**
  String alertsRowCount(int count);

  /// The number on a fleet row's alert badge (ALR-02), in the UI locale's number format.
  ///
  /// In en, this message translates to:
  /// **'{count}'**
  String alertsBadgeCount(int count);

  /// An alert center row's title; server is the server's name (server data) and metric the alert's metric, such as CPU busy.
  ///
  /// In en, this message translates to:
  /// **'{server}: {metric}'**
  String alertRowTitle(String server, String metric);

  /// An alert's severity word in the alert center.
  ///
  /// In en, this message translates to:
  /// **'{severity, select, critical{Critical} warning{Warning} other{Info}}'**
  String alertSeverity(String severity);

  /// An alert center time from before today: a date and time in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'{time}'**
  String alertDateTime(DateTime time);

  /// When a raised alert's breach began, in the alert center; time is a time of day when the breach began today, else a date and time, in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'since {time}'**
  String alertSince(String time);

  /// An alert center history row for a raise; time is a time of day in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'Raised at {time}'**
  String alertRaisedAt(String time);

  /// An alert center history row for a clear; time is a time of day in the UI locale.
  ///
  /// In en, this message translates to:
  /// **'Cleared at {time}'**
  String alertClearedAt(String time);

  /// The alert metric cpu.busy: the share of CPU time spent busy.
  ///
  /// In en, this message translates to:
  /// **'CPU busy'**
  String get alertMetricCpuBusy;

  /// The alert metric memory.used: used memory as a share of the total.
  ///
  /// In en, this message translates to:
  /// **'Memory used'**
  String get alertMetricMemoryUsed;

  /// The alert metric load.perCore: the 1-minute load average divided by the number of cores.
  ///
  /// In en, this message translates to:
  /// **'Load per core'**
  String get alertMetricLoadPerCore;

  /// The alert metric disk.used: the fullest filesystem's used space.
  ///
  /// In en, this message translates to:
  /// **'Disk space used'**
  String get alertMetricDiskUsed;

  /// The alert metric disk.inodes: the fullest filesystem's used inodes.
  ///
  /// In en, this message translates to:
  /// **'Inodes used'**
  String get alertMetricDiskInodes;

  /// The Overview card that charts a server's on-device history (HIS-01).
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyTitle;

  /// The History card's range choice of the 1-minute tier; count is 48.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Last hour} other{Last {count} hours}}'**
  String historyLastHours(int count);

  /// The History card's range choice of the 10-minute tier; count is 30.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Last day} other{Last {count} days}}'**
  String historyLastDays(int count);

  /// Tooltip of the History card's button that reads the history again.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get historyRefresh;

  /// The History card when this device recorded nothing for the server in the chosen range.
  ///
  /// In en, this message translates to:
  /// **'No history yet. Klabautermann keeps 48 hours and 30 days of this server\'s readings while it is open.'**
  String get historyEmpty;

  /// The History chart's series of each bucket's mean.
  ///
  /// In en, this message translates to:
  /// **'Average'**
  String get historyLaneMean;

  /// The History chart's series of each bucket's highest reading.
  ///
  /// In en, this message translates to:
  /// **'Peak'**
  String get historyLanePeak;

  /// Where the History chart's data comes from, as its legend says.
  ///
  /// In en, this message translates to:
  /// **'Recorded on this device while Klabautermann was open'**
  String get historySource;

  /// A History metric: the share of CPU time spent busy.
  ///
  /// In en, this message translates to:
  /// **'CPU busy'**
  String get historyMetricCpu;

  /// A History metric: used memory as a share of the total.
  ///
  /// In en, this message translates to:
  /// **'Memory used'**
  String get historyMetricMemory;

  /// A History metric: the fullest filesystem's used space.
  ///
  /// In en, this message translates to:
  /// **'Disk space used'**
  String get historyMetricDisk;

  /// A History metric: the fullest filesystem's used inodes.
  ///
  /// In en, this message translates to:
  /// **'Inodes used'**
  String get historyMetricInodes;

  /// A History metric: the 1-minute load average per core.
  ///
  /// In en, this message translates to:
  /// **'Load per core'**
  String get historyMetricLoad;

  /// Title of the alert rules page (ALR-01), and the tooltip and button that open it.
  ///
  /// In en, this message translates to:
  /// **'Alert rules'**
  String get alertRulesTitle;

  /// The alert rules page with no rule in the account.
  ///
  /// In en, this message translates to:
  /// **'No alert rules yet.'**
  String get alertRulesEmpty;

  /// The alert rules page opened from a server, when no rule applies to it.
  ///
  /// In en, this message translates to:
  /// **'No rule applies to this server yet.'**
  String get alertRulesEmptyServer;

  /// Note on the alert rules page while no sync account is enrolled; rules are rule records in the account (03 §4.8).
  ///
  /// In en, this message translates to:
  /// **'Alert rules sync through your sync account, so adding or changing one needs you signed in.'**
  String get alertRulesNeedSync;

  /// Button on the alert rules page that opens the editor on a new rule.
  ///
  /// In en, this message translates to:
  /// **'Add rule'**
  String get alertRuleAdd;

  /// Title of the rule editor for a new rule.
  ///
  /// In en, this message translates to:
  /// **'New rule'**
  String get alertRuleNew;

  /// Title of the rule editor for an existing rule.
  ///
  /// In en, this message translates to:
  /// **'Edit rule'**
  String get alertRuleEdit;

  /// The rule editor's save button.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get alertRuleSave;

  /// Tooltip of a rule row's delete button.
  ///
  /// In en, this message translates to:
  /// **'Delete rule'**
  String get alertRuleDelete;

  /// Confirmation before a rule is deleted.
  ///
  /// In en, this message translates to:
  /// **'Delete this rule? It is removed on every device that syncs your account.'**
  String get alertRuleDeleteConfirm;

  /// The confirmation's delete button.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get alertRuleDeleteAction;

  /// A rule row's title: when the rule raises. op is the comparison, metric the metric's name, such as CPU busy, and value the threshold, such as 90%.
  ///
  /// In en, this message translates to:
  /// **'{op, select, greaterThan{{metric} above {value}} greaterOrEqual{{metric} at or above {value}} lessThan{{metric} below {value}} other{{metric} at or below {value}}}'**
  String alertRuleCondition(String op, String metric, String value);

  /// When a rule clears: op is the rule's comparison, and value the clear threshold, such as 80%.
  ///
  /// In en, this message translates to:
  /// **'{op, select, greaterThan{Clears at or below {value}} greaterOrEqual{Clears below {value}} lessThan{Clears at or above {value}} other{Clears above {value}}}'**
  String alertRuleClears(String op, String value);

  /// How long a rule's condition must hold before it raises or clears, at the end of a rule row's line; duration is a number of minutes or seconds.
  ///
  /// In en, this message translates to:
  /// **'after {duration}'**
  String alertRuleFor(String duration);

  /// A rule duration in whole minutes.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute} other{{count} minutes}}'**
  String alertRuleMinutes(int count);

  /// A rule duration that is not whole minutes, in seconds.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 second} other{{count} seconds}}'**
  String alertRuleSeconds(int count);

  /// Which servers a rule applies to: one server; server is its name (server data).
  ///
  /// In en, this message translates to:
  /// **'On {server}'**
  String alertRuleScopeServer(String server);

  /// Which servers a rule applies to: one group; group is its name (server data).
  ///
  /// In en, this message translates to:
  /// **'On the {group} group'**
  String alertRuleScopeGroup(String group);

  /// Which servers a rule applies to: all of them.
  ///
  /// In en, this message translates to:
  /// **'On every server'**
  String get alertRuleScopeAll;

  /// The rule editor's metric field.
  ///
  /// In en, this message translates to:
  /// **'Metric'**
  String get alertRuleMetricLabel;

  /// The rule editor's comparison field.
  ///
  /// In en, this message translates to:
  /// **'Raise when the value is'**
  String get alertRuleOpLabel;

  /// A comparison in the rule editor's comparison field.
  ///
  /// In en, this message translates to:
  /// **'{op, select, greaterThan{Above} greaterOrEqual{At or above} lessThan{Below} other{At or below}}'**
  String alertRuleOp(String op);

  /// The rule editor's raise threshold field.
  ///
  /// In en, this message translates to:
  /// **'Raise at'**
  String get alertRuleRaiseValueLabel;

  /// The rule editor's clear threshold field.
  ///
  /// In en, this message translates to:
  /// **'Clear at'**
  String get alertRuleClearValueLabel;

  /// The rule editor's duration fields: how long the value must stay past its threshold.
  ///
  /// In en, this message translates to:
  /// **'Held for (minutes)'**
  String get alertRuleForLabel;

  /// The rule editor's severity field.
  ///
  /// In en, this message translates to:
  /// **'Severity'**
  String get alertRuleSeverityLabel;

  /// The rule editor's scope field.
  ///
  /// In en, this message translates to:
  /// **'Applies to'**
  String get alertRuleScopeLabel;

  /// The unit after a percentage threshold in the rule editor.
  ///
  /// In en, this message translates to:
  /// **'%'**
  String get alertRulePercentSuffix;

  /// Rule editor error: a threshold is not a number.
  ///
  /// In en, this message translates to:
  /// **'Enter a number.'**
  String get alertRuleNumberInvalid;

  /// Rule editor error: a percentage threshold is out of range.
  ///
  /// In en, this message translates to:
  /// **'Enter a value from 0 to 100.'**
  String get alertRulePercentInvalid;

  /// Rule editor error: a duration is not a number of minutes, 0 or more.
  ///
  /// In en, this message translates to:
  /// **'Enter 0 or more minutes.'**
  String get alertRuleMinutesInvalid;

  /// Rule editor error: an above or at-or-above rule whose clear threshold is higher than its raise threshold.
  ///
  /// In en, this message translates to:
  /// **'The clear value must not be above the raise value.'**
  String get alertRuleClearAboveRaise;

  /// Rule editor error: a below or at-or-below rule whose clear threshold is lower than its raise threshold.
  ///
  /// In en, this message translates to:
  /// **'The clear value must not be below the raise value.'**
  String get alertRuleClearBelowRaise;

  /// Why the engine refused to save or delete an alert rule, as a toast. reason is the engine's CatalogWriteFailure; detail is its own words, used for other only.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, directoryShared{Another Klabautermann may be using this device\'s data folder, so nothing was saved.} notEnrolled{Sign in to your sync account to change alert rules.} keystoreUnavailable{Your account key could not be read from the system keystore, so nothing was saved.} unknownTarget{This rule is no longer in your account.} invalidDraft{A field is missing or out of range.} tooMany{Your account holds as many rules as it can.} tooLarge{This rule is too large to save.} storeUnavailable{Klabautermann\'s sync files could not be written this session, so nothing was saved.} other{Nothing was saved: {detail}}}'**
  String alertRuleRefused(String reason, String detail);

  /// Toast when the engine stopped before it answered a rule write.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann\'s engine stopped before the rule was saved.'**
  String get alertRuleEngineStopped;

  /// The switch for raised alerts' system notifications (ALR-01), on the alert rules page and in the alert center.
  ///
  /// In en, this message translates to:
  /// **'Notify me when an alert is raised'**
  String get alertNotificationsSwitch;

  /// Under the notification switch: the coverage limit (Y3).
  ///
  /// In en, this message translates to:
  /// **'A system notification, posted only while Klabautermann is open.'**
  String get alertNotificationsSwitchDetail;

  /// Title of the app's prompt before the system asks to allow notifications.
  ///
  /// In en, this message translates to:
  /// **'Get notified of raised alerts?'**
  String get alertNotificationsPromptTitle;

  /// The notification prompt: the coverage limit (Y3), stated before the system asks.
  ///
  /// In en, this message translates to:
  /// **'Klabautermann evaluates your rules on this device while it is open, and posts a notification when one raises. It cannot notify you while it is closed.'**
  String get alertNotificationsPromptBody;

  /// The notification prompt's button that goes on to the system's request.
  ///
  /// In en, this message translates to:
  /// **'Allow notifications'**
  String get alertNotificationsPromptAllow;

  /// The notification prompt's button that leaves notifications off.
  ///
  /// In en, this message translates to:
  /// **'Not now'**
  String get alertNotificationsPromptLater;

  /// Toast when the system refused the app notifications; they stay off.
  ///
  /// In en, this message translates to:
  /// **'Notifications are turned off for Klabautermann in your system settings.'**
  String get alertNotificationsDenied;

  /// Toast when the device offers no notifications to the app.
  ///
  /// In en, this message translates to:
  /// **'This device has no system notifications Klabautermann can post.'**
  String get alertNotificationsUnavailable;

  /// Toast when the notification switch changed but settings.json could not be written.
  ///
  /// In en, this message translates to:
  /// **'The notification setting applies until Klabautermann restarts; it could not be saved.'**
  String get alertNotificationsNotSaved;

  /// A raised alert's system notification title; server is the server's name (server data), metric the metric's name, such as CPU busy, and value the reading, such as 93%.
  ///
  /// In en, this message translates to:
  /// **'{server}: {metric} at {value}'**
  String alertNotificationTitle(String server, String metric, String value);

  /// A raised alert's system notification text: its severity word, then the coverage limit (Y3).
  ///
  /// In en, this message translates to:
  /// **'{severity}. Evaluated on this device while Klabautermann is open.'**
  String alertNotificationBody(String severity);

  /// The Android notification channel's name, shown in the system's notification settings.
  ///
  /// In en, this message translates to:
  /// **'Raised alerts'**
  String get alertNotificationChannel;

  /// The Android notification channel's description, shown in the system's notification settings.
  ///
  /// In en, this message translates to:
  /// **'Alerts your rules raise while Klabautermann is open.'**
  String get alertNotificationChannelDetail;

  /// The default action of a desktop notification on Linux: brings the app forward.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get alertNotificationOpen;

  /// System tab: title of the section listing the server's pending package updates.
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get systemUpdatesTitle;

  /// System tab, Updates: the package manager lists no pending update.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get systemUpdatesNone;

  /// System tab, Updates: how many package updates the package manager lists.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 update available} other{{count} updates available}}'**
  String systemUpdatesCount(int count);

  /// System tab, Updates: how many of the pending updates fix security issues.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 is a security update} other{{count} are security updates}}'**
  String systemUpdatesSecurityCount(int count);

  /// System tab, Updates: on SUSE, how many security patches zypper says are needed; zypper lists patches rather than packages.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 security patch is needed} other{{count} security patches are needed}}'**
  String systemUpdatesSecurityPatches(int count);

  /// System tab, Updates: the server reports that a reboot is required, without naming the packages that asked.
  ///
  /// In en, this message translates to:
  /// **'The server asks for a restart.'**
  String get systemUpdatesRestart;

  /// System tab, Updates: the server reports that a reboot is required, with the packages that asked for it.
  ///
  /// In en, this message translates to:
  /// **'The server asks for a restart, for {packages}.'**
  String systemUpdatesRestartFor(String packages);

  /// System tab, Updates: the server reports that no reboot is required.
  ///
  /// In en, this message translates to:
  /// **'No restart required'**
  String get systemUpdatesNoRestart;

  /// System tab, Updates: why the check did not run, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{The server is not connected, so updates could not be checked.} transport{The connection failed while updates were checked.} other{Updates could not be checked.}}'**
  String systemUpdatesFailed(String reason);

  /// System tab, Updates: the server has none of the package managers the check knows.
  ///
  /// In en, this message translates to:
  /// **'No package manager Klabautermann reads was found (apt, dnf, zypper, pacman or apk).'**
  String get systemUpdatesNoManager;

  /// System tab, Updates: dnf has no cached metadata; the check only reads cached metadata and never refreshes it.
  ///
  /// In en, this message translates to:
  /// **'The package lists have not been downloaded on this server yet, and the check never downloads them.'**
  String get systemUpdatesNoCache;

  /// System tab, Updates: the package manager reported an error; detail is its own error text.
  ///
  /// In en, this message translates to:
  /// **'The package manager failed: {detail}'**
  String systemUpdatesManagerFailed(String detail);

  /// System tab, Updates: column header of the package name.
  ///
  /// In en, this message translates to:
  /// **'Package'**
  String get systemUpdatesPackage;

  /// System tab, Updates: column header of the installed version.
  ///
  /// In en, this message translates to:
  /// **'Installed'**
  String get systemUpdatesInstalled;

  /// System tab, Updates: column header of the version the update installs.
  ///
  /// In en, this message translates to:
  /// **'Available'**
  String get systemUpdatesAvailable;

  /// System tab, Updates: column header marking security updates.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get systemUpdatesSecurity;

  /// System tab, Updates: the cell of an update that fixes a security issue.
  ///
  /// In en, this message translates to:
  /// **'Security'**
  String get systemUpdatesSecurityYes;

  /// System tab, Updates: the list stops at its limit.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, other{Only the first {count} updates are listed.}}'**
  String systemUpdatesCut(int count);

  /// System tab, Updates: when the server last refreshed its package lists, in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'Package lists last downloaded {time}'**
  String systemUpdatesListsFrom(DateTime time);

  /// System tab, Updates: a check is running.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get systemUpdatesChecking;

  /// System tab, Updates: button that runs a new check instead of using the one from the last hour.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get systemUpdatesCheckAgain;

  /// System tab, Updates: button that downloads the server's package lists as root, in admin mode, so the next check reads current metadata.
  ///
  /// In en, this message translates to:
  /// **'Refresh package lists'**
  String get systemUpdatesRefresh;

  /// System tab, Updates: after the note that the package lists were never downloaded, says that refreshing them needs admin mode.
  ///
  /// In en, this message translates to:
  /// **'Turn on admin mode to download them.'**
  String get systemUpdatesRefreshAdminNeeded;

  /// System tab, Updates: shown after the refresh starts, until the next check.
  ///
  /// In en, this message translates to:
  /// **'When the refresh has finished, check again to read the new lists.'**
  String get systemUpdatesRefreshStarted;

  /// System tab: heading of the section that reboots or shuts down the server (SYS-03).
  ///
  /// In en, this message translates to:
  /// **'Power'**
  String get systemPowerTitle;

  /// System tab, Power: button that restarts the server, after the user types its host name.
  ///
  /// In en, this message translates to:
  /// **'Reboot'**
  String get systemPowerReboot;

  /// System tab, Power: button that turns the server off, after the user types its host name.
  ///
  /// In en, this message translates to:
  /// **'Shut down'**
  String get systemPowerShutDown;

  /// System tab, Power: shown instead of the buttons while admin mode is off, since both run as root.
  ///
  /// In en, this message translates to:
  /// **'Turn on admin mode to reboot or shut down this server.'**
  String get systemPowerAdminNeeded;

  /// System tab, Power: shown after the reboot was taken, until the server reports a new boot; elapsed is a duration such as '45 seconds'.
  ///
  /// In en, this message translates to:
  /// **'Rebooting. Waiting for the server to answer again: {elapsed} so far.'**
  String systemPowerWaiting(String elapsed);

  /// System tab, Power: shown once the rebooted server reports a new boot; elapsed is a duration such as '2 minutes'.
  ///
  /// In en, this message translates to:
  /// **'The server answered again {elapsed} after the reboot.'**
  String systemPowerBack(String elapsed);

  /// System tab, Power: shown after the shutdown was taken.
  ///
  /// In en, this message translates to:
  /// **'The server is shutting down. It stays off until someone starts it.'**
  String get systemPowerOff;

  /// System tab, Power: button that stops showing the wait for a rebooted server.
  ///
  /// In en, this message translates to:
  /// **'Stop waiting'**
  String get systemPowerStopWaiting;

  /// System tab, Updates: heading of the services still running libraries an update replaced.
  ///
  /// In en, this message translates to:
  /// **'Services to restart'**
  String get systemUpdatesRestartsTitle;

  /// System tab, Updates: button that reads, in admin mode, which services still run replaced libraries.
  ///
  /// In en, this message translates to:
  /// **'Find services to restart'**
  String get systemUpdatesRestartsRead;

  /// System tab, Updates: button that reads the services to restart again.
  ///
  /// In en, this message translates to:
  /// **'Look again'**
  String get systemUpdatesRestartsReadAgain;

  /// System tab, Updates: the services-to-restart read is running.
  ///
  /// In en, this message translates to:
  /// **'Looking for services to restart…'**
  String get systemUpdatesRestartsReading;

  /// System tab, Updates: the services-to-restart read needs admin mode, since it reads every process.
  ///
  /// In en, this message translates to:
  /// **'Finding services that still run replaced libraries needs admin mode.'**
  String get systemUpdatesRestartsAdminNeeded;

  /// System tab, Updates: the read found no service to restart.
  ///
  /// In en, this message translates to:
  /// **'No service runs a replaced library.'**
  String get systemUpdatesRestartsNone;

  /// System tab, Updates: the services still running replaced libraries; services is a comma-separated list of systemd unit names (server data).
  ///
  /// In en, this message translates to:
  /// **'Restart to load the updated libraries: {services}'**
  String systemUpdatesRestartsList(String services);

  /// System tab, Updates: needrestart reports a newer kernel than the running one.
  ///
  /// In en, this message translates to:
  /// **'A newer kernel is installed and waits for a reboot.'**
  String get systemUpdatesKernelWaiting;

  /// System tab, Updates: why the services-to-restart read read nothing, by reason.
  ///
  /// In en, this message translates to:
  /// **'{reason, select, noLink{The server is not connected, so services to restart could not be read.} adminRequired{Admin mode ended before services to restart were read.} elevationRefused{Elevation was refused, so services to restart were not read.} missing{None of needrestart, needs-restarting or zypper is installed on this server.} transport{The connection failed while services to restart were read.} other{Services to restart could not be read.}}'**
  String systemUpdatesRestartsFailed(String reason);

  /// Title of PKG-06's fleet update center, listing every server's pending updates.
  ///
  /// In en, this message translates to:
  /// **'Updates on all servers'**
  String get fleetUpdatesTitle;

  /// System tab, Updates: button that opens the fleet update center.
  ///
  /// In en, this message translates to:
  /// **'All servers'**
  String get fleetUpdatesOpen;

  /// Fleet update center: button that runs a new package check on every server instead of using the ones from the last hour.
  ///
  /// In en, this message translates to:
  /// **'Check every server again'**
  String get fleetUpdatesCheckAll;

  /// Fleet update center: the fleet is empty.
  ///
  /// In en, this message translates to:
  /// **'No servers yet.'**
  String get fleetUpdatesNoServers;

  /// Fleet update center: one server's line: pending updates, security updates (omitted at zero) and whether it asks for a restart.
  ///
  /// In en, this message translates to:
  /// **'{updates, plural, =0{Up to date} =1{1 update} other{{updates} updates}}{security, plural, =0{} other{, {security} security}}{restart, select, true{ · restart required} other{}}'**
  String fleetUpdatesSummary(int updates, int security, String restart);

  /// System tab, Updates: when the shown check ran, in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'Checked {time}'**
  String systemUpdatesCheckedAt(DateTime time);

  /// The health card's button that opens the doctor checklist (TRI-01).
  ///
  /// In en, this message translates to:
  /// **'Run the doctor'**
  String get doctorOpen;

  /// Title of the doctor checklist (TRI-01).
  ///
  /// In en, this message translates to:
  /// **'Doctor'**
  String get doctorTitle;

  /// Doctor: what the checklist is.
  ///
  /// In en, this message translates to:
  /// **'Read-only checks of this server, each with what to do about a finding. Nothing on the server changes.'**
  String get doctorIntro;

  /// Doctor: the summary line while a check still reads.
  ///
  /// In en, this message translates to:
  /// **'Checking…'**
  String get doctorRunning;

  /// Doctor: how many checks found a problem and how many a warning.
  ///
  /// In en, this message translates to:
  /// **'{problems, plural, =0{No problems} =1{1 problem} other{{problems} problems}}, {warnings, plural, =0{no warnings} =1{1 warning} other{{warnings} warnings}}'**
  String doctorSummary(int problems, int warnings);

  /// Doctor: runs the on-demand reads again.
  ///
  /// In en, this message translates to:
  /// **'Check again'**
  String get doctorAgain;

  /// Doctor: closes the checklist.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get doctorClose;

  /// Doctor: a check's name, by kind.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, diskSpace{Disk space} inodes{Inodes} failedUnits{Failed units} securityUpdates{Security updates} rebootRequired{Reboot} timeSync{Time sync} certificates{Certificates} dockerDiskUse{Docker disk use} danglingImages{Dangling images} other{Check}}'**
  String doctorCheck(String kind);

  /// Doctor: what to do about a check's finding, by kind.
  ///
  /// In en, this message translates to:
  /// **'{kind, select, diskSpace{Remove old logs, caches and unused images, or grow the filesystem. Disks on the System tab lists every mount.} inodes{Many small files use up inodes: look for caches, mail queues or session files and remove what is no longer needed.} failedUnits{Open Services to read each unit\'s log, and restart it once the cause is fixed.} securityUpdates{Install them from Updates on the System tab or with the package manager.} rebootRequired{Reboot from Power on the System tab when it suits, so the updated kernel or libraries run.} timeSync{Turn time sync on (for example with timedatectl set-ntp true) and make sure the NTP server can be reached.} certificates{Renew or replace the certificate before it expires. Certificates on the System tab shows each endpoint.} dockerDiskUse{Remove unused images, stopped containers and build cache from the Docker tab.} danglingImages{Rebuilds leave untagged images behind. Remove them from Images with the Dangling filter.} other{}}'**
  String doctorHint(String kind);

  /// Doctor: a check whose reading is missing.
  ///
  /// In en, this message translates to:
  /// **'Not known: the reading failed or has not arrived.'**
  String get doctorUnknown;

  /// Doctor: a check whose on-demand read is under way.
  ///
  /// In en, this message translates to:
  /// **'Reading…'**
  String get doctorChecking;

  /// Doctor, disk space: nothing past the warning level.
  ///
  /// In en, this message translates to:
  /// **'Every filesystem is under {percent} full.'**
  String doctorSpaceOk(String percent);

  /// Doctor, disk space: mounts past the warning level follow, one per line.
  ///
  /// In en, this message translates to:
  /// **'Filling up, the fullest at {percent}:'**
  String doctorSpaceFull(String percent);

  /// Doctor, inodes: nothing past the warning level.
  ///
  /// In en, this message translates to:
  /// **'Every filesystem uses under {percent} of its inodes.'**
  String doctorInodesOk(String percent);

  /// Doctor, inodes: mounts past the warning level follow, one per line.
  ///
  /// In en, this message translates to:
  /// **'Running out of inodes, the fullest at {percent}:'**
  String doctorInodesFull(String percent);

  /// Doctor, failed units: none.
  ///
  /// In en, this message translates to:
  /// **'No unit has failed.'**
  String get doctorUnitsOk;

  /// Doctor, failed units: the units follow, one per line.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 unit has failed:} other{{count} units have failed:}}'**
  String doctorUnitsFailed(int count);

  /// Doctor, security updates: how many.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 security update is pending.} other{{count} security updates are pending.}}'**
  String doctorSecurityPending(int count);

  /// Doctor, security updates: updates the manager cannot classify.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 update is pending, and the package manager does not say whether it fixes a security issue.} other{{count} updates are pending, and the package manager does not say which fix security issues.}}'**
  String doctorUpdatesUnclassified(int count);

  /// Doctor, security updates: none, with the other updates pending.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No updates are pending.} =1{No security updates are pending; 1 other update is.} other{No security updates are pending; {count} other updates are.}}'**
  String doctorSecurityNone(int count);

  /// Doctor, reboot: none needed.
  ///
  /// In en, this message translates to:
  /// **'No reboot is needed.'**
  String get doctorRebootNo;

  /// Doctor, reboot: needed; the packages follow, one per line.
  ///
  /// In en, this message translates to:
  /// **'A reboot is needed. Packages that asked for it, where the host says:'**
  String get doctorRebootYes;

  /// Doctor, time sync: in step.
  ///
  /// In en, this message translates to:
  /// **'The clock is synchronized.'**
  String get doctorTimeOk;

  /// Doctor, time sync: the kernel is not synchronized or time sync is off.
  ///
  /// In en, this message translates to:
  /// **'The clock is not synchronized.'**
  String get doctorTimeNotSynced;

  /// Doctor, time sync: not synchronized, with how far it is from this device ("2 minutes ahead of this device").
  ///
  /// In en, this message translates to:
  /// **'The clock is not synchronized; it reads {skew}.'**
  String doctorTimeNotSyncedSkew(String skew);

  /// Doctor, time sync: the host believes it is synchronized but is off this device's clock ("2 minutes ahead of this device").
  ///
  /// In en, this message translates to:
  /// **'The clock reads {skew}.'**
  String doctorClockOff(String skew);

  /// Doctor, certificates: nothing to check.
  ///
  /// In en, this message translates to:
  /// **'No endpoints are listed for this server.'**
  String get doctorCertificatesNone;

  /// Doctor, certificates: how to set the check up.
  ///
  /// In en, this message translates to:
  /// **'List endpoints under Certificates on the System tab to check them here.'**
  String get doctorCertificatesSetUp;

  /// Doctor, certificates: all fine.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{The endpoint presents a valid certificate.} other{All {count} endpoints present valid certificates.}}'**
  String doctorCertificatesOk(int count);

  /// Doctor, certificates: the endpoints follow, one per line.
  ///
  /// In en, this message translates to:
  /// **'Failing, untrusted, expired or expiring within 14 days:'**
  String get doctorCertificatesBad;

  /// Doctor, Docker disk use: the reclaimable size from docker system df.
  ///
  /// In en, this message translates to:
  /// **'Docker could free {size} of unused data.'**
  String doctorDockerReclaimable(String size);

  /// Doctor, dangling images: none.
  ///
  /// In en, this message translates to:
  /// **'No dangling images.'**
  String get doctorDanglingNone;

  /// Doctor, dangling images: how many and their size.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 dangling image takes {size}.} other{{count} dangling images take {size}.}}'**
  String doctorDangling(int count, String size);

  /// Fleet list: the attention notice (TRI-03), counting the unacknowledged problems.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 problem needs attention} other{{count} problems need attention}}'**
  String attentionNotice(int count);

  /// Fleet list: opens the attention queue.
  ///
  /// In en, this message translates to:
  /// **'Show'**
  String get attentionShow;

  /// Title of the attention queue (TRI-03).
  ///
  /// In en, this message translates to:
  /// **'Attention'**
  String get attentionTitle;

  /// Attention queue: what it lists and how acknowledging works.
  ///
  /// In en, this message translates to:
  /// **'Problems across the fleet, from what this device has read this run. Acknowledging one hides it until it clears; acknowledgements stay on this device.'**
  String get attentionIntro;

  /// Attention queue: no unacknowledged problem.
  ///
  /// In en, this message translates to:
  /// **'Nothing needs attention.'**
  String get attentionNone;

  /// Attention queue: heading over the acknowledged problems.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Acknowledged (1)} other{Acknowledged ({count})}}'**
  String attentionAcknowledgedHeading(int count);

  /// Attention queue: closes it.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get attentionClose;

  /// Attention queue: when a problem was acknowledged, in this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'Acknowledged {time}'**
  String attentionAcknowledgedAt(DateTime time);

  /// Attention queue: acknowledges a problem, after an optional note.
  ///
  /// In en, this message translates to:
  /// **'Acknowledge'**
  String get attentionAcknowledge;

  /// Attention queue: takes an acknowledgement back.
  ///
  /// In en, this message translates to:
  /// **'Reopen'**
  String get attentionReopen;

  /// Attention queue: opens the problem's server.
  ///
  /// In en, this message translates to:
  /// **'Open server'**
  String get attentionOpenServer;

  /// Attention queue: the engine will not dial the server until the user decides (D46).
  ///
  /// In en, this message translates to:
  /// **'Connecting is blocked until you decide, for example about a changed host key.'**
  String get attentionBlocked;

  /// Attention queue: the link failed or waits before dialling again.
  ///
  /// In en, this message translates to:
  /// **'Cannot be reached: the last attempt failed.'**
  String get attentionUnreachable;

  /// Attention queue: an in-app alert is raised, with its metric's name.
  ///
  /// In en, this message translates to:
  /// **'Alert raised: {metric}'**
  String attentionAlert(String metric);

  /// Attention queue: a failed systemd unit.
  ///
  /// In en, this message translates to:
  /// **'Unit failed: {unit}'**
  String attentionFailedUnit(String unit);

  /// Attention queue: a mount's space at the critical level.
  ///
  /// In en, this message translates to:
  /// **'{mount} is {percent} full'**
  String attentionDiskFull(String mount, String percent);

  /// Attention queue: a mount's inodes at the critical level.
  ///
  /// In en, this message translates to:
  /// **'{mount} uses {percent} of its inodes'**
  String attentionInodesFull(String mount, String percent);

  /// Attention queue: a container whose health check fails.
  ///
  /// In en, this message translates to:
  /// **'Container unhealthy: {container}'**
  String attentionUnhealthy(String container);

  /// Attention queue: title of the note dialog.
  ///
  /// In en, this message translates to:
  /// **'Acknowledge the problem'**
  String get attentionNoteTitle;

  /// Attention queue: the note field's label.
  ///
  /// In en, this message translates to:
  /// **'Note (optional)'**
  String get attentionNoteLabel;

  /// Attention queue: closes the note dialog without acknowledging.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get attentionCancel;

  /// Fleet summary strip (FL-09): servers whose link is up or whose probe answered, out of all.
  ///
  /// In en, this message translates to:
  /// **'{online} of {total} online'**
  String fleetSummaryOnline(int online, int total);

  /// Fleet summary strip (FL-09): servers with an open problem in the attention queue.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 needs attention} other{{count} need attention}}'**
  String fleetSummaryAttention(int count);

  /// Fleet summary strip (FL-09): the mean CPU busy share of the servers reporting fresh readings.
  ///
  /// In en, this message translates to:
  /// **'CPU {percent}%'**
  String fleetSummaryCpu(int percent);

  /// Fleet summary strip (FL-09): memory used and installed, summed over the servers reporting fresh readings.
  ///
  /// In en, this message translates to:
  /// **'Memory {used} of {total}'**
  String fleetSummaryMemory(String used, String total);

  /// Fleet list filter chip (FL-10): shows only servers with an open problem; the count is how many have one.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{Needs attention} other{Needs attention ({count})}}'**
  String fleetFaultsOnly(int count);

  /// Fleet list chip (FL-10): sorts servers with open problems to the top, most first.
  ///
  /// In en, this message translates to:
  /// **'Attention first'**
  String get fleetAttentionFirst;

  /// Fleet list (FL-10): shown when the faults-only filter leaves no server.
  ///
  /// In en, this message translates to:
  /// **'Nothing needs attention.'**
  String get fleetNoFaults;

  /// Fleet list (FL-10): turns the faults-only filter off.
  ///
  /// In en, this message translates to:
  /// **'Show all servers'**
  String get fleetShowAll;

  /// Server header button and page title (AUT-01): Séance's synced snippets, run on this server.
  ///
  /// In en, this message translates to:
  /// **'Snippets'**
  String get snippetsTitle;

  /// Snippets page title (AUT-01): the server the chosen snippet runs on.
  ///
  /// In en, this message translates to:
  /// **'Snippets on {server}'**
  String snippetsPageTitle(String server);

  /// Snippets page (AUT-01): the search field's label; it matches titles and commands.
  ///
  /// In en, this message translates to:
  /// **'Search snippets'**
  String get snippetsSearch;

  /// Snippets page (AUT-01): shown when the account carries no snippet.
  ///
  /// In en, this message translates to:
  /// **'No snippets yet. Snippets you save in Séance appear here once this device syncs with the same account.'**
  String get snippetsEmpty;

  /// Snippets page (AUT-01): shown when the search leaves no snippet.
  ///
  /// In en, this message translates to:
  /// **'No snippet matches your search.'**
  String get snippetsNoMatch;

  /// Snippets page (AUT-01): stands in for a snippet Séance saved without a title.
  ///
  /// In en, this message translates to:
  /// **'Untitled snippet'**
  String get snippetsUntitled;

  /// Placeholder dialog title (AUT-01): the snippet whose placeholders the user fills before the preview.
  ///
  /// In en, this message translates to:
  /// **'Fill in {title}'**
  String snippetsFillTitle(String title);

  /// Placeholder dialog (AUT-01): explains the fields above the command.
  ///
  /// In en, this message translates to:
  /// **'Each value replaces its placeholder in the command. Nothing runs until you confirm the preview.'**
  String get snippetsFillHint;

  /// Placeholder dialog (AUT-01): label of the filled command shown under the fields.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get snippetsFillCommand;

  /// Placeholder dialog (AUT-01): shown while a placeholder is still empty, so a blank value never runs.
  ///
  /// In en, this message translates to:
  /// **'Fill in every value to continue.'**
  String get snippetsFillRequired;

  /// Placeholder dialog (AUT-01): opens the action preview of the filled command.
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get snippetsContinue;

  /// Placeholder dialog (AUT-01): closes it without running anything.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get snippetsCancel;

  /// View menu: opens the command palette (PLT-07), ⌘K or Ctrl+K.
  ///
  /// In en, this message translates to:
  /// **'Command Palette…'**
  String get paletteCommand;

  /// View menu: shows a tab of the selected server's workspace (PLT-06), ⌘1 to ⌘8 or Ctrl+1 to Ctrl+8. The tab's name.
  ///
  /// In en, this message translates to:
  /// **'Go to {panel}'**
  String viewPanelCommand(String panel);

  /// Help menu: lists the keys the app takes (PLT-06), ⌘/ or Ctrl+/.
  ///
  /// In en, this message translates to:
  /// **'Keyboard Shortcuts'**
  String get keyboardMapCommand;

  /// Keyboard map dialog title (PLT-06).
  ///
  /// In en, this message translates to:
  /// **'Keyboard shortcuts'**
  String get keyboardMapTitle;

  /// Keyboard map: heading of the focused list's keys.
  ///
  /// In en, this message translates to:
  /// **'In this list'**
  String get keyboardMapList;

  /// Keyboard map: heading of the keys every window takes.
  ///
  /// In en, this message translates to:
  /// **'Everywhere'**
  String get keyboardMapEverywhere;

  /// Keyboard map: closes the dialog.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get keyboardMapClose;

  /// Keyboard map: the Escape key's name.
  ///
  /// In en, this message translates to:
  /// **'Esc'**
  String get keyboardMapEscapeKeys;

  /// Keyboard map: what Escape does.
  ///
  /// In en, this message translates to:
  /// **'Close the dialog, sheet or page on top'**
  String get keyboardMapEscape;

  /// Keyboard map: the keys that move between rows.
  ///
  /// In en, this message translates to:
  /// **'↑ ↓  or  J K'**
  String get keyboardMapMoveKeys;

  /// Keyboard map: what the arrow keys and J and K do in a list.
  ///
  /// In en, this message translates to:
  /// **'Move between rows'**
  String get keyboardMapMove;

  /// Keyboard map: the key that opens the active row.
  ///
  /// In en, this message translates to:
  /// **'Enter'**
  String get keyboardMapOpenKeys;

  /// Keyboard map: what Enter does in a list.
  ///
  /// In en, this message translates to:
  /// **'Open the row'**
  String get keyboardMapOpen;

  /// Keyboard map: the keys that open a row's actions (the context-menu key does too).
  ///
  /// In en, this message translates to:
  /// **'Shift+F10'**
  String get keyboardMapRowActionsKeys;

  /// Keyboard map: what Shift+F10 does in a list.
  ///
  /// In en, this message translates to:
  /// **'Show the row\'s actions'**
  String get keyboardMapRowActions;

  /// Keyboard map: what / does in a list with a filter field.
  ///
  /// In en, this message translates to:
  /// **'Filter the list'**
  String get keyboardMapFilter;

  /// Keyboard map: what ? does in a list.
  ///
  /// In en, this message translates to:
  /// **'Show these shortcuts'**
  String get keyboardMapShow;

  /// Single-key verb (L) in a list: opens the row's logs (PLT-06).
  ///
  /// In en, this message translates to:
  /// **'Show logs'**
  String get keyActionLogs;

  /// Single-key verb (S) in the containers list: opens a shell in the container (PLT-06).
  ///
  /// In en, this message translates to:
  /// **'Open a shell'**
  String get keyActionShell;

  /// Single-key verb (R) in a list: asks to restart the row's container or unit, with its confirmation (PLT-06).
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get keyActionRestart;

  /// Command palette: the path of the app's menu commands.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get paletteActions;

  /// Command palette: the path of the fleet's servers.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get paletteServers;

  /// Command palette: the path of the selected server's tabs.
  ///
  /// In en, this message translates to:
  /// **'{server} tabs'**
  String paletteTabs(String server);

  /// Command palette: the path of the selected server's containers.
  ///
  /// In en, this message translates to:
  /// **'{server} containers'**
  String paletteContainers(String server);

  /// Command palette: the path of the selected server's systemd units.
  ///
  /// In en, this message translates to:
  /// **'{server} units'**
  String paletteUnits(String server);

  /// Command palette: the path of the selected server's compose stacks.
  ///
  /// In en, this message translates to:
  /// **'{server} stacks'**
  String paletteStacks(String server);

  /// Command palette: a container row's second line, its state and image.
  ///
  /// In en, this message translates to:
  /// **'{state} · {image}'**
  String paletteContainerDescription(String state, String image);

  /// Overview: button at its end that opens the sheet to reorder and hide its cards (OV-06).
  ///
  /// In en, this message translates to:
  /// **'Arrange cards…'**
  String get overviewEditCards;

  /// Title of the sheet that arranges the Overview's cards (OV-06).
  ///
  /// In en, this message translates to:
  /// **'Overview cards'**
  String get overviewCardsTitle;

  /// The sheet that arranges the Overview's cards: under its title.
  ///
  /// In en, this message translates to:
  /// **'Drag a card to move it, or switch it off to hide it on every server. A card a server cannot show stays out there.'**
  String get overviewCardsHint;

  /// The sheet that arranges the Overview's cards: puts every card back in its default place, shown.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get overviewCardsReset;

  /// Toast when the Overview's card arrangement applied but could not be written to this device's settings.
  ///
  /// In en, this message translates to:
  /// **'The card arrangement applies now but was not saved, so it lasts until Klabautermann restarts.'**
  String get overviewCardsNotSaved;

  /// Export sheet: switch that adds the server's name and host name to a status card (PLT-08).
  ///
  /// In en, this message translates to:
  /// **'Name the server'**
  String get exportNameServer;

  /// Export sheet: under Name the server while it is off.
  ///
  /// In en, this message translates to:
  /// **'The card leaves out the server\'s name and host name.'**
  String get exportServerUnnamed;

  /// Export sheet: under Name the server while it is on.
  ///
  /// In en, this message translates to:
  /// **'The card names the server and its host name.'**
  String get exportServerNamed;

  /// Overview: button at the end that opens the export sheet over a status card of the server's last readings (PLT-08).
  ///
  /// In en, this message translates to:
  /// **'Share status…'**
  String get statusCardAction;

  /// Title of the export sheet over a server's status card (PLT-08).
  ///
  /// In en, this message translates to:
  /// **'Status card'**
  String get statusCardTitle;

  /// The suggested file name for a saved status card. Keep it a valid file name.
  ///
  /// In en, this message translates to:
  /// **'status.txt'**
  String get statusCardFileName;

  /// Status card: its only line before the server sent any reading.
  ///
  /// In en, this message translates to:
  /// **'Nothing has been read from the server yet.'**
  String get statusCardNothingRead;

  /// Status card: first line, with when the newest reading in it arrived, in the UI locale and this device's time zone.
  ///
  /// In en, this message translates to:
  /// **'Server status at {time}'**
  String statusCardHeading(DateTime time);

  /// Status card: the server's name in Klabautermann, only when the user chose to name it.
  ///
  /// In en, this message translates to:
  /// **'Server: {name}'**
  String statusCardServer(String name);

  /// Status card: the host's static host name, only when the user chose to name the server.
  ///
  /// In en, this message translates to:
  /// **'Host name: {hostname}'**
  String statusCardHostName(String hostname);

  /// Status card: the host's operating system as it names itself, such as Debian GNU/Linux 13 (trixie).
  ///
  /// In en, this message translates to:
  /// **'System: {os}'**
  String statusCardSystem(String os);

  /// Status card: how long the host has been up, already formatted, such as 3 days, 4 hours.
  ///
  /// In en, this message translates to:
  /// **'Up for {uptime}'**
  String statusCardUptime(String uptime);

  /// Status card: total CPU use, already formatted with its percent sign.
  ///
  /// In en, this message translates to:
  /// **'CPU: {percent} busy'**
  String statusCardCpu(String percent);

  /// Status card: the 1, 5 and 15 minute load averages.
  ///
  /// In en, this message translates to:
  /// **'Load: {load1}, {load5}, {load15}'**
  String statusCardLoad(double load1, double load5, double load15);

  /// Status card: memory used and total in IEC units, and the share used with its percent sign, all already formatted.
  ///
  /// In en, this message translates to:
  /// **'Memory: {used} of {total} used ({percent})'**
  String statusCardMemory(String used, String total, String percent);

  /// Status card: one mount's space used, with its percent sign; the mount point is a path such as /var.
  ///
  /// In en, this message translates to:
  /// **'Disk {mount}: {percent} used'**
  String statusCardDisk(String mount, String percent);

  /// Status card: how many systemd units have failed.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No failed units} =1{1 failed unit} other{{count} failed units}}'**
  String statusCardFailedUnits(int count);

  /// Status card: Docker containers running out of all the server has.
  ///
  /// In en, this message translates to:
  /// **'Containers: {running} of {total} running'**
  String statusCardContainers(int running, int total);

  /// Status card: how many containers fail their health check; shown only when some do.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 container unhealthy} other{{count} containers unhealthy}}'**
  String statusCardUnhealthy(int count);

  /// Title of the export sheet over a container's inspect output as JSON (PLT-08).
  ///
  /// In en, this message translates to:
  /// **'Export the container\'s details'**
  String get dockerDetailsRawExportTitle;

  /// The suggested file name for a container's saved inspect output. Keep it a valid file name.
  ///
  /// In en, this message translates to:
  /// **'{name}-inspect.json'**
  String dockerDetailsRawFileName(String name);
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
