/// Klabautermann's pure-Dart engine layer: the D18 engine isolate, its
/// plain-data protocol and the client the app composes over, the device
/// settings store, and the log viewer's line model
/// (docs/design/klabautermann/03, sections 3.2, 4.10, 10.1 and 10.8).
library;

export 'src/engine/engine_client.dart';
export 'src/engine/protocol.dart';
// The log viewer's line store and SGR reader (03 §10.8).
export 'src/logs/log_buffer.dart';
export 'src/logs/sgr.dart';
// The app's settings.json (03 §4.10), and the atomic writer the app's
// other device-local files (window_state.json) share with it.
export 'src/settings/device_settings_store.dart'
    show
        DeviceSettingsIssue,
        DeviceSettingsIssueKind,
        DeviceSettingsReadOnlyException,
        DeviceSettingsStore,
        DeviceSettingsWriter,
        deviceSettingsFileName,
        deviceSettingsSchemaVersion,
        writeFileAtomically;

// 03 §3.2: the app reaches seance_core, klabautermann_host and
// klabautermann_docker types only through this barrel, each behind an
// explicit `show` list that grows as its milestone wires the types in.
export 'package:klabautermann_host/klabautermann_host.dart'
    show Collector, CoreSnapshot, OverviewSnapshot;
// The app resolves `~/.ssh/config` for the FL-02 import with Séance's home
// rule, which also undoes a macOS sandbox's container `HOME`.
export 'package:seance_core/seance_core.dart' show expandHomePath;
