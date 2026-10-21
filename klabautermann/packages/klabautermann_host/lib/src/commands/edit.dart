/// Command builders for the v1 edit pipeline (SAF-12, SAF-14; 03 §5.11,
/// §8.5, §8.11, D67): reading a file with its size and hash, writing the
/// replacement to a temp file beside it, carrying the target's owner,
/// mode, ACL and xattrs over, replacing the target only while its hash is
/// unchanged, backups with their index, and crontab writes. Like
/// [HostCommands], every builder validates its arguments (03 §8.8) and
/// returns an argv list for [HostCommands.commandLine]; a root-owned
/// target runs each one through the elevation prelude.
///
/// A write runs, in order:
///
/// ```text
///   readFile ─▶ (edit, validate, preview) ─▶ backupFile ─▶ writeTemp
///     ─▶ copyAttributes ─▶ replaceIfHash ─▶ restorecon (SELinux enforcing)
///   any failure after writeTemp ─▶ removeTemp
/// ```
library;

import '../hws/collector.dart' show ArgValidators;
import 'commands.dart' show HostCommandError;
import 'operations.dart' show OperationCommands;

/// What every temp file's name holds between the target's name and its
/// token (03 §8.11): `.<name>.klabautermann-tmp-<token>`.
const String kEditTempInfix = '.klabautermann-tmp-';

/// The number of lowercase hex digits in a temp file's token.
const int kEditTempTokenLength = 16;

/// Where root-owned files' backups go (03 §8.11): root 0700, with its
/// [kEditBackupIndexName].
const String kRootBackupsDir = '/var/lib/klabautermann/backups';

/// How the login user's backup directory ends; the whole path is
/// `${XDG_STATE_HOME:-$HOME/.local/state}/klabautermann/backups`, which
/// the engine resolves in the login shell's environment.
const String kBackupsDirSuffix = '/klabautermann/backups';

/// The root footprint manifest (SAF-14, 03 §8.11).
const String kRootManifestPath = '/etc/klabautermann/manifest.json';

/// How the login user's manifest path ends; the whole path is
/// `${XDG_CONFIG_HOME:-$HOME/.config}/klabautermann/manifest.json`.
const String kManifestSuffix = '/klabautermann/manifest.json';

/// The index in each backup directory: one line per backup,
/// `<epoch seconds> TAB <sha256> TAB <original path>`.
const String kEditBackupIndexName = 'index';

/// The first systemd major whose `systemd-analyze verify` reads a file as
/// another unit (`FILE:UNIT`), which checking a unit file's temp copy
/// needs: the temp's own name is no unit name.
const int kVerifyAsUnitSystemd = 250;

/// The unit types a unit file defines (systemd.unit(5)); device and scope
/// units come from udev and the manager, never from a file.
const Set<String> _unitFileTypes = {
  'service',
  'socket',
  'target',
  'mount',
  'automount',
  'swap',
  'path',
  'timer',
  'slice',
};

/// The unit [path] defines when it is a unit file systemd loads: a unit
/// name, with a unit type's suffix, directly in a `systemd/system` or
/// `systemd/user` directory. A drop-in, under `<unit>.d/`, defines none,
/// and neither does a name with `:`, which `FILE:UNIT` would split.
/// Otherwise null.
String? unitFileName(String path) {
  final slash = path.lastIndexOf('/');
  if (slash <= 0) return null;
  final directory = path.substring(0, slash);
  if (!directory.endsWith('/systemd/system') &&
      !directory.endsWith('/systemd/user')) {
    return null;
  }
  final name = path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || !_unitFileTypes.contains(name.substring(dot + 1))) {
    return null;
  }
  return _unitName.hasMatch(name) ? name : null;
}

/// The default cap on what [EditCommands.readFile] prints of a file: an
/// editor buffer, not a log (03 §8.5).
const int kEditReadMaxBytes = 1024 * 1024;

/// The exits the edit scripts give for their own refusals, above what
/// the tools they run return (1 and 2) and below the shell's 126 and
/// 127. Each leaves the target as it was.
abstract final class EditExit {
  /// [EditCommands.replaceIfHash]: the target no longer has the hash the
  /// edit started from; the temp file is removed.
  static const int hashMismatch = 101;

  /// [EditCommands.copyAttributes]: `cp --attributes-only` was refused
  /// and the target carries extended ACL entries the fallback would
  /// drop (D67).
  static const int aclNotCarried = 102;

