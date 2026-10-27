import 'dart:async';

/// Counting semaphore over a link's session channels, plus the wire-level
/// classification of a refused channel open.
///
/// The budget is shared by every feature on the link; waiters carry the
/// caller-supplied priority and reason so a UI can say *what* is queued, and
/// a server that refuses session channels below the configured ceiling lowers
/// the effective ceiling instead of failing future opens outright.

/// Acquisition priority for [ChannelBudget.acquire], highest first.
///
/// The order is the F2 allocation order: instrumentation ahead of interactive
/// work, interactive work ahead of background consumers, and SFTP last so a
/// busy file pane cannot starve a foreground command.
enum ChannelWaitPriority {
  /// Health sampling and other cheap probes.
  sampler,

  /// Something the user just asked for.
  userAction,

  /// Follow-on work triggered by a user action.
  follow,

  /// SFTP channels, which sit idle most of their lease.
  sftp,
}

/// What a refused channel open means for the link.
enum ChannelRefusal {
  /// The peer refuses more concurrent session channels. The budget lowers its
  /// effective ceiling to the count that was already open, and future opens
  /// queue rather than erroring.
  sessionLimit,

  /// The peer refused a `direct-tcpip` or `direct-streamlocal` open. The link
  /// marks forwarding unavailable for the endpoint-discovery ladder.
  forwardDisabled,

  /// A refusal that teaches the link nothing (already at the learned ceiling,
  /// or a reason the classifier cannot attribute).
  other,
}

/// A channel open that produced no channel, either refused by the peer or
/// rejected by the local bounds.
final class ChannelOpenException implements Exception {
  const ChannelOpenException(this.refusal, this.message, {this.cause});

  /// How the link classified the refusal.
  final ChannelRefusal refusal;

  /// Human-readable description of what was refused.
  final String message;

  /// The underlying error, when one exists.
  final Object? cause;

  @override
  String toString() => message;
}

/// What the link has learned about the peer from refused opens.
final class SshLinkSeen {
  const SshLinkSeen({
    this.learnedSessionLimit,
    this.forwardingRefused = false,
    this.serverIdentification,
  });

  /// The session-channel ceiling the server demonstrated, below the
  /// configured budget. `null` while the server has refused nothing.
  final int? learnedSessionLimit;

  /// Set once a forwarding open has been refused on this link.
  final bool forwardingRefused;

  /// The identification line the server sent before the key exchange
  /// (RFC 4253 §4.2), such as `SSH-2.0-dropbear_2024.86`; null before the
  /// handshake read it. Apps read the server software from it, for example
  /// to work around a release's known gaps.
  final String? serverIdentification;

  @override
  bool operator ==(Object other) =>
      other is SshLinkSeen &&
      other.learnedSessionLimit == learnedSessionLimit &&
      other.forwardingRefused == forwardingRefused &&
      other.serverIdentification == serverIdentification;

  @override
  int get hashCode =>
      Object.hash(learnedSessionLimit, forwardingRefused, serverIdentification);

  @override
  String toString() =>
      'SshLinkSeen(learnedSessionLimit: $learnedSessionLimit, '
      'forwardingRefused: $forwardingRefused, '
      'serverIdentification: $serverIdentification)';
}

/// One held session-channel slot.
///
/// Grants are idempotent: every cleanup path may call [release] and only the
/// first one frees the slot.
final class ChannelGrant {
  ChannelGrant._(this._budget);

  final ChannelBudget _budget;
  var _released = false;

  /// Frees the slot and wakes the next waiter that fits.
  void release() {
    if (_released) return;
    _released = true;
    _budget._releaseOne();
  }
}

