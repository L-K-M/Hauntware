// Spike S3's case driver (tool/src/elevation_matrix.dart) against a
// scripted sudo: what it records for each password, the rung-4 retry,
// that no password reaches the evidence, and check mode's comparison.
import 'dart:convert';

import 'package:seance_core/seance_core.dart' show RemoteCommandResult;
import 'package:test/test.dart';

import '../../tool/src/elevation_matrix.dart';

const _password = 'right-horse-battery';
const _wrong = 'wrong-horse-battery';

/// A sudo 1.9 account with password sudo. With [cachesNothing] the
/// prelude's `sudo -n` finds no credential after `sudo -v`, as under
/// `timestamp_timeout=0`, and only the rung-4 `sudo -S` runs the command.
/// [leak] echoes the stdin into stderr, which a real tool never does.
CommandRunner _sudo({bool cachesNothing = false, bool leak = false}) =>
    (command, stdin) async {
      final input = utf8.decode(stdin);
      final firstLine = input.split('\n').first;
      final rest = input.contains('\n')
          ? input.substring(input.indexOf('\n') + 1)
          : '';
      RemoteCommandResult answer({
        String stdout = '',
        String stderr = '',
        int exit = 0,
      }) => RemoteCommandResult(
        stdout: stdout,
        stderr: leak ? '$stderr$input' : stderr,
        exitCode: exit,
      );
      final ran = answer(stdout: command.endsWith("'cat'") ? rest : '0\n');
      const rejected =
          'Sorry, try again.\nsudo: 1 incorrect password attempt\n';

      switch (command) {
        case 'id -u':
          return answer(stdout: '1000\n');
        case 'sudo -V 2>/dev/null | head -n 1':
          return answer(stdout: 'Sudo version 1.9.16p2\n');
        case 'sudo -n true' || 'sudo -n -l':
          return answer(stderr: 'sudo: a password is required\n', exit: 1);
        case 'command -v doas':
          return answer(exit: 1);
        case 'command -V printf':
          return answer(stdout: 'printf is a shell builtin\n');
      }
      if (command.contains(' elevate ')) {
        if (firstLine != _password) return answer(stderr: rejected, exit: 125);
        if (cachesNothing) {
          return answer(stderr: 'sudo: a password is required\n', exit: 1);
        }
        return ran;
      }
      if (command.contains("sudo -S -p ''")) {
        return firstLine == _password ? ran : answer(stderr: rejected, exit: 1);
      }
      throw StateError('unscripted command: $command');
    };

Future<Map<String, Object?>> _case(CommandRunner runner) => runElevationCase(
  name: 'scripted',
  description: 'a scripted sudo',
  runner: runner,
  password: _password,
  wrongPassword: _wrong,
);

Map<String, Object?> _outcome(Map<String, Object?> evidence, String name) =>
    (evidence['outcomes']! as Map<String, Object?>)[name]!
        as Map<String, Object?>;

void main() {
  test('records each password through the prelude', () async {
    final evidence = await _case(_sudo());

    expect(evidence['probe'], containsPair('printfIsBuiltin', true));
    expect(
      evidence['probe'],
      containsPair('sudoVersionLine', 'Sudo version 1.9.16p2'),
    );
    expect(_outcome(evidence, 'rightPassword'), {
      ...{'outcome': 'ran', 'exit': 0, 'commands': 1},
      'stdout': '0\n',
      'stderr': '',
      'calls': hasLength(1),
    });
    expect(
      _outcome(evidence, 'wrongPassword'),
      containsPair('kind', 'wrongPassword'),
    );
    expect(_outcome(evidence, 'noPassword'), {
      ...{'outcome': 'refused', 'kind': 'passwordRequired', 'commands': 0},
      'refusalStderr': '',
      'calls': isEmpty,
    });
    expect(evidence['stdinPayloadEchoed'], isTrue);
    expect(evidence['ranAsRoot'], isTrue);
    expect(
      [for (final c in evidence['rawCalls']! as List) (c as Map)['command']],
      ['sudo -n -l'],
    );
  });

  test('counts the rung-4 retry when the host caches nothing', () async {
    final evidence = await _case(_sudo(cachesNothing: true));

    final right = _outcome(evidence, 'rightPassword');
    expect(right, containsPair('commands', 2));
    expect(right, containsPair('outcome', 'ran'));
    final calls = right['calls']! as List;
    expect((calls.last as Map)['command'], contains("sudo -S -p ''"));
    expect(evidence['stdinPayloadEchoed'], isTrue);
  });

  test('never writes a password into the evidence', () async {
    final text = jsonEncode(await _case(_sudo()));
    expect(text, isNot(contains(_password)));
    expect(text, isNot(contains(_wrong)));

    await expectLater(_case(_sudo(leak: true)), throwsStateError);
    expect(
      () => runElevationCase(
        name: 'same',
        description: '',
        runner: _sudo(),
        password: _password,
        wrongPassword: _password,
      ),
      throwsArgumentError,
    );
  });

  group('compareElevationCases', () {
    test(
      'holds outcomes and probe facts, not texts or the version line',
      () async {
        final committed = await _case(_sudo());
        final again = jsonDecode(jsonEncode(committed)) as Map<String, Object?>;
        (again['probe']! as Map)['sudoVersionLine'] = 'Sudo version 1.9.17';
        _outcome(again, 'wrongPassword')['refusalStderr'] = 'other text\n';
        expect(compareElevationCases(committed, again), isEmpty);
      },
    );

    test('names a changed outcome, probe fact or flag', () async {
      final committed = await _case(_sudo());
      final retried = await _case(_sudo(cachesNothing: true));
      expect(compareElevationCases(committed, retried), [
        startsWith('outcomes.rightPassword: '),
        startsWith('outcomes.stdinAfterPassword: '),
      ]);

      final changed = jsonDecode(jsonEncode(committed)) as Map<String, Object?>;
      (changed['probe']! as Map)['printfIsBuiltin'] = false;
      changed['ranAsRoot'] = false;
      (changed['outcomes']! as Map).remove('noPassword');
      expect(compareElevationCases(committed, changed), [
        startsWith('probe.printfIsBuiltin: '),
        'outcomes.noPassword: committed '
            '{"outcome":"refused","kind":"passwordRequired","commands":0}, '
            'captured null',
        startsWith('ranAsRoot: '),
      ]);
    });
  });
}
