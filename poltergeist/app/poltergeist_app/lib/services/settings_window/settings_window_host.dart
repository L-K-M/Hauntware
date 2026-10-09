// The app's side of the Settings window: ghost_desktop's link engine opens
// it and keeps it in step; this host answers what it asks through the same
// models the Settings dialogs use, and builds the snapshot it renders.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../ui/settings/general_settings.dart';
import '../../ui/settings/preview_settings.dart';
import '../double_click_action.dart';
import '../external_file_opener.dart';
import '../settings_models.dart';
import '../sync_account_gate.dart';
import 'settings_window_link.dart';

/// Where the Settings window's sections come from in the app. Each is
/// optional, as in the dialogs: a boot without the seam has nothing to show
/// there, and the window leaves the section out.
final class SettingsWindowSources {
  const SettingsWindowSources({
    this.general,
    this.editors,
    this.opener = const ExternalFileOpener(),
    this.previewDownloads,
    this.backup,
    this.gate = const SyncAccountGate.production(),
    this.appearance,
    this.editorTextSize,
    this.directoryGrouping,
    this.doubleClickAction,
    this.changes = const [],
  });

  /// The General rows, read afresh at each use (a lookup, like the dialog's).
  final GeneralSettings Function()? general;

  final EditorRegistryModel? editors;

  /// The platform picker behind `Add Editor…`, run in the app's engine
  /// where its channels and plugins live.
  final ExternalFileOpener opener;

  /// The Preview & downloads rows, read afresh at each use.
  final PreviewDownloadsSettings? Function()? previewDownloads;

  final BackupSettingsModel? backup;

  final SyncAccountGate gate;

  /// This device's theme: the Appearance tab's model, and what the window
  /// draws itself in, from each snapshot.
  final AppearanceSettingsModel? appearance;

  /// The built-in editor's text size: the Appearance tab's editor part.
  final EditorTextSizeModel? editorTextSize;

  /// Whether lists keep folders on top: the General tab's file-list row.
  final DirectoryGroupingModel? directoryGrouping;

  /// What opening a file does: the Editing tab's first row.
  final DoubleClickActionModel? doubleClickAction;

  /// What else moves a value the window shows (the update-check
  /// controller behind [general]); [editors], [backup], [appearance],
  /// [editorTextSize], [directoryGrouping] and [doubleClickAction] are
  /// listened to already.
  final List<Listenable> changes;
}

class SettingsWindowHost {
  /// [requestAppExit] answers the window's quit question; by default the
  /// app's own observers, the quit guard and the exit flush among them.
  SettingsWindowHost({
    MethodChannel control = settingsWindowControlChannel,
    MethodChannel link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
  }) {
    _engine = GhostSettingsWindowHost(
      control: control,
      link: link,
      initialTab: SettingsWindowTab.general,
      sections: _sectionsOf(_sources),
      encodeError: encodeLinkError,
      requestAppExit: requestAppExit,
    );
  }

  late final GhostSettingsWindowHost<SettingsWindowTab> _engine;
  SettingsWindowSources _sources = const SettingsWindowSources();

  @visibleForTesting
  bool get connected => _engine.connected;

  @visibleForTesting
  bool get visible => _engine.visible;

  /// Bind the sections — the workspace shell's, which owns some of them
  /// (the preview threshold lives in its state). Rebinding replaces them.
  void attach(SettingsWindowSources sources) {
    _sources = sources;
    _engine.attach(_sectionsOf(sources));
  }

  /// Open the window on [tab], or bring it forward and switch it there.
  /// False when the runner has no Settings window — a build from before it
  /// existed, or a test — so the caller can show the dialog instead.
  Future<bool> open(SettingsWindowTab tab) => _engine.open(tab);

  void dispose() => _engine.dispose();

  GhostSettingsSections _sectionsOf(SettingsWindowSources sources) =>
      GhostSettingsSections(
        snapshot: _snapshot,
        handleCall: _handleCall,
        changes: [
          ?sources.editors,
          ?sources.backup,
          ?sources.appearance,
          ?sources.editorTextSize,
          ?sources.directoryGrouping,
          ?sources.doubleClickAction,
          ...sources.changes,
        ],
      );

