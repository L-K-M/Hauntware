import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'app.dart';
import 'controllers/appearance_controller.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'services/ssh_config_source.dart';

/// The composition root (03 §10.1): the engine isolate starts here, one
/// `ChangeNotifier` controller per concern is built over it, then
/// `runApp`. The settings-window branch, stores, vault and macOS titlebar
/// join this list as their milestones land.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      appearance: appearance,
    ),
  );
}
