// The app's side of the desktop settings window: ghost_desktop's link
// engine opens it and keeps it in step; this host answers what it asks
// through the app's own controllers and builds the snapshot it renders.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;

import '../../controllers/announcement_controller.dart';
import '../../controllers/appearance_controller.dart';
import '../../controllers/monitor_set.dart';
import 'settings_window_link.dart';

/// The settings window host for [platform], or null where Settings stays a
/// route: only the desktop runners host the window (D32), and phones push
/// the settings route.
SettingsWindowHost? settingsWindowHostFor(
  TargetPlatform platform, {
  required AppearanceSettings appearance,
  required AnnouncementSettings announcements,
  required MonitorSetSettings monitorSet,
}) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => SettingsWindowHost(
    appearance: appearance,
    announcements: announcements,
    monitorSet: monitorSet,
  ),
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => null,
};

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
    required AnnouncementSettings announcements,
    required MonitorSetSettings monitorSet,
    MethodChannel control = settingsWindowControlChannel,
    MethodChannel link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
  }) : _appearance = appearance,
       _announcements = announcements,
       _monitorSet = monitorSet {
    _engine = GhostSettingsWindowHost(
      control: control,
      link: link,
      initialTab: SettingsTab.general,
      sections: GhostSettingsSections(
        snapshot: _snapshot,
        handleCall: _handleCall,
        changes: [appearance, announcements, monitorSet],
      ),
      encodeError: encodeLinkError,
      requestAppExit: requestAppExit,
    );
  }

  final AppearanceSettings _appearance;
  final AnnouncementSettings _announcements;
  final MonitorSetSettings _monitorSet;
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
    SettingsLinkKey.announceThresholdBands.name: _announcements.value,
    SettingsLinkKey.monitorSet.name: encodeMonitorCandidates(_monitorSet.value),
  };

  Future<Object?> _handleCall(String name, Object? argument) async {
    switch (SettingsLinkMethod.values.asNameMap()[name]) {
      case null:
        throw MissingPluginException('No settings window method $name');
      case SettingsLinkMethod.setThemeMode:
        await _appearance.setMode(
          ThemeModePreference.values.byName(argument! as String),
        );
      case SettingsLinkMethod.setAnnounceThresholdBands:
        await _announcements.setAnnounceThresholdBands(argument! as bool);
      case SettingsLinkMethod.setMonitored:
        final change = (argument! as Map).cast<String, Object?>();
        await _monitorSet.setMonitored(
          change[SettingsLinkKey.serverId.name]! as String,
          monitored: change[SettingsLinkKey.monitored.name]! as bool,
        );
    }
    return null;
  }
}
