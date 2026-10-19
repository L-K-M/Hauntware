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
      'Klabautermann is free and unencumbered software released into the public domain under the Unlicense.';

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
  String get accessReasonPendingDocker =>
      'Checked once Docker support arrives.';

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
      'Podman can also answer on Docker\'s socket path. Docker support will tell them apart.';

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
  String get settingsAnnounceBands => 'Announce threshold changes';

  @override
  String get settingsAnnounceBandsDetail =>
      'While a server\'s Overview shows, your screen reader hears when CPU, memory or a disk crosses into or out of its warning or critical level. Values that refresh every few seconds are never read out.';

  @override
  String get settingsAnnounceNotSaved =>
      'The setting changed, but it could not be saved, so it will not be kept after a restart.';

  @override
  String get settingsAnnounceNotChanged => 'The setting could not be changed.';

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
  String get syncDisclosureAccountKey =>
      'Your encryption passphrase opens the records of every app on this account, Séance and Poltergeist included.';

  @override
  String get syncDisclosurePullOnly =>
      'Klabautermann only reads this account. It publishes nothing: no servers, host keys or passwords.';

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
  String get serverObserveOnly =>
      'Observe only: Klabautermann reads this server and changes nothing. To act on it, turn on Allow actions in the Safety menu.';

  @override
  String get serverReadOnlyNotice =>
      'Read-only: actions on this server are hidden.';

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
      'interruptsTarget': 'This interrupts what the target is doing.',
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
  String get jobsRunNow => 'Run now';

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
      'ContainerAction': 'Container action',
      'RemoveContainer': 'Remove container',
      'RemoveImage': 'Remove image',
      'StackAction': 'Stack action',
      'RedeployStack': 'Redeploy stack',
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
      'Your account cannot use the engine socket. Reaching it through sudo needs admin mode, which arrives in a later milestone.';

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
  String get dockerRetry => 'Try again';

  @override
  String get dockerTabContainers => 'Containers';

  @override
  String get dockerTabImages => 'Images';

  @override
  String get dockerTabStacks => 'Stacks';

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
}
