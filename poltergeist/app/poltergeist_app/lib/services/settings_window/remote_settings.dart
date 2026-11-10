// The Settings window's side of the link: the section models, each a copy
// of the app's replaced by every snapshot the host sends, whose every call
// runs in the app's isolate through [SettingsWindowHost].
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:ghost_keystore/app_lock.dart'
    show AppLockChange, AppLockSettings, AppLockSupport;
import 'package:planchette_editor/planchette_editor.dart' show EditorTextSize;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../theme/app_appearance.dart';
import '../../theme/theme_palette.dart';
import '../../ui/settings/general_settings.dart';
import '../../ui/settings/preview_settings.dart';
import '../bookmark_backup_service.dart'
    show BackupSwitchOutcome, RetainedBackupAccount;
import '../double_click_action.dart';
import '../editor_font.dart';
import '../external_file_opener.dart';
import '../settings_models.dart';
import '../sync_account_gate.dart';
import 'settings_window_link.dart';

/// What the window shows: nothing while it is hidden, or a Settings screen
/// opened on a tab, fresh at each showing.
typedef SettingsWindowPage = GhostSettingsPage<SettingsWindowTab>;

/// Calls into the app's isolate by Poltergeist's method names. A
/// [PlatformException] from there is the failure it reported, rebuilt as
/// its own type where the sections word it differently; no answer at all
/// means the app is gone.
final class _Link {
  _Link(this._invoke);

  final Future<Object?> Function(String method, Object? argument) _invoke;

  Future<Object?> call(SettingsLinkMethod method, [Object? argument]) =>
      _invoke(method.name, argument);
}

/// A diagnostic, never shown: a window that loses the app says so in its
/// own words ([RemoteSettings.lost]).
const _linkClosed = 'Settings link closed';

/// The Settings window's view of the app's settings.
class RemoteSettings extends GhostSettingsWindowClient<SettingsWindowTab> {
  RemoteSettings._(MethodChannel channel)
    : super(
        link: channel,
        tabs: SettingsWindowTab.values,
        decodeError: decodeLinkError,
        lostError: () => const SettingsLinkException(_linkClosed),
      );

  late final _Link _link = _Link(invoke);

  /// Say hello to the app and take its first snapshot. Throws when there is
  /// no app to answer — the window was started by hand rather than by the
  /// app.
  static Future<RemoteSettings> connect({
    MethodChannel link = settingsWindowLinkChannel,
  }) async {
    final remote = RemoteSettings._(link);
    await remote.connectToApp();
    return remote;
  }

  bool? _checkForUpdates;
  String? _appVersion;
  Map<String, Object?>? _preview;
  RemoteEditorRegistry? _editors;
  RemoteBackupSettings? _backup;
  bool _hasRecovery = false;
  late final RemoteRecovery _recovery = RemoteRecovery._(_link);
  late final RemoteAppearanceSettings _appearance = RemoteAppearanceSettings._(
    _link,
  );
  bool _hasAppearance = false;
  late final RemoteEditorTextSize _editorTextSize = RemoteEditorTextSize._(
    _link,
  );
  bool _hasEditorTextSize = false;
  late final RemoteEditorFont _editorFont = RemoteEditorFont._(_link);
  bool _hasEditorFont = false;
  late final RemoteDirectoryGrouping _directoryGrouping =
      RemoteDirectoryGrouping._(_link);
  bool _hasDirectoryGrouping = false;
  late final RemoteDoubleClickAction _doubleClickAction =
      RemoteDoubleClickAction._(_link);
  bool _hasDoubleClickAction = false;
  late final RemoteAppLock appLock = RemoteAppLock._(
    (enabled) => _link.call(SettingsLinkMethod.setAppLock, enabled),
  );
  SyncAccountGate _gate = const SyncAccountGate.production();

  /// The General rows, or null when the app has none.
  GeneralSettings? get general {
    final checkForUpdates = _checkForUpdates;
    if (checkForUpdates == null) return null;
    return GeneralSettings(
      checkForUpdates: checkForUpdates,
      appVersion: _appVersion,
      onCheckForUpdatesChanged: (enabled) =>
          _link.call(SettingsLinkMethod.setCheckForUpdates, enabled),
    );
  }

