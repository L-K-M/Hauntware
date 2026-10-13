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
  String get syncFleet => 'Synchronize';

  @override
  String get openSettings => 'Settings';

  @override
  String get statusConnected => 'Connected';

  @override
  String get statusConnecting => 'Connecting';

  @override
  String get statusDisconnected => 'Disconnected';

  @override
  String get statusFailed => 'Failed';

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
}
