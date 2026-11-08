import 'package:flutter/foundation.dart';
import 'package:ghost_keystore/app_lock.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorLigatures;
import 'package:seance_core/catalog.dart' show HostKeyConflict;
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../theme/app_appearance.dart';
import '../theme/theme_palette.dart';
import '../ui/terminal_appearance.dart';
import 'app_settings.dart';
import 'assistant_settings_sync.dart';
import 'external_file_opener.dart';
import 'secrets_recovery.dart';
import 'settings_backend.dart';

/// Keystore entry name for the Z.AI search key. A constant rather than a typed
/// value: settings hold key *names*, never keys.
const String _zaiKeyRef = 'zai';

class _AssistantKeyWriteFailure implements Exception {
  const _AssistantKeyWriteFailure(this.key, this.error, [this.rollbackError]);

  final AssistantKey key;
  final Object error;
  final Object? rollbackError;

  @override
  String toString() => rollbackError == null
      ? '$error'
      : '$error (restoring the earlier key also failed: $rollbackError)';
}

/// [SettingsBackend] over the app's own [AppState], in the app's isolate.
///
/// The Settings route uses it directly; the settings window's host uses it to
/// answer what the window forwards. It holds no state of its own — listeners
/// are the state's — so it needs no disposal and any number can exist.
class LocalSettingsBackend implements SettingsBackend {
  /// [exportFiles] is where an export is saved and read from: the platform's
  /// panels unless a test supplies its own.
  LocalSettingsBackend(
    this._state, {
    this._exportFiles = const PlatformSecretsExportFiles(),
    LlmProvider Function(ModelQuery query, String apiKey)? modelProviderBuilder,
  }) : _modelProviderBuilder = modelProviderBuilder ?? _buildModelProvider;

  final AppState _state;
  final SecretsExportFiles _exportFiles;
  final LlmProvider Function(ModelQuery query, String apiKey)
      _modelProviderBuilder;

  AppSettings get _s => _state.services.settings;

  @override
  AppSettings get settings => _s;

  @override
  int get llmConfigVersion => _state.llmConfigVersion;

