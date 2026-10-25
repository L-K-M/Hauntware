// The desktop settings window's wire: channel names, the launch argument,
// the method table and the JSON codecs for what crosses between the app's
// isolate and the window's (03 §10.2, D32; 04 §12.3 fixes the channels).
//
// The window runs on a second Flutter engine, whose isolate shares nothing
// with the app's: no engine isolate, no controllers, no stores. Each runner
// (macos/Runner/SettingsWindow.swift, linux/runner/settings_window.cc,
// windows/runner/settings_window.cpp) relays every message one engine sends
// on [settingsWindowLinkChannel] to the other, byte for byte, with its
// reply. ghost_desktop's link engine owns the handshake, the snapshots and
// the quit question; what is here is Klabautermann's own.
import 'package:flutter/services.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../../controllers/announcement_controller.dart'
    show AnnouncementNotSavedException;
import '../../controllers/app_lock_controller.dart';
import '../../controllers/appearance_controller.dart'
    show AppearanceNotSavedException;
import '../../controllers/device_name.dart' show DeviceNameNotSavedException;
import '../../controllers/monitor_set.dart';
import '../../controllers/pin_publication_controller.dart' show PinPublication;
import '../../controllers/safety_controller.dart' show SafetyNotSavedException;
import '../../controllers/sync_secrets_controller.dart'
    show SyncSecretsNotSavedException;
import '../../theme/app_theme.dart';

/// On the app's engine only: `open` in, `closed` out.
const MethodChannel settingsWindowControlChannel = MethodChannel(
  'klabautermann/settings_window',
);

/// On both engines, relayed between them by the runner.
const MethodChannel settingsWindowLinkChannel = MethodChannel(
  'klabautermann/settings_link',
);

/// What the runners start the window's engine with; `main` runs the
/// settings window instead of the app when it sees it.
const String settingsWindowArgument = '--klabautermann-settings-window';

/// The settings tabs, in order (03 §10.2). They cross the link by name.
enum SettingsTab { general, appearance, sync, servers, docker, safety, alerts }

/// Opens the desktop settings window on a tab; false when there is no
/// window to open (a runner without one, or a test), and the caller shows
/// the settings route instead. `SettingsWindowHost.open` in the app.
typedef OpenSettingsWindow = Future<bool> Function(SettingsTab tab);

/// Klabautermann's link methods, window to app. Each crosses as its
/// [name], so a typo is a compile error rather than a silent `null` on the
/// far side. The names of ghost_desktop's `GhostSettingsLinkMethod` are
/// the engine's and must not appear here.
enum SettingsLinkMethod {
  /// The Appearance tab's theme-mode switch; the argument is a
  /// [ThemeModePreference] name.
  setThemeMode,

  /// The Appearance tab's editor (M4 E25); the argument is an appearance
  /// as [encodeAppearance] writes it.
  setAppearance,

  /// The General tab's A11Y-15 switch; the argument is a bool (D60).
  setAnnounceThresholdBands,

  /// The General tab's device name (M5 plan Q6); the argument is a
  /// string, blank for the default.
  setDeviceName,

  /// The Sync tab's "sync passwords" switch (SYN-02); the argument is a
  /// bool.
  setSyncSecrets,

  /// The Sync tab's host key sharing switch (M5 plan M07); the argument is
  /// a bool.
  setPinPublication,

  /// A Servers tab toggle of FL-21's monitor set; the argument is an
  /// object of [SettingsLinkKey.serverId] and [SettingsLinkKey.monitored].
  setMonitored,

  /// The Safety tab's global read-only switch; the argument is a bool.
  setGlobalReadOnly,

  /// The Safety tab's admin expiry; the argument is whole minutes, one of
  /// `kAdminExpiryChoices`.
  setAdminExpiry,

  /// A Safety tab change to one server, a removed mark; the argument is an
  /// object of [SettingsLinkKey.serverId] and [SettingsLinkKey.safety] in
  /// `encodeServerSafety`'s form.
  setServerSafety,

  /// The Safety tab's app lock switch (SAF-20); the argument is a bool,
  /// the answer an [AppLockChange] name. The device authentication it
  /// needs runs in the app's window.
  setAppLock,
}

/// The keys of every JSON object on the link, spelled once for both sides.
enum SettingsLinkKey {
  appearance,
  palette,
  mode,
  announceThresholdBands,
  deviceName,
  syncSecrets,

  /// The host key sharing assertion, an object of [release] and
  /// [asserted], or null when the app holds none.
  pinPublication,
  release,
  asserted,

  /// The running build's version for the about row, a string or null:
  /// the window's engine registers no plugins to read it itself.
  appVersion,
  monitorSet,
  serverId,
  label,
  eligibility,
  monitored,
  safety,
  labels,

  /// The app lock, an object of [enabled], [support] and [locked], or
  /// null when the app offers none.
  appLock,
  enabled,
  support,
  locked,
}

/// The palette's stored form, bound to Klabautermann's style.
const _themeCodec = GhostThemeCodec(klabautermannThemeStyle);

/// The app's appearance as the snapshot carries it: the palette as
/// `ghost_theme` stores it, and the mode by name.
Map<String, Object?> encodeAppearance(AppAppearance appearance) => {
  SettingsLinkKey.palette.name: appearance.palette.toJson(),
  SettingsLinkKey.mode.name: appearance.mode.name,
};

/// The inverse of [encodeAppearance]. The palette decodes leniently, as a
/// stored one does; an unknown mode throws, since both ends are the same
/// build.
AppAppearance decodeAppearance(Map<String, Object?> json) => AppAppearance(
  palette: _themeCodec.decodeStored(json[SettingsLinkKey.palette.name]),
  mode: ThemeModePreference.values.byName(
    json[SettingsLinkKey.mode.name]! as String,
  ),
);

