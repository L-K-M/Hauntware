// The safety scripts through real shells (03 §7.2, §7.7, §7.17): the
// guarded kill against live processes, a reused PID simulated by start
// ticks that differ, the crontab spool listing, and the operation
// wrapper's records, refusals, launch and prune, under dash and bash.
// Each script runs as the builder's argv with `sh` and `/bin/sh` replaced
// by the shell under test, and the main cases also as the full
// `commandLine` through that shell as the login shell. A user directory
// under /tmp stands in for the operation directory, which the builder
// would refuse, so the tests swap it into the argv. Tagged `shell`; a
// shell that is not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

final _uid = int.parse((Process.runSync('id', ['-u']).stdout as String).trim());

/// Root, or a user who owns PID 1 (a container's entrypoint run with
/// `--user`), may signal it: kill(2) lets a sender whose uid matches the
/// target's real or saved uid.
final bool _mayKillPid1 = () {
  if (_uid == 0) return true;
  try {
    final line = File(
      '/proc/1/status',
    ).readAsLinesSync().firstWhere((l) => l.startsWith('Uid:'));
    final ids = line.substring(4).trim().split(RegExp(r'\s+'));
    return ids[0] == '$_uid' || ids[2] == '$_uid';
  } on Object {
    return false;
  }
}();

const _id = '0123456789abcdef';
const _placeholderDir = '/home/klab/.local/state/klabautermann/ops';

/// POSIX single quoting, as `quoteShellWord` does for sh, dash and bash.
String _quote(String word) => "'${word.replaceAll("'", r"'\''")}'";

/// Field 22 of `/proc/<pid>/stat`, read the way proc(5) says to.
int _startTicks(int pid) {
  final stat = File('/proc/$pid/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(') ') + 2).split(' ');
  return int.parse(fields[19]);
}

/// [argv] with the builder's `sh` and `/bin/sh` replaced by [shell].
List<String> _under(String shell, List<String> argv) => [
  for (final w in argv) w == 'sh' || w == '/bin/sh' ? shell : w,
];

Future<ProcessResult> _run(
  String shell,
  List<String> argv, {
  Map<String, String>? environment,
}) {
  final words = _under(shell, argv);
  return Process.run(
    words.first,
    words.skip(1).toList(),
    environment: environment,
  );
}

/// [argv] as sshd would run it: the `commandLine` through [shell].
Future<ProcessResult> _runAsLogin(String shell, List<String> argv) =>
    Process.run(shell, ['-c', HostCommands.commandLine(argv, quote: _quote)]);

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

/// A long-lived process, started as [executable] (a symlink to `sleep`
/// gives it that comm), stopped after the test if still alive.
Future<Process> _sleeper({String executable = 'sleep'}) async {
  final process = await Process.start(executable, ['30']);
  addTearDown(() => process.kill(ProcessSignal.sigkill));
  return process;
}

Future<String> _sleepPath() async =>
    ((await Process.run('sh', ['-c', 'command -v sleep'])).stdout as String)
        .trim();

/// The wrapper argv of the user setsid row for [argv], recording in [dir].
List<String> _wrapper(
  String dir, {
  required List<String> argv,
  DetachedRunner runner = DetachedRunner.loginSetsid,
  String id = _id,
  int? uid,
}) {
  final launch = OperationCommands.detachedLaunch(
    runner,
    dir: _placeholderDir,
    id: id,
    uid: uid ?? _uid,
    argv: argv,
  );
  final wrapped = launch.sublist(launch.indexOf('/bin/sh'));
  return [for (final w in wrapped) w == _placeholderDir ? dir : w];
}

Map<String, Object?> _record(String dir, {String id = _id}) =>
    jsonDecode(File('$dir/$id.json').readAsStringSync())
        as Map<String, Object?>;

