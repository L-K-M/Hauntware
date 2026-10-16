// Byte golden for `host_keys.json`, whose writer changes hands when
// FileHostKeyStore moves out of Poltergeist's app
// (docs/design/catalog-library.md section 8): fixed pins go through the
// store's default writer and the file is compared byte for byte.
//
// The golden was captured from the pre-move store running the same
// sequence. Change it only for an intentional format change, from the
// actual document a failure prints.
import 'dart:convert';
import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// A legacy row missing `port` and `pinnedAt` (rewritten with their
/// defaults), a pin with a public key, a replaced pin that keeps its
/// position, and a conditional install; the refused conflicting install
/// leaves no trace. The document is ASCII.
const _hostKeysGolden =
    r'[{"host":"legacy.example.com","port":22,"type":"ssh-rsa",'
    r'"fingerprintSha256":"SHA256:legacyFingerprint","pinnedAt":0},'
    r'{"host":"alpha.example.com","port":22,"type":"ssh-ed25519",'
    r'"fingerprintSha256":"SHA256:alphaFingerprint",'
    r'"publicKeyBase64":"AAAAC3NzaC1lZDI1NTE5AAAAIGFscGhh",'
    r'"pinnedAt":1791892800000},{"host":"beta.example.com","port":2222,'
    r'"type":"ssh-ed25519","fingerprintSha256":"SHA256:betaRekeyed",'
    r'"pinnedAt":1791892804000},{"host":"fd00::7","port":22,'
    r'"type":"ssh-ed25519","fingerprintSha256":"SHA256:gammaFingerprint",'
    r'"pinnedAt":1791892802000}]';

const _beta = HostKey(
  host: 'beta.example.com',
  port: 2222,
  type: 'ecdsa-sha2-nistp256',
  fingerprintSha256: 'SHA256:betaFingerprint',
  pinnedAt: 1791892801000,
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('host-keys-golden');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('host_keys.json bytes: legacy row, pins, a replacement and a '
      'refused conflict', () async {
    final path = '${dir.path}${Platform.pathSeparator}host_keys.json';
    await File(path).writeAsString(
      jsonEncode([
        {
          'host': 'legacy.example.com',
          'type': 'ssh-rsa',
          'fingerprintSha256': 'SHA256:legacyFingerprint',
        },
      ]),
    );
    final store = FileHostKeyStore(File(path));

    await store.put(
      const HostKey(
        host: 'alpha.example.com',
        type: 'ssh-ed25519',
        fingerprintSha256: 'SHA256:alphaFingerprint',
        publicKeyBase64: 'AAAAC3NzaC1lZDI1NTE5AAAAIGFscGhh',
        pinnedAt: 1791892800000,
      ),
    );
    await store.put(_beta);
    expect(
      await store.putIfNoConflict(
        const HostKey(
          host: 'fd00::7',
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:gammaFingerprint',
          pinnedAt: 1791892802000,
        ),
      ),
      HostKeyInstallResult.installed,
    );
    expect(
      await store.putIfNoConflict(
        const HostKey(
          host: 'alpha.example.com',
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:alphaImpostor',
          pinnedAt: 1791892803000,
        ),
      ),
      HostKeyInstallResult.conflict,
    );
    expect(
      await store.replaceIfCurrent(
        _beta,
        const HostKey(
          host: 'beta.example.com',
          port: 2222,
          type: 'ssh-ed25519',
          fingerprintSha256: 'SHA256:betaRekeyed',
          pinnedAt: 1791892804000,
        ),
      ),
      HostKeyInstallResult.installed,
    );

    // The golden is ASCII, so reading each byte as one code unit keeps a
    // mismatch readable without decoding.
    final actual = await File(path).readAsBytes();
    expect(String.fromCharCodes(actual), _hostKeysGolden);
  });
}
