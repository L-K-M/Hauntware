// Spike S3's elevation matrix (03 §8.3; 06's spike table; M4 plan E01):
// one case drives seance_core's real ElevatedExecutor, the D24 prelude
// and its rung-4 retry included, against one container's sudo, sudo-rs
// or doas, and records what each command returned. The commands reach the
// container through a [CommandRunner]; capture_elevation.dart's runner is
// `docker exec` as a non-root account, in a new session with no tty.
import 'dart:convert';

import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationException,
        ElevationProbe,
        RemoteCommandResult,
        SshLink;

/// Runs one login-shell command line with [stdin] and returns its result.
typedef CommandRunner = Future<RemoteCommandResult> Function(
  String command,
  List<int> stdin,
);

/// The evidence format's version, bumped when a field changes meaning.
const elevationEvidenceVersion = 1;

/// What the elevated command prints when it ran as root.
const _rootUid = '0\n';

/// What the stdin case sends after the password line; the command must
/// read exactly this, which shows the prelude's `read` took one line.
const _stdinPayload = 'stdin-reaches-the-command\n';

/// One command the executor or the probe sent, as the container answered.
final class RecordedCall {
  RecordedCall(this.command, this.result);

  final String command;
  final RemoteCommandResult result;

  Map<String, Object?> toJson() => {
    'command': command,
    'exit': result.exitCode,
    'stdout': result.stdout,
    'stderr': result.stderr,
  };
}

/// An [SshLink] whose only working member is [run], which hands the
/// command to [_runner] and records it. The executor needs nothing else.
final class RecordingLink implements SshLink {
  RecordingLink(this._runner);

  final CommandRunner _runner;
  final List<RecordedCall> calls = [];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    final result = await _runner(command, stdin ?? const []);
    calls.add(RecordedCall(command, result));
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('RecordingLink only runs commands');
}

/// How one executor run ended: the command's result, or the typed
/// refusal, plus the commands it took.
final class ExecutorOutcome {
  ExecutorOutcome._(this.calls, {this.result, this.refusal});

  final List<RecordedCall> calls;
  final RemoteCommandResult? result;
  final ElevationException? refusal;

  /// The comparable part, which check mode holds equal across runs: how
  /// it ended, the exit status and how many commands it took.
  Map<String, Object?> get summary => {
    'outcome': refusal == null ? 'ran' : 'refused',
    if (refusal case final r?) 'kind': r.kind.name,
    if (result case final r?) 'exit': r.exitCode,
    'commands': calls.length,
  };

  Map<String, Object?> toJson() => {
    ...summary,
    if (result case final r?) 'stdout': r.stdout,
    if (result case final r?) 'stderr': r.stderr,
    if (refusal case final r?) 'refusalStderr': r.stderr,
    'calls': [for (final call in calls) call.toJson()],
  };
}

/// Runs one case of the matrix: probes the account as the engine's probe
/// does (03 §6.1), then runs `id -u` with the right password, a wrong one
/// and none, and `cat` with stdin after the password line, each through a
/// fresh [ElevatedExecutor], plus `sudo -n -l` and, for doas, a password
/// on a pipe. [password] reaches the container only on stdin and never
/// enters the returned evidence; [wrongPassword] differs from it.
Future<Map<String, Object?>> runElevationCase({
  required String name,
  required String description,
  required CommandRunner runner,
  required String password,
  required String wrongPassword,
}) async {
  if (password == wrongPassword) {
    throw ArgumentError('the wrong password must differ from the right one');
  }
  final probeLink = RecordingLink(runner);
  final probe = await _probe(probeLink);

  Future<ExecutorOutcome> elevate(
    List<String> argv, {
    String? password,
    List<int>? stdin,
  }) async {
    final link = RecordingLink(runner);
    try {
      final result = await ElevatedExecutor(
        link,
        probe,
      ).run(argv, password: password, stdin: stdin);
      return ExecutorOutcome._(link.calls, result: result);
    } on ElevationException catch (e) {
      return ExecutorOutcome._(link.calls, refusal: e);
    }
  }

  final outcomes = {
    'rightPassword': await elevate(['id', '-u'], password: password),
    'wrongPassword': await elevate(['id', '-u'], password: wrongPassword),
    'noPassword': await elevate(['id', '-u']),
    'stdinAfterPassword': await elevate(
      ['cat'],
      password: password,
      stdin: utf8.encode(_stdinPayload),
    ),
  };

  final raw = RecordingLink(runner);
  if (probe.sudoVersionLine != null) await raw.run('sudo -n -l');
  if (probe.doasPresent) {
    await raw.run('doas -n true');
    await raw.run('doas true', stdin: utf8.encode('$password\n'));
  }

  final evidence = {
    'version': elevationEvidenceVersion,
    'case': name,
    'description': description,
    'probe': {
      'isRoot': probe.isRoot,
      'sudoVersionLine': probe.sudoVersionLine,
      'sudoIsRs': probe.sudoIsRs,
      'sudoNopasswd': probe.sudoNopasswd,
      'doasPresent': probe.doasPresent,
      'doasNopasswd': probe.doasNopasswd,
      'printfIsBuiltin': probe.printfIsBuiltin,
    },
    'probeCalls': [for (final call in probeLink.calls) call.toJson()],
    'outcomes': {
      for (final MapEntry(:key, :value) in outcomes.entries)
        key: value.toJson(),
    },
    'stdinPayloadEchoed':
        outcomes['stdinAfterPassword']!.result?.stdout == _stdinPayload,
    'ranAsRoot': outcomes['rightPassword']!.result?.stdout == _rootUid,
    'rawCalls': [for (final call in raw.calls) call.toJson()],
  };
  final text = jsonEncode(evidence);
  if (text.contains(password) || text.contains(wrongPassword)) {
    throw StateError('$name: a password reached the evidence');
  }
  return evidence;
}

