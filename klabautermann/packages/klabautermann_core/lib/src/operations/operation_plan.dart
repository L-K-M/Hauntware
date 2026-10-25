// 03 §8.5's operation model (M4 plan M8, E09): one immutable plan per
// intent, built in the engine. Its preview and its execution read the same
// steps, so what the user confirmed is what runs; the danger findings come
// from the same steps' words.
import 'package:klabautermann_host/klabautermann_host.dart'
    show DetachedRunner, UnitManager;
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show DangerFinding;

import '../engine/protocol.dart'
    show ActionIntent, ActionPreview, ActionRefusalReason, ConfirmationTier;
import 'confirmation.dart';
import 'danger.dart';
import 'plan_types.dart';

/// A planned operation. Every collection is unmodifiable, and [preview]
/// shares them, so the steps a runner takes are the ones the preview
/// showed.
@immutable
final class OperationPlan {
  /// [targetName] is what a typed confirmation must repeat: the unit,
  /// container or stack name as the user sees it. [revalidate] lists what
  /// the runner checks again right before the first step (03 §8.5).
  OperationPlan({
    required this.intent,
    required this.kind,
    required this.targetName,
    required Iterable<PlanStep> steps,
    required this.requiredLevel,
    required this.runner,
    Iterable<HostWriteRow> hostWrites = const [],
    this.detachedRunner,
    this.impact,
    this.ownership,
    this.protected,
    this.followUnit,
    Iterable<String> orphans = const [],
    Iterable<PlanWarning> warnings = const [],
    Iterable<Revalidation> revalidate = const [],
    Iterable<ShellStep> cleanup = const [],
  }) : steps = List.unmodifiable(steps),
       cleanup = List.unmodifiable(cleanup),
       hostWrites = List.unmodifiable(hostWrites),
       orphans = List.unmodifiable(orphans),
       warnings = Set.unmodifiable(warnings),
       revalidate = List.unmodifiable(revalidate),
       danger = List.unmodifiable(lintSteps(steps)),
       tier = confirmationTier(
         kind,
         protected: protected != null,
         actAnyway: ownership != null,
       ) {
    if (this.steps.isEmpty) throw ArgumentError('a plan needs a step');
    if (targetName.isEmpty) throw ArgumentError('a plan needs a target name');
  }

  final ActionIntent intent;
  final OperationKind kind;
  final String targetName;
  final List<PlanStep> steps;

  /// What the runner runs, best effort, after a step fails, such as an
  /// edit's temp file removal (03 §8.11); the preview does not list it.
  final List<ShellStep> cleanup;
  final RequiredLevel requiredLevel;
  final RunnerFacts runner;
  final List<HostWriteRow> hostWrites;

  /// The runner row of a detached operation (03 §7.17), which runs the
  /// steps on the host and outlives the session; null for a plan the
  /// session runs step by step.
  final DetachedRunner? detachedRunner;

  bool get detached => detachedRunner != null;

  final PlanImpact? impact;
  final PlanOwnership? ownership;
  final ProtectedReason? protected;

  /// The unit whose journal the app follows after the run (JOB-08).
  final String? followUnit;

  /// The stack containers `--remove-orphans` would remove (STK-06).
  final List<String> orphans;
  final Set<PlanWarning> warnings;
  final List<Revalidation> revalidate;

  /// What the linter found in the steps ([lintSteps]).
  final List<DangerFinding> danger;

  /// The tier [RunAction]'s confirmation must satisfy (03 §8.6).
  final ConfirmationTier tier;

  /// This plan with [argv], the host syslog line (SAF-13), as a last
  /// best-effort step and its row under the host writes.
  OperationPlan withAuditLine(List<String> argv) => OperationPlan(
    intent: intent,
    kind: kind,
    targetName: targetName,
    steps: [...steps, ShellStep(argv, bestEffort: true)],
    requiredLevel: requiredLevel,
    runner: runner,
    hostWrites: [...hostWrites, HostWriteRow.auditSyslog],
    detachedRunner: detachedRunner,
    impact: impact,
    ownership: ownership,
    protected: protected,
    followUnit: followUnit,
    orphans: orphans,
    warnings: warnings,
    revalidate: revalidate,
    cleanup: cleanup,
  );

  /// What [ActionPlanned] carries: the same step, host-write and finding
  /// lists, never copies.
  ActionPreview get preview => ActionPreview(
    intent: intent,
    targetName: targetName,
    steps: steps,
    hostWrites: hostWrites,
    requiredLevel: requiredLevel,
    runner: runner,
    detached: detached,
    danger: danger,
    impact: impact,
    ownership: ownership,
    protected: protected,
    requiredTier: tier,
    followUnit: followUnit,
    orphans: orphans,
    warnings: warnings,
  );
}

/// A plan, or why there is none.
typedef PlanAttempt = ({OperationPlan? plan, ActionRefusalReason? refusal});

/// What the runner checks again right before a plan's first step (03
/// §8.5). Each holds what the preview saw.
sealed class Revalidation {
  const Revalidation();
}

/// The unit still loads, or is masked, in [manager].
final class UnitLoaded extends Revalidation {
  const UnitLoaded(this.unit, {this.manager = const UnitManager.system()});

  final String unit;
  final UnitManager manager;
}

/// Process [pid] is still the one that started at [startTicks].
final class ProcessStarted extends Revalidation {
  const ProcessStarted(this.pid, this.startTicks);

  final int pid;
  final int startTicks;
}

/// What a [DockerTargetUnchanged] names.
enum DockerTargetKind { container, image, stack, volume }

/// A Docker target is unchanged: the container or image still has [id],
/// or the stack still has the containers [id] fingerprints. The runner
/// checks these through the engine's API (M4 E15).
final class DockerTargetUnchanged extends Revalidation {
  const DockerTargetUnchanged(this.kind, this.target, this.id);

  final DockerTargetKind kind;

  /// The container name, the image reference, the stack's project or
  /// the volume's name.
  final String target;

  /// The container or image id, the stack's fingerprint
  /// ([stackFingerprint]) or the volume's creation time, which a volume
  /// removed and created again under its name changes, as the preview
  /// saw it.
  final String id;
}

/// A stack's files still configure what the preview saw (STK-06): the
/// `config --hash '*'` run of [hashArgv] prints [hashes] for every
/// service, the hash each service's containers carry.
final class StackConfigUnchanged extends Revalidation {
  StackConfigUnchanged(Iterable<String> hashArgv, Map<String, String> hashes)
    : hashArgv = List.unmodifiable(hashArgv),
      hashes = Map.unmodifiable(hashes);

  final List<String> hashArgv;
  final Map<String, String> hashes;
}
