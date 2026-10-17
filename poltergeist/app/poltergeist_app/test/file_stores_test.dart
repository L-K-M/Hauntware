import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/file_stores.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'poltergeist_file_stores_test_',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  group('FileVaultStore', () {
    test('persists sealed blobs across store instances', () async {
      final file = File('${temporaryDirectory.path}/vault.json');
      final vaultKey = secureRandomBytes(32);

      await SecretVault(FileVaultStore(file), vaultKey).putSecret(
        const Secret(id: 's1', kind: SecretKind.password, value: 'hunter2'),
      );

      // Only opaque ciphertext lands on disk.
      final raw = await file.readAsString();
      expect(raw, isNot(contains('hunter2')));
      expect(raw, contains('"s1"'));

      // A fresh store over the same file opens what the first one sealed.
      final reopened = SecretVault(FileVaultStore(file), vaultKey);
      expect((await reopened.getSecret('s1'))!.value, 'hunter2');
    });

    test('deleting a secret removes it from disk', () async {
      final file = File('${temporaryDirectory.path}/vault.json');
      final vault = SecretVault(FileVaultStore(file), secureRandomBytes(32));
      await vault.putSecret(
        const Secret(id: 's1', kind: SecretKind.password, value: 'x'),
      );
      await vault.deleteSecret('s1');

      expect(await vault.getSecret('s1'), isNull);
      expect(await FileVaultStore(file).getSecretBlob('s1'), isNull);
    });

    test(
      'a corrupt vault file starts empty instead of wedging startup',
      () async {
        final file = File('${temporaryDirectory.path}/vault.json');
        await file.parent.create(recursive: true);
        await file.writeAsString('{not json');

        final store = FileVaultStore(file);
        expect(await store.getSecretBlob('s1'), isNull);

        // The bad file is quarantined aside, not deleted.
        final quarantined = temporaryDirectory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('.corrupt-'))
            .toList();
        expect(quarantined, hasLength(1));
        expect(file.existsSync(), isFalse);
      },
    );
  });
}
