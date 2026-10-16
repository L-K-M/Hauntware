import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CronDirEntry,
        CronExpression,
        CronJob,
        CronPeriod,
        ServerZone,
        TimerListFormat,
        mergeJobs;

/// [text] with the narrow no-break space intl's English `jm` format puts
/// before AM and PM.
String clock(String text) =>
    text.replaceAll(' AM', '\u202fAM').replaceAll(' PM', '\u202fPM');

/// Europe/Berlin's offsets from 2026 to early 2027, as the engine's zone
/// database gives them (D58).
final ServerZone berlin = ServerZone(
  offset: const Duration(hours: 2),
  ianaName: 'Europe/Berlin',
  offsetAt: (utc) =>
      utc.isBefore(DateTime.utc(2026, 3, 29, 1)) ||
          !utc.isBefore(DateTime.utc(2026, 10, 25, 1)) &&
              utc.isBefore(DateTime.utc(2027, 3, 28, 1))
      ? const Duration(hours: 1)
      : const Duration(hours: 2),
);

/// America/New_York's offsets around its 2026 fall-back.
final ServerZone _newYork = ServerZone(
  offset: const Duration(hours: -4),
  ianaName: 'America/New_York',
  offsetAt: (utc) => utc.isBefore(DateTime.utc(2026, 11, 1, 6))
      ? const Duration(hours: -4)
      : const Duration(hours: -5),
);

/// When the jobs readings are taken: the day before Berlin falls back.
final DateTime jobsNow = DateTime.utc(2026, 10, 24, 12);

/// The probe's answer for the jobs server: Berlin at CEST, systemd 252.
final HostProfile jobsProfile = HostProfile(
  zoneOffset: '+0200',
  timezone: 'Europe/Berlin',
  systemdVersion: 252,
);

CronJob _line(
  String source,
  String schedule,
  String command, {
  String? user,
  String? cronTz,
}) => CronJob(
  source: source,
  schedule: schedule,
  command: command,
  raw: '$schedule ${user ?? ''} $command',
  expression: CronExpression.parse(schedule),
  user: user,
  cronTz: cronTz,
);

/// A Debian host's cron table: the login user's crontab, /etc/crontab with
/// anacron installed, a cron.d file and a CRON_TZ line, evaluated by the
/// engine's own merge at [jobsNow] in Berlin.
CronResult jobsCron({bool ownCrontabKnown = true}) {
  final cron = CronSnapshot(
    jobs: [
      _line('crontab', '*/15 * * * *', '/home/deploy/bin/sync-assets'),
      _line(
        '/etc/crontab',
        '25 6 * * *',
        'test -x /usr/sbin/anacron || ( cd / && run-parts --report '
            '/etc/cron.daily )',
        user: 'root',
      ),
      _line(
        '/etc/cron.d/backup',
        '30 2 * * *',
        '/usr/local/bin/backup',
        user: 'root',
      ),
      _line(
        '/etc/cron.d/report',
        '0 9 * * 1-5',
        '/usr/local/bin/report',
        user: 'deploy',
        cronTz: 'America/New_York',
      ),
      _line('/etc/cron.d/0anacron', '@reboot', 'anacron -s', user: 'root'),
    ],
    dirEntries: const [
      CronDirEntry(period: CronPeriod.daily, name: '0anacron'),
      CronDirEntry(period: CronPeriod.daily, name: 'logrotate'),
    ],
    ownCrontabPresent: ownCrontabKnown ? true : null,
  );
  return CronResult(
    cron,
    jobs: mergeJobs(
      cron: cron,
      nowUtc: jobsNow,
      zone: berlin,
      zoneFor: (name) => name == _newYork.ianaName ? _newYork : null,
    ),
    zoneName: berlin.ianaName,
  );
}

/// The host's timers from `systemctl list-timers --output=json`: one
/// without a next elapse.
TimersResult jobsTimers() => TimersResult(
  TimersSnapshot(
    format: TimerListFormat.json,
    timers: [
      SystemdTimer(
        unit: 'apt-daily.timer',
        activates: 'apt-daily.service',
        nextUs: DateTime.utc(2026, 10, 24, 17, 41).microsecondsSinceEpoch,
      ),
      SystemdTimer(
        unit: 'fstrim.timer',
        activates: 'fstrim.service',
        nextUs: DateTime.utc(2026, 10, 26, 0, 12).microsecondsSinceEpoch,
      ),
      const SystemdTimer(unit: 'certbot.timer', activates: 'certbot.service'),
    ],
  ),
);
