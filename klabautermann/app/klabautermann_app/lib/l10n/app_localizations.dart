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

  /// Shown instead of sshConfigImported when the import left host blocks out; importedCount (0 or more) is the number of servers it added, skippedCount (1 or more) the number of host blocks it left out. One message, so the translation decides how its sentences join.
  ///
  /// In en, this message translates to:
  /// **'{importedCount, plural, =0{No hosts were imported from ~/.ssh/config.} =1{Imported 1 server from ~/.ssh/config.} other{Imported {importedCount} servers from ~/.ssh/config.}} {skippedCount, plural, =1{1 host was skipped because its port is invalid or its name repeats an earlier host.} other{{skippedCount} hosts were skipped because their port is invalid or their name repeats an earlier host.}}'**
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

  /// Snack bar shown when the app did not take a theme-mode change made in Settings.
  ///
  /// In en, this message translates to:
  /// **'The theme could not be changed.'**
  String get themeNotChanged;

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
