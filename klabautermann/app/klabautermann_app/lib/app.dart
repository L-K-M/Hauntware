import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostTheme;
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        DeviceSettingsIssue,
        ImportStoreIssue,
        InstanceLockUnavailable,
        SyncStoreIssue;

import 'controllers/announcement_controller.dart';
import 'controllers/safety_controller.dart';
import 'controllers/appearance_controller.dart';
import 'controllers/coverage_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'controllers/prompt_controller.dart';
import 'controllers/sync_controller.dart';
import 'l10n/app_localizations.dart';
import 'services/settings_window/settings_window_link.dart';
import 'theme/app_theme.dart';
import 'ui/adaptive_shell.dart';
import 'ui/macos_toolbar_band.dart';
import 'ui/menus/app_commands.dart';
import 'ui/menus/app_menu_host.dart';
import 'ui/prompts/prompt_host.dart';
import 'ui/server_safety.dart' show SafetyScope;
import 'ui/server_surfaces.dart' show AppActivityReporter;
import 'ui/settings_page.dart';
import 'ui/startup_issue_notice.dart';
import 'ui/threshold_announcer.dart' show AnnouncementScope;

/// The settings route's name: Settings on phones, and on a desktop whose
/// runner cannot open the settings window (D32).
const String kSettingsRoute = '/settings';

