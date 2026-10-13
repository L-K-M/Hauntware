import 'package:meta/meta.dart';

import '../masking.dart';

/// Managers whose containers and stacks Klabautermann treats as read-only
/// (03 §8.7 DKE-10, STK-10). Actions need an explicit tier-2 "act
/// anyway" step naming the owner.
enum ExternalManager {
  portainer('Portainer'),
  coolify('Coolify'),
  dokploy('Dokploy'),
  casaos('CasaOS'),
  umbrel('Umbrel'),
  trueNas('TrueNAS'),
  runtipi('Runtipi'),
  dockhand('Dockhand'),
  dockge('Dockge'),
  swarm('Swarm'),
  systemd('systemd');

  const ExternalManager(this.displayName);

  final String displayName;
}

/// One label that marks a target as owned by another manager (03 §8.7).
@immutable
final class OwnershipMarker {
  const OwnershipMarker({
    required this.manager,
    required this.label,
    this.value,
  });

  final ExternalManager manager;
  final String label;
  final String? value;
}

/// The ownership verdict for a container or stack (03 §8.7). Ownership
/// can only make a target more read-only, never less.
@immutable
final class Ownership {
  const Ownership(this.markers);

  static const Ownership none = Ownership(<OwnershipMarker>[]);

  final List<OwnershipMarker> markers;

  bool get isOwned => markers.isNotEmpty;

  /// The marker to name in the "managed by X" badge, chosen by the fixed
  /// priority below.
  OwnershipMarker? get primary {
    for (final manager in _priority) {
      for (final m in markers) {
        if (m.manager == manager) return m;
      }
    }
    return markers.isEmpty ? null : markers.first;
  }

  String? get badgeLabel =>
      primary == null ? null : 'managed by ${primary!.manager.displayName}';

  /// Merges several verdicts, deduplicating by manager and label
  /// (03 §7.16 STK-10: a project is owned when any container is).
  static Ownership merge(Iterable<Ownership> parts) {
    final seen = <String>{};
    final markers = <OwnershipMarker>[];
    for (final part in parts) {
      for (final m in part.markers) {
        if (seen.add('${m.manager.name}\u0000${m.label}')) markers.add(m);
      }
    }
    return Ownership(markers);
  }
}

/// Badge priority when several markers are present (03 §8.7 lists Coolify,
/// Runtipi and Swarm explicitly; the rest are best-effort).
const List<ExternalManager> _priority = [
  ExternalManager.portainer,
  ExternalManager.coolify,
  ExternalManager.dokploy,
  ExternalManager.casaos,
  ExternalManager.umbrel,
  ExternalManager.trueNas,
  ExternalManager.runtipi,
  ExternalManager.dockhand,
  ExternalManager.dockge,
  ExternalManager.swarm,
  ExternalManager.systemd,
];

/// Label prefixes that mark an external manager (03 §8.7). Portainer,
/// CasaOS, Umbrel and TrueNAS conventions are marked [U] in the plan, so
/// these prefixes are best-effort and can be widened without a breaking
/// change.
const List<(String, ExternalManager)> _prefixRules = [
  ('coolify.', ExternalManager.coolify),
  ('runtipi.', ExternalManager.runtipi),
  ('dokploy.', ExternalManager.dokploy),
  ('io.portainer.', ExternalManager.portainer),
  ('com.portainer.', ExternalManager.portainer),
  ('casaos.', ExternalManager.casaos),
  ('io.casaos.', ExternalManager.casaos),
  ('umbrel.', ExternalManager.umbrel),
  ('io.umbrel.', ExternalManager.umbrel),
  ('truenas.', ExternalManager.trueNas),
  ('com.truenas.', ExternalManager.trueNas),
  ('org.truenas.', ExternalManager.trueNas),
  ('dockhand.', ExternalManager.dockhand),
  ('dockge.', ExternalManager.dockge),
  ('com.docker.swarm.', ExternalManager.swarm),
];

/// Exact keys that mark ownership when present (03 §8.7). The Podman
/// systemd unit label name is [U] in the plan, so several spellings are
/// accepted.
const List<(String, ExternalManager)> _exactRules = [
  ('com.docker.stack.namespace', ExternalManager.swarm),
  ('io.podman.systemd_unit', ExternalManager.systemd),
  ('podman.systemd.unit', ExternalManager.systemd),
  ('PODMAN_SYSTEMD_UNIT', ExternalManager.systemd),
];

/// Detects the ownership markers of 03 §8.7 in [labels]. Masked labels
/// are skipped, since a masked value cannot be trusted as a marker.
Ownership detectOwnership(Map<String, MaskedValue> labels) {
  final markers = <OwnershipMarker>[];
  for (final e in labels.entries) {
    final value = e.value;
    if (value.isMasked) continue;
    final key = e.key;
    for (final (exact, manager) in _exactRules) {
      if (key == exact) {
        markers.add(
          OwnershipMarker(manager: manager, label: key, value: value.display),
        );
      }
    }
    for (final (prefix, manager) in _prefixRules) {
      if (key.startsWith(prefix)) {
        markers.add(
          OwnershipMarker(manager: manager, label: key, value: value.display),
        );
        break;
      }
    }
  }
  return Ownership(markers);
}
