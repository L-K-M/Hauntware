/// Command builders for detached operations (SAF-23, 03 §7.17, M11): the
/// inline wrapper that records an operation's state, the launch argv for
/// each runner row, and the cleanup and prune commands for the operation
/// directories (03 §8.11). Like [HostCommands], every builder validates
/// its arguments and returns an argv list for [HostCommands.commandLine];
/// elevation, where a row needs it, wraps the whole argv.
///
/// The record the wrapper writes, `<dir>/<id>.json`, is one line of JSON
/// with every [OpRecordField], always all of them, `null` where a value
/// is unknown or not yet set:
///
/// ```json
/// {"v":1,"id":"0123456789abcdef","state":"done","pid":4242,
///  "startTicks":987654,"unit":"klabautermann-op-0123456789abcdef.service",
///  "exit":0,"startedAt":1792065600,"endedAt":1792065660}
/// ```
library;

import 'dart:math';

import '../hws/collector.dart' show ArgValidators;
import 'commands.dart' show HostCommandError, HostCommands;
import 'proc_stat.dart';

/// The number of lowercase hex digits in an operation id (M11).
const int kOpIdLength = 16;

/// The operation directory of root-run operations (03 §7.17, §8.11):
/// root-owned 0755, so the login user can read the records it is given
/// but not replace them.
const String kRootOpsDir = '/var/lib/klabautermann/ops';

/// How every operation directory ends. The user one is
/// `${XDG_STATE_HOME:-$HOME/.local/state}/klabautermann/ops`, which the
/// engine resolves in the login shell's environment, since a transient
/// unit has no `XDG_STATE_HOME`.
const String kOpsDirSuffix = '/klabautermann/ops';

/// The transient unit name before the operation id; the unit is
/// `klabautermann-op-<id>.service` (03 §7.17).
const String kOpUnitPrefix = 'klabautermann-op-';

/// The wrapper's `$0`, which `ps` shows for a running operation.
const String kOpWrapperName = 'klabautermann-op';

/// The record format version in [OpRecordField.version].
const int kOpRecordVersion = 1;

/// The age in days after which [OperationCommands.opPrune] removes an
/// operation's files (03 §7.17 [E]).
const int kOpPruneDays = 7;

/// The wrapper's exit when it refused to start: bad parameters, a
/// directory that is missing, a symlink or not the runner's own, an id
/// already in use, or a record it could not write. The command did not
/// run and no record exists. A command may exit 125 itself, but then a
/// done record holds that code. GNU `env` and `nohup` use 125 the same
/// way, below the 126 and 127 that mean a command could not run.
const int kOpWrapperSetupFailed = 125;

/// The keys of an operation record (03 §7.17, M11), shared with the
/// record parser. The values are JSON numbers except [id], [state] and
/// [unit], which are strings; [unit], [exit], [startTicks], [startedAt]
/// and [endedAt] may be `null`.
abstract final class OpRecordField {
  /// [kOpRecordVersion].
  static const String version = 'v';

  /// The operation id, which must equal the file name's stem.
  static const String id = 'id';

  /// An [OpRecordState] wire name.
  static const String state = 'state';

  /// The wrapper shell's PID, which re-attach checks with [startTicks].
  static const String pid = 'pid';

  /// Field 22 of the wrapper's `/proc/<pid>/stat`, or `null` when it
  /// could not be read.
  static const String startTicks = 'startTicks';

  /// `klabautermann-op-<id>.service` for the systemd rows, else `null`.
  static const String unit = 'unit';

  /// The command's exit status, 0 to 255 (128 plus the signal number for
  /// a command a signal ended); `null` while running.
  static const String exit = 'exit';

  /// Seconds since the epoch when the command started (`date +%s`), or
  /// `null` where `date` has no `%s`.
  static const String startedAt = 'startedAt';

  /// Seconds since the epoch when the command ended; `null` while
  /// running.
  static const String endedAt = 'endedAt';
}

/// The state an operation record holds (03 §7.17).
enum OpRecordState {
  /// Written before the command starts.
  running,