  /// The Preview & downloads rows, or null when the app has none.
  PreviewDownloadsSettings? get previewDownloads {
    final preview = _preview;
    if (preview == null) return null;
    return PreviewDownloadsSettings(
      available: preview[SettingsLinkKey.available.name]! as bool,
      capacityBytes: preview[SettingsLinkKey.capacityBytes.name]! as int,
      thresholdBytes: preview[SettingsLinkKey.thresholdBytes.name]! as int,
      onCapacityChanged: (bytes) =>
          _link.call(SettingsLinkMethod.setPreviewCapacity, bytes),
      onThresholdChanged: (bytes) =>
          _link.call(SettingsLinkMethod.setPreviewThreshold, bytes),
      onClearCache: () async =>
          (await _link.call(SettingsLinkMethod.clearPreviewCache))! as int,
    );
  }

  /// The editor registry, or null when the app has none.
  EditorRegistryModel? get editors => _editors;

  /// The Backup section's model, or null when the app has no backup
  /// service.
  BackupSettingsModel? get backup => _backup;

  /// The Recovery section's model, or null when the app has no recovery
  /// service.
  RecoverySettingsModel? get recovery => _hasRecovery ? _recovery : null;

  /// The Appearance tab's model, or null when the app has no theme seam.
  AppearanceSettingsModel? get appearance =>
      _hasAppearance ? _appearance : null;

  /// The Appearance tab's built-in editor part, or null when the app has
  /// no editor text size.
  EditorTextSizeModel? get editorTextSize =>
      _hasEditorTextSize ? _editorTextSize : null;

  /// The editor part's font rows, or null when the app has no editor font.
  EditorFontModel? get editorFont => _hasEditorFont ? _editorFont : null;

  /// The General tab's file-list row, or null when the app has none.
  DirectoryGroupingModel? get directoryGrouping =>
      _hasDirectoryGrouping ? _directoryGrouping : null;

  /// The Editing tab's file-open row, or null when the app has none.
  DoubleClickActionModel? get doubleClickAction =>
      _hasDoubleClickAction ? _doubleClickAction : null;

  /// The theme the window draws itself in: the app's, from the latest
  /// snapshot, or the default theme when the app has no theme seam. One
  /// notifier for the window's run, so its MaterialApp listens to one
  /// thing whatever the snapshots say.
  ValueListenable<AppAppearance> get theme => _appearance;

  SyncAccountGate get gate => _gate;

  /// `Add Editor…`'s picker, shown by the app: this engine has no plugins
  /// or runner channels of its own.
  Future<ExternalEditorDefinition?> pickEditor({
    required String dialogTitle,
  }) async {
    final json = await _link.call(SettingsLinkMethod.pickEditor, dialogTitle);
    return json == null
        ? null
        : ExternalEditorDefinition.fromJson(
            (json as Map).cast<String, dynamic>(),
          );
  }

