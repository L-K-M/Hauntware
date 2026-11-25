part of 'commands.dart';

/// The first systemd major whose `systemd-analyze calendar` takes
/// `--iterations`; older ones print one elapse per expression (03 §7.7).
const int kCalendarIterationsSystemd = 242;

/// The crontab spools JOB-03 lists, in the order tried (03 §7.7, M14):
/// Debian, Ubuntu and BusyBox crond keep `crontabs/` under
/// `/var/spool/cron`, which on Debian holds other spools too; cronie
/// (RHEL, Fedora) keeps the files in `/var/spool/cron` itself.
const List<String> kCrontabSpools = [
  '/var/spool/cron/crontabs',
  '/var/spool/cron',
];

/// [HostCommands.crontabSpoolList]'s exit when it listed a spool (the
/// list may be empty).
const int kCrontabSpoolListed = 0;

/// [HostCommands.crontabSpoolList]'s exit when no spool directory exists.
const int kCrontabSpoolMissing = 3;

/// [HostCommands.crontabSpoolList]'s exit when the first spool that exists
/// cannot be listed: Debian's is `1730 root:crontab`, so the listing needs
/// elevation. An unreadable directory never reads as an empty one.
const int kCrontabSpoolDenied = 4;

/// The spool listing (03 §7.7, M14): the first directory among its
/// positional parameters that exists, on the first line, then the name
/// of each regular file in it that is not a symlink, one per line. The
/// glob skips dot files; the reader validates each name as a user name.
const String _kCrontabSpoolScript =
    '''
for d do
  [ -d "\$d" ] || continue
  [ -r "\$d" ] && [ -x "\$d" ] || exit $kCrontabSpoolDenied
  printf '%s\\n' "\$d"
  for f in "\$d"/*; do
    [ -f "\$f" ] && [ ! -h "\$f" ] || continue
    printf '%s\\n' "\${f##*/}"
  done
  exit $kCrontabSpoolListed
done
exit $kCrontabSpoolMissing''';

/// [HostCommands.anacron]'s exit when it printed the table and stamps.
const int kAnacronListed = 0;

/// [HostCommands.anacron]'s exit when `/etc/anacrontab` does not exist:
/// anacron is not installed.
const int kAnacronMissing = 3;

/// [HostCommands.anacron]'s exit when `/etc/anacrontab` exists but could
/// not be read.
const int kAnacronUnreadable = 4;

/// The marker before anacron's job stamps in [HostCommands.anacron]'s
/// output; the table comes before it.
const String kAnacronStampsMarker = '== klabautermann anacron stamps ==';

/// Prints `/etc/anacrontab`, then [kAnacronStampsMarker], then one
/// `<job> <stamp>` line per file under `/var/spool/anacron` (JOB-04, 03
/// §7.7); an unreadable stamp prints `?`.
const String _kAnacronScript =
    '''
[ -e /etc/anacrontab ] || exit $kAnacronMissing
cat /etc/anacrontab || exit $kAnacronUnreadable
printf '\n%s\n' '$kAnacronStampsMarker'
for f in /var/spool/anacron/*; do
  [ -f "\$f" ] || continue
  d=\$(cat -- "\$f" 2>/dev/null) || d='?'
  printf '%s %s\n' "\${f##*/}" "\${d:-?}"
done
exit $kAnacronListed''';

/// The syslog identifiers cron daemons log their runs under (JOB-05, 03
/// §7.7): Debian's and Ubuntu's cron, cronie and BusyBox crond.
const List<String> kCronJournalIdentifiers = ['CRON', 'CROND', 'crond'];

/// How a cron command runs as another user (JOB-19, 03 §7.7): util-linux
/// `runuser`, which root runs without a password prompt or PAM session
/// checks, or `su` where a host lacks it (BusyBox, Alpine).
enum RunAsTool {
  /// `runuser` where the host has it, else `su`, chosen on the host.
  installed,
  runuser,
  su,
}

/// Runs `$2` as the user `$1` with `runuser`, or with `su` on a host
/// without it. `su` takes its options before the user, which both the
/// util-linux and the BusyBox one read.
const String _kRunAsScript = r'''
if command -v runuser >/dev/null 2>&1; then
  exec runuser -u "$1" -- sh -c "$2"
fi
exec su -s /bin/sh -c "$2" "$1"''';
