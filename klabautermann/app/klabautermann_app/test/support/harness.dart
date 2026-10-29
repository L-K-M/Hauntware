import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show GhostUndoHistory;
import 'package:klabautermann_app/app.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/alert_center.dart';
import 'package:klabautermann_app/controllers/alert_notifications.dart';
import 'package:klabautermann_app/controllers/alert_rules_controller.dart';
import 'package:klabautermann_app/controllers/announcement_controller.dart';
import 'package:klabautermann_app/controllers/appearance_controller.dart';
import 'package:klabautermann_app/controllers/coverage_controller.dart';
import 'package:klabautermann_app/controllers/docker_endpoint_choices.dart';
import 'package:klabautermann_app/controllers/docker_notice_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/pin_publication_controller.dart';
import 'package:klabautermann_app/controllers/prompt_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/controllers/server_editor_controller.dart';
import 'package:klabautermann_app/controllers/sync_controller.dart';
import 'package:klabautermann_app/controllers/window_panes.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/hand_off.dart';
import 'package:klabautermann_app/services/settings_window/settings_window_link.dart';
import 'package:klabautermann_app/services/ssh_config_source.dart';
import 'package:klabautermann_app/services/system_notifications.dart';
import 'package:klabautermann_app/ui/alerts.dart' show alertNotificationText;
import 'package:klabautermann_app/ui/workspace_navigation.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        DeviceSettingsIssue,
        ImportStoreIssue,
        InstanceLockUnavailable,
        PinPublicationState,
        SyncAccountInfo,
        SyncStoreIssue;

import 'fake_engine.dart';

/// Everything a widget test drives the app through (03 §10.1: one controller
/// per concern, handed to the composition root's view by constructor).
final class AppHarness {
  AppHarness({
    required this.engine,
    required this.fleet,
    required this.monitoring,
    required this.prompts,
    required this.appearance,
    required this.coverage,
    required this.announcements,
    required this.dockerNotice,
    required this.sync,
    required this.serverEditor,
    this.admin,
    this.alerts,
    this.alertRules,
    this.alertNotifications,
    this.operations,
    required this.windowPanes,
    required this.undoHistory,
  });

  final FakeEngineClient engine;
  final FleetController fleet;
  final MonitoringController monitoring;
  final PromptController prompts;
  final AppearanceController appearance;
  final CoverageController coverage;
  final AnnouncementController announcements;
  final DockerNoticeController dockerNotice;
  final SyncController sync;
  final ServerEditorController serverEditor;
  final AdminController? admin;
  final AlertCenter? alerts;
  final AlertRulesController? alertRules;
  final AlertNotificationsController? alertNotifications;
  final OperationsController? operations;
  final WindowPanesController windowPanes;
  final GhostUndoHistory undoHistory;

  void dispose() {
    fleet.dispose();
    monitoring.dispose();
    prompts.dispose();
    appearance.dispose();
    coverage.dispose();
    announcements.dispose();
    dockerNotice.dispose();
    switch (sync.pinPublication) {
      case final PinPublicationController controller:
        controller.dispose();
      case _:
    }
    sync.dispose();
    serverEditor.dispose();
    admin?.dispose();
    alerts?.dispose();
    alertRules?.dispose();
    alertNotifications?.dispose();
    operations?.dispose();
    windowPanes.dispose();
    undoHistory.dispose();
  }
}