  @override
  void applySnapshot(Map<String, Object?> snapshot) {
    final general = snapshot[SettingsLinkKey.general.name] as Map?;
    _checkForUpdates = general?[SettingsLinkKey.checkForUpdates.name] as bool?;
    _appVersion = general?[SettingsLinkKey.appVersion.name] as String?;
    _preview = (snapshot[SettingsLinkKey.preview.name] as Map?)
        ?.cast<String, Object?>();

    final editors = snapshot[SettingsLinkKey.editors.name];
    if (editors == null) {
      _editors = null;
    } else {
      (_editors ??= RemoteEditorRegistry._(
        _link,
      ))._apply(EditorRegistry.fromJson(editors));
    }

    final backup = (snapshot[SettingsLinkKey.backup.name] as Map?)
        ?.cast<String, Object?>();
    if (backup == null) {
      _backup = null;
    } else {
      (_backup ??= RemoteBackupSettings._(_link))._apply(backup);
    }

    final recovery = (snapshot[SettingsLinkKey.recovery.name] as Map?)
        ?.cast<String, Object?>();
    _hasRecovery = recovery != null;
    _recovery._apply(recovery);

    final appearance = (snapshot[SettingsLinkKey.appearance.name] as Map?)
        ?.cast<String, Object?>();
    _hasAppearance = appearance != null;
    _appearance._apply(
      appearance == null ? AppAppearance.initial : decodeAppearance(appearance),
    );

    final editorTextSize = snapshot[SettingsLinkKey.editorTextSize.name] as int?;
    _hasEditorTextSize = editorTextSize != null;
    if (editorTextSize != null) _editorTextSize._apply(editorTextSize);

    final editorFont = (snapshot[SettingsLinkKey.editorFont.name] as Map?)
        ?.cast<String, Object?>();
    _hasEditorFont = editorFont != null;
    if (editorFont != null) _editorFont._apply(decodeEditorFont(editorFont));

    final grouping = snapshot[SettingsLinkKey.directoryGrouping.name] as String?;
    _hasDirectoryGrouping = grouping != null;
    if (grouping != null) {
      _directoryGrouping._apply(DirectoryGrouping.values.byName(grouping));
    }

    final action = snapshot[SettingsLinkKey.doubleClickAction.name] as String?;
    _hasDoubleClickAction = action != null;
    if (action != null) {
      _doubleClickAction._apply(DoubleClickAction.values.byName(action));
    }

    appLock._apply(
      snapshot[SettingsLinkKey.appLock.name] as Map<Object?, Object?>?,
    );

    final gate = (snapshot[SettingsLinkKey.gate.name]! as Map)
        .cast<String, Object?>();
    _gate = SyncAccountGate(
      minimumSharedVersion:
          gate[SettingsLinkKey.minimumSharedVersion.name] as String?,
      sharedIncludesSeance56Fix:
          gate[SettingsLinkKey.sharedIncludesSeance56Fix.name]! as bool,
    );
  }

  @override
  void dispose() {
    _appearance.dispose();
    _directoryGrouping.dispose();
    _doubleClickAction.dispose();
    _editorTextSize.dispose();
    _editorFont.dispose();
    _recovery.dispose();
    appLock.dispose();
    super.dispose();
  }
}

/// [AppearanceSettingsModel] over the link: the app's theme as the latest
/// snapshot carries it, and writes that run in the app's isolate.
///
/// Notifies only when a snapshot moves the theme. Every snapshot passes
/// through here, and the window's MaterialApp rebuilds for this alone, so
/// an edit on the Appearance tab re-themes the window it is made in as
/// well as the app, and nothing else re-themes it.
final class RemoteAppearanceSettings extends ChangeNotifier
    implements AppearanceSettingsModel {
  RemoteAppearanceSettings._(this._link);

  final _Link _link;
  AppAppearance _value = AppAppearance.initial;

  void _apply(AppAppearance appearance) {
    if (appearance == _value) return;
    _value = appearance;
    notifyListeners();
  }

  @override
  AppAppearance get value => _value;

  @override
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode) =>
      _link.call(
        SettingsLinkMethod.setAppearance,
        encodeAppearance(AppAppearance(palette: palette, mode: mode)),
      );
}

/// [EditorTextSizeModel] over the link: the app's size as the latest
/// snapshot carries it, and writes that run in the app's isolate.
final class RemoteEditorTextSize extends ChangeNotifier
    implements EditorTextSizeModel {
  RemoteEditorTextSize._(this._link);

  final _Link _link;
  int _value = EditorTextSize.standard;

  void _apply(int size) {
    if (size == _value) return;
    _value = size;
    notifyListeners();
  }

  @override
  int get value => _value;

  @override
  Future<void> setTextSize(int size) =>
      _link.call(SettingsLinkMethod.setEditorTextSize, size);
}

/// [EditorFontModel] over the link: the app's font as the latest snapshot
/// carries it, and writes that run in the app's isolate.
final class RemoteEditorFont extends ChangeNotifier implements EditorFontModel {
  RemoteEditorFont._(this._link);

  final _Link _link;
  EditorFont _value = EditorFont.standard;

  void _apply(EditorFont font) {
    if (font == _value) return;
    _value = font;
    notifyListeners();
  }

  @override
  EditorFont get value => _value;

  @override
  Future<void> setFont(EditorFont font) =>
      _link.call(SettingsLinkMethod.setEditorFont, encodeEditorFont(font));
}

