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
  String logJournalFieldNotSent(String name) {
    return '$name [not sent: over 4,096 bytes]';
  }

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

  @override
  String get logsPanelSource => 'Source';

  @override
  String logsPanelSourceName(String source) {
    String _temp0 = intl.Intl.selectLogic(source, {
      'journal': 'Journal',
      'kernel': 'Kernel',
      'other': 'File',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelUnit => 'Unit';

  @override
  String get logsPanelIdentifier => 'Identifier';

  @override
  String get logsPanelPriority => 'Priority';

  @override
  String get logsPanelPriorityAny => 'Any priority';

  @override
  String logsPanelPriorityLevel(String level) {
    String _temp0 = intl.Intl.selectLogic(level, {
      'emergency': 'Emergency',
      'alert': 'Alert and above',
      'critical': 'Critical and above',
      'error': 'Error and above',
      'warning': 'Warning and above',
      'notice': 'Notice and above',
      'info': 'Info and above',
      'other': 'Debug and above',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelCurrentBoot => 'Current boot only';

  @override
  String get logsPanelTimeRange => 'Time range';

  @override
  String logsPanelTimeRangeOption(String range) {
    String _temp0 = intl.Intl.selectLogic(range, {
      'last15Minutes': 'Last 15 minutes',
      'lastHour': 'Last hour',
      'last24Hours': 'Last 24 hours',
      'last7Days': 'Last 7 days',
      'other': 'Any time',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelPath => 'File path';

  @override
  String get logsPanelPathHint => 'Absolute path, such as /var/log/syslog';

  @override
  String logsPanelPathProblem(String problem) {
    String _temp0 = intl.Intl.selectLogic(problem, {
      'notAbsolute': 'Enter an absolute path that starts with /.',
      'notNormalized': 'Remove the . and .. parts from the path.',
      'other': 'The path contains a NUL character.',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelCommonPaths => 'Common paths';

  @override
  String get logsPanelApply => 'Apply';

  @override
  String logsPanelFilters(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Filters ($countString)',
      zero: 'Filters',
    );
    return '$_temp0';
  }

  @override
  String logsPanelLiveState(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'live': 'Live',
      'connecting': 'Connecting',
      'disconnected': 'Disconnected',
      'paused': 'Paused',
      'stopped': 'Stopped',
      'other': 'Unavailable',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelLiveTooltip =>
      'Follow new entries as the server writes them';

  @override
  String get logsPanelJournalLimited =>
      'Only your own journal entries are shown: your account on this server is not in the systemd-journal, adm or wheel group. The server\'s Access section shows how to add it.';

  @override
  String logsPanelStatus(String status) {
    String _temp0 = intl.Intl.selectLogic(status, {
      'opening': 'Opening the log…',
      'waitingLink': 'Waiting for the connection to the server.',
      'waitingChannel': 'Waiting for a free session on the server.',
      'waitingBackground': 'Paused while the app is in the background.',
      'loading': 'Loading entries…',
      'invalid': 'The engine refused this filter or path.',
      'missing': 'The server has no such file or log tool.',
      'denied': 'The server denied access to this log.',
      'failed': 'Reading the log failed.',
      'rejected': 'The engine did not open this log.',
      'other': 'Choose or type the absolute path of a file to tail.',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelRetry => 'Retry';

  @override
  String get logsPanelEmpty => 'This log has no entries.';

  @override
  String get logsPanelEmptyFiltered => 'No entries match these filters.';

  @override
  String get logsPanelSearchLabel => 'Search loaded entries';

  @override
  String get logsPanelSearchCase => 'Match case';

  @override
  String logsPanelSearchMatches(int total) {
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: '$totalString matches',
      one: '1 match',
      zero: 'No matches',
    );
    return '$_temp0';
  }

  @override
  String logsPanelSearchPosition(int current, int total) {
    final intl.NumberFormat currentNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String currentString = currentNumberFormat.format(current);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return '$currentString of $totalString';
  }

  @override
  String get logsPanelSearchPrevious => 'Previous match';

  @override
  String get logsPanelSearchNext => 'Next match';
}