  /// [EditCommands.copyAttributes]: as [aclNotCarried], for extended
  /// attributes other than the SELinux label.
  static const int xattrNotCarried = 103;

  /// [EditCommands.sha256List]: a path exists but `sha256sum` could not
  /// read it, so the list is incomplete.
  static const int unreadable = 104;
}

/// What [EditCommands.readFile]'s first line says of the file: its
/// size, numeric owner and group, permission bits and SHA-256.
typedef ReadHeader = ({int size, int uid, int gid, int mode, String sha256});

/// Reads [EditCommands.readFile]'s first line:
/// `<size> <uid> <gid> <octal mode> <sha256>`.
ReadHeader? parseReadHeader(String line) {
  final match = _readHeader.firstMatch(line);
  if (match == null) return null;
  final size = int.tryParse(match[1]!);
  final uid = int.tryParse(match[2]!);
  final gid = int.tryParse(match[3]!);
  final mode = int.tryParse(match[4]!, radix: 8);
  if (size == null || uid == null || gid == null || mode == null) return null;
  return (size: size, uid: uid, gid: gid, mode: mode, sha256: match[5]!);
}

/// Reads `sha256sum` output, as [EditCommands.sha256List] prints it, into
/// a hash per path. Lines it does not recognise are skipped. GNU marks a
/// line whose path holds a backslash or a newline with a leading `\` and
/// escapes the path; BusyBox prints the path as it is.
Map<String, String> parseSha256List(String output) => {
  for (final line in output.split('\n'))
    if (_sha256Line.firstMatch(line) case final m?)
      m[1] == null ? m[3]! : _unescapeSha256Path(m[3]!): m[2]!,
};

String _unescapeSha256Path(String path) => path.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => switch (m[1]!) {
    'n' => '\n',
    'r' => '\r',
    final c => c,
  },
);

// `stat -c %a` prints the mode without leading zeros, so 0007 reads `7`.
final _readHeader = RegExp(r'^(\d+) (\d+) (\d+) ([0-7]{1,4}) ([0-9a-f]{64})$');
final _sha256Line = RegExp(r'^(\\)?([0-9a-f]{64})  (/.*)$');
final _sha256 = RegExp(r'^[0-9a-f]{64}$');
final _backupName = RegExp(r'^[0-9a-f]{64}-\d{1,12}$');
final _token = RegExp('^[0-9a-f]{$kEditTempTokenLength}\$');
// systemd.unit(5)'s characters, less `:`.
final _unitName = RegExp(r'^[A-Za-z0-9_.@\\-]+$');

/// Prints `<size> <uid> <gid> <mode> <sha256>` and then, when the size is
/// at most the cap, the content. The hash is of the file as `sha256sum` read it; the
/// engine checks it against the bytes `cat` printed, which a concurrent
/// write may have changed between the two reads.
const String _kReadScript = r'''
i=$(stat -c '%s %u %g %a' -- "$1") || exit
h=$(sha256sum -- "$1") || exit
printf '%s %s\n' "$i" "${h%% *}"
s=${i%% *}
if [ "$s" -le "$2" ]; then exec cat -- "$1"; fi''';

/// Writes stdin to a new temp file that no other account can read, and
/// refuses one that already exists (`set -C`).
const String _kWriteTempScript = r'set -C; umask 077; cat > "$1"';

/// D67's attribute recipe: GNU `cp --attributes-only` carries owner, mode
/// (with the ACL) and xattrs; elsewhere `stat` gives numeric owner and
/// mode, after checking that no ACL entry or xattr would be dropped. The
/// exits are [EditExit.aclNotCarried] and [EditExit.xattrNotCarried].
const String _kCopyAttributesScript = r'''
t=$1 tmp=$2
if cp --attributes-only --preserve=mode,ownership,xattr -- "$t" "$tmp" 2>/dev/null; then
  exit 0
fi
if command -v getfacl >/dev/null 2>&1; then
  a=$(getfacl -c -- "$t" 2>/dev/null) || exit 102
  n=$(printf '%s\n' "$a" | grep -c -v -e '^$' -e '^user::' -e '^group::' -e '^other::')
  [ "$n" -eq 0 ] || exit 102
fi
if command -v getfattr >/dev/null 2>&1; then
  if getfattr -d -m - -- "$t" 2>/dev/null | grep -v -e '^#' -e '^$' -e '^security\.selinux=' | grep -q .; then
    exit 103
  fi
fi
o=$(stat -c %u:%g -- "$t") && m=$(stat -c %a -- "$t") || exit
chown -- "$o" "$tmp" && chmod -- "$m" "$tmp"''';

