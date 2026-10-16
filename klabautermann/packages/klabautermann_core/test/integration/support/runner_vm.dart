import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'fixture.dart';

/// Why the runner-VM suite skips: runner_vm.sh exports its environment.
const runnerVmSkipReason =
    'needs the runner-VM leg: run klabautermann/test/integration/run.sh on a '
    'GitHub-hosted Ubuntu runner';

/// The fleet aliases of the client config each engine imports: the
/// account outside every journal group (LOG-04), and the one in
/// `systemd-journal`.
const limitedServer = 'ssh-config:limited';
const journalServer = 'ssh-config:journal';

/// The groups whose members read the whole journal (03 §8.1).
const journalGroups = {'systemd-journal', 'adm', 'wheel'};

/// A `ps -o pid=,ppid=,args=` row.
final _psRow = RegExp(r'^\s*(\d+)\s+(\d+)\s+(.*)$');

/// The account a per-connection sshd process serves, from the titles
/// OpenSSH sets (`setproctitle`) on the privileged monitor and on the
/// child that holds the connection, which gains `@notty` once a session
/// opens:
///
/// ```text
/// sshd: klab-vm-journal [priv]
/// sshd: klab-vm-journal
/// sshd: klab-vm-journal@notty
/// ```
final _connectionTitle = RegExp(r'^sshd: ([^\s@\[]+)(?:[\s@]|$)');

/// The runner-VM leg runner_vm.sh started (03 §11.3, K28a): a second sshd
/// on loopback of the GitHub-hosted runner, which is a systemd host, with
/// two throwaway accounts whose login shell is `/bin/sh`, dash on Ubuntu.
/// It comes from the variables runner_vm.sh exports.
final class RunnerVm {
  RunnerVm._(this._environment);

  final Map<String, String> _environment;

  /// The running leg, or null when runner_vm.sh exported none of its
  /// variables. Some but not all fail the suite, as for [Fixture].
  static RunnerVm? fromEnvironment([Map<String, String>? environment]) {
    environment ??= Platform.environment;
    if (!environment.keys.any((name) => name.startsWith(_prefix))) {
      return null;
    }
    return RunnerVm._(environment);
  }

  static const _prefix = 'KLABAUTERMANN_RUNNER_VM_';

  String _variable(String name) {
    final value = _environment['$_prefix$name'];
    if (value == null || value.isEmpty) {
      throw StateError('runner_vm.sh exported no $_prefix$name');
    }
    return value;
  }

  String get _host => _variable('HOST');
  int get _port => int.parse(_variable('PORT'));
  String get _identityFile => _variable('IDENTITY_FILE');
  String get _knownHosts => _variable('KNOWN_HOSTS');
  String get _hostKeyFingerprint => _variable('HOST_KEY_FINGERPRINT');

  /// The leg's sshd listener, whose children serve one connection each.
  int get _sshdPid => int.parse(_variable('SSHD_PID'));

  /// runner_vm.sh's directory for this run, which it removes on every
  /// exit.
  String get _runtimeDirectory => _variable('RUNTIME');

  /// The account outside `systemd-journal`, `adm` and `wheel`.
  String get limitedUser => _variable('USER');

  /// The account in `systemd-journal`.
  String get journalUser => _variable('JOURNAL_USER');

  /// The transient system timer runner_vm.sh started, and its
  /// `OnCalendar=` expression in systemd's normalized form.
  String get timer => _variable('TIMER');
  String get calendar => _variable('CALENDAR');

  /// Where the leg collects evidence, or null.
  String? get _evidenceDirectory =>
      switch (_environment['KLABAUTERMANN_EVIDENCE_DIR']) {
        final path? when path.isNotEmpty => '$path/runner-vm',
        _ => null,
      };

  /// Where the engine dials, and the host key the sshd answers with.
  Endpoint get endpoint => (host: _host, port: _port);
  Map<Endpoint, Set<String>> get hostKeys => {
    endpoint: {_hostKeyFingerprint},
  };

  String get _sshConfig =>
      '''
Host limited
  HostName $_host
  Port $_port
  User $limitedUser
  IdentityFile $_identityFile

Host journal
  HostName $_host
  Port $_port
  User $journalUser
  IdentityFile $_identityFile
''';

