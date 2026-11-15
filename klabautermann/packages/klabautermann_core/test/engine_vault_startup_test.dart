// The engine's settle of a vault re-key an earlier process left (03 §4.5):
// a crash between a re-key's keystore write and its settle leaves
// `vault.json.rekey` behind, and the engine settles it against the key
// the app's keystore holds before its first use of that key after launch,
// as Séance and Poltergeist settle at startup.
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/engine/engine_isolate.dart';
import 'package:seance_core/catalog.dart' show FileVaultStore;
import 'package:seance_core/seance_core.dart'
    show Secret, SecretKind, SecretVault;
import 'package:test/test.dart';

const _deviceId = '6f1c2f0e-3c5e-4d7a-9b1e-0a2b3c4d5e6f';

void main() {
  late Directory support;

  setUp(() => support = Directory.systemTemp.createTempSync('klab-rekey-'));
  tearDown(() => support.deleteSync(recursive: true));

  test('the first key read after launch settles a re-key an earlier '
      'process left', () async {
    final oldKey = List<int>.filled(32, 1);
    final newKey = List<int>.filled(32, 2);
    final file = File('${support.path}${Platform.pathSeparator}vault.json');
    final store = FileVaultStore(file);
    await SecretVault(store, oldKey).putLocalSecret(
      const Secret(id: 'secret-a', kind: SecretKind.password, value: 'x'),
      updatedAt: 1,
    );
    (await store.stageRekey(currentKey: oldKey, newKey: newKey)).release();
    final journal = File('${file.path}.rekey');
    expect(journal.existsSync(), isTrue);

    final client = await IsolateEngineClient.spawn(
      supportDirectory: support.path,
      supportDirectoryAccess: SupportDirectoryAccess.exclusive,
      deviceId: _deviceId,
      entryPoint: engineMain,
    );
    addTearDown(client.shutdown);
    // The app's keystore binding, which holds the new key: the crash came
    // after the re-key's keystore write.
    final answers = client.events.listen((event) {
      if (event case KeystoreRequest(
        :final requestId,
        operation: KeystoreReadMasterKey(),
      )) {
        client.send(
          AnswerKeystore(
            requestId,
            KeystoreMasterKey(Uint8List.fromList(newKey)),
          ),
        );
      }
    });
    addTearDown(answers.cancel);

    // Any request that reads the master key; recovery's status needs no
    // sync account.
    final status = client.events
        .firstWhere((event) => event is RecoveryStatus)
        .timeout(const Duration(seconds: 10));
    client.send(const RecoveryStatusRequest(requestId: 'status'));
    await status;

    expect(journal.existsSync(), isFalse, reason: 'the journal was settled');
    final reopened = FileVaultStore(file);
    expect(
      (await SecretVault(reopened, newKey).getSecret('secret-a'))?.value,
      'x',
    );
  });
}
