// The plain-data parts of 03 §8.5's operation plan that cross the isolate
// boundary in an ActionPreview (M4 plan M3, M8): the exact steps, the host
// writes from 8.11, who runs the steps, and the typed facts the app words
// itself (D35). Engine-side plans (operation_plan.dart) are built from
// these, so the preview and the executed steps are one object.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show quoteShellWord;

import '../engine/protocol.dart' show ActionFinished, RevalidationFailure;

/// One step a plan runs: an exact shell command or an exact Docker API
/// request. The preview renders these and the runner executes these; no
/// second code path builds commands (03 §8.5).
@immutable
sealed class PlanStep {
  const PlanStep();

  /// The step as the preview shows it, exactly as it runs.
  String get display;
}

/// A shell command, [argv] quoted word by word into [commandLine] under
/// the C locale, the line the login shell (or, when [elevated], the
/// elevation prelude) runs. [input], an edit's new content, goes to the
/// command's stdin (after the password line when elevated); the preview
/// shows its size, not the text, which the app's diff shows.
final class ShellStep extends PlanStep {
  ShellStep(
    Iterable<String> argv, {
    this.elevated = false,
    this.discardOutput = false,
    this.bestEffort = false,
    this.captureOutput = false,
    this.endsLink = false,
    Iterable<String>? shownArgv,
    List<int>? input,
    Map<int, RevalidationFailure> exitMeanings = const {},
  }) : argv = List.unmodifiable(argv),
       shownArgv = List.unmodifiable(shownArgv ?? argv),
       input = input == null ? null : List.unmodifiable(input),
       exitMeanings = Map.unmodifiable(exitMeanings),
       commandLine =
           HostCommands.commandLine(List.of(argv), quote: quoteShellWord) +
           (discardOutput ? _discarded : ''),
       _shownLine =
           HostCommands.commandLine(
             List.of(shownArgv ?? argv),
             quote: quoteShellWord,
           ) +
           (discardOutput ? _discarded : '');

  final List<String> argv;
  final String commandLine;

  /// [argv] as the preview, the linter and the audit show it: the same
  /// words, with what 8.9 masks masked, as for a cron line's command.
  final List<String> shownArgv;
  final String _shownLine;

  /// The runner keeps what the step printed, redacted and capped, for
  /// [ActionFinished.output] (JOB-19).
  final bool captureOutput;

  /// What the command reads on stdin, or null for nothing.
  final List<int>? input;

  /// The step's output goes to `/dev/null`, so only its exit status is
  /// read: `config -q`'s errors can quote interpolated secrets (STK-06).
  final bool discardOutput;

  /// The step runs through the elevation prelude (8.3).
  final bool elevated;

  /// The step takes the host down (SYS-03): a link that drops while it
  /// runs counts as the host having taken it, and the host syslog line
  /// goes before it, since nothing runs after it.
  final bool endsLink;

  /// The step's failure leaves the run as it was: the runner records it
  /// in [ActionFinished.skippedSteps] and goes on. Only the host syslog
  /// line is one (SAF-13).
  final bool bestEffort;

  /// Exit statuses by which the step itself reports that its target
  /// changed, such as the guarded kill's 4 for a reused PID: the run then
  /// fails as a re-validation, not as a failed step.
  final Map<int, RevalidationFailure> exitMeanings;

  @override
  String get display {
    final line = elevated ? 'sudo: $_shownLine' : _shownLine;
    final bytes = input?.length;
    if (bytes == null) return line;
    return '$line < new content ($bytes ${bytes == 1 ? 'byte' : 'bytes'})';
  }
}

const _discarded = ' >/dev/null 2>&1';

/// A Docker Engine API request: [method], the versioned [path] and its
/// [query], as the HTTP pool sends it.
final class ApiStep extends PlanStep {
  ApiStep({
    required this.method,
    required this.path,
    Map<String, String> query = const {},
    Map<String, String>? json,
  }) : query = Map.unmodifiable(query),
       json = json == null ? null : Map.unmodifiable(json);

  final String method;
  final String path;
  final Map<String, String> query;

