// Command builder and validator tests (03 §8.8): every builder returns an
// argv list after validating, refuses bad arguments before producing text,
// and quotes nothing (the caller quotes).
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('systemctl', () {
    test('each verb builds an argv with --no-ask-password and --', () {
      for (final v in SystemctlVerb.values) {
        expect(HostCommands.systemctl(v, 'nginx.service'), [
          'systemctl',
          '--no-ask-password',
          v.name,
          '--',
          'nginx.service',
        ]);
      }
    });

    test('an invalid unit name is refused with the offending argument', () {
      expect(
        () => HostCommands.systemctl(SystemctlVerb.start, 'nginx; rm -rf /'),
        throwsA(
          isA<HostCommandError>().having(
            (e) => e.argument,
            'argument',
            'nginx; rm -rf /',
          ),
        ),
      );
    });
  });

  group('journalctl', () {
    test('filters append in a fixed order and JSON is always set', () {
      expect(
        HostCommands.journalctl(
          unit: 'sshd.service',
          priority: 'warning',
          since: '1 hour ago',
          cursor: 's=abc;i=1',
          lines: 500,
          grep: 'denied',
        ),
        [
          'journalctl',
          '-o',
          'json',
          '--no-pager',
          '-u',
          'sshd.service',
          '-p',
          'warning',
          '--since',
          '1 hour ago',
          '--after-cursor=s=abc;i=1',
          '-n',
          '500',
          '-g',
          'denied',
        ],
      );
    });

    test('an empty builder keeps only the JSON preamble', () {
      expect(HostCommands.journalctl(), [
        'journalctl',
        '-o',
        'json',
        '--no-pager',
      ]);
    });

    test('bad priority, cursor, since and lines are refused', () {
      expect(
        () => HostCommands.journalctl(priority: 'nope'),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.journalctl(cursor: 'not a cursor'),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.journalctl(since: 'a\nb'),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.journalctl(lines: -1),
        throwsA(isA<HostCommandError>()),
      );
    });
  });

  group('other builders', () {
    test('crontab -l -u validates the user name', () {
      expect(HostCommands.crontabList('root'), ['crontab', '-l', '-u', 'root']);
      expect(
        () => HostCommands.crontabList('Root'),
        throwsA(isA<HostCommandError>()),
      );
    });

    test('df fixes its flags and validates the path', () {
      expect(HostCommands.df(), ['df', '-PT', '-B1']);
      expect(HostCommands.df(inodes: true), ['df', '-Pi']);
      expect(HostCommands.df(path: '/mnt/backup'), [
        'df',
        '-PT',
        '-B1',
        '/mnt/backup',
      ]);
      expect(
        () => HostCommands.df(path: 'relative'),
        throwsA(isA<HostCommandError>()),
      );
    });

    test('ss is fixed', () {
      expect(HostCommands.ss(), ['ss', '-tulpn']);
    });

    test(
      'onCalendar clears TZ in a subshell and passes the expression as \$1',
      () {
        expect(HostCommands.onCalendar('daily', iterations: 3), [
          'sh',
          '-c',
          '(unset TZ; systemd-analyze calendar --iterations=3 "\$1")',
          'hws-cal',
          'daily',
        ]);
      },
    );

    test('onCalendar drops --iterations below systemd 242', () {
      expect(
        HostCommands.onCalendar('daily', iterations: 3, systemdMajor: 239)[2],
        '(unset TZ; systemd-analyze calendar "\$1")',
      );
    });

    test('onCalendar refuses a bad expression and a bad iteration count', () {
      expect(
        () => HostCommands.onCalendar('daily\nrm', iterations: 1),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.onCalendar('daily', iterations: 0),
        throwsA(isA<HostCommandError>()),
      );
    });
  });
}
