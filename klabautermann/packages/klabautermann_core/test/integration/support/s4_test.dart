import 'package:klabautermann_core/klabautermann_core.dart' show quoteShellWord;
import 'package:test/test.dart';

import 's4.dart';

const _listSessions = 'loginctl list-sessions --no-legend --no-pager';
const _user = 'fixture';

typedef _Result = ({int? exitCode, String stdout, String stderr});

_Result _result(String stdout, {int exitCode = 0}) => (
  exitCode: exitCode,
  stdout: stdout,
  stderr: exitCode == 0 ? '' : 'query failed',
);

HostRun _host(String rows, Map<String, _Result> classes) => (line) async {
  if (line == _listSessions) return _result(rows);
  for (final entry in classes.entries) {
    if (line ==
        'loginctl show-session --property=Class --value -- '
            '${quoteShellWord(entry.key)}') {
      return entry.value;
    }
  }
  throw StateError('Unexpected fixture command: $line');
};

void main() {
  for (final rows in ['', 'No sessions.\n', '0 sessions listed.\n']) {
    test('an empty session table is logged out: ${rows.trim()}', () async {
      expect(await hasLoginSession(_host(rows, {}), _user), isFalse);
    });
  }

  test('other accounts do not prevent this account logout', () async {
    expect(
      await hasLoginSession(_host('1 1001 other seat0 tty1\n', {}), _user),
      isFalse,
    );
  });

  for (final sessionClass in ['manager', 'manager-early']) {
    test('$sessionClass is not an interactive or background login', () async {
      expect(
        await hasLoginSession(
          _host('m1 2000 $_user - 12 $sessionClass -\n', {
            'm1': _result('$sessionClass\n'),
          }),
          _user,
        ),
        isFalse,
      );
    });
  }

  test('pre-256 tables query the session class separately', () async {
    expect(
      await hasLoginSession(
        _host('c1 2000 $_user seat0 tty1\n', {'c1': _result('user\n')}),
        _user,
      ),
      isTrue,
    );
  });

  for (final sessionClass in [
    'user',
    'background',
    'background-light',
    'unknown',
    'manager-unrecognized',
    '',
  ]) {
    test('an owned $sessionClass session still prevents logout', () async {
      expect(
        await hasLoginSession(
          _host(
            'm1 2000 $_user - 12 manager -\n'
            'c2 2000 $_user - 13 $sessionClass -\n',
            {'m1': _result('manager\n'), 'c2': _result('$sessionClass\n')},
          ),
          _user,
        ),
        isTrue,
      );
    });
  }

  test(
    'a session disappearing during its class read needs a fresh poll',
    () async {
      expect(
        await hasLoginSession(
          _host('c1 2000 $_user -\n', {'c1': _result('', exitCode: 1)}),
          _user,
        ),
        isTrue,
      );
      expect(await hasLoginSession(_host('', {}), _user), isFalse);
    },
  );

  test('a failed session listing never certifies logout', () async {
    expect(
      () => hasLoginSession((_) async => _result('', exitCode: 1), _user),
      throwsStateError,
    );
  });

  test('an unrecognized session table never certifies logout', () async {
    expect(
      () => hasLoginSession(_host('unexpected table format\n', {}), _user),
      throwsStateError,
    );
  });
}
