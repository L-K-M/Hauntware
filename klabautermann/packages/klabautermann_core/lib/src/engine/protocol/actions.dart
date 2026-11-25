import 'package:klabautermann_host/klabautermann_host.dart'
    show KillSignal, PowerVerb, SystemctlVerb;
import 'package:meta/meta.dart';
// DangerLinter's findings are plain data: a severity and three values.
import 'package:seance_core/seance_core.dart' show DangerFinding;

import '../../operations/plan_types.dart';
import 'host_queries.dart' show UnitScope;

/// A one-off command's output (CTX-08, JOB-19), with secrets redacted as the
/// audit log redacts them, at most [kExecOutputMax] bytes in all.
@immutable
final class ExecOutput {
  const ExecOutput({
    required this.stdout,
    required this.stderr,
    this.truncated = false,
  });

  final String stdout;
  final String stderr;

  /// Whether the command printed more than [kExecOutputMax] bytes, the
  /// rest of which was read and dropped.
  final bool truncated;
}

/// The most a one-off command's output keeps [E] (CTX-08).
const int kExecOutputMax = 1024 * 1024;

/// Why a plan failed.
enum ActionFailure {
  /// The server's link is gone.
  noLink,

  /// The target changed since the preview (03 §8.5); nothing ran.
  revalidation,

  /// Elevation refused a step: admin mode ended or the password changed.
  elevationRefused,

  /// A step exited non-zero or answered an HTTP error; later steps did
  /// not run.
  stepFailed,

  /// The link failed during a step.
  transport,

  /// A step ran past its time limit (`StepTimeout`); the runner closed
  /// its channel, which can stop the command on the host.
  timedOut,

  /// The engine has no runner for an API step yet (M4 E15).
  unsupportedStep,

  /// polkit refused a step run without elevation: admin mode would run
  /// it (03 §7.5).
  adminRequired,

  /// A detached operation ended before it recorded a result (03 §7.17):
  /// its wrapper was killed, at logout or by a reboot.
  interrupted,

  /// A detached operation did not start: its directory could not be
  /// resolved, or `systemd-run` or `setsid` failed, with [exitCode].
  launchFailed,
}

/// What re-validation found changed (03 §8.5).
enum RevalidationFailure {
  /// The unit no longer loads.
  unitMissing,

  /// The process exited.
  processGone,

  /// The PID now names another process: its start time differs.
  processReused,

  /// The container id or the stack's configuration changed.
  targetChanged,

  /// An edited file or crontab no longer has the hash the edit started
  /// from: someone else changed it (03 §8.5). The app reads it again and
  /// shows the difference.
  contentChanged,

  /// The check could not read what it compares.
  unreadable,
}

/// Why an [ActionRefused] refused; the app words each (D35).
enum ActionRefusalReason {
  /// The action has no planner in this engine.
  notImplemented,

  /// No previewed plan has the id, or it already ran.
  unknownPlan,

  /// The plan outlived its five minutes; plan again.
  expiredPlan,

  /// The server's link was re-established since the preview; plan again.
  stalePlan,

  /// The confirmation does not meet the plan's tier, or does not name
  /// the target.
  confirmationMismatch,

  /// The server is observe-only: management is off for it (SAF-01).
  observeOnly,

  /// Read-only mode is on, for the server or for every server (SAF-06).
  readOnly,

  /// The plan needs admin mode, which is off for the server (03 §8.2).
  adminRequired,

  /// The intent names no valid target: a unit name outside systemd's
  /// grammar, a verb the MVP does not offer, a timer that activates
  /// nothing.
  invalidTarget,

  /// The target changed since the app saw it: the process exited, or its
  /// PID now names another process.
  targetChanged,

  /// The server has no ready link to plan over.
  noLink,

  /// The server's Docker endpoint could not be reached (M4 E15).
  engineUnavailable,

  /// Containers use the image, and the removal did not ask to force it
  /// (IMG-02).
  imageInUse,

  /// A container mounts the volume, so the engine would refuse its
  /// removal (VOL-02).
  volumeInUse,