/// [DirectoryGroupingModel] over the link: the app's value as the latest
/// snapshot carries it, and writes that run in the app's isolate.
final class RemoteDirectoryGrouping extends ChangeNotifier
    implements DirectoryGroupingModel {
  RemoteDirectoryGrouping._(this._link);

  final _Link _link;
  DirectoryGrouping _value = DirectoryGrouping.first;

  void _apply(DirectoryGrouping grouping) {
    if (grouping == _value) return;
    _value = grouping;
    notifyListeners();
  }

  @override
  DirectoryGrouping get value => _value;

  @override
  Future<void> setGrouping(DirectoryGrouping grouping) =>
      _link.call(SettingsLinkMethod.setDirectoryGrouping, grouping.name);
}

/// [DoubleClickActionModel] over the link: the app's value as the latest
/// snapshot carries it, and writes that run in the app's isolate.
final class RemoteDoubleClickAction extends ChangeNotifier
    implements DoubleClickActionModel {
  RemoteDoubleClickAction._(this._link);

  final _Link _link;
  DoubleClickAction _value = DoubleClickAction.open;

  void _apply(DoubleClickAction action) {
    if (action == _value) return;
    _value = action;
    notifyListeners();
  }

  @override
  DoubleClickAction get value => _value;

  @override
  Future<void> setAction(DoubleClickAction action) =>
      _link.call(SettingsLinkMethod.setDoubleClickAction, action.name);
}

/// [EditorRegistryModel] over the link.
final class RemoteEditorRegistry extends ChangeNotifier
    implements EditorRegistryModel {
  RemoteEditorRegistry._(this._link);

  final _Link _link;
  EditorRegistry _registry = EditorRegistry();
  String? _registryJson;

  void _apply(EditorRegistry registry) {
    final json = jsonEncode(registry.toJson());
    if (json == _registryJson) return;
    _registryJson = json;
    _registry = registry;
    notifyListeners();
  }

  @override
  EditorRegistry get registry => _registry;

  @override
  Future<void> register(ExternalEditorDefinition editor) =>
      _link.call(SettingsLinkMethod.registerEditor, editor.toJson());

  @override
  Future<void> remove(String id) =>
      _link.call(SettingsLinkMethod.removeEditor, id);

  @override
  Future<void> setDefault(String id) =>
      _link.call(SettingsLinkMethod.setDefaultEditor, id);
}

