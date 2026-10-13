import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'app.dart';
import 'controllers/appearance_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'services/settings_window/settings_window_host.dart';
import 'services/settings_window/settings_window_link.dart';
import 'services/ssh_config_source.dart';
import 'settings_window_app.dart';

/// The composition root (03 §10.1): the settings-window branch, then the
/// engine isolate, one `ChangeNotifier` controller per concern built over
/// it, and `runApp`. Stores, vault and the macOS titlebar join this list
/// as their milestones land.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // The desktop settings window's engine runs this same entrypoint (D32).
  // It is a second Flutter engine whose isolate shares nothing with this
  // one, so it gets the settings window's app and nothing below: no second
  // engine isolate (D18), no sync, no stores. Everything it needs crosses
  // the settings link.
  if (args.contains(settingsWindowArgument)) {
    await runSettingsWindow();
    return;
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
  final appearance = AppearanceController();

  // Desktop only: the runners there host the settings window; phones keep
  // the settings route.
  final settingsWindow = switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => SettingsWindowHost(appearance: appearance),
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => null,
  };

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      appearance: appearance,
      openSettingsWindow: settingsWindow?.open,
    ),
  );
}