  /// A volume of that name already exists (VOL-02).
  volumeExists,

  /// A container holds an endpoint on the network (DNW-02).
  networkInUse,

  /// `bridge`, `host` and `none` are the engine's own and stay (DNW-01).
  builtinNetwork,

  /// A prune's filters match nothing now (DKE-05).
  nothingToPrune,

  /// The stack's services depend on each other in a cycle, so there is no
  /// order to act in (STK-03).
  dependencyCycle,

  /// A manager's labels mark the stack, and a redeploy offers no act
  /// anyway (STK-06, 03 §8.7).
  stackManaged,

  /// The stack's files are not verified as its source (STK-01), so its
  /// commands cannot be rebuilt from them (STK-06).
  stackUnverified,

  /// Only the legacy `docker-compose` is installed, which stays read-only
  /// (STK-05).
  legacyComposeOnly,

  /// The detached operation needs root and the account's passwordless
  /// sudo reaches only `docker`, which cannot start a root runner (03
  /// §7.17).
  sudoRightMissing,

  /// Root would write into a directory that an account other than root
  /// can change, where a swapped symlink could redirect its writes (03
  /// §7.17, §9).
  userWritableDirectory,
}

/// What the user wants done (03 §10.1 `intent`, M4 plan M3): one variant
/// per MVP action. The engine validates every value again before it builds
/// a plan from it.
@immutable
sealed class ActionIntent {
  const ActionIntent(this.serverId);

  final String serverId;
}

/// [intent]'s kind as the audit log and the operation records store it,
/// and the app words it (`activityAction`). The keys are the intent
/// types' names, written out so that stored records stay readable however
/// the build names its types; never change one.
String actionKeyOf(ActionIntent intent) => switch (intent) {
  KillProcess() => 'KillProcess',
  UnitAction() => 'UnitAction',
  StartTimer() => 'StartTimer',
  RefreshPackageLists() => 'RefreshPackageLists',
  PowerAction() => 'PowerAction',
  RunCronJob() => 'RunCronJob',
  RunSnippet() => 'RunSnippet',
  ContainerAction() => 'ContainerAction',
  ContainerBulkAction() => 'ContainerBulkAction',
  ContainerExec() => 'ContainerExec',
  RemoveContainer() => 'RemoveContainer',
  RemoveImage() => 'RemoveImage',
  CreateVolume() => 'CreateVolume',
  RemoveVolume() => 'RemoveVolume',
  RemoveNetwork() => 'RemoveNetwork',
  PullImage() => 'PullImage',
  PruneDocker() => 'PruneDocker',
  StackAction() => 'StackAction',
  StackComposeAction() => 'StackComposeAction',
  RedeployStack() => 'RedeployStack',
  EditFile() => 'EditFile',
  KeepLastBackups() => 'KeepLastBackups',
  RemoveBackups() => 'RemoveBackups',
};

/// Signals process [pid] (PRC-02), only while its start time still reads
/// [startTicks], so a reused PID is never hit (03 §8.5).
final class KillProcess extends ActionIntent {
  const KillProcess(
    super.serverId, {
    required this.pid,
    required this.startTicks,
    this.signal = KillSignal.sigterm,
  });

  final int pid;
  final int startTicks;
  final KillSignal signal;
}

/// Starts, stops, restarts or reloads a system unit (SVC-03).
final class UnitAction extends ActionIntent {
  const UnitAction(
    super.serverId, {
    required this.unit,
    required this.verb,
    this.scope = UnitScope.system,
  });

  final String unit;
  final SystemctlVerb verb;
  final UnitScope scope;
}

/// Runs a timer's service now (JOB-08), the system's or the login
/// user's.
final class StartTimer extends ActionIntent {
  const StartTimer(
    super.serverId, {
    required this.timer,
    this.scope = UnitScope.system,
  });

  final String timer;
  final UnitScope scope;
}

/// Refreshes the package manager's lists as root (PKG-05, 03 §7.8), in
/// admin mode, so the next package check reads current metadata.
final class RefreshPackageLists extends ActionIntent {
  const RefreshPackageLists(super.serverId);
}

