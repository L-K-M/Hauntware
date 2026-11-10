// CRED-05's Settings → Backup → Recovery model: the app-side
// [RecoverySettingsModel] over [SecretsRecovery], for the Settings
// dialogs and the enrolment prompt. The Settings window's side is
// `RemoteRecovery`, over the link.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'secrets_recovery.dart';
import 'settings_models.dart';

/// [RecoverySettingsModel] over the app's [SecretsRecovery]. It carries
/// the configured flag the section and the Settings window render, owns
/// the file panels and the "Not now" answer, and reloads after every
/// action so a change made elsewhere (the window, the prompt) shows.
final class RecoverySettings extends ChangeNotifier
    implements RecoverySettingsModel {
  RecoverySettings({
    required SecretsRecovery recovery,
    required SecretsExportFiles files,
    required bool promptDeclined,
    required Future<void> Function(bool declined) savePromptDeclined,
    DateTime Function() now = DateTime.now,
  }) : // Keep the dependencies private while allowing injection.
       // ignore: prefer_initializing_formals
       _recovery = recovery,
       // ignore: prefer_initializing_formals
       _files = files,
       // ignore: prefer_initializing_formals
       _savePromptDeclined = savePromptDeclined,
       // ignore: prefer_initializing_formals
       _now = now {
    _promptDeclined = promptDeclined;
    unawaited(_reload());
  }

  final SecretsRecovery _recovery;
  final SecretsExportFiles _files;
  final Future<void> Function(bool declined) _savePromptDeclined;
  final DateTime Function() _now;

  bool? _configured;
  bool _promptDeclined = false;

  @override
  bool? get configured => _configured;

  /// Whether the user answered "Not now" to the enrolment offer, so it is
  /// not made again; Settings still offers the code.
  bool get promptDeclined => _promptDeclined;

  /// The configured answer, loading it when the first answer has not
  /// arrived. A vault that cannot be read this session (locked, no
  /// keystore) reads as no code; the next action reports the real fault.
  Future<bool> recoveryConfigured() async {
    final configured = _configured;
    if (configured != null) return configured;
    await _reload();
    return _configured ?? false;
  }

  /// Remembers "Not now" to the enrolment offer. Not remembered on disk
  /// means not remembered in memory either, so a later launch offers it
  /// again; the caller reports the failure.
  Future<void> declinePrompt() async {
    _promptDeclined = true;
    try {
      await _savePromptDeclined(true);
    } on Object {
      _promptDeclined = false;
      rethrow;
    }
    notifyListeners();
  }

  Future<void> _reload() async {
    final bool configured;
    try {
      configured = await _recovery.configured();
    } on Object {
      // The section keeps "Checking…" and the next action reports the
      // real failure; the offer reads this as no code.
      return;
    }
    if (configured == _configured) return;
    _configured = configured;
    notifyListeners();
  }

  @override
  Future<String> newCode() async => _recovery.newCode();

  @override
  Future<void> saveCode(String code) async {
    try {
      await _recovery.saveCode(code);
    } finally {
      await _reload();
    }
  }

  @override
  Future<String?> exportSecrets() async {
    try {
      final bytes = await _recovery.exportSecrets();
      return await _files.save(bytes, secretsExportFileName(_now()));
    } finally {
      await _reload();
    }
  }

  @override
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required RestoreConflictPolicy policy,
  }) async {
    final export = await _files.open();
    if (export == null) return null;
    try {
      return await _recovery.restoreSecrets(export, code, policy: policy);
    } finally {
      await _reload();
    }
  }
}
