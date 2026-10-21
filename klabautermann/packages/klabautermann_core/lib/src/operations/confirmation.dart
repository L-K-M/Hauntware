// 03 §8.6's confirmation tiers as a pure function (SAF-05, M4 E09): what
// an operation needs from the user before it runs.
import '../engine/protocol.dart' show ConfirmationTier;

/// The kinds of operation 03 §8.6's table sorts into tiers. Reads are no
/// operations: tier 0 needs no plan.
enum OperationKind {
  start(ConfirmationTier.acknowledge),
  stop(ConfirmationTier.acknowledge),
  restart(ConfirmationTier.acknowledge),
  reload(ConfirmationTier.acknowledge),
  pause(ConfirmationTier.acknowledge),
  unpause(ConfirmationTier.acknowledge),
  kill(ConfirmationTier.acknowledge),
  runTimerNow(ConfirmationTier.acknowledge),

  /// A cron line's command, run once now (JOB-19).
  cronRunNow(ConfirmationTier.acknowledge),
  stackStart(ConfirmationTier.acknowledge),
  stackStop(ConfirmationTier.acknowledge),
  stackRestart(ConfirmationTier.acknowledge),

  /// A one-off command in a container (CTX-08).
  containerExec(ConfirmationTier.acknowledge),

  /// Pull and redeploy, keeping orphans.
  redeploy(ConfirmationTier.acknowledge),
  redeployRemovingOrphans(ConfirmationTier.typedPhrase),
  stackServicePull(ConfirmationTier.acknowledge),
  stackServiceRecreate(ConfirmationTier.acknowledge),
  stackServiceScale(ConfirmationTier.acknowledge),
  removeContainer(ConfirmationTier.acknowledge),
  removeContainerWithVolumes(ConfirmationTier.typedPhrase),
  removeUnusedImage(ConfirmationTier.acknowledge),
  forceRemoveImageInUse(ConfirmationTier.typedPhrase),
  prune(ConfirmationTier.typedPhrase),
  composeDown(ConfirmationTier.typedPhrase),
  crontabOverwrite(ConfirmationTier.typedPhrase),
  reboot(ConfirmationTier.typedPhrase),
  packageUpgrade(ConfirmationTier.typedPhrase);

  const OperationKind(this.baseTier);

  /// The tier the kind needs on a non-protected target nobody else owns.
  final ConfirmationTier baseTier;
}

/// The tier an operation of [kind] needs (03 §8.6): its base tier, raised
/// to the typed confirmation for a [protected] target, an "act anyway" on
/// a target another manager owns ([actAnyway], 8.7), or a [fleetWide]
/// action.
ConfirmationTier confirmationTier(
  OperationKind kind, {
  bool protected = false,
  bool actAnyway = false,
  bool fleetWide = false,
}) {
  if (protected || actAnyway || fleetWide) return ConfirmationTier.typedPhrase;
  return kind.baseTier;
}

/// Whether [confirmation]'s tier and phrase satisfy [required] for a
/// target named [targetName]: a typed confirmation must name the target
/// exactly, and a lower tier never satisfies a higher one.
bool confirmationSatisfies({
  required ConfirmationTier required,
  required ConfirmationTier given,
  required String targetName,
  String? phrase,
}) {
  if (given.index < required.index) return false;
  if (required != ConfirmationTier.typedPhrase) return true;
  return given == ConfirmationTier.typedPhrase && phrase == targetName;
}
