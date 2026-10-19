// The plain-data parts of 03 §8.5's operation plan that cross the isolate
// boundary in an ActionPreview (M4 plan M3, M8): the exact steps, the host
// writes from 8.11, who runs the steps, and the typed facts the app words
// itself (D35). Engine-side plans (operation_plan.dart) are built from
// these, so the preview and the executed steps are one object.
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show quoteShellWord;

import '../engine/protocol.dart' show RevalidationFailure;

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
/// elevation prelude) runs.
final class ShellStep extends PlanStep {
  ShellStep(
    Iterable<String> argv, {
    this.elevated = false,
    this.discardOutput = false,
    Map<int, RevalidationFailure> exitMeanings = const {},
  }) : argv = List.unmodifiable(argv),
       exitMeanings = Map.unmodifiable(exitMeanings),
       commandLine =
           HostCommands.commandLine(List.of(argv), quote: quoteShellWord) +
           (discardOutput ? _discarded : '');

  final List<String> argv;
  final String commandLine;

  /// The step's output goes to `/dev/null`, so only its exit status is
  /// read: `config -q`'s errors can quote interpolated secrets (STK-06).
  final bool discardOutput;

  /// The step runs through the elevation prelude (8.3).
  final bool elevated;

  /// Exit statuses by which the step itself reports that its target
  /// changed, such as the guarded kill's 4 for a reused PID: the run then
  /// fails as a re-validation, not as a failed step.
  final Map<int, RevalidationFailure> exitMeanings;

  @override
  String get display => elevated ? 'sudo: $commandLine' : commandLine;
}

const _discarded = ' >/dev/null 2>&1';

/// A Docker Engine API request: [method], the versioned [path] and its
/// [query], as the HTTP pool sends it.
final class ApiStep extends PlanStep {
  ApiStep({
    required this.method,
    required this.path,
    Map<String, String> query = const {},
  }) : query = Map.unmodifiable(query);

  final String method;
  final String path;
  final Map<String, String> query;

  @override
  String get display => query.isEmpty
      ? '$method $path'
      : '$method $path?${Uri(queryParameters: query).query}';
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

  /// The target restarts or stops; nothing beyond it is touched.
  interruptsTarget,
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
