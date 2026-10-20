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
    test('a boot by offset or ID replaces the bare -b', () {
      expect(HostCommands.journalctl(boot: const JournalBoot.offset(-1)), [
        'journalctl',
        '-o',
        'json',
        '--no-pager',
        '-b',
        '-1',
      ]);
      const id = '0123456789abcdef0123456789abcdef';
      expect(
        HostCommands.journalctl(kernel: true, boot: const JournalBoot.id(id)),
        ['journalctl', '-o', 'json', '--no-pager', '-k', '-b', id],
      );
      for (final bad in [
        const JournalBoot.offset(1),
        const JournalBoot.id('0123'),
        const JournalBoot.id('-b; id'),
      ]) {
        expect(
          () => HostCommands.journalctl(boot: bad),
          throwsA(isA<HostCommandError>()),
        );
      }
      expect(
        () => HostCommands.journalctl(
          currentBoot: true,
          boot: const JournalBoot.offset(0),
        ),
        throwsA(isA<HostCommandError>()),
      );
    });

    test('filters append in a fixed order and JSON is always set', () {
      expect(
        HostCommands.journalctl(
          unit: 'sshd.service',
          identifier: 'sshd',
          currentBoot: true,
          priority: 'warning',
          until: DateTime.utc(2026, 10, 15, 12),
          cursor: 's=abc;i=1',
          lines: 500,
          order: JournalOrder.newestFirst,
          grep: 'denied',
        ),
        [
          'journalctl',
          '-o',
          'json',
          '--no-pager',
          '-b',
          '-u',
          'sshd.service',
          '-t',
          'sshd',
          '-p',
          'warning',
          '--until=@1792065600',
          '--after-cursor=s=abc;i=1',
          '-n',
          '500',
          '-r',
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

    test('the kernel log is -k -b, and a follow is -f', () {
      expect(
        HostCommands.journalctl(
          kernel: true,
          currentBoot: true,
          lines: 0,
          order: JournalOrder.follow,
        ),
        ['journalctl', '-o', 'json', '--no-pager', '-k', '-b', '-n', '0', '-f'],
      );
    });

    test('the kernel log takes identifier and unit filters', () {
      // journald names kernel-transport records (SYSLOG_IDENTIFIER=kernel,
      // or the `systemd[1]:` prefix of a line written to /dev/kmsg) and
      // gives the lines it wrote there itself its own unit.
      expect(
        HostCommands.journalctl(
          kernel: true,
          unit: 'systemd-journald.service',
          identifier: 'systemd',
        ).sublist(4),
        ['-k', '-b', '-u', 'systemd-journald.service', '-t', 'systemd'],
      );
    });

    test('times are epoch seconds, with microseconds when present', () {
      final since = DateTime.fromMicrosecondsSinceEpoch(
        1792065600000042,
        isUtc: true,
      );
      expect(
        HostCommands.journalctl(since: since),
        contains('--since=@1792065600.000042'),
      );
      // The instant counts, not the zone it is written in.
      expect(
        HostCommands.journalctl(since: DateTime.utc(1970, 1, 1, 0, 0, 5)),
        contains('--since=@5'),
      );
    });

    test('combinations journalctl refuses and a bounded follow fail', () {
      final t = DateTime.utc(2026, 10, 15);
      for (final build in <void Function()>[
        () => HostCommands.journalctl(since: t, cursor: 's=1'),
        () => HostCommands.journalctl(until: t, order: JournalOrder.follow),
        () => HostCommands.journalctl(
          since: t.add(const Duration(seconds: 1)),
          until: t,
        ),
        () => HostCommands.journalctl(since: DateTime.utc(1969, 12, 31)),
      ]) {
        expect(build, throwsA(isA<HostCommandError>()));
      }
    });

    test('hostile filters are refused before any argv exists', () {
      for (final build in <void Function()>[
        () => HostCommands.journalctl(priority: 'nope'),
        () => HostCommands.journalctl(cursor: 'not a cursor'),
        () => HostCommands.journalctl(cursor: 's=1;\$(id)'),
        () => HostCommands.journalctl(unit: 'a.service; reboot'),
        () => HostCommands.journalctl(unit: '-a.service\n'),
        () => HostCommands.journalctl(identifier: ''),
        () => HostCommands.journalctl(identifier: 'cron\nx'),
        () => HostCommands.journalctl(identifier: 'cron\x1b[2J'),
        () => HostCommands.journalctl(grep: 'a\x00b'),
        () => HostCommands.journalctl(lines: -1),
      ]) {
        expect(build, throwsA(isA<HostCommandError>()));
      }
    });

    test('a cursor journalctl printed feeds back as --after-cursor', () {
      final cursor = parseJournalLine(
        '{"__CURSOR":"s=7b1d3c2a;i=1a2b;b=0f1e2d3c;m=2dc6c0;'
        't=63a1b2c3d4e5f;x=9c8b7a6f"}',
      )!.cursor!;
      expect(
        HostCommands.journalctl(cursor: cursor, order: JournalOrder.follow),
        contains('--after-cursor=$cursor'),
      );
    });

    test('a follow after a cursor prints every record after it', () {
      // Up to systemd 253, the 10 lines -f implies end the first pass.
      expect(
        HostCommands.journalctl(cursor: 's=1', order: JournalOrder.follow),
        [
          ...['journalctl', '-o', 'json', '--no-pager'],
          ...['--after-cursor=s=1', '--no-tail', '-f'],
        ],
      );
      expect(
        HostCommands.journalctl(cursor: 's=1', order: JournalOrder.newestFirst),
        isNot(contains('--no-tail')),
      );
      expect(
        () => HostCommands.journalctl(
          cursor: 's=1',
          lines: 10,
          order: JournalOrder.follow,
        ),
        throwsA(isA<HostCommandError>()),
      );
    });

    test('shell syntax in a filter stays one argument', () {
      const identifier = r"x'; rm -rf / #$(id)`id`";
      final argv = HostCommands.journalctl(identifier: identifier);
      expect(argv.sublist(argv.indexOf('-t')), ['-t', identifier]);
    });
  });

  group('dmesg and tail', () {
    test('dmesg asks for decoded JSON and takes nothing else', () {
      expect(HostCommands.dmesgJson(), ['dmesg', '--json', '--decode']);
    });

    test('tail ends its options before the path', () {
      expect(HostCommands.tail('/var/log/syslog', lines: 500), [
        'tail',
        '-n',
        '500',
        '--',
        '/var/log/syslog',
      ]);
      expect(HostCommands.tail("/var/log/a b'\$(id)", lines: 0, follow: true), [
        'tail',
        '-n',
        '0',
        '-F',
        '--',
        "/var/log/a b'\$(id)",
      ]);
    });

    test('tail refuses relative, unnormalized and NUL paths', () {
      for (final path in [
        '',
        'var/log/syslog',
        '-n1',
        '/var/log/../../etc/shadow',
        '/var/log/./syslog',
        '/var/log/.',
        '/var/log/a\x00b',
      ]) {
        expect(
          () => HostCommands.tail(path, lines: 10),
          throwsA(isA<HostCommandError>()),
          reason: path,
        );
      }
      expect(
        () => HostCommands.tail('/var/log/syslog', lines: -1),
        throwsA(isA<HostCommandError>()),
      );
    });
  });

  group('commandLine', () {
    String quote(String w) => '<$w>';

    test('exports the sampler environment and execs the argv', () {
      expect(
        HostCommands.commandLine(['journalctl', '-k'], quote: quote),
        '<sh> <-c> <export LC_ALL=C TZ=UTC SYSTEMD_PAGER= NO_COLOR=1; '
        'exec "\$@"> <sh> <journalctl> <-k>',
      );
    });

    test('C.UTF-8 replaces C only when asked', () {
      expect(
        HostCommands.commandLine(
          ['tail', '--', '/x'],
          quote: quote,
          locale: CommandLocale.cUtf8,
        ),
        contains('<export LC_ALL=C.UTF-8 TZ=UTC '),
      );
    });

    test('an empty argv is refused', () {
      expect(
        () => HostCommands.commandLine(const [], quote: quote),
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
          '(unset TZ; systemd-analyze calendar --iterations=3 -- "\$1")',
          'hws-cal',
          'daily',
        ]);
      },
    );

    test('onCalendar passes a leading-dash expression after --', () {
      // A host-sent `OnCalendar=--version` must not become an option.
      final argv = HostCommands.onCalendar('--version', iterations: 1);
      expect(argv.sublist(2), [
        '(unset TZ; systemd-analyze calendar --iterations=1 -- "\$1")',
        'hws-cal',
        '--version',
      ]);
    });

    test('onCalendar drops --iterations below systemd 242', () {
      expect(
        HostCommands.onCalendar('daily', iterations: 3, systemdMajor: 239)[2],
        '(unset TZ; systemd-analyze calendar -- "\$1")',
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

  group('guarded kill, timers and the crontab spool', () {
    test('guardedKill passes pid, ticks and signal as parameters', () {
      final argv = HostCommands.guardedKill(4242, 987654, KillSignal.sigterm);
      expect(argv.take(2), ['sh', '-c']);
      expect(argv.skip(3), ['klabautermann-kill', '4242', '987654', 'TERM']);
      // The script is constant: nothing interpolates into it.
      expect(HostCommands.guardedKill(1, 0, KillSignal.sigkill)[2], argv[2]);
      expect(argv[2], contains(r'kill -s "$3" "$1"'));
    });

    test('guardedKill refuses a non-positive pid and negative ticks', () {
      for (final build in <void Function()>[
        () => HostCommands.guardedKill(0, 1, KillSignal.sigterm),
        () => HostCommands.guardedKill(-1, 1, KillSignal.sigterm),
        () => HostCommands.guardedKill(10, -1, KillSignal.sigterm),
      ]) {
        expect(build, throwsA(isA<HostCommandError>()));
      }
    });

    test('every kill signal passes the signal-name validator', () {
      for (final s in KillSignal.values) {
        expect(ArgValidators.signalName(s.wireName), isNull, reason: s.name);
        expect(s.wireName, matches(RegExp(r'^[A-Z0-9]+$')));
      }
    });

    test('guarded kill outcomes map exit codes both ways', () {
      expect(
        GuardedKillOutcome.values.map((o) => o.exitCode).toSet(),
        hasLength(GuardedKillOutcome.values.length),
      );
      for (final o in GuardedKillOutcome.values) {
        expect(GuardedKillOutcome.fromExitCode(o.exitCode), o);
      }
      expect(GuardedKillOutcome.reused.exitCode, kGuardedKillReused);
      for (final code in [1, 2, 126, 127, 255]) {
        expect(GuardedKillOutcome.fromExitCode(code), isNull);
      }
    });

    test('timerStart starts the activated unit with the guards', () {
      expect(HostCommands.timerStart('logrotate.service'), [
        'systemctl',
        '--no-ask-password',
        'start',
        '--',
        'logrotate.service',
      ]);
      for (final unit in ['logrotate.timer', 'a; reboot', '']) {
        expect(
          () => HostCommands.timerStart(unit),
          throwsA(isA<HostCommandError>()),
          reason: unit,
        );
      }
    });

    test('crontabSpoolList tries the Debian spool before the RHEL one', () {
      final argv = HostCommands.crontabSpoolList();
      expect(argv.take(2), ['sh', '-c']);
      expect(argv.skip(3), [
        'klabautermann-spool',
        '/var/spool/cron/crontabs',
        '/var/spool/cron',
      ]);
      expect(
        () => HostCommands.crontabSpoolList(spools: const []),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.crontabSpoolList(spools: const ['spool']),
        throwsA(isA<HostCommandError>()),
      );
    });

    test('parseCrontabSpool keeps valid user names and counts the rest', () {
      final spool = parseCrontabSpool(
        '/var/spool/cron/crontabs\nroot\nalice\ntmp.XyZ123\nBob\n',
      )!;
      expect(spool.directory, '/var/spool/cron/crontabs');
      expect(spool.users, ['root', 'alice']);
      expect(spool.skipped, 2);
      expect(parseCrontabSpool('/var/spool/cron\n')!.users, isEmpty);
      final blank = parseCrontabSpool('/var/spool/cron/crontabs\nroot\n\n\n')!;
      expect(blank.users, ['root']);
      expect(blank.skipped, 0);
      expect(parseCrontabSpool(''), isNull);
      expect(parseCrontabSpool('root\nalice\n'), isNull);
    });
  });

  test('re-validation reads validate their target (03 §8.5)', () {
    expect(HostCommands.startTicks(42).last, '42');
    expect(() => HostCommands.startTicks(0), throwsA(isA<HostCommandError>()));
    expect(HostCommands.unitLoadState('nginx.service'), [
      'systemctl',
      'show',
      '--property=LoadState',
      '--value',
      '--',
      'nginx.service',
    ]);
    expect(
      () => HostCommands.unitLoadState('-x'),
      throwsA(isA<HostCommandError>()),
    );
  });

  group('log sources', () {
    test('the boot list asks for JSON only where journalctl has it', () {
      expect(HostCommands.journalBoots(JournalBootsFormat.json), [
        'journalctl',
        '--list-boots',
        '--no-pager',
        '-o',
        'json',
      ]);
      expect(HostCommands.journalBoots(JournalBootsFormat.text), [
        'journalctl',
        '--list-boots',
        '--no-pager',
      ]);
    });

    test('a rotated log reads through the decompressor its name asks for', () {
      final gz = HostCommands.rotatedTail('/var/log/syslog.2.gz', lines: 50);
      expect(gz.sublist(4), ['zcat', '/var/log/syslog.2.gz', '50']);
      final xz = HostCommands.rotatedTail('/var/log/messages.xz', lines: 5);
      expect(xz.sublist(4), ['xzcat', '/var/log/messages.xz', '5']);
      expect(
        () => HostCommands.rotatedTail('/var/log/syslog', lines: 5),
        throwsA(isA<HostCommandError>()),
        reason: 'an uncompressed log reads through tail',
      );
      expect(
        () => HostCommands.rotatedTail('../etc/shadow.gz', lines: 5),
        throwsA(isA<HostCommandError>()),
      );
    });
  });
}
