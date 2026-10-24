// The settings window's side of the link: copies of the app's settings,
// replaced by every snapshot the host sends, whose every change runs in
// the app's isolate through `SettingsWindowHost`.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_theme/ghost_theme.dart';

import '../../controllers/announcement_controller.dart';
import '../../controllers/appearance_controller.dart';
import '../../controllers/monitor_set.dart';
import '../../controllers/safety_controller.dart';
import '../../controllers/sync_secrets_controller.dart';
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

  /// The Sync tab's "sync passwords" switch, from the latest snapshot.
  late final RemoteSyncSecrets syncSecrets = RemoteSyncSecrets._(
    (enabled) => invoke(SettingsLinkMethod.setSyncSecrets.name, enabled),
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
    syncSecrets._apply(snapshot[SettingsLinkKey.syncSecrets.name]! as bool);
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
  }

  @override
  void dispose() {
    appearance.dispose();
    announcements.dispose();
    syncSecrets.dispose();
    monitorSet.dispose();
    safety.dispose();
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
