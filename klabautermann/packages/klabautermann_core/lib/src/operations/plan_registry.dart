// The plans the engine has previewed and not yet run (03 §8.5, M4 E09):
// held by id for a short while, each with the link generation it was
// planned on, so a plan made over a link that has since dropped, or one
// the user left standing, is refused rather than run against a host that
// may have changed.
import 'dart:math';

import 'operation_plan.dart';

/// How long a previewed plan stays runnable [E].
const kPlanLifetime = Duration(minutes: 5);

/// Why [PlanRegistry.take] found no plan to run.
enum PlanMissing {
  /// No plan has the id, or it already ran.
  unknown,

  /// The plan outlived [kPlanLifetime].
  expired,

  /// The server's link was re-established since the plan was made.
  stale,
}

/// What [PlanRegistry.take] returns: the plan, or why there is none.
typedef PlanLookup = ({OperationPlan? plan, PlanMissing? missing});

/// Previewed plans by id. Each plan runs at most once: [take] removes it.
final class PlanRegistry {
  PlanRegistry({DateTime Function()? now, Random? random})
    : _now = now ?? DateTime.now,
      _random = random ?? Random.secure();

  final DateTime Function() _now;
  final Random _random;
  final Map<String, _Held> _plans = {};

  /// Holds [plan], made over the server's link generation
  /// [linkGeneration], and returns its new id. Plans past their lifetime
  /// are dropped first.
  String hold(OperationPlan plan, {required int linkGeneration}) {
    _dropExpired();
    String id;
    do {
      id = _newId();
    } while (_plans.containsKey(id));
    _plans[id] = _Held(plan, linkGeneration, _now().add(kPlanLifetime));
    return id;
  }

  /// Removes and returns plan [planId] if it is still runnable on the
  /// server's current link generation [linkGeneration]. An expired or
  /// stale plan is removed too: it can never run.
  PlanLookup take(String planId, {required int linkGeneration}) {
    final held = _plans.remove(planId);
    if (held == null) return (plan: null, missing: PlanMissing.unknown);
    if (!_now().isBefore(held.expiresAt)) {
      return (plan: null, missing: PlanMissing.expired);
    }
    if (held.linkGeneration != linkGeneration) {
      return (plan: null, missing: PlanMissing.stale);
    }
    return (plan: held.plan, missing: null);
  }

  /// Drops every plan for [serverIds], which left the fleet or changed
  /// endpoint.
  void forget(Set<String> serverIds) => _plans.removeWhere(
    (_, held) => serverIds.contains(held.plan.intent.serverId),
  );

  /// How many plans are held, for tests.
  int get length => _plans.length;

  void _dropExpired() {
    final now = _now();
    _plans.removeWhere((_, held) => !now.isBefore(held.expiresAt));
  }

  String _newId() => [
    for (var i = 0; i < 8; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

final class _Held {
  _Held(this.plan, this.linkGeneration, this.expiresAt);

  final OperationPlan plan;
  final int linkGeneration;
  final DateTime expiresAt;
}
