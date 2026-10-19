// Helpers of spike S4 (03 §7.17; 06 spike table), shared by the runner-VM
// suite (runner_vm_s4_test.dart) and the Docker host's setsid suite
// (s4_setsid_test.dart): the operation record E08's wrapper writes, the
// session facts of a process from /proc, and the evidence files the
// cases write for klabautermann/docs/evidence/s4/.
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart' show quoteShellWord;
import 'package:klabautermann_host/klabautermann_host.dart'
    show DetachedRunner, OpRecordField, OpRecordState, OperationCommands;
import 'package:test/test.dart';

/// Runs one shell command line on the host under test, as some account,
/// and returns its exit status and output.
typedef HostRun =
    Future<({int? exitCode, String stdout, String stderr})> Function(
      String commandLine,
    );

/// The command line that prints the login user's operation directory,
/// resolved in the login shell's environment as 03 §7.17 says the engine
/// does (`kOpsDirSuffix`).
const userOpsDirLine =
    r'printf "%s\n" "${XDG_STATE_HOME:-$HOME/.local/state}/klabautermann/ops"';

/// The launch prefix of E08's `setsid` rows, before the wrapper's own
/// argv: `sh -c <launcher> klabautermann-launch`.
const _launcherWords = 4;

/// The wrapper's argv from E08's login `setsid` row, without its
/// launcher. The S4 cases put other launchers in front of it:
/// `/bin/sh -c <wrapper> klabautermann-op <dir> <id> <uid> - -- <argv...>`.
List<String> wrapperArgv({
  required String dir,
  required String id,
  required int uid,
  required List<String> argv,
}) => OperationCommands.detachedLaunch(
  DetachedRunner.loginSetsid,
  dir: dir,
  id: id,
  uid: uid,
  argv: argv,
).sublist(_launcherWords);

/// One operation record (03 §7.17, E08), or null when [text] is empty.
Map<String, Object?>? parseOpRecord(String text) {
  if (text.trim().isEmpty) return null;
  final record = jsonDecode(text) as Map<String, Object?>;
  expect(record.keys, containsAll([OpRecordField.state, OpRecordField.pid]));
  return record;
}

/// Reads `<dir>/<id>.json` with [run] until its state is done, and
/// returns it; fails after [timeout] with the last record read.
Future<Map<String, Object?>> untilDone(
  HostRun run,
  String dir,
  String id, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  Map<String, Object?>? last;
  while (true) {
    final read = await run(
      'cat -- ${quoteShellWord('$dir/$id.json')} 2>/dev/null || true',
    );
    last = parseOpRecord(read.stdout);
    if (last?[OpRecordField.state] == OpRecordState.done.wireName) {
      return last!;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('operation $id never wrote a done record; last read: $last');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

/// What /proc says of a process: its state letter, parent, process group,
/// session and real uid.
typedef ProcFacts = ({String state, int ppid, int pgrp, int session, int uid});

/// The facts of process [pid] read with [run], or null when it has
/// exited, a zombie included.
Future<ProcFacts?> procFacts(HostRun run, int pid) async {
  final read = await run(
    'cat /proc/$pid/stat 2>/dev/null && '
    'grep "^Uid:" /proc/$pid/status 2>/dev/null || true',
  );
  final lines = const LineSplitter().convert(read.stdout);
  if (lines.length < 2) return null;
  final stat = lines.first;
  final fields = stat.substring(stat.lastIndexOf(') ') + 2).split(' ');
  final uid = lines[1].split(RegExp(r'\s+'))[1];
  final facts = (
    state: fields[0],
    ppid: int.parse(fields[1]),
    pgrp: int.parse(fields[2]),
    session: int.parse(fields[3]),
    uid: int.parse(uid),
  );
  return facts.state == 'Z' ? null : facts;
}

/// [facts] for an evidence file.
Map<String, Object?>? procJson(ProcFacts? facts) => facts == null
    ? null
    : {
        'state': facts.state,
        'ppid': facts.ppid,
        'pgrp': facts.pgrp,
        'session': facts.session,
        'uid': facts.uid,
      };

/// A command result for an evidence file.
Map<String, Object?> resultJson(
  ({int? exitCode, String stdout, String stderr}) result,
) => {
  'exit': result.exitCode,
  'stdout': result.stdout,
  'stderr': result.stderr,
};

/// Writes spike S4's evidence: one JSON file per case under [directory],
/// or nothing when the run collects none.
final class S4Evidence {
  S4Evidence(this.directory);

  final String? directory;

  /// Writes [data] to `<directory>/<name>.json`, with the case's name and
  /// the time it was written. Call it before the case's expectations, so
  /// a failing case still leaves its evidence.
  Future<void> write(String name, Map<String, Object?> data) async {
    final root = directory;
    if (root == null) return;
    final file = File('$root/$name.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'case': name, 'recordedAt': DateTime.now().toUtc().toIso8601String(), ...data})}\n',
    );
  }
}

/// Polls [check] every half second until it holds, for at most
/// [timeout]; returns whether it held.
Future<bool> eventually(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (await check()) return true;
    if (DateTime.now().isAfter(deadline)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}