/// Reboots or powers off the server (SYS-03, 03 §7.11) as root, in admin
/// mode, after the user types its host name. The run ends once the host
/// takes the command; the app waits for a rebooted host to answer again.
final class PowerAction extends ActionIntent {
  const PowerAction(super.serverId, this.verb);

  final PowerVerb verb;
}

/// Runs a cron line's command once, now, as the user cron runs it as
/// (03 §7.7, JOB-19): `sh -c` with the line's `%` text on standard input,
/// and its output in [ActionFinished.output]. [source] and [raw] name the
/// line as the jobs list shows it, masked; the engine reads the source
/// again and finds the line by its masked form.
final class RunCronJob extends ActionIntent {
  const RunCronJob(super.serverId, {required this.source, required this.raw});

  /// [CronJob.source]: `crontab`, `crontab -u <user>`, `/etc/crontab` or
  /// an `/etc/cron.d/` file.
  final String source;

  /// The line as the jobs list shows it, masked.
  final String raw;
}

/// Runs a Séance snippet's [command], its placeholders already filled,
/// once on the server as the login user (03 §7.21, AUT-01): `sh -c`,
/// with its output in [ActionFinished.output]. [title] names it in the
/// preview and the audit log.
final class RunSnippet extends ActionIntent {
  const RunSnippet(
    super.serverId, {
    required this.title,
    required this.command,
  });

  final String title;
  final String command;
}

/// What [ContainerAction] does to a container (CTR-02).
enum ContainerVerb { start, stop, restart, pause, unpause, kill }

/// Changes a container's state (CTR-02); [signal] only with
/// [ContainerVerb.kill], whose default is the engine's (`SIGKILL`).
final class ContainerAction extends ActionIntent {
  const ContainerAction(
    super.serverId, {
    required this.containerId,
    required this.verb,
    this.signal,
  });

  final String containerId;
  final ContainerVerb verb;
  final KillSignal? signal;
}

/// What [ContainerBulkAction] does to each container it names (CTR-07).
enum ContainerBulkVerb {
  start,
  stop,
  restart,

  /// Removal without its anonymous volumes and without `force`, so only
  /// a container that is not up.
  remove;

  /// Whether a container in [state], as the Engine API names it, takes
  /// this verb, as its own actions offer it: start for one that is not
  /// up, stop for one running or restarting, restart for one running,
  /// remove for one not up. Paused and removing ones take none.
  bool appliesTo(String? state) => switch (this) {
    start || remove => const {'created', 'exited', 'dead'}.contains(state),
    stop => state == 'running' || state == 'restarting',
    restart => state == 'running',
  };
}

/// The most containers one [ContainerBulkAction] names [E]: each takes
/// a request to plan and one to re-validate.
const kContainerBulkMax = 100;

/// One verb on several containers (CTR-07), as one plan with a step per
/// container in [containerIds]' order, each by its full id. The engine
/// leaves out a container whose state does not take [verb]
/// ([ContainerBulkVerb.appliesTo]) and refuses when none is left.
final class ContainerBulkAction extends ActionIntent {
  ContainerBulkAction(
    super.serverId, {
    required Iterable<String> containerIds,
    required this.verb,
  }) : containerIds = List.unmodifiable(containerIds);

  final List<String> containerIds;
  final ContainerBulkVerb verb;
}

/// Runs [argv] once in [containerId] without a TTY (03 §7.13, CTX-08), as
/// [user] where set, and reports its output and exit code in
/// [ActionFinished.output] and [ActionFinished.exitCode].
final class ContainerExec extends ActionIntent {
  ContainerExec(
    super.serverId, {
    required this.containerId,
    required Iterable<String> argv,
    this.user,
  }) : argv = List.unmodifiable(argv);

  final String containerId;
  final List<String> argv;
  final String? user;
}

/// Removes a container (CTR-05), its anonymous volumes with [volumes],
/// a running one with [force].
final class RemoveContainer extends ActionIntent {
  const RemoveContainer(
    super.serverId, {
    required this.containerId,
    this.volumes = false,
    this.force = false,
  });