/// [BackupSettingsModel] over the link.
final class RemoteBackupSettings extends ChangeNotifier
    implements BackupSettingsModel {
  RemoteBackupSettings._(this._link);

  final _Link _link;
  Map<String, Object?> _state = const {};
  String? _stateJson;

  SyncAccount? _account;
  List<HostKeyConflict> _pinConflicts = const [];
  RetainedBackupAccount? _retainedAccount;

  void _apply(Map<String, Object?> state) {
    final json = jsonEncode(state);
    if (json == _stateJson) return;
    _stateJson = json;
    _state = state;
    final account = state[SettingsLinkKey.account.name] as Map?;
    _account = account == null
        ? null
        : decodeSyncAccount(account.cast<String, Object?>());
    _pinConflicts = [
      for (final conflict in state[SettingsLinkKey.pinConflicts.name]! as List)
        decodeHostKeyConflict((conflict as Map).cast<String, Object?>()),
    ];
    final retained = state[SettingsLinkKey.retainedAccount.name] as Map?;
    _retainedAccount = retained == null
        ? null
        : decodeRetainedAccount(retained.cast<String, Object?>());
    notifyListeners();
  }

  @override
  SyncAccount? get account => _account;

  @override
  bool get syncing => _state[SettingsLinkKey.syncing.name]! as bool;

  @override
  bool get syncSecrets => _state[SettingsLinkKey.syncSecrets.name]! as bool;

  @override
  Set<String> get notices => {
    ...(_state[SettingsLinkKey.notices.name]! as List).cast<String>(),
  };

  @override
  bool get passphraseUnverified =>
      _state[SettingsLinkKey.passphraseUnverified.name]! as bool;

  @override
  List<HostKeyConflict> get pinConflicts => _pinConflicts;

  @override
  Set<String> get trippedIds => {
    ...(_state[SettingsLinkKey.trippedIds.name]! as List).cast<String>(),
  };

  @override
  String? get quarantinedPath =>
      _state[SettingsLinkKey.quarantinedPath.name] as String?;

  @override
  DateTime? get lastSyncAt {
    final millis = _state[SettingsLinkKey.lastSyncAt.name] as int?;
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  @override
  String? get lastSyncError =>
      _state[SettingsLinkKey.lastSyncError.name] as String?;

  @override
  RetainedBackupAccount? get retainedAccount => _retainedAccount;

  @override
  bool get deleteSeparateOffered =>
      _state[SettingsLinkKey.deleteSeparateOffered.name]! as bool;

  @override
  Future<void> setSyncSecrets(bool enabled) =>
      _link.call(SettingsLinkMethod.setSyncSecrets, enabled);

  /// The password and passphrase cross to the app's isolate in memory
  /// only; nothing on the link is persisted.
  @override
  Future<void> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) => _link.call(SettingsLinkMethod.registerSeparate, {
    SettingsLinkKey.baseUrl.name: baseUrl,
    SettingsLinkKey.username.name: username,
    SettingsLinkKey.password.name: password,
    SettingsLinkKey.encryptionPassphrase.name: encryptionPassphrase,
  });

  @override
  Future<void> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) => _link.call(SettingsLinkMethod.loginAccount, {
    SettingsLinkKey.baseUrl.name: baseUrl,
    SettingsLinkKey.username.name: username,
    SettingsLinkKey.password.name: password,
    SettingsLinkKey.encryptionPassphrase.name: encryptionPassphrase,
    SettingsLinkKey.mode.name: mode.name,
  });

  @override
  Future<void> backUpNow() => _link.call(SettingsLinkMethod.backUpNow);

  @override
  Future<void> signOut() => _link.call(SettingsLinkMethod.signOut);

  @override
  Future<void> deleteSeparateAccount({required String confirmedName}) =>
      _link.call(SettingsLinkMethod.deleteSeparateAccount, confirmedName);

  @override
  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async => decodeSwitchOutcome(
    ((await _link.call(SettingsLinkMethod.switchToShared, {
              SettingsLinkKey.baseUrl.name: baseUrl,
              SettingsLinkKey.username.name: username,
              SettingsLinkKey.password.name: password,
              SettingsLinkKey.encryptionPassphrase.name: encryptionPassphrase,
            }))!
            as Map)
        .cast<String, Object?>(),
  );

  @override
  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) => _link.call(SettingsLinkMethod.resolvePinConflict, {
    SettingsLinkKey.conflict.name: encodeHostKeyConflict(conflict),
    SettingsLinkKey.keepLocal.name: keepLocal,
  });

  @override
  Future<void> deleteRetainedSeparateAccount({required String confirmedName}) =>
      _link.call(
        SettingsLinkMethod.deleteRetainedSeparateAccount,
        confirmedName,
      );

  @override
  Future<void> declineRetainedDelete() =>
      _link.call(SettingsLinkMethod.declineRetainedDelete);
}

/// [RecoverySettingsModel] over the link: the app's configured flag as
/// the latest snapshot carries it, and the explicit actions run in the
/// app's isolate, where the file panels and the vault key live.
final class RemoteRecovery extends ChangeNotifier
    implements RecoverySettingsModel {
  RemoteRecovery._(this._link);

  final _Link _link;
  bool? _configured;

  void _apply(Map<Object?, Object?>? json) {
    final configured = json?[SettingsLinkKey.configured.name] as bool?;
    if (configured == _configured) return;
    _configured = configured;
    notifyListeners();
  }

  @override
  bool? get configured => _configured;

  @override
  Future<String> newCode() async =>
      (await _link.call(SettingsLinkMethod.newRecoveryCode))! as String;

  /// The code crosses to the app's isolate in memory only, to be kept
  /// there; nothing on the link is persisted.
  @override
  Future<void> saveCode(String code) =>
      _link.call(SettingsLinkMethod.saveRecoveryCode, code);

  @override
  Future<String?> exportSecrets() async =>
      await _link.call(SettingsLinkMethod.exportSecrets) as String?;

  /// The code crosses to the app's isolate in memory only; the file is
  /// read there and never crosses.
  @override
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required RestoreConflictPolicy policy,
  }) async {
    final json = await _link.call(SettingsLinkMethod.restoreSecrets, {
      SettingsLinkKey.code.name: code,
      SettingsLinkKey.policy.name: policy.name,
    });
    return json == null
        ? null
        : SecretsRestoreSummary.fromJson(
            (json as Map).cast<String, dynamic>(),
          );
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
