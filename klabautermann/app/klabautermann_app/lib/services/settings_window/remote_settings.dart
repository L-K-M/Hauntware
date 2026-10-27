// The settings window's side of the link: copies of the app's settings,
// replaced by every snapshot the host sends, whose every change runs in
// the app's isolate through `SettingsWindowHost`.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_theme/ghost_theme.dart';

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
import '../../ui/charts/charts.dart' show ChartThresholds;
import '../../ui/threshold_scope.dart';
import '../stored_safety.dart';
import '../../theme/app_theme.dart';
import 'settings_window_link.dart';

/// A diagnostic, never shown: a window that loses the app says so in its
/// own words ([GhostSettingsWindowClient.lost]).
const _linkClosed = 'Settings link closed';

/// The settings window's view of the app's settings.
final class RemoteSettings extends GhostSettingsWindowClient<SettingsTab> {
  RemoteSettings._(MethodChannel link)
    : super(
        link: link,
        tabs: SettingsTab.values,
        decodeError: decodeLinkError,
        lostError: () => const SettingsLinkException(_linkClosed),
      );

  /// Says hello to the app and takes its first snapshot. Throws when there
  /// is no app to answer: the window was started by hand rather than by
  /// the app.
  static Future<RemoteSettings> connect({
    MethodChannel link = settingsWindowLinkChannel,
  }) async {
    final remote = RemoteSettings._(link);
    await remote.connectToApp();
    return remote;
  }

  /// The Appearance tab's model, and the appearance the window draws itself
  /// in: the app's, from the latest snapshot.
  late final RemoteAppearance appearance = RemoteAppearance._(
    (method, argument) => invoke(method.name, argument),
  );

  /// The General tab's A11Y-15 switch, from the latest snapshot.
  late final RemoteAnnouncements announcements = RemoteAnnouncements._(
    (announce) =>
        invoke(SettingsLinkMethod.setAnnounceThresholdBands.name, announce),
  );

  /// The Alerts tab's usage bands, from the latest snapshot; null until
  /// the app offers them.
  RemoteThresholds? get thresholds => _thresholds.offered ? _thresholds : null;
  late final RemoteThresholds _thresholds = RemoteThresholds._(
    (metric, levels) => invoke(SettingsLinkMethod.setThresholds.name, {
      SettingsLinkKey.metric.name: metric.name,
      SettingsLinkKey.levels.name: [
        levels.careful,
        levels.warning,
        levels.critical,
      ],
    }),
  );

  /// The General tab's polling budget, from the latest snapshot; null
  /// while the app offers none.
  RemoteCadence? get cadence => _cadence.offered ? _cadence : null;

  late final RemoteCadence _cadence = RemoteCadence._(
    (preset) => invoke(SettingsLinkMethod.setCadence.name, preset.name),
  );

  /// The General tab's device name, from the latest snapshot.
  late final RemoteDeviceName deviceName = RemoteDeviceName._(
    (name) => invoke(SettingsLinkMethod.setDeviceName.name, name),
  );

  /// The Sync tab's "sync passwords" switch, from the latest snapshot.
  late final RemoteSyncSecrets syncSecrets = RemoteSyncSecrets._(
    (enabled) => invoke(SettingsLinkMethod.setSyncSecrets.name, enabled),
  );

  /// The Sync tab's host key sharing switch, from the latest snapshot.
  late final RemotePinPublication pinPublication = RemotePinPublication._(
    (asserted) => invoke(SettingsLinkMethod.setPinPublication.name, asserted),
  );

  /// The app's version for the about row, from the latest snapshot; null
  /// when the app could not tell.
  String? get appVersion => _appVersion;
  String? _appVersion;

  /// The Servers tab's monitor set toggles, from the latest snapshot.
  late final RemoteMonitorSet monitorSet = RemoteMonitorSet._(
    (serverId, monitored) => invoke(SettingsLinkMethod.setMonitored.name, {
      SettingsLinkKey.serverId.name: serverId,
      SettingsLinkKey.monitored.name: monitored,
    }),
  );

