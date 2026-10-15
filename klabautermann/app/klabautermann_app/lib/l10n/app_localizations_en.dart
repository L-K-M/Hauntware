// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Klabautermann';

  @override
  String get fleetTitle => 'Fleet';

  @override
  String get fleetSectionServers => 'Servers';

  @override
  String get fleetEmptyTitle => 'No servers yet';

  @override
  String get fleetEmptyBody => 'Add a server to start monitoring your fleet.';

  @override
  String serversCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count servers',
      one: '1 server',
      zero: 'no servers',
    );
    return '$_temp0';
  }

  @override
  String sidebarSectionSemantics(String title, String count) {
    return '$title, $count';
  }

  @override
  String get sidebarShowSection => 'Show section';

  @override
  String get sidebarHideSection => 'Hide section';

  @override
  String get sidebarFilterHint => 'Filter servers';

  @override
  String get sidebarFilterClear => 'Clear filter';

  @override
  String get sidebarAddMenu => 'Add';

  @override
  String get sidebarRowMenu => 'Server actions';

  @override
  String get sidebarCompactRows => 'Compact rows';

  @override
  String get sidebarComfortableRows => 'Comfortable rows';

  @override
  String get addServer => 'Add server';

  @override
  String get importSshConfig => 'Import from ~/.ssh/config';

  @override
  String sshConfigImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count servers from ~/.ssh/config.',
      one: 'Imported 1 server from ~/.ssh/config.',
      zero: 'Your ~/.ssh/config names no hosts to import.',
    );
    return '$_temp0';
  }

  @override
  String sshConfigImportedWithSkips(int importedCount, int skippedCount) {
    String _temp0 = intl.Intl.pluralLogic(
      importedCount,
      locale: localeName,
      other: 'Imported $importedCount servers from ~/.ssh/config.',
      one: 'Imported 1 server from ~/.ssh/config.',
      zero: 'No hosts were imported from ~/.ssh/config.',
    );
    String _temp1 = intl.Intl.pluralLogic(
      skippedCount,
      locale: localeName,
      other:
          '$skippedCount hosts were skipped because of settings Klabautermann cannot follow as ssh would, such as a ProxyCommand, Include or Match block.',
      one:
          '1 host was skipped because of settings Klabautermann cannot follow as ssh would, such as a ProxyCommand, Include or Match block.',
    );
    return '$_temp0 $_temp1';
  }

  @override
  String get sshConfigMissing => 'There is no ~/.ssh/config on this computer.';

  @override
  String get sshConfigUnreadable =>
      'Your ~/.ssh/config could not be read. Check that it is a regular file you can open.';

  @override
  String get sshConfigTooLarge => 'Your ~/.ssh/config is too large to import.';

  @override
  String get sshConfigImportFailed =>
      'The import from ~/.ssh/config failed. Try again, and restart the app if it keeps failing.';

  @override
  String get sshConfigImportNotSaved =>
      'This import could not be saved, so it will not be kept after a restart.';

  @override
  String get syncFleet => 'Synchronize';

  @override
  String get openSettings => 'Settings';

  @override
  String get settingsCommand => 'Settings…';

  @override
  String get appQuitLabel => 'Quit';

  @override
  String get menuFile => 'File';

  @override
  String get menuView => 'View';

  @override
  String get menuWindow => 'Window';

  @override
  String get statusConnected => 'Connected';

  @override
  String get statusConnecting => 'Connecting';

  @override
  String get statusDisconnected => 'Disconnected';

  @override
  String get statusFailed => 'Failed';

  @override
  String get statusAuthenticating => 'Authenticating';

  @override
  String get statusLimited => 'Connected with limits';

  @override
  String get statusWaitingToReconnect => 'Waiting to reconnect';

  @override
  String get statusNeedsInput => 'Needs your input';

  @override
  String get statusBlocked => 'Blocked';

  @override
  String get statusConnectionLost => 'Connection lost';

  @override
  String statusSemantics(String status) {
    return 'Server status: $status';
  }

  @override
  String get fleetRowProbeOnline => 'Online';

  @override
  String get fleetRowProbeOffline => 'Offline';

  @override
  String get fleetRowProbeUnknown => 'Reachability unknown';

  @override
  String fleetRowAgeSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String fleetRowAgeMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String fleetRowAgeHours(int hours) {
    return '$hours h';
  }

  @override
  String fleetRowUpdated(String age) {
    return 'Updated $age ago';
  }

  @override
  String fleetRowStaleAge(String age) {
    return 'Stale · $age';
  }

  @override
  String get fleetRowCpu => 'CPU';

  @override
  String get fleetRowMemory => 'Memory';

  @override
  String get fleetRowDisk => 'Disk';

  @override
  String fleetRowLocatorConflict(String servers) {
    return 'Host key conflict with $servers: they reach the same address through a different jump route.';
  }

  @override
  String get fleetRowPartSeparator => ' · ';

  @override
  String get fleetRowListSeparator => ', ';

  @override
  String fleetRowLinkAnnouncement(String server, String status) {
    return '$server: $status';
  }

  @override
  String fleetFilterCount(int matches, int total) {
    return '$matches of $total';
  }

  @override
  String fleetFilterCountOpensFirst(int matches, int total) {
    return '$matches of $total · Enter opens the first';
  }

  @override
  String get fleetFilterNoMatches => 'No servers match';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsTabGeneral => 'General';

  @override
  String get settingsTabAppearance => 'Appearance';

  @override
  String get settingsTabSync => 'Sync';

  @override
  String get settingsTabServers => 'Servers';

  @override
  String get settingsTabDocker => 'Docker';

  @override
  String get settingsTabSafety => 'Safety';

  @override
  String get settingsTabAlerts => 'Alerts';

  @override
  String get themeLabel => 'Theme';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeNotSaved =>
      'The theme changed, but it could not be saved, so it will not be kept after a restart.';

  @override
  String get themeNotChanged => 'The theme could not be changed.';

  @override
  String settingsFileRecovered(String fileName) {
    return 'Your settings file could not be read and was reset. The old file is kept as $fileName.';
  }

  @override
  String settingsFileRecoveredNotSaved(String fileName) {
    return 'Your settings file could not be read or reset. The old file is kept as $fileName. Changes you make now may be lost when Klabautermann restarts.';
  }

  @override
  String get settingsFileLeftAsIs =>
      'Your settings file could not be read, so it was left as it is. Changes you make now are not saved.';

  @override
  String get settingsFileNewer =>
      'Your settings were saved by a newer version of Klabautermann. Changes you make now are not saved.';

  @override
  String get settingsFileNotSaved =>
      'Your settings could not be saved. Changes you make now may be lost when Klabautermann restarts.';

  @override
  String importsFileRecovered(String fileName) {
    return 'Your imported servers could not be read and were cleared. The old file is kept as $fileName. Import ~/.ssh/config again to bring them back.';
  }

  @override
  String get importsFileLeftAsIs =>
      'Your imported servers could not be read, so their file was left as it is. Servers you import now will not be kept after a restart.';

  @override
  String get importsFileNewer =>
      'Your imported servers were saved by a newer version of Klabautermann. Servers you import now will not be kept after a restart.';

  @override
  String get instanceLockUnavailable =>
      'Klabautermann could not check whether it is already running. If you open it twice, the two copies can overwrite each other\'s settings and imported servers.';

  @override
  String get alreadyRunningTitle => 'Klabautermann is already running';

  @override
  String get alreadyRunningBody =>
      'Switch to the Klabautermann window that is already open. Only one copy runs at a time, so two copies never overwrite each other\'s settings and imported servers.';

  @override
  String get alreadyRunningQuit => 'Quit';

  @override
  String get settingsWindowUnreachable =>
      'Settings cannot reach Klabautermann. Close this window and open Settings again.';

  @override
  String get workspaceEmptyTitle => 'Select a server';

  @override
  String get workspaceEmptyBody =>
      'Choose a server from the fleet to see its workspace.';

  @override
  String get inspectorTitle => 'Inspector';

  @override
  String get inspectorEmptyBody =>
      'Details, alerts, operations and coverage appear here once you select a server.';

  @override
  String get placeholderMilestone => 'Available in a later milestone.';

  @override
  String get coverageFirstRunTitle => 'How Klabautermann watches your servers';

  @override
  String get coverageFirstRunBody =>
      'Klabautermann connects over SSH only while it is open. It installs nothing on your servers unless you ask it to. Charts cover only the time this device was connected.';

  @override
  String get coverageFirstRunDismiss => 'Got it';

  @override
  String get coverageFirstRunDetails => 'Coverage details';

  @override
  String get coverageFirstRunNotSaved =>
      'Klabautermann could not save that you dismissed the coverage note, so it shows again after a restart.';

  @override
  String coverageChip(int watched, int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other:
          'Watching $watched of $total servers on this device, only while open',
      one: 'Watching $watched of 1 server on this device, only while open',
    );
    return '$_temp0';
  }

  @override
  String get coverageChipHint => 'Show coverage details';

  @override
  String get coverageSheetTitle => 'Coverage on this device';

  @override
  String get coverageTierBadge => 'T0';

  @override
  String get coverageTierTitle => 'SSH while Klabautermann is open';

  @override
  String get coverageTierBody =>
      'Klabautermann reads your servers over SSH only while it is open. It installs nothing on them unless you ask it to.';

  @override
  String get coverageCoveredHeading => 'Covered';

  @override
  String get coverageLiveTitle => 'Live readings while open';

  @override
  String get coverageLiveBody =>
      'Metrics, processes, services, logs and jobs of the servers you have open.';

  @override
  String get coverageWatchedTitle => 'Continuous watching';

  @override
  String coverageWatchedBody(int watched) {
    String _temp0 = intl.Intl.pluralLogic(
      watched,
      locale: localeName,
      other:
          '$watched servers are read continuously while Klabautermann is open. Any others are read only while you have them open.',
      one:
          '1 server is read continuously while Klabautermann is open. Any others are read only while you have them open.',
      zero:
          'No server is watched on this device, so each is read only while you have it open.',
    );
    return '$_temp0';
  }

  @override
  String get coverageNotCoveredHeading => 'Not covered';

  @override
  String get coverageClosedTitle => 'While Klabautermann is closed';

  @override
  String get coverageClosedBody =>
      'Nothing checks your servers, so nothing can warn you about them.';

  @override
  String get coverageHostDownTitle => 'A server going down';

  @override
  String get coverageHostDownBody =>
      'If a server stops while Klabautermann is closed, you find out the next time you open it.';

  @override
  String get coverageHistoryTitle => 'History before you connected';

  @override
  String get coverageHistoryBody =>
      'Charts cover only the time this device was connected. Gaps are marked, never filled in.';

  @override
  String get coverageBackgroundTitle => 'While in the background';

  @override
  String get coverageBackgroundBody =>
      'Reading stops while Klabautermann is in the background and resumes when you return.';

  @override
  String coverageFreshnessSeconds(int seconds) {
    return '$seconds s';
  }

  @override
  String coverageFreshnessMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String coverageFreshnessHours(int hours) {
    return '$hours h';
  }

  @override
  String coverageFreshnessDays(int days) {
    return '$days d';
  }

  @override
  String coverageFreshnessUpdated(String age) {
    return 'Updated $age ago';
  }

  @override
  String coverageFreshnessStale(String age) {
    return 'Stale: updated $age ago';
  }

  @override
  String coverageFreshnessDisconnected(String age) {
    return 'Disconnected $age ago';
  }

  @override
  String get coverageFreshnessPaused => 'Paused: app in background';

  @override
  String get coverageFreshnessNotWatched => 'Not watched on this device';

  @override
  String get coverageFreshnessNoData => 'No data yet';

  @override
  String serverTitle(String name) {
    return '$name';
  }

  @override
  String get workspaceTabOverview => 'Overview';

  @override
  String get workspaceTabProcesses => 'Processes';

  @override
  String get workspaceTabServices => 'Services';

  @override
  String get workspaceTabLogs => 'Logs';

  @override
  String get workspaceTabJobs => 'Jobs';

  @override
  String get workspaceTabDocker => 'Docker';

  @override
  String get workspaceTabSystem => 'System';

  @override
  String get workspaceTabAccess => 'Access';

  @override
  String get serverTabMore => 'More';

  @override
  String chartSeriesSummary(
    String label,
    String current,
    String lowest,
    String highest,
    String trend,
  ) {
    return '$label: now $current, lowest $lowest, highest $highest, $trend';
  }

  @override
  String chartSeriesEmpty(String label) {
    return '$label: no data yet';
  }

  @override
  String chartSeriesUnknown(String label) {
    return '$label: unknown';
  }

  @override
  String get chartUnknownValue => 'unknown';

  @override
  String get chartGapAppClosed => 'app closed';

  @override
  String get chartGapBackground => 'in background';

  @override
  String get chartGapDisconnected => 'disconnected';

  @override
  String chartGapSummary(DateTime start, DateTime end, String reason) {
    final intl.DateFormat startDateFormat = intl.DateFormat.jms(localeName);
    final String startString = startDateFormat.format(start);
    final intl.DateFormat endDateFormat = intl.DateFormat.jms(localeName);
    final String endString = endDateFormat.format(end);

    return 'No data from $startString to $endString: $reason';
  }

  @override
  String chartGapOngoing(DateTime start, String reason) {
    final intl.DateFormat startDateFormat = intl.DateFormat.jms(localeName);
    final String startString = startDateFormat.format(start);

    return 'No data since $startString: $reason';
  }

  @override
  String chartTime(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.jm(localeName);
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String chartTimeWithSeconds(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.jms(localeName);
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String get chartTrendRising => 'rising';

  @override
  String get chartTrendFalling => 'falling';

  @override
  String get chartTrendSteady => 'steady';

  @override
  String chartPercent(double share) {
    final intl.NumberFormat shareNumberFormat =
        intl.NumberFormat.decimalPercentPattern(
          locale: localeName,
          decimalDigits: 0,
        );
    final String shareString = shareNumberFormat.format(share);

    return '$shareString';
  }

  @override
  String chartBarSummary(String label, String parts, String total) {
    return '$label: $parts of $total';
  }

  @override
  String chartBarPart(String label, String value) {
    return '$label $value';
  }

  @override
  String get chartListSeparator => ', ';

  @override
  String chartWithSeverity(String part, String severity) {
    return '$part ($severity)';
  }

  @override
  String get chartSeverityWarning => 'warning';

  @override
  String get chartSeverityCritical => 'critical';

  @override
  String chartStale(String summary) {
    return '$summary, stale';
  }

  @override
  String tableCellSemantics(String column, String value) {
    return '$column: $value';
  }

  @override
  String get tableSortedAscending => 'Sorted ascending';

  @override
  String get tableSortedDescending => 'Sorted descending';

  @override
  String get tableSortHint => 'Sort by this column';

  @override
  String get tableRowActions => 'Row actions';

  @override
  String get logViewLabel => 'Log';

  @override
  String get logFollow => 'Follow';

  @override
  String get logLevelError => 'Error';

  @override
  String get logLevelWarning => 'Warning';

  @override
  String get logLevelDebug => 'Debug';

  @override
  String logDroppedLines(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString lines dropped here',
      one: '1 line dropped here',
    );
    return '$_temp0';
  }

  @override
  String logLineCut(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '[line cut: $totalString characters in all]';
  }

  @override
  String get logJournalNotSent => '[not sent: over 4,096 bytes]';

  @override
  String logJournalFieldsLeftOut(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString more fields not kept',
      one: '1 more field not kept',
    );
    return '$_temp0';
  }

  @override
  String get logJournalShowFields => 'Show fields';

  @override
  String get logJournalHideFields => 'Hide fields';
}
