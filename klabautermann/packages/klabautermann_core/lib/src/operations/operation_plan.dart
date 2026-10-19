// 03 §8.5's operation model (M4 plan M8, E09): one immutable plan per
// intent, built in the engine. Its preview and its execution read the same
// steps, so what the user confirmed is what runs; the danger findings come
// from the same steps' words.
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show DangerFinding;

import '../engine/protocol.dart'
    show ActionIntent, ActionPreview, ConfirmationTier;
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
    this.detached = false,
    this.impact,
    this.ownership,
    this.protected,
    Iterable<Revalidation> revalidate = const [],
  }) : steps = List.unmodifiable(steps),
       hostWrites = List.unmodifiable(hostWrites),
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
  final RequiredLevel requiredLevel;
  final RunnerFacts runner;
  final List<HostWriteRow> hostWrites;

  /// The steps run in a detached operation (03 §7.17), which outlives
  /// the session.
  final bool detached;

  final PlanImpact? impact;
  final PlanOwnership? ownership;
  final ProtectedReason? protected;
  final List<Revalidation> revalidate;

  /// What the linter found in the steps ([lintSteps]).
  final List<DangerFinding> danger;

  /// The tier [RunAction]'s confirmation must satisfy (03 §8.6).
  final ConfirmationTier tier;

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
  );
}

/// What the runner checks again right before a plan's first step (03
/// §8.5). Each holds what the preview saw.
sealed class Revalidation {
  const Revalidation();
}

/// The unit still loads.
final class UnitLoaded extends Revalidation {
  const UnitLoaded(this.unit);

  final String unit;
}

/// Process [pid] is still the one that started at [startTicks].
final class ProcessStarted extends Revalidation {
  const ProcessStarted(this.pid, this.startTicks);

  final int pid;
  final int startTicks;
}

/// A Docker target is unchanged: the container still has [id], or the
/// stack's configuration still hashes to it. The Docker planners check
/// these through the engine's API (M4 E15).
final class DockerTargetUnchanged extends Revalidation {
  const DockerTargetUnchanged(this.target, this.id);

  /// The container name or the stack's project.
  final String target;

  /// The container id or the configuration hash the preview saw.
  final String id;
}