/// The engine's probe of the elevation facts (03 §6.1 "Elevation" row):
/// each a command of its own, whose failure leaves the fact unset.
Future<ElevationProbe> _probe(RecordingLink link) async {
  Future<RemoteCommandResult> run(String command) => link.run(command);

  final uid = await run('id -u');
  final version = await run('sudo -V 2>/dev/null | head -n 1');
  final sudoLine = version.stdout.trim();
  final hasSudo = version.exitCode == 0 && sudoLine.isNotEmpty;
  final sudoNopasswd = hasSudo && (await run('sudo -n true')).exitCode == 0;
  final doasPresent = (await run('command -v doas')).exitCode == 0;
  final doasNopasswd = doasPresent && (await run('doas -n true')).exitCode == 0;
  final printf = await run('command -V printf');
  return ElevationProbe(
    isRoot: uid.stdout.trim() == '0',
    sudoVersionLine: hasSudo ? sudoLine : null,
    sudoIsRs: hasSudo && sudoLine.startsWith('sudo-rs'),
    sudoNopasswd: sudoNopasswd,
    doasPresent: doasPresent,
    doasNopasswd: doasNopasswd,
    printfIsBuiltin: printf.stdout.contains('builtin'),
  );
}

/// The differences between a committed case and a new capture of it, by
/// [ExecutorOutcome.summary], the probe facts and the two derived flags;
/// empty when they match. Stderr texts and command lines are not
/// compared: E04 reads those from the committed copy.
List<String> compareElevationCases(
  Map<String, Object?> committed,
  Map<String, Object?> captured,
) {
  final differences = <String>[];
  void same(String path, Object? a, Object? b) {
    if (jsonEncode(a) != jsonEncode(b)) {
      differences.add(
        '$path: committed ${jsonEncode(a)}, '
        'captured ${jsonEncode(b)}',
      );
    }
  }

  same('version', committed['version'], captured['version']);
  final committedProbe = committed['probe'] as Map?;
  final capturedProbe = captured['probe'] as Map?;
  for (final key in {...?committedProbe?.keys, ...?capturedProbe?.keys}) {
    if (key == 'sudoVersionLine') continue;
    same('probe.$key', committedProbe?[key], capturedProbe?[key]);
  }
  final committedOutcomes = committed['outcomes'] as Map? ?? const {};
  final capturedOutcomes = captured['outcomes'] as Map? ?? const {};
  for (final key in {...committedOutcomes.keys, ...capturedOutcomes.keys}) {
    same(
      'outcomes.$key',
      _summaryOf(committedOutcomes[key]),
      _summaryOf(capturedOutcomes[key]),
    );
  }
  for (final key in ['stdinPayloadEchoed', 'ranAsRoot']) {
    same(key, committed[key], captured[key]);
  }
  return differences;
}

Map<String, Object?>? _summaryOf(Object? outcome) => switch (outcome) {
  final Map<String, Object?> o => {
    for (final key in const ['outcome', 'kind', 'exit', 'commands'])
      if (o.containsKey(key)) key: o[key],
  },
  _ => null,
};
