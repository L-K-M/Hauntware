// Byte goldens for `vault.json` and `vault.json.rekey`, whose writer
// changes hands when FileVaultStore moves out of Poltergeist's app
// (docs/design/catalog-library.md section 8), and the owner-only mode
// both files keep through the move.
//
// `vault.json` holds opaque blobs, so fixed blobs give a fixed document,
// compared byte for byte. The journal seals each generation with a random
// nonce, so it is compared in layers: the document around the two sealed
// generations byte for byte, then each generation's plaintext byte for
// byte after opening it with its key, with the one entry that carries a
// random seal replaced by a marker.
//
// The goldens were captured from the pre-move store running the same
// sequences. Change them only for an intentional format change, from the
// actual documents a failure prints.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// A legacy entry from a hand-written file (rewritten compactly, and kept
/// in place when the batch overwrites it), a put, a merged batch, a delete
/// and a later put. The document is ASCII.
const _vaultGolden =
    '{"legacy":"b3BhcXVlOmxlZ2FjeS0y","beta":"b3BhcXVlOmJldGE=",'
    '"gamma":"b3BhcXVlOmdhbW1h"}';

/// The journal around its two sealed generations, keyed by the SHA-256 of
/// each key: the current key's first, then the new key's.
const _journalGolden =
    '{"version":1,"snapshots":{'
    '"ae216c2ef5247a3782c135efa279a3e4cdc61094270f5d2be58c6204b7a612c9":'
    '"<sealed under the current key>",'
    '"00e988677eecf94c0bb9233371c7c0d6f4db8ebdcdecb7c5ebaa666f17249227":'
    '"<sealed under the new key>"}}';

/// [_orphan] as stored. The current key cannot open it, so the new
/// generation carries it byte for byte.
const _orphanStored =
    'CzBVep/E6Q4zWH2ix+wRNluApcrvFDleg6jN8hc8YYar0PUaP2SJrtP4HUJnjLHW';

const _currentGenerationGolden =
    '{"blobs":{"orphan":"$_orphanStored","live":"<live, as stored>"}}';
const _newGenerationGolden =
    '{"blobs":{"orphan":"$_orphanStored","live":"<live, resealed>"}}';
const _resealedLiveGolden = '{"id":"live","value":"live-secret"}';
const _settledVaultGolden =
    '{"orphan":"$_orphanStored","live":"<live, resealed>"}';

const _ownerReadWrite = 0x180; // 0600
const _permissionBits = 0x1ff;

final _currentKey = List<int>.generate(32, (i) => i + 1);
final _newKey = List<int>.generate(32, (i) => 0xa0 + i);
final _orphan = Uint8List.fromList(
  List<int>.generate(48, (i) => (i * 37 + 11) & 0xff),
);

Uint8List _opaque(String name) =>
    Uint8List.fromList(utf8.encode('opaque:$name'));

int _mode(File file) => file.statSync().mode & _permissionBits;

final _ownerOnlyModesApply = Platform.isLinux || Platform.isMacOS;