/// Semaphore over one link's concurrently open session channels.
///
/// Forwarding channels do not consume this budget (the link bounds them
/// separately); everything else opens through [acquire] so a busy link queues
/// instead of tripping the server's `MaxSessions`.
final class ChannelBudget {
  ChannelBudget(this.capacity) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'must be at least 1');
    }
  }

  /// The configured ceiling on open session channels.
  final int capacity;

  var _inUse = 0;
  int? _learnedLimit;
  final _waiters = <_ChannelWaiter>[];

  /// Slots currently held.
  int get inUse => _inUse;

  /// The ceiling in force: the configured capacity, tightened by the lowest
  /// count the server has demonstrated it will tolerate.
  int get effectiveLimit {
    final learned = _learnedLimit;
    return learned == null || learned > capacity ? capacity : learned;
  }

  /// The count the server taught us, if a below-cap refusal arrived.
  int? get learnedLimit => _learnedLimit;

  /// The queued acquires, in service order, with the reason each gave.
  List<({ChannelWaitPriority priority, String reason})> get pendingWaiters =>
      List.unmodifiable(
        _waiters.map((w) => (priority: w.priority, reason: w.reason)),
      );

  /// Takes a slot immediately, or queues behind earlier waiters of equal or
  /// higher priority.
  ///
  /// Queued futures only complete when a slot frees or [failWaiters] runs, so
  /// callers inside a link close path must rely on the link failing them.
  Future<ChannelGrant> acquire(ChannelWaitPriority priority, String reason) {
    if (effectiveLimit == 0) {
      return Future.error(
        const ChannelOpenException(
          ChannelRefusal.sessionLimit,
          'The server accepts no session channels.',
        ),
      );
    }
    if (_inUse < effectiveLimit && _waiters.isEmpty) {
      _inUse++;
      return Future.value(ChannelGrant._(this));
    }
    final waiter = _ChannelWaiter(priority, reason);
    // Higher priority first; FIFO inside one priority band.
    final index = _waiters.indexWhere((w) => w.priority.index > priority.index);
    _waiters.insert(index < 0 ? _waiters.length : index, waiter);
    return waiter.grant.future;
  }

  /// Records the server's demonstrated ceiling.
  ///
  /// Only lowers the effective limit: a second refusal at a tighter count
  /// tightens further, but the limit never relaxes once learned.
  void learnLimit(int openCountWhenRefused) {
    final current = _learnedLimit;
    if (current == null || openCountWhenRefused < current) {
      _learnedLimit = openCountWhenRefused;
    }
  }

  /// Completes every queued acquire with [error] and clears the queue.
  void failWaiters(Object error) {
    for (final waiter in _waiters) {
      waiter.grant.completeError(error);
    }
    _waiters.clear();
  }

  void _releaseOne() {
    _inUse--;
    while (_inUse < effectiveLimit && _waiters.isNotEmpty) {
      _inUse++;
      _waiters.removeAt(0).grant.complete(ChannelGrant._(this));
    }
  }
}

final class _ChannelWaiter {
  _ChannelWaiter(this.priority, this.reason);

  final ChannelWaitPriority priority;
  final String reason;
  final grant = Completer<ChannelGrant>();
}

/// Which open request the peer refused. Not barrel-exported; the link feeds
/// it to [classifyChannelRefusal].
enum ChannelOpenKind { session, directTcpip, directStreamLocal }

/// RFC 4254 §6.1 `SSH_OPEN_CONNECT_FAILED`: the reason code a session-limit
/// refusal carries. OpenSSH historically reports `MaxSessions` refusals as
/// administratively-prohibited with an "open failed" description instead, so
/// the classifier accepts either signal.
const sshOpenConnectFailed = 2;

/// Maps a wire refusal to a [ChannelRefusal].
///
/// A connect-failed session refusal while the observed open count is below
/// the ceiling in force is the server's `MaxSessions` speaking: the count
/// that was open is the real limit, so the link learns it and the link
/// degrades rather than failing. A refusal on a forwarding open means this
/// transport cannot carry that forwarding kind. Anything else is an opaque
/// refusal.
ChannelRefusal classifyChannelRefusal(
  ChannelOpenKind kind, {
  required int observedOpens,
  required int effectiveLimit,
  int? reasonCode,
  String description = '',
}) {
  if (kind != ChannelOpenKind.session) {
    return ChannelRefusal.forwardDisabled;
  }
  if (observedOpens >= effectiveLimit) {
    return ChannelRefusal.other;
  }
  final isConnectFailure =
      reasonCode == sshOpenConnectFailed ||
      description.toLowerCase().contains('open failed');
  return isConnectFailure ? ChannelRefusal.sessionLimit : ChannelRefusal.other;
}
