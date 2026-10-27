import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ServicesBinding;
import 'package:ghost_licenses/ghost_licenses.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'controllers/admin_controller.dart';
import 'controllers/alert_center.dart';
import 'controllers/alert_notifications.dart';
import 'controllers/alert_rules_controller.dart';
import 'controllers/announcement_controller.dart';
import 'controllers/app_lock_controller.dart';
import 'controllers/attention.dart';
import 'controllers/cadence_controller.dart';
import 'controllers/container_columns.dart';
import 'controllers/coverage_controller.dart';
import 'controllers/device_name.dart';
import 'controllers/pin_publication_controller.dart';
import 'controllers/docker_endpoint_choices.dart';
import 'controllers/docker_notice_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitor_set.dart';
import 'controllers/monitoring_controller.dart';
import 'controllers/operations_controller.dart';
import 'controllers/prompt_controller.dart';
import 'controllers/server_editor_controller.dart';
import 'controllers/server_prefs_controller.dart';
import 'controllers/stack_folders.dart';
import 'controllers/tls_endpoints.dart';
import 'controllers/sync_controller.dart';
import 'controllers/sync_secrets_controller.dart';
import 'controllers/threshold_controller.dart';
import 'l10n/app_localizations.dart';
import 'services/app_version.dart';
import 'services/device_authenticator.dart';
import 'services/engine_keystore.dart';
import 'services/hand_off.dart';
import 'services/instance_guard.dart';
import 'services/macos_titlebar.dart';
import 'services/settings_window/settings_window_host.dart';
import 'services/settings_window/settings_window_link.dart';
import 'services/ssh_config_source.dart';
import 'services/stored_appearance.dart';
import 'services/stored_safety.dart';
import 'services/system_notifications.dart';
import 'services/window_state.dart';
import 'settings_window_app.dart';
import 'ui/alerts.dart' show alertNotificationText;
import 'ui/already_running_app.dart';
import 'ui/workspace_navigation.dart' show WorkspaceNavigation;