void main() {
  late Directory dir;
  late File vault;
  late File journal;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vault-golden');
    vault = File('${dir.path}${Platform.pathSeparator}vault.json');
    journal = File('${vault.path}.rekey');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('vault.json bytes: a legacy entry, puts, a merged batch and a '
      'delete', () async {
    await vault.writeAsString(
      '{"legacy": "${base64.encode(utf8.encode('legacy-blob'))}"}',
    );
    final store = FileVaultStore(vault);

    await store.putSecretBlob('alpha', _opaque('alpha'));
    await store.putSecretBlobs({
      'beta': _opaque('beta'),
      'legacy': _opaque('legacy-2'),
    });
    await store.deleteSecret('alpha');
    await store.putSecretBlob('gamma', _opaque('gamma'));

    // The golden is ASCII, so reading each byte as one code unit keeps a
    // mismatch readable without decoding.
    expect(String.fromCharCodes(await vault.readAsBytes()), _vaultGolden);
  });

  test('vault.json.rekey: both generations, a refused mutation, and the '
      'settled vault', () async {
    final store = FileVaultStore(vault);
    final live = await VaultCrypto.sealJson(_currentKey, {
      'id': 'live',
      'value': 'live-secret',
    });
    await store.putSecretBlobs({'orphan': _orphan, 'live': live});

    await store.stageRekey(currentKey: _currentKey, newKey: _newKey);

    final staged = String.fromCharCodes(await journal.readAsBytes());
    final snapshots = ((jsonDecode(staged) as Map)['snapshots'] as Map)
        .cast<String, String>();
    final sealedCurrent = snapshots.values.first;
    final sealedNew = snapshots.values.last;
    expect(
      staged
          .replaceFirst(sealedCurrent, '<sealed under the current key>')
          .replaceFirst(sealedNew, '<sealed under the new key>'),
      _journalGolden,
    );

    final currentGeneration = utf8.decode(
      await VaultCrypto.open(_currentKey, base64.decode(sealedCurrent)),
    );
    expect(
      currentGeneration.replaceFirst(base64.encode(live), '<live, as stored>'),
      _currentGenerationGolden,
    );

    final newGeneration = utf8.decode(
      await VaultCrypto.open(_newKey, base64.decode(sealedNew)),
    );
    final resealed =
        ((jsonDecode(newGeneration) as Map)['blobs'] as Map)['live'] as String;
    expect(
      newGeneration.replaceFirst(resealed, '<live, resealed>'),
      _newGenerationGolden,
    );
    expect(
      utf8.decode(await VaultCrypto.open(_newKey, base64.decode(resealed))),
      _resealedLiveGolden,
    );

    // The staged journal locks mutations out without touching either file.
    final vaultBefore = await vault.readAsBytes();
    await expectLater(
      store.putSecretBlob('refused', _opaque('refused')),
      throwsStateError,
    );
    expect(await vault.readAsBytes(), vaultBefore);
    expect(String.fromCharCodes(await journal.readAsBytes()), staged);

    expect(await store.settleRekey(_newKey), VaultRekeyOutcome.adopted);
    expect(await journal.exists(), isFalse);
    expect(
      String.fromCharCodes(
        await vault.readAsBytes(),
      ).replaceFirst(resealed, '<live, resealed>'),
      _settledVaultGolden,
    );
  });

  test(
    'vault.json and vault.json.rekey are written owner-only',
    () async {
      final store = FileVaultStore(vault);

      await store.putSecretBlob('a', _opaque('a'));
      expect(_mode(vault), _ownerReadWrite);

      // A lax mode set after the store opened the file: only the writer
      // can restore owner-only here.
      await _chmod('644', vault);
      await store.putSecretBlob('b', _opaque('b'));
      expect(_mode(vault), _ownerReadWrite);

      await store.stageRekey(currentKey: _currentKey, newKey: _newKey);
      expect(_mode(journal), _ownerReadWrite);

      await _chmod('644', vault);
      expect(await store.settleRekey(_newKey), VaultRekeyOutcome.adopted);
      expect(_mode(vault), _ownerReadWrite);

      // No temporary sibling outlives a write.
      expect(dir.listSync().map((entry) => entry.uri.pathSegments.last), [
        'vault.json',
      ]);
    },
    skip: _ownerOnlyModesApply
        ? false
        : 'owner-only mode bits apply on Linux and macOS',
  );

  test(
    'opening a lax vault tightens it to owner-only',
    () async {
      await vault.writeAsString('{}');
      await _chmod('644', vault);

      expect(await FileVaultStore(vault).getSecretBlob('a'), isNull);
      expect(_mode(vault), _ownerReadWrite);
    },
    skip: _ownerOnlyModesApply
        ? false
        : 'owner-only mode bits apply on Linux and macOS',
  );
}

Future<void> _chmod(String mode, File file) async {
  final result = await Process.run('chmod', [mode, file.path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect(_mode(file), int.parse(mode, radix: 8));
}