/// Re-checks the target's hash right before the rename (03 §8.5's
/// compare-and-swap); a mismatch exits [EditExit.hashMismatch], and it or
/// a failed rename removes the temp.
const String _kReplaceIfHashScript = r'''
h=$(sha256sum -- "$1") || { s=$?; rm -f -- "$2"; exit "$s"; }
if [ "${h%% *}" != "$3" ]; then rm -f -- "$2"; exit 101; fi
mv -f -- "$2" "$1" || { s=$?; rm -f -- "$2"; exit "$s"; }''';

/// Copies the target to `<dir>/<sha256>-<epoch>`, through a temp name so
/// a partial copy never looks like a backup, and replaces the
/// [kEditBackupIndexName] with one more line the same way. Prints the
/// backup's path.
const String _kBackupScript = r'''
umask 077
d=$2
mkdir -p -- "$d" && chmod 0700 -- "$d" || exit
h=$(sha256sum -- "$1") || exit
h=${h%% *}
t=$(date +%s)
b=$d/$h-$t
cp -p -- "$1" "$b.tmp" && mv -f -- "$b.tmp" "$b" || { s=$?; rm -f -- "$b.tmp"; exit "$s"; }
x=$d/.index.tmp.$$
{ cat -- "$d/index" 2>/dev/null; printf '%s\t%s\t%s\n' "$t" "$h" "$1"; } > "$x" &&
  mv -f -- "$x" "$d/index" || { s=$?; rm -f -- "$x"; exit "$s"; }
printf '%s\n' "$b"''';

/// Replaces a crontab with stdin while `crontab -l` still hashes to the
/// SHA-256 the edit started from: a missing crontab reads, and hashes, as
/// empty. The first argument is the hash, then `crontab`'s own words.
const String _kCrontabWriteIfHashScript = r'''
h=$1
shift
c=$(crontab -l "$@" 2>/dev/null; printf x)
c=$(printf '%s' "${c%x}" | sha256sum) || exit
if [ "${c%% *}" != "$h" ]; then exit 101; fi
exec crontab "$@" -''';

/// Saves `crontab -l`'s output as a backup, as [_kBackupScript] saves a
/// file, under the name `crontab:<user>` in the index.
const String _kCrontabBackupScript = r'''
umask 077
d=$1
n=$2
shift 2
mkdir -p -- "$d" && chmod 0700 -- "$d" || exit
t=$(date +%s)
crontab -l "$@" > "$d/.crontab.tmp" 2>/dev/null || : > "$d/.crontab.tmp"
h=$(sha256sum -- "$d/.crontab.tmp") || exit
h=${h%% *}
b=$d/$h-$t
mv -f -- "$d/.crontab.tmp" "$b" || { s=$?; rm -f -- "$d/.crontab.tmp"; exit "$s"; }
{ cat -- "$d/index" 2>/dev/null; printf '%s\t%s\t%s\n' "$t" "$h" "$n"; } > "$d/.index.tmp" &&
  mv -f -- "$d/.index.tmp" "$d/index" || exit
printf '%s\n' "$b"''';

/// Sets `c` to the SHA-256 of `$1`, or of nothing when `$1` does not
/// exist. A `$1` that exists but cannot be read exits non-zero, so it
/// never passes for an absent one.
const String _kHashOrEmpty =
    'if [ -e "\$1" ]; then c=\$(sha256sum < "\$1") || exit; '
    'else c=\$(sha256sum < /dev/null); fi\n';

/// Exits [EditExit.hashMismatch] unless `c` holds the SHA-256 in `$2`.
const String _kExitUnlessHash =
    'if [ "\${c%% *}" != "\$2" ]; then exit ${EditExit.hashMismatch}; fi\n';

/// Replaces a backup index with stdin while it still hashes to the
/// SHA-256 the plan read (an absent index hashes as empty), so a backup
/// another edit added meanwhile is never dropped from it.
const String _kIndexWriteIfHashScript =
    'umask 077\n'
    '$_kHashOrEmpty'
    '$_kExitUnlessHash'
    'cat > "\$1.klabautermann-tmp" && mv -f -- "\$1.klabautermann-tmp" "\$1" ||\n'
    '  { s=\$?; rm -f -- "\$1.klabautermann-tmp"; exit "\$s"; }';

