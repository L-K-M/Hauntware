import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostTheme;
import 'package:klabautermann_core/klabautermann_core.dart'
    show DeviceSettingsIssue;

import 'controllers/appearance_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'l10n/app_localizations.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/settings_issue_notice.dart';
import 'ui/settings_page.dart';

/// The settings route's name; desktop gets a second window later (D32),
/// this stays the mobile and fallback path.
const String kSettingsRoute = '/settings';

/// The composition root's view (03 §10.1): one `MaterialApp` whose only
/// rebuild input is [AppearanceController]; fleet and monitoring changes
/// reach surfaces through their own listenables.
class KlabautermannApp extends StatelessWidget {
  const KlabautermannApp({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.appearance,
    this.settingsIssue,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final AppearanceController appearance;

  /// What went wrong opening `settings.json`, told once at startup.
  final DeviceSettingsIssue? settingsIssue;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        // Built through ghost_theme the way Séance draws its MaterialApp
        // (03 D9): the extensions shared widgets read come with it.
        final themes = GhostTheme.forAppearance(
          klabautermannThemeStyle,
          appearance.value,
        );
        return MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: themes.theme,
          darkTheme: themes.darkTheme,
          themeMode: themes.themeMode,
          // The shell's settings callback needs a context under the
          // MaterialApp's Navigator; the ListenableBuilder's own context
          // sits above it.
          home: SettingsIssueNotice(
            issue: settingsIssue,
            child: Builder(
              builder: (context) => AdaptiveShell(
                fleet: fleet,
                monitoring: monitoring,
                onOpenSettings: () =>
                    Navigator.of(context).pushNamed(kSettingsRoute),
              ),
            ),
          ),
          routes: {kSettingsRoute: (_) => SettingsPage(appearance: appearance)},
        );
      },
    );
  }
}