/// The composition root (03 §10.1): the settings-window branch, the
/// instance lock, the macOS titlebar, then the device settings store, the
/// main window's restored frame, the engine isolate, one `ChangeNotifier`
/// controller per concern built over them, the keystore that answers the
/// engine's sync (D62), and `runApp`. The catalog stores and the vault
/// are the engine's (03 §4.10, D63).
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The licenses page lists the APK's Maven libraries too (Android).
  registerPlatformLicenses();

  // The desktop settings window's engine runs this same entrypoint (D32).
  // It is a second Flutter engine whose isolate shares nothing with this
  // one, so it gets the settings window's app and nothing below: no second
  // engine isolate (D18), no sync, no stores, and never settings.json,
  // which only the app's isolate opens. Everything it needs crosses the
  // settings link.
  if (args.contains(settingsWindowArgument)) {
    await runSettingsWindow();
    return;
  }

  // One desktop instance (03 §4.10): the support directory's lock comes
  // before settings.json, window_state.json and the engine isolate, so a
  // second instance never reads or writes any of them, and the device id
  // below is minted by one process only. The lock lasts as long as this
  // process. When it cannot be taken at all, the app runs unguarded and
  // says so after the first frame rather than refusing to start.
  final supportDirectory = await getApplicationSupportDirectory();
  InstanceLockUnavailable? instanceLockIssue;
  final instanceLock = await lockInstanceFor(
    defaultTargetPlatform,
    supportDirectory,
  );
  switch (instanceLock) {
    case null || InstanceLockAcquired():
      break;
    case InstanceLockHeld():
      debugPrint('Klabautermann is already running; this instance quits.');
      // The frame is the running instance's to restore and save, so this
      // window stays where the runner put it, with the standard titlebar;
      // on macOS it still has to be shown.
      await showMainWindowUnrestored(platform: defaultTargetPlatform);
      runApp(
        AlreadyRunningApp(
          onQuit: () => unawaited(
            ServicesBinding.instance.exitApplication(AppExitType.required),
          ),
        ),
      );
      return;
    case final InstanceLockUnavailable issue:
      debugPrint('$instanceLockFileName: ${issue.error}');
      instanceLockIssue = issue;
  }

  // macOS: the integrated titlebar goes in while the runner still keeps
  // the window hidden, so it never shows the standard one first.
  final toolbarBand = defaultTargetPlatform == TargetPlatform.macOS
      ? await installMacosTitlebar()
      : null;

  // settings.json (03 §4.10), owned by this isolate. Opened before the
  // engine isolate so the device id is minted and saved before anything
  // that could read it starts, and so the first frame is drawn in the
  // stored theme. Opening never throws; a file it cannot use is reported
  // after the first frame.
  File supportFile(String name) =>
      File('${supportDirectory.path}${Platform.pathSeparator}$name');
  final settings = await DeviceSettingsStore.open(
    supportFile(deviceSettingsFileName),
  );
  if (settings.issue case final issue?) {
    debugPrint('settings.json: ${issue.kind.name} ${issue.error ?? ''}');
  }

  // Desktop only: put the main window back where it was closed (size,
  // monitor, maximized or full screen) before the first frame, and keep
  // tracking it. On macOS this is also what shows the window, which the
  // runner keeps hidden until it is placed, so it runs before anything
  // below that can throw, such as the engine handshake: a throw ahead of
  // it would leave the app without a window.
  await restoreMainWindow(
    stateFile: supportFile(windowStateFileName),
    platform: defaultTargetPlatform,
  );

  // D18: all SSH, sampling, parsing, Docker, sync and rule evaluation run
  // in the engine isolate; the UI sends plain-data requests and listens.
  // The engine keeps its own files in the same support directory (03
  // §4.10) and reports what it found wrong with them in its handshake.
  // Links are on (03 §10.1): opening a server's view connects to it, and
  // the prompt controller below shows the host-key and keyboard prompts
  // a connect raises. The engine writes its capability cache and
  // `host_keys.json`, and syncs, only while this process holds the
  // directory alone; otherwise it keeps this run's pins in memory (D59,
  // D61, D63). It gets the device id read above, after the lock, so
  // enrollment never reads an id another process may have minted.
  // Probes are on too (FL-04): the engine probes confirmed endpoints and
  // the fleet rows show the answers.
  final engine = await IsolateEngineClient.spawn(
    supportDirectory: supportDirectory.path,
    linksEnabled: true,
    probesEnabled: true,
    supportDirectoryAccess: supportDirectoryAccessFor(instanceLock),
    deviceId: settings.deviceId,
  );
  final importStoreIssue = engine.ready.importStoreIssue;
  if (importStoreIssue != null) {
    debugPrint(
      'ssh_config_imports.json: ${importStoreIssue.kind.name} '
      '${importStoreIssue.detail ?? ''}',
    );
  }

  // FL-02: desktops get the ssh_config import; phones get no source.
  // FleetController subscribes to engine.events before any other
  // listener: the client holds the startup CatalogReplaced (the saved
  // imports) for its first listener only, so another one subscribing
  // first could take it and leave the rail empty until the next import.
  final fleet = FleetController(
    engine,
    sshConfig: sshConfigSourceFor(defaultTargetPlatform, Platform.environment),
    // The rail's pinned shortlist (03 §10.3), device-local in
    // settings.json as Séance keeps its pins.
    pinnedServerIds: settings.pinnedServerIds,
    savePins: settings.setPinnedServerIds,
    // FL-21's monitor set (03 §4.3 step 4), device-local in settings.json:
    // until the user chooses one, every eligible server on a desktop and
    // none on a phone.
    monitorSet: settings.monitorSet,
    monitorSetDefault: monitorSetDefaultFor(defaultTargetPlatform),
    saveMonitorSet: settings.setMonitorSet,
  );
  // CN-09's Docker socket per server, chosen on this device and kept in
  // settings.json (03 §4.10, D54); a server the fleet drops or moves to
  // another endpoint loses its choice (SYN-08).
  final dockerEndpointChoices = DockerEndpointChoices(
    stored: settings.dockerEndpointOverrides,
    save: settings.setDockerEndpointOverride,
    purge: settings.purgeDockerEndpointOverrides,
  )..followFleet(fleet);
  // Spawned once per launch: a restarted engine would be a new client
  // with new controllers over it, whose seq floors start empty (D44), and
  // KlabautermannApp remounts its tree when handed them.
  // STK-08's scan folders per server, device-local in settings.json until
  // the pref record syncs them (M5 plan M05).
  final stackFolders = StackFolders(
    stored: settings.stackFolders,
    save: settings.setStackFolders,
  );
  // CRT-01's endpoints per server, device-local in settings.json, since
  // the check runs from this device.
  final tlsEndpoints = TlsEndpoints(
    stored: settings.tlsEndpoints,
    save: settings.setTlsEndpoints,
  );
  // TRI-03's acknowledgements, device-local in settings.json (02 TRI-03).
  final attentionAcks = AttentionAcks(
    stored: settings.attention,
    save: settings.setAttention,
  );
  // The Containers tab's chosen columns (CTR-08), device-local.
  final containerColumns = ContainerColumnChoice(
    stored: settings.containerColumns,
    save: settings.setContainerColumns,
  );
  final monitoring = MonitoringController(
    engine,
    attentionAcks: attentionAcks,
    dockerEndpointChoices: dockerEndpointChoices,
    stackFolders: stackFolders,
    tlsEndpoints: tlsEndpoints,
    containerColumns: containerColumns,
  );
  // The host-key and keyboard-interactive prompts the engine raises while
  // it connects, shown one at a time over every route.
  final prompts = PromptController(engine);
  // Admin mode per server (03 §8.2): the engine runs it and holds the
  // password; the header's chip asks and shows its state.
  final admin = AdminController(engine);
  // In-app alerts (ALR-01): the engine evaluates the synced rules on live
  // samples; the fleet list and rows show what they raise.
  final alerts = AlertCenter(engine);
  // The synced rules behind them, and the editor's writes (03 §4.8).
  final alertRules = AlertRulesController(engine);
  // Their system notifications (ALR-01), worded in the device's locale
  // as it is when each posts, and switched on per device in
  // settings.json.
  AppLocalizations deviceStrings() => lookupAppLocalizations(
    basicLocaleListResolution(
      PlatformDispatcher.instance.locales,
      AppLocalizations.supportedLocales,
    ),
  );
  final startStrings = deviceStrings();
  final alertNotifications = AlertNotificationsController(
    engine,
    notifications: await LocalSystemNotifications.start((
      channelName: startStrings.alertNotificationChannel,
      channelDescription: startStrings.alertNotificationChannelDetail,
      openAction: startStrings.alertNotificationOpen,
    )),
    textOf: (raise) => alertNotificationText(
      deviceStrings(),
      raise,
      server:
          fleet.servers
              .where((server) => server.id == raise.serverId)
              .firstOrNull
              ?.displayName ??
          raise.serverId,
    ),
    enabled: settings.alertNotifications,
    save: settings.setAlertNotifications,
  );
  // Action previews and runs (03 §8.5): the engine plans and runs them;
  // the app shows the preview and the results.
  final operations = OperationsController(
    engine,
    auditInMemory: engine.ready.auditInMemory,
  );
  // Pull-only sync (03 §4.3, D14): the sign-in and rounds the user asks
  // for, and the OS keystore the engine's sync reaches through this
  // isolate, which alone can call the keystore plugin (D62).
  // Pin publication (D15, M5 plan M07): offered only once a release with
  // Séance's #56 fix is named, which the engine reports at start.
  final pinPublication = PinPublicationController(
    engine,
    initial: engine.ready.pinPublication,
  );
  final sync = SyncController(
    engine,
    account: engine.ready.syncAccount,
    pinPublication: pinPublication,
  );
  // In-app server editing (FL-03): offered while enrolled (P16).
  final serverEditor = ServerEditorController(engine);
  // The app lock (SAF-20), device-local in settings.json: the engine's
  // keystore reads wait for it, and admin mode ends when it engages.
  final appLock = AppLockController(
    authenticator: LocalDeviceAuthenticator(
      reason: () => lookupAppLocalizations(
        basicLocaleListResolution(
          PlatformDispatcher.instance.locales,
          AppLocalizations.supportedLocales,
        ),
      ).appLockReason,
    ),
    supported: appLockSupportedOn(defaultTargetPlatform),
    enabled: settings.appLock,
    save: settings.setAppLock,
    onLocked: admin.turnOffAll,
  );
  EngineKeystoreResponder(
    engine,
    klabautermannMasterKeyManager(),
    guard: appLock.read,
  );
  for (final issue in engine.ready.syncStoreIssues) {
    debugPrint('${issue.fileName}: ${issue.kind.name} ${issue.detail ?? ''}');
  }
  final appearance = appearanceFromSettings(settings);
  // 03 §9.5 item 1: the first-run card shows until dismissed on this
  // device, which settings.json keeps.
  final coverage = CoverageController(
    firstRunCardDismissed: settings.firstRunCardDismissed,
    saveDismissal: settings.dismissFirstRunCard,
  );

  // A11Y-15's switch (D60), kept per device in settings.json.
  final announcements = AnnouncementController(
    announceThresholdBands: settings.announceThresholdBands,
    save: settings.setAnnounceThresholdBands,
  );

  // OV-11's threshold bands, kept per device in settings.json.
  final thresholds = ThresholdController(
    stored: settings.thresholds,
    save: settings.setThresholds,
  );

  // The polling budget (SAF-19), kept per device in settings.json; the
  // engine samples at its 6.4 column from the start and follows changes.
  final cadence = CadenceController(
    preset: CadencePreset.parse(settings.cadence),
    save: settings.setCadence,
  );
  void applyCadence() => monitoring.setCadenceProfile(
    cadence.value.profileOn(defaultTargetPlatform),
  );
  applyCadence();
  cadence.addListener(applyCadence);

  // The synced servers' preferences (03 §4.8), as the engine reports their
  // `pref` records.
  final serverPrefs = ServerPrefsController(engine);

  // The safety preferences (M4 plan M4), in settings.json and, for synced
  // servers, their read-only switches and marks in their `pref` records
  // (M5 plan M06); applied to the engine now, since it starts with every
  // server observe-only, and on every change.
  final safety = safetyFromSettings(
    settings,
    engine,
    labelOf: (serverId) =>
        fleet.servers
            .where((server) => server.id == serverId)
            .firstOrNull
            ?.displayName ??
        serverId,
    prefs: serverPrefs,
  );

  // The device name the host syslog line gives (SAF-13, M5 plan Q6),
  // device-local in settings.json and applied to the engine now, since it
  // names no device until told.
  final deviceName = DeviceNameController(
    stored: settings.deviceName,
    fallback: defaultDeviceName(defaultTargetPlatform),
    apply: (name) {
      try {
        engine.send(SetDeviceName(name));
      } on StateError {
        // A stopped engine runs nothing; the next one gets the name at
        // its spawn.
      }
    },
    save: settings.setDeviceName,
  );

  // The "sync passwords" switch (SYN-02), device-local in settings.json
  // and applied to the engine now, since it starts with the switch off.
  final syncSecrets = SyncSecretsController(
    syncSecrets: settings.syncSecrets,
    apply: (enabled) {
      try {
        engine.send(SetSyncSecrets(enabled: enabled));
      } on StateError {
        // A stopped engine syncs nothing; the next one gets the switch at
        // its spawn.
      }
    },
    save: settings.setSyncSecrets,
  );

  // SAF-08's notice heads the Docker tab until dismissed on this device,
  // which settings.json keeps (03 §8.4).
  final dockerNotice = DockerNoticeController(
    dismissed: settings.rootEquivalenceNoticeDismissed,
    saveDismissal: settings.dismissRootEquivalenceNotice,
  );
  // The About dialog's version (M16), read here once: the settings
  // window's engine has no plugins and gets it over the link.
  final appVersion = await readAppVersion();
  // Which siblings can take a hand-off here, asked of the OS once.
  final handOff = await UrlHandOffLauncher.probe(
    platform: defaultTargetPlatform,
    onError: (error, stack) => FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    ),
  );

  // Desktop only: the runners there host the settings window; phones keep
  // the settings route.
  final settingsWindow = settingsWindowHostFor(
    defaultTargetPlatform,
    appearance: appearance,
    announcements: announcements,
    thresholds: thresholds,
    deviceName: deviceName,
    appVersion: appVersion,
    monitorSet: fleet.monitorSettings,
    safety: safety,
    appLock: appLock,
    syncSecrets: syncSecrets,
    pinPublication: pinPublication,
    cadence: cadence,
  );

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      prompts: prompts,
      appearance: appearance,
      coverage: coverage,
      announcements: announcements,
      thresholds: thresholds,
      cadence: cadence,
      deviceName: deviceName,
      safety: safety,
      appLock: appLock,
      syncSecrets: syncSecrets,
      pinPublication: pinPublication,
      admin: admin,
      alerts: alerts,
      alertRules: alertRules,
      alertNotifications: alertNotifications,
      operations: operations,
      dockerNotice: dockerNotice,
      sync: sync,
      serverEditor: serverEditor,
      settingsIssue: settings.issue,
      importStoreIssue: importStoreIssue,
      syncStoreIssues: engine.ready.syncStoreIssues,
      instanceLockIssue: instanceLockIssue,
      openSettingsWindow: settingsWindow?.open,
      toolbarBand: toolbarBand,
      appVersion: appVersion,
      handOff: handOff,
      navigation: WorkspaceNavigation(fleet),
    ),
  );
}