  @override
  SyncStatus get syncStatus => SyncStatus(
    syncing: _state.syncing,
    lastSyncAt: _state.lastSyncAt,
    lastSyncError: _state.lastSyncError,
    pinConflicts: _state.services.pinConflicts,
  );

  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);

  @override
  AppLockAvailability get appLockAvailability =>
      _state.services.appLock.availability;

  @override
  Future<void> setAppLock(AppLockMode mode) => _state.setAppLock(mode);

  /// Turning the update check off also clears any banner already showing
  /// this session.
  @override
  Future<void> setCheckForUpdates(bool enabled) async {
    _s.checkForUpdates = enabled;
    await _state.services.saveSettings();
    if (!enabled) _state.dismissUpdateNotice();
  }

  @override
  LocalShellInfo get localShell =>
      LocalShellInfo.of(_state.services.localShell);

  @override
  String? get appVersion => _state.appVersion;

  /// [AppState.setLocalShellEnabled] writes the setting and closes the local
  /// tabs itself; the keep-alive setter's rollback dance is not needed here
  /// because a failed save reverts inside the same method.
  @override
  Future<void> setLocalShellEnabled(bool enabled) =>
      _state.setLocalShellEnabled(enabled);

  @override
  Future<void> setKeepSessionsAlive(bool enabled) async {
    _s.keepSessionsAliveInBackground = enabled;
    try {
      await _state.services.saveSettings();
      // A newer call may have landed while this save was in flight; its own
      // write owns the apply, and this stale one must not clobber it.
      if (_s.keepSessionsAliveInBackground != enabled) return;
      _state.setKeepSessionsAliveEnabled(enabled);
    } catch (_) {
      // The newer choice is authoritative and stands; only this call's own
      // value is put back.
      if (_s.keepSessionsAliveInBackground != enabled) return;
      _s.keepSessionsAliveInBackground = !enabled;
      rethrow;
    }
  }

  /// Refreshes the suggestion list, which empties when the switch goes off.
  @override
  Future<void> setCommandSuggestions(bool enabled) async {
    _s.commandSuggestions = enabled;
    await _state.services.saveSettings();
    _state.refreshSuggestions();
  }

  @override
  Future<void> setTerminalAppearance({
    required double fontSize,
    required String fontFamily,
    required TerminalPalette palette,
    required TerminalLigatures ligatures,
  }) async {
    if (_s.terminalFontSize == fontSize &&
        _s.terminalPalette == palette &&
        _s.terminalFontFamily == fontFamily &&
        _s.terminalLigatures == ligatures) {
      return;
    }
    _s.terminalFontSize = fontSize;
    _s.terminalPalette = palette;
    _s.terminalFontFamily = fontFamily;
    _s.terminalLigatures = ligatures;
    // Terminals read the settings during build, so they need a nudge.
    _state.terminalAppearanceChanged();
    await _state.services.saveSettings();
  }

  @override
  Future<void> setEditorFontSize(int size) => _state.setEditorFontSize(size);

  @override
  Future<void> setEditorFont({
    required String fontFamily,
    required EditorLigatures ligatures,
  }) => _state.setEditorFont(fontFamily: fontFamily, ligatures: ligatures);

  /// Applied before the write, like the terminal's appearance: the screen
  /// writes through on every change, and the app repainting only after the
  /// disk had caught up would make each edit lag by a save.
  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    if (_s.themePalette == palette && _s.themeMode == mode) return;
    _s.themePalette = palette;
    _s.themeMode = mode;
    _state.appearanceChanged();
    await _state.services.saveSettings();
  }

  /// Stored as a copy: the caller keeps editing its own registry, and those
  /// edits must reach the settings through here, not by aliasing.
  @override
  Future<void> setEditorRegistry(EditorRegistry registry) async {
    _s.editorRegistry = EditorRegistry.fromJson(registry.toJson());
    await _state.services.saveSettings();
  }

  @override
  Future<ExternalEditorDefinition?> pickEditor() =>
      const ExternalFileOpener().pickEditor();

  /// Keyless local endpoints (Ollama) need no key. The manual model field
  /// remains the fallback if this fails or the list omits the model wanted.
  @override
  Future<List<String>> fetchModels(ModelQuery query) async {
    final ref = query.kind == LlmProviderKind.anthropic
        ? 'anthropic'
        : 'openai';
    final key = query.typedApiKey.isNotEmpty
        ? query.typedApiKey
        : (await _state.services.masterKeys.getApiKey(ref) ?? '');
    final provider = _modelProviderBuilder(query, key);
    try {
      final models = await provider.listModels();
      models.sort();
      return models;
    } finally {
      closeLlmProvider(provider);
    }
  }

  AssistantSaveResult _result(
    AssistantSaveStatus status, {
    AssistantKey? failedKey,
    String? error,
  }) => AssistantSaveResult(
    status: status,
    current: AssistantFields.of(_s),
    version: _state.llmConfigVersion,
    failedKey: failedKey,
    error: error,
  );

  /// Save the assistant half of the settings from [draft].
  ///
  /// Throws only for a failure after the keystore writes (the settings write
  /// itself); everything the screen has to tell apart comes back as a
  /// [AssistantSaveResult].
  @override
  Future<AssistantSaveResult> saveAssistant(AssistantDraft draft) async {
    final state = _state;
    // The screen reloads its fields after an adoption it causes, but a
    // periodic round adopts too, and the screen may be open while it does.
    // Saving the fields it loaded earlier would write the pre-adoption values
    // back over the adopted ones — and stamp them, so the revert would win on
    // every device. Refused before anything is written: the adopted values
    // are loaded instead, and the user saves again from what is actually
    // configured. Typed keys are left in their fields; only the assistant
    // half is reloaded.
    if (state.llmConfigVersion != draft.versionSeen) {
      return _result(AssistantSaveStatus.adoptedBeforeSave);
    }
    // For the re-check below: the guard above sees an adoption that landed
    // before this Save, not one that lands during its awaits.
    final versionAtEntry = state.llmConfigVersion;
    final s = _s;
    final settingsAtEntry = assistantSyncFingerprint(s);
    final stampAtEntry = s.assistantUpdatedAt;
    final fields = draft.fields;
    // Store the API key under a per-provider name, taken from the draft once:
    // a provider read again after the keystore writes could disagree with
    // the one the key was stored under, and `openaiCompatible` holding
    // `'anthropic'` authenticates against nothing.
    final kind = fields.kind;
    final ref = kind == LlmProviderKind.anthropic ? 'anthropic' : 'openai';
    final zaiEnabled = fields.zaiEnabled;
    final enteredZaiKey = draft.zaiApiKey.trim();
    final enteredLlmKey = draft.llmApiKey.trim();

    // Keys and the fields that reference them form one synced value. Keep the
    // keychain writes inside the mutation phase too, so collection observes
    // either the old value or the complete edit. If a later key fails, restore
    // the earlier writes before releasing the queue.
    final keyWrites = <({String name, String value, AssistantKey key})>[
      if (zaiEnabled && enteredZaiKey.isNotEmpty)
        (name: _zaiKeyRef, value: enteredZaiKey, key: AssistantKey.zai),
      if (enteredLlmKey.isNotEmpty)
        (name: ref, value: enteredLlmKey, key: AssistantKey.llm),
    ];
    var zaiWithoutKey = false;
    final searxng = fields.searxngUrl.trim();
    late ({bool stale, String? publishError}) committed;
    try {
      committed = await state.commitAssistantSettings(
        expectedVersion: versionAtEntry,
        expectedUpdatedAt: stampAtEntry,
        expectedFingerprint: settingsAtEntry,
        keyEntered: draft.keyEntered,
        prepare: () async {
          final previous = <String, String?>{};
          for (final write in keyWrites) {
            try {
              previous[write.name] = await state.services.masterKeys
                  .readApiKeyForUpdate(write.name);
            } catch (error) {
              throw _AssistantKeyWriteFailure(write.key, error);
            }
          }
          Future<void> restore(
            Iterable<({String name, String value, AssistantKey key})> writes,
          ) async {
            Object? firstError;
            for (final write in writes) {
              try {
                final old = previous[write.name];
                if (old == null) {
                  await state.services.masterKeys.deleteApiKey(write.name);
                } else {
                  await state.services.masterKeys.putApiKey(write.name, old);
                }
              } catch (error) {
                firstError ??= error;
              }
            }
            if (firstError != null) throw firstError;
          }

          final completed = <({String name, String value, AssistantKey key})>[];
          for (final write in keyWrites) {
            try {
              await state.services.masterKeys.putApiKey(
                write.name,
                write.value,
              );
              completed.add(write);
            } catch (error) {
              Object? rollbackError;
              try {
                await restore(completed.reversed);
              } catch (error) {
                rollbackError = error;
              }
              throw _AssistantKeyWriteFailure(write.key, error, rollbackError);
            }
          }
          zaiWithoutKey =
              zaiEnabled &&
              (await state.services.masterKeys.getApiKey(_zaiKeyRef)) == null;
          return () => restore(keyWrites.reversed);
        },
        update: (settings) {
          settings.llmKind = kind;
          settings.llmBaseUrl = fields.baseUrl.trim();
          settings.llmModel = fields.model.trim();
          settings.llmApiKeyRef = ref;
          settings.redactionEnabled = fields.redactionEnabled;
          settings.searxngUrl = searxng.isEmpty ? null : searxng;
          // The reference is what switches the backend on; turning it off
          // leaves the key in the keystore rather than deleting it, like every
          // other key here.
          settings.zaiApiKeyRef = zaiEnabled ? _zaiKeyRef : null;
        },
      );
    } on _AssistantKeyWriteFailure catch (failure) {
      return _result(
        AssistantSaveStatus.keystoreFailed,
        failedKey: failure.key,
        error: '$failure',
      );
    }
    if (committed.stale) {
      return _result(AssistantSaveStatus.adoptedBeforeSave);
    }
    final publishError = committed.publishError;
    // Rebuild the chat provider (new key/model) and refresh sidebar
    // visibility.
    //
    // Caught rather than thrown: everything above is past the point of no
    // return — the keystores, `settings.json` and the published record are
    // all written — so throwing would report "Settings not saved" for a save
    // that succeeded and tell the user to re-enter secrets that are on disk.
    // `reloadLlmProvider` does `llmConfigVersion++` as its first statement,
    // before any await, so the one bump counted below has landed even when a
    // later step throws.
    String? reloadError;
    try {
      await state.reloadLlmProvider();
    } catch (e) {
      reloadError = '$e';
    }
    // This Save is the configuration now in effect — unless a periodic round
    // adopted another device's configuration during the awaits above. The
    // reload just made is this Save's own bump, and the only one it makes:
    // `assistantSettingsEdited` does not touch the counter. Anything else is
    // an adoption, and blessing this version would let the next Save revert
    // it silently, with a fresh stamp.
    const bumpsThisSaveMakes = 1; // reloadLlmProvider
    return AssistantSaveResult(
      status: AssistantSaveStatus.saved,
      current: AssistantFields.of(s),
      version: state.llmConfigVersion,
      keysStored: draft.keyEntered,
      publishError: publishError,
      reloadError: reloadError,
      adoptedMeanwhile:
          state.llmConfigVersion != versionAtEntry + bumpsThisSaveMakes,
      zaiWithoutKey: zaiWithoutKey,
    );
  }

  /// Persist the sync switches and (re)start the auto-sync timer.
  @override
  Future<SyncPrefsResult> setSyncPrefs({
    required bool autoSync,
    required bool syncSecrets,
    required bool syncAssistant,
  }) async {
    final state = _state;
    final s = _s;
    SyncPrefsResult result({
      String? saveError,
      String? assistantSyncError,
      bool adopted = false,
    }) => SyncPrefsResult(
      autoSync: s.autoSync,
      syncSecrets: s.syncSecrets,
      syncAssistant: s.syncAssistant,
      current: AssistantFields.of(s),
      version: state.llmConfigVersion,
      saveError: saveError,
      assistantSyncError: assistantSyncError,
      adopted: adopted,
    );

    final saved = await state.saveSyncPreferences(
      autoSync: autoSync,
      syncSecrets: syncSecrets,
      syncAssistant: syncAssistant,
    );
    if (saved.saveError != null) return result(saveError: saved.saveError);
    final wasSyncingAssistant = saved.wasSyncingAssistant;
    state.ensureAutoSyncTimer();
    // Switching it on adopts what the account already has, and publishes what
    // this device has only when there was nothing to adopt.
    if (!syncAssistant || wasSyncingAssistant) return result();
    // Taken immediately before the round: only this round's own bump means
    // "adopted". A periodic round that adopted earlier also moved the counter,
    // and on the publish path — where this round itself bumps nothing — a
    // stale baseline would read as an adoption and have the screen reload
    // the fields, discarding whatever the user had typed into them.
    final versionBeforeRound = state.llmConfigVersion;
    try {
      await state.assistantSyncSwitchedOn();
    } catch (e) {
      // Rolled back for the same reason the failed write above is: both mean
      // the adopt-first step did not run, and leaving the switch on lets the
      // next Save stamp `now` and publish this device's configuration over
      // the account's newer record — the clobber adopting first exists to
      // prevent. Turning it on again retries.
      try {
        await state.disableAssistantSync();
      } catch (_) {
        // The original failure is the one worth telling; the in-memory flag
        // was already switched off before the failed durable write.
      }
      return result(assistantSyncError: '$e');
    }
    // Adoption rewrites the assistant half of `settings`. Reported only when
    // it actually ran: the switch publishes when the account holds nothing,
    // which rewrites nothing here, and reloading then would overwrite what
    // the user had typed but not yet saved. `_runSyncAndRefresh` reloads the
    // provider, and so bumps the counter, only when the round adopted.
    return result(adopted: state.llmConfigVersion != versionBeforeRound);
  }

  @override
  Future<void> enrollSync(SyncEnrollment enrollment) async {
    if (enrollment.mode == SyncEnrollmentMode.register) {
      await _state.registerSync(
        baseUrl: enrollment.baseUrl,
        username: enrollment.username,
        password: enrollment.password,
        encryptionPassphrase: enrollment.encryptionPassphrase,
      );
    } else {
      await _state.loginSync(
        baseUrl: enrollment.baseUrl,
        username: enrollment.username,
        password: enrollment.password,
        encryptionPassphrase: enrollment.encryptionPassphrase,
      );
    }
    // Schedule periodic sync if enabled; the caller verifies enrollment with
    // one immediate round.
    _state.ensureAutoSyncTimer();
  }

  @override
  Future<SyncCounts> syncNow() async {
    final outcome = await _state.syncNow();
    return SyncCounts(pulled: outcome.pulled, pushed: outcome.pushed);
  }

  @override
  Future<PulledPinResolution> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) => _state.resolvePinConflict(conflict, keepLocal: keepLocal);

  @override
  Future<InboxAppsView> inboxApps() async => InboxAppsView(
    syncConfigured: _state.services.isSyncConfigured,
    apps: [
      for (final app in _state.inboxApps)
        InboxAppSummary(
          id: app.id,
          name: app.name,
          allowedServerIds: app.allowedServerIds,
          refused: _state.inboxFailures[app.id] ?? 0,
        ),
    ],
    servers: [
      for (final server in _state.servers)
        InboxServerChoice(id: server.id, label: server.label),
    ],
  );

  @override
  Future<String> addInboxApp(InboxAppDraft draft) => _state.addInboxApp(
    name: draft.name,
    allowedServerIds: draft.allowedServerIds,
  );

  @override
  Future<void> updateInboxApp(String appId, InboxAppDraft draft) =>
      _state.updateInboxApp(
        appId,
        name: draft.name,
        allowedServerIds: draft.allowedServerIds,
      );

  @override
  Future<void> removeInboxApp(String appId) => _state.removeInboxApp(appId);

  @override
  Future<bool> recoveryConfigured() => _state.recoveryConfigured();

  @override
  Future<String> newRecoveryCode() async => _state.newRecoveryCode();

  @override
  Future<void> saveRecoveryCode(String code) => _state.saveRecoveryCode(code);

  @override
  Future<String?> exportSecrets() async {
    final Uint8List export;
    try {
      export = await _state.exportSecrets();
    } on SecretsExportException {
      // The only failure building an export has: a vault past the caps.
      throw const SettingsBackendException(secretsExportTooLargeMessage);
    }
    return _exportFiles.save(export, secretsExportFileName(DateTime.now()));
  }

  /// A file that is not an export, a wrong code or an altered file throws
  /// the sentence the screen shows, so both backends print the same thing.
  @override
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required RestoreConflictPolicy policy,
  }) async {
    try {
      final export = await _exportFiles.open();
      if (export == null) return null;
      return await _state.restoreSecrets(export, code, policy: policy);
    } on SecretsExportException catch (error) {
      throw SettingsBackendException(
        secretsExportFailureMessage(error.failure),
      );
    }
  }
}

LlmProvider _buildModelProvider(ModelQuery query, String apiKey) {
  final baseUrl = query.baseUrl.trim();
  final model = query.model.trim();
  return query.kind == LlmProviderKind.anthropic
      ? AnthropicProvider(apiKey: apiKey, baseUrl: baseUrl, model: model)
      : OpenAiCompatibleProvider(
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
        );
}
