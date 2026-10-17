import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ServicesBinding;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'controllers/announcement_controller.dart';
import 'controllers/coverage_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'controllers/prompt_controller.dart';
import 'controllers/sync_controller.dart';
import 'services/engine_keystore.dart';
import 'services/instance_guard.dart';
import 'services/macos_titlebar.dart';
import 'services/settings_window/settings_window_host.dart';
import 'services/settings_window/settings_window_link.dart';
import 'services/ssh_config_source.dart';
import 'services/stored_appearance.dart';
import 'services/window_state.dart';
import 'settings_window_app.dart';
import 'ui/already_running_app.dart';

/// The composition root (03 §10.1): the settings-window branch, the
/// instance lock, the macOS titlebar, then the device settings store, the
/// main window's restored frame, the engine isolate, one `ChangeNotifier`
/// controller per concern built over them, the keystore that answers the
/// engine's sync (D62), and `runApp`. The catalog stores and the vault
/// are the engine's (03 §4.10, D63).
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

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
  // Links stay off (03 §10.1): host-key pins would last only until the
  // engine stops, since the catalog library's `host_keys.json` has not
  // landed (03 §4.10). The engine writes its capability cache and syncs
  // only while this process holds the directory alone (D59, D63). It gets
  // the device id read above, after the lock, so enrollment never reads
  // an id another process may have minted.
  final engine = await IsolateEngineClient.spawn(
    supportDirectory: supportDirectory.path,
    linksEnabled: false,
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
  );
  // Spawned once per launch: a restarted engine would be a new client
  // with new controllers over it, whose seq floors start empty (D44), and
  // KlabautermannApp remounts its tree when handed them.
  final monitoring = MonitoringController(engine);
  // The host-key and keyboard-interactive prompts the engine raises while
  // it connects, shown one at a time over every route.
  final prompts = PromptController(engine);
  // Pull-only sync (03 §4.3, D14): the sign-in and rounds the user asks
  // for, and the OS keystore the engine's sync reaches through this
  // isolate, which alone can call the keystore plugin (D62).
  final sync = SyncController(engine, account: engine.ready.syncAccount);
  EngineKeystoreResponder(engine, klabautermannMasterKeyManager());
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

  // Desktop only: the runners there host the settings window; phones keep
  // the settings route.
  final settingsWindow = settingsWindowHostFor(
    defaultTargetPlatform,
    appearance: appearance,
    announcements: announcements,
  );

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      prompts: prompts,
      appearance: appearance,
      coverage: coverage,
      announcements: announcements,
      sync: sync,
      settingsIssue: settings.issue,
      importStoreIssue: importStoreIssue,
      syncStoreIssues: engine.ready.syncStoreIssues,
      instanceLockIssue: instanceLockIssue,
      openSettingsWindow: settingsWindow?.open,
      toolbarBand: toolbarBand,
    ),
  );
}
