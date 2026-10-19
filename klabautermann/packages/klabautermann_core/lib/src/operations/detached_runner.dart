// The detached runner (03 §7.17, SAF-23, M4 plan M11), first half: which
// runner row an operation gets, and its launch. Re-attach, the results'
// audit and cleanup follow (E17b). Only an operation that needs root runs
// as root; admin mode alone only asks the system manager to start a login
// user's operation, so it survives logout without linger.
import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show
        ElevationException,
        RemoteCommandException,
        RemoteCommandResult,
        SshLink,
        quoteShellWord;

import '../admin/admin_mode.dart';
import 'plan_types.dart';

/// Why a detached operation cannot start (03 §7.17).
enum DetachedRefusal {
  /// It needs root and admin mode is off.
  adminRequired,

  /// It needs root, and the account's passwordless sudo reaches only
  /// `docker`, which does not cover `systemd-run` or `setsid`: the
  /// preview names the missing sudo right.
  sudoRightMissing,
}

/// The runner an operation gets, or why it gets none; [mayDieAtLogout]
/// is the preview's warning fact for a `setsid` operation under logind's
/// `KillUserProcesses=yes` [U].
typedef RunnerChoice = ({
  DetachedRunner? runner,
  DetachedRefusal? refusal,
  bool mayDieAtLogout,
});

/// The first matching row of 03 §7.17's table for an operation needing
/// [level] on a host [profile] described, with admin mode on or off.
/// [sudoCoversRunners] is false under a sudo rule scoped to `docker`,
/// where only the login rows without elevation remain. Unknown probe
/// facts never enable a row: no systemd directory reads as none, and an
/// unknown linger as off.
RunnerChoice selectDetachedRunner({
  required HostProfile profile,
  required RequiredLevel level,
  required bool adminMode,
  bool sudoCoversRunners = true,
}) {
  final systemd = profile.systemdDir == true;
  if (level == RequiredLevel.admin) {
    if (!adminMode) return _refused(DetachedRefusal.adminRequired);
    if (!sudoCoversRunners) return _refused(DetachedRefusal.sudoRightMissing);
    return _chosen(
      systemd ? DetachedRunner.rootSystemd : DetachedRunner.rootSetsid,
      profile,
    );
  }
  if (adminMode && systemd && sudoCoversRunners && profile.uid != 0) {
    return _chosen(DetachedRunner.loginSystemdUid, profile);
  }
  // The user manager answers only where its runtime directory is set,
  // and stops after the last session without linger.
  if (systemd &&
      profile.lingerEnabled == true &&
      profile.xdgRuntimeDir != null) {
    return _chosen(DetachedRunner.loginSystemdUser, profile);
  }
  return _chosen(DetachedRunner.loginSetsid, profile);
}

/// The program sudo runs when [runner]'s row elevates its launch (E08's
/// argv): `systemd-run` on the systemd rows, `sh` running the `setsid`
/// launcher on the root `setsid` row; null when the row elevates nothing.
String? elevatedProgram(DetachedRunner runner) {
  if (!runner.elevated) return null;
  return runner.transientUnit ? 'systemd-run' : 'sh';
}

/// Whether the login user's sudo rules let root run [program] with any
/// arguments (03 §7.17, D66), from `sudo -l` over [link], with
/// [session]'s password on stdin when it has one. A root login and an
/// account without sudo are not checked. A listing that cannot be read,
/// or a link that fails while reading it, refuses nothing: the launch
/// then meets sudo's own refusal, or the same link failure, and reports
/// it.
Future<bool> sudoAllowsProgram({
  required SshLink link,
  required AdminSession session,
  required HostProfile profile,
  required String program,
}) async {
  if (profile.uid == 0 || profile.sudoVersionLine == null) return true;

  final password = session.password;
  final RemoteCommandResult result;
  try {
    // The C locale keeps sudo's own lines in the English the reader knows.
    result = await link.run(
      password == null ? 'LC_ALL=C sudo -n -l' : "LC_ALL=C sudo -S -p '' -l",
      stdin: password == null ? const [] : utf8.encode('$password\n'),
    );
  } on RemoteCommandException {
    return true;
  }
  return sudoListAllows('${result.stdout}\n${result.stderr}', program) ?? true;
}

