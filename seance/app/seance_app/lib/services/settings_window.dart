import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

import '../app_state.dart';
import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import '../ui/terminal_appearance.dart';
import 'app_settings.dart';
import 'external_file_opener.dart';
import 'local_settings_backend.dart';
import 'local_shell_service.dart';
import 'secrets_recovery.dart';
import 'settings_backend.dart';

/// The desktop Settings window: a native window of its own, on a second
/// Flutter engine, whose Dart side runs `runSettingsWindow` rather than the
/// app.
///
/// Created the first time Settings is opened and kept for the rest of the
/// app's life: closing it hides it, and opening it again shows a fresh
/// screen. ghost_desktop's link engine (`GhostSettingsWindowHost`,
/// `GhostSettingsWindowClient`) owns that lifecycle, the handshake and the
/// snapshots; what is here is Séance's: the channels, the method table, the
/// snapshot and [SettingsBackend] on both sides.
///
/// Two channels connect it to the app, both in the runners
/// (`macos/Runner/SettingsWindow.swift`, `linux/runner/settings_window.cc`,
/// `windows/runner/settings_window.cpp`):
///
/// - [settingsWindowControlChannel], on the app's engine only: Dart asks the
///   runner to open the window (or bring it forward), and the runner reports
///   `closed` when the user closes — hides — it.
/// - [settingsWindowLinkChannel], on both engines: the runner forwards every
///   message one engine sends on it to the other, byte for byte, and the
///   reply back. That is the only way two engines can talk — they share
///   nothing else — so it carries the whole of [SettingsBackend].
const MethodChannel settingsWindowControlChannel = MethodChannel(
  'seance/settings_window',
);

/// See [settingsWindowControlChannel].
const MethodChannel settingsWindowLinkChannel = MethodChannel(
  'seance/settings_link',
);

/// The argument the runners start the settings window's engine with.
const String settingsWindowArgument = '--seance-settings-window';

/// Séance's link methods, window to app; each crosses as its [name], so a
/// typo is a compile error rather than a silent `null` on the far side.
/// The names of ghost_desktop's `GhostSettingsLinkMethod` are the engine's.
@visibleForTesting
enum SettingsLinkMethod {
  setCheckForUpdates,
  setLocalShellEnabled,
  setKeepSessionsAlive,
  setCommandSuggestions,
  setTerminalAppearance,
  setEditorFontSize,
  setAppearance,
  setEditorRegistry,
  pickEditor,
  fetchModels,
  saveAssistant,
  setSyncPrefs,
  enrollSync,
  syncNow,
  inboxApps,
  addInboxApp,
  updateInboxApp,
  removeInboxApp,
  recoveryConfigured,
  newRecoveryCode,
  saveRecoveryCode,
  exportSecrets,
  restoreSecrets,
}

/// What the window renders from: the settings and the two live values the
/// screen watches.
Map<String, dynamic> _snapshotOf(SettingsBackend backend) => {
  'settings': backend.settings.toJson(),
  'llmConfigVersion': backend.llmConfigVersion,
  'syncStatus': backend.syncStatus.toJson(),
};

/// The app's side of the settings window: ghost_desktop's link engine
/// opens it and sends it a fresh snapshot whenever the app's state changes
/// while it shows; this host answers what it asks through a
/// [LocalSettingsBackend].
class SettingsWindowHost {
  /// [exportFiles] replaces the platform's save and open panels for a
  /// secrets export, in tests.
  SettingsWindowHost(
    AppState state, {
    MethodChannel control = settingsWindowControlChannel,
    MethodChannel link = settingsWindowLinkChannel,
    @visibleForTesting Future<AppExitResponse> Function()? requestAppExit,
    @visibleForTesting SecretsExportFiles? exportFiles,
  }) : _backend = exportFiles == null
           ? LocalSettingsBackend(state)
           : LocalSettingsBackend(state, exportFiles: exportFiles) {
    _engine = GhostSettingsWindowHost(
      control: control,
      link: link,
      initialTab: SettingsTab.general,
      sections: GhostSettingsSections(
        snapshot: () => _snapshotOf(_backend),
        handleCall: _handleCall,
        changes: [state],
      ),
      requestAppExit: requestAppExit,
    );
  }

