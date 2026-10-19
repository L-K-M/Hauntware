// 03 §8.7's ownership markers as plan facts (DKE-10, STK-10; M4 plan
// M10): a target another manager owns needs the typed "act anyway" step
// naming it, and the planners refuse some actions on it outright.
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue, Ownership, detectOwnership;

import 'plan_types.dart' show PlanOwnership;

/// The manager that owns a container with [labels], or null.
PlanOwnership? containerOwnership(Map<String, MaskedValue> labels) =>
    _owner(detectOwnership(labels));

/// The manager that owns a stack: any of its containers' labels mark it
/// (STK-10).
PlanOwnership? stackOwnership(Iterable<Map<String, MaskedValue>> labels) =>
    _owner(Ownership.merge(labels.map(detectOwnership)));

PlanOwnership? _owner(Ownership ownership) => switch (ownership.primary) {
  final marker? => PlanOwnership(marker.manager.displayName),
  null => null,
};