/// Writes stdin to the manifest through a temp file beside it, creating
/// its directory 0700, while the manifest still hashes to the read the
/// plan rewrote (an absent one hashes as empty); otherwise exits
/// [EditExit.hashMismatch].
const String _kManifestWriteScript =
    'umask 077\n'
    'mkdir -p -- "\${1%/*}" || exit\n'
    '$_kHashOrEmpty'
    '$_kExitUnlessHash'
    'x=\$1.klabautermann-tmp.\$\$\n'
    'cat > "\$x" && mv -f -- "\$x" "\$1" || { s=\$?; rm -f -- "\$x"; exit "\$s"; }';

/// The validated builders of the edit pipeline (03 §8.5, §8.8, D67).
abstract final class EditCommands {
  /// The temp file beside [target] for an edit with [token], 16
  /// lowercase hex digits the engine draws per edit (03 §8.11).
  static String tempPathFor(String target, String token) {
    _checkPath(target);
    if (!_token.hasMatch(token)) {
      throw HostCommandError('not a temp token', argument: token);
    }
    final slash = target.lastIndexOf('/');
    return '${target.substring(0, slash + 1)}'
        '.${target.substring(slash + 1)}$kEditTempInfix$token';
  }

  /// `<size> <uid> <gid> <mode> <sha256>` of [path], then its content
  /// when it is at most [cap] bytes (03 §8.5); [parseReadHeader] reads
  /// the first line.
  static List<String> readFile(String path, {int cap = kEditReadMaxBytes}) {
    _checkPath(path);
    if (cap < 0) throw HostCommandError('negative cap', argument: '$cap');
    return ['sh', '-c', _kReadScript, 'klabautermann-read', path, '$cap'];
  }

  /// Writes stdin to [temp], made by [tempPathFor], mode 0600 until
  /// [copyAttributes] sets the target's; refuses a temp that exists.
  static List<String> writeTemp(String temp) {
    _checkTemp(temp);
    return ['sh', '-c', _kWriteTempScript, 'klabautermann-write', temp];
  }

  /// Carries [target]'s owner, mode, ACL and xattrs over to [temp] by
  /// D67's recipe. Where `cp --attributes-only` is refused (BusyBox), it
  /// exits [EditExit.aclNotCarried] or [EditExit.xattrNotCarried] rather
  /// than drop what it cannot copy.
  static List<String> copyAttributes(String target, String temp) {
    _checkPair(target, temp);
    return [
      'sh',
      '-c',
      _kCopyAttributesScript,
      'klabautermann-attributes',
      target,
      temp,
    ];
  }

  /// Renames [temp] over [target] while [target]'s hash is still
  /// [sha256]; otherwise exits [EditExit.hashMismatch]. A mismatch or a
  /// failed rename removes [temp].
  static List<String> replaceIfHash(String target, String temp, String sha256) {
    _checkPair(target, temp);
    if (!_sha256.hasMatch(sha256)) {
      throw HostCommandError('not a SHA-256', argument: sha256);
    }
    return [
      'sh',
      '-c',
      _kReplaceIfHashScript,
      'klabautermann-replace',
      target,
      temp,
      sha256,
    ];
  }

  /// Checks [temp] as the unit [unit] with `systemd-analyze verify`
  /// before it replaces the unit file (03 §8.5): `FILE:UNIT` loads the
  /// temp under the unit's name, which needs systemd
  /// [kVerifyAsUnitSystemd] or later. It runs in system mode, which
  /// needs no user manager, for user units too.
  static List<String> verifyUnit(String temp, String unit) {
    _checkTemp(temp);
    if (temp.contains(':')) {
      throw HostCommandError(
        'FILE:UNIT cannot name a path with :',
        argument: temp,
      );
    }
    if (unitFileName('/etc/systemd/system/$unit') != unit) {
      throw HostCommandError('not a unit file name', argument: unit);
    }
    return ['systemd-analyze', 'verify', '--', '$temp:$unit'];
  }

  /// Prints `1` while SELinux enforces; fails where the host has no
  /// SELinux (D67). World-readable, so the login user's read decides.
  static List<String> selinuxEnforcing() => const [
    'cat',
    '/sys/fs/selinux/enforce',
  ];

  /// Restores [path]'s SELinux label (D67): the step a write adds after
  /// the rename while [selinuxEnforcing] prints `1`.
  static List<String> restorecon(String path) {
    _checkPath(path);
    return ['restorecon', '--', path];
  }

