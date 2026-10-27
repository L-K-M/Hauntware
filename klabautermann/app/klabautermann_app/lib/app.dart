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

import 'controllers/admin_controller.dart';
import 'controllers/alert_center.dart';
import 'controllers/alert_notifications.dart';
import 'controllers/alert_rules_controller.dart';
import 'controllers/snippets_controller.dart';
import 'controllers/announcement_controller.dart';
import 'controllers/app_lock_controller.dart';
import 'controllers/pin_publication_controller.dart';
import 'controllers/safety_controller.dart';
import 'controllers/appearance_controller.dart';
import 'controllers/coverage_controller.dart';
import 'controllers/device_name.dart';
import 'controllers/docker_notice_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'controllers/operations_controller.dart';
import 'controllers/prompt_controller.dart';
import 'controllers/server_editor_controller.dart';
import 'controllers/sync_controller.dart';
import 'controllers/sync_secrets_controller.dart';
import 'l10n/app_localizations.dart';
import 'services/settings_window/settings_window_link.dart';
import 'services/hand_off.dart' show HandOffLauncher;
import 'theme/app_theme.dart';
import 'ui/actions/action_entry.dart' show OperationsScope;
import 'ui/actions/action_preview.dart' show ActionResultToasts;
import 'ui/adaptive_shell.dart';
import 'ui/admin_mode_chip.dart' show AdminScope;
import 'ui/alert_notifications.dart' show AlertNotificationsScope;
import 'ui/alert_rules.dart' show AlertRulesScope;
import 'ui/snippets.dart' show SnippetsScope;
import 'ui/alerts.dart' show AlertScope;
import 'ui/app_lock_gate.dart';
import 'ui/docker/docker_panel.dart' show DockerNoticeScope;
import 'ui/hand_off_actions.dart' show HandOffScope;
import 'ui/macos_toolbar_band.dart';
import 'ui/menus/app_commands.dart';
import 'ui/menus/app_menu_host.dart';
import 'ui/prompts/prompt_host.dart';
import 'ui/server_editing.dart';
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
    this.deviceName,
    this.safety,
    this.appLock,
    this.syncSecrets,
    this.pinPublication,
    this.admin,
    this.alerts,
    this.alertRules,
    this.snippets,
    this.alertNotifications,
    this.operations,
    required this.dockerNotice,
    this.sync,
    this.serverEditor,
    this.settingsIssue,
    this.importStoreIssue,
    this.syncStoreIssues = const [],
    this.instanceLockIssue,
    this.openSettingsWindow,
    this.toolbarBand,
    this.appVersion,
    this.handOff,
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

  /// The app lock (SAF-20), whose screen covers every route while locked;
  /// null in tests that leave it out.
  final AppLockController? appLock;

  /// The device name the host syslog line gives (M5 plan Q6); like
  /// [appearance], it outlives an engine run. Null in tests that leave it
  /// out, where General settings show no device name.
  final DeviceNameController? deviceName;

  /// The device's "sync passwords" switch (SYN-02); like [appearance], it
  /// outlives an engine run. Null in tests that leave it out, where the
  /// Sync settings tab is a placeholder.
  final SyncSecretsController? syncSecrets;

  /// The host key sharing assertion (M5 plan M07), one engine run's like
  /// [sync]; null in tests that leave it out.
  final PinPublicationController? pinPublication;

  /// Admin mode per server (03 §8.2), one engine run's like [fleet]. Null
  /// in tests that leave it out, where the header shows no admin chip.
  final AdminController? admin;

  /// The in-app alerts the engine's rules raise (ALR-01), one engine run's
  /// like [fleet]. Null in tests that leave it out, where the fleet shows
  /// no alert notice or badges.
  final AlertCenter? alerts;

  /// The account's alert rules and their editor (ALR-01), one engine
  /// run's like [fleet]. Null in tests that leave it out, where no surface
  /// offers the rules page.
  final AlertRulesController? alertRules;

  /// Séance's synced snippets (AUT-01), one engine run's like [fleet].
  /// Null in tests that leave it out, where no surface offers them.
  final SnippetsController? snippets;

  /// Raised alerts' system notifications (ALR-01), one engine run's like
  /// [fleet]. Null in tests that leave it out, where no surface offers
  /// the switch.
  final AlertNotificationsController? alertNotifications;

  /// Previews and runs of actions (03 §8.5), one engine run's like
  /// [fleet]. Null in tests that leave it out, where no action can run.
  final OperationsController? operations;

  /// Whether the Docker tab still shows SAF-08's notice on this device
  /// (03 §8.4); like [appearance], it outlives an engine run.
  final DockerNoticeController dockerNotice;

  /// Opens hand-offs to Séance and Poltergeist (X-03, X-04, X-10); null in
  /// tests that leave it out, where no hand-off is offered.
  final HandOffLauncher? handOff;

  /// The sync account (03 §4.3), one engine run's like [fleet]; null in
  /// tests that leave sync out, which shows the sync control idle.
  final SyncController? sync;

  /// In-app server editing over the engine (FL-03), one engine run's like
  /// [sync]. Editing is offered only with both and an enrolled account
  /// (P16); null in tests that leave it out.
  final ServerEditorController? serverEditor;

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

  /// The running build's version for the About dialog and Settings >
  /// General (`readAppVersion`); null when the platform could not tell,
  /// and in tests that leave it out.
  final String? appVersion;

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

  /// [child] under the run results' toasts, which need the navigator's
  /// overlay above them; as it is without operations.
  Widget _withResultToasts(Widget child) => switch (operations) {
    final operations? => ActionResultToasts(
      operations: operations,
      child: child,
    ),
    null => child,
  };

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

  /// Server editing, when both its controllers are given.
  ServerEditing? get _serverEditing => switch ((serverEditor, sync)) {
    (final editor?, final sync?) => ServerEditing(
      editor: editor,
      sync: sync,
      fleet: fleet,
    ),
    _ => null,
  };

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
          // the announcement switch, and the Docker tab its notice, on
          // every route, the phone's pushed server screen included.
          builder: (context, child) {
            final scoped = DockerNoticeScope(
              notice: dockerNotice,
              child: AnnouncementScope(
                announce: announcements,
                openSettings: (context) => unawaited(_openSettings(context)),
                child: withMacosToolbarBand(toolbarBand, child: child!),
              ),
            );
            final withOperations = switch (operations) {
              final operations? => OperationsScope(
                operations: operations,
                child: scoped,
              ),
              null => scoped,
            };
            final withAdmin = switch (admin) {
              final admin? => AdminScope(admin: admin, child: withOperations),
              null => withOperations,
            };
            final withSafety = switch (safety) {
              final safety? => SafetyScope(safety: safety, child: withAdmin),
              null => withAdmin,
            };
            final withEditing = switch (_serverEditing) {
              final editing? => ServerEditingScope(
                editing: editing,
                child: withSafety,
              ),
              null => withSafety,
            };
            final withRules = switch (alertRules) {
              final rules? => AlertRulesScope(rules: rules, child: withEditing),
              null => withEditing,
            };
            final withSnippets = switch (snippets) {
              final snippets? => SnippetsScope(
                snippets: snippets,
                child: withRules,
              ),
              null => withRules,
            };
            final withNotifications = switch (alertNotifications) {
              final notifications? => AlertNotificationsScope(
                notifications: notifications,
                child: withSnippets,
              ),
              null => withSnippets,
            };
            final withAlerts = switch (alerts) {
              final alerts? => AlertScope(
                alerts: alerts,
                child: withNotifications,
              ),
              null => withNotifications,
            };
            final withHandOff = switch (handOff) {
              final handOff? => HandOffScope(
                launcher: handOff,
                child: withAlerts,
              ),
              null => withAlerts,
            };
            return switch (appLock) {
              final appLock? => AppLockGate(lock: appLock, child: withHandOff),
              null => withHandOff,
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
              labelOf: (serverId) =>
                  fleet.servers
                      .where((server) => server.id == serverId)
                      .firstOrNull
                      ?.displayName ??
                  serverId,
              child: _withResultToasts(
                Builder(
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
                        appVersion: appVersion,
                      ),
                      // The add verbs follow the enrollment (P16).
                      child: ListenableBuilder(
                        listenable: Listenable.merge([?sync]),
                        builder: (context, _) => AdaptiveShell(
                          fleet: fleet,
                          monitoring: monitoring,
                          coverage: coverage,
                          onOpenSettings: openSettings,
                          sync: sync,
                          onAddServer: switch (_serverEditing) {
                            final editing? when editing.enabled =>
                              () =>
                                  unawaited(openServerEditor(context, editing)),
                            _ => null,
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          routes: {
            kSettingsRoute: (_) => SettingsPage(
              appearance: appearance,
              announcements: announcements,
              deviceName: deviceName,
              appVersion: appVersion,
              monitorSet: fleet.monitorSettings,
              safety: safety,
              appLock: appLock,
              syncSecrets: syncSecrets,
              pinPublication: pinPublication,
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