/// Pumps the real [KlabautermannApp] over a [FakeEngineClient] at [size],
/// which is what decides the shell (03 §10.2 desktop, §10.5 phone).
/// [sshConfig] stands in for the platform's ssh_config source: a fake for a
/// desktop, null (the default) for a phone, as `sshConfigSourceFor` picks.
/// [openSettingsWindow] likewise stands in for the desktop settings window
/// (null, the default, is a phone's route). [appearance] replaces the
/// in-memory controller, for a test that builds one over a settings store
/// or under a settings window host (the harness disposes it), and
/// [settingsIssue] is what opening that store reported. [importStoreIssue]
/// stands in for what the engine's handshake reported about its import
/// store, [instanceLockIssue] for an instance lock that could not be
/// taken, and [toolbarBand] for the macOS integrated titlebar's band
/// state. [syncAccount] is the sync account the engine started with and
/// [syncStoreIssues] what it reported about its sync files. [coverage]
/// replaces a controller whose first-run card was
/// already dismissed, so the card shows only in the tests that want it.
/// [announcements] replaces an in-memory A11Y-15 switch that is on, and
/// [dockerNotice] an in-memory SAF-08 notice not yet dismissed, and
/// [dockerEndpointChoices] the Docker controller's in-memory socket
/// choices (the caller disposes one it passes).
/// [appVersion] stands in for what `readAppVersion` read. [safety], which
/// the caller disposes, adds the safety preferences; none leaves the
/// Safety menu and notices out. [admin] adds the admin mode controller
/// over the fake engine, [alerts] the alert center, the alert rules and
/// the alert notifications, posting to [notifications] (none: the device
/// has none), and [operations] the operations one.
/// [palette] adds the command palette's workspace navigation.
/// [linkGrace] defaults to zero, which disconnects a server as its last
/// view closes: the tree unmounts at the end of every test, and the test
/// binding fails a test that leaves a grace timer pending.
Future<AppHarness> pumpApp(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  List<FleetServer> servers = const [],
  SshConfigSource? sshConfig,
  AppearanceController? appearance,
  CoverageController? coverage,
  AnnouncementController? announcements,
  SafetyController? safety,
  bool admin = false,
  bool alerts = false,
  SystemNotifications? notifications,
  bool operations = false,
  DockerNoticeController? dockerNotice,
  DockerEndpointChoices? dockerEndpointChoices,
  DeviceSettingsIssue? settingsIssue,
  ImportStoreIssue? importStoreIssue,
  InstanceLockUnavailable? instanceLockIssue,
  SyncAccountInfo? syncAccount,
  PinPublicationState? pinPublication,
  List<SyncStoreIssue> syncStoreIssues = const [],
  OpenSettingsWindow? openSettingsWindow,
  ValueListenable<bool>? toolbarBand,
  String? appVersion,
  HandOffLauncher? handOff,
  Duration linkGrace = Duration.zero,
  bool palette = false,
  WindowPanesController? windowPanes,
  GhostUndoHistory? undoHistory,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final harness = AppHarness(
    engine: engine,
    fleet: FleetController(engine, servers: servers, sshConfig: sshConfig),
    monitoring: MonitoringController(
      engine,
      linkGrace: linkGrace,
      dockerEndpointChoices: dockerEndpointChoices,
    ),
    prompts: PromptController(engine),
    appearance: appearance ?? AppearanceController(),
    coverage: coverage ?? CoverageController(firstRunCardDismissed: true),
    announcements: announcements ?? AnnouncementController(),
    dockerNotice: dockerNotice ?? DockerNoticeController(),
    sync: SyncController(
      engine,
      account: syncAccount,
      pinPublication: pinPublication == null
          ? null
          : PinPublicationController(engine, initial: pinPublication),
    ),
    serverEditor: ServerEditorController(engine),
    admin: admin ? AdminController(engine) : null,
    alerts: alerts ? AlertCenter(engine) : null,
    alertRules: alerts ? AlertRulesController(engine) : null,
    alertNotifications: alerts
        ? AlertNotificationsController(
            engine,
            notifications: notifications,
            textOf: (raise) => alertNotificationText(
              lookupAppLocalizations(const Locale('en')),
              raise,
              server:
                  servers
                      .where((server) => server.id == raise.serverId)
                      .firstOrNull
                      ?.displayName ??
                  raise.serverId,
            ),
          )
        : null,
    operations: operations ? OperationsController(engine) : null,
    windowPanes: windowPanes ?? WindowPanesController(),
    undoHistory: undoHistory ?? GhostUndoHistory(),
  );
  addTearDown(() async {
    harness.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    KlabautermannApp(
      fleet: harness.fleet,
      monitoring: harness.monitoring,
      prompts: harness.prompts,
      appearance: harness.appearance,
      coverage: harness.coverage,
      announcements: harness.announcements,
      safety: safety,
      admin: harness.admin,
      alerts: harness.alerts,
      alertRules: harness.alertRules,
      alertNotifications: harness.alertNotifications,
      operations: harness.operations,
      dockerNotice: harness.dockerNotice,
      sync: harness.sync,
      serverEditor: harness.serverEditor,
      pinPublication: switch (harness.sync.pinPublication) {
        final PinPublicationController controller => controller,
        _ => null,
      },
      settingsIssue: settingsIssue,
      importStoreIssue: importStoreIssue,
      syncStoreIssues: syncStoreIssues,
      instanceLockIssue: instanceLockIssue,
      openSettingsWindow: openSettingsWindow,
      toolbarBand: toolbarBand,
      appVersion: appVersion,
      handOff: handOff,
      navigation: palette ? WorkspaceNavigation(harness.fleet) : null,
      windowPanes: harness.windowPanes,
      undoHistory: harness.undoHistory,
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

/// The ARB strings the widget tests assert against by their English text.
const List<FleetServer> twoServers = [
  FleetServer(id: 'srv-1', displayName: 'web-1', address: 'web-1.example'),
  FleetServer(id: 'srv-2', displayName: 'db-1', address: '10.0.0.4'),
];