  final String containerId;
  final bool volumes;
  final bool force;
}

/// Removes an image by reference or id (IMG-02); one in use only with
/// [force].
final class RemoveImage extends ActionIntent {
  const RemoveImage(super.serverId, {required this.image, this.force = false});

  final String image;
  final bool force;
}

/// Creates a named volume with [driver] (03 §7.15 VOL-02); null asks
/// for the engine's default, `local`.
final class CreateVolume extends ActionIntent {
  const CreateVolume(super.serverId, {required this.name, this.driver});

  final String name;
  final String? driver;
}

/// Removes the volume [name] and the data in it (03 §7.15 VOL-02),
/// behind the typed confirmation; one a container mounts is refused.
final class RemoveVolume extends ActionIntent {
  const RemoveVolume(super.serverId, {required this.name});

  final String name;
}

/// Removes the network [networkId] (03 §7.15 DNW-02): never a built-in
/// one, and not while a container holds an endpoint on it.
final class RemoveNetwork extends ActionIntent {
  const RemoveNetwork(super.serverId, {required this.networkId});

  final String networkId;
}

/// How an image pull runs (03 §7.14 IMG-03, REG-01).
enum PullRoute {
  /// `POST /images/create` with per-layer progress; the daemon pulls
  /// anonymously, and closing the view stops it.
  engine,

  /// The host's `docker pull` over the link, with the host's own
  /// `docker login` and credential helpers; it ends with its channel.
  host,

  /// The host's `docker pull` as a detached operation (03 §7.17), which
  /// outlives a closed view or a backgrounded phone.
  hostDetached,
}

/// Pulls the image [reference] (03 §7.14 IMG-03): `name`, `name:tag` or
/// `name@digest`, with a registry host when it has one. A name without a
/// tag pulls `latest`, never every tag. [via] says how; a private
/// registry's credentials are the host's own (REG-01), which only the
/// host routes use.
final class PullImage extends ActionIntent {
  const PullImage(
    super.serverId, {
    required this.reference,
    this.via = PullRoute.engine,
  });

  final String reference;
  final PullRoute via;
}

/// The kinds of unused Docker objects a prune removes (03 §7.12 DKE-05).
enum DockerPruneKind { containers, images, volumes, networks, buildCache }

/// Removes the unused objects of [kind] (DKE-05, IMG-06): stopped
/// containers, dangling images or with [all] every image no container
/// uses, volumes no container mounts, user-defined networks no container
/// is on, or the build cache no build uses. The preview lists them first.
final class PruneDocker extends ActionIntent {
  const PruneDocker(super.serverId, {required this.kind, this.all = false})
    : assert(!all || kind == DockerPruneKind.images, 'only images prune all');

  final DockerPruneKind kind;

  /// For images, every unused one rather than the dangling ones only
  /// (`docker image prune -a`).
  final bool all;
}

/// What [StackAction] does to a Compose project (STK-03).
enum StackVerb { start, stop, restart }

/// Starts, stops or restarts a Compose project's containers (STK-03), or
/// only [service]'s (STK-23). [actAnyway] confirms acting on a stack
/// another manager owns (03 §8.7).
final class StackAction extends ActionIntent {
  const StackAction(
    super.serverId, {
    required this.project,
    required this.verb,
    this.service,
    this.actAnyway = false,
  });

  final String project;
  final StackVerb verb;
  final String? service;
  final bool actAnyway;
}

/// What [StackComposeAction] runs on a Compose project (STK-23).
enum StackComposeVerb {
  /// Pull one service's image.
  pullService,

  /// Recreate one service's containers even when unchanged.
  recreateService,

  /// Set one service's replica count.
  scaleService,

  /// Take the whole stack down, never with its volumes.
  down,
}

/// A compose operation on a verified, unmanaged stack (STK-23), run as
/// one detached operation as STK-06's redeploy is: [service] for every
/// verb but [StackComposeVerb.down], and [replicas] for
/// [StackComposeVerb.scaleService].
final class StackComposeAction extends ActionIntent {
  const StackComposeAction(
    super.serverId, {
    required this.project,
    required this.verb,
    this.service,
    this.replicas,
  });