  /// Removes [temp] after a failed write.
  static List<String> removeTemp(String temp) {
    _checkTemp(temp);
    return ['rm', '-f', '--', temp];
  }

  /// Prints the login user's backup directory, resolved in the login
  /// shell's environment as [OperationCommands.userOpsDir] resolves the
  /// operation directory.
  static List<String> userBackupsDir() => [
    'sh',
    '-c',
    r'u=${XDG_STATE_HOME:-$HOME/.local/state}; '
        r'case $u in /*) ;; *) u=$HOME/.local/state ;; esac; '
        "printf '%s\\n' \"\$u$kBackupsDirSuffix\"",
  ];

  /// Copies [target] into [dir], [kRootBackupsDir] or a user directory
  /// ending in [kBackupsDirSuffix], as `<sha256>-<epoch>`, appends to
  /// its [kEditBackupIndexName], and prints the copy's path (03 §8.11).
  static List<String> backupFile(String target, String dir) {
    _checkPath(target);
    _checkBackupDir(dir);
    return ['sh', '-c', _kBackupScript, 'klabautermann-backup', target, dir];
  }

  /// Replaces [user]'s crontab, or the login user's, with stdin (JOB-04
  /// to JOB-07). `crontab` validates the whole table before it installs
  /// it; [HostCommands.commandLine] runs it under `LC_ALL=C`.
  static List<String> crontabWrite({String? user}) {
    _checkUser(user);
    return [
      'crontab',
      if (user != null) ...['-u', user],
      '-',
    ];
  }

  /// Replaces [user]'s crontab, or the login user's, with stdin while its
  /// current table still hashes to [sha256]; otherwise exits
  /// [EditExit.hashMismatch] and installs nothing (JOB-04 to JOB-07).
  static List<String> crontabWriteIfHash(String sha256, {String? user}) {
    if (!_sha256.hasMatch(sha256)) {
      throw HostCommandError('not a SHA-256', argument: sha256);
    }
    _checkUser(user);
    return [
      'sh',
      '-c',
      _kCrontabWriteIfHashScript,
      'klabautermann-crontab',
      sha256,
      if (user != null) ...['-u', user],
    ];
  }

  /// Saves [user]'s crontab, or the login user's, into [dir] as
  /// [backupFile] saves a file, indexed under [indexName]
  /// (`crontab:<user>`); an absent crontab saves as empty. Prints the
  /// copy's path.
  static List<String> crontabBackup(
    String dir, {
    required String indexName,
    String? user,
  }) {
    _checkBackupDir(dir);
    _checkUser(user);
    if (!indexName.startsWith('crontab:') ||
        indexName.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw HostCommandError('not a crontab index name', argument: indexName);
    }
    return [
      'sh',
      '-c',
      _kCrontabBackupScript,
      'klabautermann-crontab-backup',
      dir,
      indexName,
      if (user != null) ...['-u', user],
    ];
  }

  /// Prints the login user's manifest path, resolved in the login
  /// shell's environment as [userBackupsDir] resolves its directory.
  static List<String> userManifestPath() => [
    'sh',
    '-c',
    r'c=${XDG_CONFIG_HOME:-$HOME/.config}; '
        r'case $c in /*) ;; *) c=$HOME/.config ;; esac; '
        "printf '%s\\n' \"\$c$kManifestSuffix\"",
  ];

  /// Prints the footprint manifest at [path] (SAF-14, 03 §8.11), or
  /// nothing when there is none yet.
  static List<String> manifestRead(String path) {
    _checkManifest(path);
    return _readIfPresent(path);
  }

  /// Replaces the footprint manifest at [path] with stdin, atomically,
  /// while it still hashes to [baseSha256], the SHA-256 of the read the
  /// new rows were built from; otherwise exits [EditExit.hashMismatch]
  /// and leaves it as it was.
  static List<String> manifestWrite(String path, String baseSha256) {
    _checkManifest(path);
    if (!_sha256.hasMatch(baseSha256)) {
      throw HostCommandError('not a SHA-256', argument: baseSha256);
    }
    return [
      'sh',
      '-c',
      _kManifestWriteScript,
      'klabautermann-manifest',
      path,
      baseSha256,
    ];
  }

  /// Prints the index of backup directory [dir], or nothing when it has
  /// none.
  static List<String> backupIndexRead(String dir) {
    _checkBackupDir(dir);
    return _readIfPresent('$dir/$kEditBackupIndexName');
  }

