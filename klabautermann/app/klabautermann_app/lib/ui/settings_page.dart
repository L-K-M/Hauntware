import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/appearance_controller.dart';
import '../l10n/app_localizations.dart';
import 'inspector_pane.dart' show PlaceholderPaneBody;

/// The settings route (03 §10.2): the seven planned tabs as placeholders,
/// except Appearance, which already drives [AppearanceController]. On
/// desktop this becomes a second window through `GhostSettingsWindowHost`
/// when the native runners land (D32); the route stays the mobile and
/// fallback path.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.appearance});

  final AppearanceController appearance;

  static List<String> _tabLabels(AppLocalizations l10n) => [
    l10n.settingsTabGeneral,
    l10n.settingsTabAppearance,
    l10n.settingsTabSync,
    l10n.settingsTabServers,
    l10n.settingsTabDocker,
    l10n.settingsTabSafety,
    l10n.settingsTabAlerts,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tabs = _tabLabels(l10n);
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.settingsTitle),
          bottom: TabBar(
            isScrollable: true,
            tabs: [for (final label in tabs) Tab(text: label)],
          ),
        ),
        body: TabBarView(
          children: [
            const PlaceholderPaneBody(),
            AppearanceTab(appearance: appearance),
            for (var i = 0; i < tabs.length - 2; i++)
              const PlaceholderPaneBody(),
          ],
        ),
      ),
    );
  }
}

/// The working part of settings at M1a: the theme-mode choice, so
/// light/dark switching is real from the first scaffold (03 §10.9).
class AppearanceTab extends StatelessWidget {
  const AppearanceTab({super.key, required this.appearance});

  final AppearanceController appearance;

  /// The theme changes at once; a save that fails says so in a top toast
  /// (the suite keeps the bottom edge clear), since the change then lasts
  /// only until the app restarts.
  Future<void> _setMode(BuildContext context, ThemeModePreference mode) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notSaved = AppLocalizations.of(context).themeNotSaved;
    try {
      await appearance.setMode(mode);
    } on Exception catch (error) {
      debugPrint('The theme was not saved: $error');
      if (overlay.mounted) showTopToast(overlay, message: notSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              l10n.themeLabel,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SegmentedButton<ThemeModePreference>(
              segments: [
                ButtonSegment(
                  value: ThemeModePreference.system,
                  label: Text(l10n.themeSystem),
                ),
                ButtonSegment(
                  value: ThemeModePreference.light,
                  label: Text(l10n.themeLight),
                ),
                ButtonSegment(
                  value: ThemeModePreference.dark,
                  label: Text(l10n.themeDark),
                ),
              ],
              selected: {appearance.mode},
              onSelectionChanged: (modes) =>
                  unawaited(_setMode(context, modes.first)),
            ),
          ],
        );
      },
    );
  }
}