  /// The Safety tab's app lock switch, from the latest snapshot.
  late final RemoteAppLock appLock = RemoteAppLock._(
    (enabled) => invoke(SettingsLinkMethod.setAppLock.name, enabled),
  );

  /// The Safety tab's model, from the latest snapshot.
  late final RemoteSafety safety = RemoteSafety._(
    (method, argument) => invoke(method.name, argument),
  );

  @override
  void applySnapshot(Map<String, Object?> snapshot) {
    _appVersion = snapshot[SettingsLinkKey.appVersion.name] as String?;
    appearance._apply(
      decodeAppearance(
        (snapshot[SettingsLinkKey.appearance.name]! as Map)
            .cast<String, Object?>(),
      ),
    );
    announcements._apply(
      snapshot[SettingsLinkKey.announceThresholdBands.name]! as bool,
    );
    _cadence._apply(snapshot[SettingsLinkKey.cadence.name] as String?);
    deviceName._apply(snapshot[SettingsLinkKey.deviceName.name]! as String);
    _thresholds._apply(
      snapshot[SettingsLinkKey.thresholds.name] as Map<Object?, Object?>?,
    );
    syncSecrets._apply(snapshot[SettingsLinkKey.syncSecrets.name]! as bool);
    pinPublication._apply(
      decodePinPublication(
        snapshot[SettingsLinkKey.pinPublication.name] as Map<Object?, Object?>?,
      ),
    );
    monitorSet._apply(
      decodeMonitorCandidates(
        snapshot[SettingsLinkKey.monitorSet.name]! as List<Object?>,
      ),
    );
    safety._apply(
      decodeStoredSafety(
        (snapshot[SettingsLinkKey.safety.name]! as Map).cast<String, Object?>(),
      ),
      (snapshot[SettingsLinkKey.labels.name]! as Map).cast<String, String>(),
    );
    appLock._apply(
      snapshot[SettingsLinkKey.appLock.name] as Map<Object?, Object?>?,
    );
  }

  @override
  void dispose() {
    appearance.dispose();
    announcements.dispose();
    deviceName.dispose();
    _thresholds.dispose();
    syncSecrets.dispose();
    pinPublication.dispose();
    monitorSet.dispose();
    safety.dispose();
    appLock.dispose();
    super.dispose();
  }
}

/// [AnnouncementSettings] over the link: the app's switch as the latest
/// snapshot carries it, and changes that run in the app's isolate.
final class RemoteAnnouncements extends ChangeNotifier
    implements AnnouncementSettings {
  RemoteAnnouncements._(this._call);

  final Future<Object?> Function(bool announce) _call;

  // The app's default until the first snapshot, which comes with hello.
  bool _value = true;

  void _apply(bool announce) {
    if (announce == _value) return;
    _value = announce;
    notifyListeners();
  }

  @override
  bool get value => _value;

  @override
  Future<void> setAnnounceThresholdBands(bool announce) async {
    await _call(announce);
  }
}

/// [ThresholdSettings] over the link: the app's bands as the latest
/// snapshot carries them, and changes that run in the app's isolate.
final class RemoteThresholds extends ChangeNotifier
    implements ThresholdSettings {
  RemoteThresholds._(this._call);

  final Future<Object?> Function(ThresholdMetric metric, ChartThresholds levels)
  _call;

  /// Whether the app's snapshot carries bands; a build without them
  /// leaves the Alerts tab a placeholder.
  bool offered = false;

  MetricThresholds _value = decodeThresholds(const {});

  void _apply(Map<Object?, Object?>? stored) {
    offered = stored != null;
    final value = decodeThresholds({
      for (final MapEntry(:key, :value) in (stored ?? const {}).entries)
        if ((key, value) case (final String metric, final List<Object?> levels))
          metric: [
            for (final level in levels.whereType<num>()) level.toDouble(),
          ],
    });
    if (mapEquals(value, _value)) return;
    _value = value;
    notifyListeners();
  }

  @override
  MetricThresholds get value => _value;

  @override
  Future<void> setThresholds(
    ThresholdMetric metric,
    ChartThresholds levels,
  ) async {
    await _call(metric, levels);
  }
}

