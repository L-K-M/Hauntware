// CRED-05's app-side RecoverySettings model: the configured flag, the
// file panels and the prompt answer over the job-6 SecretsRecovery
// service. The crypto matrix lives in secrets_recovery_test.dart and
// seance_core's vault_recovery_test.dart.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/recovery_settings.dart';
import 'package:poltergeist_app/services/secrets_recovery.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// The file panels with scripted answers.
final class _FakeFiles implements SecretsExportFiles {
  Uint8List? next;
  Uint8List? savedBytes;
  String? savedName;

  @override
  Future<String?> save(Uint8List bytes, String fileName) async {
    savedBytes = bytes;
    savedName = fileName;
    return '/tmp/$fileName';
  }

  @override
  Future<Uint8List?> open() async => next;
}

final class _FailingStore extends InMemoryVaultStore {
  bool failReads = true;

  @override
  Future<Uint8List?> getSecretBlob(String id) async {
    if (failReads) throw const FormatException('untrusted record');
    return super.getSecretBlob(id);
  }
}

void main() {
  late InMemoryVaultStore store;
  late SecretVault vault;
  late SecretsRecovery recovery;
  late _FakeFiles files;
  late List<bool> declined;

  setUp(() {
    store = InMemoryVaultStore();
    final key = Uint8List(32);
    vault = SecretVault(store, key);
    recovery = SecretsRecovery(store, () async => vault);
    files = _FakeFiles();
    declined = [];
  });

  RecoverySettings model({
    bool promptDeclined = false,
    DateTime Function()? now,
  }) => RecoverySettings(
    recovery: recovery,
    files: files,
    promptDeclined: promptDeclined,
    savePromptDeclined: (value) async => declined.add(value),
    now: now ?? DateTime.now,
  );

  test('loads the configured flag and reloads after each action', () async {
    final settings = model();
    expect(settings.configured, isNull);
    expect(await settings.recoveryConfigured(), isFalse);

    final code = recovery.newCode();
    await settings.saveCode(code);

    expect(await settings.recoveryConfigured(), isTrue);
  });

  test('a failed status read is not a missing recovery code', () async {
    final failing = _FailingStore();
    recovery = SecretsRecovery(
      failing,
      () async => SecretVault(failing, Uint8List(32)),
    );
    final settings = model();
    addTearDown(settings.dispose);

    await expectLater(settings.recoveryConfigured(), throwsA(isA<Exception>()));
    expect(settings.configured, isNull);
    failing.failReads = false;
    expect(await settings.recoveryConfigured(), isFalse);
    expect(settings.configured, isFalse);
  });

  test('export builds the bytes and saves them under the dated name', () async {
    final settings = model(now: () => DateTime(2026, 11, 10));
    await settings.saveCode(recovery.newCode());

    final destination = await settings.exportSecrets();

    expect(destination, '/tmp/poltergeist-secrets-2026-11-10.json');
    expect(files.savedName, 'poltergeist-secrets-2026-11-10.json');
    expect(files.savedBytes, isNotNull);
  });

  test(
    'restore opens the file and merges it; a cancelled panel is null',
    () async {
      // Device A: a secret and a code, exported.
      final aStore = InMemoryVaultStore();
      final aVault = SecretVault(aStore, Uint8List(32));
      final aRecovery = SecretsRecovery(aStore, () async => aVault);
      await aVault.putSecret(
        Secret(id: 'pw-web', kind: SecretKind.password, value: 'value'),
      );
      final code = aRecovery.newCode();
      await aRecovery.saveCode(code);
      final export = await aRecovery.exportSecrets();

      // Device B: the model under test.
      files.next = export;
      final summary = await model().restoreSecrets(
        code: code,
        policy: RestoreConflictPolicy.replaceExisting,
      );
      expect(summary?.added, 1);

      // A cancelled panel reads as no restore.
      files.next = null;
      expect(
        await model().restoreSecrets(
          code: code,
          policy: RestoreConflictPolicy.keepExisting,
        ),
        isNull,
      );
    },
  );

  test('declinePrompt persists, and reverts when the save fails', () async {
    final settings = model();
    await settings.declinePrompt();

    expect(declined, [true]);
    expect(settings.promptDeclined, isTrue);
  });

  test('a failed decline leaves the offer standing', () async {
    final settings = RecoverySettings(
      recovery: recovery,
      files: files,
      promptDeclined: false,
      savePromptDeclined: (_) async => throw StateError('disk full'),
    );

    await expectLater(settings.declinePrompt(), throwsStateError);
    expect(settings.promptDeclined, isFalse);
  });
}