  /// Replaces the index of backup directory [dir] with stdin, atomically,
  /// while it still hashes to [baseSha256]; otherwise exits
  /// [EditExit.hashMismatch] and leaves it as it was.
  static List<String> backupIndexWrite(String dir, String baseSha256) {
    _checkBackupDir(dir);
    if (!_sha256.hasMatch(baseSha256)) {
      throw HostCommandError('not a SHA-256', argument: baseSha256);
    }
    return [
      'sh',
      '-c',
      _kIndexWriteIfHashScript,
      'klabautermann-index',
      '$dir/$kEditBackupIndexName',
      baseSha256,
    ];
  }

  /// Prints each of [paths] that exists, one per line.
  static List<String> existingPaths(List<String> paths) {
    if (paths.isEmpty) throw const HostCommandError('no paths');
    paths.forEach(_checkPath);
    return [
      'sh',
      '-c',
      r'''for p; do [ -e "$p" ] && printf '%s\n' "$p"; done; :''',
      'klabautermann-exists',
      ...paths,
    ];
  }

  /// Removes the backups named [names], `<sha256>-<epoch>`, from [dir].
  static List<String> removeBackups(String dir, List<String> names) {
    _checkBackupDir(dir);
    if (names.isEmpty) throw const HostCommandError('no backups');
    for (final name in names) {
      if (!_backupName.hasMatch(name)) {
        throw HostCommandError('not a backup name', argument: name);
      }
    }
    return ['rm', '-f', '--', for (final name in names) '$dir/$name'];
  }

  /// The read of [path] that prints nothing when it is absent.
  static List<String> _readIfPresent(String path) => [
    'sh',
    '-c',
    r'[ ! -e "$1" ] || exec cat -- "$1"',
    'klabautermann-read-if-present',
    path,
  ];

  /// `sha256sum` of each of [paths] that exists, for the footprint's
  /// verification; [parseSha256List] reads the output, which leaves out a
  /// path that is gone. A gone path is not a failure, so any other exit
  /// than 0 means the list is incomplete: a path that exists but could
  /// not be read exits [EditExit.unreadable].
  static List<String> sha256List(List<String> paths) {
    if (paths.isEmpty) throw const HostCommandError('no paths');
    paths.forEach(_checkPath);
    return [
      'sh',
      '-c',
      'for p; do [ ! -e "\$p" ] || sha256sum -- "\$p" || '
          'exit ${EditExit.unreadable}; done',
      'klabautermann-sha256',
      ...paths,
    ];
  }

  /// [path] is absolute and normalized (03 §8.8), and holds no control
  /// character, which would break the backup index's lines.
  static void _checkPath(String path) {
    final reason = ArgValidators.absolutePath(path);
    if (reason != null) throw HostCommandError(reason, argument: path);
    if (path == '/' || path.endsWith('/')) {
      throw HostCommandError('not a file path', argument: path);
    }
    if (path.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw HostCommandError('path has a control character', argument: path);
    }
  }

  static void _checkUser(String? user) {
    if (user != null && ArgValidators.userName(user) != null) {
      throw HostCommandError('not a user name', argument: user);
    }
  }

  static void _checkManifest(String path) {
    _checkPath(path);
    if (path != kRootManifestPath && !path.endsWith(kManifestSuffix)) {
      throw HostCommandError('not a manifest path', argument: path);
    }
  }

  static void _checkBackupDir(String dir) {
    _checkPath(dir);
    if (dir != kRootBackupsDir && !dir.endsWith(kBackupsDirSuffix)) {
      throw HostCommandError('not a backup directory', argument: dir);
    }
  }

  /// [temp] is a temp file name [tempPathFor] makes.
  static void _checkTemp(String temp) {
    _checkPath(temp);
    final name = temp.substring(temp.lastIndexOf('/') + 1);
    final at = name.lastIndexOf(kEditTempInfix);
    if (!name.startsWith('.') ||
        at <= 1 ||
        !_token.hasMatch(name.substring(at + kEditTempInfix.length))) {
      throw HostCommandError('not an edit temp file', argument: temp);
    }
  }

  /// [temp] is [target]'s own temp file, in the same directory.
  static void _checkPair(String target, String temp) {
    _checkPath(target);
    _checkTemp(temp);
    final token = temp.substring(temp.length - kEditTempTokenLength);
    if (tempPathFor(target, token) != temp) {
      throw HostCommandError('not the target\'s temp file', argument: temp);
    }
  }
}
