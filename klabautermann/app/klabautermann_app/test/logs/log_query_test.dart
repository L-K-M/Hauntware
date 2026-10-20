import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/log_query.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

void main() {
  group('logPathProblem mirrors the engine\'s absolutePath rule', () {
    // The cases of klabautermann_host's request_test for
    // ArgValidators.absolutePath, plus the edges its rule decides.
    const accepted = [
      '/etc/hosts',
      '/var/log/nginx/error.log',
      '/',
      '/var/log/',
      '/var//log',
      '/var/log/.hidden',
      '/var/log/..2',
    ];
    const refused = {
      '': LogPathProblem.empty,
      'etc/hosts': LogPathProblem.notAbsolute,
      './hosts': LogPathProblem.notAbsolute,
      '~/app.log': LogPathProblem.notAbsolute,
      '/etc/../hosts': LogPathProblem.notNormalized,
      '/etc/./hosts': LogPathProblem.notNormalized,
      '/var/log/..': LogPathProblem.notNormalized,
      '/var/log/.': LogPathProblem.notNormalized,
      '/etc/\u0000hosts': LogPathProblem.nul,
    };

    for (final path in accepted) {
      test('accepts "$path"', () => expect(logPathProblem(path), isNull));
    }
    for (final MapEntry(key: path, value: problem) in refused.entries) {
      test('refuses "$path"', () => expect(logPathProblem(path), problem));
    }
    test('offers only paths it accepts', () {
      expect(kCommonLogPaths.map(logPathProblem), everyElement(isNull));
    });
  });

  group('LogQuery', () {
    final now = DateTime.utc(2026, 10, 15, 12);

    test('maps the journal filters, leaving unset ones open', () {
      final source =
          const LogQuery(
                unit: 'nginx.service',
                priority: LogPriority.warning,
                currentBootOnly: true,
                range: LogTimeRange.lastHour,
              ).toSource(now)
              as JournalLogSource;

      expect(source.unit, 'nginx.service');
      expect(source.identifier, isNull);
      expect(source.priority, LogPriority.warning);
      expect(source.currentBootOnly, isTrue);
      expect(source.since, DateTime.utc(2026, 10, 15, 11));
      expect(source.until, isNull);
    });

    test('a file needs a path the engine accepts', () {
      const file = LogQuery(source: LogSourceKind.file);

      expect(file.ready, isFalse);
      expect(file.withPath('var/log/syslog').ready, isFalse);
      final tail = file.withPath('/var/log/syslog');
      expect(tail.ready, isTrue);
      expect((tail.toSource(now) as FileLogSource).path, '/var/log/syslog');
    });

    test('counts the filters a phone\'s Filters button shows', () {
      expect(const LogQuery().filterCount, 0);
      expect(
        const LogQuery(
          unit: 'a.service',
          range: LogTimeRange.last7Days,
        ).filterCount,
        2,
      );
      expect(const LogQuery(source: LogSourceKind.kernel).filterCount, 0);
      expect(
        const LogQuery(source: LogSourceKind.file).withPath('/x').filterCount,
        1,
      );
    });
  });

  group('server search and boots (LOG-06, LOG-09)', () {
    test('serverLogPattern escapes plain text and ignores case by (?i)', () {
      expect(
        serverLogPattern('a.b (c)', regex: false, caseSensitive: false),
        r'(?i)a\.b \(c\)',
      );
      expect(serverLogPattern('a.b', regex: true, caseSensitive: true), 'a.b');
    });

    final past = JournalBootEntry(offset: -1, id: 'a' * 32);

    test('the journal reads the pattern and the past boot by its ID', () {
      final query = const LogQuery().withGrep('(?i)oom').withBoot(past);
      final source = query.toSource(DateTime.utc(2026)) as JournalLogSource;
      expect(source.grep, '(?i)oom');
      expect(source.boot, JournalBoot.id('a' * 32));
      expect(source.currentBootOnly, isFalse);
      expect(query.followable, isFalse);
      expect(query.filterCount, 1);
    });

    test('the kernel log reads the past boot; this boot clears it', () {
      final kernel = const LogQuery()
          .withSource(LogSourceKind.kernel)
          .withBoot(past);
      expect(
        (kernel.toSource(DateTime.utc(2026)) as KernelLogSource).boot,
        JournalBoot.id('a' * 32),
      );

      final current = kernel.withBoot(null, current: true);
      expect(current.pastBoot, isNull);
      expect(current.currentBootOnly, isTrue);
      expect(current.followable, isTrue);
      expect(
        (current.toSource(DateTime.utc(2026)) as KernelLogSource).boot,
        isNull,
      );
    });

    test('no pattern reaches the engine as none', () {
      final source =
          const LogQuery().toSource(DateTime.utc(2026)) as JournalLogSource;
      expect(source.grep, isNull);
      expect(source.boot, isNull);
    });
  });
}