RunnerChoice _refused(DetachedRefusal refusal) =>
    (runner: null, refusal: refusal, mayDieAtLogout: false);

RunnerChoice _chosen(DetachedRunner runner, HostProfile profile) => (
  runner: runner,
  refusal: null,
  mayDieAtLogout:
      runner == DetachedRunner.loginSetsid &&
      profile.killUserProcesses == 'yes',
);

/// A new operation id: [kOpIdLength] lowercase hex digits from a secure
/// source, unless a test passes [random].
String newOpId([Random? random]) {
  final source = random ?? Random.secure();
  return [
    for (var i = 0; i < kOpIdLength; i++) source.nextInt(16).toRadixString(16),
  ].join();
}

/// Why a launch did not start its operation.
enum LaunchFailure {
  /// The user operation directory could not be resolved.
  noDirectory,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// The launcher exited non-zero: `systemd-run` could not start the
  /// unit, or the `setsid` launcher could not fork.
  failed,

  /// The link failed.
  transport,
}

/// How a launch ended: [id] started in [dir] with [pid] where the
/// `setsid` rows print it, or [failure] with the launcher's [exitCode].
/// Started means the launcher returned, not that the wrapper accepted:
/// it runs in the background or in the unit, so its refusal (E08's
/// [kOpWrapperSetupFailed]) never reaches the launcher and shows as an
/// id with no record, which re-attach reports (E17b).
typedef LaunchResult = ({
  String id,
  String? dir,
  int? pid,
  LaunchFailure? failure,
  int? exitCode,
});

/// Launches [argv] as operation [id] with [runner] over [link]: the
/// operation directory is [kRootOpsDir] on the root rows and the login
/// user's, resolved in the login shell, otherwise; the launch goes
/// through [session]'s elevation where the row says so. [uid] is the
/// login user's.
Future<LaunchResult> launchDetached({
  required SshLink link,
  required DetachedRunner runner,
  required int uid,
  required List<String> argv,
  required String id,
  AdminSession? session,
}) async {
  LaunchResult failed(LaunchFailure failure, {String? dir, int? code}) =>
      (id: id, dir: dir, pid: null, failure: failure, exitCode: code);

  try {
    final String dir;
    if (runner.runsAsRoot) {
      dir = kRootOpsDir;
    } else {
      final resolved = await link.run(
        HostCommands.commandLine(
          OperationCommands.userOpsDir(),
          quote: quoteShellWord,
        ),
        stdin: const [],
      );
      final printed = resolved.stdout.trim();
      if (resolved.exitCode != 0 || !printed.startsWith('/')) {
        return failed(LaunchFailure.noDirectory, code: resolved.exitCode);
      }
      dir = printed;
    }

    final launch = OperationCommands.detachedLaunch(
      runner,
      dir: dir,
      id: id,
      uid: uid,
      argv: argv,
    );
    final result = runner.elevated
        ? await _elevated(session, launch)
        : await link.run(
            HostCommands.commandLine(launch, quote: quoteShellWord),
            stdin: const [],
          );
    if (result == null) return failed(LaunchFailure.elevationRefused, dir: dir);
    return switch (result.exitCode) {
      0 => (
        id: id,
        dir: dir,
        pid: runner.transientUnit ? null : int.tryParse(result.stdout.trim()),
        failure: null,
        exitCode: 0,
      ),
      final code => failed(LaunchFailure.failed, dir: dir, code: code),
    };
  } on ElevationException {
    return failed(LaunchFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(LaunchFailure.transport);
  } on HostCommandError {
    return failed(LaunchFailure.failed);
  }
}

/// [argv] through [session]'s executor, or null without admin mode.
Future<RemoteCommandResult?> _elevated(
  AdminSession? session,
  List<String> argv,
) async {
  if (session == null) return null;
  return session.executor.run(argv, password: session.password);
}