/// The composition root's view (03 §10.1): one `MaterialApp` whose only
/// rebuild input is [AppearanceController]; fleet, monitoring and prompt
/// changes reach surfaces through their own listenables.
class KlabautermannApp extends StatelessWidget {
  const KlabautermannApp({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.prompts,
    required this.appearance,
    required this.coverage,
    required this.announcements,
    this.safety,
    this.sync,
    this.settingsIssue,
    this.importStoreIssue,
    this.syncStoreIssues = const [],
    this.instanceLockIssue,
    this.openSettingsWindow,
    this.toolbarBand,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// The engine's prompts, which [PromptHost] shows over every route.
  final PromptController prompts;
  final AppearanceController appearance;

  /// Whether the first-run coverage card still shows (03 §9.5 item 1).
  /// Like [appearance], it outlives an engine run.
  final CoverageController coverage;

  /// Whether threshold-band changes are announced (A11Y-15, D60); like
  /// [appearance], it outlives an engine run.
  final AnnouncementController announcements;

  /// The safety preferences the engine enforces (M4 plan M4); like
  /// [appearance], they outlive an engine run. Null in tests that leave
  /// safety out: Settings then shows its placeholder and the server header
  /// neither the Safety menu nor its notices.
  final SafetyController? safety;

  /// The sync account (03 §4.3), one engine run's like [fleet]; null in
  /// tests that leave sync out, which shows the sync control idle.
  final SyncController? sync;

  /// What went wrong opening `settings.json`, told once at startup.
  final DeviceSettingsIssue? settingsIssue;

  /// What went wrong when the engine loaded `ssh_config_imports.json`,
  /// told once at startup beside [settingsIssue].
  final ImportStoreIssue? importStoreIssue;

  /// What was wrong with the engine's sync state files at start (03
  /// §4.10), told once beside [importStoreIssue].
  final List<SyncStoreIssue> syncStoreIssues;

  /// Why the instance lock could not be taken, told once at startup: this
  /// desktop instance runs without the guard against a second one.
  final InstanceLockUnavailable? instanceLockIssue;

  /// Opens Settings in its own window; null on phones, where Settings is
  /// [kSettingsRoute].
  final OpenSettingsWindow? openSettingsWindow;

  /// Whether the macOS unified toolbar band shows, when the window has the
  /// integrated titlebar (`installMacosTitlebar`); null everywhere else,
  /// and then no surface reserves a band.
  final ValueListenable<bool>? toolbarBand;

  /// The settings window where there is one, otherwise the route. A window
  /// that cannot open falls back to the route, so Settings stays reachable,
  /// whatever it fails with (an error too, as Séance's fallback does).
  Future<void> _openSettings(BuildContext context) async {
    final openWindow = openSettingsWindow;
    if (openWindow != null) {
      try {
        if (await openWindow(SettingsTab.general)) return;
      } on Object catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            context: ErrorDescription('while opening the settings window'),
          ),
        );
      }
    }
    if (!context.mounted) return;
    unawaited(Navigator.of(context).pushNamed(kSettingsRoute));
  }

  @override
  Widget build(BuildContext context) {
    // Controllers last one engine run (D44), and routes and surfaces keep
    // the ones they were built with, so new ones remount the whole tree:
    // every surface then opens and subscribes on the new engine.
    return _RemountOnChange(
      identity: (fleet, monitoring, prompts),
      // On phones the engine pauses sampling while the user cannot see the
      // app (03 §6.4); the reporter tells it when that changes.
      child: AppActivityReporter(
        monitoring: monitoring,
        child: _buildApp(context),
      ),
    );
  }

  Widget _buildApp(BuildContext context) {
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
          // The band is reserved above every route, so nothing
          // interactive lands under the traffic lights. The Overview reads
          // the announcement switch on every route, the phone's pushed
          // server screen included.
          builder: (context, child) {
            final scoped = AnnouncementScope(
              announce: announcements,
              openSettings: (context) => unawaited(_openSettings(context)),
              child: withMacosToolbarBand(toolbarBand, child: child!),
            );
            return switch (safety) {
              final safety? => SafetyScope(safety: safety, child: scoped),
              null => scoped,
            };
          },
          // The shell's settings callback and the menus' commands need a
          // context under the MaterialApp's Navigator; the
          // ListenableBuilder's own context sits above it.
          home: StartupIssueNotice(
            settingsIssue: settingsIssue,
            importStoreIssue: importStoreIssue,
            syncStoreIssues: syncStoreIssues,
            instanceLockIssue: instanceLockIssue,
            // The home route stays mounted under every other route, so
            // its dialogs come up over Settings too.
            child: PromptHost(
              prompts: prompts,
              child: Builder(
                builder: (context) {
                  void openSettings() => unawaited(_openSettings(context));
                  // The desktop menus and their shortcuts (03 §10.2),
                  // from the one command registry.
                  return AppMenuHost(
                    listenable: fleet,
                    commands: buildAppCommands(
                      platform: Theme.of(context).platform,
                      fleet: fleet,
                      onOpenSettings: openSettings,
                    ),
                    child: AdaptiveShell(
                      fleet: fleet,
                      monitoring: monitoring,
                      coverage: coverage,
                      onOpenSettings: openSettings,
                      sync: sync,
                    ),
                  );
                },
              ),
            ),
          ),
          routes: {
            kSettingsRoute: (_) => SettingsPage(
              appearance: appearance,
              announcements: announcements,
              monitorSet: fleet.monitorSettings,
              safety: safety,
            ),
          },
        );
      },
    );
  }
}

/// Remounts [child] when [identity] changes, across two frames: the first
/// shows nothing and disposes the old tree as it ends, and the next mounts
/// the new one. A swap within one frame would mount the new tree while the
/// old one is only deactivated, but some platform state has one owner at a
/// time: macOS's [PlatformMenuBar] asserts on a second bar, and the old
/// bar's dispose would clear the native menus the new one had just set.
/// The blank frame only comes with new controllers, an engine restart.
class _RemountOnChange extends StatefulWidget {
  const _RemountOnChange({required this.identity, required this.child});

  final Object identity;
  final Widget child;

  @override
  State<_RemountOnChange> createState() => _RemountOnChangeState();
}

class _RemountOnChangeState extends State<_RemountOnChange> {
  bool _clearing = false;

  @override
  void didUpdateWidget(_RemountOnChange oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity == oldWidget.identity) return;

    _clearing = true;
    // Post-frame callbacks run after the frame has disposed what it
    // unmounted, so the old tree is gone when the new one builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _clearing = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_clearing) return const SizedBox.shrink();
    return widget.child;
  }
}
