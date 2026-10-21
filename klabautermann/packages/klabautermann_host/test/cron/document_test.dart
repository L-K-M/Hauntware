// Crontab document tests (JOB-06, JOB-07, 03 §7.7): a crontab survives a
// parse and print byte for byte, edits change only their lines, pausing
// and resuming are idempotent and restore the job exactly, and a cron
// command splits at `%` as cron splits it.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _crontab = '''
# m h dom mon dow command
SHELL=/bin/bash
MAILTO="ops@example.com"

*/5 * * * * /usr/local/bin/poll --quiet
@daily  tar czf /backup/home.tgz /home   # nightly
\t# indented comment
0 3 * * 1 date +\\%F > /tmp/monday
''';

void main() {
  group('round trip', () {
    for (final (name, text) in [
      ('a crontab with a final newline', _crontab),
      ('one without', _crontab.substring(0, _crontab.length - 1)),
      ('an empty crontab', ''),
      ('blank lines only', '\n\n'),
      ('CRLF lines', '* * * * * a\r\n* * * * * b\r\n'),
    ]) {
      test('$name prints its own bytes', () {
        expect(CrontabDocument.parse(text).text, text);
      });
    }

    test('lines are classified as cron reads them', () {
      final doc = CrontabDocument.parse(_crontab);
      expect(doc.lines.map((l) => l.kind), [
        CrontabLineKind.comment,
        CrontabLineKind.environment,
        CrontabLineKind.environment,
        CrontabLineKind.blank,
        CrontabLineKind.job,
        CrontabLineKind.job,
        CrontabLineKind.comment,
        CrontabLineKind.job,
      ]);
    });
  });

  group('edits', () {
    test('replace, insert and remove touch only their lines', () {
      final doc = CrontabDocument.parse(_crontab)
          .replace(4, '*/10 * * * * /usr/local/bin/poll --quiet')
          .insert(5, '# added')
          .remove(3);
      final before = _crontab.split('\n');
      final after = doc.text.split('\n');
      expect(after[3], '*/10 * * * * /usr/local/bin/poll --quiet');
      expect(after[4], '# added');
      expect(after.sublist(5), before.sublist(5));
      expect(after.sublist(0, 3), before.sublist(0, 3));
    });

    test(
      'an edited crontab ends in a newline, so cron reads its last line',
      () {
        final doc = CrontabDocument.parse('* * * * * a').insert(1, '@hourly b');
        expect(doc.text, '* * * * * a\n@hourly b\n');
      },
    );

    test('a line holding a newline is refused', () {
      expect(
        () => CrontabDocument.parse(_crontab).replace(0, 'a\n* * * * * evil'),
        throwsArgumentError,
      );
    });
  });

  group('pause and resume', () {
    final at = DateTime.utc(2026, 10, 20, 16, 30);

    test(
      'pausing comments the job out with its time; resuming restores it',
      () {
        final doc = CrontabDocument.parse(_crontab);
        final paused = doc.pause(5, at: at);
        final line = paused.lines[5];
        expect(
          line.text,
          '# klabautermann:paused 2026-10-20T16:30:00Z '
          '@daily  tar czf /backup/home.tgz /home   # nightly',
        );
        expect(line.kind, CrontabLineKind.pausedJob);
        expect(line.pausedAt, at);
        expect(paused.resume(5).text, doc.text);
      },
    );

    test('both are idempotent', () {
      final paused = CrontabDocument.parse(_crontab).pause(4, at: at);
      expect(
        paused.pause(4, at: at.add(const Duration(hours: 1))).text,
        paused.text,
      );
      final resumed = paused.resume(4);
      expect(resumed.resume(4).text, resumed.text);
    });

    test('a CRLF job pauses and resumes byte for byte', () {
      final doc = CrontabDocument.parse('* * * * * a\r\n* * * * * b\r\n');
      final paused = doc.pause(0, at: at);
      final line = paused.lines[0];

      expect(line.kind, CrontabLineKind.pausedJob);
      expect(line.pausedAt, at);
      expect(line.pausedJob, '* * * * * a\r');
      expect(paused.pause(0, at: at).text, paused.text);
      expect(paused.resume(0).text, doc.text);
    });

    test('only jobs pause and only paused jobs resume', () {
      final doc = CrontabDocument.parse(_crontab);
      expect(() => doc.pause(0, at: at), throwsArgumentError);
      expect(() => doc.pause(1, at: at), throwsArgumentError);
      expect(() => doc.resume(0), throwsArgumentError);
    });
  });

  group('cron command', () {
    test('the first unescaped % starts the standard input', () {
      expect(splitCronCommand('mail -s hi root%line one%line two'), (
        command: 'mail -s hi root',
        stdin: 'line one\nline two',
      ));
    });

    test(r'\% is a literal percent sign, anywhere', () {
      expect(splitCronCommand(r'date +\%F > /tmp/d'), (
        command: 'date +%F > /tmp/d',
        stdin: null,
      ));
      expect(splitCronCommand(r'cat%100\% done'), (
        command: 'cat',
        stdin: '100% done',
      ));
    });

    test('other backslashes are kept', () {
      expect(splitCronCommand(r'echo a\nb'), (
        command: r'echo a\nb',
        stdin: null,
      ));
    });
  });

  group('run now', () {
    test('as the login user, or as another through runuser or su', () {
      expect(HostCommands.runCronCommand('backup.sh'), [
        'sh',
        '-c',
        'backup.sh',
      ]);
      expect(HostCommands.runCronCommand('backup.sh', asUser: 'www-data'), [
        'runuser',
        '-u',
        'www-data',
        '--',
        'sh',
        '-c',
        'backup.sh',
      ]);
      expect(
        HostCommands.runCronCommand(
          'backup.sh',
          asUser: 'www-data',
          tool: RunAsTool.su,
        ),
        ['su', '-s', '/bin/sh', '-c', 'backup.sh', 'www-data'],
      );
    });

    test('an empty command or a bad user is refused', () {
      expect(
        () => HostCommands.runCronCommand('  '),
        throwsA(isA<HostCommandError>()),
      );
      expect(
        () => HostCommands.runCronCommand('x', asUser: '-root'),
        throwsA(isA<HostCommandError>()),
      );
    });
  });
}
