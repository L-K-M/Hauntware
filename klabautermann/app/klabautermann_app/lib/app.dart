import 'package:flutter/material.dart';

import 'controllers/appearance_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'l10n/app_localizations.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
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
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final AppearanceController appearance;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        return MaterialApp(
          onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: klabautermannTheme(
            Brightness.light,
            Theme.of(context).platform,
          ),
          darkTheme: klabautermannTheme(
            Brightness.dark,
            Theme.of(context).platform,
          ),
          themeMode: appearance.themeMode,
          // The shell's settings callback needs a context under the
          // MaterialApp's Navigator; the ListenableBuilder's own context
          // sits above it.
          home: Builder(
            builder: (context) => AdaptiveShell(
              fleet: fleet,
              monitoring: monitoring,
              onOpenSettings: () =>
                  Navigator.of(context).pushNamed(kSettingsRoute),
            ),
          ),
          routes: {kSettingsRoute: (_) => SettingsPage(appearance: appearance)},
        );
      },
    );
  }
}
