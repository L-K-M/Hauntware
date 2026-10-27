// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Klabautermann (preview)';

  @override
  String get fleetTitle => 'Fleet';

  @override
  String get fleetSectionServers => 'Servers';

  @override
  String get fleetSectionPinned => 'Pinned';

  @override
  String get fleetSectionImported => 'Imported';

  @override
  String get fleetRowPin => 'Pin to top';

  @override
  String get fleetRowUnpin => 'Unpin';

  @override
  String get fleetPinNotSaved =>
      'Klabautermann could not save your pinned servers, so the change lasts only until it quits.';

  @override
  String get fleetRowMonitor => 'Monitor';

  @override
  String get fleetRowStopMonitoring => 'Stop monitoring';

  @override
  String monitorSetFull(int limit) {
    return 'You can monitor up to $limit servers on this device. Stop monitoring one first.';
  }

  @override
  String get monitorSetNotSaved =>
      'Klabautermann could not save your monitored servers, so the change lasts only until it quits.';

  @override
  String get monitorSetNotChanged =>
      'The monitored servers could not be changed.';

  @override
  String get monitorIneligibleEndpoint =>
      'Confirm this server\'s endpoint to monitor it.';

  @override
  String get monitorIneligibleCredentials =>
      'Signs in with a password or a stored key, which asks you first, so it is read only while you have it open.';

  @override
  String get monitorIneligibleUnknown =>
      'Import your ssh_config again to monitor this server.';

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
  String get menuHelp => 'Help';

  @override
  String get aboutCommand => 'About Klabautermann';

  @override
  String aboutVersion(String version) {
    return 'Version $version';
  }

  @override
  String get aboutVersionUnknown => 'Version unknown';

  @override
  String get aboutLicence =>
      'Klabautermann\'s own code is public domain (Unlicense). It includes third-party components that keep their own licenses, listed under View licenses.';

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
  String get linkFailureUnreachable =>
      'This server could not be reached. Check its address and your network connection.';

  @override
  String get linkFailureTimedOut =>
      'This server did not answer in time. Check that it is running and that your network reaches it.';

  @override
  String get linkFailureAuthenticationRejected =>
      'The server rejected your credentials. Make sure it trusts your key or password.';

  @override
  String get linkFailureCredentialUnavailable =>
      'No credential could be offered to this server. Check that its key file can be read and holds a supported key, or load a key into ssh-agent.';

  @override
  String get linkFailureKeyPassphraseRequired =>
      'A key for this server needs a passphrase, which Klabautermann cannot ask for. Load the key into ssh-agent and remove the IdentityFile line that names it from ~/.ssh/config, then import the config again.';

  @override
  String get linkFailureKeyFileHiddenBySandbox =>
      'A key file for this server cannot be read in the Flatpak sandbox. Load the key into ssh-agent and remove the IdentityFile line that names it from ~/.ssh/config, then import the config again.';

  @override
  String get linkFailureHostKeyDeclined =>
      'This server\'s host key has not been trusted, so Klabautermann did not connect.';

  @override
  String get linkFailureKeyboardInteractiveCancelled =>
      'The server\'s sign-in questions were cancelled, so Klabautermann did not connect.';

  @override
  String get linkFailureUnsupportedAlgorithm =>
      'This server requires an algorithm Klabautermann does not support yet.';

  @override
  String get linkFailureInsecureAlgorithmsOnly =>
      'This server offers only algorithms Klabautermann refuses as insecure.';

  @override
  String get linkFailureKeyExchangeTimedOut =>
      'Klabautermann could not finish this server\'s key exchange in time on this device.';

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
  String get coverageServerChip => 'T0: sampled only while open';

  @override
  String get coverageServerTitle => 'Coverage';

  @override
  String get coverageLiveSampling =>
      'Reading this server now, while you have it open.';

  @override
  String get coverageLiveWaiting =>
      'Waiting for the connection to this server.';

  @override
  String get coverageLivePaused =>
      'Paused while Klabautermann is in the background.';

  @override
  String get coverageLiveIdle =>
      'Not reading this server now: the open panel takes no readings.';

  @override
  String get coverageLivePolicy =>
      'Reads this server only while you have it open.';

  @override
  String coverageSessionTitle(int minutes) {
    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: 'The last $minutes minutes on this device',
      one: 'The last minute on this device',
    );
    return '$_temp0';
  }

  @override
  String get coverageSessionLane => 'CPU busy';

  @override
  String get coverageSessionSource => 'Recorded by this device while connected';

  @override
  String coverageMonitorRunning(String units) {
    return 'External monitor running: $units. It may cover this server while Klabautermann is closed; Klabautermann does not read it.';
  }

  @override
  String coverageMonitorStopped(String units) {
    return 'No external monitor is running. Installed but stopped: $units.';
  }

  @override
  String get coverageMonitorNone =>
      'No external monitor found among this server\'s systemd services.';

  @override
  String get coverageMonitorChecking =>
      'Looking for an external monitor among this server\'s systemd services.';

  @override
  String get coverageMonitorUnknown =>
      'Klabautermann cannot tell whether an external monitor runs: this server\'s systemd services could not be listed.';

  @override
  String get coverageDetailsGaps => 'Recent gaps';

  @override
  String get coverageDetailsNoGaps =>
      'No pauses, lost links or failed readings.';

  @override
  String coverageDetailsEarlierGaps(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count earlier gaps not shown.',
      one: '1 earlier gap not shown.',
    );
    return '$_temp0';
  }

  @override
  String coverageReturnBanner(String start, String end) {
    return 'Paused $start to $end while in background. No data for that period.';
  }

  @override
  String get coverageReturnDismiss => 'Dismiss';

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
  String serverPanelPageTitle(String panel, String name) {
    return '$panel on $name';
  }

  @override
  String fleetServerLeftNotice(String name) {
    return '$name is no longer in your fleet, so its screen closed.';
  }

  @override
  String get fleetServerLeftDismiss => 'Dismiss';

  @override
  String get processesWaiting => 'Waiting for the first process list.';

  @override
  String processesUnavailable(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'missing': 'The server lacks a tool the process list needs.',
      'denied': 'The server refused the process list.',
      'timeout': 'The process list did not finish in time.',
      'other': 'The process list failed.',
    });
    return '$_temp0';
  }

  @override
  String processesShownOf(int shown, int total) {
    final intl.NumberFormat shownNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String shownString = shownNumberFormat.format(shown);
    final intl.NumberFormat totalNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String totalString = totalNumberFormat.format(total);

    return 'Showing $shownString of $totalString processes';
  }

  @override
  String processesShownSome(int shown) {
    final intl.NumberFormat shownNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String shownString = shownNumberFormat.format(shown);

    return 'Showing $shownString processes; the server left others out';
  }

  @override
  String get processesFilterHint => 'Filter processes';

  @override
  String get processesFilterClear => 'Clear filter';

  @override
  String get processesSortBy => 'Sort by';

  @override
  String get processesEmpty => 'The server listed no processes.';

  @override
  String get processesNoMatch => 'No process matches the filter.';

  @override
  String get processesColumnCommand => 'Command';

  @override
  String get processesColumnPid => 'PID';

  @override
  String get processesColumnUser => 'User';

  @override
  String get processesColumnCpu => 'CPU';

  @override
  String get processesColumnMemory => 'Memory';

  @override
  String get processesColumnStarted => 'Started';

  @override
  String get processesParentPid => 'Parent PID';

  @override
  String get processesTree => 'Tree';

  @override
  String processesFlag(String flag) {
    String _temp0 = intl.Intl.selectLogic(flag, {
      'zombie': 'zombie',
      'uninterruptible': 'waiting on I/O',
      'other': 'flagged',
    });
    return '$_temp0';
  }

  @override
  String processesFlagCount(String flag, int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString zombie processes',
      one: '1 zombie process',
    );
    String _temp1 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$countString processes waiting on I/O they cannot be interrupted from',
      one: '1 process waiting on I/O it cannot be interrupted from',
    );
    String _temp2 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString flagged processes',
      one: '1 flagged process',
    );
    String _temp3 = intl.Intl.selectLogic(flag, {
      'zombie': '$_temp0',
      'uninterruptible': '$_temp1',
      'other': '$_temp2',
    });
    return '$_temp3';
  }

  @override
  String get processesFlagSeparator => '; ';

  @override
  String get processesState => 'State';

  @override
  String processesUid(int uid) {
    return 'UID $uid';
  }

  @override
  String processesCpu(double share) {
    final intl.NumberFormat shareNumberFormat =
        intl.NumberFormat.decimalPercentPattern(
          locale: localeName,
          decimalDigits: 1,
        );
    final String shareString = shareNumberFormat.format(share);

    return '$shareString';
  }

  @override
  String processesStartedTime(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.jm(localeName);
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String processesStartedDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.yMMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String get processesCommandUnavailable => 'Command line unavailable';

  @override
  String processesCommandUnavailableOf(String name) {
    return '$name (command line unavailable)';
  }

  @override
  String get processesMasked => '(masked)';

  @override
  String processesFact(String label, String value) {
    return '$label: $value';
  }

  @override
  String get processesCommandLineTitle => 'Command line';

  @override
  String get processesDetailTitle => 'Details';

  @override
  String get processesDetailReading => 'Reading details…';

  @override
  String get processesDetailReadAgain => 'Read again';

  @override
  String processesDetailFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server denied reading this process.',
      'missing': 'The server lacks a tool this read needs.',
      'other': 'Reading this process\'s details failed.',
    });
    return '$_temp0';
  }

  @override
  String processesDetailEnded(String end) {
    String _temp0 = intl.Intl.selectLogic(end, {
      'gone': 'This process has exited.',
      'reused':
          'Its process ID now belongs to another process, so nothing was read.',
      'other': 'This process has ended.',
    });
    return '$_temp0';
  }

  @override
  String get processesDetailNoStart =>
      'The server did not report when this process started, so its details are not read.';

  @override
  String get processesDetailUnit => 'Unit';

  @override
  String get processesDetailNoUnit => 'None';

  @override
  String get processesDetailContainer => 'Container';

  @override
  String processesDetailContainerValue(String runtime, String id) {
    String _temp0 = intl.Intl.selectLogic(runtime, {
      'docker': 'Docker',
      'podman': 'Podman',
      'containerd': 'containerd',
      'crio': 'CRI-O',
      'other': 'Container',
    });
    return '$_temp0 $id';
  }

  @override
  String get processesDetailCwd => 'Working directory';

  @override
  String get processesDetailNotReadable => 'Not readable as this user';

  @override
  String get processesDetailThreads => 'Threads';

  @override
  String get processesDetailSwap => 'Swap';

  @override
  String get processesDetailSwitches => 'Context switches';

  @override
  String processesDetailSwitchesValue(int voluntary, int involuntary) {
    return '$voluntary voluntary, $involuntary involuntary';
  }

  @override
  String get processesDetailOpenFiles => 'Open files';

  @override
  String processesDetailOpenFilesOf(int count, int limit) {
    return '$count of $limit';
  }

  @override
  String get processesDetailProcessLimit => 'Process limit';

  @override
  String get processesDetailUnlimited => 'Unlimited';

  @override
  String get processesEnvironmentTitle => 'Environment';

  @override
  String get processesEnvironmentNone => 'No environment variables.';

  @override
  String get processesEnvironmentDenied =>
      'The environment is not readable as this user.';

  @override
  String processesEnvironmentCapped(int count) {
    return 'Only the first $count variables were read.';
  }

  @override
  String processesEnvironmentEntry(String name, String value) {
    return '$name: $value';
  }

  @override
  String processesRevealNote(int seconds) {
    return 'Select a masked argument to show it for $seconds seconds.';
  }

  @override
  String get processesRevealHint => 'Show the masked value';

  @override
  String get processesHideHint => 'Mask again';

  @override
  String get systemIdentityTitle => 'Identity';

  @override
  String get systemUptimeTitle => 'Uptime';

  @override
  String get systemNetworkTitle => 'Network';

  @override
  String get systemDisksTitle => 'Disks';

  @override
  String get systemHostname => 'Host name';

  @override
  String get systemOperatingSystem => 'Operating system';

  @override
  String get systemKernel => 'Kernel';

  @override
  String systemKernelValue(String name, String release) {
    return '$name $release';
  }

  @override
  String get systemArchitecture => 'Architecture';

  @override
  String get systemVirtualization => 'Virtualization';

  @override
  String get systemVirtualizationNone => 'None detected';

  @override
  String systemVirtualizationMachine(String name) {
    return 'Virtual machine ($name)';
  }

  @override
  String systemVirtualizationContainer(String name) {
    return 'Container ($name)';
  }

  @override
  String get systemVirtualizationContainerUnnamed => 'Container';

  @override
  String get systemContainerNotice =>
      'This server is a container. Figures that would come from its host read as unknown.';

  @override
  String get systemUnknown => 'Unknown';

  @override
  String get systemUnknownContainer =>
      'Inside this container this figure would be the host\'s, so it is not shown.';

  @override
  String get systemUptime => 'Up for';

  @override
  String systemUptimeDays(int days, int hours) {
    final intl.NumberFormat daysNumberFormat = intl.NumberFormat.decimalPattern(
      localeName,
    );
    final String daysString = daysNumberFormat.format(days);
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$daysString days',
      one: '1 day',
    );
    String _temp1 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hoursString hours',
      one: '1 hour',
    );
    return '$_temp0, $_temp1';
  }

  @override
  String systemUptimeHours(int hours, int minutes) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);
    final intl.NumberFormat minutesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String minutesString = minutesNumberFormat.format(minutes);

    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hoursString hours',
      one: '1 hour',
    );
    String _temp1 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutesString minutes',
      one: '1 minute',
    );
    return '$_temp0, $_temp1';
  }

  @override
  String systemUptimeMinutes(int minutes) {
    final intl.NumberFormat minutesNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String minutesString = minutesNumberFormat.format(minutes);

    String _temp0 = intl.Intl.pluralLogic(
      minutes,
      locale: localeName,
      other: '$minutesString minutes',
      one: '1 minute',
      zero: 'Less than a minute',
    );
    return '$_temp0';
  }

  @override
  String get systemBooted => 'Booted';

  @override
  String systemBootedValue(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String get systemOomTitle => 'Out-of-memory kills';

  @override
  String get systemOomReading => 'Reading the kernel\'s out-of-memory kills.';

  @override
  String systemOomFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected, so the out-of-memory kills cannot be read.',
      'denied': 'The server refused the out-of-memory read.',
      'missing': 'The server lacks a tool the out-of-memory read needs.',
      'other': 'The out-of-memory kills could not be read.',
    });
    return '$_temp0';
  }

  @override
  String systemOomCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count processes were killed for lack of memory since boot.',
      one: '1 process was killed for lack of memory since boot.',
      zero: 'No process was killed for lack of memory since boot.',
    );
    return '$_temp0';
  }

  @override
  String get systemOomCountUnknown =>
      'This kernel does not count out-of-memory kills (Linux 4.13 and later do).';

  @override
  String get systemOomLogDenied =>
      'Your login may not read the kernel log, so the killed processes cannot be named. Membership in the adm or systemd-journal group, or sudo, gives access.';

  @override
  String systemOomProcess(String command, int pid) {
    return '$command (PID $pid)';
  }

  @override
  String systemOomKilledAt(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'Killed $timeString';
  }

  @override
  String systemOomAfterBoot(String time) {
    return 'Killed $time after boot';
  }

  @override
  String systemOomMemory(String size) {
    return '$size of its own memory when killed';
  }

  @override
  String get systemOomCgroupLimit =>
      'A memory limit ran out, such as a container\'s, not the server\'s memory.';

  @override
  String get systemOomShowLog => 'Show in kernel log';

  @override
  String get systemOomReadAgain => 'Read again';

  @override
  String get systemOomLogTitle => 'Out-of-memory reports';

  @override
  String get systemOomLogClose => 'Close';

  @override
  String get systemReceive => 'Receive';

  @override
  String get systemTransmit => 'Transmit';

  @override
  String get systemWaiting => 'Waiting for the first reading.';

  @override
  String get systemUnavailableMissing =>
      'The server lacks the tool this reading needs.';

  @override
  String get systemUnavailableDenied => 'The server refused this reading.';

  @override
  String get systemUnavailableTimeout => 'This reading did not finish in time.';

  @override
  String get systemUnavailableError => 'This reading failed.';

  @override
  String get systemDisksTimedOut =>
      'Disk usage did not finish in time. A network mount (NFS or SMB) that stopped answering is the usual cause.';

  @override
  String systemDisksLastListed(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'These mounts are from the reading at $timeString; their usage is unknown now.';
  }

  @override
  String get systemDisksNoTimeout =>
      'This server has no timeout command, so a network mount that stops answering can stall disk readings.';

  @override
  String systemDisksShowPseudo(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return 'Show pseudo filesystems ($countString)';
  }

  @override
  String get systemDisksEmpty => 'No mounts to show.';

  @override
  String get systemDevice => 'Device';

  @override
  String get systemDiskActivityTitle => 'Disk activity';

  @override
  String get systemDiskActivityWaiting => 'Rates show from the second reading.';

  @override
  String get systemDiskActivityEmpty => 'No disk has done any I/O yet.';

  @override
  String get systemDiskRead => 'Read';

  @override
  String get systemDiskWrite => 'Write';

  @override
  String get systemDiskReadsPerSecond => 'Reads/s';

  @override
  String get systemDiskWritesPerSecond => 'Writes/s';

  @override
  String get systemDiskReadAwait => 'Read wait';

  @override
  String get systemDiskWriteAwait => 'Write wait';

  @override
  String get systemDiskBusy => 'Busy';

  @override
  String systemDiskOperations(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String systemDiskMilliseconds(double ms) {
    final intl.NumberFormat msNumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 1,
        );
    final String msString = msNumberFormat.format(ms);

    return '$msString ms';
  }

  @override
  String get systemTemperaturesTitle => 'Temperatures';

  @override
  String get systemTemperatureSensor => 'Sensor';

  @override
  String systemTemperatureSensorName(String chip, String label) {
    return '$chip: $label';
  }

  @override
  String get systemTemperatureReading => 'Temperature';

  @override
  String get systemTemperatureHigh => 'High';

  @override
  String get systemTemperatureCritical => 'Critical';

  @override
  String systemTemperatureCelsius(double celsius) {
    final intl.NumberFormat celsiusNumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 0,
        );
    final String celsiusString = celsiusNumberFormat.format(celsius);

    return '$celsiusString °C';
  }

  @override
  String get systemGpusTitle => 'GPUs';

  @override
  String get systemGpuColumn => 'GPU';

  @override
  String get systemGpuBusy => 'Busy';

  @override
  String get systemGpuMemory => 'Memory';

  @override
  String get systemGpuPower => 'Power';

  @override
  String systemGpuWatts(double watts) {
    final intl.NumberFormat wattsNumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 0,
        );
    final String wattsString = wattsNumberFormat.format(watts);

    return '$wattsString W';
  }

  @override
  String systemGpuNvidiaFailed(String message) {
    return 'nvidia-smi is installed but failed: $message';
  }

  @override
  String get systemBootsTitle => 'Boots';

  @override
  String get systemMountReading => 'Reading mount options…';

  @override
  String systemMountFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server denied the read.',
      'missing': 'The server lacks a tool this read needs.',
      'other': 'The read failed.',
    });
    return 'Mount options could not be read. $_temp0';
  }

  @override
  String get systemMountGone => 'Nothing is mounted here any more.';

  @override
  String get systemMountSource => 'Source';

  @override
  String get systemMountOptions => 'Options';

  @override
  String get systemMountReadOnly => 'Mounted read-only';

  @override
  String get systemSwapTitle => 'Swap';

  @override
  String get systemSwapReading => 'Reading swap devices…';

  @override
  String get systemSwapNone => 'No swap devices are in use.';

  @override
  String systemSwapFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server denied the read.',
      'missing': 'The server lacks a tool this read needs.',
      'other': 'The read failed.',
    });
    return 'Swap devices could not be read. $_temp0';
  }

  @override
  String systemSwapUsage(String used, String size) {
    return '$used used of $size';
  }

  @override
  String systemSwapDetail(String kind, int priority) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'partition': 'Partition',
      'file': 'File',
      'other': 'Swap device',
    });
    return '$_temp0, priority $priority';
  }

  @override
  String get systemSwapReadAgain => 'Read again';

  @override
  String get systemBootsReading => 'Reading kernels and boots…';

  @override
  String get systemBootsReadAgain => 'Read again';

  @override
  String systemKernelRunning(String release) {
    return 'Running kernel $release';
  }

  @override
  String systemKernelState(String state, String newest) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'current': 'This is the newest kernel installed.',
      'newerInstalled': 'Kernel $newest is installed. A reboot loads it.',
      'runningRemoved':
          'The running kernel\'s modules were removed, as an upgrade does. A reboot loads $newest.',
      'other':
          'Whether a newer kernel is installed is unknown: no module directory was found, as in a container.',
    });
    return '$_temp0';
  }

  @override
  String systemKernelFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server refused the kernel check.',
      'missing': 'The server lacks the tools the kernel check runs.',
      'other': 'The kernel check failed.',
    });
    return '$_temp0';
  }

  @override
  String get systemProcessorTitle => 'Processor';

  @override
  String get systemProcessorReading => 'Reading the processor…';

  @override
  String get systemProcessorReadAgain => 'Read again';

  @override
  String get systemProcessorModel => 'Model';

  @override
  String get systemProcessorNoModel =>
      'This processor does not report a model name, as is common on ARM boards.';

  @override
  String get systemProcessorSockets => 'Sockets';

  @override
  String get systemProcessorCores => 'Cores';

  @override
  String get systemProcessorThreadsPerCore => 'Threads per core';

  @override
  String get systemProcessorLogical => 'Logical CPUs';

  @override
  String get systemProcessorUsable => 'Usable CPUs';

  @override
  String systemProcessorFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server refused the processor read.',
      'missing': 'The server lacks the tools the processor read runs.',
      'other': 'The processor read failed.',
    });
    return '$_temp0';
  }

  @override
  String get systemPortsTitle => 'Listening ports';

  @override
  String get systemPortsReading => 'Reading the listening ports…';

  @override
  String get systemPortsReadAgain => 'Read again';

  @override
  String systemPortsFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server refused the port read.',
      'missing': 'The server lacks the tools the port read runs.',
      'other': 'The port read failed.',
    });
    return '$_temp0';
  }

  @override
  String get systemPortsNoTool =>
      'The server has neither ss nor netstat, so its ports cannot be listed.';

  @override
  String get systemPortsHidden =>
      'Some ports belong to other users\' processes, whose names only root may see.';

  @override
  String get systemPortsNone => 'Nothing listens on this server.';

  @override
  String systemPortsEvery(String protocol, int port) {
    String _temp0 = intl.Intl.selectLogic(protocol, {
      'tcp': 'TCP',
      'udp': 'UDP',
      'other': '$protocol',
    });
    return '$_temp0 $port on every address';
  }

  @override
  String systemPortsOn(String protocol, int port, String addresses) {
    String _temp0 = intl.Intl.selectLogic(protocol, {
      'tcp': 'TCP',
      'udp': 'UDP',
      'other': '$protocol',
    });
    return '$_temp0 $port on $addresses';
  }

  @override
  String systemPortsProcess(String name, int pid) {
    return '$name (PID $pid)';
  }

  @override
  String get systemPortsOwnerHidden => 'Held by another user\'s process';

  @override
  String systemPortsUnit(String unit) {
    return 'Unit $unit';
  }

  @override
  String systemPortsContainer(String id) {
    return 'Container $id';
  }

  @override
  String get systemNetInterfacesTitle => 'Interfaces';

  @override
  String get systemNetReading => 'Reading the network interfaces…';

  @override
  String get systemNetReadAgain => 'Read again';

  @override
  String systemNetFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server refused the interface read.',
      'missing': 'The server lacks the tools the interface read runs.',
      'other': 'The interface read failed.',
    });
    return '$_temp0';
  }

  @override
  String get systemNetNoAddresses =>
      'The server has no ip command that lists addresses, so none are shown.';

  @override
  String systemNetShowAll(int count) {
    return 'Show loopback and virtual interfaces ($count)';
  }

  @override
  String get systemNetNone => 'The server lists no network interfaces.';

  @override
  String systemNetInterface(String name, String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'up': 'up',
      'down': 'down',
      'dormant': 'dormant',
      'lowerLayerDown': 'lower layer down',
      'notPresent': 'not present',
      'testing': 'testing',
      'other': 'state not reported',
    });
    return '$name: $_temp0';
  }

  @override
  String systemNetAddress(String address, int prefix) {
    return '$address/$prefix';
  }

  @override
  String systemNetMtu(int mtu) {
    return 'MTU $mtu';
  }

  @override
  String systemNetSpeedMbps(int speed) {
    return 'Link speed $speed Mb/s';
  }

  @override
  String systemNetSpeedGbps(double speed) {
    final intl.NumberFormat speedNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String speedString = speedNumberFormat.format(speed);

    return 'Link speed $speedString Gb/s';
  }

  @override
  String systemNetRates(String rx, String tx) {
    return 'Receiving $rx, sending $tx';
  }

  @override
  String systemNetErrors(
    int rxErrors,
    int txErrors,
    int rxDropped,
    int txDropped,
  ) {
    return 'Errors: $rxErrors in, $txErrors out. Dropped: $rxDropped in, $txDropped out.';
  }

  @override
  String get systemNetConnectionsTitle => 'Connections';

  @override
  String get systemNetConnectionsUnknown =>
      'The server\'s socket counts could not be read.';

  @override
  String get systemNetTcpEstablished => 'TCP established';

  @override
  String get systemNetTcpListening => 'TCP listening';

  @override
  String get systemNetTcpTimeWait => 'TCP time wait';

  @override
  String get systemNetTcpCloseWait => 'TCP close wait';

  @override
  String get systemNetTcpOther => 'TCP in other states';

  @override
  String get systemNetUdp => 'UDP sockets';

  @override
  String get systemNetSocketsUsed => 'All sockets';

  @override
  String get systemBootsTimelineTitle => 'Boot timeline';

  @override
  String get systemBootsCurrent => 'This boot';

  @override
  String systemBootsSpan(String start, String duration) {
    return 'Started $start, ran $duration';
  }

  @override
  String systemBootEnd(String end) {
    String _temp0 = intl.Intl.selectLogic(end, {
      'clean': 'Shut down cleanly',
      'unclean': 'Ended without a shutdown: a crash, power loss or hard reset',
      'other':
          'How it ended is unknown: its journal is not readable as this user',
    });
    return '$_temp0';
  }

  @override
  String get systemBootsNone => 'The journal lists no boots.';

  @override
  String systemBootsNotListed(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString earlier boots are not listed.',
      one: '1 earlier boot is not listed.',
    );
    return '$_temp0';
  }

  @override
  String get systemBootEndsUnknown =>
      'How the earlier boots ended could not be read.';

  @override
  String get systemDriveHealthTitle => 'Drive health';

  @override
  String get systemDriveHealthAdminNeeded =>
      'Turn on admin mode to read drive health: smartctl needs the drives\' device nodes.';

  @override
  String get systemDriveHealthRead => 'Read drive health';

  @override
  String get systemDriveHealthReadAgain => 'Read again';

  @override
  String get systemDriveHealthReading => 'Reading drive health…';

  @override
  String systemDriveHealthFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink':
          'The server is not connected, so drive health could not be read.',
      'adminRequired': 'Admin mode ended before drive health was read.',
      'elevationRefused':
          'Elevation was refused, so drive health was not read.',
      'missing': 'smartmontools is not installed on this server.',
      'unreadable':
          'smartctl did not answer as smartmontools 7.0 or later does.',
      'transport': 'The connection failed while drive health was read.',
      'other': 'Drive health could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get systemDriveHealthNone => 'No drive answered smartctl\'s scan.';

  @override
  String systemDriveHealthNotRead(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more drives were not read.',
      one: '1 more drive was not read.',
    );
    return '$_temp0';
  }

  @override
  String get systemFirewallTitle => 'Firewall';

  @override
  String get systemFirewallAdminNeeded =>
      'Turn on admin mode to read the firewall: every firewall tool needs root to list its rules.';

  @override
  String get systemFirewallRead => 'Read firewall rules';

  @override
  String get systemFirewallReadAgain => 'Read again';

  @override
  String get systemFirewallReading => 'Reading the firewall rules…';

  @override
  String systemFirewallFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink':
          'The server is not connected, so the firewall could not be read.',
      'adminRequired': 'Admin mode ended before the firewall was read.',
      'elevationRefused':
          'Elevation was refused, so the firewall was not read.',
      'unreadable':
          'The firewall tools answered in a way this app cannot read.',
      'transport': 'The connection failed while the firewall was read.',
      'other': 'The firewall could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get systemFirewallNoTool =>
      'No firewall tool was found on this server: none of ufw, firewalld, nft or iptables is installed.';

  @override
  String get systemFirewallUfw => 'ufw';

  @override
  String get systemFirewallFirewalld => 'firewalld';

  @override
  String get systemFirewallNftables => 'nftables';

  @override
  String get systemFirewallIptables => 'iptables (IPv4)';

  @override
  String get systemFirewallIp6tables => 'ip6tables (IPv6)';

  @override
  String systemFirewallActive(String active) {
    String _temp0 = intl.Intl.selectLogic(active, {
      'true': 'Active',
      'other': 'Inactive: ufw filters nothing',
    });
    return '$_temp0';
  }

  @override
  String systemFirewallRunning(String running) {
    String _temp0 = intl.Intl.selectLogic(running, {
      'true': 'Running',
      'other': 'Not running',
    });
    return '$_temp0';
  }

  @override
  String systemFirewallUfwDefaults(
    String incoming,
    String outgoing,
    String routed,
  ) {
    return 'By default: incoming $incoming, outgoing $outgoing, routed $routed';
  }

  @override
  String systemFirewallUfwRule(String to, String action, String from) {
    return '$to: $action from $from';
  }

  @override
  String get systemFirewallNoRules => 'No rules.';

  @override
  String systemFirewallZoneDefault(String zone) {
    return '$zone (default zone)';
  }

  @override
  String systemFirewallZoneInterfaces(String interfaces) {
    return 'Interfaces: $interfaces';
  }

  @override
  String systemFirewallZoneSources(String sources) {
    return 'Sources: $sources';
  }

  @override
  String systemFirewallZoneServices(String services) {
    return 'Services allowed: $services';
  }

  @override
  String systemFirewallZonePorts(String ports) {
    return 'Ports allowed: $ports';
  }

  @override
  String get systemFirewallNone => 'none';

  @override
  String systemFirewallZonesIdle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count other zones have no interface or source.',
      one: '1 other zone has no interface or source.',
    );
    return '$_temp0';
  }

  @override
  String systemFirewallChain(String chain, String policy, int rules) {
    String _temp0 = intl.Intl.pluralLogic(
      rules,
      locale: localeName,
      other: '$rules rules',
      one: '1 rule',
      zero: 'no rules',
    );
    return '$chain: policy $policy, $_temp0';
  }

  @override
  String get systemFirewallNoPolicy => 'none';

  @override
  String get systemSshdTitle => 'SSH server';

  @override
  String get systemSshdAdminNeeded =>
      'Turn on admin mode to read the SSH server\'s settings: sshd needs root to print them.';

  @override
  String get systemSshdRead => 'Read SSH server settings';

  @override
  String get systemSshdReadAgain => 'Read again';

  @override
  String get systemSshdReading => 'Reading the SSH server\'s settings…';

  @override
  String systemSshdFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink':
          'The server is not connected, so the SSH server\'s settings could not be read.',
      'adminRequired':
          'Admin mode ended before the SSH server\'s settings were read.',
      'elevationRefused':
          'Elevation was refused, so the SSH server\'s settings were not read.',
      'missing': 'No sshd was found on this server.',
      'refused':
          'sshd refused to print its settings, as for an error in its configuration.',
      'unreadable': 'sshd\'s settings could not be read.',
      'transport':
          'The connection failed while the SSH server\'s settings were read.',
      'other': 'The SSH server\'s settings could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get systemSshdMatchRemote =>
      'Match blocks for the server\'s own address or port are not applied: this sshd is too old to be told them.';

  @override
  String get systemSshdMatchNone =>
      'No Match blocks are applied: these are sshd\'s settings before any Match block, as the read could not name this connection.';

  @override
  String get systemSshdPorts => 'Ports';

  @override
  String get systemSshdListen => 'Listens on';

  @override
  String get systemSshdRootLogin => 'Root login';

  @override
  String systemSshdRoot(String value) {
    String _temp0 = intl.Intl.selectLogic(value, {
      'yes': 'Allowed',
      'no': 'Not allowed',
      'keysOnly': 'With a key only',
      'forcedCommandsOnly': 'Forced commands only',
      'other': 'Unknown',
    });
    return '$_temp0';
  }

  @override
  String get systemSshdPassword => 'Password login';

  @override
  String get systemSshdKeyboard => 'Keyboard-interactive login';

  @override
  String get systemSshdPubkey => 'Key login';

  @override
  String systemSshdEnabled(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'true': 'On',
      'false': 'Off',
      'other': 'Unknown',
    });
    return '$_temp0';
  }

  @override
  String get systemSshdMethods => 'Required login methods';

  @override
  String get systemSshdHostKeys => 'Host keys';

  @override
  String get systemSshdUserKeys => 'Accepted user key types';

  @override
  String get systemSshdMaxSessions => 'Sessions per connection';

  @override
  String get systemSshdTcpForwarding => 'TCP forwarding';

  @override
  String get systemSshdSocketForwarding => 'Socket forwarding';

  @override
  String systemSshdForwarding(String value) {
    String _temp0 = intl.Intl.selectLogic(value, {
      'all': 'Allowed',
      'local': 'Local only',
      'remote': 'Remote only',
      'no': 'Off',
      'other': 'Unknown',
    });
    return '$_temp0';
  }

  @override
  String get systemSshdPermitOpen => 'Forwarding targets';

  @override
  String get systemSshdDocker => 'Docker over SSH';

  @override
  String get systemSshdDockerAllowed => 'Not blocked by sshd\'s settings';

  @override
  String systemSshdDockerBlocked(String settings) {
    return 'Blocked by $settings';
  }

  @override
  String get systemSshdDockerNote =>
      'A key\'s options in authorized_keys, such as restrict, can block it too; sshd does not show those.';

  @override
  String get systemCertificatesTitle => 'Certificates';

  @override
  String get systemCertificatesNone =>
      'List the host names and ports whose certificates this device should check, such as this server\'s web sites.';

  @override
  String get systemCertificatesNotSaved =>
      'The endpoints could not be saved on this device; they are kept until the app quits.';

  @override
  String get systemCertificatesCheck => 'Check again';

  @override
  String get systemCertificatesEdit => 'Edit endpoints…';

  @override
  String get systemCertificatesChecking => 'Checking…';

  @override
  String get systemCertificatesNotChecked => 'Not checked yet';

  @override
  String systemCertificatesFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'lookup': 'The host name did not resolve from this device.',
      'connect': 'This device could not connect.',
      'timeout': 'No answer within 10 seconds.',
      'handshake': 'The endpoint answered, but not with TLS.',
      'other': 'The check failed.',
    });
    return '$_temp0';
  }

  @override
  String systemCertificatesExpires(DateTime date, int days) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.yMMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'in $days days',
      one: 'in 1 day',
      zero: 'today',
    );
    return 'Expires $dateString, $_temp0';
  }

  @override
  String systemCertificatesExpired(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.yMMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return 'Expired $dateString';
  }

  @override
  String get systemCertificatesUntrusted =>
      'This device does not trust this certificate for the host name: it may be self-signed, expired or issued for another name.';

  @override
  String systemCertificatesIssuer(String issuer) {
    return 'Issued by $issuer';
  }

  @override
  String get systemCertificatesEditTitle => 'Endpoints to check';

  @override
  String systemCertificatesHelper(int max) {
    return 'One per line: a host name or address, with :port for a port other than 443. At most $max.';
  }

  @override
  String systemCertificatesProblem(String problem, int max) {
    String _temp0 = intl.Intl.selectLogic(problem, {
      'notEndpoint':
          'Each line needs a host name or address, with an optional :port.',
      'tooMany': 'List at most $max endpoints.',
      'other': 'These endpoints cannot be checked.',
    });
    return '$_temp0';
  }

  @override
  String get systemCertificatesCancel => 'Cancel';

  @override
  String get systemCertificatesSave => 'Save';

  @override
  String get systemAccountsTitle => 'Users';

  @override
  String get systemAccountsColumn => 'Account';

  @override
  String get systemAccountsUid => 'UID';

  @override
  String get systemAccountsRoot => 'Root access';

  @override
  String get systemAccountsGroups => 'Groups';

  @override
  String get systemAccountsShell => 'Shell';

  @override
  String systemAccountsRootReason(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'uidZero': 'UID 0',
      'adminGroup': 'sudo, wheel or admin group',
      'dockerGroup': 'docker group',
      'other': 'Can become root',
    });
    return '$_temp0';
  }

  @override
  String systemAccountsFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink':
          'The server is not connected, so its accounts could not be read.',
      'unreadable': 'The server\'s answer could not be read as its accounts.',
      'transport': 'The connection failed while the accounts were read.',
      'other': 'The accounts could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get systemAccountsReading => 'Reading accounts…';

  @override
  String systemAccountsNotListed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more accounts are not listed.',
      one: '1 more account is not listed.',
    );
    return '$_temp0';
  }

  @override
  String systemAccountsShowSystem(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Show $count service accounts',
      one: 'Show 1 service account',
    );
    return '$_temp0';
  }

  @override
  String get systemAccountsHideSystem => 'Hide service accounts';

  @override
  String get systemAccountsSessionsTitle => 'Logged in';

  @override
  String get systemAccountsSessionsNone => 'No one is logged in.';

  @override
  String get systemAccountsSessionsUnknown =>
      'Who is logged in is unknown: this server\'s who prints a format the app does not read.';

  @override
  String systemAccountsSessionLocal(String user, String line, DateTime since) {
    final intl.DateFormat sinceDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String sinceString = sinceDateFormat.format(since);

    return '$user on $line, since $sinceString';
  }

  @override
  String systemAccountsSessionRemote(
    String user,
    String line,
    String from,
    DateTime since,
  ) {
    final intl.DateFormat sinceDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String sinceString = sinceDateFormat.format(since);

    return '$user on $line from $from, since $sinceString';
  }

  @override
  String get systemAccountsReadAgain => 'Read again';

  @override
  String get systemDriveColumn => 'Drive';

  @override
  String get systemDriveDevice => 'Device';

  @override
  String get systemDriveHealth => 'Health';

  @override
  String systemDriveVerdict(String verdict) {
    String _temp0 = intl.Intl.selectLogic(verdict, {
      'passed': 'Passed',
      'warning': 'Warning',
      'failing': 'Failing',
      'asleep': 'Asleep',
      'other': 'Unknown',
    });
    return '$_temp0';
  }

  @override
  String get systemDriveWear => 'Wear';

  @override
  String get systemDriveBadSectors => 'Bad sectors';

  @override
  String systemDriveBadSectorCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get systemDrivePowerOn => 'Powered on';

  @override
  String systemDriveHours(int hours) {
    final intl.NumberFormat hoursNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String hoursString = hoursNumberFormat.format(hours);

    return '$hoursString h';
  }

  @override
  String get systemTimeTitle => 'Time';

  @override
  String get systemTimeZone => 'Time zone';

  @override
  String get systemTimeSync => 'Time sync';

  @override
  String get systemTimeSynced => 'Synchronized';

  @override
  String get systemTimeNotSynced => 'Not synchronized';

  @override
  String get systemTimeSyncOff => 'Off';

  @override
  String get systemClock => 'Clock';

  @override
  String get systemClockInStep => 'In step with this device';

  @override
  String systemClockAhead(String amount) {
    return '$amount ahead of this device';
  }

  @override
  String systemClockBehind(String amount) {
    return '$amount behind this device';
  }

  @override
  String systemClockSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds',
      one: '1 second',
    );
    return '$_temp0';
  }

  @override
  String systemClockMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String systemClockHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String get systemColumnMount => 'Mount';

  @override
  String get systemColumnType => 'Type';

  @override
  String get systemColumnUsed => 'Used';

  @override
  String get systemColumnUse => 'Use';

  @override
  String get systemColumnInodes => 'Inodes';

  @override
  String get systemColumnUsage => 'Usage';

  @override
  String systemUsedOf(String used, String size) {
    return '$used of $size';
  }

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
  String get chartGapReadingFailed => 'reading failed';

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
  String get chartSeverityCareful => 'careful';

  @override
  String get chartSeverityWarning => 'warning';

  @override
  String get chartSeverityCritical => 'critical';

  @override
  String chartStale(String summary) {
    return '$summary, stale';
  }

  @override
  String get accessNeverRuns =>
      'Klabautermann never runs these fix commands. Copy one and run it yourself on the server.';

  @override
  String get accessRootEquivalenceTitle => 'Root-equivalent access';

  @override
  String get accessRootEquivalenceBody =>
      'Using a rootful Docker or Podman socket, or a broad passwordless sudo rule, gives the same power as root on this server. A rootless engine gives only the power of the user that runs it.';

  @override
  String get accessNotChecked =>
      'Not checked yet. Klabautermann checks access after it connects to this server.';

  @override
  String get accessRowNotChecked => 'Not checked yet.';

  @override
  String get accessStatusOk => 'OK';

  @override
  String get accessStatusMissing => 'Missing';

  @override
  String get accessStatusUnknown => 'Unknown';

  @override
  String get accessItemSudo => 'Passwordless sudo';

  @override
  String get accessItemJournal => 'Journal group';

  @override
  String get accessItemDockerSocket => 'Docker socket';

  @override
  String get accessItemStreamlocal => 'Streamlocal forwarding';

  @override
  String get accessItemCompose => 'Compose plugin';

  @override
  String get accessItemSystemd => 'systemd version';

  @override
  String get accessItemRuntime => 'Container runtime';

  @override
  String get accessReasonProbeUnavailable =>
      'The server\'s probe could not answer this.';

  @override
  String get accessReasonRootLogin =>
      'You log in as root, so no elevation or group is needed.';

  @override
  String get accessReasonSudoNoPassword =>
      'sudo runs without asking for a password.';

  @override
  String get accessReasonDoasNoPassword =>
      'doas runs without asking for a password. sudo is not installed.';

  @override
  String get accessReasonSudoNotPasswordless =>
      'sudo asks for a password, or your account may not use it. No fix is offered: a broad passwordless rule equals root.';

  @override
  String get accessReasonDoasNotPasswordless =>
      'doas asks for a password, which Klabautermann cannot enter. sudo is not installed.';

  @override
  String get accessReasonNoElevationTool =>
      'Neither sudo nor doas is installed.';

  @override
  String get accessReasonJournalGroup =>
      'You are in a group that can read the whole system journal.';

  @override
  String get accessReasonNotInJournalGroup =>
      'The journal shows only your own entries. Members of systemd-journal can read all of them.';

  @override
  String get accessReasonNoJournal => 'This server has no journalctl.';

  @override
  String get accessReasonRootfulSocket =>
      'You can use a rootful engine socket.';

  @override
  String get accessReasonRootlessSocket =>
      'You can use rootless engine sockets only.';

  @override
  String get accessReasonSocketNotWritable =>
      'Engine sockets exist, but your account cannot use any of them.';

  @override
  String get accessReasonNoEngineSocket =>
      'No Docker or Podman socket was found.';

  @override
  String get accessReasonDockerEndpointPending =>
      'Checked when Klabautermann looks for this server\'s Docker engine, after it connects.';

  @override
  String get accessReasonStreamlocalAllowed =>
      'The SSH server forwards the engine socket, the fastest route to Docker.';

  @override
  String get accessReasonStreamlocalDisabled =>
      'The SSH server refused to forward the engine socket (AllowStreamLocalForwarding or DisableForwarding in its sshd_config). Docker goes through a slower relay on the server when it has one.';

  @override
  String get accessReasonStreamlocalSocketDenied =>
      'The SSH server could not open the engine socket as your account, which cannot use it. The Docker socket row shows how access is granted.';

  @override
  String get accessReasonStreamlocalUntested =>
      'Not tested: no engine socket could be tried. The Docker tab says why.';

  @override
  String accessReasonComposePlugin(String version) {
    return 'Version $version.';
  }

  @override
  String accessReasonComposeStandaloneOnly(String version) {
    return 'Only the standalone docker-compose $version is installed. Stacks show read-only and their sources are not verified.';
  }

  @override
  String accessReasonComposeLegacyOnly(String version) {
    return 'Only Compose v1 ($version) is installed, unmaintained since 2023. Stacks show read-only.';
  }

  @override
  String get accessReasonNoCompose =>
      'Neither docker compose nor docker-compose is installed.';

  @override
  String get accessReasonComposeNotChecked =>
      'Checked once Klabautermann reaches this server\'s Docker engine.';

  @override
  String get accessReasonComposeCheckFailed =>
      'The check for docker compose failed on this server.';

  @override
  String accessReasonSystemdJson(int version) {
    return 'Version $version: unit and timer lists are read in full.';
  }

  @override
  String accessReasonSystemdTextFallback(int version) {
    return 'Version $version: older than 246, so unit and timer lists are read from text output.';
  }

  @override
  String accessReasonSystemdOlderThanTested(int version) {
    return 'Version $version is older than any tested version (239).';
  }

  @override
  String get accessReasonSystemdVersionUnparsed =>
      'systemd runs, but its version could not be read.';

  @override
  String get accessReasonNotSystemd => 'This server does not run systemd.';

  @override
  String get accessReasonEnginesDetected => 'Found on this server:';

  @override
  String get accessReasonEngineCliWithoutSocket =>
      'A docker or podman command exists, but no engine socket was found.';

  @override
  String get accessReasonNoEngine => 'No Docker or Podman engine was found.';

  @override
  String accessReasonRuntimeChosen(String path) {
    return 'Chosen manually on this device: $path';
  }

  @override
  String accessReasonRuntimeChosenUnavailable(String path) {
    return '$path was chosen on this device, but Docker does not use it: it did not answer, so another socket or none is in use.';
  }

  @override
  String get accessRootEquivalentBadge => 'Root-equivalent';

  @override
  String get accessDockerGroupWarning =>
      'Members of the docker group are root-equivalent. A rootless engine, which equals your user, is the safer choice.';

  @override
  String get accessFixRootShell =>
      'Run this as root: the server has neither sudo nor doas.';

  @override
  String get accessFixElevationUnknown =>
      'Run this as root. The probe could not tell whether the server has sudo or doas.';

  @override
  String get accessFixNextLogin =>
      'Group changes take effect at your next login.';

  @override
  String get accessFixCopy => 'Copy command';

  @override
  String accessFixCopyLabel(String item) {
    return 'Copy command for $item';
  }

  @override
  String get accessFixCopied => 'Copied. Run it yourself on the server.';

  @override
  String get accessFixCopyFailed =>
      'Not copied. The clipboard still holds its earlier text; try again before you paste.';

  @override
  String get accessEngineDockerRootful => 'Docker, rootful';

  @override
  String get accessEngineDockerRootless => 'Docker, rootless';

  @override
  String get accessEnginePodmanRootful => 'Podman, rootful';

  @override
  String get accessEnginePodmanRootless => 'Podman, rootless';

  @override
  String accessEngineAt(String engine, String path) {
    return '$engine at $path';
  }

  @override
  String get accessEngineUsableRootful =>
      'Your account can use it, which is root-equivalent.';

  @override
  String get accessEngineUsableRootless =>
      'Your account can use it, which equals the user that runs it.';

  @override
  String get accessEngineNotUsable => 'Your account cannot use it.';

  @override
  String get accessRuntimeAlias =>
      'Podman can also answer on Docker\'s socket path. Once connected, the server header names the engine that answers.';

  @override
  String accessPanelHiddenTitle(String panel) {
    return '$panel is not available on this server';
  }

  @override
  String get accessNeedJournalAccess =>
      'Your account cannot read the whole journal.';

  @override
  String get accessNeedDmesg => 'dmesg is not available.';

  @override
  String get accessNeedTail => 'This server has no tail command.';

  @override
  String get accessNeedCrontab => 'This server has no crontab command.';

  @override
  String get accessOpen => 'Open Access';

  @override
  String accessPageTitle(String name) {
    return 'Access on $name';
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
  String logContainerStream(String stream) {
    String _temp0 = intl.Intl.selectLogic(stream, {
      'stderr': 'standard error',
      'other': 'standard output',
    });
    return '$_temp0';
  }

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
  String get servicesWaiting => 'Waiting for the first list of units…';

  @override
  String get servicesUnavailableMissing =>
      'This server has no systemctl, so there are no units to list.';

  @override
  String get servicesUnavailableDenied =>
      'The server refused to list its units.';

  @override
  String get servicesUnavailableTimeout =>
      'Listing units took too long and was stopped.';

  @override
  String get servicesUnavailableError => 'Listing units failed.';

  @override
  String get servicesTextFallback =>
      'This server\'s systemd is older than version 246, so units are read from text. States that could not be read show as unknown.';

  @override
  String get servicesFilterType => 'Type';

  @override
  String get servicesFilterTypeAll => 'All types';

  @override
  String get servicesFilterState => 'State';

  @override
  String get servicesFilterStateAll => 'All states';

  @override
  String get servicesEmpty => 'No units match these filters.';

  @override
  String get servicesColumnUnit => 'Unit';

  @override
  String get servicesColumnLoad => 'Load';

  @override
  String get servicesColumnActive => 'Active';

  @override
  String get servicesColumnSub => 'Sub';

  @override
  String get servicesColumnDescription => 'Description';

  @override
  String servicesFailedCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString failed units',
      one: '1 failed unit',
      zero: 'No failed units',
    );
    return '$_temp0';
  }

  @override
  String servicesFailedUnit(String unit, String state) {
    return '$unit: $state';
  }

  @override
  String servicesFailedMore(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'and $countString more',
      one: 'and 1 more',
    );
    return '$_temp0';
  }

  @override
  String get servicesUnitClose => 'Close unit details';

  @override
  String get servicesLogsTitle => 'Recent log lines';

  @override
  String get servicesLogsShow => 'Show recent log lines';

  @override
  String get servicesLogsClose => 'Close log lines';

  @override
  String get servicesLogsRequested => 'Asking the server for recent log lines…';

  @override
  String get servicesLogsWaitingLink =>
      'Waiting for the connection to the server…';

  @override
  String get servicesLogsWaitingChannel =>
      'Waiting for a free session on the server…';

  @override
  String get servicesLogsWaitingBackground =>
      'Paused while the app is in the background.';

  @override
  String get servicesLogsReading => 'Reading recent log lines…';

  @override
  String get servicesLogsEmpty => 'The journal holds no lines for this unit.';

  @override
  String get servicesLogsRefused =>
      'Reading unit logs is not available in this version yet.';

  @override
  String get servicesLogsEngineStopped =>
      'The app\'s engine stopped. Restart the app to read unit logs.';

  @override
  String get servicesLogsInvalid =>
      'This unit\'s name cannot be used to read its logs.';

  @override
  String get servicesLogsMissing =>
      'This server has no journalctl, so unit logs cannot be read.';

  @override
  String get servicesLogsDenied =>
      'The server refused to read this unit\'s journal.';

  @override
  String get servicesLogsFailed => 'Reading this unit\'s journal failed.';

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
  String get logsPanelBoot => 'Boot';

  @override
  String logsPanelBootChoice(String choice) {
    String _temp0 = intl.Intl.selectLogic(choice, {
      'all': 'All boots',
      'current': 'This boot',
      'other': 'Boot',
    });
    return '$_temp0';
  }

  @override
  String logsPanelBootPast(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString boots ago',
      one: 'Previous boot',
    );
    return '$_temp0';
  }

  @override
  String logsPanelBootSpan(String start, String end) {
    return '$start to $end';
  }

  @override
  String get logsPanelBootsLoading => 'Reading the server\'s boots…';

  @override
  String logsPanelBootsFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server denied access to its boot list.',
      'missing': 'The server has no journal to list boots from.',
      'other': 'Reading the server\'s boots failed.',
    });
    return '$_temp0';
  }

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
  String get logsPanelBrowseFiles => 'Browse /var/log';

  @override
  String get logsPanelFiles => 'Files in /var/log';

  @override
  String get logsPanelFilesFilter => 'Filter by name';

  @override
  String get logsPanelFilesLoading => 'Listing the server\'s log files…';

  @override
  String logsPanelFilesFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Not connected to the server.',
      'denied': 'The server denied access to /var/log.',
      'missing': 'The server cannot list /var/log.',
      'other': 'Listing the server\'s log files failed.',
    });
    return '$_temp0';
  }

  @override
  String get logsPanelFilesEmpty => 'The server has no files under /var/log.';

  @override
  String get logsPanelFilesNoMatch => 'No file path contains this text.';

  @override
  String logsPanelFileDetails(String size, String modified) {
    return '$size, changed $modified';
  }

  @override
  String get logsPanelFileCompressed =>
      'Compressed: reads its last lines, without following';

  @override
  String get logsPanelFileUnreadable =>
      'Your account cannot read it; admin mode can';

  @override
  String get logsExport => 'Export';

  @override
  String logsExportTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Export $count lines',
      one: 'Export 1 line',
    );
    return '$_temp0';
  }

  @override
  String get logsExportIncludeSecrets => 'Include secrets';

  @override
  String get logsExportSecretsRedacted =>
      'Passwords, tokens and keys are replaced before the lines leave the app.';

  @override
  String get logsExportSecretsIncluded =>
      'The lines leave the app as they are, secrets included.';

  @override
  String logsExportAction(String target) {
    String _temp0 = intl.Intl.selectLogic(target, {
      'copy': 'Copy',
      'save': 'Save…',
      'other': 'Share…',
    });
    return '$_temp0';
  }

  @override
  String logsExportDone(String target) {
    String _temp0 = intl.Intl.selectLogic(target, {
      'copy': 'Copied the lines.',
      'other': 'Saved the lines.',
    });
    return '$_temp0';
  }

  @override
  String logsExportFailed(String target) {
    String _temp0 = intl.Intl.selectLogic(target, {
      'copy': 'The lines could not be copied.',
      'save': 'The lines could not be saved.',
      'other': 'The lines could not be shared.',
    });
    return '$_temp0';
  }

  @override
  String get logsExportNotRedacted =>
      'The lines could not be redacted, so nothing was exported.';

  @override
  String logsExportFileName(String source) {
    String _temp0 = intl.Intl.selectLogic(source, {
      'journal': 'journal',
      'kernel': 'kernel',
      'other': 'log',
    });
    return '$_temp0.log';
  }

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
  String get logsPanelLivePastBoot =>
      'A past boot has no new entries to follow';

  @override
  String get logsPanelLiveCompressed =>
      'A compressed file has no new lines to follow';

  @override
  String get logsPanelJournalLimited =>
      'Only your own journal entries are shown: your account on this server is not in the systemd-journal, adm or wheel group. The server\'s Access section shows how to add it.';

  @override
  String get logsPanelKernelLimited =>
      'Kernel messages may be missing: your account on this server is not in the systemd-journal, adm or wheel group, so the journal shows it none. The server\'s Access section shows how to add it.';

  @override
  String logsPanelStatus(String status) {
    String _temp0 = intl.Intl.selectLogic(status, {
      'opening': 'Opening the log…',
      'waitingLink': 'Waiting for the connection to the server.',
      'waitingChannel': 'Waiting for a free session on the server.',
      'waitingBackground': 'Paused while the app is in the background.',
      'gap':
          'Following again. Lines written while it was paused or disconnected may be missing.',
      'loading': 'Loading entries…',
      'invalid': 'The engine refused this filter or path.',
      'missing': 'The server has no such file or log tool.',
      'denied': 'The server denied access to this log.',
      'failed': 'Reading the log failed.',
      'rejected': 'The engine did not open this log.',
      'searchUnsupported':
          'This server\'s journal cannot search. Clear the server search to read the log.',
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
  String get logsPanelEmptyLimited => 'No entries are visible to your account.';

  @override
  String get logsPanelSearchLabel => 'Search loaded entries';

  @override
  String get logsPanelSearchCase => 'Match case';

  @override
  String get logsPanelSearchRegex => 'Regular expression';

  @override
  String get logsPanelSearchInvalid => 'Not a valid regular expression';

  @override
  String get logsPanelSearchServer => 'Search the whole journal on the server';

  @override
  String logsPanelServerMatch(String pattern) {
    return 'Server search: $pattern';
  }

  @override
  String get logsPanelServerMatchClear => 'Clear the server search';

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

  @override
  String overviewHeaderRuntime(String engines) {
    return 'Runtime: $engines';
  }

  @override
  String overviewHeaderRuntimeDockerPath(String engines) {
    return 'Runtime: $engines (Podman can also answer on Docker\'s socket path)';
  }

  @override
  String get overviewHeaderRuntimeSeparator => '; ';

  @override
  String get overviewHeaderRuntimeNone => 'Runtime: none found';

  @override
  String get overviewHeaderRuntimeUnknown => 'Runtime: unknown';

  @override
  String get overviewHeaderRuntimeNotChecked => 'Runtime: not checked yet';

  @override
  String get overviewWaiting => 'Waiting for the first reading.';

  @override
  String overviewUnavailable(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'missing': 'The server lacks a file or tool this reading needs.',
      'denied': 'The server refused this reading.',
      'timeout': 'This reading took too long, so the server stopped it.',
      'other': 'This reading failed on the server.',
    });
    return '$_temp0';
  }

  @override
  String get overviewUnknown => 'Unknown';

  @override
  String get overviewUnknownContainer =>
      'Inside this container these figures would be the host\'s, so they are not shown.';

  @override
  String get overviewUnknownContainerLoadPerCore =>
      'Inside this container the core count would be the host\'s, so the load per core is not shown.';

  @override
  String get overviewCpuTitle => 'CPU';

  @override
  String get overviewCpuBusy => 'Busy';

  @override
  String get overviewCpuUser => 'User';

  @override
  String get overviewCpuSystem => 'System';

  @override
  String get overviewCpuIdle => 'Idle';

  @override
  String get overviewCpuIowait => 'I/O wait';

  @override
  String get overviewCpuSteal => 'Steal';

  @override
  String get overviewCpuIrq => 'IRQ';

  @override
  String get overviewCpuSoftirq => 'Soft IRQ';

  @override
  String overviewCpuHintSteal(String percent) {
    return 'Steal $percent: the host running this virtual machine gives its CPU time to other guests, often a noisy neighbour on a VPS. Programs here run slower than the busy figure suggests.';
  }

  @override
  String overviewCpuHintIowait(String percent) {
    return 'I/O wait $percent: cores sat idle while tasks waited for storage. The kernel calls this figure unreliable, so check disk latency before blaming the disks.';
  }

  @override
  String overviewCpuHintInterrupts(String percent) {
    return 'Interrupts $percent: the CPUs spend this much handling devices, often heavy network traffic.';
  }

  @override
  String get overviewPerCoreTitle => 'Per core';

  @override
  String get overviewLoadTitle => 'Load';

  @override
  String get overviewLoad1 => '1 min';

  @override
  String get overviewLoad5 => '5 min';

  @override
  String get overviewLoad15 => '15 min';

  @override
  String get overviewLoadPerCore => 'Per core';

  @override
  String overviewLoadValue(double load) {
    final intl.NumberFormat loadNumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 2,
        );
    final String loadString = loadNumberFormat.format(load);

    return '$loadString';
  }

  @override
  String get overviewMemoryTitle => 'Memory';

  @override
  String get overviewMemoryUsed => 'Used';

  @override
  String get overviewMemoryBuffers => 'Buffers';

  @override
  String get overviewMemoryCache => 'Cache';

  @override
  String get overviewMemoryTotal => 'Total';

  @override
  String get overviewMemoryAvailable => 'Available';

  @override
  String get overviewMemoryShared => 'Shared';

  @override
  String get overviewMemoryArc => 'ZFS ARC counted as used';

  @override
  String get overviewSwapTitle => 'Swap';

  @override
  String get overviewSwapNone => 'No swap is set up.';

  @override
  String get overviewSlowTitle => 'Why is it slow?';

  @override
  String get overviewSlowNone =>
      'Nothing in the latest reading points to a slowdown.';

  @override
  String overviewSlowCpuWait(String percent) {
    return 'Tasks waited for a CPU $percent of the last 10 seconds: the processor is the bottleneck.';
  }

  @override
  String overviewSlowLoadHigh(double load) {
    final intl.NumberFormat loadNumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 2,
        );
    final String loadString = loadNumberFormat.format(load);

    return 'The load is $loadString per core: more tasks want to run than there are cores.';
  }

  @override
  String overviewSlowSteal(String percent) {
    return 'The hypervisor gave $percent of the CPU time to other guests.';
  }

  @override
  String overviewSlowIoStall(String percent) {
    return 'Tasks stalled on storage $percent of the last 10 seconds: the disks are the bottleneck.';
  }

  @override
  String overviewSlowIowait(String percent) {
    return 'Cores sat idle $percent of the time waiting for storage.';
  }

  @override
  String overviewSlowSlowDisk(String device, int ms) {
    return '$device takes $ms ms per request: it is slow or saturated.';
  }

  @override
  String overviewSlowBusyDisk(String device, String percent) {
    return '$device is busy $percent of the time: requests queue behind each other.';
  }

  @override
  String overviewSlowMemoryStall(String percent) {
    return 'Tasks stalled waiting for memory $percent of the last 10 seconds: the server is short of RAM.';
  }

  @override
  String overviewSlowSwapHeavy(String percent) {
    return 'Swap is $percent full and little memory is free: the server pages to disk.';
  }

  @override
  String get overviewSlowWhere =>
      'Processes sorts what runs by CPU and memory; System lists recent out-of-memory kills.';

  @override
  String get overviewPressureTitle => 'Pressure';

  @override
  String get overviewPressureCaption =>
      'Share of time tasks stalled, over the last 10 s, 1 min and 5 min. \"Some\" counts time at least one task waited, \"full\" time all of them did.';

  @override
  String get overviewPressureNone =>
      'This kernel reports no pressure figures. That is normal before Linux 4.20 or with PSI turned off.';

  @override
  String get overviewPressureCpu => 'CPU';

  @override
  String get overviewPressureMemory => 'Memory';

  @override
  String get overviewPressureIo => 'I/O';

  @override
  String overviewPressureSome(String resource) {
    return '$resource, some';
  }

  @override
  String overviewPressureFull(String resource) {
    return '$resource, full';
  }

  @override
  String overviewPressureValue(double avg10, double avg60, double avg300) {
    final intl.NumberFormat avg10NumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 2,
        );
    final String avg10String = avg10NumberFormat.format(avg10);
    final intl.NumberFormat avg60NumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 2,
        );
    final String avg60String = avg60NumberFormat.format(avg60);
    final intl.NumberFormat avg300NumberFormat =
        intl.NumberFormat.decimalPatternDigits(
          locale: localeName,
          decimalDigits: 2,
        );
    final String avg300String = avg300NumberFormat.format(avg300);

    return '$avg10String% · $avg60String% · $avg300String%';
  }

  @override
  String get jobsWaiting => 'Waiting for the first reading.';

  @override
  String jobsEmpty(String crontab, String timers) {
    String _temp0 = intl.Intl.selectLogic(timers, {
      'read':
          'No jobs found in your crontab, the system cron files or systemd timers.',
      'other': 'No jobs found in your crontab or the system cron files.',
    });
    String _temp1 = intl.Intl.selectLogic(timers, {
      'read': 'No jobs found in the system cron files or systemd timers.',
      'other': 'No jobs found in the system cron files.',
    });
    String _temp2 = intl.Intl.selectLogic(crontab, {
      'read': '$_temp0',
      'other': '$_temp1',
    });
    return '$_temp2';
  }

  @override
  String get jobsNoSystemd =>
      'This server does not run systemd, so it has no timers.';

  @override
  String jobsUnavailable(String source, String reason) {
    String _temp0 = intl.Intl.selectLogic(source, {
      'cron': 'Cron jobs',
      'other': 'Timers',
    });
    String _temp1 = intl.Intl.selectLogic(reason, {
      'missing': 'the server lacks a file or tool this reading needs.',
      'denied': 'the server refused this reading.',
      'timeout': 'this reading took too long, so the server stopped it.',
      'other': 'this reading failed on the server.',
    });
    return '$_temp0 could not be read: $_temp1';
  }

  @override
  String get jobsOwnCrontabUnknown =>
      'Your own crontab could not be read, so its jobs may be missing.';

  @override
  String jobsZoneRules(String zone) {
    return 'Cron times are in $zone, the server\'s time zone.';
  }

  @override
  String jobsZoneFixed(String offset, String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noZoneName': 'as it reported no time zone name',
      'unknownZone': 'as this device does not know its time zone',
      'other': 'as its time zone name and offset disagree',
    });
    return 'Cron times are at the server\'s offset now, $offset, $_temp0, so later DST changes do not show.';
  }

  @override
  String jobsTimerZone(String offset) {
    return 'Timer times are at the server\'s offset now, $offset; a DST change before a run does not show.';
  }

  @override
  String get jobsTimerZoneUtc =>
      'Timer times are in UTC, as the server\'s offset is not known yet.';

  @override
  String get jobsColumnJob => 'Job';

  @override
  String get jobsColumnSource => 'Source';

  @override
  String get jobsColumnSchedule => 'Schedule';

  @override
  String get jobsColumnNext => 'Next run';

  @override
  String jobsNextRun(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.MMMEd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String jobsRunInZone(String time, String zone) {
    return '$time in $zone';
  }

  @override
  String jobsNextRunAtOffset(DateTime time, String offset) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.MMMEd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return '$timeString $offset';
  }

  @override
  String jobsNextRunDst(String time) {
    return '$time (DST)';
  }

  @override
  String jobsRunTime(DateTime time, String offset) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMEd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return '$timeString $offset';
  }

  @override
  String jobsUtcOffset(String sign, DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.Hm(localeName);
    final String timeString = timeDateFormat.format(time);

    String _temp0 = intl.Intl.selectLogic(sign, {
      'zero': 'UTC',
      'minus': 'UTC−$timeString',
      'other': 'UTC+$timeString',
    });
    return '$_temp0';
  }

  @override
  String get jobsSourceOwnCrontab => 'Your crontab';

  @override
  String jobsSourceAsUser(String source, String user) {
    return '$source, as $user';
  }

  @override
  String get jobsSourceTimer => 'systemd timer';

  @override
  String get jobsTimerTriggersUnread =>
      'Triggers are not read in this version.';

  @override
  String get jobsDetailsWritten => 'As written';

  @override
  String get jobsDetailsStarts => 'Starts';

  @override
  String get jobsDetailsNextRuns => 'Next runs';

  @override
  String jobsScheduleCron(String schedule) {
    return 'Runs $schedule';
  }

  @override
  String jobsScheduleCronMacro(String macro) {
    String _temp0 = intl.Intl.selectLogic(macro, {
      'reboot': 'Runs when cron starts',
      'yearly': 'Runs once a year, at midnight on 1 January',
      'annually': 'Runs once a year, at midnight on 1 January',
      'monthly': 'Runs once a month, at midnight on the 1st',
      'weekly': 'Runs once a week, at midnight on Sunday',
      'daily': 'Runs every day at midnight',
      'midnight': 'Runs every day at midnight',
      'other': 'Runs every hour, on the hour',
    });
    return '$_temp0';
  }

  @override
  String jobsScheduleInZone(String schedule, String zone) {
    return '$schedule ($zone time)';
  }

  @override
  String jobsScheduleCalendar(String expression) {
    return 'On calendar $expression';
  }

  @override
  String jobsScheduleMonotonic(String base, String span) {
    String _temp0 = intl.Intl.selectLogic(base, {
      'active': '$span after the timer starts',
      'boot': '$span after boot',
      'startup': '$span after systemd starts',
      'unitActive': '$span after the job last started',
      'other': '$span after the job last finished',
    });
    return '$_temp0';
  }

  @override
  String jobsCronMinute(
    String shape,
    String items,
    int step,
    String first,
    String last,
  ) {
    String _temp0 = intl.Intl.selectLogic(shape, {
      'all': 'every minute',
      'step': 'every $step minutes',
      'rangeStep': 'every $step minutes from minute $first to $last',
      'value': 'at minute $items',
      'other': 'at minutes $items',
    });
    return '$_temp0';
  }

  @override
  String jobsCronHour(
    String shape,
    String items,
    int step,
    String first,
    String last,
  ) {
    String _temp0 = intl.Intl.selectLogic(shape, {
      'all': 'every hour',
      'step': 'every $step hours',
      'rangeStep': 'every $step hours from hour $first to $last',
      'value': 'during hour $items',
      'other': 'during hours $items',
    });
    return '$_temp0';
  }

  @override
  String jobsCronDayOfMonth(
    String shape,
    String items,
    int step,
    String first,
    String last,
  ) {
    String _temp0 = intl.Intl.selectLogic(shape, {
      'rangeStep': 'every $step days of the month from day $first to $last',
      'value': 'on day $items of the month',
      'other': 'on days $items of the month',
    });
    return '$_temp0';
  }

  @override
  String jobsCronMonth(
    String shape,
    String items,
    int step,
    String first,
    String last,
  ) {
    String _temp0 = intl.Intl.selectLogic(shape, {
      'step': 'every $step months',
      'rangeStep': 'every $step months from $first to $last',
      'other': 'in $items',
    });
    return '$_temp0';
  }

  @override
  String jobsCronDayOfWeek(
    String shape,
    String items,
    int step,
    String first,
    String last,
  ) {
    String _temp0 = intl.Intl.selectLogic(shape, {
      'step': 'every $step days of the week',
      'rangeStep': 'every $step days of the week from $first to $last',
      'other': 'on $items',
    });
    return '$_temp0';
  }

  @override
  String jobsCronHoursStepped(String first, String last, int step) {
    return 'during hours $first to $last in steps of $step';
  }

  @override
  String jobsCronTimes(String times) {
    return 'at $times';
  }

  @override
  String jobsCronRange(String first, String last) {
    return '$first to $last';
  }

  @override
  String jobsCronItemStep(int step, String first, String last) {
    return 'every $step from $first to $last';
  }

  @override
  String jobsCronDaysEither(String dom, String dow) {
    return '$dom or $dow';
  }

  @override
  String jobsCronDaysBoth(String dom, String dow) {
    return '$dom, but only $dow';
  }

  @override
  String jobsPhrasePair(String first, String second) {
    return '$first, $second';
  }

  @override
  String jobsListPair(String first, String second) {
    return '$first and $second';
  }

  @override
  String jobsListMore(String first, String rest) {
    return '$first, $rest';
  }

  @override
  String jobsSpanDays(int days) {
    return '$days d';
  }

  @override
  String jobsSpanHours(int hours) {
    return '$hours h';
  }

  @override
  String jobsSpanMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String jobsSpanSeconds(num seconds) {
    final intl.NumberFormat secondsNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String secondsString = secondsNumberFormat.format(seconds);

    return '$secondsString s';
  }

  @override
  String jobsSpanPair(String first, String second) {
    return '$first $second';
  }

  @override
  String jobsRunsUnknown(String reason, int limit, int years) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'reboot': 'Runs when cron starts, not at a time.',
      'unparsed': 'The schedule does not parse, so its runs are unknown.',
      'timeZoneUnresolved':
          'This device does not know the CRON_TZ zone, so its runs are unknown.',
      'serverZoneUnknown':
          'The server\'s time zone is not known yet, so its runs are unknown.',
      'noRunInHorizon': 'No run falls in the next $years years.',
      'notEvaluated':
          'Runs are worked out for the first $limit cron lines only.',
      'anacron':
          'anacron runs this directory; its timing is not shown in this version.',
      'paused': 'Paused: cron skips this job until it is resumed.',
      'other': 'No cron line runs this directory.',
    });
    return '$_temp0';
  }

  @override
  String jobsNextRunUnknown(String reason, int years) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'reboot': 'At cron start',
      'unparsed': 'Unreadable schedule',
      'timeZoneUnresolved': 'Zone not known',
      'serverZoneUnknown': 'Zone not known yet',
      'noRunInHorizon': 'None in $years years',
      'notEvaluated': 'Not worked out',
      'anacron': 'Timed by anacron',
      'paused': 'Paused',
      'other': 'Not run',
    });
    return '$_temp0';
  }

  @override
  String jobsRunGap(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.jm(localeName);
    final String timeString = timeDateFormat.format(time);

    return '$timeString does not occur that day because of the DST change, so the job runs at the change.';
  }

  @override
  String jobsRunOverlap(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.jm(localeName);
    final String timeString = timeDateFormat.format(time);

    return '$timeString occurs twice at this DST change; the job runs at the first only.';
  }

  @override
  String get jobsRunNearTransition =>
      'Within an hour of a DST change: the server\'s own zone data may move this run by an hour.';

  @override
  String jobsTimerRandomDelay(String span) {
    return 'Each run starts up to $span late, at random (RandomizedDelaySec).';
  }

  @override
  String get jobsTimerOneRun =>
      'systemd\'s timer list gives only the next run, so later runs are not shown.';

  @override
  String get jobsCalendarOneRun =>
      'systemd before version 242 lists only the next run, so later runs are not shown.';

  @override
  String get hostKeyUnknownTitle => 'Unknown host key';

  @override
  String get hostKeyChangedTitle => 'HOST KEY CHANGED';

  @override
  String hostKeyChangedWarning(String host) {
    return 'The key for $host does not match the one you previously trusted. This can mean a man-in-the-middle attack. Only continue if you know why the key changed.';
  }

  @override
  String promptEndpoint(String host, int port) {
    return '$host:$port';
  }

  @override
  String promptEndpointWithUser(String user, String host, int port) {
    return '$user@$host:$port';
  }

  @override
  String get hostKeyFingerprintLabel => 'Fingerprint';

  @override
  String get hostKeyNewKeyLabel => 'New key';

  @override
  String get hostKeyPreviousLabel => 'Previously trusted';

  @override
  String get hostKeyCancel => 'Cancel';

  @override
  String get hostKeyTrustConnect => 'Trust and connect';

  @override
  String get hostKeyTrustNewKey => 'Trust the new key';

  @override
  String get keyboardTitle => 'Authentication';

  @override
  String get keyboardRequestFrom => 'Request from';

  @override
  String get keyboardServerMessage => 'Server message';

  @override
  String get keyboardShowAnswer => 'Show answer';

  @override
  String get keyboardHideAnswer => 'Hide answer';

  @override
  String get keyboardCancel => 'Cancel';

  @override
  String get keyboardSubmit => 'Submit';

  @override
  String get connectRejectedNoLoginName =>
      'You can\'t connect to this server yet: your SSH config names no user for it or for a jump host it goes through, and your login name could not be read from this device. Add a User line to your SSH config, then import it again.';

  @override
  String get connectRejectedAddressOnly =>
      'You can\'t connect to this server yet: it comes from an earlier import that kept only its address. Import your SSH config again to connect.';

  @override
  String get connectRejectedEndpointNotConfirmed =>
      'You can\'t connect to this server yet: its address comes from your sync account and isn\'t confirmed on this device, or it changed since you confirmed it. Choose Review over the server list to check and confirm it.';

  @override
  String endpointsPendingNotice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count synced servers wait for you to confirm their addresses.',
      one: '$count synced server waits for you to confirm its address.',
    );
    return '$_temp0';
  }

  @override
  String get endpointsReview => 'Review';

  @override
  String get endpointsTitle => 'Confirm server addresses';

  @override
  String get endpointsBody =>
      'These servers come from your sync account. Klabautermann connects only to addresses you confirm on this device, so an address changed on another device cannot receive your sign-in unnoticed. Check each host, port, user and jump route before you confirm it.';

  @override
  String get endpointsSearch => 'Search servers';

  @override
  String endpointsRoute(String route) {
    return 'via $route';
  }

  @override
  String get endpointsRouteSeparator => ' → ';

  @override
  String get endpointsChanged => 'Changed since you confirmed it';

  @override
  String get endpointsNoMatch => 'No servers match your search.';

  @override
  String get endpointsNoneLeft =>
      'Every synced server\'s address is confirmed on this device.';

  @override
  String get endpointsConfirmAllShown => 'Confirm all shown';

  @override
  String endpointsConfirmSelected(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Confirm $count servers',
      one: 'Confirm $count server',
      zero: 'Confirm selected',
    );
    return '$_temp0';
  }

  @override
  String endpointsConfirmed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Confirmed $count server addresses.',
      one: 'Confirmed $count server address.',
    );
    return '$_temp0';
  }

  @override
  String get endpointsStillPending =>
      'Some servers still need confirming: confirm the jump hosts they go through too.';

  @override
  String get endpointsFailed =>
      'The confirmation could not be saved on this device, so these servers stay unconfirmed. Try again.';

  @override
  String get settingsAccessibilityTitle => 'Accessibility';

  @override
  String get settingsCadenceTitle => 'Refresh';

  @override
  String get settingsCadenceLabel => 'How often servers are read';

  @override
  String settingsCadencePreset(String preset) {
    String _temp0 = intl.Intl.selectLogic(preset, {
      'automatic': 'Automatic',
      'desktop': 'Desktop',
      'phone': 'Phone',
      'other': 'Cellular saver',
    });
    return '$_temp0';
  }

  @override
  String settingsCadenceDetail(String preset) {
    String _temp0 = intl.Intl.selectLogic(preset, {
      'automatic':
          'Desktop rates on a computer, phone rates on a phone or tablet.',
      'desktop': 'Fleet rows every 5 s, the open server every 2 s.',
      'phone':
          'Fleet rows every 10 s, the open server every 3 s, to save battery.',
      'other':
          'Fleet rows every 30 s, the open server every 10 s; timers, cron jobs, temperatures, GPUs and disk health are read once when you open them.',
    });
    return '$_temp0';
  }

  @override
  String get settingsCadenceNotSaved =>
      'The refresh rate changed but could not be saved. It lasts until Klabautermann quits.';

  @override
  String get settingsCadenceNotChanged =>
      'The refresh rate could not be changed.';

  @override
  String get settingsAnnounceBands => 'Announce threshold changes';

  @override
  String get settingsAnnounceBandsDetail =>
      'While a server\'s Overview shows, your screen reader hears when CPU, memory or a disk crosses into or out of its warning or critical level. Values that refresh every few seconds are never read out.';

  @override
  String get settingsThresholdsTitle => 'Usage bands';

  @override
  String get settingsThresholdsDetail =>
      'The levels the fleet rows, the Overview and its health card judge each metric by. Careful shows an info icon, warning and critical also take their colour, and only warning and critical are announced.';

  @override
  String get settingsThresholdCareful => 'Careful from';

  @override
  String get settingsThresholdWarning => 'Warning from';

  @override
  String get settingsThresholdCritical => 'Critical from';

  @override
  String get settingsThresholdPercentSuffix => '%';

  @override
  String get settingsThresholdsInvalid =>
      'Each level must be a whole percent from 1 to 100, and each one higher than the one before.';

  @override
  String get settingsThresholdDefault => 'Default';

  @override
  String get settingsThresholdCancel => 'Cancel';

  @override
  String get settingsThresholdSave => 'Save';

  @override
  String get settingsThresholdsNotSaved =>
      'The levels changed but could not be saved. They last until Klabautermann quits.';

  @override
  String get settingsThresholdsNotChanged => 'The levels could not be changed.';

  @override
  String settingsThresholdMetric(String metric) {
    String _temp0 = intl.Intl.selectLogic(metric, {
      'cpu': 'CPU',
      'memory': 'Memory',
      'other': 'Disk',
    });
    return '$_temp0';
  }

  @override
  String settingsThresholdLevels(
    String careful,
    String warning,
    String critical,
  ) {
    return 'Careful from $careful, warning from $warning, critical from $critical';
  }

  @override
  String get settingsAnnounceNotSaved =>
      'The setting changed, but it could not be saved, so it will not be kept after a restart.';

  @override
  String get settingsAnnounceNotChanged => 'The setting could not be changed.';

  @override
  String get appLockTitle => 'Klabautermann is locked';

  @override
  String get appLockDetail =>
      'Unlock with this device\'s passcode, PIN or biometrics. Connections already open keep running.';

  @override
  String get settingsWindowLocked =>
      'Unlock it in its main window to change settings.';

  @override
  String get appLockUnlock => 'Unlock';

  @override
  String get appLockFailed =>
      'Authentication failed or was cancelled. Try again.';

  @override
  String get appLockUnavailable =>
      'This device has no passcode, PIN or biometrics to ask for. Set one up, then try again.';

  @override
  String get appLockReason => 'Unlock Klabautermann';

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
    return 'Ask for this device\'s passcode, PIN or biometrics when Klabautermann opens and after $_temp0 in the background. Locking turns admin mode off on every server.';
  }

  @override
  String get settingsAppLockUnsupported =>
      'This platform has no device authentication Klabautermann can ask for.';

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
  String get settingsSyncSecretsTitle => 'Passwords and keys';

  @override
  String get settingsSyncSecrets => 'Sync saved passwords & keys';

  @override
  String get settingsSyncSecretsDetail =>
      'Only includes servers where credential sync is also enabled.';

  @override
  String get settingsSyncSecretsNotSaved =>
      'The setting changed, but it could not be saved, so it will not be kept after a restart.';

  @override
  String get settingsSyncSecretsNotChanged =>
      'The setting could not be changed.';

  @override
  String get settingsPinPublicationTitle => 'Host keys';

  @override
  String settingsPinPublication(String release) {
    return 'Every device runs Séance $release or later';
  }

  @override
  String get settingsPinPublicationDetail =>
      'While on, host keys you confirm are shared with your other devices, so they can check a server the first time they connect. Turning it off stops sharing; keys already shared stay.';

  @override
  String get settingsPinPublicationNotChanged =>
      'The host key setting could not be changed.';

  @override
  String get settingsAboutTitle => 'About';

  @override
  String get settingsMonitorTitle => 'Monitoring';

  @override
  String settingsMonitorDetail(int limit) {
    return 'Monitored servers are read continuously while Klabautermann is open, and their rows show CPU, memory and disk. A server can be monitored once its endpoint is confirmed and it signs in with an SSH agent or a key file, without asking you. Up to $limit servers.';
  }

  @override
  String settingsMonitorCount(int monitored, int limit) {
    return '$monitored of $limit servers monitored';
  }

  @override
  String get settingsMonitorEmpty =>
      'No servers yet. Servers you sync or import show here.';

  @override
  String overviewBandAnnouncement(String metric, String value, String band) {
    String _temp0 = intl.Intl.selectLogic(band, {
      'warning': 'warning level',
      'critical': 'critical level',
      'other': 'back to normal',
    });
    return '$metric $value: $_temp0';
  }

  @override
  String overviewBandDisk(String mount) {
    return 'Disk $mount';
  }

  @override
  String overviewBandInodes(String mount) {
    return 'Inodes on $mount';
  }

  @override
  String get overviewHealthTitle => 'Health';

  @override
  String get overviewHealthUnitsWaiting =>
      'Waiting for the first check of failed units.';

  @override
  String overviewHealthUnitsCheckFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'missing':
          'The last check of failed units could not run: this server lacks systemctl.',
      'denied': 'The server refused the last check of failed units.',
      'timeout': 'The last check of failed units took too long.',
      'other': 'The last check of failed units failed.',
    });
    return '$_temp0';
  }

  @override
  String get overviewDisksWaiting => 'Waiting for the first disk reading.';

  @override
  String overviewHealthDisksUnknown(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'missing': 'Disk use is unknown: this server lacks df.',
      'denied': 'Disk use is unknown: the server refused the reading.',
      'timeout': 'Disk use is unknown: the reading did not finish in time.',
      'other': 'Disk use is unknown: the reading failed.',
    });
    return '$_temp0';
  }

  @override
  String overviewHealthDisksOk(String level) {
    return 'No disk has $level or more of its space or inodes used.';
  }

  @override
  String overviewHealthDiskSpace(String mount, String percent, String band) {
    String _temp0 = intl.Intl.selectLogic(band, {
      'critical': 'critical',
      'other': 'warning',
    });
    return '$mount: $percent of its space used, $_temp0';
  }

  @override
  String overviewHealthDiskInodes(String mount, String percent, String band) {
    String _temp0 = intl.Intl.selectLogic(band, {
      'critical': 'critical',
      'other': 'warning',
    });
    return '$mount: $percent of its inodes used, $_temp0';
  }

  @override
  String overviewHealthAnnouncements(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'on': 'Threshold announcements: on',
      'other': 'Threshold announcements: off',
    });
    return '$_temp0';
  }

  @override
  String get overviewHealthAnnouncementsHint => 'Opens Settings';

  @override
  String get overviewDiskSize => 'Size';

  @override
  String overviewDisksMore(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more mounts are on the System tab.',
      one: '1 more mount is on the System tab.',
    );
    return '$_temp0';
  }

  @override
  String get overviewHostTitle => 'Host';

  @override
  String get overviewHostWaiting =>
      'Waiting for the operating system and kernel.';

  @override
  String overviewHealthContainersUnhealthy(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString unhealthy containers',
      one: '1 unhealthy container',
      zero: 'No unhealthy containers',
    );
    return '$_temp0';
  }

  @override
  String overviewHealthContainer(String name, String status) {
    return '$name: $status';
  }

  @override
  String get overviewDockerTitle => 'Docker';

  @override
  String get overviewDockerReading => 'Reading the containers and images.';

  @override
  String overviewDockerStale(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'These figures are from $timeString. The Docker engine cannot be reached now, so they may be out of date.';
  }

  @override
  String overviewDockerListFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'daemonError':
          'The engine refused or failed to list the containers or images.',
      'connectionFailed':
          'The connection to the engine failed while listing the containers or images.',
      'other': 'The containers or images could not be listed.',
    });
    return '$_temp0';
  }

  @override
  String overviewDockerCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String get overviewDockerRunning => 'Running';

  @override
  String get overviewDockerPaused => 'Paused';

  @override
  String get overviewDockerStopped => 'Stopped';

  @override
  String get overviewDockerUnhealthy => 'Unhealthy';

  @override
  String get overviewDockerImages => 'Images';

  @override
  String get overviewDockerImagesInUse => 'Images in use';

  @override
  String get overviewDockerDangling => 'Dangling images';

  @override
  String get overviewDockerReclaimable => 'Reclaimable space';

  @override
  String get overviewDockerNotMeasured => 'Not measured';

  @override
  String get overviewDockerMeasureNote =>
      'Measuring asks the engine to add up every image, container, volume and build cache, which can take a while on large hosts.';

  @override
  String get overviewDockerMeasure => 'Measure disk use';

  @override
  String get overviewDockerMeasureAgain => 'Measure again';

  @override
  String get overviewDockerMeasuring =>
      'Measuring disk use. This can take a while on large hosts.';

  @override
  String overviewDockerMeasured(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'Measured at $timeString.';
  }

  @override
  String overviewDockerMeasureFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'linkUnavailable':
          'Disk use could not be measured: the server is not connected.',
      'profileUnknown':
          'Disk use could not be measured: the server has not been checked yet.',
      'endpointUnavailable':
          'Disk use could not be measured: the Docker engine cannot be reached.',
      'daemonError': 'The engine refused or failed to measure its disk use.',
      'connectionFailed':
          'The connection to the engine failed or timed out while measuring disk use.',
      'cancelled':
          'The measurement stopped because the connection to the engine changed. Measure again to retry.',
      'other': 'Disk use could not be measured.',
    });
    return '$_temp0';
  }

  @override
  String get syncSignInTooltip =>
      'Sign in to your Séance account to list its servers';

  @override
  String syncNowTooltip(String username, String host) {
    return 'Synchronize with $host as $username';
  }

  @override
  String get syncSignInTitle => 'Sign in to your Séance account';

  @override
  String get syncSignInBody =>
      'Klabautermann lists the servers you keep in Séance. Sign in with the server address, account name, password and encryption passphrase you use in Séance.';

  @override
  String get syncServerAddress => 'Server address';

  @override
  String get syncAccountName => 'Account name';

  @override
  String get syncPassword => 'Password';

  @override
  String get syncPassphrase => 'Encryption passphrase';

  @override
  String get syncPassphraseHelper => 'Often the same as your password.';

  @override
  String get syncConfirmTitle => 'Before you sign in';

  @override
  String get syncFleetAssertion =>
      'Every device that uses this account runs Séance 0.9.0 or later.';

  @override
  String get syncFleetAssertionDetail =>
      'Older Séance releases can mistake records from other apps for servers.';

  @override
  String syncPinPublicationAssertion(String release) {
    return 'Every device on this account runs Séance $release or later';
  }

  @override
  String get syncPinPublicationAssertionDetail =>
      'Then host keys you confirm are shared with them. Older releases accept a shared key without checking it.';

  @override
  String get syncDisclosureAccountKey =>
      'Your encryption passphrase opens the records of every app on this account, Séance and Poltergeist included.';

  @override
  String get syncDisclosure =>
      'Klabautermann publishes only the servers you add, edit or delete here, with their passwords or keys when you let them sync, and each server\'s read-only switch and marks. It publishes no host keys.';

  @override
  String get syncSignInAction => 'Sign in';

  @override
  String get syncSignedIn =>
      'Signed in. Your Séance servers are now in the fleet.';

  @override
  String get syncPassphraseUnverified =>
      'No record on the account has confirmed your encryption passphrase yet. If servers are missing, sign in again with the passphrase you use in Séance.';

  @override
  String get syncValidationServerAddress =>
      'Enter the server address, starting with https:// or http://.';

  @override
  String get syncValidationUrlCredentials =>
      'Leave your account name and password out of the server address.';

  @override
  String get syncValidationAccountName => 'Enter your account name.';

  @override
  String get syncValidationPassword => 'Enter your password.';

  @override
  String get syncValidationPassphrase => 'Enter your encryption passphrase.';

  @override
  String get syncFailedDirectoryShared =>
      'Sync is off because Klabautermann could not check whether another copy of it is running.';

  @override
  String get syncFailedNoDeviceId =>
      'Sync is off because this device\'s settings file could not be read or saved.';

  @override
  String get syncFailedOtherAccount =>
      'This device is already signed in to another account.';

  @override
  String get syncFailedKdfDowngrade =>
      'The server asked for weaker password protection than Klabautermann accepts, so nothing was sent. The server may have been tampered with.';

  @override
  String get syncFailedCredentials =>
      'The server did not accept this account name and password.';

  @override
  String get syncFailedSession =>
      'The server no longer accepts this device\'s sign-in. Sign in again.';

  @override
  String get syncFailedUnreachable =>
      'The sync server could not be reached. Check the address and your connection.';

  @override
  String get syncFailedServer =>
      'The sync server reported an error. Try again later.';

  @override
  String get syncFailedKeystore =>
      'The system keychain could not store or hand over the sync keys. Unlock it and try again.';

  @override
  String get syncFailedStore =>
      'A sync file could not be saved, so the sign-in was not kept.';

  @override
  String get syncFailed => 'Sync failed.';

  @override
  String syncFileRecovered(String fileName, String keptAs) {
    return 'The sync file $fileName could not be read and was cleared. The old file is kept as $keptAs.';
  }

  @override
  String syncFileLeftAsIs(String fileName) {
    return 'The sync file $fileName could not be read, so it was left as it is. Sync changes will not be kept after a restart.';
  }

  @override
  String syncFileNewer(String fileName) {
    return 'The sync file $fileName was saved by a newer version of Klabautermann. Sync changes will not be kept after a restart.';
  }

  @override
  String get settingsSafetyReadOnly => 'Read-only everywhere';

  @override
  String get settingsSafetyReadOnlyDetail =>
      'While this is on, no server takes an action and every action is hidden. Monitoring, logs and other reads work as before, so it is safe for screen sharing.';

  @override
  String get settingsSafetyAdminExpiry => 'Admin mode ends after';

  @override
  String settingsSafetyAdminExpiryMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get settingsSafetyAdminExpiryDetail =>
      'Admin mode turns off after this long without an action. It also turns off when the link drops, and on a phone when Klabautermann goes to the background.';

  @override
  String get settingsSafetyMarksTitle => 'Marked protected';

  @override
  String get settingsSafetyMarksDetail =>
      'An action on a target you marked protected asks you to type its name first. Marks stay on this device.';

  @override
  String get settingsSafetyMarksEmpty =>
      'You have not marked anything protected.';

  @override
  String settingsSafetyMark(String target, String server) {
    return '$target on $server';
  }

  @override
  String settingsSafetyMarkRemove(String target) {
    return 'Remove the mark on $target';
  }

  @override
  String get settingsSafetyNotSaved =>
      'The setting changed, but it could not be saved, so it will not be kept after a restart.';

  @override
  String get settingsSafetyNotChanged => 'The setting could not be changed.';

  @override
  String get serverSafetyMenu => 'Safety';

  @override
  String get serverAllowActions => 'Allow actions';

  @override
  String get serverReadOnly => 'Read-only';

  @override
  String get serverHostAuditLine => 'Log actions on the server';

  @override
  String get serverObserveOnly =>
      'Observe only: Klabautermann reads this server and changes nothing. To act on it, turn on Allow actions in the Safety menu.';

  @override
  String get serverReadOnlyNotice =>
      'Read-only: actions on this server are hidden.';

  @override
  String credentialTitle(String label) {
    return 'Password for $label';
  }

  @override
  String get credentialExplanation =>
      'Saved only if you choose to: on this device, in its encrypted vault, and used for this server from now on.';

  @override
  String get credentialPassword => 'Password';

  @override
  String get credentialSaveInVault => 'Save in vault';

  @override
  String get credentialCancel => 'Cancel';

  @override
  String get credentialConnect => 'Connect';

  @override
  String elevationTitle(String host) {
    return 'Admin password for $host';
  }

  @override
  String elevationDetail(String user) {
    return 'Klabautermann asks sudo for root as $user with this password. It is kept in memory only while admin mode is on, and never saved.';
  }

  @override
  String get elevationRetry => 'That password did not work. Try again.';

  @override
  String get elevationPassword => 'Password';

  @override
  String get elevationCancel => 'Cancel';

  @override
  String get elevationTurnOn => 'Turn on';

  @override
  String get adminChipOff => 'Admin mode';

  @override
  String get adminChipStarting => 'Turning on admin mode';

  @override
  String adminChipOn(String time) {
    return 'Admin mode until $time';
  }

  @override
  String get adminChipReadOnly =>
      'Admin mode is not available while the server is read-only.';

  @override
  String get adminOnNotice =>
      'Admin mode is on: actions you confirm here run as root.';

  @override
  String adminFailure(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'observeOnly':
          'Admin mode needs Allow actions turned on for this server.',
      'readOnly': 'Admin mode is not available while this server is read-only.',
      'noLink': 'Admin mode needs a connection to this server.',
      'notProbed':
          'Klabautermann has not checked this server yet. Try admin mode again in a moment.',
      'unavailable':
          'This server offers no way to become root that Klabautermann can use.',
      'ttyRequired':
          'This server lets you become root only from a terminal, so admin mode is not available.',
      'notInSudoers': 'Your account on this server may not use sudo.',
      'wrongPassword':
          'The password was refused three times, so admin mode stayed off.',
      'cancelled': 'Admin mode stayed off because no password was given.',
      'other': 'Admin mode could not be turned on.',
    });
    return '$_temp0';
  }

  @override
  String adminEnded(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'inactivity': 'Admin mode ended after a while without an action.',
      'background':
          'Admin mode ended when Klabautermann went to the background.',
      'linkLost': 'Admin mode ended when the connection dropped.',
      'serverRemoved': 'Admin mode ended because the server changed.',
      'other': 'Admin mode ended.',
    });
    return '$_temp0';
  }

  @override
  String get actionPreviewTitle => 'Review before it runs';

  @override
  String actionPreviewTarget(String target) {
    return 'Target: $target';
  }

  @override
  String get actionPreviewSteps => 'What will run';

  @override
  String get actionPreviewRoot => 'root';

  @override
  String get actionPreviewRootDetail =>
      'This step runs as root through admin mode.';

  @override
  String actionPreviewRunner(String identity) {
    return 'Runs as $identity';
  }

  @override
  String actionPreviewRunnerEngine(String identity, String engine) {
    return 'Runs as $identity through $engine';
  }

  @override
  String actionPreviewCredentials(String credentials) {
    String _temp0 = intl.Intl.selectLogic(credentials, {
      'session': 'Signs in with this connection\'s own sign-in.',
      'adminPassword': 'Uses the admin mode password.',
      'passwordless': 'Needs no password.',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String get actionPreviewHostWrites => 'What it leaves on the server';

  @override
  String actionPreviewHostWrite(String row) {
    String _temp0 = intl.Intl.selectLogic(row, {
      'userOperationRecords': 'An operation record in your home directory',
      'rootOperationRecords':
          'An operation record under /var/lib/klabautermann',
      'transientUnit': 'A transient systemd unit, gone when it ends',
      'engineState': 'The container engine\'s own state',
      'loginRecords': 'Login records, as every SSH command leaves',
      'editTarget': 'The file or crontab you edited',
      'editTempFile':
          'A temporary copy beside the file, renamed over it or removed',
      'userBackups': 'A backup in your Klabautermann backups folder',
      'rootBackups': 'A backup under /var/lib/klabautermann/backups',
      'footprintManifest': 'The list of what Klabautermann keeps on the server',
      'packageLists': 'The package manager\'s cached package lists',
      'auditSyslog':
          'One line in the system log naming this action and this device',
      'other': 'A change on the server',
    });
    return '$_temp0';
  }

  @override
  String actionPreviewImpact(String kind, int count) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'dropsSession': 'This can drop your connection to the server.',
      'stopsContainers': 'This stops $count running containers.',
      'removesVolumes':
          'This deletes the container\'s volumes and the data in them.',
      'forcesImageInUse': '$count containers still use this image.',
      'deletesVolumeData': 'This deletes the volume and the data in it.',
      'interruptsTarget': 'This interrupts what the target is doing.',
      'restartsHost':
          'This restarts the server: everything on it stops, and the connection drops until it is back.',
      'stopsHost':
          'This turns the server off: everything on it stops, and it stays off until someone starts it.',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String actionPreviewProtected(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'builtIn': 'Protected: Klabautermann always protects this target.',
      'sessionPath':
          'Protected: your connection to the server runs through it.',
      'publishesSessionPort':
          'Protected: it publishes the SSH port or a VPN port.',
      'userMarked': 'Protected: you marked it protected.',
      'other': 'Protected.',
    });
    return '$_temp0';
  }

  @override
  String actionPreviewOwnership(String manager) {
    return 'Managed by $manager. Acting on it here can conflict with $manager.';
  }

  @override
  String get actionPreviewDetached =>
      'Runs on the server and continues if you leave or the connection drops. Its result shows under Operations.';

  @override
  String get actionPreviewDetachedIos =>
      'Runs on the server and continues if you leave the app or the connection drops. Its result shows under Operations when you come back.';

  @override
  String actionPreviewPruneRemoves(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Removes $count objects',
      one: 'Removes 1 object',
    );
    return '$_temp0';
  }

  @override
  String actionPreviewPruneFrees(String size) {
    return 'Frees $size';
  }

  @override
  String actionPreviewPruneItem(String name, String size) {
    return '$name ($size)';
  }

  @override
  String get actionPreviewPruneKeeps => 'Kept';

  @override
  String actionPreviewPruneKept(String name, String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'inUse': 'in use',
      'builtin': 'the engine\'s own',
      'other': 'kept',
    });
    return '$name: $_temp0';
  }

  @override
  String get actionPreviewOrphans =>
      'Containers the stack\'s files no longer name';

  @override
  String get actionPreviewRemoveOrphans => 'Also remove these containers';

  @override
  String actionPreviewWarning(String warning) {
    String _temp0 = intl.Intl.selectLogic(warning, {
      'profileGatedServices':
          'Some running services are enabled only by a compose profile, which Klabautermann cannot see. The redeploy leaves them as they are.',
      'profilesUnknown':
          'The compose CLI could not list every profile\'s services, so some of these containers may belong to a service a profile enables.',
      'mayDieAtLogout':
          'This server ends your processes when you log out, which can stop the operation before it finishes.',
      'unitNotVerified':
          'This server\'s systemd is not known to be version 250 or later, so the unit file is not checked before it is replaced.',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String actionStartedOnServer(String target) {
    return 'Started on the server: $target';
  }

  @override
  String get actionPreviewDanger => 'Warnings';

  @override
  String actionPreviewFinding(String severity, String explanation) {
    String _temp0 = intl.Intl.selectLogic(severity, {
      'critical': 'Critical',
      'other': 'Warning',
    });
    return '$_temp0: $explanation';
  }

  @override
  String actionConfirmNames(String target) {
    return 'This acts on $target.';
  }

  @override
  String actionConfirmType(String target) {
    return 'Type $target to confirm';
  }

  @override
  String get actionConfirmRun => 'Run';

  @override
  String get actionConfirmCancel => 'Cancel';

  @override
  String actionRunning(String target) {
    return 'Running on $target';
  }

  @override
  String actionSucceeded(String target) {
    return 'Done: $target';
  }

  @override
  String actionFailed(String target, String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'there is no connection to the server.',
      'revalidation': 'the target changed since the preview.',
      'elevationRefused': 'admin mode refused the step.',
      'stepFailed': 'a step failed.',
      'transport': 'the connection failed during the run.',
      'unsupportedStep': 'this version cannot run one of its steps.',
      'adminRequired': 'it needs admin mode.',
      'launchFailed': 'its operation could not be started on the server.',
      'other': 'it failed.',
    });
    return '$target did not finish: $_temp0';
  }

  @override
  String actionFailedPlain(String target) {
    return '$target did not finish.';
  }

  @override
  String actionCancelled(String target) {
    return '$target was cancelled.';
  }

  @override
  String actionRefused(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notImplemented': 'This action is not available yet.',
      'unknownPlan': 'The preview is out of date. Open it again.',
      'expiredPlan': 'The preview is out of date. Open it again.',
      'stalePlan': 'The connection changed since the preview. Open it again.',
      'confirmationMismatch': 'The confirmation did not match.',
      'observeOnly': 'Turn on Allow actions for this server first.',
      'readOnly': 'The server is read-only.',
      'adminRequired': 'Turn on admin mode first.',
      'invalidTarget': 'This target cannot be acted on.',
      'targetChanged': 'The target changed. Look again before acting.',
      'noLink': 'Connect to the server first.',
      'engineUnavailable': 'The server\'s container engine cannot be reached.',
      'imageInUse':
          'Containers use this image. Remove them first, or force the removal.',
      'volumeInUse':
          'A container mounts this volume. Remove the container first.',
      'volumeExists': 'A volume with this name already exists.',
      'networkInUse':
          'A container is on this network. Stop or disconnect it first.',
      'builtinNetwork':
          'This is one of the engine\'s own networks, which stay.',
      'nothingToPrune': 'There is nothing to prune.',
      'dependencyCycle':
          'The stack\'s services depend on each other in a loop, so there is no order to act in.',
      'stackManaged': 'A manager deploys this stack. Redeploy it there.',
      'stackUnverified':
          'The stack\'s files are not verified as its source, so it cannot be redeployed from them.',
      'legacyComposeOnly':
          'Only the legacy docker-compose is installed, which Klabautermann does not run.',
      'sudoRightMissing':
          'This needs root, and your sudo rule allows only docker.',
      'other': 'The action was refused.',
    });
    return '$_temp0';
  }

  @override
  String get processTerminate => 'Terminate';

  @override
  String get processKill => 'Kill';

  @override
  String get processSendSignal => 'Send signal';

  @override
  String processSignalName(String name) {
    return 'SIG$name';
  }

  @override
  String get unitStart => 'Start';

  @override
  String get unitStop => 'Stop';

  @override
  String get unitRestart => 'Restart';

  @override
  String get unitReload => 'Reload';

  @override
  String get adminTurnOn => 'Turn on admin mode';

  @override
  String get dockerContainerStart => 'Start';

  @override
  String get dockerContainerStop => 'Stop';

  @override
  String get dockerContainerRestart => 'Restart';

  @override
  String get dockerContainerPause => 'Pause';

  @override
  String get dockerContainerUnpause => 'Unpause';

  @override
  String get dockerContainerKill => 'Kill';

  @override
  String get dockerContainerRemove => 'Remove';

  @override
  String get dockerContainerRemoveVolumes => 'Remove with volumes';

  @override
  String get dockerImageRemove => 'Remove';

  @override
  String get dockerImageForceRemove => 'Force remove';

  @override
  String get dockerStackStart => 'Start';

  @override
  String get dockerStackStop => 'Stop';

  @override
  String get dockerStackRestart => 'Restart';

  @override
  String get dockerActions => 'Actions';

  @override
  String jobsBadged(String text, String badge) {
    return '$text, $badge';
  }

  @override
  String get jobsPaused => 'Paused';

  @override
  String get jobsPausedDetail =>
      'Paused: cron skips this line until it is resumed.';

  @override
  String jobsManagedBy(String manager) {
    String _temp0 = intl.Intl.selectLogic(manager, {
      'dokku': 'Managed by Dokku',
      'coolify': 'Managed by Coolify',
      'dokploy': 'Managed by Dokploy',
      'runtipi': 'Managed by Runtipi',
      'other': 'Managed by another tool',
    });
    return '$_temp0';
  }

  @override
  String jobsManagedDetail(String manager) {
    String _temp0 = intl.Intl.selectLogic(manager, {
      'dokku': 'Dokku',
      'coolify': 'Coolify',
      'dokploy': 'Dokploy',
      'runtipi': 'Runtipi',
      'other': 'Another tool',
    });
    return '$_temp0 manages this line. Change it there; a change here may be overwritten.';
  }

  @override
  String get jobsLastRun => 'Last run';

  @override
  String get jobsLastRunReading => 'Reading…';

  @override
  String get jobsLastRunNever => 'Never triggered.';

  @override
  String get jobsLastRunSucceeded => 'It succeeded.';

  @override
  String jobsLastRunExited(String result, int status) {
    return 'It ended as $result, exit status $status.';
  }

  @override
  String jobsLastRunEnded(String result) {
    return 'It ended as $result.';
  }

  @override
  String get jobsLastRunNoStatus =>
      'When cron started it; cron logs no exit status.';

  @override
  String jobsLastRunNotLogged(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Not among the $count newest job starts cron logged.',
      one: 'Not among the 1 newest job start cron logged.',
      zero: 'cron logged no job starts that can be read.',
    );
    return '$_temp0';
  }

  @override
  String jobsLastRunFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Connect to the server to read the last run.',
      'invalidTarget': 'This job\'s last run cannot be read.',
      'other': 'The last run could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get jobsCronRunRunning => 'Running…';

  @override
  String get jobsCronRunSucceeded => 'It finished with exit status 0.';

  @override
  String jobsCronRunExited(int status) {
    return 'It finished with exit status $status.';
  }

  @override
  String get jobsCronRunNoOutput => 'It printed nothing.';

  @override
  String get jobsCronRunTruncated =>
      'The output was longer than this; the rest was dropped.';

  @override
  String get jobsRunNow => 'Run now';

  @override
  String get jobsPause => 'Pause';

  @override
  String get jobsResume => 'Resume';

  @override
  String get jobsPauseLineChanged =>
      'The crontab no longer holds this line as shown. Wait for the next reading and try again.';

  @override
  String jobsRunOutputTitle(String unit) {
    return 'Output of $unit';
  }

  @override
  String get jobsRunOutputClose => 'Close output';

  @override
  String jobsSourceUserCrontab(String user) {
    return '$user\'s crontab';
  }

  @override
  String get jobsSourceMine => 'Yours and the system\'s';

  @override
  String get jobsSourceOtherUsers => 'Other users';

  @override
  String get jobsOtherUsersReading => 'Reading other users\' crontabs.';

  @override
  String get jobsOtherUsersRefresh => 'Read again';

  @override
  String get jobsOtherUsersEmpty => 'No other user has a crontab.';

  @override
  String jobsOtherUsersFailure(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'Other users\' crontabs need a connection to the server.',
      'adminRequired': 'Other users\' crontabs need admin mode.',
      'elevationRefused': 'Admin mode could not read the crontabs.',
      'noSpool': 'This server keeps no crontab spool.',
      'spoolDenied': 'Even admin mode may not list the crontab spool.',
      'unreadable': 'The crontab spool could not be read.',
      'transport': 'The connection failed while reading.',
      'other': 'Other users\' crontabs could not be read.',
    });
    return '$_temp0';
  }

  @override
  String jobsOtherUsersUnreadable(String users) {
    return 'Could not read the crontab of $users.';
  }

  @override
  String jobsOtherUsersNotRead(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count more users\' crontabs were not read.',
      one: '1 more user\'s crontab was not read.',
    );
    return '$_temp0';
  }

  @override
  String get jobsOtherUsersMasked =>
      'Commands are masked where they look like they hold secrets.';

  @override
  String get activityMenu => 'Activity';

  @override
  String activityTitle(String server) {
    return 'Activity on $server';
  }

  @override
  String get activityDetail =>
      'Every action this device ran on the server, newest first. Records are kept for 90 days and never synced. Commands are stored with secrets removed.';

  @override
  String get activityInMemory =>
      'Another Klabautermann window has the settings folder, so this log lasts only until this window closes.';

  @override
  String get activityColumnTime => 'Time';

  @override
  String get activityColumnTarget => 'Target';

  @override
  String get activityColumnAction => 'Action';

  @override
  String get activityColumnTier => 'Confirmation';

  @override
  String get activityColumnResult => 'Result';

  @override
  String activityAction(String action) {
    String _temp0 = intl.Intl.selectLogic(action, {
      'KillProcess': 'Signal',
      'UnitAction': 'Unit action',
      'StartTimer': 'Run timer now',
      'RefreshPackageLists': 'Refresh package lists',
      'PowerAction': 'Reboot or shut down',
      'ContainerAction': 'Container action',
      'RemoveContainer': 'Remove container',
      'ContainerBulkAction': 'Containers action',
      'RemoveImage': 'Remove image',
      'CreateVolume': 'Create volume',
      'RemoveVolume': 'Remove volume',
      'RemoveNetwork': 'Remove network',
      'PruneDocker': 'Prune',
      'PullImage': 'Pull image',
      'StackAction': 'Stack action',
      'RedeployStack': 'Redeploy stack',
      'ContainerExec': 'Run command',
      'ContainerShell': 'Container shell',
      'EditFile': 'Edit',
      'KeepLastBackups': 'Keep recent backups',
      'RemoveBackups': 'Remove backups',
      'other': 'Action',
    });
    return '$_temp0';
  }

  @override
  String activityTier(String tier) {
    String _temp0 = intl.Intl.selectLogic(tier, {
      'none': 'None',
      'acknowledge': 'Confirmed',
      'typedPhrase': 'Name typed',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String activityResult(String outcome) {
    String _temp0 = intl.Intl.selectLogic(outcome, {
      'succeeded': 'Done',
      'failed': 'Failed',
      'cancelled': 'Cancelled',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String activityFailure(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink': 'No connection to the server.',
      'revalidation': 'The target changed since the preview.',
      'elevationRefused': 'Admin mode refused the step.',
      'stepFailed': 'A step failed.',
      'transport': 'The connection failed during the run.',
      'unsupportedStep': 'This version could not run a step.',
      'adminRequired': 'It needed admin mode.',
      'launchFailed': 'Its operation could not be started on the server.',
      'other': 'It failed.',
    });
    return '$_temp0';
  }

  @override
  String activityExitCode(int code) {
    return 'Exit status $code';
  }

  @override
  String activityHttpStatus(int status) {
    return 'Engine answered HTTP $status';
  }

  @override
  String get activitySteps => 'What ran';

  @override
  String get activityReading => 'Reading the log.';

  @override
  String get activityEmpty =>
      'Nothing has run on this server from this device.';

  @override
  String get activityOlder => 'Show older';

  @override
  String get activityCopy => 'Copy the log';

  @override
  String get activityCopied =>
      'The log is on the clipboard, with secrets removed.';

  @override
  String get activityNotCopied => 'Not copied. Try again.';

  @override
  String activityTime(String date, String time) {
    return '$date $time';
  }

  @override
  String detachedChipRunning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count operations running',
      one: '1 operation running',
    );
    return '$_temp0';
  }

  @override
  String detachedChipResults(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count operation results',
      one: '1 operation result',
    );
    return '$_temp0';
  }

  @override
  String detachedSheetTitle(String server) {
    return 'Operations on $server';
  }

  @override
  String get detachedIncomplete =>
      'Some operations may be missing: an operation folder on the server could not be read.';

  @override
  String get detachedEmpty => 'No operations.';

  @override
  String get detachedLaunchedElsewhere => 'Started on another device.';

  @override
  String detachedUnnamed(String id) {
    return 'Operation $id';
  }

  @override
  String detachedName(String action, String target) {
    return '$action: $target';
  }

  @override
  String detachedRunningSince(String time) {
    return 'Running since $time.';
  }

  @override
  String get detachedRunning => 'Running.';

  @override
  String get detachedSucceeded => 'Finished.';

  @override
  String detachedFailed(int code) {
    return 'Failed with exit status $code.';
  }

  @override
  String get detachedLost =>
      'Stopped before it finished, for example by a logout or a restart.';

  @override
  String get detachedUnknown => 'Its state could not be read.';

  @override
  String get detachedShowOutput => 'Show output';

  @override
  String get detachedAcknowledge => 'Clear';

  @override
  String get detachedCleanupWaits =>
      'Cleared. Its files are deleted once admin mode is on.';

  @override
  String detachedOutputTitle(String name) {
    return 'Output of $name';
  }

  @override
  String get detachedOutputClose => 'Close output';

  @override
  String get dockerTransportWaiting => 'Engine API: waiting for the connection';

  @override
  String get dockerTransportResolving => 'Engine API: looking for a route';

  @override
  String get dockerTransportSocketForward =>
      'Engine API via SSH socket forward';

  @override
  String get dockerTransportCliRelay =>
      'Engine API via docker CLI relay (limited streams)';

  @override
  String get dockerTransportSudoRelay =>
      'Engine API via sudo relay (root-equivalent)';

  @override
  String get dockerTransportSocatRelay => 'Engine API via socat relay';

  @override
  String get dockerTransportNoRelay =>
      'No Engine API route: forwarding is off and there is no relay';

  @override
  String get dockerTransportNeedsAdminMode =>
      'No Engine API route: the socket needs admin mode';

  @override
  String get dockerTransportSocketDenied =>
      'No Engine API route: your account cannot use the socket';

  @override
  String get dockerTransportProbeFailed =>
      'No Engine API route: the socket check failed';

  @override
  String get dockerTransportNoSocket =>
      'No Engine API route: no engine socket found';

  @override
  String get dockerTransportSocketsUnknown =>
      'No Engine API route: the sockets were not checked';

  @override
  String get dockerTransportUnreachable =>
      'Engine API: the engine did not answer';

  @override
  String get dockerTransportUnsupported =>
      'Engine API: the engine\'s API version is not supported';

  @override
  String get dockerTransportLinkError =>
      'Engine API: the connection failed while looking for a route';

  @override
  String get dockerTransportInvalidChoice =>
      'No Engine API route: the chosen socket path is not valid';

  @override
  String get dockerLowSession => 'Low-session mode';

  @override
  String get dockerBadgeRootfulSocket => 'Rootful socket: root-equivalent';

  @override
  String dockerBadgeRootlessEngine(String user) {
    return 'Rootless engine: equals user $user';
  }

  @override
  String get dockerBadgeRootlessEngineLogin =>
      'Rootless engine: equals your login user';

  @override
  String get dockerBadgeSudoRelay => 'Sudo relay: root-equivalent';

  @override
  String get dockerBadgeCustomSocket => 'Custom socket: root-equivalent';

  @override
  String get dockerRuntimeDocker => 'Docker';

  @override
  String get dockerRuntimePodman => 'Podman';

  @override
  String get dockerGateWaitingTitle => 'Waiting for the connection';

  @override
  String get dockerGateWaitingBody =>
      'Klabautermann looks for the Docker engine once it is connected to this server and knows what the server offers.';

  @override
  String get dockerGateResolvingTitle => 'Looking for the Docker engine';

  @override
  String get dockerGateResolvingBody =>
      'Klabautermann is finding a way to reach the engine socket and agreeing on an API version with the engine.';

  @override
  String get dockerGateNoRelay =>
      'Socket forwarding is off on this server, and it has nothing to relay through: no docker or podman command, no socat and no nc.';

  @override
  String get dockerGateNeedsAdminMode =>
      'Your account cannot use the engine socket. Turn on admin mode to reach it through sudo.';

  @override
  String get dockerGateSocketDenied =>
      'Your account cannot use the engine socket, and this server has no sudo. The Access tab shows how access is granted.';

  @override
  String get dockerGateProbeFailed =>
      'Checking the engine socket failed, so Klabautermann cannot tell how to reach it.';

  @override
  String get dockerGateNoSocket =>
      'No Docker or Podman socket was found on this server.';

  @override
  String get dockerGateSocketsUnknown =>
      'The server\'s capability check has not reported its engine sockets.';

  @override
  String get dockerGateUnreachable =>
      'A route to the engine socket opened, but the engine did not answer over it.';

  @override
  String get dockerGateBelowClientFloor =>
      'The engine\'s newest API version is older than 1.41, the oldest Klabautermann supports.';

  @override
  String get dockerGateBelowServerMinimum =>
      'The engine only accepts API versions newer than Klabautermann supports.';

  @override
  String get dockerGateApiVersionUnknown =>
      'The engine did not report an API version Klabautermann can read.';

  @override
  String get dockerGateLinkError =>
      'The connection to this server failed while Klabautermann looked for the engine.';

  @override
  String get dockerGateInvalidChoice =>
      'The socket path chosen for this server is not a valid absolute path. Choose another socket below.';

  @override
  String get dockerRetry => 'Try again';

  @override
  String get dockerTabContainers => 'Containers';

  @override
  String get dockerTabImages => 'Images';

  @override
  String get dockerTabVolumes => 'Volumes';

  @override
  String get dockerTabNetworks => 'Networks';

  @override
  String get dockerTabEvents => 'Events';

  @override
  String get dockerEventsBuffer =>
      'Events show from when Klabautermann started following them. The engine keeps only a limited buffer, so events while the stream was lost may be missing.';

  @override
  String get dockerEventsWaiting => 'Waiting for the events stream…';

  @override
  String dockerEventsFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'connectionFailed':
          'The connection to the engine failed while following its events.',
      'other': 'The engine\'s events could not be followed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerEventsAll => 'All';

  @override
  String dockerEventsKind(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'container': 'Containers',
      'image': 'Images',
      'volume': 'Volumes',
      'network': 'Networks',
      'other': 'Other',
    });
    return '$_temp0';
  }

  @override
  String get dockerEventsSearch => 'Search by name, action or image';

  @override
  String get dockerEventsNone =>
      'No events yet. They appear here as the engine reports them.';

  @override
  String get dockerEventsNoMatch => 'No event matches the filter.';

  @override
  String dockerEventsLine(String name, String action) {
    return '$name: $action';
  }

  @override
  String dockerEventsImage(String image) {
    return 'image $image';
  }

  @override
  String dockerEventsExitCode(int code) {
    return 'exit code $code';
  }

  @override
  String dockerEventsGap(String from, String until, String resumed) {
    String _temp0 = intl.Intl.selectLogic(resumed, {
      'true':
          'Not followed from $from to $until. The engine sent the events it still held, so some may be missing.',
      'other':
          'Not followed from $from to $until. Events in this span are not shown.',
    });
    return '$_temp0';
  }

  @override
  String get dockerTabStacks => 'Stacks';

  @override
  String get dockerEngineLingerOff =>
      'This rootless engine runs under your user, and linger is off: its containers stop when your last session on the server ends. Turn linger on with loginctl enable-linger to keep them running.';

  @override
  String get dockerTabReview => 'Review';

  @override
  String get dockerReviewIntro =>
      'Reads each container\'s configuration and flags settings that give a container power over the host, expose a database, or let its logs fill the disk. Each container is read once per review.';

  @override
  String get dockerReviewRun => 'Review containers';

  @override
  String get dockerReviewAgain => 'Review again';

  @override
  String get dockerReviewReading => 'Reading each container\'s configuration…';

  @override
  String dockerReviewNone(int total) {
    String _temp0 = intl.Intl.pluralLogic(
      total,
      locale: localeName,
      other: 'None of the $total containers carries a finding.',
      one: 'The one container carries no finding.',
      zero: 'The engine has no containers to review.',
    );
    return '$_temp0';
  }

  @override
  String dockerReviewFlagged(int flagged, int total) {
    return 'Containers with findings: $flagged of $total';
  }

  @override
  String dockerReviewOmitted(int omitted, int max) {
    String _temp0 = intl.Intl.pluralLogic(
      omitted,
      locale: localeName,
      other:
          '$omitted more containers were not read: a review reads at most $max.',
      one: '1 more container was not read: a review reads at most $max.',
    );
    return '$_temp0';
  }

  @override
  String dockerReviewUnreadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'The engine refused to inspect $count containers, so they are not reviewed.',
      one: 'The engine refused to inspect 1 container, so it is not reviewed.',
    );
    return '$_temp0';
  }

  @override
  String dockerReviewContainerInStack(String name, String stack) {
    return '$name in $stack';
  }

  @override
  String dockerReviewFinding(String level, String risk) {
    return '$level: $risk';
  }

  @override
  String dockerReviewLevel(String level) {
    String _temp0 = intl.Intl.selectLogic(level, {
      'high': 'High',
      'medium': 'Medium',
      'low': 'Low',
      'other': 'Finding',
    });
    return '$_temp0';
  }

  @override
  String dockerReviewRisk(String risk) {
    String _temp0 = intl.Intl.selectLogic(risk, {
      'privileged': 'Privileged',
      'socketMount': 'Engine socket mounted',
      'hostNetwork': 'Host network',
      'hostPid': 'Host processes visible',
      'addedCapabilities': 'Added capabilities',
      'databasePublished': 'Database on every address',
      'rootUser': 'Runs as root',
      'logsUnrotated': 'Logs never rotate',
      'latestTag': 'Floating image tag',
      'noHealthcheck': 'No health check',
      'noRestartPolicy': 'No restart policy',
      'other': 'Finding',
    });
    return '$_temp0';
  }

  @override
  String dockerReviewRiskWhy(String risk) {
    String _temp0 = intl.Intl.selectLogic(risk, {
      'privileged':
          'It has every device and capability of the host, so a break-in reaches the host.',
      'socketMount':
          'Whoever controls the container controls the engine, which is root on the host.',
      'hostNetwork':
          'It shares the host\'s network and reaches every service listening on it.',
      'hostPid': 'It sees, and can signal, every process on the host.',
      'addedCapabilities':
          'It holds capabilities beyond the engine\'s default set.',
      'databasePublished':
          'Its database port is published on every address, not only on localhost or a private network.',
      'rootUser':
          'Its processes run as root, and the engine maps root to root on the host.',
      'logsUnrotated':
          'It logs with json-file and no max-size, so its log file grows until the disk is full.',
      'latestTag':
          'A new pull can bring a different image. Pin a version or a digest.',
      'noHealthcheck':
          'The engine cannot tell when it stops working while it still runs.',
      'noRestartPolicy': 'It stays stopped after a crash or a reboot.',
      'other': 'It may put the host at risk.',
    });
    return '$_temp0';
  }

  @override
  String get dockerReviewToolsHeading => 'Other tools on this host';

  @override
  String dockerReviewTool(String tool) {
    String _temp0 = intl.Intl.selectLogic(tool, {
      'portainer': 'Portainer',
      'dockhand': 'Dockhand',
      'dockge': 'Dockge',
      'dozzle': 'Dozzle',
      'beszel': 'Beszel',
      'uptimeKuma': 'Uptime Kuma',
      'netdata': 'Netdata',
      'wud': 'What\'s Up Docker',
      'other': 'Another tool',
    });
    return '$_temp0';
  }

  @override
  String dockerReviewToolContainer(String name, String state) {
    return 'Container $name, $state';
  }

  @override
  String dockerReviewToolContainerName(String name) {
    return 'Container $name';
  }

  @override
  String get dockerReviewToolNoPorts => 'It publishes no port.';

  @override
  String dockerReviewFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notInFleet': 'This server is no longer in the fleet.',
      'linkUnavailable': 'There is no connection to this server.',
      'profileUnknown': 'The server\'s capability check has not answered yet.',
      'endpointUnavailable': 'The Docker engine cannot be reached.',
      'tooManyQueries':
          'This server already has as many Docker reads waiting as Klabautermann allows.',
      'daemonError':
          'The engine refused or failed to list or inspect the containers.',
      'connectionFailed':
          'The connection to the engine failed during the review.',
      'cancelled': 'The review stopped before it finished.',
      'other': 'The containers could not be reviewed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerEngineHeading => 'Engine';

  @override
  String dockerEngineApi(String version) {
    return 'API $version';
  }

  @override
  String dockerEngineVersion(String name, String version) {
    return '$name $version';
  }

  @override
  String dockerEngineVersionUnknown(String name) {
    return '$name, version unknown';
  }

  @override
  String dockerEngineOs(String os, String architecture) {
    return '$os on $architecture';
  }

  @override
  String get dockerEngineOsUnknown => 'Operating system unknown';

  @override
  String get dockerEngineReading => 'Reading the engine details…';

  @override
  String get dockerEngineReadFailed => 'The engine details could not be read.';

  @override
  String get dockerNoticeDismiss => 'Got it';

  @override
  String get dockerNoticeNotSaved =>
      'Klabautermann could not save that you dismissed the root-equivalence note, so it shows again after a restart.';

  @override
  String get dockerSocketLabel => 'Socket';

  @override
  String get dockerSocketAutomatic => 'Find automatically';

  @override
  String dockerSocketCustomCurrent(String path) {
    return 'Custom: $path';
  }

  @override
  String get dockerSocketCustomAction => 'Custom path…';

  @override
  String dockerSocketNotInUse(String path) {
    return '$path was chosen but did not answer, so the sockets found are tried instead.';
  }

  @override
  String get dockerSocketNotSaved =>
      'Klabautermann could not save the socket choice, so it applies only until Klabautermann quits.';

  @override
  String get dockerSocketCustomTitle => 'Custom engine socket';

  @override
  String get dockerSocketCustomBody =>
      'Klabautermann tries this socket first. If it does not answer, the sockets it finds are tried instead.';

  @override
  String get dockerSocketCustomField => 'Socket path';

  @override
  String get dockerSocketCustomHint => '/run/user/1000/docker.sock';

  @override
  String get dockerSocketCustomUse => 'Use';

  @override
  String get dockerSocketCustomCancel => 'Cancel';

  @override
  String get dockerSocketPathNotAbsolute =>
      'Enter an absolute path, starting with /.';

  @override
  String get dockerSocketPathUnsafe =>
      'The path cannot contain line breaks or NUL characters.';

  @override
  String get appearanceThemeTitle => 'Theme';

  @override
  String get appearanceThemeHelpTitle => 'Themes';

  @override
  String get appearanceThemeHelp =>
      'A theme is kept on this device only and never syncs. To use one elsewhere, copy it here and paste it into Klabautermann on the other device.';

  @override
  String get appearanceThemeFootnote =>
      'Picking a theme copies its colours here. It is a starting point, not a mode, so everything below stays yours to change.';

  @override
  String appearancePresetTooltip(String name) {
    return 'Use the $name theme';
  }

  @override
  String get appearanceModeTitle => 'Mode';

  @override
  String get appearanceModeLead => 'Automatic colours follow';

  @override
  String get appearanceOwnSurfaceDark =>
      'This theme has its own surface, so it is always dark. Set Surface to Automatic to choose a mode.';

  @override
  String get appearanceOwnSurfaceLight =>
      'This theme has its own surface, so it is always light. Set Surface to Automatic to choose a mode.';

  @override
  String get appearanceColoursTitle => 'Colours';

  @override
  String get appearanceColoursHelpTitle => 'Automatic colours';

  @override
  String get appearanceColoursHelp =>
      'Automatic colours are the light or dark neutrals Klabautermann ships with, as the mode picks them. Once you give the theme a surface of its own, they are mixed from that surface and the text instead. Lines and the selection may be translucent.';

  @override
  String get appearanceAccent => 'Accent';

  @override
  String get appearanceSlotSurface => 'Surface';

  @override
  String get appearanceSlotSidebar => 'Sidebar';

  @override
  String get appearanceSlotRaised => 'Headers and bars';

  @override
  String get appearanceSlotText => 'Text';

  @override
  String get appearanceSlotSecondaryText => 'Secondary text';

  @override
  String get appearanceSlotHairline => 'Lines';

  @override
  String get appearanceSlotSelection => 'Selection';

  @override
  String get appearanceSlotOnline => 'Online';

  @override
  String get appearanceSlotOffline => 'Offline';

  @override
  String get appearanceSlotConnecting => 'Connecting';

  @override
  String get appearanceSlotUnknown => 'Unknown';

  @override
  String get appearanceStatusTitle => 'Status colours';

  @override
  String get appearanceStatusFootnote =>
      'Each status also keeps its own shape and its name, so these colours never have to say it alone.';

  @override
  String get appearanceAutomatic => 'Automatic';

  @override
  String appearanceAutomaticSemantics(String label) {
    return '$label: Automatic';
  }

  @override
  String appearanceChooseColour(String label) {
    return 'Choose the $label colour';
  }

  @override
  String appearanceChooseAutomaticColour(String label) {
    return 'Choose a $label colour (now Automatic)';
  }

  @override
  String get appearanceShapeTitle => 'Shape and type';

  @override
  String get appearanceInterfaceFont => 'Interface font';

  @override
  String get appearanceInterfaceFontHint => 'System default';

  @override
  String get appearanceInterfaceFontHelper =>
      'Logs and commands keep their monospace font.';

  @override
  String get appearanceCorners => 'Corners';

  @override
  String get appearanceCornersSquare => 'Square';

  @override
  String appearanceCornersPercent(int percent) {
    return '$percent%';
  }

  @override
  String appearanceCornersSemantics(String label) {
    return 'Corners $label';
  }

  @override
  String get appearanceShareTitle => 'Share';

  @override
  String get appearanceCopyTheme => 'Copy theme';

  @override
  String get appearancePasteTheme => 'Paste theme';

  @override
  String get appearanceShareFootnote =>
      'Copies the theme as text you can keep or send. Pasting reads what it can and leaves everything else at the default.';

  @override
  String get appearanceThemeCopied => 'Theme copied.';

  @override
  String get appearancePasteNotATheme =>
      'The clipboard does not hold a theme. Copy one with Copy theme first.';

  @override
  String get appearanceStartOverTitle => 'Start over';

  @override
  String appearanceResetButton(String name) {
    return 'Reset to $name';
  }

  @override
  String get appearanceUsingOwnColours => 'Using your own colours.';

  @override
  String appearanceUsingPreset(String name) {
    return 'Using $name.';
  }

  @override
  String get appearanceResetTitle => 'Reset the theme?';

  @override
  String appearanceResetBody(String name) {
    return 'Every colour, the font and the corners go back to the $name theme. The mode stays as it is.';
  }

  @override
  String get appearanceCancel => 'Cancel';

  @override
  String get appearanceReset => 'Reset';

  @override
  String appearanceAbout(String title) {
    return 'About $title';
  }

  @override
  String get appearanceClose => 'Close';

  @override
  String get dockerContainersColumnName => 'Name';

  @override
  String get dockerContainersColumnState => 'State';

  @override
  String get dockerContainersColumnHealth => 'Health';

  @override
  String get dockerContainersColumnStatus => 'Status';

  @override
  String get dockerContainersColumnImage => 'Image';

  @override
  String get dockerContainersColumnPorts => 'Ports';

  @override
  String get dockerContainersColumnStack => 'Stack';

  @override
  String get dockerContainersColumnCpu => 'CPU';

  @override
  String get dockerContainersColumnMemory => 'Memory';

  @override
  String get dockerContainersColumnNetwork => 'Network';

  @override
  String get dockerContainersColumnBlockIo => 'Block I/O';

  @override
  String get dockerContainersColumnPids => 'PIDs';

  @override
  String get dockerContainersColumnIp => 'IP';

  @override
  String get dockerContainersColumnStarted => 'Started';

  @override
  String dockerContainersIo(String first, String second) {
    return '$first / $second';
  }

  @override
  String get dockerContainersColumns => 'Columns';

  @override
  String get dockerContainersColumnsTitle => 'Columns';

  @override
  String get dockerContainersColumnsDrag => 'Drag to reorder';

  @override
  String get dockerContainersColumnsReset => 'Reset';

  @override
  String get dockerContainersColumnsCancel => 'Cancel';

  @override
  String get dockerContainersColumnsDone => 'Done';

  @override
  String get dockerContainersColumnsNotSaved =>
      'The columns could not be saved. They stay until Klabautermann quits.';

  @override
  String get dockerContainersSelect => 'Select';

  @override
  String get dockerContainersColumnSelect => 'Selection';

  @override
  String dockerContainersRowSelected(String selected) {
    String _temp0 = intl.Intl.selectLogic(selected, {
      'true': 'Selected',
      'other': 'Not selected',
    });
    return '$_temp0';
  }

  @override
  String get dockerContainersSelectOne => 'Select';

  @override
  String get dockerContainersDeselect => 'Deselect';

  @override
  String get dockerContainersSelectProject => 'Select its containers';

  @override
  String get dockerContainersDeselectProject => 'Deselect its containers';

  @override
  String dockerContainersGroupSelection(String summary, String selection) {
    String _temp0 = intl.Intl.selectLogic(selection, {
      'all': 'all selected',
      'some': 'some selected',
      'other': 'none selected',
    });
    return '$summary, $_temp0';
  }

  @override
  String dockerContainersSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count selected',
      one: '1 selected',
      zero: 'None selected',
    );
    return '$_temp0';
  }

  @override
  String dockerContainersBulkVerb(String verb, int count) {
    String _temp0 = intl.Intl.selectLogic(verb, {
      'start': 'Start',
      'stop': 'Stop',
      'restart': 'Restart',
      'remove': 'Remove',
      'other': 'Act',
    });
    return '$_temp0 ($count)';
  }

  @override
  String get dockerContainersSelectAll => 'Select all shown';

  @override
  String get dockerContainersSelectNone => 'Clear selection';

  @override
  String dockerContainersBulkMax(int max) {
    return 'Select at most $max containers to act on them at once.';
  }

  @override
  String dockerContainerState(String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'created': 'Created',
      'running': 'Running',
      'paused': 'Paused',
      'restarting': 'Restarting',
      'removing': 'Removing',
      'exited': 'Exited',
      'dead': 'Dead',
      'other': 'Unknown',
    });
    return '$_temp0';
  }

  @override
  String dockerContainerStateFlagged(String state, String flag) {
    String _temp0 = intl.Intl.selectLogic(flag, {
      'restartLoop': 'restart loop',
      'failed': 'failed',
      'other': 'flagged',
    });
    return '$state ($_temp0)';
  }

  @override
  String dockerContainerFlagTooltip(String flag, int code) {
    String _temp0 = intl.Intl.selectLogic(flag, {
      'restartLoop':
          'The engine is starting it again after it exited, as a restart policy does in a loop. The details show how often it restarted.',
      'failed':
          'Its last run exited with code $code, which a stop does not leave.',
      'other': 'Exit code $code',
    });
    return '$_temp0';
  }

  @override
  String dockerContainerHealth(String health) {
    String _temp0 = intl.Intl.selectLogic(health, {
      'healthy': 'Healthy',
      'unhealthy': 'Unhealthy',
      'starting': 'Starting',
      'other': 'No health check',
    });
    return '$_temp0';
  }

  @override
  String dockerContainersCpu(double share) {
    final intl.NumberFormat shareNumberFormat =
        intl.NumberFormat.decimalPercentPattern(
          locale: localeName,
          decimalDigits: 1,
        );
    final String shareString = shareNumberFormat.format(share);

    return '$shareString';
  }

  @override
  String dockerContainersStale(String value) {
    return '$value, stale';
  }

  @override
  String dockerContainersSwarmService(String service) {
    return '$service (Swarm)';
  }

  @override
  String get dockerContainersNoStack => 'Not in a stack';

  @override
  String dockerContainersGroupSummary(int count, int up) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count containers',
      one: '1 container',
    );
    return '$_temp0, $up running';
  }

  @override
  String get dockerContainersSearchHint => 'Search by name, image or ID';

  @override
  String get dockerContainersSearchClear => 'Clear search';

  @override
  String get dockerContainersRunningOnly => 'Running only';

  @override
  String get dockerContainersSortBy => 'Sort by';

  @override
  String dockerContainersFact(String label, String value) {
    return '$label: $value';
  }

  @override
  String get dockerContainersReading => 'Reading the containers…';

  @override
  String get dockerContainersEmpty => 'This engine has no containers.';

  @override
  String get dockerContainersNoneRunning =>
      'No container is running. Turn off Running only to see the stopped ones.';

  @override
  String get dockerContainersNoMatch => 'No container matches the search.';

  @override
  String dockerContainersFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'daemonError': 'The engine refused or failed to list the containers.',
      'connectionFailed':
          'The connection to the engine failed while listing the containers.',
      'other': 'The containers could not be listed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerContainersKept => 'The list below is the last one read.';

  @override
  String get dockerContainersStatsFailed =>
      'The CPU and memory figures could not be read, so the ones shown may be old.';

  @override
  String get dockerContainersLowSession =>
      'Low-session mode: stats are read one container at a time, so they update more slowly.';

  @override
  String get dockerContainersLowSessionRelay =>
      'Low-session mode: the list is read again every 15 seconds instead of following engine events, and stats are read one container at a time.';

  @override
  String get dockerImagesColumnTags => 'Tags';

  @override
  String get dockerImagesColumnId => 'ID';

  @override
  String get dockerImagesColumnSize => 'Size';

  @override
  String get dockerImagesColumnCreated => 'Created';

  @override
  String get dockerImagesColumnUse => 'Use';

  @override
  String get dockerImagesColumnUpdate => 'Update';

  @override
  String get dockerImagesDangling => 'Dangling';

  @override
  String dockerImagesInUse(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'In use by $count containers',
      one: 'In use by 1 container',
    );
    return '$_temp0';
  }

  @override
  String dockerImagesInUseShort(int count) {
    return 'In use ($count)';
  }

  @override
  String get dockerImagesUnused => 'Unused';

  @override
  String dockerImagesCreated(String age, String date) {
    return '$age, $date';
  }

  @override
  String dockerImagesDate(DateTime date) {
    final intl.DateFormat dateDateFormat = intl.DateFormat.yMMMd(localeName);
    final String dateString = dateDateFormat.format(date);

    return '$dateString';
  }

  @override
  String get dockerImagesAgeNow => 'Less than a minute ago';

  @override
  String dockerImagesAgeMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String dockerImagesAgeHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String dockerImagesAgeDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String dockerImagesAgeWeeks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count weeks ago',
      one: '1 week ago',
    );
    return '$_temp0';
  }

  @override
  String dockerImagesAgeMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count months ago',
      one: '1 month ago',
    );
    return '$_temp0';
  }

  @override
  String dockerImagesAgeYears(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count years ago',
      one: '1 year ago',
    );
    return '$_temp0';
  }

  @override
  String get dockerImagesFilterAll => 'All';

  @override
  String get dockerImagesFilterUnused => 'Unused';

  @override
  String get dockerImagesFilterDangling => 'Dangling';

  @override
  String get dockerImagesSearchHint => 'Search by tag or ID';

  @override
  String get dockerImagesSearchClear => 'Clear search';

  @override
  String get dockerImagesSortBy => 'Sort by';

  @override
  String dockerImagesFact(String label, String value) {
    return '$label: $value';
  }

  @override
  String get dockerImagesReading => 'Reading the images…';

  @override
  String get dockerImagesEmpty => 'This engine has no images.';

  @override
  String get dockerImagesNoMatch => 'No image matches the search.';

  @override
  String get dockerImagesNoneUnused => 'Every image is in use by a container.';

  @override
  String get dockerImagesNoneDangling => 'No image is dangling.';

  @override
  String get dockerImagesFilterUpdates => 'Updates';

  @override
  String get dockerImagesNoneUpdates => 'No image has an update.';

  @override
  String get dockerImagesUpdatesCheck => 'Check for updates';

  @override
  String get dockerImagesUpdatesChecking => 'Checking for updates…';

  @override
  String dockerImagesUpdatesFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'connectionFailed': 'The update check could not run on the server.',
      'endpointUnavailable':
          'The update check needs the Docker engine, which is not reachable.',
      'daemonError':
          'The engine refused or failed to list the images for the update check.',
      'other': 'The update check failed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerImagesUpdatesNoCurl =>
      'This server has no curl, so no registry was asked. The engine can ask instead, but each tag it checks spends one of Docker Hub\'s pulls for the server\'s address.';

  @override
  String get dockerImagesUpdatesThroughDaemon => 'Check through the engine';

  @override
  String dockerImagesUpdatesRateLimited(String time) {
    return 'Docker Hub\'s limit for this server\'s address is used up. Those images are checked again after $time.';
  }

  @override
  String get dockerImagesUpdateNotChecked => 'Not checked';

  @override
  String get dockerImagesUpdateAvailable => 'Update available';

  @override
  String get dockerImagesUpdateCurrent => 'Current';

  @override
  String get dockerImagesUpdateUndecided => 'Unknown';

  @override
  String dockerImagesUpdateUnknown(String reason) {
    return 'Unknown: $reason';
  }

  @override
  String dockerImagesUpdateWhy(String issue) {
    String _temp0 = intl.Intl.selectLogic(issue, {
      'noResult': 'the registry did not answer',
      'unauthorized':
          'the registry wants credentials the server\'s Docker CLI does not have',
      'notFound': 'the registry does not know this tag',
      'rateLimited': 'Docker Hub\'s limit for the server\'s address is used up',
      'noDigest': 'this registry does not say which digest it holds',
      'noLocalDigest': 'this image was not pulled from the registry',
      'other': 'the registry refused the check',
    });
    return '$_temp0';
  }

  @override
  String get dockerImagesUpdateWhyNoBuildx =>
      'the registry wants credentials, and the server\'s Docker CLI has no buildx plugin to read them';

  @override
  String dockerImagesFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'daemonError': 'The engine refused or failed to list the images.',
      'connectionFailed':
          'The connection to the engine failed while listing the images.',
      'other': 'The images could not be listed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerImagesKept => 'The list below is the last one read.';

  @override
  String get dockerImagesUseUnknown =>
      'Which images are in use is unknown: this engine\'s API reports no count, and the containers could not be listed.';

  @override
  String dockerImageHistoryTitle(String image) {
    return '$image: history';
  }

  @override
  String get dockerImageHistoryReading => 'Reading the image\'s history…';

  @override
  String get dockerImageHistoryEmpty =>
      'The engine reports no layers for this image.';

  @override
  String dockerImageHistoryMasked(int count, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count instructions hold masked values. Reveal values shows them for $seconds seconds.',
      one:
          '1 instruction holds masked values. Reveal values shows them for $seconds seconds.',
    );
    return '$_temp0';
  }

  @override
  String get dockerImageHistoryNoInstruction => 'No instruction recorded';

  @override
  String get dockerImageHistoryComment => 'Comment';

  @override
  String get dockerLinksTitle => 'Links';

  @override
  String dockerLinksFrom(String source) {
    String _temp0 = intl.Intl.selectLogic(source, {
      'dockhand': 'From a Dockhand label',
      'dozzle': 'From a Dozzle label',
      'traefik': 'A Traefik route',
      'caddy': 'A Caddy site',
      'other': 'From a label',
    });
    return '$_temp0';
  }

  @override
  String dockerLinksFromPort(String source, String port) {
    String _temp0 = intl.Intl.selectLogic(source, {
      'dockhand': 'From a Dockhand label, port $port',
      'other': 'From a label, port $port',
    });
    return '$_temp0';
  }

  @override
  String dockerLinksOpen(String name) {
    return 'Open $name in the browser';
  }

  @override
  String get dockerLinksNotOpened =>
      'The link could not be opened in a browser.';

  @override
  String get dockerProcessesTitle => 'Processes';

  @override
  String get dockerProcessesStopped =>
      'The container is not running, so it has no processes.';

  @override
  String get dockerProcessesReading => 'Reading processes…';

  @override
  String get dockerProcessesReadAgain => 'Read again';

  @override
  String get dockerProcessesNone =>
      'The engine lists no processes for this container.';

  @override
  String dockerProcessesCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$countString processes',
      one: '1 process',
    );
    return '$_temp0';
  }

  @override
  String dockerProcessesFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notInFleet': 'This server is no longer in the fleet.',
      'linkUnavailable': 'There is no connection to this server.',
      'profileUnknown': 'The server\'s capability check has not answered yet.',
      'endpointUnavailable': 'The Docker engine cannot be reached.',
      'tooManyQueries':
          'This server already has as many Docker reads waiting as Klabautermann allows.',
      'notFound': 'The engine no longer has this container.',
      'daemonError':
          'The engine refused or failed to list the container\'s processes.',
      'connectionFailed':
          'The connection to the engine failed while reading the processes.',
      'cancelled': 'The read stopped before it ran.',
      'other': 'The container\'s processes could not be read.',
    });
    return '$_temp0';
  }

  @override
  String dockerImageHistoryFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notInFleet': 'This server is no longer in the fleet.',
      'linkUnavailable': 'There is no connection to this server.',
      'profileUnknown': 'The server\'s capability check has not answered yet.',
      'endpointUnavailable': 'The Docker engine cannot be reached.',
      'tooManyQueries':
          'This server already has as many Docker reads waiting as Klabautermann allows.',
      'notFound': 'The engine no longer has this image.',
      'daemonError':
          'The engine refused or failed to read the image\'s history.',
      'connectionFailed':
          'The connection to the engine failed while reading the history.',
      'cancelled': 'The read stopped before it ran.',
      'other': 'The image\'s history could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get dockerImagesLowSessionRelay =>
      'Low-session mode: the list is read again every 15 seconds instead of following engine events.';

  @override
  String get dockerVolumesColumnName => 'Name';

  @override
  String get dockerVolumesColumnDriver => 'Driver';

  @override
  String dockerVolumesInUse(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Mounted by $count containers',
      one: 'Mounted by 1 container',
    );
    return '$_temp0';
  }

  @override
  String get dockerVolumesSearchHint => 'Search by name or driver';

  @override
  String get dockerVolumesReading => 'Reading the volumes…';

  @override
  String get dockerVolumesEmpty => 'This engine has no volumes.';

  @override
  String get dockerVolumesNoMatch => 'No volume matches the search.';

  @override
  String get dockerVolumesNoneUnused =>
      'Every volume is mounted by a container.';

  @override
  String dockerVolumesFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'daemonError': 'The engine refused or failed to list the volumes.',
      'connectionFailed':
          'The connection to the engine failed while listing the volumes.',
      'other': 'The volumes could not be listed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerVolumesUseUnknown =>
      'Which volumes are in use is unknown: the containers, whose mounts tell, could not be listed.';

  @override
  String get dockerPullOpen => 'Pull image…';

  @override
  String get dockerPullTitle => 'Pull an image';

  @override
  String get dockerPullReference => 'Image';

  @override
  String get dockerPullReferenceHint =>
      'nginx:1.27 or registry.example.com/app:2';

  @override
  String get dockerPullStart => 'Pull';

  @override
  String get dockerPullCancel => 'Stop pull';

  @override
  String dockerPullRunning(String route) {
    String _temp0 = intl.Intl.selectLogic(route, {
      'engine': 'Pulling. Closing this sheet stops the pull.',
      'host': 'Pulling on the server. Losing the connection stops the pull.',
      'other': 'Starting the pull on the server.',
    });
    return '$_temp0';
  }

  @override
  String dockerPullRoute(String route) {
    String _temp0 = intl.Intl.selectLogic(route, {
      'engine': 'Engine',
      'host': 'Server\'s login',
      'other': 'Detached',
    });
    return '$_temp0';
  }

  @override
  String dockerPullRouteNote(String route) {
    String _temp0 = intl.Intl.selectLogic(route, {
      'engine':
          'The engine pulls anonymously and shows each layer. Closing the sheet stops it.',
      'host':
          'The server\'s docker pull uses its own docker login, for private registries. The output shows at the end.',
      'other':
          'The server\'s docker pull runs on its own and keeps running when you leave. Follow it under Operations.',
    });
    return '$_temp0';
  }

  @override
  String dockerPullDetached(String target) {
    return 'The pull of $target started on the server.';
  }

  @override
  String dockerPullLayerBytes(String status, String current, String total) {
    return '$status: $current of $total';
  }

  @override
  String get dockerPrune => 'Prune…';

  @override
  String dockerPruneChoice(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'containers': 'Prune stopped containers…',
      'images': 'Prune dangling images…',
      'imagesAll': 'Prune all unused images…',
      'volumes': 'Prune unused volumes…',
      'networks': 'Prune unused networks…',
      'buildCache': 'Prune the build cache…',
      'other': 'Prune…',
    });
    return '$_temp0';
  }

  @override
  String get dockerVolumeCreate => 'Create volume…';

  @override
  String get dockerVolumeCreateTitle => 'Create a volume';

  @override
  String get dockerVolumeCreateSubmit => 'Continue';

  @override
  String get dockerVolumeDriverHint => 'local';

  @override
  String get dockerVolumeNameRequired => 'Enter a name.';

  @override
  String get dockerVolumeNameInvalid =>
      'Use letters, digits, \'_\', \'.\' and \'-\', starting with a letter or digit, at least two characters.';

  @override
  String get dockerVolumeRemove => 'Remove';

  @override
  String get dockerNetworksColumnScope => 'Scope';

  @override
  String get dockerNetworksColumnSubnet => 'Subnet';

  @override
  String get dockerNetworksColumnGateway => 'Gateway';

  @override
  String get dockerNetworksNoSubnet => 'None';

  @override
  String get dockerNetworksBuiltin => 'Built-in';

  @override
  String dockerNetworksBuiltinName(String name) {
    return '$name, built-in';
  }

  @override
  String dockerNetworksInUse(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count containers on it',
      one: '1 container on it',
    );
    return '$_temp0';
  }

  @override
  String get dockerNetworksSearchHint => 'Search by name, driver or subnet';

  @override
  String get dockerNetworksReading => 'Reading the networks…';

  @override
  String get dockerNetworksEmpty => 'This engine has no networks.';

  @override
  String get dockerNetworksNoMatch => 'No network matches the search.';

  @override
  String get dockerNetworksNoneUnused =>
      'Every network you made has a container on it.';

  @override
  String dockerNetworksFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'daemonError': 'The engine refused or failed to list the networks.',
      'connectionFailed':
          'The connection to the engine failed while listing the networks.',
      'other': 'The networks could not be listed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerNetworksUseUnknown =>
      'Which networks are in use is unknown: the containers, which name their networks, could not be listed.';

  @override
  String get dockerNetworkRemove => 'Remove';

  @override
  String get dockerDetailsClose => 'Close the container details';

  @override
  String get dockerDetailsReading => 'Reading the container details…';

  @override
  String dockerDetailsFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notInFleet': 'This server is no longer in the fleet.',
      'linkUnavailable': 'There is no connection to this server.',
      'profileUnknown': 'The server\'s capability check has not answered yet.',
      'endpointUnavailable': 'The Docker engine cannot be reached.',
      'tooManyQueries':
          'This server already has as many Docker reads waiting as Klabautermann allows.',
      'daemonError': 'The engine refused or failed to inspect the container.',
      'connectionFailed':
          'The connection to the engine failed while inspecting the container.',
      'cancelled': 'The read stopped before it ran.',
      'other': 'The container details could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get dockerDetailsKept => 'The details below are the last ones read.';

  @override
  String get dockerDetailsRemoved => 'This container was removed.';

  @override
  String dockerDetailsManagedBy(String manager) {
    return 'Managed by $manager';
  }

  @override
  String dockerDetailsManagedByNote(String manager, String label) {
    return 'Changes made outside $manager can be overwritten by it. The label $label marks it.';
  }

  @override
  String get dockerDiagnosisTitle => 'Diagnosis';

  @override
  String dockerDiagnosisKind(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'oomLimit': 'Out of memory',
      'oomHost': 'Out of memory on the host',
      'killed': 'Killed',
      'segfault': 'Crashed',
      'notExecutable': 'Command not executable',
      'commandNotFound': 'Command not found',
      'runtimeError': 'The engine could not start it',
      'exitedWithError': 'Exited with an error',
      'exitsAtOnce': 'Exits right after starting',
      'restartLoop': 'Restart loop',
      'unhealthy': 'Health check failing',
      'other': 'Something went wrong',
    });
    return '$_temp0';
  }

  @override
  String dockerDiagnosisWhy(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'oomLimit':
          'The kernel stopped it, most likely for going over its memory limit. Raise the limit or find what keeps growing.',
      'oomHost':
          'The kernel stopped it while the host ran out of memory. It has no memory limit of its own.',
      'killed':
          'It ended with SIGKILL (exit code 137) without running out of memory: a docker kill, a stop that ran past its timeout, or another process.',
      'segfault':
          'It ended with a segmentation fault (exit code 139), a crash inside the program.',
      'notExecutable':
          'Exit code 126: the command exists but cannot run. Check its permissions and its interpreter line.',
      'commandNotFound':
          'Exit code 127: the entrypoint or command names a program the image does not have.',
      'runtimeError': 'The engine reported this error for it:',
      'exitedWithError':
          'Its process ended with an error. Its last log lines usually say why.',
      'exitsAtOnce':
          'It exited with code 0 and its restart policy starts it again: its main process does not stay in the foreground.',
      'restartLoop':
          'Its restart policy has started it again after each exit since it was last started by hand. Its logs show what each run ended with.',
      'unhealthy':
          'Its health check keeps failing. Health checks shows what each check printed.',
      'other': 'Its state says something went wrong.',
    });
    return '$_temp0';
  }

  @override
  String dockerDiagnosisMemoryLimit(String limit) {
    return 'Memory limit: $limit';
  }

  @override
  String dockerDiagnosisExitCode(int code) {
    return 'Exit code: $code';
  }

  @override
  String dockerDiagnosisRestarts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Restarted $count times',
      one: 'Restarted once',
      zero: 'Restarting now',
    );
    return '$_temp0';
  }

  @override
  String get dockerDetailsOverview => 'Overview';

  @override
  String get dockerDetailsId => 'ID';

  @override
  String dockerDetailsStateExited(String state, int code) {
    return '$state, exit code $code';
  }

  @override
  String get dockerDetailsOomKilled =>
      'Its last run was stopped for running out of memory.';

  @override
  String get dockerDetailsStateError =>
      'The engine reported an error for this container.';

  @override
  String dockerDetailsHealthStreak(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count failed checks in a row',
      one: '1 failed check in a row',
    );
    return '$_temp0';
  }

  @override
  String get dockerDetailsRestartPolicy => 'Restart policy';

  @override
  String dockerDetailsRestartPolicyName(String policy) {
    String _temp0 = intl.Intl.selectLogic(policy, {
      'no': 'Never restart',
      'always': 'Always restart',
      'unlessStopped': 'Restart unless stopped',
      'onFailure': 'Restart on failure',
      'other': 'Unknown',
    });
    return '$_temp0';
  }

  @override
  String dockerDetailsRestartPolicyRetries(String policy, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count times',
      one: 'once',
    );
    return '$policy, at most $_temp0';
  }

  @override
  String get dockerDetailsRestarts => 'Restarts';

  @override
  String get dockerDetailsImageId => 'Image ID';

  @override
  String get dockerDetailsCreated => 'Created';

  @override
  String get dockerDetailsStarted => 'Started';

  @override
  String get dockerDetailsFinished => 'Stopped';

  @override
  String dockerDetailsTime(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String get dockerDetailsHealthTitle => 'Health checks';

  @override
  String get dockerDetailsHealthEmpty => 'No health check has run yet.';

  @override
  String dockerDetailsHealthCheck(String code, DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.MMMd(
      localeName,
    ).add_jms();
    final String timeString = timeDateFormat.format(time);

    return 'Exit code $code, $timeString';
  }

  @override
  String dockerDetailsHealthCheckUntimed(String code) {
    return 'Exit code $code';
  }

  @override
  String get dockerDetailsHealthNoOutput => 'No output';

  @override
  String dockerDetailsRevealNote(int seconds) {
    return 'Select a masked value to show it for $seconds seconds.';
  }

  @override
  String get dockerDetailsMasked => '(masked)';

  @override
  String get dockerDetailsRevealHint => 'Show the masked value';

  @override
  String get dockerDetailsHideHint => 'Mask again';

  @override
  String dockerDetailsEntry(String name, String value) {
    return '$name: $value';
  }

  @override
  String get dockerDetailsCommandTitle => 'Command';

  @override
  String get dockerDetailsEntrypoint => 'Entrypoint';

  @override
  String get dockerDetailsCmd => 'Arguments';

  @override
  String get dockerDetailsNone => 'None';

  @override
  String get dockerDetailsEnvTitle => 'Environment';

  @override
  String get dockerDetailsEnvEmpty => 'No environment variables.';

  @override
  String get dockerDetailsLabelsTitle => 'Labels';

  @override
  String get dockerDetailsLabelsEmpty => 'No labels.';

  @override
  String get dockerDetailsMountsTitle => 'Mounts';

  @override
  String get dockerDetailsMountsEmpty => 'No mounts.';

  @override
  String dockerDetailsMountKind(String type) {
    String _temp0 = intl.Intl.selectLogic(type, {
      'bind': 'Bind mount',
      'volume': 'Volume',
      'tmpfs': 'Memory (tmpfs)',
      'npipe': 'Named pipe',
      'cluster': 'Cluster volume',
      'image': 'Image',
      'other': 'Mount',
    });
    return '$_temp0';
  }

  @override
  String get dockerDetailsMountReadOnly => 'read-only';

  @override
  String get dockerDetailsMountReadWrite => 'read-write';

  @override
  String dockerDetailsMountSummary(String kind, String access) {
    return '$kind, $access';
  }

  @override
  String get dockerDetailsPortsEmpty => 'No published or exposed ports.';

  @override
  String get dockerDetailsNetworksTitle => 'Networks';

  @override
  String get dockerDetailsNetworkMode => 'Network mode';

  @override
  String get dockerDetailsNetworksEmpty => 'Not attached to a network.';

  @override
  String get dockerDetailsIpAddress => 'IP address';

  @override
  String get dockerDetailsGateway => 'Gateway';

  @override
  String get dockerDetailsAliases => 'Aliases';

  @override
  String get dockerDetailsRawTitle => 'Raw JSON';

  @override
  String get dockerDetailsRawNote => 'Masked values stay masked here.';

  @override
  String get dockerLogsShow => 'Show logs';

  @override
  String get dockerCommandOpen => 'Run a command';

  @override
  String dockerCommandTitle(String container) {
    return 'Run a command in $container';
  }

  @override
  String get dockerCommandLabel => 'Command';

  @override
  String get dockerCommandHelper =>
      'Runs without a shell or terminal. Quote words as in a shell; for pipes and variables, run sh -c \'…\'.';

  @override
  String get dockerCommandUnparsed =>
      'Enter a complete command: close any open quote and remove a trailing backslash.';

  @override
  String get dockerCommandRun => 'Run';

  @override
  String get dockerCommandRunning => 'Running…';

  @override
  String get dockerCommandStdout => 'Output';

  @override
  String get dockerCommandStderr => 'Errors';

  @override
  String get dockerCommandNoOutput => 'The command printed nothing.';

  @override
  String get dockerCommandTruncated =>
      'The output was longer than 1 MiB; the rest was dropped.';

  @override
  String get dockerShellOpen => 'Open a shell';

  @override
  String get dockerShellHide => 'Show details';

  @override
  String dockerShellTitle(String container) {
    return 'Shell in $container';
  }

  @override
  String get dockerShellShellLabel => 'Shell';

  @override
  String get dockerShellShellAuto => 'Automatic: /bin/bash, then /bin/sh';

  @override
  String get dockerShellUserLabel => 'User';

  @override
  String get dockerShellUserHint => 'The container\'s user';

  @override
  String get dockerShellStart => 'Open shell';

  @override
  String get dockerShellOpening => 'Opening the shell…';

  @override
  String dockerShellRunning(String command) {
    return 'Running $command';
  }

  @override
  String dockerShellEnded(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'exited': 'The shell exited.',
      'closed': 'The shell was closed.',
      'observeOnly': 'Management is off for this server, so no shell opens.',
      'readOnly': 'Read-only mode is on, so no shell opens.',
      'notInFleet': 'This server is no longer in the fleet.',
      'endpointUnavailable':
          'The server\'s Docker endpoint could not be reached.',
      'noChannel':
          'No session channel was free on the server. Close another view or shell and try again.',
      'tooMany':
          'This server already has the most shells open. Close one first.',
      'refused': 'The container is gone, or Docker refused the shell.',
      'linkLost': 'The connection to the server was lost.',
      'adminEnded': 'Admin mode ended, and the shell with it.',
      'failed': 'The shell failed.',
      'other': 'The engine stopped, and the shell with it.',
    });
    return '$_temp0';
  }

  @override
  String dockerShellExitCode(int code) {
    return 'Exit code $code.';
  }

  @override
  String get dockerShellReopen => 'Open again';

  @override
  String get dockerShellChange => 'Change shell';

  @override
  String get dockerShellClose => 'Close the shell';

  @override
  String get dockerShellCopy => 'Copy';

  @override
  String get dockerShellPaste => 'Paste';

  @override
  String dockerShellPasteTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Paste $count lines?',
      one: 'Paste 1 line?',
    );
    return '$_temp0';
  }

  @override
  String get dockerShellPasteFindings =>
      'Some of these lines look dangerous. Each line runs as you paste it.';

  @override
  String get dockerShellPasteUnchecked =>
      'These lines could not be checked. Each line runs as you paste it.';

  @override
  String dockerShellPasteFinding(int line, String explanation) {
    return 'Line $line: $explanation';
  }

  @override
  String get dockerShellPasteAll => 'Paste all';

  @override
  String get dockerShellPasteFirstLine => 'First line only';

  @override
  String get dockerShellPasteCancel => 'Cancel';

  @override
  String get dockerLogsTitle => 'Logs';

  @override
  String get dockerLogsClose => 'Close logs';

  @override
  String get dockerLogsEmpty => 'This container has no log lines.';

  @override
  String get dockerLogsRangeChoose => 'Choose start and end…';

  @override
  String dockerLogsRangeBetween(String since, String until) {
    return '$since to $until';
  }

  @override
  String get dockerLogsRangeTitle => 'Time range';

  @override
  String get dockerLogsRangeFrom => 'From';

  @override
  String get dockerLogsRangeTo => 'To';

  @override
  String get dockerLogsRangeOrder => 'The start must come before the end.';

  @override
  String get dockerLogsRangeCancel => 'Cancel';

  @override
  String get dockerLogsRangeApply => 'Apply';

  @override
  String dockerLogsExportFileName(String container) {
    return '$container.log';
  }

  @override
  String get dockerStackLogsOpen => 'Logs';

  @override
  String dockerStackLogsTitle(String project) {
    return '$project logs';
  }

  @override
  String get dockerStackLogsNone =>
      'This stack has no containers, so it has no logs.';

  @override
  String dockerStackLogsOmitted(int shown, int omitted) {
    String _temp0 = intl.Intl.pluralLogic(
      omitted,
      locale: localeName,
      other: '$omitted more are not shown.',
      one: '1 more is not shown.',
    );
    return '$shown containers\' logs are read at once, as each holds a connection to the server. $_temp0';
  }

  @override
  String dockerStackLogsState(String container, String state) {
    String _temp0 = intl.Intl.selectLogic(state, {
      'waiting': 'waiting',
      'ended': 'stopped reading',
      'refused': 'refused',
      'other': 'opening',
    });
    return '$container: $_temp0';
  }

  @override
  String get dockerLogsLiveRange =>
      'A range with an end has no new lines to follow.';

  @override
  String dockerLogsDriverUnreadable(String reason, String driver) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'none': 'This container keeps no logs: driver none.',
      'podman':
          'Podman cannot read this container\'s logs: driver $driver. Podman reads only the json-file, k8s-file and journald drivers.',
      'cacheDisabled':
          'Docker cannot read this container\'s logs: driver $driver, cache disabled. Docker reads another driver\'s logs only through its local cache.',
      'other':
          'Docker cannot read this container\'s logs: its logging driver keeps none it can read.',
    });
    return '$_temp0';
  }

  @override
  String get dockerStacksReading => 'Reading the stacks…';

  @override
  String dockerStacksFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'tooManyQueries':
          'This server already has as many Docker watches open as Klabautermann allows.',
      'daemonError':
          'The engine refused or failed to list the containers the stacks are read from.',
      'connectionFailed':
          'The connection to the engine failed while listing the stacks.',
      'other': 'The stacks could not be listed.',
    });
    return '$_temp0';
  }

  @override
  String get dockerStacksKept => 'The list below is the last one read.';

  @override
  String get dockerStacksEmpty => 'This engine runs no compose stacks.';

  @override
  String get dockerStacksLowSessionRelay =>
      'Low-session mode: the stacks are read again every 15 seconds instead of following engine events.';

  @override
  String get dockerStacksCliLabel => 'Compose CLI';

  @override
  String dockerStacksCliPlugin(String version) {
    return 'Docker Compose $version';
  }

  @override
  String dockerStacksCliStandalone(String legacy, String version) {
    String _temp0 = intl.Intl.selectLogic(legacy, {
      'true': 'docker-compose $version (Compose v1, unmaintained): read-only',
      'other': 'docker-compose $version (standalone): read-only',
    });
    return '$_temp0';
  }

  @override
  String get dockerStacksCliNone =>
      'None found, so no stack\'s source can be verified.';

  @override
  String dockerStackVerdict(String verdict) {
    String _temp0 = intl.Intl.selectLogic(verdict, {
      'verifying': 'Checking source…',
      'waiting': 'Waiting for a channel',
      'verified': 'Verified source',
      'notOnHost': 'Source not on host',
      'other': 'Unverified source',
    });
    return '$_temp0';
  }

  @override
  String dockerStackNotOnHostDeployedBy(String manager) {
    return 'Source not on host (deployed by $manager)';
  }

  @override
  String dockerStackUnverified(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noSourceLabels': 'Unverified source: no compose files recorded',
      'unsafeLabels': 'Unverified source: unsafe names in the labels',
      'noHashLabels': 'Unverified source: a service has no config hash',
      'noComposeCli': 'Unverified source: no compose CLI',
      'standaloneComposeOnly':
          'Unverified source: standalone docker-compose only',
      'cliCouldNotHash': 'Unverified source: the compose CLI cannot hash',
      'configFailed': 'Unverified source: compose config failed',
      'hashMismatch': 'Unverified source: the files changed since the deploy',
      'checkFailed': 'Unverified source: the check could not run',
      'other': 'Unverified source',
    });
    return '$_temp0';
  }

  @override
  String dockerStackVerdictNote(String verdict) {
    String _temp0 = intl.Intl.selectLogic(verdict, {
      'verifying':
          'Klabautermann is checking the compose files on the host against the running containers.',
      'verified':
          'The compose files on the host are the ones these containers were deployed from.',
      'notOnHost':
          'A compose file the containers name is not on the host. A manager that runs compose in its own container records paths inside that container.',
      'other':
          'The compose files on the host could not be matched to the ones these containers were deployed from, so they are not treated as the stack\'s source.',
    });
    return '$_temp0';
  }

  @override
  String dockerStackManagedBy(String manager) {
    return 'Managed by $manager: read-only';
  }

  @override
  String dockerStackManagedByNote(String manager, String label) {
    return 'Changes made outside $manager can be overwritten by it, so Klabautermann treats this stack as read-only. The label $label marks it.';
  }

  @override
  String dockerStackServices(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count services',
      one: '1 service',
    );
    return '$_temp0';
  }

  @override
  String dockerStackRunning(int up, int total) {
    return '$up of $total running';
  }

  @override
  String dockerStackUnhealthy(int count) {
    return '$count unhealthy';
  }

  @override
  String get dockerStackOpenHint => 'Show the stack\'s overview';

  @override
  String get dockerStackSource => 'Source';

  @override
  String get dockerStackWorkingDir => 'Working directory';

  @override
  String get dockerStackConfigFiles => 'Compose files';

  @override
  String get dockerStackEnvFiles => 'Environment files';

  @override
  String get dockerStackComposeVersion => 'Deployed with Compose';

  @override
  String get dockerStackNoneRecorded => 'None recorded';

  @override
  String get dockerStackServicesHeading => 'Services';

  @override
  String get dockerStackOneOff => 'one-off';

  @override
  String dockerStackPorts(String ports) {
    return 'Ports $ports';
  }

  @override
  String get dockerStackOpenContainerHint => 'Show the container\'s details';

  @override
  String get dockerStackGone => 'This stack has no containers any more.';

  @override
  String get dockerStackFilesView => 'View files';

  @override
  String get dockerStackFilesUnverified =>
      'Its files show only once its source is verified.';

  @override
  String dockerStackFileTitle(String project) {
    return '$project: files';
  }

  @override
  String get dockerStackFileClose => 'Close';

  @override
  String dockerStackFileReading(String file) {
    return 'Reading $file…';
  }

  @override
  String dockerStackFileEditorLabel(String file) {
    return '$file, read-only';
  }

  @override
  String dockerStackFileMasked(int count, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count values are masked. Reveal values shows them for $seconds seconds.',
      one: '1 value is masked. Reveal values shows it for $seconds seconds.',
    );
    return '$_temp0';
  }

  @override
  String get dockerStackFileReveal => 'Reveal values';

  @override
  String get dockerStackFileHide => 'Hide values';

  @override
  String dockerStackFileTruncated(String size, String limit) {
    return 'This file is $size, so only its complete lines within the first $limit show.';
  }

  @override
  String dockerStackFileFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'unknownStack': 'No container belongs to this stack any more.',
      'notVerified':
          'This stack\'s source is no longer verified, so its files do not show.',
      'notStackFile': 'This path is none of the stack\'s files.',
      'notFound': 'There is no file at this path on the host.',
      'permissionDenied':
          'Your account cannot read this file. Admin mode reads it through sudo.',
      'notRegularFile':
          'This path is a link, a directory or another special file, which is not read.',
      'readFailed':
          'The file could not be read, or it changed while it was read.',
      'other': 'The file could not be read.',
    });
    return '$_temp0';
  }

  @override
  String dockerStackFileQueryFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'notInFleet': 'This server is no longer in the fleet.',
      'linkUnavailable': 'There is no connection to this server.',
      'profileUnknown': 'The server\'s capability check has not answered yet.',
      'endpointUnavailable': 'The Docker engine cannot be reached.',
      'tooManyQueries':
          'This server already has as many Docker reads waiting as Klabautermann allows.',
      'daemonError':
          'The engine refused or failed to list the stack\'s containers.',
      'connectionFailed':
          'The connection to the engine failed while reading the file.',
      'cancelled': 'The read stopped before it ran.',
      'other': 'The file could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get editClose => 'Close';

  @override
  String editTitleFile(String name) {
    return 'Edit $name';
  }

  @override
  String get editTitleOwnCrontab => 'Edit your crontab';

  @override
  String editTitleCrontab(String user) {
    return 'Edit $user\'s crontab';
  }

  @override
  String get editRetry => 'Read again';

  @override
  String get editReading => 'Reading the file…';

  @override
  String editReadFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink': 'There is no connection to this server.',
      'invalidTarget': 'Klabautermann does not edit this path.',
      'notFound': 'There is no file at this path on the host.',
      'adminRequired':
          'Only root can read this file. Turn on admin mode to edit it.',
      'tooLarge': 'This file is too large for the editor.',
      'notText': 'This file is not text.',
      'stackUnverified':
          'This stack\'s files are not its verified source, so Klabautermann does not edit them.',
      'failed': 'The file could not be read.',
      'other': 'The file could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get editRootFile => 'Root\'s file';

  @override
  String get editUnsaved => 'Not saved';

  @override
  String editEditorLabel(String path) {
    return 'Editor for $path';
  }

  @override
  String get editDiscard => 'Discard changes';

  @override
  String get editReview => 'Review changes';

  @override
  String get editDiscardTitle => 'Discard your changes?';

  @override
  String get editDiscardBody =>
      'Your changes are not saved to the server and will be lost.';

  @override
  String get editKeepEditing => 'Keep editing';

  @override
  String get editConflictTitle => 'The file changed on the server';

  @override
  String get editConflictBody =>
      'It changed since you opened it, so your save did not run. Your changes are still here.';

  @override
  String get editConflictDiscard => 'Discard mine';

  @override
  String get editConflictCompare => 'Reload and compare';

  @override
  String editProblem(int line, String kind, String subject) {
    String _temp0 = intl.Intl.pluralLogic(
      line,
      locale: localeName,
      other: 'Line $line',
    );
    String _temp1 = intl.Intl.selectLogic(kind, {
      'syntaxError': 'does not parse',
      'duplicateKey': 'key set again',
      'duplicateTable': 'table declared again',
      'duplicateAttribute': 'attribute given twice',
      'jsonComment': 'comment in JSON',
      'jsonTrailingComma': 'trailing comma in JSON',
      'unterminatedQuote': 'quote never closed',
      'tabIndentation': 'tab indentation',
      'mismatchedClosingTag': 'closing tag does not match',
      'unclosedElement': 'element never closed',
      'unexpectedClosingTag': 'closing tag without an open element',
      'mergeConflict': 'merge conflict marker',
      'other': 'problem',
    });
    return '$_temp0: $_temp1 $subject';
  }

  @override
  String get editSave => 'Save to server';

  @override
  String get editSaveAnyway => 'Save anyway';

  @override
  String get editDiffing => 'Comparing…';

  @override
  String editDiffStatus(String status) {
    String _temp0 = intl.Intl.selectLogic(status, {
      'identical': 'Your text is the same as the server\'s.',
      'tooLarge': 'The change is too large to show as a diff.',
      'timedOut': 'The comparison took too long to show.',
      'failed': 'The comparison failed.',
      'other': 'The change cannot be shown.',
    });
    return '$_temp0';
  }

  @override
  String get editDiffLabel => 'Changes to the file';

  @override
  String dockerStackServiceActions(String service) {
    return 'Actions for $service';
  }

  @override
  String get dockerStackServicePull => 'Pull image';

  @override
  String get dockerStackServiceRecreate => 'Recreate';

  @override
  String get dockerStackServiceScale => 'Scale';

  @override
  String dockerStackScaleTitle(String service) {
    return 'Scale $service';
  }

  @override
  String get dockerStackScaleLabel => 'Containers';

  @override
  String dockerStackScaleRange(int max) {
    return 'Enter a number from 0 to $max.';
  }

  @override
  String get dockerStackScaleCancel => 'Cancel';

  @override
  String get dockerStackDown => 'Down';

  @override
  String get dockerStackProfiles => 'Profiles';

  @override
  String get dockerStackProfilesReading => 'Reading…';

  @override
  String get dockerStackProfilesFailed => 'The profiles could not be listed.';

  @override
  String get dockerStacksUnlisted => 'Stacks without containers';

  @override
  String get dockerStackFoldersNone =>
      'Name the folders your stacks live in, such as /opt/stacks, to find stacks that have no containers.';

  @override
  String dockerStackFoldersList(String folders) {
    return 'Folders: $folders';
  }

  @override
  String get dockerStackFoldersChoose => 'Choose folders';

  @override
  String get dockerStackFoldersScanAgain => 'Scan again';

  @override
  String get dockerStackFoldersScanning => 'Scanning the folders…';

  @override
  String get dockerStackFoldersScanFailed =>
      'The folders could not be scanned.';

  @override
  String get dockerStackFoldersNoneFound =>
      'Every stack in these folders has containers.';

  @override
  String get dockerStackFoldersIncomplete =>
      'A folder could not be read, so some stacks may be missing.';

  @override
  String get dockerStackFoldersTitle => 'Stack folders';

  @override
  String dockerStackFoldersHelper(int max) {
    return 'One absolute path per line, at most $max. The folders and the folders right below them are searched for compose files. Kept on this device.';
  }

  @override
  String dockerStackFoldersProblem(String problem, int max) {
    String _temp0 = intl.Intl.selectLogic(problem, {
      'notAbsolute':
          'Each folder must be an absolute path, such as /opt/stacks.',
      'tooMany': 'Name at most $max folders.',
      'other': 'These folders cannot be scanned.',
    });
    return '$_temp0';
  }

  @override
  String get dockerStackFoldersCancel => 'Cancel';

  @override
  String get dockerStackFoldersSave => 'Save';

  @override
  String get dockerStackFoldersNotSaved =>
      'The folders could not be saved on this device. They apply until the app quits.';

  @override
  String get dockerStackFileEdit => 'Edit';

  @override
  String get jobsEditOwnCrontab => 'Edit your crontab';

  @override
  String editDiffServerLabel(String path) {
    return '$path (server)';
  }

  @override
  String editDiffYourLabel(String path) {
    return '$path (yours)';
  }

  @override
  String get footprintMenu => 'Footprint';

  @override
  String get diagnosticsMenu => 'Diagnostic bundle…';

  @override
  String get diagnosticsReading => 'Reading each collector once…';

  @override
  String diagnosticsTitle(String server, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sections',
      one: '1 section',
    );
    return 'Diagnostic bundle for $server: $_temp0';
  }

  @override
  String get diagnosticsHint =>
      'The raw output of each collector, for a parser bug report. It names this server\'s processes, units, mounts and paths, so read it before you share it.';

  @override
  String diagnosticsMissing(String collectors) {
    return 'No answer from: $collectors';
  }

  @override
  String diagnosticsFailed(String failure) {
    String _temp0 = intl.Intl.selectLogic(failure, {
      'noLink':
          'Klabautermann is not reading this server right now, so its collectors cannot be read. Open the server while it is connected and try again.',
      'other': 'The collectors could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get diagnosticsFileName => 'diagnostics.txt';

  @override
  String footprintTitle(String server) {
    return 'Footprint on $server';
  }

  @override
  String get footprintVerify => 'Check again';

  @override
  String get footprintChecking =>
      'Checking what Klabautermann keeps on this server…';

  @override
  String get footprintUnavailable =>
      'Klabautermann cannot check what it keeps on this server without a connection. Connect, then check again.';

  @override
  String get footprintRootUnchecked =>
      'Root\'s backups and manifest are checked in admin mode.';

  @override
  String footprintWarning(String warning) {
    return 'The check reported: $warning';
  }

  @override
  String get footprintNone => 'Klabautermann keeps nothing on this server.';

  @override
  String footprintScope(String scope) {
    String _temp0 = intl.Intl.selectLogic(scope, {
      'user': 'Your account',
      'root': 'Root',
      'other': 'Other',
    });
    return '$_temp0';
  }

  @override
  String footprintFile(String kind, String present) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'backupDirectory': 'Backup directory',
      'backupIndex': 'Backup index',
      'other': 'File',
    });
    String _temp1 = intl.Intl.selectLogic(present, {
      'true': 'present',
      'other': 'missing on the host',
    });
    return '$_temp0 · $_temp1';
  }

  @override
  String footprintKeepLast(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Keep the newest $count backups of each file',
      one: 'Keep only the newest backup of each file',
    );
    return '$_temp0';
  }

  @override
  String get footprintRemoveAll => 'Remove all backups';

  @override
  String footprintCrontabSource(String user) {
    return '$user\'s crontab';
  }

  @override
  String footprintBackup(String hash, String status) {
    String _temp0 = intl.Intl.selectLogic(status, {
      'intact': 'unchanged',
      'modified': 'changed on the host since it was recorded',
      'missing': 'missing on the host',
      'other': 'unknown',
    });
    return '$hash · $_temp0';
  }

  @override
  String get footprintRestore => 'Restore…';

  @override
  String get footprintRestoreChanged =>
      'The backup changed since it was checked, so it was not opened.';

  @override
  String get unitEnable => 'Enable';

  @override
  String get unitDisable => 'Disable';

  @override
  String get unitMask => 'Mask';

  @override
  String get unitUnmask => 'Unmask';

  @override
  String get unitResetFailed => 'Reset failed state';

  @override
  String get unitMoreActions => 'More';

  @override
  String unitQueryFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink': 'There is no connection to this server.',
      'invalidUnit': 'This is not a unit name.',
      'notFound': 'The manager has no such unit.',
      'managerUnavailable':
          'Your user manager cannot be reached: you need a login session or lingering.',
      'failed': 'The read failed.',
      'other': 'The read failed.',
    });
    return '$_temp0';
  }

  @override
  String get unitResourcesMemory => 'Memory';

  @override
  String get unitResourcesCpu => 'CPU time';

  @override
  String unitResourcesCpuSeconds(String seconds) {
    return '$seconds s';
  }

  @override
  String get unitResourcesTasks => 'Tasks';

  @override
  String get unitResourcesRestarts => 'Restarts';

  @override
  String get unitResourcesMainPid => 'Main PID';

  @override
  String get unitResourcesActiveSince => 'Active since';

  @override
  String get unitFileShow => 'Show unit file';

  @override
  String unitFileTitle(String unit) {
    return '$unit file';
  }

  @override
  String get unitFileClose => 'Close';

  @override
  String get unitFileReading => 'Reading the unit file…';

  @override
  String unitFileMasked(int count, int seconds) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count values are masked.',
      one: '1 value is masked.',
    );
    return '$_temp0 Reveal shows them for $seconds seconds.';
  }

  @override
  String get unitFileReveal => 'Reveal values';

  @override
  String get unitFileHide => 'Hide values';

  @override
  String unitFileEditorLabel(String unit) {
    return 'File of $unit';
  }

  @override
  String get servicesScopeSystem => 'System';

  @override
  String get servicesScopeUser => 'Yours';

  @override
  String get servicesUserLogsAbsent =>
      'The logs of your own units are not shown here yet.';

  @override
  String get servicesUserUnavailable =>
      'Your own units could not be read. Your user manager runs only while you are logged in, or with lingering enabled.';

  @override
  String get serverEditorAddTitle => 'Add server';

  @override
  String get serverEditorEditTitle => 'Edit server';

  @override
  String get serverEditorLabel => 'Label';

  @override
  String get serverEditorHost => 'Host';

  @override
  String get serverEditorPort => 'Port';

  @override
  String get serverEditorUsername => 'Username';

  @override
  String get serverEditorAuthentication => 'Authentication';

  @override
  String get serverEditorAuthAgent => 'ssh-agent';

  @override
  String get serverEditorAuthPassword => 'Password';

  @override
  String get serverEditorAuthPrivateKey => 'Private key';

  @override
  String get serverEditorAgentInfo =>
      'Keys are provided by your ssh-agent; nothing is stored.';

  @override
  String get serverEditorPasswordLabel => 'Password';

  @override
  String get serverEditorReferenceKeyTitle => 'Reference a key file on disk';

  @override
  String get serverEditorReferenceKeySubtitle =>
      'Don\'t store the key — read it at connect';

  @override
  String get serverEditorIdentityFileHint => '~/.ssh/id_ed25519';

  @override
  String get serverEditorIdentityFilePath => 'Identity file path';

  @override
  String get serverEditorBrowse => 'Browse…';

  @override
  String get serverEditorPrivateKeyPem => 'Private key (PEM/OpenSSH)';

  @override
  String get serverEditorKeyPassphrase => 'Key passphrase (optional)';

  @override
  String get serverEditorStartDirectory => 'Start folder (optional)';

  @override
  String get serverEditorStartDirectoryHint => 'e.g. ~/sites or /var/www';

  @override
  String get serverEditorStartDirectoryNote =>
      'Opens when you connect to this server. A relative path starts in your home folder. Blank opens your home folder.';

  @override
  String get serverEditorStartDirectoryInvalid =>
      'Use an absolute path such as /var/www, or one in your own home such as ~/sites.';

  @override
  String get serverEditorLoginScript => 'Login script (optional)';

  @override
  String get serverEditorLoginScriptHint =>
      'e.g. cd ~/work && tmux attach -t work || tmux new -s work';

  @override
  String get serverEditorLoginScriptNote =>
      'Séance runs this as if typed at the prompt right after connecting. Klabautermann keeps it with the server and never runs it. Keep secrets out of it. Blank for none.';

  @override
  String get serverEditorAppearance => 'Appearance';

  @override
  String get serverEditorGroup => 'Group';

  @override
  String get serverEditorGroupHint =>
      'Production, Home lab, … — blank for none';

  @override
  String get serverEditorColour => 'Colour';

  @override
  String get serverEditorMark => 'Mark';

  @override
  String get serverEditorChooseMark => 'Choose…';

  @override
  String get serverEditorDefaultMarkTooltip => 'Use the default mark';

  @override
  String get serverEditorSyncSecretTitle => 'Allow this credential to sync';

  @override
  String get serverEditorSyncSecretExcluded =>
      'Not used while this server is excluded from sync.';

  @override
  String get serverEditorSyncSecretSubtitle =>
      'End-to-end encrypted. Also needs sync set up with \"Sync saved passwords & keys\" enabled.';

  @override
  String get serverEditorExcludeTitle => 'Exclude from sync';

  @override
  String get serverEditorExcludeOnSubtitle =>
      'Kept on this device only. A copy that synced earlier is removed from the sync server and from your other devices.';

  @override
  String get serverEditorExcludeOffSubtitle =>
      'Keep this server on this device only — never upload it.';

  @override
  String get serverEditorTest => 'Test connection';

  @override
  String get serverEditorTesting => 'Testing…';

  @override
  String get serverEditorTestingSemantic => 'Testing connection';

  @override
  String get serverEditorCancel => 'Cancel';

  @override
  String get serverEditorSave => 'Save';

  @override
  String get serverEditorTestDisclaimer =>
      'Testing authenticates without opening a shell or running the login script. A host key you approve here is trusted for the test only — the first real connection asks again.';

  @override
  String get serverEditorRequired => 'Required';

  @override
  String get serverEditorPortRange => '1–65535';

  @override
  String get serverEditorTestFailedSummary => 'Could not test the connection.';

  @override
  String serverEditorSaveFailed(String error) {
    return 'Could not save: $error';
  }

  @override
  String get serverEditorExcludeConfirmTitle => 'Exclude from sync?';

  @override
  String get serverEditorExcludeConfirmBody =>
      'If this server synced earlier, it is removed from the sync server and from your other devices, along with any credential that synced with it. This device keeps its copy.';

  @override
  String get serverEditorExcludeConfirmCancel => 'Cancel';

  @override
  String get serverEditorExcludeConfirmAction => 'Exclude';

  @override
  String get serverEditorCustomColour => 'Custom colour…';

  @override
  String serverEditorCustomColourValue(String hex) {
    return 'Custom colour ($hex)';
  }

  @override
  String get serverMarkPickerTitle => 'Server mark';

  @override
  String get serverMarkPickerIconsTab => 'Icons';

  @override
  String get serverMarkPickerEmojiTab => 'Emoji';

  @override
  String get serverMarkPickerImageTab => 'Image';

  @override
  String get serverMarkPickerCancel => 'Cancel';

  @override
  String get serverMarkPickerSearchHint =>
      'Search icons — try k8s, psql, prod…';

  @override
  String get serverMarkPickerNoMatch => 'No icon matches.';

  @override
  String get serverMarkPickerDefault => 'Default';

  @override
  String get serverMarkPickerEmojiHintMacOS =>
      'Press Control-Command-Space for the system emoji picker.';

  @override
  String get serverMarkPickerEmojiHintWindows =>
      'Press Windows-. for the system emoji picker.';

  @override
  String get serverMarkPickerEmojiHintLinux =>
      'Your desktop may offer an emoji picker with Control-Shift-E or Control-.';

  @override
  String get serverMarkPickerEmojiHintOther => 'Switch your keyboard to emoji.';

  @override
  String get serverMarkPickerAnyEmoji => 'Any emoji';

  @override
  String get serverMarkPickerOneEmoji => 'One emoji, please.';

  @override
  String get serverMarkPickerUse => 'Use';

  @override
  String get serverMarkPickerEmojiFontNote =>
      'An emoji is drawn with the system’s own emoji font, so a device without one shows a box — the icon chosen under Icons is what it falls back to there.';

  @override
  String get serverMarkPickerOpenFailed =>
      'That file could not be opened. Try another.';

  @override
  String get serverMarkPickerTooLarge =>
      'That file is too big to read. Crop or export it smaller first.';

  @override
  String get serverMarkPickerUndecodable =>
      'That file could not be read as an image.';

  @override
  String get serverMarkPickerEncodeFailed =>
      'That image could not be prepared. Try again, or pick another.';

  @override
  String get serverMarkPickerIncompressible =>
      'That image would not fit in a server record even at badge size. Try a simpler picture — a logo rather than a photograph.';

  @override
  String get serverMarkPickerNoImage => 'No image on this server yet.';

  @override
  String get serverMarkPickerHasImage => 'This server carries an image.';

  @override
  String get serverMarkPickerChooseImage => 'Choose image…';

  @override
  String get serverMarkPickerReplaceImage => 'Replace image…';

  @override
  String get serverMarkPickerRemoveImage => 'Remove image';

  @override
  String get serverMarkPickerImageFormats => 'PNG, JPEG, WebP or SVG';

  @override
  String get serverMarkPickerImageFormatsIos => 'PNG, JPEG or WebP';

  @override
  String serverMarkPickerImageExplanation(String formats, int side) {
    return '$formats. The image is cropped square, stored at $side pixels, and travels inside this server’s own settings — so it reaches your other devices with everything else about the server, and never arrives without it. Anything larger than a badge can show would only be paid for on every sync. A transparent image shows the server’s colour through it.';
  }

  @override
  String get serverColorPickerTitle => 'Custom colour';

  @override
  String get colorPickerHexLabel => 'Hex';

  @override
  String get colorPickerHexError => 'Six hex digits';

  @override
  String get colorPickerHue => 'Hue';

  @override
  String get colorPickerSaturation => 'Saturation';

  @override
  String get colorPickerBrightness => 'Brightness';

  @override
  String colorPickerDegrees(int degrees) {
    return '$degrees degrees';
  }

  @override
  String colorPickerPercent(int percent) {
    return '$percent percent';
  }

  @override
  String get serverColorPickerHint =>
      'Drawn as picked, with the mark kept legible on it in both themes. Devices running an older version show the nearest of the named colours instead.';

  @override
  String get colorPickerOpacity => 'Opacity';

  @override
  String get colorPickerHexErrorAlpha => 'Six or eight hex digits';

  @override
  String get colorPickerCancel => 'Cancel';

  @override
  String get colorPickerUse => 'Use colour';

  @override
  String get fleetRowEdit => 'Edit…';

  @override
  String get fleetRowDelete => 'Delete…';

  @override
  String serverDeleteTitle(String name) {
    return 'Delete $name?';
  }

  @override
  String get serverDeleteBody =>
      'The server leaves your sync account, and with it every device that syncs it. Its saved password or key goes too, unless another server uses it.';

  @override
  String get serverDeleteCancel => 'Cancel';

  @override
  String get serverDeleteAction => 'Delete';

  @override
  String get serverEditGone => 'This server is no longer in your account.';

  @override
  String get serverEditEngineStopped =>
      'Klabautermann\'s engine stopped, so nothing was saved. Restart Klabautermann and try again.';

  @override
  String serverEditRefused(String reason, String detail) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'directoryShared':
          'Another Klabautermann may be using this device\'s data folder, so nothing was saved.',
      'notEnrolled': 'Sign in to your sync account to edit servers.',
      'keystoreUnavailable':
          'Your account key could not be read from the system keystore, so nothing was saved.',
      'unknownTarget': 'This server is no longer in your account.',
      'invalidDraft': 'A field is missing or out of range.',
      'tooMany': 'Your account holds as many servers as it can.',
      'tooLarge':
          'This server is too large to save. Try a smaller image for its mark.',
      'storeUnavailable':
          'Klabautermann\'s sync files could not be written this session, so nothing was saved.',
      'other': 'Nothing was saved: $detail',
    });
    return '$_temp0';
  }

  @override
  String get settingsServersAccountTitle => 'Servers in your account';

  @override
  String get settingsServersAccountDetail =>
      'Add a server to your sync account here. To edit or delete one, open its menu in the server list.';

  @override
  String get handOffOpenInSeance => 'Open terminal in Séance';

  @override
  String get handOffSeanceNotOpened => 'Séance did not open the link.';

  @override
  String get handOffOpenTerminalHere => 'Open terminal here';

  @override
  String get handOffOpenInPoltergeist => 'Open in Poltergeist';

  @override
  String get handOffPoltergeistNotOpened =>
      'Poltergeist did not open the link.';

  @override
  String get settingsDeviceTitle => 'This device';

  @override
  String get settingsDeviceName => 'Device name';

  @override
  String get settingsDeviceNameDetail =>
      'Servers\' system logs name this device beside each action you take there. Leave it blank for the default.';

  @override
  String get settingsDeviceNameNotSaved =>
      'The device name changed, but it could not be saved, so it will not be kept after a restart.';

  @override
  String get settingsDeviceNameNotChanged =>
      'The device name could not be changed.';

  @override
  String get serverEditorTestSucceeded => 'Connection test succeeded';

  @override
  String get serverEditorTestFailed => 'Connection test failed';

  @override
  String get connectionLogTitle => 'Connection log';

  @override
  String get connectionLogCopy => 'Copy';

  @override
  String get connectionLogCopied => 'Log copied';

  @override
  String get connectionLogCopyFailed => 'Could not copy the log';

  @override
  String get connectionLogEmpty => '(no log captured)';

  @override
  String get fleetRowDuplicate => 'Duplicate';

  @override
  String serverDuplicated(String name) {
    return 'Copied $name';
  }

  @override
  String get serverEditorImportKeyFile => 'Import from file…';

  @override
  String get serverEditorKeyFileImportFailed =>
      'Could not read that file as a key.';

  @override
  String get alertsTitle => 'Alerts';

  @override
  String get alertsCoverage =>
      'Evaluated on this device while Klabautermann is open.';

  @override
  String alertsNoticeActive(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alerts are active',
      one: '1 alert is active',
    );
    return '$_temp0';
  }

  @override
  String get alertsNoticeCleared =>
      'Every alert has cleared since you last looked.';

  @override
  String get alertsShow => 'Show alerts';

  @override
  String get alertsActiveHeading => 'Active';

  @override
  String get alertsNoneActive => 'No alert is active.';

  @override
  String get alertsHistoryHeading => 'Earlier';

  @override
  String alertsRowCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count alerts',
      one: '1 alert',
    );
    return '$_temp0';
  }

  @override
  String alertsBadgeCount(int count) {
    final intl.NumberFormat countNumberFormat =
        intl.NumberFormat.decimalPattern(localeName);
    final String countString = countNumberFormat.format(count);

    return '$countString';
  }

  @override
  String alertRowTitle(String server, String metric) {
    return '$server: $metric';
  }

  @override
  String alertSeverity(String severity) {
    String _temp0 = intl.Intl.selectLogic(severity, {
      'critical': 'Critical',
      'warning': 'Warning',
      'other': 'Info',
    });
    return '$_temp0';
  }

  @override
  String alertDateTime(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return '$timeString';
  }

  @override
  String alertSince(String time) {
    return 'since $time';
  }

  @override
  String alertRaisedAt(String time) {
    return 'Raised at $time';
  }

  @override
  String alertClearedAt(String time) {
    return 'Cleared at $time';
  }

  @override
  String get alertMetricCpuBusy => 'CPU busy';

  @override
  String get alertMetricMemoryUsed => 'Memory used';

  @override
  String get alertMetricLoadPerCore => 'Load per core';

  @override
  String get alertMetricDiskUsed => 'Disk space used';

  @override
  String get alertMetricDiskInodes => 'Inodes used';

  @override
  String get historyTitle => 'History';

  @override
  String historyLastHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last $count hours',
      one: 'Last hour',
    );
    return '$_temp0';
  }

  @override
  String historyLastDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last $count days',
      one: 'Last day',
    );
    return '$_temp0';
  }

  @override
  String get historyRefresh => 'Refresh';

  @override
  String get historyEmpty =>
      'No history yet. Klabautermann keeps 48 hours and 30 days of this server\'s readings while it is open.';

  @override
  String get historyLaneMean => 'Average';

  @override
  String get historyLanePeak => 'Peak';

  @override
  String get historySource =>
      'Recorded on this device while Klabautermann was open';

  @override
  String get historyMetricCpu => 'CPU busy';

  @override
  String get historyMetricMemory => 'Memory used';

  @override
  String get historyMetricDisk => 'Disk space used';

  @override
  String get historyMetricInodes => 'Inodes used';

  @override
  String get historyMetricLoad => 'Load per core';

  @override
  String get alertRulesTitle => 'Alert rules';

  @override
  String get alertRulesEmpty => 'No alert rules yet.';

  @override
  String get alertRulesEmptyServer => 'No rule applies to this server yet.';

  @override
  String get alertRulesNeedSync =>
      'Alert rules sync through your sync account, so adding or changing one needs you signed in.';

  @override
  String get alertRuleAdd => 'Add rule';

  @override
  String get alertRuleNew => 'New rule';

  @override
  String get alertRuleEdit => 'Edit rule';

  @override
  String get alertRuleSave => 'Save';

  @override
  String get alertRuleDelete => 'Delete rule';

  @override
  String get alertRuleDeleteConfirm =>
      'Delete this rule? It is removed on every device that syncs your account.';

  @override
  String get alertRuleDeleteAction => 'Delete';

  @override
  String alertRuleCondition(String op, String metric, String value) {
    String _temp0 = intl.Intl.selectLogic(op, {
      'greaterThan': '$metric above $value',
      'greaterOrEqual': '$metric at or above $value',
      'lessThan': '$metric below $value',
      'other': '$metric at or below $value',
    });
    return '$_temp0';
  }

  @override
  String alertRuleClears(String op, String value) {
    String _temp0 = intl.Intl.selectLogic(op, {
      'greaterThan': 'Clears at or below $value',
      'greaterOrEqual': 'Clears below $value',
      'lessThan': 'Clears at or above $value',
      'other': 'Clears above $value',
    });
    return '$_temp0';
  }

  @override
  String alertRuleFor(String duration) {
    return 'after $duration';
  }

  @override
  String alertRuleMinutes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes',
      one: '1 minute',
    );
    return '$_temp0';
  }

  @override
  String alertRuleSeconds(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count seconds',
      one: '1 second',
    );
    return '$_temp0';
  }

  @override
  String alertRuleScopeServer(String server) {
    return 'On $server';
  }

  @override
  String alertRuleScopeGroup(String group) {
    return 'On the $group group';
  }

  @override
  String get alertRuleScopeAll => 'On every server';

  @override
  String get alertRuleMetricLabel => 'Metric';

  @override
  String get alertRuleOpLabel => 'Raise when the value is';

  @override
  String alertRuleOp(String op) {
    String _temp0 = intl.Intl.selectLogic(op, {
      'greaterThan': 'Above',
      'greaterOrEqual': 'At or above',
      'lessThan': 'Below',
      'other': 'At or below',
    });
    return '$_temp0';
  }

  @override
  String get alertRuleRaiseValueLabel => 'Raise at';

  @override
  String get alertRuleClearValueLabel => 'Clear at';

  @override
  String get alertRuleForLabel => 'Held for (minutes)';

  @override
  String get alertRuleSeverityLabel => 'Severity';

  @override
  String get alertRuleScopeLabel => 'Applies to';

  @override
  String get alertRulePercentSuffix => '%';

  @override
  String get alertRuleNumberInvalid => 'Enter a number.';

  @override
  String get alertRulePercentInvalid => 'Enter a value from 0 to 100.';

  @override
  String get alertRuleMinutesInvalid => 'Enter 0 or more minutes.';

  @override
  String get alertRuleClearAboveRaise =>
      'The clear value must not be above the raise value.';

  @override
  String get alertRuleClearBelowRaise =>
      'The clear value must not be below the raise value.';

  @override
  String alertRuleRefused(String reason, String detail) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'directoryShared':
          'Another Klabautermann may be using this device\'s data folder, so nothing was saved.',
      'notEnrolled': 'Sign in to your sync account to change alert rules.',
      'keystoreUnavailable':
          'Your account key could not be read from the system keystore, so nothing was saved.',
      'unknownTarget': 'This rule is no longer in your account.',
      'invalidDraft': 'A field is missing or out of range.',
      'tooMany': 'Your account holds as many rules as it can.',
      'tooLarge': 'This rule is too large to save.',
      'storeUnavailable':
          'Klabautermann\'s sync files could not be written this session, so nothing was saved.',
      'other': 'Nothing was saved: $detail',
    });
    return '$_temp0';
  }

  @override
  String get alertRuleEngineStopped =>
      'Klabautermann\'s engine stopped before the rule was saved.';

  @override
  String get alertNotificationsSwitch => 'Notify me when an alert is raised';

  @override
  String get alertNotificationsSwitchDetail =>
      'A system notification, posted only while Klabautermann is open.';

  @override
  String get alertNotificationsPromptTitle => 'Get notified of raised alerts?';

  @override
  String get alertNotificationsPromptBody =>
      'Klabautermann evaluates your rules on this device while it is open, and posts a notification when one raises. It cannot notify you while it is closed.';

  @override
  String get alertNotificationsPromptAllow => 'Allow notifications';

  @override
  String get alertNotificationsPromptLater => 'Not now';

  @override
  String get alertNotificationsDenied =>
      'Notifications are turned off for Klabautermann in your system settings.';

  @override
  String get alertNotificationsUnavailable =>
      'This device has no system notifications Klabautermann can post.';

  @override
  String get alertNotificationsNotSaved =>
      'The notification setting applies until Klabautermann restarts; it could not be saved.';

  @override
  String alertNotificationTitle(String server, String metric, String value) {
    return '$server: $metric at $value';
  }

  @override
  String alertNotificationBody(String severity) {
    return '$severity. Evaluated on this device while Klabautermann is open.';
  }

  @override
  String get alertNotificationChannel => 'Raised alerts';

  @override
  String get alertNotificationChannelDetail =>
      'Alerts your rules raise while Klabautermann is open.';

  @override
  String get alertNotificationOpen => 'Open';

  @override
  String get systemUpdatesTitle => 'Updates';

  @override
  String get systemUpdatesNone => 'Up to date';

  @override
  String systemUpdatesCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count updates available',
      one: '1 update available',
    );
    return '$_temp0';
  }

  @override
  String systemUpdatesSecurityCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count are security updates',
      one: '1 is a security update',
    );
    return '$_temp0';
  }

  @override
  String systemUpdatesSecurityPatches(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count security patches are needed',
      one: '1 security patch is needed',
    );
    return '$_temp0';
  }

  @override
  String get systemUpdatesRestart => 'The server asks for a restart.';

  @override
  String systemUpdatesRestartFor(String packages) {
    return 'The server asks for a restart, for $packages.';
  }

  @override
  String get systemUpdatesNoRestart => 'No restart required';

  @override
  String systemUpdatesFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink': 'The server is not connected, so updates could not be checked.',
      'transport': 'The connection failed while updates were checked.',
      'other': 'Updates could not be checked.',
    });
    return '$_temp0';
  }

  @override
  String get systemUpdatesNoManager =>
      'No package manager Klabautermann reads was found (apt, dnf, zypper, pacman or apk).';

  @override
  String get systemUpdatesNoCache =>
      'The package lists have not been downloaded on this server yet, and the check never downloads them.';

  @override
  String systemUpdatesManagerFailed(String detail) {
    return 'The package manager failed: $detail';
  }

  @override
  String get systemUpdatesPackage => 'Package';

  @override
  String get systemUpdatesInstalled => 'Installed';

  @override
  String get systemUpdatesAvailable => 'Available';

  @override
  String get systemUpdatesSecurity => 'Security';

  @override
  String get systemUpdatesSecurityYes => 'Security';

  @override
  String systemUpdatesCut(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Only the first $count updates are listed.',
    );
    return '$_temp0';
  }

  @override
  String systemUpdatesListsFrom(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'Package lists last downloaded $timeString';
  }

  @override
  String get systemUpdatesChecking => 'Checking for updates…';

  @override
  String get systemUpdatesCheckAgain => 'Check again';

  @override
  String get systemUpdatesRefresh => 'Refresh package lists';

  @override
  String get systemUpdatesRefreshAdminNeeded =>
      'Turn on admin mode to download them.';

  @override
  String get systemUpdatesRefreshStarted =>
      'When the refresh has finished, check again to read the new lists.';

  @override
  String get systemPowerTitle => 'Power';

  @override
  String get systemPowerReboot => 'Reboot';

  @override
  String get systemPowerShutDown => 'Shut down';

  @override
  String get systemPowerAdminNeeded =>
      'Turn on admin mode to reboot or shut down this server.';

  @override
  String systemPowerWaiting(String elapsed) {
    return 'Rebooting. Waiting for the server to answer again: $elapsed so far.';
  }

  @override
  String systemPowerBack(String elapsed) {
    return 'The server answered again $elapsed after the reboot.';
  }

  @override
  String get systemPowerOff =>
      'The server is shutting down. It stays off until someone starts it.';

  @override
  String get systemPowerStopWaiting => 'Stop waiting';

  @override
  String get systemUpdatesRestartsTitle => 'Services to restart';

  @override
  String get systemUpdatesRestartsRead => 'Find services to restart';

  @override
  String get systemUpdatesRestartsReadAgain => 'Look again';

  @override
  String get systemUpdatesRestartsReading => 'Looking for services to restart…';

  @override
  String get systemUpdatesRestartsAdminNeeded =>
      'Finding services that still run replaced libraries needs admin mode.';

  @override
  String get systemUpdatesRestartsNone => 'No service runs a replaced library.';

  @override
  String systemUpdatesRestartsList(String services) {
    return 'Restart to load the updated libraries: $services';
  }

  @override
  String get systemUpdatesKernelWaiting =>
      'A newer kernel is installed and waits for a reboot.';

  @override
  String systemUpdatesRestartsFailed(String reason) {
    String _temp0 = intl.Intl.selectLogic(reason, {
      'noLink':
          'The server is not connected, so services to restart could not be read.',
      'adminRequired': 'Admin mode ended before services to restart were read.',
      'elevationRefused':
          'Elevation was refused, so services to restart were not read.',
      'missing':
          'None of needrestart, needs-restarting or zypper is installed on this server.',
      'transport': 'The connection failed while services to restart were read.',
      'other': 'Services to restart could not be read.',
    });
    return '$_temp0';
  }

  @override
  String get fleetUpdatesTitle => 'Updates on all servers';

  @override
  String get fleetUpdatesOpen => 'All servers';

  @override
  String get fleetUpdatesCheckAll => 'Check every server again';

  @override
  String get fleetUpdatesNoServers => 'No servers yet.';

  @override
  String fleetUpdatesSummary(int updates, int security, String restart) {
    String _temp0 = intl.Intl.pluralLogic(
      updates,
      locale: localeName,
      other: '$updates updates',
      one: '1 update',
      zero: 'Up to date',
    );
    String _temp1 = intl.Intl.pluralLogic(
      security,
      locale: localeName,
      other: ', $security security',
      zero: '',
    );
    String _temp2 = intl.Intl.selectLogic(restart, {
      'true': ' · restart required',
      'other': '',
    });
    return '$_temp0$_temp1$_temp2';
  }

  @override
  String systemUpdatesCheckedAt(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'Checked $timeString';
  }

  @override
  String get doctorOpen => 'Run the doctor';

  @override
  String get doctorTitle => 'Doctor';

  @override
  String get doctorIntro =>
      'Read-only checks of this server, each with what to do about a finding. Nothing on the server changes.';

  @override
  String get doctorRunning => 'Checking…';

  @override
  String doctorSummary(int problems, int warnings) {
    String _temp0 = intl.Intl.pluralLogic(
      problems,
      locale: localeName,
      other: '$problems problems',
      one: '1 problem',
      zero: 'No problems',
    );
    String _temp1 = intl.Intl.pluralLogic(
      warnings,
      locale: localeName,
      other: '$warnings warnings',
      one: '1 warning',
      zero: 'no warnings',
    );
    return '$_temp0, $_temp1';
  }

  @override
  String get doctorAgain => 'Check again';

  @override
  String get doctorClose => 'Close';

  @override
  String doctorCheck(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'diskSpace': 'Disk space',
      'inodes': 'Inodes',
      'failedUnits': 'Failed units',
      'securityUpdates': 'Security updates',
      'rebootRequired': 'Reboot',
      'timeSync': 'Time sync',
      'certificates': 'Certificates',
      'dockerDiskUse': 'Docker disk use',
      'danglingImages': 'Dangling images',
      'other': 'Check',
    });
    return '$_temp0';
  }

  @override
  String doctorHint(String kind) {
    String _temp0 = intl.Intl.selectLogic(kind, {
      'diskSpace':
          'Remove old logs, caches and unused images, or grow the filesystem. Disks on the System tab lists every mount.',
      'inodes':
          'Many small files use up inodes: look for caches, mail queues or session files and remove what is no longer needed.',
      'failedUnits':
          'Open Services to read each unit\'s log, and restart it once the cause is fixed.',
      'securityUpdates':
          'Install them from Updates on the System tab or with the package manager.',
      'rebootRequired':
          'Reboot from Power on the System tab when it suits, so the updated kernel or libraries run.',
      'timeSync':
          'Turn time sync on (for example with timedatectl set-ntp true) and make sure the NTP server can be reached.',
      'certificates':
          'Renew or replace the certificate before it expires. Certificates on the System tab shows each endpoint.',
      'dockerDiskUse':
          'Remove unused images, stopped containers and build cache from the Docker tab.',
      'danglingImages':
          'Rebuilds leave untagged images behind. Remove them from Images with the Dangling filter.',
      'other': '',
    });
    return '$_temp0';
  }

  @override
  String get doctorUnknown =>
      'Not known: the reading failed or has not arrived.';

  @override
  String get doctorChecking => 'Reading…';

  @override
  String doctorSpaceOk(String percent) {
    return 'Every filesystem is under $percent full.';
  }

  @override
  String doctorSpaceFull(String percent) {
    return 'Filling up, the fullest at $percent:';
  }

  @override
  String doctorInodesOk(String percent) {
    return 'Every filesystem uses under $percent of its inodes.';
  }

  @override
  String doctorInodesFull(String percent) {
    return 'Running out of inodes, the fullest at $percent:';
  }

  @override
  String get doctorUnitsOk => 'No unit has failed.';

  @override
  String doctorUnitsFailed(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count units have failed:',
      one: '1 unit has failed:',
    );
    return '$_temp0';
  }

  @override
  String doctorSecurityPending(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count security updates are pending.',
      one: '1 security update is pending.',
    );
    return '$_temp0';
  }

  @override
  String doctorUpdatesUnclassified(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count updates are pending, and the package manager does not say which fix security issues.',
      one:
          '1 update is pending, and the package manager does not say whether it fixes a security issue.',
    );
    return '$_temp0';
  }

  @override
  String doctorSecurityNone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No security updates are pending; $count other updates are.',
      one: 'No security updates are pending; 1 other update is.',
      zero: 'No updates are pending.',
    );
    return '$_temp0';
  }

  @override
  String get doctorRebootNo => 'No reboot is needed.';

  @override
  String get doctorRebootYes =>
      'A reboot is needed. Packages that asked for it, where the host says:';

  @override
  String get doctorTimeOk => 'The clock is synchronized.';

  @override
  String get doctorTimeNotSynced => 'The clock is not synchronized.';

  @override
  String doctorTimeNotSyncedSkew(String skew) {
    return 'The clock is not synchronized; it reads $skew.';
  }

  @override
  String doctorClockOff(String skew) {
    return 'The clock reads $skew.';
  }

  @override
  String get doctorCertificatesNone =>
      'No endpoints are listed for this server.';

  @override
  String get doctorCertificatesSetUp =>
      'List endpoints under Certificates on the System tab to check them here.';

  @override
  String doctorCertificatesOk(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'All $count endpoints present valid certificates.',
      one: 'The endpoint presents a valid certificate.',
    );
    return '$_temp0';
  }

  @override
  String get doctorCertificatesBad =>
      'Failing, untrusted, expired or expiring within 14 days:';

  @override
  String doctorDockerReclaimable(String size) {
    return 'Docker could free $size of unused data.';
  }

  @override
  String get doctorDanglingNone => 'No dangling images.';

  @override
  String doctorDangling(int count, String size) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count dangling images take $size.',
      one: '1 dangling image takes $size.',
    );
    return '$_temp0';
  }

  @override
  String attentionNotice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count problems need attention',
      one: '1 problem needs attention',
    );
    return '$_temp0';
  }

  @override
  String get attentionShow => 'Show';

  @override
  String get attentionTitle => 'Attention';

  @override
  String get attentionIntro =>
      'Problems across the fleet, from what this device has read this run. Acknowledging one hides it until it clears; acknowledgements stay on this device.';

  @override
  String get attentionNone => 'Nothing needs attention.';

  @override
  String attentionAcknowledgedHeading(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Acknowledged ($count)',
      one: 'Acknowledged (1)',
    );
    return '$_temp0';
  }

  @override
  String get attentionClose => 'Close';

  @override
  String attentionAcknowledgedAt(DateTime time) {
    final intl.DateFormat timeDateFormat = intl.DateFormat.yMMMd(
      localeName,
    ).add_jm();
    final String timeString = timeDateFormat.format(time);

    return 'Acknowledged $timeString';
  }

  @override
  String get attentionAcknowledge => 'Acknowledge';

  @override
  String get attentionReopen => 'Reopen';

  @override
  String get attentionOpenServer => 'Open server';

  @override
  String get attentionBlocked =>
      'Connecting is blocked until you decide, for example about a changed host key.';

  @override
  String get attentionUnreachable =>
      'Cannot be reached: the last attempt failed.';

  @override
  String attentionAlert(String metric) {
    return 'Alert raised: $metric';
  }

  @override
  String attentionFailedUnit(String unit) {
    return 'Unit failed: $unit';
  }

  @override
  String attentionDiskFull(String mount, String percent) {
    return '$mount is $percent full';
  }

  @override
  String attentionInodesFull(String mount, String percent) {
    return '$mount uses $percent of its inodes';
  }

  @override
  String attentionUnhealthy(String container) {
    return 'Container unhealthy: $container';
  }

  @override
  String get attentionNoteTitle => 'Acknowledge the problem';

  @override
  String get attentionNoteLabel => 'Note (optional)';

  @override
  String get attentionCancel => 'Cancel';

  @override
  String get paletteCommand => 'Command Palette…';

  @override
  String get paletteActions => 'Actions';

  @override
  String get paletteServers => 'Servers';

  @override
  String paletteTabs(String server) {
    return '$server tabs';
  }

  @override
  String paletteContainers(String server) {
    return '$server containers';
  }

  @override
  String paletteContainerDescription(String state, String image) {
    return '$state · $image';
  }
}