  /// The request's JSON body, shown as sent: plain names a create
  /// request carries (VOL-02), never a secret.
  final Map<String, String>? json;

  @override
  String get display {
    final request = query.isEmpty
        ? '$method $path'
        : '$method $path?${Uri(queryParameters: query).query}';
    final body = json;
    return body == null ? request : '$request ${jsonEncode(body)}';
  }
}

/// A one-off command in a container (CTX-08): `POST
/// /containers/{id}/exec` with [argv] and [user] at [path], then the
/// exec's start, whose output the runner captures.
final class ExecStep extends PlanStep {
  ExecStep({
    required this.path,
    required this.containerId,
    required Iterable<String> argv,
    this.user,
  }) : argv = List.unmodifiable(argv);

  /// The create request's versioned path.
  final String path;
  final String containerId;
  final List<String> argv;
  final String? user;

  /// The create request and its body, as the API sends them.
  @override
  String get display =>
      'POST $path '
      '${jsonEncode({'Cmd': argv, if (user != null) 'User': user, 'Tty': false})}';
}

/// What a plan needs of the session (03 §8.2): the login user's own
/// rights, or admin mode's elevation.
enum RequiredLevel { login, admin }

/// The MVP rows of 03 §8.11's host write inventory a plan may cause.
/// Anything a plan writes beyond its rows is a defect, which the M4
/// inventory test checks.
enum HostWriteRow {
  /// `${XDG_STATE_HOME:-~/.local/state}/klabautermann/ops/<id>.{json,log}`.
  userOperationRecords,

  /// `/var/lib/klabautermann/ops/`, files owned by the login user.
  rootOperationRecords,

  /// The transient unit `klabautermann-op-<id>`, collected.
  transientUnit,

  /// Engine state the user's Docker action changes.
  engineState,

  /// wtmp, lastlog and the auth log, from the SSH connection itself.
  loginRecords,

  /// The `logger -t klabautermann` line in the host's journal or syslog
  /// after each run (SAF-13, v1).
  auditSyslog,

  /// The edited file or crontab itself (v1, SAF-12).
  editTarget,

  /// `.<name>.klabautermann-tmp-<token>` beside the target, renamed over
  /// it or removed (v1).
  editTempFile,

  /// `~/.local/state/klabautermann/backups/` and its index (v1).
  userBackups,

  /// `/var/lib/klabautermann/backups/`, root 0700, and its index (v1).
  rootBackups,

  /// `~/.config/klabautermann/manifest.json` or
  /// `/etc/klabautermann/manifest.json`, written with the first backup
  /// (v1, SAF-14).
  footprintManifest,

  /// The package manager's cached lists, which PKG-05 refreshes.
  packageLists,
}

/// How the steps reach their target.
enum RunnerCredentials {
  /// The SSH session's own rights.
  session,

  /// Admin mode's password through the elevation prelude.
  adminPassword,

  /// A NOPASSWD rule (rung 2) or a root login (rung 1).
  passwordless,
}

/// Who runs a plan's steps (SAF-04): the account they run as, the Docker
/// route for API steps, and the credentials.
@immutable
final class RunnerFacts {
  const RunnerFacts({
    required this.identity,
    this.engine,
    this.credentials = RunnerCredentials.session,
  });

  /// The account the steps run as: the login user, or `root`.
  final String identity;

  /// The Docker route the API steps take, as 5.9 labels it; null when
  /// the plan has none.
  final String? engine;

  final RunnerCredentials credentials;
}

/// A fact the preview warns about; the app words it (D35).
enum PlanWarning {
  /// Running services are named only under a compose profile, which the
  /// labels do not record, so the redeploy leaves them as they are
  /// (STK-06) [U].
  profileGatedServices,

  /// The CLI could not list every profile's services, so an orphan may
  /// be a profile-gated service (STK-06).
  profilesUnknown,

  /// A `setsid` operation, which logind ends at logout under
  /// `KillUserProcesses=yes` (03 §7.17).
  mayDieAtLogout,