  /// An engine that imports [limitedServer] and [journalServer]. [name]
  /// titles its event log in the evidence directory.
  Future<FixtureEngine> engine(String name) => FixtureEngine.launch(
    name: name,
    runtimeDirectory: _runtimeDirectory,
    sshConfig: _sshConfig,
    hosts: 2,
    evidenceDirectory: _evidenceDirectory,
  );

  /// Runs [command] as [user] through OpenSSH's client to the same sshd,
  /// out of the engine's sight, and returns its stdout; a failure fails
  /// the test. The login shell, dash, reads [command] as the engine's
  /// commands are read.
  Future<String> ssh(String user, String command) async {
    final result = await Process.run('ssh', [
      '-F',
      '/dev/null',
      '-o',
      'BatchMode=yes',
      '-o',
      'IdentitiesOnly=yes',
      '-o',
      'IdentityAgent=none',
      '-o',
      'StrictHostKeyChecking=yes',
      '-o',
      'UserKnownHostsFile=$_knownHosts',
      '-o',
      'GlobalKnownHostsFile=/dev/null',
      '-o',
      'ConnectTimeout=10',
      '-i',
      _identityFile,
      '-p',
      '$_port',
      '-l',
      user,
      _host,
      '--',
      command,
    ]);
    if (result.exitCode != 0) {
      fail('ssh $user exited ${result.exitCode}: ${result.stderr}');
    }
    return '${result.stdout}';
  }

  /// Runs [command] through the runner's passwordless sudo, the tests'
  /// side channel for signals and for writing while the sshd is paused.
  Future<String> sudo(List<String> command) async {
    final result = await Process.run('sudo', ['-n', ...command]);
    if (result.exitCode != 0) {
      fail(
        'sudo ${command.join(' ')} exited ${result.exitCode}: '
        '${result.stderr}',
      );
    }
    return '${result.stdout}';
  }

  /// Writes `marker <n>` for each of [numbers], in order, to the journal
  /// as [user], with [tag] as the syslog identifier: over SSH, or with
  /// [viaSudo] through `sudo -u`, which works while the sshd is paused.
  Future<void> logMarkers(
    String user,
    String tag,
    Iterable<int> numbers, {
    bool viaSudo = false,
  }) async {
    for (final n in numbers) {
      final argv = ['logger', '-t', tag, 'marker $n'];
      if (viaSudo) {
        await sudo(['-u', user, ...argv]);
      } else {
        await ssh(user, argv.map(quoteShellWord).join(' '));
      }
    }
  }

  /// Stops and continues the sshd listener: while it is stopped, a new
  /// connection waits in the listen queue unanswered, and the ones it
  /// served go on.
  Future<void> pauseSshd() => sudo(['kill', '-STOP', '$_sshdPid']);
  Future<void> resumeSshd() => sudo(['kill', '-CONT', '$_sshdPid']);

  /// The processes serving [user]'s connections to the leg's sshd, each
  /// connection's privileged monitor and the child that holds its
  /// socket: killing both closes the connection at once, as a dropped
  /// network path or a restarted sshd would.
  Future<List<int>> connectionProcesses(String user) async {
    final ps = await Process.run('ps', ['-e', '-o', 'pid=,ppid=,args=']);
    if (ps.exitCode != 0) fail('ps exited ${ps.exitCode}: ${ps.stderr}');

    final children = <int, List<int>>{};
    final titles = <int, String>{};
    for (final line in const LineSplitter().convert('${ps.stdout}')) {
      final row = _psRow.firstMatch(line);
      if (row == null) continue;
      final pid = int.parse(row[1]!);
      (children[int.parse(row[2]!)] ??= []).add(pid);
      titles[pid] = row[3]!;
    }

    final serving = <int>[];
    final pending = [...?children[_sshdPid]];
    while (pending.isNotEmpty) {
      final pid = pending.removeLast();
      if (_connectionTitle.firstMatch(titles[pid]!)?[1] == user) {
        serving.add(pid);
      }
      pending.addAll(children[pid] ?? const []);
    }
    return serving..sort();
  }
}