  final LocalSettingsBackend _backend;
  late final GhostSettingsWindowHost<SettingsTab> _engine;

  @visibleForTesting
  bool get connected => _engine.connected;

  @visibleForTesting
  bool get visible => _engine.visible;

  /// Open the window on [tab], or bring an open one forward and switch it
  /// there. False when the runner has no settings window — a build from
  /// before it existed — so the caller can show the Settings route instead.
  Future<bool> open(SettingsTab tab) => _engine.open(tab);

  void dispose() => _engine.dispose();

  Future<Object?> _handleCall(String name, Object? argument) async {
    final method = SettingsLinkMethod.values.asNameMap()[name];
    if (method == null) {
      throw MissingPluginException('No settings method $name');
    }
    return _dispatch(method, argument);
  }

  Future<Object?> _dispatch(
    SettingsLinkMethod method,
    Object? argument,
  ) async {
    Map<String, dynamic> map() => (argument! as Map).cast<String, dynamic>();
    switch (method) {
      case SettingsLinkMethod.setCheckForUpdates:
        await _backend.setCheckForUpdates(argument! as bool);
      case SettingsLinkMethod.setLocalShellEnabled:
        await _backend.setLocalShellEnabled(argument! as bool);
      case SettingsLinkMethod.setKeepSessionsAlive:
        await _backend.setKeepSessionsAlive(argument! as bool);
      case SettingsLinkMethod.setCommandSuggestions:
        await _backend.setCommandSuggestions(argument! as bool);
      case SettingsLinkMethod.setTerminalAppearance:
        final json = map();
        await _backend.setTerminalAppearance(
          fontSize: (json['fontSize'] as num).toDouble(),
          fontFamily: json['fontFamily'] as String,
          palette: TerminalPalette.values.byName(json['palette'] as String),
        );
      case SettingsLinkMethod.setEditorFontSize:
        await _backend.setEditorFontSize(argument! as int);
      case SettingsLinkMethod.setAppearance:
        final json = map();
        await _backend.setAppearance(
          ThemePalette.decodeStored(json['palette']),
          ThemeModePreference.values.byName(json['mode'] as String),
        );
      case SettingsLinkMethod.setEditorRegistry:
        await _backend.setEditorRegistry(EditorRegistry.fromJson(argument));
      case SettingsLinkMethod.pickEditor:
        return (await _backend.pickEditor())?.toJson();
      case SettingsLinkMethod.fetchModels:
        return await _backend.fetchModels(ModelQuery.fromJson(map()));
      case SettingsLinkMethod.saveAssistant:
        return (await _backend.saveAssistant(
          AssistantDraft.fromJson(map()),
        )).toJson();
      case SettingsLinkMethod.setSyncPrefs:
        final json = map();
        return (await _backend.setSyncPrefs(
          autoSync: json['autoSync'] as bool,
          syncSecrets: json['syncSecrets'] as bool,
          syncAssistant: json['syncAssistant'] as bool,
        )).toJson();
      case SettingsLinkMethod.enrollSync:
        await _backend.enrollSync(SyncEnrollment.fromJson(map()));
      case SettingsLinkMethod.syncNow:
        return (await _backend.syncNow()).toJson();
      case SettingsLinkMethod.inboxApps:
        return (await _backend.inboxApps()).toJson();
      case SettingsLinkMethod.addInboxApp:
        return await _backend.addInboxApp(InboxAppDraft.fromJson(map()));
      case SettingsLinkMethod.updateInboxApp:
        final json = map();
        await _backend.updateInboxApp(
          json['app'] as String,
          InboxAppDraft.fromJson((json['draft'] as Map).cast()),
        );
      case SettingsLinkMethod.removeInboxApp:
        await _backend.removeInboxApp(argument! as String);
      case SettingsLinkMethod.recoveryConfigured:
        return await _backend.recoveryConfigured();
      case SettingsLinkMethod.newRecoveryCode:
        return await _backend.newRecoveryCode();
      case SettingsLinkMethod.saveRecoveryCode:
        await _backend.saveRecoveryCode(argument! as String);
      case SettingsLinkMethod.exportSecrets:
        return await _backend.exportSecrets();
      case SettingsLinkMethod.restoreSecrets:
        final json = map();
        return (await _backend.restoreSecrets(
          code: json['code'] as String,
          policy: RestoreConflictPolicy.values.byName(json['policy'] as String),
        ))?.toJson();
    }
    return null;
  }
}