  /// Everything the window renders. Sections the app has no seam for are
  /// null, and the window leaves them out.
  Map<String, Object?> _snapshot() {
    final general = _sources.general?.call();
    final preview = _sources.previewDownloads?.call();
    final editors = _sources.editors;
    final backup = _sources.backup;
    final gate = _sources.gate;
    final appearance = _sources.appearance;
    final editorTextSize = _sources.editorTextSize;
    return {
      SettingsLinkKey.editorTextSize.name: editorTextSize?.value,
      SettingsLinkKey.directoryGrouping.name:
          _sources.directoryGrouping?.value.name,
      SettingsLinkKey.doubleClickAction.name:
          _sources.doubleClickAction?.value.name,
      SettingsLinkKey.general.name: general == null
          ? null
          : {SettingsLinkKey.checkForUpdates.name: general.checkForUpdates},
      SettingsLinkKey.editors.name: editors?.registry.toJson(),
      SettingsLinkKey.preview.name: preview == null
          ? null
          : {
              SettingsLinkKey.available.name: preview.available,
              SettingsLinkKey.capacityBytes.name: preview.capacityBytes,
              SettingsLinkKey.thresholdBytes.name: preview.thresholdBytes,
            },
      SettingsLinkKey.backup.name: backup == null
          ? null
          : _backupSnapshot(backup),
      SettingsLinkKey.gate.name: {
        SettingsLinkKey.minimumSharedVersion.name: gate.minimumSharedVersion,
        SettingsLinkKey.sharedIncludesSeance56Fix.name:
            gate.sharedIncludesSeance56Fix,
      },
      SettingsLinkKey.appearance.name: appearance == null
          ? null
          : encodeAppearance(appearance.value),
    };
  }

  static Map<String, Object?> _backupSnapshot(BackupSettingsModel backup) {
    final account = backup.account;
    final retained = backup.retainedAccount;
    return {
      SettingsLinkKey.account.name: account == null
          ? null
          : encodeSyncAccount(account),
      SettingsLinkKey.syncing.name: backup.syncing,
      SettingsLinkKey.syncSecrets.name: backup.syncSecrets,
      SettingsLinkKey.notices.name: backup.notices.toList()..sort(),
      SettingsLinkKey.passphraseUnverified.name: backup.passphraseUnverified,
      SettingsLinkKey.pinConflicts.name: [
        for (final conflict in backup.pinConflicts)
          encodeHostKeyConflict(conflict),
      ],
      SettingsLinkKey.trippedIds.name: backup.trippedIds.toList()..sort(),
      SettingsLinkKey.quarantinedPath.name: backup.quarantinedPath,
      SettingsLinkKey.lastSyncAt.name:
          backup.lastSyncAt?.millisecondsSinceEpoch,
      SettingsLinkKey.lastSyncError.name: backup.lastSyncError,
      SettingsLinkKey.retainedAccount.name: retained == null
          ? null
          : encodeRetainedAccount(retained),
      SettingsLinkKey.deleteSeparateOffered.name: backup.deleteSeparateOffered,
    };
  }

  Future<Object?> _handleCall(String name, Object? argument) async {
    final method = SettingsLinkMethod.values.asNameMap()[name];
    if (method == null) {
      throw MissingPluginException('No Settings window method $name');
    }
    return _dispatch(method, argument);
  }

