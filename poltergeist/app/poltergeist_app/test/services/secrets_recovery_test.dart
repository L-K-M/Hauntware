// CRED-05 service coverage: the export file name, the failure copy, the
// vault-level operations over an in-memory store, and the picked-file read
// budget. The wire format's crypto matrix lives in
// seance_core/test/vault/vault_recovery_test.dart.
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:file_picker/file_picker.dart';
// The plugin's static API delegates here; swapping it keeps real open logic.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/secrets_recovery.dart';
import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

Secret _secret(String id, [String? value]) =>
    Secret(id: id, kind: SecretKind.password, value: value ?? 'value-$id');

/// One device's vault: its store, its key, and the recovery service bound to
/// the same key-resolving seam the app's provider uses.
final class _Device {
  _Device(this.store, List<int>? key) : key = key ?? Uint8List(32) {
    vault = SecretVault(store, this.key);
    recovery = SecretsRecovery(store, () async => key == null ? null : vault);
  }

  final InMemoryVaultStore store;
  final List<int> key;
  late final SecretVault vault;
  late final SecretsRecovery recovery;
}

class _ExportPicker extends FilePickerPlatform {
  FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => result;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  group('export file name', () {
    test('is product-prefixed and dated', () {
      expect(
        secretsExportFileName(DateTime(2026, 11, 10)),
        'poltergeist-secrets-2026-11-10.json',
      );
      expect(
        secretsExportFileName(DateTime(2026, 1, 2)),
        'poltergeist-secrets-2026-01-02.json',
      );
    });
  });

  group('failure copy', () {
    test('maps every export failure to its sentence', () {
      expect(
        secretsExportFailureMessage(SecretsExportFailure.malformed, l10n),
        l10n.secretsExportMalformed,
      );
      expect(
        secretsExportFailureMessage(
          SecretsExportFailure.unsupportedVersion,
          l10n,
        ),
        l10n.secretsExportUnsupportedVersion,
      );
      expect(
        secretsExportFailureMessage(SecretsExportFailure.tooLarge, l10n),
        l10n.secretsExportFileTooLarge,
      );
      expect(
        secretsExportFailureMessage(SecretsExportFailure.invalidCode, l10n),
        l10n.secretsExportInvalidCode,
      );
      expect(
        secretsExportFailureMessage(SecretsExportFailure.wrongCode, l10n),
        l10n.secretsExportWrongCode,
      );
      expect(
        secretsExportFailureMessage(SecretsExportFailure.tampered, l10n),
        l10n.secretsExportTampered,
      );
    });
  });

