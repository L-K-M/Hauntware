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
}

/// The keys of every JSON object on the link, spelled once for both sides.
enum SettingsLinkKey { appearance, palette, mode }

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

/// A failure the app reported for a call from the window, or the window's
/// own when no app answers.
final class SettingsLinkException implements Exception {
  const SettingsLinkException(this.message);

  final String message;

  @override
  String toString() => message;
}