  /// A unit file the host's systemd cannot check before the rename:
  /// `systemd-analyze verify` reads a temp copy as the unit only from
  /// systemd 250 (03 §8.5).
  unitNotVerified,
}

/// The consequence a plan's impact line names (03 §8.6); the app words
/// it (D35).
enum ImpactKind {
  /// The target carries this session (sshd, the network, a VPN).
  dropsSession,

  /// [PlanImpact.count] running containers stop.
  stopsContainers,

  /// The container's anonymous volumes are removed with it: their data
  /// has no way back.
  removesVolumes,

  /// An image in use by [PlanImpact.count] containers is removed anyway.
  forcesImageInUse,

  /// A volume is removed with the data in it: it has no way back.
  deletesVolumeData,

  /// The target restarts or stops; nothing beyond it is touched.
  interruptsTarget,

  /// The host restarts: everything on it stops, and the link drops until
  /// it is back (SYS-03).
  restartsHost,

  /// The host turns off and stays off until someone starts it (SYS-03).
  stopsHost,
}

@immutable
final class PlanImpact {
  const PlanImpact(this.kind, {this.count});

  final ImpactKind kind;

  /// How many things the impact reaches, when it counts them.
  final int? count;
}

/// Why a target is protected (03 §8.6, SAF-22). A protected target needs
/// the typed confirmation.
enum ProtectedReason {
  /// The built-in list: sshd, network managers, firewalls, VPNs, the
  /// container engines and PID 1.
  builtIn,

  /// The session's own path: its sshd, the sampler's PIDs and their
  /// parents.
  sessionPath,

  /// A container publishing the session's SSH port or a VPN port.
  publishesSessionPort,

  /// The user marked it on this device (M4 plan Q1).
  userMarked,
}

/// Another manager owns the target (03 §8.7): acting needs the tier-2
/// "act anyway" step naming it, and some plans refuse outright.
@immutable
final class PlanOwnership {
  const PlanOwnership(this.manager);

  /// The manager's name as its marker gives it, for example `coolify`.
  final String manager;
}

/// One object a prune removes, as its preview lists it (DKE-05): its
/// name, or a short id when it has none, and its size in bytes when the
/// engine reports one per object.
@immutable
final class PruneItem {
  const PruneItem(this.name, {this.size});

  final String name;
  final int? size;
}

/// Why a prune leaves an object that its kind covers (DKE-05's exemption
/// labels).
enum PruneExemption {
  /// A container uses the image, mounts the volume or is on the network.
  inUse,

  /// One of the engine's own networks: `bridge`, `host` or `none`.
  builtin,
}

/// An object a prune leaves, and why (DKE-05).
@immutable
final class PruneKept {
  const PruneKept(this.name, this.reason);

  final String name;
  final PruneExemption reason;
}

/// What a prune's preview lists (03 §7.12 DKE-05): what the same filters
/// the prune sends match now, what they leave and why, and the bytes the
/// prune frees when the engine reports them.
@immutable
final class PrunePreview {
  PrunePreview({
    required Iterable<PruneItem> removes,
    Iterable<PruneKept> kept = const [],
    int? count,
    this.freed,
  }) : removes = List.unmodifiable(removes),
       kept = List.unmodifiable(kept),
       count = count ?? removes.length {
    assert(
      this.removes.isEmpty || this.count == this.removes.length,
      'only the build cache counts what it does not list',
    );
  }

  /// The objects removed, by name; empty for the build cache, whose
  /// records have no names to show.
  final List<PruneItem> removes;
  final List<PruneKept> kept;

  /// How many objects the prune removes.
  final int count;

  /// The bytes the prune frees: the sum of [removes]' sizes, or the
  /// engine's reclaimable figure where it reports no size per object.
  final int? freed;
}

/// An API step the daemon answered with an error it explained, as a pull
/// whose stream ends on an `errorDetail` (IMG-03): the runner fails the
/// step with [detail] as its output and [status] when the daemon sent
/// one.
final class ApiStepError implements Exception {
  const ApiStepError(this.detail, {this.status});

  final String detail;
  final int? status;

  @override
  String toString() => 'ApiStepError($status): $detail';
}