  /// Written after the command ended, with its exit status.
  done;

  /// The [OpRecordField.state] value.
  String get wireName => name;
}

/// The five runner rows of 03 §7.17, in its order; the first that
/// matches applies, and the engine picks it (E17).
enum DetachedRunner {
  /// Needs root, admin mode on, systemd system manager: `systemd-run`
  /// through the elevation prelude, records in [kRootOpsDir].
  rootSystemd(runsAsRoot: true, elevated: true, transientUnit: true),

  /// Needs root, admin mode on, no systemd system manager: a `setsid`
  /// launch through the elevation prelude, records in [kRootOpsDir].
  rootSetsid(runsAsRoot: true, elevated: true, transientUnit: false),

  /// Needs no root, admin mode on, systemd system manager:
  /// `systemd-run --uid=<login uid>` through the elevation prelude, so
  /// the operation survives logout without linger; user directory.
  loginSystemdUid(runsAsRoot: false, elevated: true, transientUnit: true),

  /// Needs no root, admin mode off, user manager reachable with
  /// `Linger=yes`: `systemd-run --user`; user directory.
  loginSystemdUser(runsAsRoot: false, elevated: false, transientUnit: true),

  /// Otherwise: a `setsid` launch as the login user; user directory.
  loginSetsid(runsAsRoot: false, elevated: false, transientUnit: false);

  const DetachedRunner({
    required this.runsAsRoot,
    required this.elevated,
    required this.transientUnit,
  });

  /// Whether the wrapper and the command run as root, in [kRootOpsDir].
  final bool runsAsRoot;

  /// Whether the launch argv goes through the elevation prelude.
  final bool elevated;

  /// Whether the operation runs in the transient unit
  /// `klabautermann-op-<id>.service`, which its record names.
  final bool transientUnit;
}

/// Why [id] is not an operation id, or null when it is one:
/// [kOpIdLength] lowercase hex digits. The record parser applies it to
/// file names and to the record's own id.
String? validateOpId(String id) {
  if (id.length != kOpIdLength) return 'operation id length';
  if (!_opIdPattern.hasMatch(id)) return 'operation id not lowercase hex';
  return null;
}

