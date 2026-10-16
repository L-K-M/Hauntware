import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/ui/jobs_view.dart';
import 'package:klabautermann_host/klabautermann_host.dart';

import 'support/charts.dart' show loadChartDateFormats;
import 'support/jobs.dart';

final _l10n = AppLocalizationsEn();

String _cron(String text, {String? zone}) =>
    scheduleText(_l10n, CronSchedule.parse(text, timeZone: zone)!);

/// JOB-02's schedules in words (03 §7.7, A11Y-05): every
/// ScheduleDescription variant through its ARB templates, a cron schedule
/// worded from its fields as written, and runs on the server's clock across
/// a DST change.
void main() {
  setUpAll(loadChartDateFormats);

  group('a cron schedule reads its fields as written', () {
    const cases = {
      '* * * * *': 'Runs every minute',
      '*/15 * * * *': 'Runs every 15 minutes',
      '0,15,30,45 * * * *': 'Runs at minutes 0, 15, 30 and 45, every hour',
      '0-30/10 * * * *':
          'Runs every 10 minutes from minute 0 to 30, every hour',
      '30 2 * * *': 'Runs at 2:30 AM',
      '0 6,18 * * 1-5': 'Runs at 6:00 AM and 6:00 PM, on Monday to Friday',
      '*/5 9-17 * * *': 'Runs every 5 minutes, during hours 9 to 17',
      '5 */2 * * *': 'Runs at minute 5, every 2 hours',
      // A stepped hour beside a minute that steps is a span, not a
      // second schedule.
      '*/15 */2 * * *':
          'Runs every 15 minutes, during hours 0 to 23 in steps of 2',
      '* 8-18/2 * * *': 'Runs every minute, during hours 8 to 18 in steps of 2',
      '0 0 1,15 * *': 'Runs at 12:00 AM, on days 1 and 15 of the month',
      '0 0 * jan-mar sat,7':
          'Runs at 12:00 AM, on Saturday and Sunday, '
          'in January to March',
      // A written 7 is Sunday too, so 0-7 spans the week.
      '0 0 * * 0-7': 'Runs at 12:00 AM, on Sunday to Saturday',
      '0 0 * * 0-7/2':
          'Runs at 12:00 AM, every 2 days of the week from Sunday to '
          'Saturday',
      '0 0 * * 5-7': 'Runs at 12:00 AM, on Friday to Sunday',
      '0 4 1 * mon': 'Runs at 4:00 AM, on day 1 of the month or on Monday',
      // A month's length varies, so a stepped day of the month always
      // names its bounds.
      '0 4 */2 * 1':
          'Runs at 4:00 AM, every 2 days of the month from day 1 to 31, '
          'but only on Monday',
      // A step that does not divide its field's cycle restarts with it:
      // */45 runs at :00 and :45, so it names its bounds.
      '*/45 * * * *': 'Runs every 45 minutes from minute 0 to 59, every hour',
      '*/7 * * * *': 'Runs every 7 minutes from minute 0 to 59, every hour',
      '0 */5 * * *': 'Runs at minute 0, every 5 hours from hour 0 to 23',
      '0 0 1 */5 *':
          'Runs at 12:00 AM, on day 1 of the month, every 5 months from '
          'January to December',
      '0 0 1 */3 *': 'Runs at 12:00 AM, on day 1 of the month, every 3 months',
      '0 0 * * */2':
          'Runs at 12:00 AM, every 2 days of the week from Sunday to '
          'Saturday',
      '1,*/20 3 * * *':
          'Runs at minutes 1 and every 20 from 0 to 59, '
          'during hour 3',
    };
    for (final MapEntry(key: text, value: words) in cases.entries) {
      test(text, () => expect(_cron(text), clock(words)));
    }

    test('a macro, @reboot and CRON_TZ', () {
      expect(_cron('@daily'), 'Runs every day at midnight');
      expect(_cron('@hourly'), 'Runs every hour, on the hour');
      expect(_cron('@reboot'), 'Runs when cron starts');
      expect(
        _cron('30 2 * * *', zone: 'America/New_York'),
        clock('Runs at 2:30 AM (America/New_York time)'),
      );
    });
  });

  test('a calendar trigger reads verbatim and a monotonic one in words', () {
    expect(
      scheduleText(_l10n, CalendarSchedule(normalized: '*-*-* 06:00:00')),
      'On calendar *-*-* 06:00:00',
    );
    for (final (base, words) in [
      (MonotonicBase.active, '15 min after the timer starts'),
      (MonotonicBase.boot, '15 min after boot'),
      (MonotonicBase.startup, '15 min after systemd starts'),
      (MonotonicBase.unitActive, '15 min after the job last started'),
      (MonotonicBase.unitInactive, '15 min after the job last finished'),
    ]) {
      expect(
        scheduleText(
          _l10n,
          MonotonicSchedule(base: base, span: const Duration(minutes: 15)),
        ),
        words,
      );
    }
  });

  test('a span keeps every unit and its milliseconds; an offset its sign', () {
    expect(
      spanText(_l10n, const Duration(hours: 1, minutes: 30)),
      '1 h 30 min',
    );
    expect(spanText(_l10n, const Duration(days: 1, seconds: 2)), '1 d 2 s');
    expect(spanText(_l10n, const Duration(milliseconds: 1500)), '1.5 s');
    expect(spanText(_l10n, Duration.zero), '0 s');

    expect(utcOffsetText(_l10n, const Duration(hours: 2)), 'UTC+02:00');
    expect(
      utcOffsetText(_l10n, const Duration(hours: -5, minutes: -30)),
      'UTC−05:30',
    );
    expect(utcOffsetText(_l10n, Duration.zero), 'UTC');
  });

  test('runs follow the server zone across its DST changes', () {
    String runs(String schedule, DateTime after) => [
      for (final run in nextCronRuns(
        CronExpression.parse(schedule)!,
        afterUtc: after,
        zone: berlin,
        count: 2,
      ))
        [runTimeText(_l10n, run), ?runNote(_l10n, run)].join(' | '),
    ].join('\n').replaceAll('\u202f', ' ');

    // Spring forward: 2:30 does not exist on 29 March, so cron runs it at
    // the change, 3:00 CEST.
    expect(
      runs('30 2 * * *', DateTime.utc(2026, 3, 28, 12)),
      'Sun, Mar 29, 2026 3:00 AM UTC+02:00 | 2:30 AM does not occur that '
      'day because of the DST change, so the job runs at the change.\n'
      'Mon, Mar 30, 2026 2:30 AM UTC+02:00',
    );
    // Fall back: 2:30 occurs twice on 25 October; the run is the first.
    expect(
      runs('30 2 * * *', DateTime.utc(2026, 10, 24, 12)),
      'Sun, Oct 25, 2026 2:30 AM UTC+02:00 | 2:30 AM occurs twice at this '
      'DST change; the job runs at the first only.\n'
      'Mon, Oct 26, 2026 2:30 AM UTC+01:00',
    );
    // An hour before a change, the zone data may differ from the server's.
    expect(
      runs('0 1 * * *', DateTime.utc(2026, 3, 28, 12)),
      'Sun, Mar 29, 2026 1:00 AM UTC+01:00 | Within an hour of a DST '
      "change: the server's own zone data may move this run by an hour.\n"
      'Mon, Mar 30, 2026 1:00 AM UTC+02:00',
    );
  });

  test('a system @macro line runs as the user after its macro', () {
    // cron reads a system table's user field after a macro as after five
    // fields, so the row names that user and its title leaves it out.
    final parsed = parseCron(
      '== crontab_meta ==\nrc=0\n'
      '== crontab ==\n'
      '== etc_crontab ==\n@daily root /usr/local/bin/rotate\n'
      '== cron_d ==\ntunnel\t@reboot deploy /usr/local/bin/start-tunnel\n'
      '== cron_dirs ==\n',
      ParseContext.standard,
    );
    expect(parsed.warnings, isEmpty);
    final rows = cronResultOf(parsed.value).jobs.cast<CronJobEntry>();

    expect(
      [
        for (final row in rows)
          (
            jobTitle(row),
            sourceText(_l10n, row),
            scheduleText(_l10n, row.schedule!),
          ),
      ],
      [
        (
          '/usr/local/bin/rotate',
          '/etc/crontab, as root',
          'Runs every day at midnight',
        ),
        (
          '/usr/local/bin/start-tunnel',
          '/etc/cron.d/tunnel, as deploy',
          'Runs when cron starts',
        ),
      ],
    );

    final (daily, dailyUnknown) = cronRuns(rows.first);
    expect(dailyUnknown, isNull);
    expect(
      runTimeText(_l10n, daily.first),
      clock('Sun, Oct 25, 2026 12:00 AM UTC+02:00'),
    );
    final (reboot, rebootUnknown) = cronRuns(rows.last);
    expect(reboot, isEmpty);
    expect(rebootUnknown, JobRunsUnknown.reboot);
  });

  test('why runs are unknown, and where systemd lists one run only', () {
    expect(
      runsUnknownText(_l10n, JobRunsUnknown.anacron),
      'anacron runs this directory; its timing is not shown in this '
      'version.',
    );
    expect(
      runsUnknownText(_l10n, JobRunsUnknown.noDriver),
      'No cron line runs this directory.',
    );
    expect(
      runsUnknownText(_l10n, JobRunsUnknown.notEvaluated),
      'Runs are worked out for the first 200 cron lines only.',
    );
    expect(
      runsUnknownText(_l10n, JobRunsUnknown.noRunInHorizon),
      'No run falls in the next 10 years.',
    );
    expect(listsOneElapse(HostProfile(systemdVersion: 239)), isTrue);
    expect(listsOneElapse(HostProfile(systemdVersion: 242)), isFalse);
    expect(listsOneElapse(HostProfile()), isFalse);
  });
}
