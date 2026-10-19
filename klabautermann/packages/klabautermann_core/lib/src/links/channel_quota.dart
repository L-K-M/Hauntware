/// The engine's shares of one server's session channels (03 §5.2). The
/// link's own semaphore bounds the total at 8; each kind of consumer the
/// engine runs takes its own share below that, so one kind cannot hold
/// the slots another needs. A consumer that finds its share full waits in
/// the engine, where it can say so, instead of queueing on the link.
///
/// One [ChannelQuota] per server serves every consumer the engine runs
/// on that server's link (M9): the host log reads, and the Docker
/// session's stack checks and, on relay ranks, its pooled connection,
/// events stream and container log streams. [ChannelQuotas] hands them
/// out, so the log router and the Docker router count against the same
/// slots.
library;

import 'dart:async';
import 'dart:math' as math;

/// A kind of consumer with its own share of a server's session channels
/// (03 §5.2). The samplers, SFTP and per-operation channels hold one each
/// by construction and take no share here.
enum ChannelShare {
  /// Short actions and one-shot reads: bounded log reads, the Docker
  /// stack checks, and a relay's pooled connection while it is open.
  shortAction(2),

  /// Followers (`journalctl -f`, `tail -F`, an operation log's follow, a
  /// container log follow and the Docker events stream on a relay), each
  /// holding its channel while its view is open (K26).
  follower(2);

  const ChannelShare(this.limit);

  /// How many of the kind run at once.
  final int limit;
}

/// The least learned session limit under which a follower may take a
/// channel: the two samplers, one follower and one short action. Below it
/// a follower waits for a channel, since holding the last free one would
/// leave short actions none.
const kFollowerMinSessionLimit = 4;

/// The most followers at once in 03 §5.2's low-session mode, which any
/// learned session limit puts a server in (M9).
const kLowSessionFollowersMax = 1;

/// The session channels the two samplers hold on every link, outside
/// the shares.
const kSamplerChannels = 2;

/// One server's [ChannelShare] slots in use, owned by the engine isolate.
final class ChannelQuota {
  /// A quota on its own; [ChannelQuotas.of] gives the shared one.
  ChannelQuota() : _freed = null;

  ChannelQuota._(this._freed);

  final void Function()? _freed;
  final Map<ChannelShare, int> _held = {
    for (final share in ChannelShare.values) share: 0,
  };
  final List<Completer<void>> _waiters = [];

  /// How many slots of [share] are taken.
  int held(ChannelShare share) => _held[share]!;

  /// Takes a slot of [share] and returns true, or returns false when its
  /// slots are all taken or the session limit the link learned
  /// ([learnedSessionLimit]) leaves no room for another. Under a learned
  /// limit the shares together hold what the samplers leave, and
  /// followers none below [kFollowerMinSessionLimit] and
  /// [kLowSessionFollowersMax] at or above it. Below that limit the
  /// samplers leave less than the short-action share, which then keeps
  /// its own slots and queues on the link as before (D22).
  bool take(ChannelShare share, {int? learnedSessionLimit}) {
    final held = _held[share]!;
    if (learnedSessionLimit != null) {
      if (share == ChannelShare.follower &&
          (learnedSessionLimit < kFollowerMinSessionLimit ||
              held >= kLowSessionFollowersMax)) {
        return false;
      }
      final room = math.max(
        ChannelShare.shortAction.limit,
        learnedSessionLimit - kSamplerChannels,
      );
      if (_held.values.fold(0, (sum, n) => sum + n) >= room) return false;
    }

    if (held >= share.limit) return false;
    _held[share] = held + 1;
    return true;
  }

  /// Takes a slot of [share] once one is free, under the session limit
  /// the link has learned by then ([learnedSessionLimit]). Only for short
  /// actions.
  Future<void> acquire(
    ChannelShare share, {
    int? Function()? learnedSessionLimit,
  }) async {
    assert(share == ChannelShare.shortAction, 'a follower never waits here');
    while (!take(share, learnedSessionLimit: learnedSessionLimit?.call())) {
      final freed = Completer<void>();
      _waiters.add(freed);
      await freed.future;
    }
  }

  /// Gives back a slot of [share] that [take] or [acquire] took, waking
  /// what waits for one.
  void give(ChannelShare share) {
    final held = _held[share]!;
    assert(held > 0, 'no ${share.name} slot is taken');
    _held[share] = held - 1;

    final waiters = _waiters.toList();
    _waiters.clear();
    for (final waiter in waiters) {
      waiter.complete();
    }
    _freed?.call();
  }
}

/// Every server's [ChannelQuota], owned by the engine isolate and shared
/// by the consumers of each server's link (M9).
final class ChannelQuotas {
  final Map<String, ChannelQuota> _quotas = {};
  final List<void Function(String serverId)> _listeners = [];
  final Set<String> _notifying = {};

  /// [serverId]'s quota.
  ChannelQuota of(String serverId) => _quotas.putIfAbsent(
    serverId,
    () => ChannelQuota._(() => _notify(serverId)),
  );

  /// Calls [listener] with a server whose quota freed a slot, so a
  /// consumer waiting on it can try again. It runs in a microtask after
  /// the slot went back, never inside the consumer that gave it, and
  /// once for slots freed together.
  void onFreed(void Function(String serverId) listener) =>
      _listeners.add(listener);

  /// Forgets the quotas of servers outside [fleet]. Slots still held go
  /// back to the forgotten quota, which nothing takes from again.
  void retain(Set<String> fleet) =>
      _quotas.removeWhere((serverId, _) => !fleet.contains(serverId));

  void _notify(String serverId) {
    if (!_notifying.add(serverId)) return;
    scheduleMicrotask(() {
      _notifying.remove(serverId);
      for (final listener in _listeners.toList()) {
        listener(serverId);
      }
    });
  }
}