  final String project;
  final StackComposeVerb verb;
  final String? service;
  final int? replicas;
}

/// Pulls a verified, unmanaged stack's images and recreates it (STK-06),
/// removing orphan containers with [removeOrphans].
final class RedeployStack extends ActionIntent {
  const RedeployStack(
    super.serverId, {
    required this.project,
    this.removeOrphans = false,
  });

  final String project;
  final bool removeOrphans;
}

/// What an edit reads and writes (03 §8.5, SAF-12, X-05).
@immutable
sealed class EditTarget {
  const EditTarget();
}

/// A file by its absolute, normalized path (03 §8.8).
final class FileTarget extends EditTarget {
  const FileTarget(this.path);

  final String path;

  @override
  bool operator ==(Object other) => other is FileTarget && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A crontab (JOB-04 to JOB-07): the login user's, or [user]'s, which
/// another account's needs admin mode.
final class CrontabTarget extends EditTarget {
  const CrontabTarget({this.user});

  final String? user;

  @override
  bool operator ==(Object other) =>
      other is CrontabTarget && other.user == user;

  @override
  int get hashCode => Object.hash(CrontabTarget, user);
}

/// One file of the compose project [project] (03 §7.16 STK-07): a config
/// or environment file its containers recorded, or the `.env` in its
/// working directory, as [DockerStackFileQuery] reads them. Only a
/// verified project's files are read or written, and a write checks the
/// candidate with `compose config -q` before it replaces the file.
final class StackFileTarget extends EditTarget {
  const StackFileTarget({required this.project, required this.path});

  final String project;

  /// The file's absolute path, as the project's labels name it.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is StackFileTarget &&
      other.project == project &&
      other.path == path;

  @override
  int get hashCode => Object.hash(StackFileTarget, project, path);
}

/// Replaces [target]'s content with [text] (SAF-12, X-05), only while the
/// target still has [baseSha256], the hash its [ReadEditable] read. The
/// plan backs the target up first, writes a temp file beside it, carries
/// its owner, mode, ACL and xattrs over (D67) and renames it over the
/// target; a crontab goes through `crontab -`. [resolvedPath] is the
/// [EditContent.resolvedPath] the read reported: a link retargeted since
/// is refused as a changed target.
final class EditFile extends ActionIntent {
  const EditFile(
    super.serverId, {
    required this.target,
    required this.text,
    required this.baseSha256,
    this.resolvedPath,
  });

  final EditTarget target;
  final String text;
  final String baseSha256;
  final String? resolvedPath;
}

/// Whose backups a footprint action or row is (03 §8.11): the login
/// user's, under its home, or root's under `/var/lib`, which needs admin
/// mode.
enum FootprintScope { user, root }

/// Keeps the newest [count] backups of each file in [scope]'s backup
/// directory and removes the rest, with their index lines (SAF-14,
/// "keep last N"; tier 1).
final class KeepLastBackups extends ActionIntent {
  const KeepLastBackups(super.serverId, {required this.scope, this.count = 5})
    : assert(count >= 1, 'keep at least one');

  final FootprintScope scope;
  final int count;
}

/// Removes every backup of [source], a path or `crontab:<user>`, from
/// [scope]'s backup directory (SAF-14). They are the only undo of the
/// edits they back up, so this needs the typed confirmation.
final class RemoveBackups extends ActionIntent {
  const RemoveBackups(
    super.serverId, {
    required this.scope,
    required this.source,
  });

  final FootprintScope scope;
  final String source;
}

/// The app's safety preferences (M4 plan M4, SAF-01, SAF-06): per server,
/// whether management is on and whether it is read-only, plus the global
/// read-only switch and admin mode's inactivity expiry.
@immutable
final class SafetyPolicy {
  const SafetyPolicy({
    this.globalReadOnly = false,
    this.servers = const {},
    this.adminExpiry = kDefaultAdminExpiry,
  });

  final bool globalReadOnly;

