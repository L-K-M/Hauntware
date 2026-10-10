import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:poltergeist_core/poltergeist_core.dart';
// The classifier is connection-module internal (not barrel-exported) — the
// test reaches it directly, like the module's own consumers do.
// ignore: implementation_imports
import 'package:poltergeist_core/src/connection/ssh_transport.dart';
// The proposal the preflight has to match, read by wire name only: dartssh2
// itself stays inside lib/src/connection, tests included.
// ignore: implementation_imports
import 'package:seance_core/src/ssh/ssh_algorithms.dart';
import 'package:test/test.dart';

const _lineFeed = 0x0a;
const _sshMsgKexInit = 20;
const _cookieBytes = 16;

/// The first six name-lists of the client's KEXINIT (RFC 4253 §7.1): key
/// exchange, host key, then cipher and MAC for each direction. Null until
/// the identification line and the whole unencrypted packet have arrived.
List<List<String>>? _clientKexInitNameLists(List<int> written) {
  final versionEnd = written.indexOf(_lineFeed) + 1;
  if (versionEnd == 0 || written.length < versionEnd + 5) return null;

  final packet = Uint8List.fromList(written.sublist(versionEnd));
  final data = ByteData.sublistView(packet);
  final packetLength = data.getUint32(0);
  if (packet.length < 4 + packetLength) return null;

  var offset = 5;
  expect(packet[offset], _sshMsgKexInit);
  offset += 1 + _cookieBytes;
  return [
    for (var list = 0; list < 6; list++)
      () {
        final length = data.getUint32(offset);
        final names = latin1.decode(
          packet.sublist(offset + 4, offset + 4 + length),
        );
        offset += 4 + length;
        return names.isEmpty ? <String>[] : names.split(',');
      }(),
  ];
}

void main() {
  test('the host-key preflight proposes what the authenticated connect does',
      () async {
    // The preflight builds its own SSHClient ahead of seance_core's. Were it
    // to propose dartssh2's bare defaults, a server offering only the legacy
    // fallback would be turned away here and never reach the connect that
    // accepts it. Read off the wire from a loopback listener, because the
    // preflight dials its own socket.
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(listener.close);
    final kexInit = Completer<List<List<String>>>();
    listener.listen((connection) {
      final written = <int>[];
      connection.listen(
        (bytes) {
          written.addAll(bytes);
          final lists = _clientKexInitNameLists(written);
          if (lists == null || kexInit.isCompleted) return;

          kexInit.complete(lists);
          // Hang up without a version line: nothing past the proposal is
          // under test, and no host key may reach the prompt.
          connection.destroy();
        },
        onError: (Object _) {},
      );
    });

    await expectLater(
      preflightDartSshHostKey(
        config: ServerConfig(
          id: 's',
          label: 's',
          host: InternetAddress.loopbackIPv4.address,
          port: listener.port,
          username: 'me',
          authMethod: AuthMethod.password,
          createdAt: 0,
          updatedAt: 0,
        ),
        tofu: TofuVerifier(InMemoryHostKeyStore()),
        onHostKey: (_) async => fail('no host key was presented'),
      ),
      throwsA(isA<SshConnectException>()),
    );

    final lists = await kexInit.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => fail('The preflight never sent its KEXINIT.'),
    );
    final expected = suiteSshAlgorithms;
    final kex = [for (final algorithm in expected.kex) algorithm.name];
    final hostkey = [for (final algorithm in expected.hostkey) algorithm.name];
    final cipher = [for (final algorithm in expected.cipher) algorithm.name];
    final mac = [for (final algorithm in expected.mac) algorithm.name];
    expect(lists, [
      // dartssh2 appends the strict-kex (OpenSSH PROTOCOL) and RFC 8308
      // ext-info markers to the first KEXINIT, after the real methods.
      [...kex, 'kex-strict-c-v00@openssh.com', 'ext-info-c'],
      hostkey,
      cipher,
      cipher,
      mac,
      mac,
    ]);
    // Spelled out once, so this file does not pass vacuously against an
    // empty or bare-default definition: the legacy tail is on the wire.
    expect(lists[0], contains('diffie-hellman-group14-sha1'));
    expect(lists[1], contains('ssh-rsa'));
    expect(lists[2], contains('aes128-cbc'));
  });

  test('a channel-open timeout classifies as disconnected, not unsupported',
      () {
    final error = classifySftpOpenFailure(
      TimeoutException('SFTP open timed out', const Duration(seconds: 15)),
      transportClosed: false,
    );

    // Transient: the pool's fallbacks and (later) reconnect must treat it
    // as retryable — `unsupported` means "this server cannot do SFTP".
    expect(error.kind, RemoteFileErrorKind.disconnected);
    expect(error.message, contains('timed out'));
  });

  test('a dead transport classifies as disconnected', () {
    final error = classifySftpOpenFailure(
      StateError('connection reset'),
      transportClosed: true,
    );

    expect(error.kind, RemoteFileErrorKind.disconnected);
  });

  test('other failures stay unsupported with the cause attached', () {
    final cause = FormatException('bad subsystem reply');

    final error = classifySftpOpenFailure(cause, transportClosed: false);

    expect(error.kind, RemoteFileErrorKind.unsupported);
    expect(error.cause, same(cause));
  });

  test('VFS exceptions pass through unchanged', () {
    const original = RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'open SFTP',
      message: 'denied',
    );

    expect(
      classifySftpOpenFailure(original, transportClosed: false),
      same(original),
    );
  });
}