int _mode(String path) => FileStat.statSync(path).mode & 0x1ff;

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group('$name: guarded kill', () {
      test('signals when the start ticks match', () async {
        final p = await _sleeper();
        final argv = HostCommands.guardedKill(
          p.pid,
          _startTicks(p.pid),
          KillSignal.sigterm,
        );

        final result = await _runAsLogin(shell, argv);
        expect(
          result.exitCode,
          kGuardedKillSignalled,
          reason: '${result.stderr}',
        );
        expect(await p.exitCode, -ProcessSignal.sigterm.signalNumber);
      });

      test('refuses a reused PID: the start ticks differ', () async {
        final p = await _sleeper();
        final argv = HostCommands.guardedKill(
          p.pid,
          _startTicks(p.pid) + 1,
          KillSignal.sigkill,
        );

        final result = await _runAsLogin(shell, argv);
        expect(result.exitCode, kGuardedKillReused);
        expect(
          GuardedKillOutcome.fromExitCode(result.exitCode),
          GuardedKillOutcome.reused,
        );
        expect(
          File('/proc/${p.pid}/stat').existsSync(),
          isTrue,
          reason: 'the process must still run',
        );
      });

      test('reads the ticks after the last ") " of a hostile comm', () async {
        final dir = await _tempDir('klab-comm-');
        final link = Link('${dir.path}/e) 1 2 3 4 5');
        await link.create(await _sleepPath());
        final p = await _sleeper(executable: link.path);

        final ticks = _startTicks(p.pid);
        final argv = HostCommands.guardedKill(p.pid, ticks, KillSignal.sigterm);
        final result = await _run(shell, argv);
        expect(
          result.exitCode,
          kGuardedKillSignalled,
          reason: '${result.stderr}',
        );
        expect(await p.exitCode, -ProcessSignal.sigterm.signalNumber);
      });

      test('a comm with a newline reads as unreadable, not a guess', () async {
        final dir = await _tempDir('klab-comm-');
        final link = Link('${dir.path}/x\ny) 1 2 3');
        await link.create(await _sleepPath());
        final p = await _sleeper(executable: link.path);

        final argv = HostCommands.guardedKill(p.pid, 0, KillSignal.sigkill);
        final result = await _run(shell, argv);
        expect(result.exitCode, kGuardedKillUnreadable);
        expect(File('/proc/${p.pid}/stat').existsSync(), isTrue);
      });

      test('a PID with no /proc entry is gone', () async {
        // Above the largest pid_max Linux allows (2^22).
        final argv = HostCommands.guardedKill(4194305, 1, KillSignal.sigterm);
        final result = await _run(shell, argv);
        expect(result.exitCode, kGuardedKillGone);
      });

      test('the script refuses parameters the builder would', () async {
        final script = HostCommands.guardedKill(1, 1, KillSignal.sigterm)[2];
        for (final params in [
          ['0', '1', 'TERM'],
          ['-1', '1', 'TERM'],
          ['012', '1', 'TERM'],
          ['1 2', '1', 'TERM'],
          ['', '1', 'TERM'],
          ['1', '-1', 'TERM'],
          ['1', '', 'TERM'],
          ['1', '1', 'term'],
          ['1', '1', 'TERM;id'],
          ['1', '1', ''],
        ]) {
          final result = await _run(shell, [
            'sh',
            '-c',
            script,
            'k',
            ...params,
          ]);
          expect(result.exitCode, kGuardedKillInvalid, reason: '$params');
        }
      });

      test('a kill the kernel refuses exits killFailed', () async {
        // PID 1 belongs to root; CONT would be harmless anyway.
        final argv = HostCommands.guardedKill(
          1,
          _startTicks(1),
          KillSignal.sigcont,
        );
        final result = await _run(shell, argv);
        expect(result.exitCode, kGuardedKillFailed);
      }, skip: _mayKillPid1 ? 'this user may signal PID 1' : null);
    });

    group('$name: crontab spool', () {
      test('lists the first spool that exists, regular files only', () async {
        final root = await _tempDir('klab-spool-');
        final debian = Directory('${root.path}/crontabs')..createSync();
        Directory('${root.path}/cron').createSync();
        for (final f in ['root', 'alice', '.hidden', 'tmp.XyZ']) {
          File('${debian.path}/$f').writeAsStringSync('* * * * * true\n');
        }
        Directory('${debian.path}/sub').createSync();
        Link('${debian.path}/link').createSync('${debian.path}/root');

        final argv = HostCommands.crontabSpoolList(
          spools: ['${root.path}/missing', debian.path, '${root.path}/cron'],
        );
        final result = await _runAsLogin(shell, argv);
        expect(
          result.exitCode,
          kCrontabSpoolListed,
          reason: '${result.stderr}',
        );
        expect(result.stdout, '${debian.path}\nalice\nroot\ntmp.XyZ\n');
        final spool = parseCrontabSpool(result.stdout as String)!;
        expect(spool.users, ['alice', 'root']);
        expect(spool.skipped, 1);
      });

      test('an empty spool lists only its directory', () async {
        final root = await _tempDir('klab-spool-');
        final result = await _run(
          shell,
          HostCommands.crontabSpoolList(spools: [root.path]),
        );
        expect(result.exitCode, kCrontabSpoolListed);
        expect(result.stdout, '${root.path}\n');
      });

      test('no spool directory exits missing', () async {
        final root = await _tempDir('klab-spool-');
        final result = await _run(
          shell,
          HostCommands.crontabSpoolList(spools: ['${root.path}/none']),
        );
        expect(result.exitCode, kCrontabSpoolMissing);
        expect(result.stdout, isEmpty);
      });

      test(
        'an unreadable spool exits denied instead of reading as empty',
        () async {
          final root = await _tempDir('klab-spool-');
          final spool = Directory('${root.path}/crontabs')..createSync();
          File('${spool.path}/alice').writeAsStringSync('');
          await Process.run('chmod', ['0300', spool.path]);
          addTearDown(() => Process.run('chmod', ['0700', spool.path]));

          final result = await _run(
            shell,
            HostCommands.crontabSpoolList(spools: [spool.path]),
          );
          expect(result.exitCode, kCrontabSpoolDenied);
          expect(result.stdout, isEmpty);
        },
        skip: _uid == 0 ? 'root reads every directory' : null,
      );
    });

    group('$name: operation wrapper', () {
      late String root;
      late String ops;

      setUp(() async {
        root = (await _tempDir('klab-ops-')).path;
        ops = '$root/state/klabautermann/ops';
      });

      test('records running, then done with the exit code', () async {
        // The command prints the running record into the log, so the test
        // sees what a reader saw mid-run.
        final result = await _run(
          shell,
          _wrapper(
            ops,
            argv: [
              'sh',
              '-c',
              r'printf "out\n"; printf "err\n" >&2; cat "$1"; exit 3',
              'op',
              '$ops/$_id.json',
            ],
          ),
        );
        expect(result.exitCode, 3, reason: '${result.stderr}');

        final log = File('$ops/$_id.log').readAsLinesSync();
        expect(log.take(2), ['out', 'err']);
        final running = jsonDecode(log[2]) as Map<String, Object?>;
        expect(running, {
          OpRecordField.version: kOpRecordVersion,
          OpRecordField.id: _id,
          OpRecordField.state: OpRecordState.running.wireName,
          OpRecordField.pid: isA<int>(),
          OpRecordField.startTicks: isA<int>(),
          OpRecordField.unit: null,
          OpRecordField.exit: null,
          OpRecordField.startedAt: isA<int>(),
          OpRecordField.endedAt: null,
        });

        final done = _record(ops);
        expect(done.keys, running.keys);
        expect(done[OpRecordField.state], OpRecordState.done.wireName);
        expect(done[OpRecordField.exit], 3);
        expect(done[OpRecordField.pid], running[OpRecordField.pid]);
        expect(
          done[OpRecordField.startTicks],
          running[OpRecordField.startTicks],
        );
        expect(
          done[OpRecordField.endedAt] as int,
          greaterThanOrEqualTo(done[OpRecordField.startedAt] as int),
        );
        expect(File('$ops/$_id.json').readAsStringSync(), endsWith('}\n'));

        expect(_mode(ops), 0x1c0, reason: 'directory 0700');
        expect(_mode('$ops/$_id.json'), 0x180, reason: 'record 0600');
        expect(_mode('$ops/$_id.log'), 0x180, reason: 'log 0600');
        expect(File('$ops/.$_id.tmp').existsSync(), isFalse);
      });

      test('writes each record to a temp file and moves it over', () async {
        final bin = await _tempDir('klab-bin-');
        final calls = '${bin.path}/mv.calls';
        final mv = File('${bin.path}/mv')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'printf "%s|" "\$@" >>"$calls"; printf "\\n" >>"$calls"\n'
            'PATH=${Platform.environment['PATH']} exec mv "\$@"\n',
          );
        await Process.run('chmod', ['0755', mv.path]);

        final result = await _run(
          shell,
          _wrapper(ops, argv: ['true']),
          environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final move = '-f|$ops/.$_id.tmp|$ops/$_id.json|';
        expect(File(calls).readAsLinesSync(), [move, move]);
        expect(_record(ops)[OpRecordField.state], 'done');
      });

      test('a systemd row records its transient unit', () async {
        final result = await _run(
          shell,
          _wrapper(
            ops,
            runner: DetachedRunner.loginSystemdUser,
            argv: ['true'],
          ),
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(_record(ops)[OpRecordField.unit], opUnitName(_id));
      });

      test('a command that does not exist is done with 127', () async {
        final result = await _run(
          shell,
          _wrapper(ops, argv: ['klabautermann-no-such-command']),
        );
        expect(result.exitCode, 127);
        expect(_record(ops)[OpRecordField.exit], 127);
      });

      test('a command named like a wrapper function runs the program', () {
        // `command` bypasses the wrapper's own klab_* functions.
        return _run(shell, _wrapper(ops, argv: ['klab_rec'])).then((r) {
          expect(r.exitCode, 127);
          expect(_record(ops)[OpRecordField.exit], 127);
        });
      });

      test('refusals exit setup-failed and run nothing', () async {
        final marker = '$root/ran';
        final cmd = ['touch', marker];
        final good = _wrapper(ops, argv: cmd);
        List<String> withParam(int index, String value) =>
            [...good]..[index] = value;

        final other = await _tempDir('klab-ops-other-');
        final linkParent = '${other.path}/state/klabautermann';
        Directory(linkParent).createSync(recursive: true);
        Link('$linkParent/ops').createSync(other.path);

        // Wrapper words: sh -c W $0 dir id uid unit -- cmd...
        for (final (what, argv) in [
          ('bad id', withParam(5, '0123456789ABCDEF')),
          ('short id', withParam(5, '0123')),
          ('bad uid', withParam(6, '1x')),
          ('foreign uid', withParam(6, '${_uid + 1}')),
          ('unit of another id', withParam(7, opUnitName('ffffffffffffffff'))),
          ('missing --', withParam(8, 'x')),
          ('not an operation directory', withParam(4, '${other.path}/ops')),
          ('symlinked directory', withParam(4, '$linkParent/ops')),
          ('no command', good.sublist(0, 9)),
        ]) {
          final result = await _run(shell, argv);
          expect(result.exitCode, kOpWrapperSetupFailed, reason: what);
          expect(File(marker).existsSync(), isFalse, reason: what);
        }
        expect(Directory(ops).existsSync(), isFalse);
      });

      test('an id already in use is refused', () async {
        expect((await _run(shell, _wrapper(ops, argv: ['true']))).exitCode, 0);
        File('$ops/$_id.json').deleteSync();
        // The log alone still claims the id.
        final again = await _run(shell, _wrapper(ops, argv: ['false']));
        expect(again.exitCode, kOpWrapperSetupFailed);
        expect(File('$ops/$_id.json').existsSync(), isFalse);
      });

      test('the setsid launch detaches and prints the record PID', () async {
        // The launcher's own argv, with the stand-in directory swapped in.
        final launch = [
          for (final w in OperationCommands.detachedLaunch(
            DetachedRunner.loginSetsid,
            dir: _placeholderDir,
            id: _id,
            uid: _uid,
            argv: const ['sh', '-c', 'sleep 0.2; exit 7'],
          ))
            w == _placeholderDir ? ops : w,
        ];
        final result = await _runAsLogin(shell, launch);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final pid = int.parse((result.stdout as String).trim());

        final record = File('$ops/$_id.json');
        for (var i = 0; i < 100; i++) {
          if (record.existsSync() &&
              _record(ops)[OpRecordField.state] == 'done') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        final done = _record(ops);
        expect(done[OpRecordField.state], 'done');
        expect(done[OpRecordField.exit], 7);
        expect(done[OpRecordField.pid], pid);
      });
    });

    group('$name: cleanup and prune', () {
      test('opPrune removes old operation files only', () async {
        final root = await _tempDir('klab-prune-');
        final ops = '${root.path}/klabautermann/ops';
        Directory(ops).createSync(recursive: true);
        final now = DateTime.now();
        final old = now.subtract(const Duration(days: 8));
        final young = now.subtract(const Duration(days: 6));
        final files = {
          '$_id.json': old,
          '$_id.log': old,
          '.$_id.tmp': old,
          'ffffffffffffffff.json': young,
          'ffffffffffffffff.log': young,
          'notes.txt': old,
          '0123.json': old,
        };
        for (final MapEntry(key: f, value: t) in files.entries) {
          File('$ops/$f')
            ..writeAsStringSync('x')
            ..setLastModifiedSync(t);
        }

        final argv = [
          for (final w in OperationCommands.opPrune(_placeholderDir))
            w == _placeholderDir ? ops : w,
        ];
        final result = await _runAsLogin(shell, argv);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final left = Directory(
          ops,
        ).listSync().map((e) => e.uri.pathSegments.last).toSet();
        expect(left, {
          'ffffffffffffffff.json',
          'ffffffffffffffff.log',
          'notes.txt',
          '0123.json',
        });
      });

      test('opPrune of a missing directory succeeds', () async {
        final root = await _tempDir('klab-prune-');
        final argv = [
          for (final w in OperationCommands.opPrune(_placeholderDir))
            w == _placeholderDir ? '${root.path}/klabautermann/ops' : w,
        ];
        expect((await _run(shell, argv)).exitCode, 0);
      });

      test('opCleanup removes the operation files', () async {
        final root = await _tempDir('klab-clean-');
        final ops = '${root.path}/klabautermann/ops';
        Directory(ops).createSync(recursive: true);
        for (final f in ['$_id.json', '$_id.log', 'other.json']) {
          File('$ops/$f').writeAsStringSync('x');
        }
        final argv = [
          for (final w in OperationCommands.opCleanup(_placeholderDir, [_id]))
            w.replaceFirst(_placeholderDir, ops),
        ];
        expect((await _runAsLogin(shell, argv)).exitCode, 0);
        expect(Directory(ops).listSync().map((e) => e.uri.pathSegments.last), [
          'other.json',
        ]);
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
