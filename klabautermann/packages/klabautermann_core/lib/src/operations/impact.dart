// The impact line a preview names (03 §8.6, D35): typed facts the app
// words, such as "drops your session" or "stops 23 running containers".
import 'plan_types.dart';

/// Stopping, restarting or reloading [unit]: a protected unit on the
/// session's path drops the session, a container engine stops its
/// [runningContainers], anything else interrupts the unit itself.
PlanImpact unitImpact(
  String unit, {
  ProtectedReason? protected,
  int? runningContainers,
}) {
  if (protected == ProtectedReason.sessionPath ||
      _sessionUnits.any(unit.startsWith)) {
    return const PlanImpact(ImpactKind.dropsSession);
  }
  if (_engineUnits.contains(unit)) {
    return PlanImpact(ImpactKind.stopsContainers, count: runningContainers);
  }
  return const PlanImpact(ImpactKind.interruptsTarget);
}

/// Removing a container: with [volumes], its anonymous volumes go too.
PlanImpact containerRemovalImpact({required bool volumes}) => volumes
    ? const PlanImpact(ImpactKind.removesVolumes)
    : const PlanImpact(ImpactKind.interruptsTarget);

/// Removing an image that [usingContainers] containers use: forcing it
/// removes an image in use.
PlanImpact? imageRemovalImpact({required int usingContainers}) =>
    usingContainers > 0
    ? PlanImpact(ImpactKind.forcesImageInUse, count: usingContainers)
    : null;

/// A stack action on [runningContainers] containers.
PlanImpact stackImpact({required int runningContainers}) =>
    PlanImpact(ImpactKind.stopsContainers, count: runningContainers);

/// Units whose stop ends SSH, the network or the VPN this session may use.
const _sessionUnits = [
  'ssh',
  'NetworkManager',
  'systemd-networkd',
  'networking',
  'network.service',
  'wicked',
  'tailscaled',
  'wg-quick@',
  'zerotier-one',
  'openvpn',
];

const _engineUnits = {
  'docker.service',
  'docker.socket',
  'containerd.service',
  'podman.service',
  'podman.socket',
};
