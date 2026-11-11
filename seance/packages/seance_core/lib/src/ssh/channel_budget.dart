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
  /// queue rather than erroring; the refused open itself queues and goes out
  /// once more, and this reaches a caller only if that refused too.
  sessionLimit,

  /// The peer refused a `direct-tcpip` or `direct-streamlocal` open because
  /// it does not forward that kind (RFC 4254 reason administratively
  /// prohibited, or an unknown channel type). The link marks forwarding
  /// refused in [SshLinkSeen].
  forwardDisabled,

  /// The peer tried to reach the forwarding target and could not (RFC 4254
  /// reason connect failed): a closed port, a missing Unix socket. Says
  /// nothing about the link. OpenSSH also answers a `direct-streamlocal`
  /// open this way when its own settings refuse it, so for a socket this
  /// does not prove that forwarding works.
  connectFailed,

  /// A refusal that teaches the link nothing (a reason the classifier cannot
  /// attribute, or a first session refusal with nothing open).
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

/// What the link has learned about the peer, from refused channel opens
/// and from the version exchange.
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
  ChannelGrant._(this._budget, this._serial);

  final ChannelBudget _budget;

  /// Order of issue: grants are taken in the order their opens go out.
  final int _serial;
  var _released = false;

  /// Frees the slot and wakes the next waiter that fits.
  void release() {
    if (_released) return;
    _released = true;
    _budget._releaseOne(this);
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

  /// Grants not yet released, in order of issue.
  final _held = <ChannelGrant>{};
  var _nextSerial = 0;
  int? _learnedLimit;
  final _waiters = <_ChannelWaiter>[];

  /// Slots currently held.
  int get inUse => _held.length;

  /// Slots still held that were granted before [grant].
  ///
  /// When the server refuses [grant]'s open, this is the count it had
  /// open: every earlier open was answered before the refusal, and the
  /// opens granted after [grant] reached the server after it. [inUse]
  /// counts those later opens too, and overstates the limit.
  int heldBefore(ChannelGrant grant) =>
      _held.where((held) => held._serial < grant._serial).length;

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
    if (inUse < effectiveLimit && _waiters.isEmpty) {
      return Future.value(_grant());
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

  ChannelGrant _grant() {
    final grant = ChannelGrant._(this, _nextSerial++);
    _held.add(grant);
    return grant;
  }

  void _releaseOne(ChannelGrant grant) {
    _held.remove(grant);
    while (inUse < effectiveLimit && _waiters.isNotEmpty) {
      _waiters.removeAt(0).grant.complete(_grant());
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

/// RFC 4254 §5.1 `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED`: the server's own
/// policy refused the open, as OpenSSH and Dropbear answer a `direct-tcpip`
/// open their forwarding settings refuse.
const sshOpenAdministrativelyProhibited = 1;

/// RFC 4254 §5.1 `SSH_OPEN_CONNECT_FAILED`: the reason code a session-limit
/// refusal carries. OpenSSH historically reports `MaxSessions` refusals as
/// administratively-prohibited with an "open failed" description instead, so
/// the classifier accepts either signal. On a forwarding open it means the
/// server could not reach the target.
const sshOpenConnectFailed = 2;

/// RFC 4254 §5.1 `SSH_OPEN_UNKNOWN_CHANNEL_TYPE`: the server does not know
/// the forwarding kind at all, as Dropbear before 2024.84 answers
/// `direct-streamlocal`.
const sshOpenUnknownChannelType = 3;

/// Maps a wire refusal to a [ChannelRefusal].
///
/// A connect-failed session refusal is the server's `MaxSessions` speaking:
/// the link learns the count that was open as the real limit and degrades
/// rather than failing (a refusal of an open granted before the link
/// learned the limit teaches it again and lowers nothing). A forwarding open refused by policy or as
/// an unknown type means this transport cannot carry that forwarding kind;
/// one refused as connect failed means the target did not answer. Anything
/// else is an opaque refusal.
ChannelRefusal classifyChannelRefusal(
  ChannelOpenKind kind, {
  int? reasonCode,
  String description = '',
}) {
  if (kind != ChannelOpenKind.session) {
    return switch (reasonCode) {
      sshOpenAdministrativelyProhibited ||
      sshOpenUnknownChannelType => ChannelRefusal.forwardDisabled,
      sshOpenConnectFailed => ChannelRefusal.connectFailed,
      _ => ChannelRefusal.other,
    };
  }
  final isConnectFailure =
      reasonCode == sshOpenConnectFailed ||
      description.toLowerCase().contains('open failed');
  return isConnectFailure ? ChannelRefusal.sessionLimit : ChannelRefusal.other;
}
