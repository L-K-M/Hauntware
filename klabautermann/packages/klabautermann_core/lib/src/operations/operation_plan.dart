// 03 §8.5's operation model (M4 plan M8, E09): one immutable plan per
// intent, built in the engine. Its preview and its execution read the same
// steps, so what the user confirmed is what runs; the danger findings come
// from the same steps' words.
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show DangerFinding, DangerLinter;

import '../engine/protocol.dart'
    show ActionIntent, ActionPreview, ConfirmationTier;
import 'confirmation.dart';
import 'plan_types.dart';

/// A planned operation. Every collection is unmodifiable, and [preview]
/// shares them, so the steps a runner takes are the ones the preview
/// showed.
@immutable
final class OperationPlan {
  /// [targetName] is what a typed confirmation must repeat: the unit,
  /// container or stack name as the user sees it. [expectedState] holds
  /// what re-validation compares right before the run (03 §8.5): a
  /// container id, a PID's start ticks, a stack's config hash.
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
    Map<String, String> expectedState = const {},
  }) : steps = List.unmodifiable(steps),
       hostWrites = List.unmodifiable(hostWrites),
       expectedState = Map.unmodifiable(expectedState),
       danger = List.unmodifiable(_lint(steps)),
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
  final Map<String, String> expectedState;

  /// What `DangerLinter.scan` found in the shell steps' words.
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

  // The linter matches shell words, which the exact command line quotes
  // one by one behind its locale wrapper, so it reads each step's argv
  // joined by spaces: the same words, with any `sh -c` script as text.
  static List<DangerFinding> _lint(Iterable<PlanStep> steps) => [
    for (final step in steps)
      if (step is ShellStep) ...DangerLinter.scan(step.argv.join(' ')),
  ];
}
