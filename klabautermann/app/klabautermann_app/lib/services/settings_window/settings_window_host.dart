// The app's side of the desktop settings window: ghost_desktop's link
// engine opens it and keeps it in step; this host answers what it asks
// through the app's own controllers and builds the snapshot it renders.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;

import '../../controllers/appearance_controller.dart';
import 'settings_window_link.dart';

/// Opens Settings in a native window of its own and serves it from the
/// app's isolate. Desktop only; the composition root builds none on a
/// phone, where Settings is a route.
///
/// The window is a second engine (D32): everything it shows comes from
/// this host's snapshots and everything it changes runs here, so it never
/// starts an engine isolate (D18), a store or sync of its own.
final class SettingsWindowHost {
  /// [requestAppExit] answers the window's quit question; by default the
  /// app's own observers.
  SettingsWindowHost({
    required AppearanceSettings appearance,
    MethodChannel control = settingsWindowControlChannel,
    MethodChannel link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
  }) : _appearance = appearance {
    _engine = GhostSettingsWindowHost(
      control: control,
      link: link,
      initialTab: SettingsTab.general,
      sections: GhostSettingsSections(
        snapshot: _snapshot,
        handleCall: _handleCall,
        changes: [appearance],
      ),
      requestAppExit: requestAppExit,
    );
  }

  final AppearanceSettings _appearance;
  late final GhostSettingsWindowHost<SettingsTab> _engine;

  @visibleForTesting
  bool get connected => _engine.connected;

  @visibleForTesting
  bool get visible => _engine.visible;

  /// Opens the window on [tab], or brings it forward and switches it there.
  /// False when the runner has no settings window (a build from before it
  /// existed, or a test), so the caller can push the settings route.
  Future<bool> open(SettingsTab tab) => _engine.open(tab);

  void dispose() => _engine.dispose();

  /// Everything the window renders.
  Map<String, Object?> _snapshot() => {
    SettingsLinkKey.appearance.name: encodeAppearance(_appearance.value),
  };

  Future<Object?> _handleCall(String name, Object? argument) async {
    switch (SettingsLinkMethod.values.asNameMap()[name]) {
      case null:
        throw MissingPluginException('No settings window method $name');
      case SettingsLinkMethod.setThemeMode:
        await _appearance.setMode(
          ThemeModePreference.values.byName(argument! as String),
        );
    }
    return null;
  }
}
