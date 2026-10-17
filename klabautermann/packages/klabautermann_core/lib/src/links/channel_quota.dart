/// The engine's shares of one server's session channels (03 §5.2). The
/// link's own semaphore bounds the total at 8; each kind of consumer the
/// engine runs takes its own share below that, so one kind cannot hold
/// the slots another needs. A consumer that finds its share full waits in
/// the engine, where it can say so, instead of queueing on the link.
library;

/// A kind of consumer with its own share of a server's session channels
/// (03 §5.2). The samplers, SFTP and per-operation channels hold one each
/// by construction and take no share here.
enum ChannelShare {
  /// Short actions and one-shot reads, bounded log reads among them.
  shortAction(2),

  /// Followers (`journalctl -f`, `tail -F`, an operation log's follow),
  /// each holding its channel while its view is open (K26).
  follower(2);

  const ChannelShare(this.limit);

  /// How many of the kind run at once.
  final int limit;
}

/// The least learned session limit under which a follower may take a
/// channel: the two samplers, one follower and one short action. Below it
/// a follower waits for a channel, since holding the last free one would
/// leave short actions none, and each session above it makes room for
/// one more follower up to the share's 2. 03 §5.2's low-session mode
/// arrives with M3.
const kFollowerMinSessionLimit = 4;

/// One server's [ChannelShare] slots in use, owned by the engine isolate.
final class ChannelQuota {
  final Map<ChannelShare, int> _held = {
    for (final share in ChannelShare.values) share: 0,
  };

  /// How many slots of [share] are taken.
  int held(ChannelShare share) => _held[share]!;

  /// Takes a slot of [share] and returns true, or returns false when its
  /// slots are all taken or, for a follower, the session limit the link
  /// learned ([learnedSessionLimit]) leaves no room for another: none
  /// below [kFollowerMinSessionLimit], one at it.
  bool take(ChannelShare share, {int? learnedSessionLimit}) {
    final held = _held[share]!;
    if (share == ChannelShare.follower &&
        learnedSessionLimit != null &&
        held > learnedSessionLimit - kFollowerMinSessionLimit) {
      return false;
    }

    if (held >= share.limit) return false;
    _held[share] = held + 1;
    return true;
  }

  /// Gives back a slot of [share] that [take] took.
  void give(ChannelShare share) {
    final held = _held[share]!;
    assert(held > 0, 'no ${share.name} slot is taken');
    _held[share] = held - 1;
  }
}
