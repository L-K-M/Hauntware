// The app's side of the desktop settings window: ghost_desktop's link
// engine opens it and keeps it in step; this host answers what it asks
// through the app's own controllers and builds the snapshot it renders.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_theme/ghost_theme.dart' show ThemeModePreference;

import '../../controllers/announcement_controller.dart';
import '../../controllers/cadence_controller.dart';
import '../../controllers/app_lock_controller.dart';
import '../../controllers/appearance_controller.dart';
import '../../controllers/device_name.dart';
import '../../controllers/monitor_set.dart';
import '../../controllers/pin_publication_controller.dart';
import '../../controllers/safety_controller.dart';
import '../../controllers/sync_secrets_controller.dart';
import '../../controllers/threshold_controller.dart';
import '../../ui/threshold_scope.dart' show ThresholdMetric;
import '../stored_safety.dart';
import 'settings_window_link.dart';

/// The settings window host for [platform], or null where Settings stays a
/// route: only the desktop runners host the window (D32), and phones push
/// the settings route.
SettingsWindowHost? settingsWindowHostFor(
  TargetPlatform platform, {
  required AppearanceSettings appearance,
  required AnnouncementSettings announcements,
  required DeviceNameSettings deviceName,
  required String? appVersion,
  required MonitorSetSettings monitorSet,
  required SafetySettings safety,
  required SyncSecretsSettings syncSecrets,
  ThresholdSettings? thresholds,
  PinPublicationSettings? pinPublication,
  AppLockSettings? appLock,
  CadenceSettings? cadence,
  CadenceCapSettings? cadenceCaps,
}) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => SettingsWindowHost(
    appearance: appearance,
    announcements: announcements,
    deviceName: deviceName,
    appVersion: appVersion,
    monitorSet: monitorSet,
    safety: safety,
    syncSecrets: syncSecrets,
    thresholds: thresholds,
    pinPublication: pinPublication,
    appLock: appLock,
    cadence: cadence,
    cadenceCaps: cadenceCaps,
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
  /// app's own observers. [appVersion] is the app's (`readAppVersion`),
  /// which the window's about row shows.
  SettingsWindowHost({
    required AppearanceSettings appearance,
    required AnnouncementSettings announcements,
    required DeviceNameSettings deviceName,
    required this._appVersion,
    required MonitorSetSettings monitorSet,
    required SafetySettings safety,
    required SyncSecretsSettings syncSecrets,
    ThresholdSettings? thresholds,
    PinPublicationSettings? pinPublication,
    AppLockSettings? appLock,
    CadenceSettings? cadence,
    CadenceCapSettings? cadenceCaps,
    MethodChannel control = settingsWindowControlChannel,
    MethodChannel link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
  }) : _appearance = appearance,
       _announcements = announcements,
       _deviceName = deviceName,
       _monitorSet = monitorSet,
       _safety = safety,
       _syncSecrets = syncSecrets,
       _thresholds = thresholds,
       _pinPublication = pinPublication,
       _appLock = appLock,
       _cadence = cadence,
       _cadenceCaps = cadenceCaps {
    _engine = GhostSettingsWindowHost(
      control: control,
      link: link,
      initialTab: SettingsTab.general,
      sections: GhostSettingsSections(
        snapshot: _snapshot,
        handleCall: _handleCall,
        changes: [
          appearance,
          announcements,
          deviceName,
          monitorSet,
          safety,
          syncSecrets,
          ?thresholds,
          ?pinPublication,
          ?appLock,
          ?cadence,
          ?cadenceCaps,
        ],
      ),
      encodeError: encodeLinkError,
      requestAppExit: requestAppExit,
    );
  }

  final AppearanceSettings _appearance;
  final AnnouncementSettings _announcements;
  final DeviceNameSettings _deviceName;
  final String? _appVersion;
  final MonitorSetSettings _monitorSet;
  final SafetySettings _safety;
  final SyncSecretsSettings _syncSecrets;
  final ThresholdSettings? _thresholds;
  final PinPublicationSettings? _pinPublication;
  final AppLockSettings? _appLock;
  final CadenceSettings? _cadence;
  final CadenceCapSettings? _cadenceCaps;
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
    SettingsLinkKey.cadence.name: _cadence?.value.name,
    SettingsLinkKey.cadenceCaps.name: switch (_cadenceCaps?.value) {
      final caps? => {
        for (final MapEntry(:key, :value) in caps.entries) key: value.name,
      },
      null => null,
    },
    SettingsLinkKey.deviceName.name: _deviceName.value,
    SettingsLinkKey.thresholds.name: switch (_thresholds) {
      final thresholds? => encodeThresholds(thresholds.value),
      null => null,
    },
    SettingsLinkKey.syncSecrets.name: _syncSecrets.value,
    SettingsLinkKey.pinPublication.name: switch (_pinPublication?.value) {
      final value? => encodePinPublication(value),
      null => null,
    },
    SettingsLinkKey.appVersion.name: _appVersion,
    SettingsLinkKey.monitorSet.name: encodeMonitorCandidates(_monitorSet.value),
    SettingsLinkKey.safety.name: encodeStoredSafety(_safety.value),
    SettingsLinkKey.labels.name: {
      for (final id in _safety.value.servers.keys) id: _safety.labelOf(id),
    },
    SettingsLinkKey.appLock.name: switch (_appLock) {
      final lock? => encodeAppLock(lock),
      null => null,
    },
  };

  Future<Object?> _handleCall(String name, Object? argument) async {
    // A locked app changes nothing from the settings window, which covers
    // itself then; a call already on its way when the lock engaged is
    // refused here.
    if (_appLock?.locked ?? false) throw const AppLockedException();
    switch (SettingsLinkMethod.values.asNameMap()[name]) {
      case null:
        throw MissingPluginException('No settings window method $name');
      case SettingsLinkMethod.setThemeMode:
        await _appearance.setMode(
          ThemeModePreference.values.byName(argument! as String),
        );
      case SettingsLinkMethod.setAppearance:
        final appearance = decodeAppearance(
          (argument! as Map).cast<String, Object?>(),
        );
        await _appearance.setAppearance(appearance.palette, appearance.mode);
      case SettingsLinkMethod.setAnnounceThresholdBands:
        await _announcements.setAnnounceThresholdBands(argument! as bool);
      case SettingsLinkMethod.setCadence:
        await _cadence?.setCadence(CadencePreset.parse(argument! as String));
      case SettingsLinkMethod.setCadenceCap:
        final [serverId as String, name as String?] = argument! as List;
        await _cadenceCaps?.setCap(serverId, CadenceCap.parse(name));
      case SettingsLinkMethod.setDeviceName:
        await _deviceName.setDeviceName(argument! as String);
      case SettingsLinkMethod.setThresholds:
        final call = (argument! as Map).cast<String, Object?>();
        final [careful, warning, critical] = [
          for (final level in call[SettingsLinkKey.levels.name]! as List)
            (level as num).toDouble(),
        ];
        final levels = thresholdsOf(careful, warning, critical);
        if (levels == null) {
          throw ArgumentError.value(argument, 'levels', 'not valid bands');
        }
        await _thresholds?.setThresholds(
          ThresholdMetric.values.byName(
            call[SettingsLinkKey.metric.name]! as String,
          ),
          levels,
        );
      case SettingsLinkMethod.setSyncSecrets:
        await _syncSecrets.setSyncSecrets(argument! as bool);
      case SettingsLinkMethod.setPinPublication:
        final pinPublication = _pinPublication;
        if (pinPublication == null) {
          throw StateError('No pin publication settings');
        }
        await pinPublication.setAsserted(argument! as bool);
      case SettingsLinkMethod.setMonitored:
        final change = (argument! as Map).cast<String, Object?>();
        await _monitorSet.setMonitored(
          change[SettingsLinkKey.serverId.name]! as String,
          monitored: change[SettingsLinkKey.monitored.name]! as bool,
        );
      case SettingsLinkMethod.setGlobalReadOnly:
        await _safety.setGlobalReadOnly(argument! as bool);
      case SettingsLinkMethod.setAdminExpiry:
        await _safety.setAdminExpiry(Duration(minutes: argument! as int));
      case SettingsLinkMethod.setAppLock:
        final appLock = _appLock;
        if (appLock == null) throw StateError('No app lock settings');
        // The device authentication runs here, in the app's window.
        return (await appLock.setEnabled(argument! as bool)).name;
      case SettingsLinkMethod.setServerSafety:
        final change = (argument! as Map).cast<String, Object?>();
        await _safety.setServerSafety(
          change[SettingsLinkKey.serverId.name]! as String,
          decodeServerSafety(
            (change[SettingsLinkKey.safety.name]! as Map)
                .cast<String, Object?>(),
          ),
        );
    }
    return null;
  }
}