/// A fresh operation id from [random], which the engine makes
/// `Random.secure()` (M11).
String generateOpId(Random random) {
  final b = StringBuffer();
  for (var i = 0; i < kOpIdLength ~/ 2; i++) {
    b.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// The transient unit of operation [id] (03 §7.17).
String opUnitName(String id) => '$kOpUnitPrefix$id.service';

final _opIdPattern = RegExp(r'^[0-9a-f]+$');

/// A `find -name` pattern for one operation id.
const _kHexIdGlob =
    '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
    '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]';

/// Defines `klab_prune <dir> <n>`: removes the operation files directly
/// in `<dir>` (records, logs and leftover temp files, by name) whose data
/// changed more than `<n>` whole days ago. `find` ignores the fractional
/// part of the age, so `+6` keeps everything younger than 7 days.
/// `-maxdepth` comes first, where GNU `find` wants it; BusyBox has it
/// too. A missing directory has nothing to prune.
const _kPruneFunction =
    '''
klab_prune() {
  [ -d "\$1" ] || return 0
  find "\$1" -maxdepth 1 -type f \\( -name '$_kHexIdGlob.json' \\
    -o -name '$_kHexIdGlob.log' -o -name '.$_kHexIdGlob.tmp' \\) \\
    -mtime "+\$2" -exec rm -f {} +
}
''';

/// The inline wrapper (03 §7.17):
/// `sh -c <wrapper> klabautermann-op <dir> <id> <uid> <unit|-> -- <cmd...>`.
/// It holds no secret, so it can sit in argv.
///
/// 1. It checks its parameters again, then makes the directory: as root
///    only [kRootOpsDir] (parents 0755, so the login user can read it),
///    otherwise only a directory of the uid it runs as (0700). It refuses
///    a symlink or a directory it does not own, so root never writes
///    into a user-writable one.
/// 2. As root it prunes [kRootOpsDir] (03 §7.17, "by the next root-run
///    wrapper").
/// 3. It creates `<id>.log` exclusively (`set -C`), so an id in use
///    fails, and as root `chown`s it to the login user. The redirection
///    sits on `true`: on the special builtin `:` its failure would end
///    dash with status 2 instead of the refusal.
/// 4. It writes the running record (PID `$$`, its start ticks, the unit)
///    to `.<id>.tmp` and `mv`s it over `<id>.json`, so a reader sees a
///    whole record or none; as root the temp file is `chown`ed first.
/// 5. It runs the command from `/`, every row alike, with stdin on
///    `/dev/null` and output appended to the log; `command` keeps a
///    command named like a wrapper function from calling it.
/// 6. It writes the done record the same way and exits with the
///    command's status.
///
/// Any refusal before the command exits [kOpWrapperSetupFailed]. A wrapper
/// killed while the command runs leaves the running record, whose PID
/// and start ticks then no longer match: re-attach reads that as an
/// orphan (E17).
const _kOpWrapper =
    '''
umask 077
d=\$1 i=\$2 u=\$3 n=\$4
[ "\$5" = -- ] || exit $kOpWrapperSetupFailed
shift 5
[ \$# -gt 0 ] || exit $kOpWrapperSetupFailed
case \$i in '' | *[!0-9a-f]*) exit $kOpWrapperSetupFailed ;; esac
[ \${#i} -eq $kOpIdLength ] || exit $kOpWrapperSetupFailed
case \$u in '' | *[!0-9]*) exit $kOpWrapperSetupFailed ;; esac
case \$n in
  -) j=null ;;
  "$kOpUnitPrefix\$i.service") j="\\"\$n\\"" ;;
  *) exit $kOpWrapperSetupFailed ;;
esac
case \$d in /*$kOpsDirSuffix) ;; *) exit $kOpWrapperSetupFailed ;; esac
m=\$(id -u) || exit $kOpWrapperSetupFailed
if [ "\$d" = '$kRootOpsDir' ]; then
  [ "\$m" = 0 ] || exit $kOpWrapperSetupFailed
  (umask 022 && mkdir -p "\$d") || exit $kOpWrapperSetupFailed
  k=755
else
  [ "\$m" = "\$u" ] || exit $kOpWrapperSetupFailed
  mkdir -p "\$d" || exit $kOpWrapperSetupFailed
  k=700
fi
[ -d "\$d" ] && [ ! -h "\$d" ] && [ -O "\$d" ] && chmod "\$k" "\$d" ||
  exit $kOpWrapperSetupFailed
c=; [ "\$m" = "\$u" ] || c=1
$_kPruneFunction$kStartTicksFunction
klab_now() {
  _x=\$(date +%s 2>/dev/null)
  case \$_x in '' | *[!0-9]*) _x=null ;; esac
}
klab_rec() {
  printf '{"${OpRecordField.version}":$kOpRecordVersion,"${OpRecordField.id}":"%s","${OpRecordField.state}":"%s","${OpRecordField.pid}":%s,"${OpRecordField.startTicks}":%s,"${OpRecordField.unit}":%s,"${OpRecordField.exit}":%s,"${OpRecordField.startedAt}":%s,"${OpRecordField.endedAt}":%s}\\n' \\
    "\$i" "\$1" "\$\$" "\$s" "\$j" "\$2" "\$a" "\$3" >"\$t" &&
    { [ -z "\$c" ] || chown "\$u" "\$t"; } &&
    mv -f "\$t" "\$f"
}
[ "\$k" = 700 ] || klab_prune "\$d" ${kOpPruneDays - 1} 2>/dev/null
cd / || exit $kOpWrapperSetupFailed
f=\$d/\$i.json t=\$d/.\$i.tmp l=\$d/\$i.log
[ ! -e "\$f" ] && [ ! -h "\$f" ] || exit $kOpWrapperSetupFailed
set -C
true >"\$l" || exit $kOpWrapperSetupFailed
set +C
[ -z "\$c" ] || chown "\$u" "\$l" || { rm -f "\$l"; exit $kOpWrapperSetupFailed; }
if klab_ticks \$\$; then s=\$KT; else s=null; fi
klab_now; a=\$_x
klab_rec running null null ||
  { rm -f "\$t" "\$l"; exit $kOpWrapperSetupFailed; }
command "\$@" >>"\$l" 2>&1 </dev/null
r=\$?
klab_now
klab_rec done "\$r" "\$_x"
exit "\$r"''';

/// The `setsid` rows' launcher: the wrapper in a new session with every
/// standard stream on `/dev/null`, so the SSH channel closes when this
/// shell exits, then the wrapper's PID. A backgrounded child of a
/// non-interactive shell leads no process group, so `setsid` calls
/// setsid(2) in place and execs the wrapper without forking, in
/// util-linux and BusyBox alike (BusyBox's applet has no `-f`; 03 §7.17
/// [U], spike S4). The printed `$!` is therefore the record's PID.
const _kSetsidLaunch = r'''setsid "$@" </dev/null >/dev/null 2>&1 &
printf '%s\n' "$!"''';

/// Builders for detached operations (03 §7.17, §8.11).
abstract final class OperationCommands {
  /// The launch argv of operation [id] for [runner] (03 §7.17): the
  /// wrapper runs [argv] as root on the root rows and as the login user
  /// otherwise, and records it for uid [uid], the login user's: in
  /// [kRootOpsDir] on the root rows, whose files it `chown`s to that
  /// uid, and in the resolved user directory [dir] otherwise. Uid 0 is
  /// refused on [DetachedRunner.loginSystemdUid], where `--uid=0` would
  /// run a root unit that records in the user directory. The systemd
  /// rows name the transient unit [opUnitName] and pass `--collect
  /// --quiet`; the setsid rows print the
  /// wrapper's PID. When [DetachedRunner.elevated] holds, the caller runs
  /// the argv through the elevation prelude.
  static List<String> detachedLaunch(
    DetachedRunner runner, {
    required String dir,
    required String id,
    required int uid,
    required List<String> argv,
  }) {
    _checkOpId(id);
    _checkRunnerDir(runner, dir);
    if (uid < 0) throw HostCommandError('negative uid', argument: '$uid');
    if (uid == 0 && runner == DetachedRunner.loginSystemdUid) {
      throw HostCommandError(
        'a root unit would record in the user directory',
        argument: '0',
      );
    }
    _checkArgv(argv);

    final unit = opUnitName(id);
    final wrapped = [
      '/bin/sh',
      '-c',
      _kOpWrapper,
      kOpWrapperName,
      dir,
      id,
      '$uid',
      if (runner.transientUnit) unit else '-',
      '--',
      ...argv,
    ];
    if (!runner.transientUnit) {
      return ['sh', '-c', _kSetsidLaunch, 'klabautermann-launch', ...wrapped];
    }

    return [
      'systemd-run',
      if (runner == DetachedRunner.loginSystemdUser) '--user',
      if (runner == DetachedRunner.loginSystemdUid) '--uid=$uid',
      '--unit=$unit',
      '--collect',
      '--quiet',
      '--',
      // The service manager expands `${NAME}`, and `$NAME` as a whole
      // word, in a transient service's command line (systemd-run's
      // --expand-environment defaults to on for services, and before
      // systemd 254 there was no way off), which would empty the
      // wrapper's own variables; `$$` is its escape for a literal `$`.
      for (final word in wrapped) word.replaceAll(r'$', r'$$'),
    ];
  }

  /// Prints the login user's operation directory as the `ops` collector
  /// resolves it (03 §7.17): `${XDG_STATE_HOME:-$HOME/.local/state}`, a
  /// relative `XDG_STATE_HOME` ignored, then [kOpsDirSuffix]. The engine
  /// runs it in the login shell before a launch on the user rows, since a
  /// transient unit has no `XDG_STATE_HOME` of its own.
  static List<String> userOpsDir() => [
    'sh',
    '-c',
    r'u=${XDG_STATE_HOME:-$HOME/.local/state}; '
        r'case $u in /*) ;; *) u=$HOME/.local/state ;; esac; '
        "printf '%s\\n' \"\$u$kOpsDirSuffix\"",
  ];

  /// `rm -f --` of each operation's record, log and leftover temp file
  /// in [dir] (03 §7.17 "Cleanup"), after its result was shown and
  /// audited. [kRootOpsDir] needs the elevation prelude: the login user
  /// owns the files there but cannot unlink in the root-owned directory.
  static List<String> opCleanup(String dir, List<String> ids) {
    _checkOpsDir(dir);
    if (ids.isEmpty) throw const HostCommandError('no operation to clean up');
    for (final id in ids) {
      _checkOpId(id);
    }
    return [
      'rm',
      '-f',
      '--',
      for (final id in ids) ...[
        '$dir/$id.json',
        '$dir/$id.log',
        '$dir/.$id.tmp',
      ],
    ];
  }

  /// The prune of [dir] (03 §7.17): every operation file there older than
  /// [days] whole days, matched by name, and nothing when the directory
  /// does not exist. On connect for the user directory; for
  /// [kRootOpsDir] in admin mode, through the elevation prelude, and by
  /// every root-run wrapper.
  static List<String> opPrune(String dir, {int days = kOpPruneDays}) {
    _checkOpsDir(dir);
    if (days < 1) {
      throw HostCommandError('days must be positive', argument: '$days');
    }
    return [
      'sh',
      '-c',
      '${_kPruneFunction}klab_prune "\$1" "\$2"',
      'klabautermann-prune',
      dir,
      '${days - 1}',
    ];
  }

  static void _checkOpId(String id) {
    final reason = validateOpId(id);
    if (reason != null) throw HostCommandError(reason, argument: id);
  }

  /// [dir] is [kRootOpsDir] or a user operation directory: absolute,
  /// normalized, ending in [kOpsDirSuffix] below some other directory,
  /// and never under `/tmp` or `/var/tmp` (03 §8.11 "Never /tmp").
  static void _checkOpsDir(String dir) {
    if (dir == kRootOpsDir) return;
    final reason = ArgValidators.absolutePath(dir);
    if (reason != null) throw HostCommandError(reason, argument: dir);
    if (dir.contains('//') ||
        !dir.endsWith(kOpsDirSuffix) ||
        dir.length == kOpsDirSuffix.length) {
      throw HostCommandError('not an operation directory', argument: dir);
    }
    if (dir.startsWith('/tmp/') || dir.startsWith('/var/tmp/')) {
      throw HostCommandError('operation directory in /tmp', argument: dir);
    }
    for (final c in dir.codeUnits) {
      if (c < 0x20 || c == 0x7f) {
        throw HostCommandError('control byte in directory', argument: dir);
      }
    }
  }

  /// The root rows write only to [kRootOpsDir], the others never there.
  static void _checkRunnerDir(DetachedRunner runner, String dir) {
    _checkOpsDir(dir);
    if (runner.runsAsRoot != (dir == kRootOpsDir)) {
      throw HostCommandError(
        runner.runsAsRoot
            ? 'a root-run operation records in $kRootOpsDir'
            : 'a login-user operation records in the user directory',
        argument: dir,
      );
    }
  }

  /// The command must name a program, not an option of the wrapper's
  /// `command`, and argv cannot carry NUL bytes.
  static void _checkArgv(List<String> argv) {
    if (argv.isEmpty || argv.first.isEmpty) {
      throw const HostCommandError('empty command');
    }
    if (argv.first.startsWith('-')) {
      throw HostCommandError('command starts with -', argument: argv.first);
    }
    for (final word in argv) {
      if (word.codeUnits.contains(0)) {
        throw HostCommandError('NUL in a command word', argument: word);
      }
    }
  }
}
