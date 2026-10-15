/// Klabautermann's pure-Dart engine layer: the D18 engine isolate, its
/// plain-data protocol and the client the app composes over, the device
/// settings store, the instance lock and the log viewer's line model
/// (docs/design/klabautermann/03, sections 3.2, 4.10, 10.1 and 10.8).
library;

export 'src/engine/engine_client.dart';
// What a substitute engine for IsolateEngineClient.spawn's entryPoint is
// handed; the app's restart test runs one.
export 'src/engine/engine_isolate.dart' show EngineStart;
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
// One desktop instance per support directory (03 §4.10); the error-code
// rule stays internal.
export 'src/settings/instance_lock.dart'
    show
        InstanceLock,
        InstanceLockAcquired,
        InstanceLockAttempt,
        InstanceLockHeld,
        InstanceLockUnavailable,
        instanceLockFileName;

// 03 §3.2: the app reaches seance_core, klabautermann_host and
// klabautermann_docker types only through this barrel, each behind an
// explicit `show` list that changes as a milestone wires types in or
// retires them.
// The host types are the plain data that sampling results and
// HostProfileChanged carry (D52), the file names
// HostProfile.showsHostFigures takes (D50), and the log viewer's journal
// rows.
export 'package:klabautermann_host/klabautermann_host.dart'
    show
        CpuPercentages,
        CronSnapshot,
        DiskRate,
        FsMount,
        FsSnapshot,
        HostProfile,
        JournalEntry,
        LoadAvg,
        NetRate,
        ProcsSelection,
        SystemWideProcFile,
        SystemdUnit,
        TimersSnapshot,
        UnitListFormat,
        UnitsSnapshot;
// The Logs panel's LOG-04 notice: the access check's journal row (K04)
// over the probe's HostProfile.
export 'package:klabautermann_host/klabautermann_host.dart'
    show AccessReport, evaluateAccess;
// The app resolves `~/.ssh/config` for the FL-02 import with Séance's home
// rule, which also undoes a macOS sandbox's container `HOME`.
export 'package:seance_core/seance_core.dart' show expandHomePath;
