// Detached-operation builder tests (03 §7.17, §8.11): each runner row's
// launch argv, the directory rules, and the refusals before any argv
// exists. The real-shell behaviour is in
// test/integration/command_scripts_shell_test.dart.
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _id = '0123456789abcdef';
const _userDir = '/home/klab/.local/state/klabautermann/ops';

List<String> _launch(
  DetachedRunner runner, {
  String? dir,
  String id = _id,
  int uid = 1000,
  List<String> argv = const ['docker', 'compose', 'pull'],
}) => OperationCommands.detachedLaunch(
  runner,
  dir: dir ?? (runner.runsAsRoot ? kRootOpsDir : _userDir),
  id: id,
  uid: uid,
  argv: argv,
);

/// The wrapper's words from `/bin/sh` on, after the runner's own.
List<String> _wrapped(List<String> argv) =>
    argv.sublist(argv.indexOf('/bin/sh'));

void main() {
  group('detachedLaunch', () {
    test('the systemd rows name the transient unit and collect it', () {
      final unit = 'klabautermann-op-$_id.service';
      for (final (runner, extra) in [
        (DetachedRunner.rootSystemd, const <String>[]),
        (DetachedRunner.loginSystemdUid, const ['--uid=1000']),
        (DetachedRunner.loginSystemdUser, const ['--user']),
      ]) {
        final argv = _launch(runner);
        expect(argv.sublist(0, argv.indexOf('/bin/sh')), [
          'systemd-run',
          ...extra,
          '--unit=$unit',
          '--collect',
          '--quiet',
          '--',
        ], reason: runner.name);
        final dir = runner.runsAsRoot ? kRootOpsDir : _userDir;
        expect(_wrapped(argv).skip(3), [
          'klabautermann-op',
          dir,
          _id,
          '1000',
          unit,
          '--',
          'docker',
          'compose',
          'pull',
        ], reason: runner.name);
      }
    });

    test('the systemd rows escape every dollar sign, which a service '
        "manager would otherwise expand in the unit's command line", () {
      final setsid = OperationCommands.detachedLaunch(
        DetachedRunner.loginSetsid,
        dir: _userDir,
        id: _id,
        uid: 1000,
        argv: const ['echo', r'$HOME', r'${PATH}'],
      );
      final script = _wrapped(setsid)[2];
      expect(script, contains(r'$'));
      for (final runner in [
        DetachedRunner.rootSystemd,
        DetachedRunner.loginSystemdUid,
        DetachedRunner.loginSystemdUser,
      ]) {
        final argv = OperationCommands.detachedLaunch(
          runner,
          dir: runner.runsAsRoot ? kRootOpsDir : _userDir,
          id: _id,
          uid: 1000,
          argv: const ['echo', r'$HOME', r'${PATH}'],
        );
        final wrapped = _wrapped(argv);
        expect(wrapped[2], script.replaceAll(r'$', r'$$'), reason: runner.name);
        expect(wrapped.sublist(wrapped.length - 2), [r'$$HOME', r'$${PATH}']);
      }
    });

    test('the setsid rows go through the launcher and record no unit', () {
      for (final runner in [
        DetachedRunner.rootSetsid,
        DetachedRunner.loginSetsid,
      ]) {
        final argv = _launch(runner);
        expect(argv.take(2), ['sh', '-c']);
        expect(
          argv[2],
          startsWith('setsid "\$@" </dev/null >/dev/null 2>&1 &'),
        );
        expect(argv[3], 'klabautermann-launch');
        expect(_wrapped(argv).skip(3).take(6), [
          'klabautermann-op',
          runner.runsAsRoot ? kRootOpsDir : _userDir,
          _id,
          '1000',
          '-',
          '--',
        ]);
      }
    });

    test('every row runs the same constant wrapper', () {
      // The systemd rows carry it escaped for the service manager.
      String script(DetachedRunner r) {
        final word = _wrapped(_launch(r))[2];
        return r.transientUnit ? word.replaceAll(r'$$', r'$') : word;
      }

      final scripts = {
        for (final r in DetachedRunner.values) script(r),
        _wrapped(
          _launch(DetachedRunner.loginSetsid, id: 'ffffffffffffffff'),
        )[2],
      };
      expect(scripts, hasLength(1));
      expect(scripts.single, contains('mv -f "\$t" "\$f"'));
    });

    test('which rows need elevation and run as root', () {
      expect(DetachedRunner.values.where((r) => r.elevated), [
        DetachedRunner.rootSystemd,
        DetachedRunner.rootSetsid,
        DetachedRunner.loginSystemdUid,
      ]);
      expect(DetachedRunner.values.where((r) => r.runsAsRoot), [
        DetachedRunner.rootSystemd,
        DetachedRunner.rootSetsid,
      ]);
    });

    test('root rows record only in the root directory, others never', () {
      for (final runner in DetachedRunner.values) {
        final wrong = runner.runsAsRoot ? _userDir : kRootOpsDir;
        expect(
          () => _launch(runner, dir: wrong),
          throwsA(isA<HostCommandError>()),
          reason: runner.name,
        );
      }
    });

    test('a directory that is not an operation directory is refused', () {
      for (final dir in [
        '',
        'home/klab/.local/state/klabautermann/ops',
        '/klabautermann/ops',
        '/home/klab/.local/state/klabautermann/ops/',
        '/home/klab/.local/state/klabautermann',
        '/home/klab/../root/.local/state/klabautermann/ops',
        '/home/klab/./klabautermann/ops',
        '/home//klabautermann/ops',
        '/tmp/x/klabautermann/ops',
        '/var/tmp/x/klabautermann/ops',
        '/home/a\nb/klabautermann/ops',
        '/home/a\x00b/klabautermann/ops',
      ]) {
        expect(
          () => _launch(DetachedRunner.loginSetsid, dir: dir),
          throwsA(isA<HostCommandError>()),
          reason: dir,
        );
      }
    });

    test('bad ids, uids and commands are refused', () {
      for (final build in <void Function()>[
        () => _launch(DetachedRunner.loginSetsid, id: '0123456789ABCDEF'),
        () => _launch(DetachedRunner.loginSetsid, id: '0123456789abcde'),
        () => _launch(DetachedRunner.loginSetsid, id: '0123456789abcdef0'),
        () => _launch(DetachedRunner.loginSetsid, id: '../../etc/passwd'),
        () => _launch(DetachedRunner.loginSetsid, uid: -1),
        // systemd-run --uid=0 would run a root unit that records in the
        // user directory.
        () => _launch(DetachedRunner.loginSystemdUid, uid: 0),
        () => _launch(DetachedRunner.loginSetsid, argv: const []),
        () => _launch(DetachedRunner.loginSetsid, argv: const ['']),
        () => _launch(DetachedRunner.loginSetsid, argv: const ['-p', 'x']),
        () => _launch(DetachedRunner.loginSetsid, argv: const ['a', 'b\x00']),
      ]) {
        expect(build, throwsA(isA<HostCommandError>()));
      }
    });

    test('shell syntax in the command stays one word each', () {
      const hostile = [r'$(id)', "'; rm -rf / #", '`id`', 'a b', '--'];
      final argv = _launch(
        DetachedRunner.loginSetsid,
        argv: const ['printf', '%s', ...hostile],
      );
      expect(argv.sublist(argv.length - hostile.length), hostile);
    });
  });

  group('operation ids', () {
    test('generateOpId makes 16 lowercase hex digits', () {
      final random = Random(7);
      for (var i = 0; i < 50; i++) {
        final id = generateOpId(random);
        expect(validateOpId(id), isNull, reason: id);
      }
      expect(opUnitName(_id), 'klabautermann-op-$_id.service');
      expect(ArgValidators.unitName(opUnitName(_id)), isNull);
    });

    test('validateOpId refuses other shapes', () {
      for (final id in ['', 'abc', '0123456789ABCDEF', '0123456789abcdeg']) {
        expect(validateOpId(id), isNotNull, reason: id);
      }
    });
  });

  group('cleanup and prune', () {
    test('opCleanup removes record, log and temp file of each id', () {
      expect(OperationCommands.opCleanup(kRootOpsDir, [_id]), [
        'rm',
        '-f',
        '--',
        '$kRootOpsDir/$_id.json',
        '$kRootOpsDir/$_id.log',
        '$kRootOpsDir/.$_id.tmp',
      ]);
      expect(
        OperationCommands.opCleanup(_userDir, [_id, 'ffffffffffffffff']),
        hasLength(3 + 6),
      );
    });

    test('opCleanup refuses no ids, bad ids and foreign directories', () {
      for (final build in <void Function()>[
        () => OperationCommands.opCleanup(_userDir, const []),
        () => OperationCommands.opCleanup(_userDir, const ['*']),
        () => OperationCommands.opCleanup(_userDir, const ['../x']),
        () => OperationCommands.opCleanup('/etc', const [_id]),
        () =>
            OperationCommands.opCleanup('/tmp/klabautermann/ops', const [_id]),
      ]) {
        expect(build, throwsA(isA<HostCommandError>()));
      }
    });

    test('opPrune passes the directory and whole days less one', () {
      final argv = OperationCommands.opPrune(_userDir);
      expect(argv.take(2), ['sh', '-c']);
      expect(argv.skip(3), ['klabautermann-prune', _userDir, '6']);
      expect(OperationCommands.opPrune(kRootOpsDir, days: 1).last, '0');
      expect(
        () => OperationCommands.opPrune(_userDir, days: 0),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => OperationCommands.opPrune('/'),
        throwsA(isA<HostCommandError>()),
      );
    });
  });

  test('record fields and states are the documented names', () {
    expect(
      [
        OpRecordField.version,
        OpRecordField.id,
        OpRecordField.state,
        OpRecordField.pid,
        OpRecordField.startTicks,
        OpRecordField.unit,
        OpRecordField.exit,
        OpRecordField.startedAt,
        OpRecordField.endedAt,
      ],
      [
        'v',
        'id',
        'state',
        'pid',
        'startTicks',
        'unit',
        'exit',
        'startedAt',
        'endedAt',
      ],
    );
    expect(OpRecordState.values.map((s) => s.wireName), ['running', 'done']);
  });
}
