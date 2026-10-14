import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'controllers/fleet_controller.dart';
import 'controllers/monitoring_controller.dart';
import 'services/settings_window/settings_window_host.dart';
import 'services/settings_window/settings_window_link.dart';
import 'services/ssh_config_source.dart';
import 'services/stored_appearance.dart';
import 'settings_window_app.dart';

/// The composition root (03 §10.1): the settings-window branch, then the
/// device settings store, the engine isolate, one `ChangeNotifier`
/// controller per concern built over them, and `runApp`. The catalog
/// stores, vault and the macOS titlebar join this list as their
/// milestones land.
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

  // settings.json (03 §4.10), owned by this isolate. Opened before the
  // engine isolate so the device id is minted and saved before anything
  // that could read it starts, and so the first frame is drawn in the
  // stored theme. Opening never throws; a file it cannot use is reported
  // after the first frame.
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
  // FleetController subscribes to engine.events before any other
  // listener: the client holds the startup CatalogReplaced (the saved
  // imports) for its first listener only, so another one subscribing
  // first could take it and leave the rail empty until the next import.
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

  runApp(
    KlabautermannApp(
      fleet: fleet,
      monitoring: monitoring,
      appearance: appearance,
      settingsIssue: settings.issue,
      importStoreIssue: importStoreIssue,
      openSettingsWindow: settingsWindow?.open,
    ),
  );
}
