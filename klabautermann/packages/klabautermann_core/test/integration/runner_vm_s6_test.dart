// Spike S6 on the GitHub-hosted Ubuntu runner (03 §5.11, §8.5; M5 plan
// M01): the privileged-file recipes of
// klabautermann/test/integration/privileged_recipes.sh, which
// capture.sh --privileged-files-only runs in containers, here on ext4
// with POSIX ACLs and through seance_core's elevation prelude as
// runner_vm.sh's password-sudo account, as the engine would run them;
// and whether `sftp-server`, started through the same prelude over an
// exec channel, answers an SFTP handshake and opens a root-only file
// that the unelevated server cannot.
//
// Each case writes what it saw to
// $KLABAUTERMANN_EVIDENCE_DIR/runner-vm/s6/ before its expectations
// (klabautermann/docs/evidence/s6/), in a root-owned directory under
// /var/tmp that it removes again. runner_vm.sh starts the leg and runs
// these one at a time; without it they skip.
@Tags(['runner-vm-s6'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart' show quoteShellWord;
import 'package:seance_core/seance_core.dart'
    show ElevatedExecutor, ElevationProbe, RemoteExit, RemoteProcess, SshLink;
import 'package:test/test.dart';

import 'support/runner_vm.dart';
import 'support/s4.dart' show HostRun, S4Evidence;

/// Covers one command over the link, a prelude run included, and one
/// SFTP reply.
const _commandTimeout = Duration(seconds: 30);

/// Where OpenSSH installs `sftp-server` on Debian and Ubuntu, on the
/// RHEL family, and on Arch.
const _sftpServerPaths = [
  '/usr/lib/openssh/sftp-server',
  '/usr/libexec/openssh/sftp-server',
  '/usr/lib/ssh/sftp-server',
];

// SFTP version 3 (draft-ietf-secsh-filexfer-02), as OpenSSH speaks it.
const _sshFxpInit = 1;
const _sshFxpOpen = 3;
const _sshFxpVersion = 2;
const _sshFxpStatus = 101;
const _sshFxpHandle = 102;
const _sshFxfRead = 0x01;
const _sftpVersion = 3;

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('spike S6 on the runner VM', () {}, skip: runnerVmSkipReason);
    return;
  }
  final evidence = S4Evidence(vm.s6EvidenceDirectory);

  HostRun over(SshLink link) => (line) async {
    final result = await link.run(
      line,
      stdin: const [],
      timeout: _commandTimeout,
    );
    return (
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  };

  /// What the engine's probe would learn of password sudo (03 §6.1).
  Future<ElevationProbe> probe(HostRun run) async => ElevationProbe(
    sudoVersionLine: (await run('sudo -V | head -n 1')).stdout.trim(),
    printfIsBuiltin: (await run(
      'command -V printf',
    )).stdout.contains('builtin'),
  );

  /// A fresh root-owned directory, mode 0700, removed after the test.
  Future<String> rootDirectory() async {
    final dir = (await vm.sudo([
      'mktemp',
      '-d',
      '/var/tmp/klabautermann-s6.XXXXXX',
    ])).trim();
    addTearDown(() => vm.sudo(['rm', '-rf', '--', dir]));
    return dir;
  }

  test('the recipes run through the prelude on ext4 with ACLs', () async {
    final dir = await rootDirectory();
    final link = await vm.link(vm.sudoUser);
    addTearDown(link.close);
    final executor = ElevatedExecutor(link, await probe(over(link)));

    final result = await executor.run(
      ['sh', '-c', await _recipes(), 'sh', dir, vm.limitedUser],
      password: await vm.sudoPassword(),
      timeout: _commandTimeout,
    );
    final mount = await vm.sudo([
      'findmnt',
      '-no',
      'FSTYPE,OPTIONS',
      '-T',
      dir,
    ]);
    await vm.sudo(['rm', '-rf', '--', dir]);
    final removed = !await Directory(dir).exists();

    await evidence.write('recipes', {
      'user': vm.sudoUser,
      'reader': vm.limitedUser,
      'filesystem': mount.trim(),
      'exitCode': result.exitCode,
      'output': const LineSplitter().convert(result.stdout),
      'stderr': result.stderr,
      'directoryRemoved': removed,
    });

    expect(result.exitCode, 0, reason: result.stderr);
    expect(
      result.stdout,
      contains('setfacl: present'),
      reason: 'S6 needs the runner image to carry the acl tools',
    );
    expect(
      _section(result.stdout, 'baseline'),
      contains('acl: user:${vm.limitedUser}:r--'),
    );
    expect(removed, isTrue);
  });

  test('an elevated sftp-server answers over an exec channel', () async {
    final dir = await rootDirectory();
    final probeFile = '$dir/sftp-probe';
    await vm.sudo([
      'sh',
      '-c',
      r'printf s6 >"$1" && chmod 0600 "$1"',
      'sh',
      probeFile,
    ]);
    final link = await vm.link(vm.sudoUser);
    addTearDown(link.close);
    final run = over(link);
    final executor = ElevatedExecutor(link, await probe(run));

    final found = await run(
      'for path in ${_sftpServerPaths.join(' ')}; do '
      r'if [ -x "$path" ]; then echo "$path"; break; fi; done',
    );
    final binary = found.stdout.trim();
    expect(binary, isNotEmpty, reason: 'no sftp-server in $_sftpServerPaths');

    final elevated = await executor.start([
      binary,
    ], password: await vm.sudoPassword());
    final refusal = await elevated.refusal;
    final elevatedSession = await _sftpSession(elevated, probeFile);
    final plainSession = await _sftpSession(
      await link.start(quoteShellWord(binary)),
      probeFile,
    );

    await evidence.write('sftp-server', {
      'user': vm.sudoUser,
      'binary': binary,
      'refusal': refusal?.toString(),
      'elevated': elevatedSession,
      'unelevated': plainSession,
      'note':
          'seance_core opens SFTP only as the subsystem, so using this '
          'needs an SshLink API that runs an SFTP client over a '
          'RemoteProcess (M5 plan M01).',
    });

    expect(refusal, isNull);
    expect(elevatedSession['version'], _sftpVersion);
    expect(elevatedSession['open'], 'handle');
    expect(plainSession['open'], startsWith('status '));
  });
}

/// The recipe script, from the workspace this suite runs in.
Future<String> _recipes() async {
  final workspace = await Isolate.resolvePackageUri(
    Uri.parse('package:_klabautermann_workspace/'),
  );
  if (workspace == null) throw StateError('Workspace package is unresolved.');
  return File.fromUri(
    workspace.resolve('../test/integration/privileged_recipes.sh'),
  ).readAsString();
}

/// The lines of [output] under `## <name>` up to the next section.
String _section(String output, String name) {
  final start = output.indexOf('## $name\n');
  if (start < 0) return '';
  final end = output.indexOf('\n## ', start + 1);
  return output.substring(start, end < 0 ? output.length : end);
}

/// Speaks SFTP v3 to [process]: the version handshake, then an open of
/// [path] for reading. Returns the server's version and the open's
/// outcome (`handle`, or `status <code>`), then ends the server.
Future<Map<String, Object?>> _sftpSession(
  RemoteProcess process,
  String path,
) async {
  final stderr = StringBuffer();
  final stderrDone = process.stderr
      .transform(utf8.decoder)
      .listen(stderr.write)
      .asFuture<void>();
  final packets = _PacketReader(process.stdout);
  final session = <String, Object?>{};
  try {
    process.stdin.add(_packet(_sshFxpInit, _uint32(_sftpVersion)));
    final version = await packets.next();
    session['version'] = version?.type == _sshFxpVersion
        ? _readUint32(version!.payload, 0)
        : 'no version reply (${version?.type})';

    process.stdin.add(
      _packet(_sshFxpOpen, [
        ..._uint32(1),
        ..._string(utf8.encode(path)),
        ..._uint32(_sshFxfRead),
        ..._uint32(0),
      ]),
    );
    final reply = await packets.next();
    session['open'] = switch (reply?.type) {
      _sshFxpHandle => 'handle',
      _sshFxpStatus => 'status ${_readUint32(reply!.payload, 4)}',
      final type => 'unexpected reply $type',
    };
  } on TimeoutException {
    session['timedOut'] = true;
  } finally {
    await process.stdin.close();
    final exit = await process.exit.timeout(
      _commandTimeout,
      onTimeout: () async {
        await process.close();
        return const RemoteExit();
      },
    );
    await packets.cancel();
    await stderrDone.timeout(_commandTimeout, onTimeout: () {});
    session['exitCode'] = exit.exitCode;
    session['stderr'] = '$stderr';
  }
  return session;
}

/// Frames SFTP packets out of a byte stream.
final class _PacketReader {
  _PacketReader(Stream<List<int>> stream) : _chunks = StreamIterator(stream);

  final StreamIterator<List<int>> _chunks;
  final _buffer = <int>[];

  /// The next packet's type and payload, or null when the stream ends
  /// first.
  Future<({int type, List<int> payload})?> next() async {
    while (true) {
      if (_buffer.length >= 4) {
        final length = _readUint32(_buffer, 0);
        if (_buffer.length >= 4 + length) {
          final packet = _buffer.sublist(4, 4 + length);
          _buffer.removeRange(0, 4 + length);
          return (type: packet.first, payload: packet.sublist(1));
        }
      }
      if (!await _chunks.moveNext().timeout(_commandTimeout)) return null;
      _buffer.addAll(_chunks.current);
    }
  }

  Future<void> cancel() => _chunks.cancel();
}

List<int> _packet(int type, List<int> payload) => [
  ..._uint32(payload.length + 1),
  type,
  ...payload,
];

List<int> _string(List<int> bytes) => [..._uint32(bytes.length), ...bytes];

List<int> _uint32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _readUint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