  Future<Object?> _dispatch(SettingsLinkMethod method, Object? argument) async {
    Map<String, Object?> map() => (argument! as Map).cast<String, Object?>();
    String text(String key) => map()[key]! as String;
    final backup = _sources.backup;
    final editors = _sources.editors;
    switch (method) {
      case SettingsLinkMethod.setCheckForUpdates:
        await _require(
          _sources.general,
        )().onCheckForUpdatesChanged(argument! as bool);
      case SettingsLinkMethod.setAppearance:
        final appearance = decodeAppearance(map());
        await _require(
          _sources.appearance,
        ).setAppearance(appearance.palette, appearance.mode);
      case SettingsLinkMethod.setEditorTextSize:
        await _require(_sources.editorTextSize).setTextSize(argument! as int);
      case SettingsLinkMethod.setDirectoryGrouping:
        await _require(
          _sources.directoryGrouping,
        ).setGrouping(DirectoryGrouping.values.byName(argument! as String));
      case SettingsLinkMethod.setDoubleClickAction:
        await _require(
          _sources.doubleClickAction,
        ).setAction(DoubleClickAction.values.byName(argument! as String));
      case SettingsLinkMethod.registerEditor:
        await _require(editors).register(
          ExternalEditorDefinition.fromJson(map().cast<String, dynamic>()),
        );
      case SettingsLinkMethod.removeEditor:
        await _require(editors).remove(argument! as String);
      case SettingsLinkMethod.setDefaultEditor:
        await _require(editors).setDefault(argument! as String);
      case SettingsLinkMethod.pickEditor:
        final picked = await _sources.opener.pickEditor(
          dialogTitle: argument! as String,
        );
        return picked?.toJson();
      case SettingsLinkMethod.setPreviewCapacity:
        await _require(
          _sources.previewDownloads?.call(),
        ).onCapacityChanged(argument! as int);
        // The cap lives in the shell's cache, which notifies no one.
        _engine.snapshotChanged();
      case SettingsLinkMethod.setPreviewThreshold:
        await _require(
          _sources.previewDownloads?.call(),
        ).onThresholdChanged(argument! as int);
        _engine.snapshotChanged();
      case SettingsLinkMethod.clearPreviewCache:
        return await _require(_sources.previewDownloads?.call()).onClearCache();
      case SettingsLinkMethod.setSyncSecrets:
        await _require(backup).setSyncSecrets(argument! as bool);
      case SettingsLinkMethod.registerSeparate:
        await _require(backup).registerSeparate(
          baseUrl: text(SettingsLinkKey.baseUrl.name),
          username: text(SettingsLinkKey.username.name),
          password: text(SettingsLinkKey.password.name),
          encryptionPassphrase: text(SettingsLinkKey.encryptionPassphrase.name),
        );
      case SettingsLinkMethod.loginAccount:
        await _require(backup).loginAccount(
          baseUrl: text(SettingsLinkKey.baseUrl.name),
          username: text(SettingsLinkKey.username.name),
          password: text(SettingsLinkKey.password.name),
          encryptionPassphrase: text(SettingsLinkKey.encryptionPassphrase.name),
          mode: SyncAccountMode.values.byName(text(SettingsLinkKey.mode.name)),
        );
      case SettingsLinkMethod.backUpNow:
        await _require(backup).backUpNow();
      case SettingsLinkMethod.signOut:
        await _require(backup).signOut();
      case SettingsLinkMethod.deleteSeparateAccount:
        await _require(
          backup,
        ).deleteSeparateAccount(confirmedName: argument! as String);
      case SettingsLinkMethod.switchToShared:
        return encodeSwitchOutcome(
          await _require(backup).switchToShared(
            baseUrl: text(SettingsLinkKey.baseUrl.name),
            username: text(SettingsLinkKey.username.name),
            password: text(SettingsLinkKey.password.name),
            encryptionPassphrase: text(
              SettingsLinkKey.encryptionPassphrase.name,
            ),
          ),
        );
      case SettingsLinkMethod.resolvePinConflict:
        final json = map();
        await _require(backup).resolvePinConflict(
          decodeHostKeyConflict(
            (json[SettingsLinkKey.conflict.name]! as Map)
                .cast<String, Object?>(),
          ),
          keepLocal: json[SettingsLinkKey.keepLocal.name]! as bool,
        );
      case SettingsLinkMethod.deleteRetainedSeparateAccount:
        await _require(
          backup,
        ).deleteRetainedSeparateAccount(confirmedName: argument! as String);
      case SettingsLinkMethod.declineRetainedDelete:
        await _require(backup).declineRetainedDelete();
    }
    return null;
  }

  /// A section the window could only have shown if the app had it.
  static T _require<T extends Object>(T? source) =>
      source ?? (throw StateError('This section is not available.'));
}