/// The pin publication state as the snapshot carries it.
Map<String, Object?> encodePinPublication(PinPublication value) => {
  SettingsLinkKey.release.name: value.release,
  SettingsLinkKey.asserted.name: value.asserted,
};

/// The inverse of [encodePinPublication]; null reads as none offered.
PinPublication decodePinPublication(Map<Object?, Object?>? json) => json == null
    ? const PinPublication()
    : PinPublication(
        release: json[SettingsLinkKey.release.name] as String?,
        asserted: json[SettingsLinkKey.asserted.name]! as bool,
      );

/// The app lock as the snapshot carries it, its support by name.
Map<String, Object?> encodeAppLock(AppLockSettings lock) => {
  SettingsLinkKey.enabled.name: lock.enabled,
  SettingsLinkKey.support.name: lock.support.name,
  SettingsLinkKey.locked.name: lock.locked,
};

/// The monitor set's candidates as the snapshot carries them, in fleet
/// order, the eligibility by name.
List<Map<String, Object?>> encodeMonitorCandidates(
  List<MonitorCandidate> candidates,
) => [
  for (final candidate in candidates)
    {
      SettingsLinkKey.serverId.name: candidate.serverId,
      SettingsLinkKey.label.name: candidate.label,
      SettingsLinkKey.eligibility.name: candidate.eligibility.name,
      SettingsLinkKey.monitored.name: candidate.monitored,
    },
];

/// The inverse of [encodeMonitorCandidates]; an unknown eligibility
/// throws, since both ends are the same build.
List<MonitorCandidate> decodeMonitorCandidates(List<Object?> json) => [
  for (final item in json.cast<Map<Object?, Object?>>())
    MonitorCandidate(
      serverId: item[SettingsLinkKey.serverId.name]! as String,
      label: item[SettingsLinkKey.label.name]! as String,
      eligibility: monitorEligibilityNamed(
        item[SettingsLinkKey.eligibility.name]! as String,
      ),
      monitored: item[SettingsLinkKey.monitored.name]! as bool,
    ),
];

/// Why a call failed in the app's isolate, as the code of the
/// [PlatformException] that carries it.
enum SettingsLinkError {
  /// The change applied but the app could not save it. It crosses as
  /// itself, and the window rebuilds the [AppearanceNotSavedException], so
  /// the Appearance tab words it the same in both places.
  notSaved,

  /// As [notSaved], for the A11Y-15 switch: the window rebuilds the
  /// [AnnouncementNotSavedException].
  announcementNotSaved,

  /// The monitor set is full: the window rebuilds the
  /// [MonitorSetFullException], so the Servers tab words it as the app's
  /// rows do.
  monitorSetFull,

  /// As [notSaved], for the monitor set: the window rebuilds the
  /// [MonitorSetNotSavedException].
  monitorSetNotSaved,

  /// As [notSaved], for the safety settings: the window rebuilds the
  /// [SafetyNotSavedException].
  safetyNotSaved,

  /// As [notSaved], for the "sync passwords" switch: the window rebuilds
  /// the [SyncSecretsNotSavedException].
  syncSecretsNotSaved,

  /// As [notSaved], for the device name: the window rebuilds the
  /// [DeviceNameNotSavedException].
  deviceNameNotSaved,

  /// Anything else: the change did not happen.
  failed,
}

/// [error] as the link carries it: a [PlatformException] whose code is a
/// [SettingsLinkError] and whose message is what the error printed.
PlatformException encodeLinkError(Object error) => PlatformException(
  code: switch (error) {
    AppearanceNotSavedException() => SettingsLinkError.notSaved.name,
    AnnouncementNotSavedException() =>
      SettingsLinkError.announcementNotSaved.name,
    MonitorSetFullException() => SettingsLinkError.monitorSetFull.name,
    MonitorSetNotSavedException() => SettingsLinkError.monitorSetNotSaved.name,
    SafetyNotSavedException() => SettingsLinkError.safetyNotSaved.name,
    SyncSecretsNotSavedException() =>
      SettingsLinkError.syncSecretsNotSaved.name,
    DeviceNameNotSavedException() => SettingsLinkError.deviceNameNotSaved.name,
    _ => SettingsLinkError.failed.name,
  },
  message: '$error',
);

/// A settings window call the app refused because it is locked (SAF-20):
/// the window covers itself then, and changes nothing until the app is
/// unlocked in its own window.
final class AppLockedException implements Exception {
  const AppLockedException();
}

/// The inverse of [encodeLinkError], in the window.
Exception decodeLinkError(PlatformException error) {
  final message = error.message ?? error.code;
  return switch (SettingsLinkError.values.asNameMap()[error.code]) {
    SettingsLinkError.notSaved => AppearanceNotSavedException(message),
    SettingsLinkError.announcementNotSaved => AnnouncementNotSavedException(
      message,
    ),
    SettingsLinkError.monitorSetFull => const MonitorSetFullException(),
    SettingsLinkError.monitorSetNotSaved => MonitorSetNotSavedException(
      message,
    ),
    SettingsLinkError.safetyNotSaved => SafetyNotSavedException(message),
    SettingsLinkError.syncSecretsNotSaved => SyncSecretsNotSavedException(
      message,
    ),
    SettingsLinkError.deviceNameNotSaved => DeviceNameNotSavedException(
      message,
    ),
    SettingsLinkError.failed || null => SettingsLinkException(message),
  };
}

/// A failure the app reported for a call from the window, or the window's
/// own when no app answers.
final class SettingsLinkException implements Exception {
  const SettingsLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}
