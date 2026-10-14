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
  /// **'{importedCount, plural, =0{No hosts were imported from ~/.ssh/config.} =1{Imported 1 server from ~/.ssh/config.} other{Imported {importedCount} servers from ~/.ssh/config.}} {skippedCount, plural, =1{1 host was skipped because its port is unsupported or its name repeats an earlier host.} other{{skippedCount} hosts were skipped because their port is unsupported or their name repeats an earlier host.}}'**
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
