import 'dart:io';

import 'package:test/test.dart';

/// Writes a new ed25519 key encrypted with [passphrase] to [path] with
/// OpenSSH's own ssh-keygen, so the suites commit no key material. One KDF
/// round keeps opening it quick.
Future<void> writeEncryptedKey(String path, String passphrase) async {
  await File(path).parent.create(recursive: true);
  final result = await Process.run('ssh-keygen', [
    '-q',
    '-t',
    'ed25519',
    '-a',
    '1',
    '-N',
    passphrase,
    '-C',
    'klabautermann_core test key',
    '-f',
    path,
  ]);
  if (result.exitCode != 0) fail('ssh-keygen failed: ${result.stderr}');
}
