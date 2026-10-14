import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'services/ssh_config_source.dart';
import 'services/stored_appearance.dart';

/// The composition root (03 §10.1): the device settings store opens here,
/// the engine isolate starts, one `ChangeNotifier` controller per concern
/// is built over them, then `runApp`. The settings-window branch, the
/// catalog stores, vault and macOS titlebar join this list as their
/// milestones land.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // settings.json (03 §4.10), owned by this isolate. Opened first so the
  // device id is minted and saved before anything that could read it
  // starts, and so the first frame is drawn in the stored theme. Opening
  // never throws; a file it cannot use is reported after the first frame.
  final supportDirectory = await getApplicationSupportDirectory();
  final settings = await DeviceSettingsStore.open(
    File(
      '${supportDirectory.path}${Platform.pathSeparator}'
      '$deviceSettingsFileName',
    ),
  );
  if (settings.issue case final issue?) {
    debugPrint('settings.json: ${issue.kind.name} ${issue.error ?? ''}');
  }

  // D18: all SSH, sampling, parsing, Docker, sync and rule evaluation run
  // in the engine isolate; the UI sends plain-data requests and listens.
  // The engine keeps its own files in the same support directory (03
  // §4.10) and reports what it found wrong with them in its handshake.
  final engine = await IsolateEngineClient.spawn(
    supportDirectory: supportDirectory.path,
  );
  final importStoreIssue = engine.ready.importStoreIssue;
  if (importStoreIssue != null) {
    debugPrint(
      'ssh_config_imports.json: ${importStoreIssue.kind.name} '
      '${importStoreIssue.detail ?? ''}',
    );
  }

  // FL-02: desktops get the ssh_config import; phones get no source.
  final fleet = FleetController(
    engine,
    sshConfig: sshConfigSourceFor(defaultTargetPlatform, Platform.environment),
  );
  final monitoring = MonitoringController(engine);
  final appearance = appearanceFromSettings(settings);

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      appearance: appearance,
      settingsIssue: settings.issue,
      importStoreIssue: importStoreIssue,
    ),
  );
}