/// What the settings window shows: nothing while it is hidden, or a Settings
/// screen opened on a tab, fresh at each showing (its fields and half-typed
/// keys are not the last showing's).
typedef SettingsWindowPage = GhostSettingsPage<SettingsTab>;

/// What a call throws when no app answers it.
const _notResponding =
    'Séance is not responding. Close this window and open Settings again.';

/// The settings window's side: a [SettingsBackend] whose every call runs in
/// the app's isolate, through [SettingsWindowHost].
///
/// [settings] is a copy, replaced by each snapshot the host sends; the screen
/// loads its fields from it once and otherwise only watches the sync status
/// and the configuration version, as it does in the route.
class RemoteSettingsBackend extends GhostSettingsWindowClient<SettingsTab>
    implements SettingsBackend {
  RemoteSettingsBackend._(MethodChannel link)
    : super(
        link: link,
        tabs: SettingsTab.values,
        decodeError: (error) =>
            SettingsBackendException(error.message ?? error.code),
        lostError: () => const SettingsBackendException(_notResponding),
      );

  late AppSettings _settings;
  late int _llmConfigVersion;
  late SyncStatus _syncStatus;

  /// The theme the window draws itself in: the app's, from the latest
  /// snapshot. Its own notifier for the reason [AppState.appearance] is
  /// one — every snapshot notifies, and the window's MaterialApp rebuilds
  /// only for the ones that change the theme, so an edit on the Appearance
  /// tab re-themes the window it is made in as well as the app.
  ValueListenable<AppAppearance> get appearance => _appearance;
  final ValueNotifier<AppAppearance> _appearance = ValueNotifier(
    AppAppearance.initial,
  );

  /// Say hello to the app and take its first snapshot. Throws a
  /// [SettingsBackendException] when there is no app to answer — the window
  /// was started by hand rather than by the app.
  static Future<RemoteSettingsBackend> connect({
    MethodChannel link = settingsWindowLinkChannel,
  }) async {
    final backend = RemoteSettingsBackend._(link);
    await backend.connectToApp();
    return backend;
  }

  @override
  AppSettings get settings => _settings;

  @override
  int get llmConfigVersion => _llmConfigVersion;

  @override
  SyncStatus get syncStatus => _syncStatus;

  @override
  void applySnapshot(Map<String, Object?> snapshot) {
    _settings = AppSettings.fromJson(
      (snapshot['settings'] as Map).cast<String, dynamic>(),
    );
    _appearance.value = AppAppearance(
      palette: _settings.themePalette,
      mode: _settings.themeMode,
    );
    _llmConfigVersion = snapshot['llmConfigVersion'] as int;
    _syncStatus = SyncStatus.fromJson(
      (snapshot['syncStatus'] as Map).cast<String, dynamic>(),
    );
  }

  Future<Object?> _call(SettingsLinkMethod method, [Object? argument]) =>
      invoke(method.name, argument);

  Map<String, dynamic> _map(Object? value) =>
      (value! as Map).cast<String, dynamic>();

  @override
  Future<void> setCheckForUpdates(bool enabled) =>
      _call(SettingsLinkMethod.setCheckForUpdates, enabled);

  /// This engine shares the app's process — the platform and environment a
  /// local shell reads are identical on both sides, so the answer is
  /// computed here rather than carried over the link.
  @override
  LocalShellInfo get localShell =>
      LocalShellInfo.of(LocalShellService());

  @override
  Future<void> setLocalShellEnabled(bool enabled) =>
      _call(SettingsLinkMethod.setLocalShellEnabled, enabled);

  @override
  Future<void> setKeepSessionsAlive(bool enabled) =>
      _call(SettingsLinkMethod.setKeepSessionsAlive, enabled);

  @override
  Future<void> setCommandSuggestions(bool enabled) =>
      _call(SettingsLinkMethod.setCommandSuggestions, enabled);

  @override
  Future<void> setTerminalAppearance({
    required double fontSize,
    required String fontFamily,
    required TerminalPalette palette,
  }) => _call(SettingsLinkMethod.setTerminalAppearance, {
    'fontSize': fontSize,
    'fontFamily': fontFamily,
    'palette': palette.name,
  });

  @override
  Future<void> setEditorFontSize(int size) =>
      _call(SettingsLinkMethod.setEditorFontSize, size);

  @override
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode) =>
      _call(SettingsLinkMethod.setAppearance, {
        'palette': palette.toJson(),
        'mode': mode.name,
      });

  @override
  Future<void> setEditorRegistry(EditorRegistry registry) =>
      _call(SettingsLinkMethod.setEditorRegistry, registry.toJson());

  @override
  Future<ExternalEditorDefinition?> pickEditor() async {
    final json = await _call(SettingsLinkMethod.pickEditor);
    return json == null ? null : ExternalEditorDefinition.fromJson(_map(json));
  }

  @override
  Future<List<String>> fetchModels(ModelQuery query) async =>
      ((await _call(SettingsLinkMethod.fetchModels, query.toJson()))! as List)
          .cast<String>();

  @override
  Future<AssistantSaveResult> saveAssistant(AssistantDraft draft) async =>
      AssistantSaveResult.fromJson(
        _map(await _call(SettingsLinkMethod.saveAssistant, draft.toJson())),
      );

  @override
  Future<SyncPrefsResult> setSyncPrefs({
    required bool autoSync,
    required bool syncSecrets,
    required bool syncAssistant,
  }) async => SyncPrefsResult.fromJson(
    _map(
      await _call(SettingsLinkMethod.setSyncPrefs, {
        'autoSync': autoSync,
        'syncSecrets': syncSecrets,
        'syncAssistant': syncAssistant,
      }),
    ),
  );

  @override
  Future<void> enrollSync(SyncEnrollment enrollment) =>
      _call(SettingsLinkMethod.enrollSync, enrollment.toJson());

  @override
  Future<SyncCounts> syncNow() async =>
      SyncCounts.fromJson(_map(await _call(SettingsLinkMethod.syncNow)));

  @override
  Future<InboxAppsView> inboxApps() async =>
      InboxAppsView.fromJson(_map(await _call(SettingsLinkMethod.inboxApps)));

  @override
  Future<String> addInboxApp(InboxAppDraft draft) async =>
      (await _call(SettingsLinkMethod.addInboxApp, draft.toJson()))! as String;

  @override
  Future<void> updateInboxApp(String appId, InboxAppDraft draft) =>
      _call(SettingsLinkMethod.updateInboxApp, {'app': appId, 'draft': draft.toJson()});

  @override
  Future<void> removeInboxApp(String appId) =>
      _call(SettingsLinkMethod.removeInboxApp, appId);

  @override
  Future<bool> recoveryConfigured() async =>
      (await _call(SettingsLinkMethod.recoveryConfigured))! as bool;

  /// The code crosses to this isolate in memory only, to be shown once.
  @override
  Future<String> newRecoveryCode() async =>
      (await _call(SettingsLinkMethod.newRecoveryCode))! as String;

  /// And back, in memory only, once the user confirmed writing it down.
  @override
  Future<void> saveRecoveryCode(String code) =>
      _call(SettingsLinkMethod.saveRecoveryCode, code);

  @override
  Future<String?> exportSecrets() async =>
      await _call(SettingsLinkMethod.exportSecrets) as String?;

  /// The code crosses to the app's isolate in memory only; the file is read
  /// there and never crosses.
  @override
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required RestoreConflictPolicy policy,
  }) async {
    final json = await _call(SettingsLinkMethod.restoreSecrets, {
      'code': code,
      'policy': policy.name,
    });
    return json == null ? null : SecretsRestoreSummary.fromJson(_map(json));
  }

  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }
}
