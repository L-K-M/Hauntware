import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'services/macos_titlebar.dart';
import 'services/settings_window/settings_window_host.dart';
import 'services/settings_window/settings_window_link.dart';
import 'services/ssh_config_source.dart';
import 'services/stored_appearance.dart';
import 'services/window_state.dart';
import 'settings_window_app.dart';

/// The composition root (03 §10.1): the settings-window branch, the macOS
/// titlebar, then the device settings store, the engine isolate, one
/// `ChangeNotifier` controller per concern built over them, the main
/// window's restored frame, and `runApp`. The catalog stores and vault
/// join this list as their milestones land.
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
  final supportDirectory = await getApplicationSupportDirectory();
  File supportFile(String name) =>
      File('${supportDirectory.path}${Platform.pathSeparator}$name');
  final settings = await DeviceSettingsStore.open(
    supportFile(deviceSettingsFileName),
  );
  if (settings.issue case final issue?) {
    debugPrint('settings.json: ${issue.kind.name} ${issue.error ?? ''}');
  }

  // D18: all SSH, sampling, parsing, Docker, sync and rule evaluation run
  // in the engine isolate; the UI sends plain-data requests and listens.
  final engine = await IsolateEngineClient.spawn();

  // FL-02: desktops get the ssh_config import; phones get no source.
  final fleet = FleetController(
    engine,
    sshConfig: sshConfigSourceFor(defaultTargetPlatform, Platform.environment),
  );
  final monitoring = MonitoringController(engine);
  final appearance = appearanceFromSettings(settings);

  // Desktop only: the runners there host the settings window; phones keep
  // the settings route.
  final settingsWindow = settingsWindowHostFor(
    defaultTargetPlatform,
    appearance: appearance,
  );

  // Desktop only: put the main window back where it was closed (size,
  // monitor, maximized or full screen) before the first frame, and keep
  // tracking it. On macOS this is also what shows the window, which the
  // runner keeps hidden until it is placed.
  await restoreMainWindow(
    stateFile: supportFile(windowStateFileName),
    platform: defaultTargetPlatform,
  );

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      appearance: appearance,
      settingsIssue: settings.issue,
      openSettingsWindow: settingsWindow?.open,
      toolbarBand: toolbarBand,
    ),
  );
}
