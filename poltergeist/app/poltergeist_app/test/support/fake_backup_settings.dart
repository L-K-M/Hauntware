// The smallest [BackupSettingsModel] for tests that mount the Backup
// section for the sake of another section inside it (CRED-05's
// Recovery): no account, so the enrollment form shows, and every
// mutating call unimplemented.
import 'package:flutter/foundation.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final class FakeBackupSettings extends ChangeNotifier
    implements BackupSettingsModel {
  @override
  SyncAccount? get account => null;
  @override
  bool get syncing => false;
  @override
  bool get syncSecrets => false;
  @override
  Set<String> get notices => {};
  @override
  bool get passphraseUnverified => false;
  @override
  List<HostKeyConflict> get pinConflicts => [];
  @override
  Set<String> get trippedIds => {};
  @override
  String? get quarantinedPath => null;
  @override
  DateTime? get lastSyncAt => null;
  @override
  String? get lastSyncError => null;
  @override
  RetainedBackupAccount? get retainedAccount => null;
  @override
  bool get deleteSeparateOffered => false;

  @override
  Future<void> setSyncSecrets(bool enabled) async => throw UnimplementedError();
  @override
  Future<void> registerSeparate({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async => throw UnimplementedError();
  @override
  Future<void> loginAccount({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
    required SyncAccountMode mode,
  }) async => throw UnimplementedError();
  @override
  Future<void> backUpNow() async => throw UnimplementedError();
  @override
  Future<void> signOut() async => throw UnimplementedError();
  @override
  Future<void> deleteSeparateAccount({required String confirmedName}) async =>
      throw UnimplementedError();
  @override
  Future<BackupSwitchOutcome> switchToShared({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) async => throw UnimplementedError();
  @override
  Future<void> resolvePinConflict(
    HostKeyConflict conflict, {
    required bool keepLocal,
  }) async => throw UnimplementedError();
  @override
  Future<void> deleteRetainedSeparateAccount({
    required String confirmedName,
  }) async => throw UnimplementedError();
  @override
  Future<void> declineRetainedDelete() async => throw UnimplementedError();
}