  group('VaultRecovery binding', () {
    test('an export opens on another device with another key', () async {
      final a = _Device(InMemoryVaultStore(), Uint8List(32));
      await a.vault.putSecrets([_secret('pw-web'), _secret('pw-db')]);
      final code = a.recovery.newCode();
      await a.recovery.saveCode(code);
      final export = await a.recovery.exportSecrets();

      final b = _Device(
        InMemoryVaultStore(),
        Uint8List.fromList(List.filled(32, 9)),
      );
      final summary = await b.recovery.restoreSecrets(
        export,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );

      expect(summary.added, 2);
      expect((await b.vault.getSecret('pw-web'))!.value, 'value-pw-web');
      expect((await b.vault.getSecret('pw-db'))!.value, 'value-pw-db');
      // Restoring brings credentials, not the other device's recovery.
      expect(await b.recovery.configured(), isFalse);
    });

    test('a credential already here is kept or replaced as asked', () async {
      final a = _Device(InMemoryVaultStore(), Uint8List(32));
      await a.vault.putSecrets([_secret('pw-web')]);
      final code = a.recovery.newCode();
      await a.recovery.saveCode(code);
      final export = await a.recovery.exportSecrets();

      final b = _Device(
        InMemoryVaultStore(),
        Uint8List.fromList(List.filled(32, 9)),
      );
      await b.vault.putSecrets([_secret('pw-web', 'mine')]);

      final kept = await b.recovery.restoreSecrets(
        export,
        code,
        policy: RestoreConflictPolicy.keepExisting,
      );
      expect((kept.added, kept.kept, kept.replaced), (0, 1, 0));
      expect((await b.vault.getSecret('pw-web'))!.value, 'mine');

      final replaced = await b.recovery.restoreSecrets(
        export,
        code,
        policy: RestoreConflictPolicy.replaceExisting,
      );
      expect((replaced.added, replaced.kept, replaced.replaced), (0, 0, 1));
      expect((await b.vault.getSecret('pw-web'))!.value, 'value-pw-web');
    });

    test('a wrong code or an altered file writes nothing', () async {
      final a = _Device(InMemoryVaultStore(), Uint8List(32));
      await a.vault.putSecrets([_secret('pw-web')]);
      final code = a.recovery.newCode();
      await a.recovery.saveCode(code);
      final export = await a.recovery.exportSecrets();

      final b = _Device(
        InMemoryVaultStore(),
        Uint8List.fromList(List.filled(32, 9)),
      );
      await b.vault.putSecrets([_secret('mine')]);
      final before = await b.store.allSecretBlobs();

      await expectLater(
        b.recovery.restoreSecrets(
          export,
          RecoveryKey.encode(Uint8List(32)),
          policy: RestoreConflictPolicy.replaceExisting,
        ),
        throwsA(
          isA<SecretsExportException>().having(
            (error) => error.failure,
            'failure',
            SecretsExportFailure.wrongCode,
          ),
        ),
      );
      final altered = Uint8List.fromList(export)..[export.length ~/ 2] ^= 0x01;
      await expectLater(
        b.recovery.restoreSecrets(
          altered,
          code,
          policy: RestoreConflictPolicy.replaceExisting,
        ),
        throwsA(isA<SecretsExportException>()),
      );
      expect(await b.store.allSecretBlobs(), before);
    });

    test('export needs a code, and a locked vault does nothing', () async {
      final a = _Device(InMemoryVaultStore(), Uint8List(32));
      await expectLater(
        a.recovery.exportSecrets(),
        throwsA(isA<RecoveryNotSetUpException>()),
      );

      final locked = _Device(InMemoryVaultStore(), null);
      await expectLater(
        locked.recovery.saveCode(locked.recovery.newCode()),
        throwsA(isA<VaultLockedException>()),
      );
      await expectLater(
        locked.recovery.exportSecrets(),
        throwsA(isA<VaultLockedException>()),
      );
      await expectLater(
        locked.recovery.restoreSecrets(
          Uint8List(0),
          'code',
          policy: RestoreConflictPolicy.keepExisting,
        ),
        throwsA(isA<VaultLockedException>()),
      );
      // Whether a code exists needs no key.
      expect(await locked.recovery.configured(), isFalse);
    });

    test('configured reports an entry without a key', () async {
      final a = _Device(InMemoryVaultStore(), Uint8List(32));
      await a.recovery.saveCode(a.recovery.newCode());
      final locked = SecretsRecovery(a.store, () async => null);
      expect(await locked.configured(), isTrue);
    });
  });

  group('picked export size limit', () {
    late FilePickerPlatform previousPicker;
    late _ExportPicker picker;

    setUp(() {
      previousPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker = _ExportPicker();
    });

    tearDown(() => FilePickerPlatform.instance = previousPicker);

    Matcher oversized() => throwsA(
      isA<SecretsExportException>().having(
        (error) => error.failure,
        'failure',
        SecretsExportFailure.tooLarge,
      ),
    );

    test('rejects oversized metadata without loading the contents', () async {
      var read = false;
      Stream<List<int>> source() async* {
        read = true;
        yield const [1];
      }

      picker.result = FilePickerResult([
        PlatformFile(
          name: 'too-large.json',
          size: SecretsExport.maxBytes + 1,
          readStream: source(),
        ),
      ]);

      await expectLater(PlatformSecretsExportFiles().open(), oversized());
      expect(read, isFalse);
    });

    test('reads a pathless provider through its stream', () async {
      const contents = [123, 125]; // {} without a filesystem path.
      picker.result = FilePickerResult([
        PlatformFile(
          name: 'export.json',
          size: contents.length,
          readStream: Stream.value(contents),
        ),
      ]);

      expect(await PlatformSecretsExportFiles().open(), contents);
    });

    test('bounds unknown or stale sizes and cancels the stream', () async {
      var cancelled = false;
      Stream<List<int>> source() async* {
        try {
          yield Uint8List(SecretsExport.maxBytes);
          yield const [1];
          fail('read beyond the export limit');
        } finally {
          cancelled = true;
        }
      }

      picker.result = FilePickerResult([
        PlatformFile(name: 'export.json', size: 0, readStream: source()),
      ]);

      await expectLater(PlatformSecretsExportFiles().open(), oversized());
      expect(cancelled, isTrue);
    });
  });
}