/// [CadenceSettings] over the link: the app's preset as the latest
/// snapshot carries it, and changes that run in the app's isolate.
final class RemoteCadence extends ChangeNotifier implements CadenceSettings {
  RemoteCadence._(this._call);

  final Future<Object?> Function(CadencePreset preset) _call;

  /// Whether the app offers a polling budget; the first snapshot says.
  bool offered = false;

  CadencePreset _value = CadencePreset.automatic;

  void _apply(String? name) {
    final preset = CadencePreset.parse(name);
    if (offered == (name != null) && preset == _value) return;
    offered = name != null;
    _value = preset;
    notifyListeners();
  }

  @override
  CadencePreset get value => _value;

  @override
  Future<void> setCadence(CadencePreset preset) async {
    await _call(preset);
  }
}

/// [DeviceNameSettings] over the link: the app's name as the latest
/// snapshot carries it, and changes that run in the app's isolate.
final class RemoteDeviceName extends ChangeNotifier
    implements DeviceNameSettings {
  RemoteDeviceName._(this._call);

  final Future<Object?> Function(String name) _call;

  // Blank until the first snapshot, which comes with hello.
  String _value = '';

  void _apply(String name) {
    if (name == _value) return;
    _value = name;
    notifyListeners();
  }

  @override
  String get value => _value;

  // As the app's controller reports it through its last answer here.
  bool _saved = true;

  @override
  bool get saved => _saved;

  @override
  Future<void> setDeviceName(String name) async {
    try {
      await _call(name);
      _saved = true;
    } on DeviceNameNotSavedException {
      _saved = false;
      rethrow;
    }
  }
}

/// [SyncSecretsSettings] over the link: the app's switch as the latest
/// snapshot carries it, and changes that run in the app's isolate.
final class RemoteSyncSecrets extends ChangeNotifier
    implements SyncSecretsSettings {
  RemoteSyncSecrets._(this._call);

  final Future<Object?> Function(bool enabled) _call;

  // The app's default until the first snapshot, which comes with hello.
  bool _value = false;

  void _apply(bool enabled) {
    if (enabled == _value) return;
    _value = enabled;
    notifyListeners();
  }

  @override
  bool get value => _value;

  @override
  Future<void> setSyncSecrets(bool enabled) async {
    await _call(enabled);
  }
}

/// [AppLockSettings] over the link: the app's lock as the latest snapshot
/// carries it, and a change whose device authentication runs in the
/// app's window. An app that offers no lock reads as unsupported.
final class RemoteAppLock extends ChangeNotifier implements AppLockSettings {
  RemoteAppLock._(this._call);

  final Future<Object?> Function(bool enabled) _call;

  bool _enabled = false;
  AppLockSupport _support = AppLockSupport.unsupported;
  bool _locked = false;

  void _apply(Map<Object?, Object?>? json) {
    final enabled = json?[SettingsLinkKey.enabled.name] as bool? ?? false;
    final support = switch (json?[SettingsLinkKey.support.name]) {
      final String name => AppLockSupport.values.byName(name),
      _ => AppLockSupport.unsupported,
    };
    final locked = json?[SettingsLinkKey.locked.name] as bool? ?? false;
    if (enabled == _enabled && support == _support && locked == _locked) {
      return;
    }
    _enabled = enabled;
    _support = support;
    _locked = locked;
    notifyListeners();
  }

  @override
  bool get enabled => _enabled;

  @override
  bool get locked => _locked;

  @override
  AppLockSupport get support => _support;

  @override
  Future<AppLockChange> setEnabled(bool enabled) async =>
      AppLockChange.values.byName((await _call(enabled))! as String);
}