  /// By server id; a server without an entry has the default: management
  /// off.
  final Map<String, ServerSafety> servers;

  /// One of [kAdminExpiryChoices].
  final Duration adminExpiry;
}

/// One server's safety preferences. Management is off by default
/// (SAF-01): the server is observed, never changed.
@immutable
final class ServerSafety {
  const ServerSafety({
    this.management = false,
    this.readOnly = false,
    this.marks = const {},
    this.hostAuditLine = true,
  });

  final bool management;
  final bool readOnly;

  /// Whether a run writes the host syslog line (SAF-13): on by default,
  /// and the synced `pref` record's value for a synced server.
  final bool hostAuditLine;

  /// Targets the user marked protected on this device (SAF-22): unit,
  /// container and stack names. They stay device-local until v1's `pref`
  /// records (M4 plan Q1).
  final Set<String> marks;

  ServerSafety copyWith({
    bool? management,
    bool? readOnly,
    Set<String>? marks,
    bool? hostAuditLine,
  }) => ServerSafety(
    management: management ?? this.management,
    readOnly: readOnly ?? this.readOnly,
    marks: marks ?? this.marks,
    hostAuditLine: hostAuditLine ?? this.hostAuditLine,
  );
}

/// Admin mode's default inactivity expiry [E] (03 §8.2).
const kDefaultAdminExpiry = Duration(minutes: 15);

/// The expiries the Safety tab offers (M4 plan M5).
const kAdminExpiryChoices = [
  Duration(minutes: 5),
  kDefaultAdminExpiry,
  Duration(minutes: 30),
  Duration(minutes: 60),
];

/// How far 03 §8.6's tiers make the user go before a plan runs.
enum ConfirmationTier {
  /// No confirmation needed (read-only-shaped plans).
  none,

  /// A dialog acknowledgement.
  acknowledge,

  /// The user types the target's name (protected targets, 03 §8.6).
  typedPhrase,
}

/// The user's answer to [ActionPlanned]'s tier requirement (03 §8.6).
@immutable
final class ActionConfirmation {
  const ActionConfirmation({required this.tier, this.phrase});

  final ConfirmationTier tier;

  /// The typed target name when [tier] is [ConfirmationTier.typedPhrase].
  final String? phrase;
}

/// What [PlanAction] previews before anything runs (03 §8.5, SAF-04):
/// the exact steps the plan will run, the host writes they cause, who runs
/// them, the typed risk facts the app words (D35), and the tier
/// [RunAction] must satisfy. The engine's plan and this preview share the
/// step list, so what the user confirms is what runs.
@immutable
final class ActionPreview {
  const ActionPreview({
    required this.intent,
    required this.targetName,
    required this.steps,
    required this.requiredLevel,
    required this.runner,
    required this.requiredTier,
    this.hostWrites = const [],
    this.detached = false,
    this.danger = const [],
    this.impact,
    this.ownership,
    this.protected,
    this.followUnit,
    this.orphans = const [],
    this.prune,
    this.warnings = const {},
  });

  final ActionIntent intent;

  /// What a typed confirmation repeats.
  final String targetName;

  final List<PlanStep> steps;
  final RequiredLevel requiredLevel;
  final RunnerFacts runner;
  final ConfirmationTier requiredTier;
  final List<HostWriteRow> hostWrites;

  /// The steps run as a detached operation (03 §7.17).
  final bool detached;

  /// What DangerLinter found in the shell steps.
  final List<DangerFinding> danger;

  final PlanImpact? impact;
  final PlanOwnership? ownership;

  /// Why the target is protected, or null when it is not.
  final ProtectedReason? protected;

  /// The unit whose journal shows the run's effect, from the run's start:
  /// JOB-08's timer service (03 §7.7).
  final String? followUnit;

  /// The stack's containers whose service its files no longer name,
  /// which `--remove-orphans` would remove (STK-06).
  final List<String> orphans;

  /// What a prune removes and what it leaves, and why (DKE-05).
  final PrunePreview? prune;

  final Set<PlanWarning> warnings;
}
