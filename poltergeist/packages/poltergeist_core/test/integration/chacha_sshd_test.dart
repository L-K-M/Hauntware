@Tags(['integration'])
@Timeout(Duration(minutes: 2))
library;

// The sshd-chacha audit fixture (port 2212) offers one cipher,
// chacha20-poly1305@openssh.com, and ML-KEM or curve25519 key exchange.
// dartssh2 3.0.2 had no chacha20-poly1305, so the M0 audit recorded this
// server as a failed connection (docs/M0-DARTSSH2-REPORT.md,
// algorithm-chacha-curve-pq). dartssh2 3.2.0 added the cipher to its
// defaults, so from 4.1.0 on Poltergeist's production connect path must
// reach this server. The key exchange is curve25519-sha256: dartssh2
// still has no mlkem768x25519-sha256, so an ML-KEM-only server remains
// out of reach.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

const _hostVariable = 'POLTERGEIST_SSHD';
const _chachaPortVariable = 'POLTERGEIST_SSHD_CHACHA';
const _userVariable = 'POLTERGEIST_SSHD_USER';
const _keyVariable = 'POLTERGEIST_SSHD_KEY';
const _remoteRootVariable = 'POLTERGEIST_SSHD_REMOTE_ROOT';
const _serverId = 'fixture-chacha';
const _chachaCipher = 'chacha20-poly1305@openssh.com';

void main() {
  final environment = Platform.environment;
  final enabled = [
    _hostVariable,
    _chachaPortVariable,
    _userVariable,
    _keyVariable,
    _remoteRootVariable,
  ].every(environment.containsKey);

  test(
    'a chacha20-poly1305-only sshd connects and serves SFTP',
    () async {
      String requiredVariable(String name) =>
          environment[name] ??
          (throw StateError('The enabled fixture requires $name.'));
      final host = requiredVariable(_hostVariable);
      if (host != InternetAddress.loopbackIPv4.address) {
        throw StateError('The Docker fixture must use IPv4 loopback.');
      }
      final port = int.parse(requiredVariable(_chachaPortVariable));
      final privateKey = await File(
        requiredVariable(_keyVariable),
      ).readAsString();
      final remoteRoot = requiredVariable(_remoteRootVariable);

      final package = await Isolate.resolvePackageUri(
        Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
      );
      if (package == null) {
        throw StateError('Core package is unresolved.');
      }
      Future<String> fixtureFile(String path) => File.fromUri(
        package.resolve('../../../test/integration/$path'),
      ).readAsString();

      // A connection only proves chacha20-poly1305 support while the
      // server offers nothing else; widening the fixture must fail here.
      final cipherLines = const LineSplitter()
          .convert(await fixtureFile('sshd-common/config/sshd_config.chacha'))
          .where((line) => line.startsWith('Ciphers '));
      expect(cipherLines, ['Ciphers $_chachaCipher']);

      final publicKey = (await fixtureFile(
        'keys/ssh_host_ed25519_key.pub',
      )).trim().split(RegExp(r'\s+'));
      final store = InMemoryHostKeyStore();
      await store.put(
        HostKey.fromPublicKey(
          host: host,
          port: port,
          type: publicKey[0],
          publicKeyBase64: publicKey[1],
          pinnedAt: 0,
        ),
      );

      final server = ServerConfig(
        id: _serverId,
        label: _serverId,
        host: host,
        port: port,
        username: requiredVariable(_userVariable),
        authMethod: AuthMethod.privateKey,
        createdAt: 0,
        updatedAt: 0,
      );
      final manager = PooledConnectionManager(
        resolveServer: (_) async => server,
        resolveCredentials: (_, _) async => ResolvedCredentials(
          credentials: SshCredentials.privateKey(privateKey),
          origin: CredentialOrigin.stored,
        ),
        tofu: TofuVerifier(store),
        onHostKey: (_) async => fail('A pre-seeded fixture must never prompt.'),
        onKeyboardInteractive: (_) async =>
            fail('Stored credentials must not prompt.'),
      );
      addTearDown(() => manager.disconnectServer(_serverId));

      final browse = await manager.openBrowseChannel(
        _serverId,
        paneTabId: 'chacha',
      );
      addTearDown(browse.close);

      // Read real bytes back so both directions of the encrypted
      // channel carry SFTP traffic, not just the authentication.
      final collected = BytesBuilder(copy: false);
      final sink = StreamController<List<int>>();
      final subscription = sink.stream.listen(collected.add);
      await browse.fs.download(
        '$remoteRoot/fixtures/readdir-00/readdir-00-entry-000.txt',
        sink,
      );
      await sink.close();
      await subscription.cancel();
      expect(
        utf8.decode(collected.toBytes()),
        'readdir-00/readdir-00-entry-000.txt\n',
      );
    },
    skip: enabled
        ? false
        : 'Set $_hostVariable, $_chachaPortVariable, $_userVariable, '
              '$_keyVariable, and $_remoteRootVariable to enable.',
  );
}