/// [PinPublicationSettings] over the link: the app's state as the latest
/// snapshot carries it, and changes that run in the app's isolate.
final class RemotePinPublication extends ChangeNotifier
    implements PinPublicationSettings {
  RemotePinPublication._(this._call);

  final Future<Object?> Function(bool asserted) _call;

  // None offered until the first snapshot, which comes with hello.
  PinPublication _value = const PinPublication();

  void _apply(PinPublication value) {
    if (value == _value) return;
    _value = value;
    notifyListeners();
  }

  @override
  PinPublication get value => _value;

  @override
  Future<void> setAsserted(bool asserted) async {
    await _call(asserted);
  }
}

/// [MonitorSetSettings] over the link: the app's candidates as the latest
/// snapshot carries them, and toggles that run in the app's isolate.
final class RemoteMonitorSet extends ChangeNotifier
    implements MonitorSetSettings {
  RemoteMonitorSet._(this._call);

  final Future<Object?> Function(String serverId, bool monitored) _call;

  // None until the first snapshot, which comes with hello.
  List<MonitorCandidate> _value = const [];

  void _apply(List<MonitorCandidate> candidates) {
    if (listEquals(candidates, _value)) return;
    _value = List.unmodifiable(candidates);
    notifyListeners();
  }

  @override
  List<MonitorCandidate> get value => _value;

  @override
  Future<void> setMonitored(String serverId, {required bool monitored}) async {
    await _call(serverId, monitored);
  }
}

/// [AppearanceSettings] over the link: the app's appearance as the latest
/// snapshot carries it, and changes that run in the app's isolate.
///
/// Notifies only when a snapshot moves the appearance, so the window's
/// `MaterialApp`, which rebuilds for this alone, re-themes when the theme
/// changes (in the window or in the app) and for nothing else.
final class RemoteAppearance extends ChangeNotifier
    implements AppearanceSettings {
  RemoteAppearance._(this._call);

  final Future<Object?> Function(SettingsLinkMethod method, Object? argument)
  _call;

  AppAppearance _value = AppAppearance(
    palette: klabautermannThemePresets.initial,
  );

  void _apply(AppAppearance appearance) {
    if (appearance == _value) return;
    _value = appearance;
    notifyListeners();
  }

  @override
  AppAppearance get value => _value;

  @override
  Future<void> setMode(ThemeModePreference mode) async {
    await _call(SettingsLinkMethod.setThemeMode, mode.name);
  }

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    await _call(
      SettingsLinkMethod.setAppearance,
      encodeAppearance(AppAppearance(palette: palette, mode: mode)),
    );
  }
}

/// [SafetySettings] over the link: the app's policy and its servers'
/// labels as the latest snapshot carries them, and changes that run in
/// the app's isolate.
final class RemoteSafety extends ChangeNotifier implements SafetySettings {
  RemoteSafety._(this._call);

  final Future<Object?> Function(SettingsLinkMethod method, Object? argument)
  _call;

  // The engine's own default until the first snapshot, which comes with
  // hello.
  SafetyPolicy _value = const SafetyPolicy();
  Map<String, String> _labels = const {};

  void _apply(SafetyPolicy policy, Map<String, String> labels) {
    _value = policy;
    _labels = Map.unmodifiable(labels);
    notifyListeners();
  }

  @override
  SafetyPolicy get value => _value;

  @override
  String labelOf(String serverId) => _labels[serverId] ?? serverId;

  @override
  Future<void> setGlobalReadOnly(bool readOnly) async {
    await _call(SettingsLinkMethod.setGlobalReadOnly, readOnly);
  }

  @override
  Future<void> setAdminExpiry(Duration expiry) async {
    await _call(SettingsLinkMethod.setAdminExpiry, expiry.inMinutes);
  }

  @override
  Future<void> setServerSafety(String serverId, ServerSafety safety) async {
    await _call(SettingsLinkMethod.setServerSafety, {
      SettingsLinkKey.serverId.name: serverId,
      SettingsLinkKey.safety.name: encodeServerSafety(safety),
    });
  }
}
