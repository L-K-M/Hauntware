// CRED-05's Recovery model with scripted state, recording each call and
// notifying like the app's does. Tests that mount the Settings window's
// Sync tab use it to see what reached the app's isolate.
import 'package:flutter/foundation.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final class FakeRecoverySettings extends ChangeNotifier
    implements RecoverySettingsModel {
  final List<String> calls = [];

  @override
  bool? configured = false;

  String code = 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ23-4567-89AB';
  String? destination;
  SecretsRestoreSummary? summary;
  Object? failure;

  @override
  Future<void> refresh() async {
    calls.add('refreshRecoveryStatus');
    final failure = this.failure;
    if (failure != null) throw failure;
    configured ??= false;
    notifyListeners();
  }

  @override
  Future<String> newCode() async {
    calls.add('newRecoveryCode');
    return code;
  }

  @override
  Future<void> saveCode(String code) async {
    calls.add('saveRecoveryCode');
    configured = true;
    notifyListeners();
  }

  @override
  Future<String?> exportSecrets() async {
    calls.add('exportSecrets');
    final failure = this.failure;
    if (failure != null) throw failure;
    return destination;
  }

  @override
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required RestoreConflictPolicy policy,
  }) async {
    calls.add('restoreSecrets');
    final failure = this.failure;
    if (failure != null) throw failure;
    return summary;
  }
}
