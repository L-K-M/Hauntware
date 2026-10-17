import 'dart:async';
import 'dart:math';

import 'package:seance_core/seance_core.dart'
    show
        ServerConfig,
        SshLink,
        SshLinkClosed,
        SshLinkClosedReason,
        SshLinkDegraded,
        SshLinkDegradedReason,
        SshLinkReady,
        SshLinkState;

import '../engine/protocol.dart';
// Sampler restarts use the link backoff figures of 03 §5.1, so the
// supervisor shares their function.
import '../sampling/sampler_timing.dart' show samplerRestartDelay;
import 'link_connector.dart';

/// Connect attempts in flight at once, across the fleet (D19, 03 §5.12):
/// bursts of new connections trip `MaxStartups` and fail2ban (c2 R11),
/// also on a jump host many servers share. A given-up attempt whose dial
/// is on its way to the network keeps its slot until the dial returns.
const int kMaxConnectsInFlight = 4;

/// The longest random wait before an unattended attempt dials [E], so
/// servers queued together do not connect in step (03 §5.12).
const Duration kConnectJitter = Duration(seconds: 1);

/// How long an attempt may work, or wait for its server's given-up dial
/// to return, before it is given up as timed out [E]; the clock stops
/// while a prompt waits on the user and starts over once it is answered.
/// `SshLink.connect` bounds each socket connect but gives a handshake and
/// authentication five minutes, and a stat or read of a key file stalled
/// on a mount has no bound at all.
const Duration kConnectAttemptDeadline = Duration(seconds: 60);

/// How long links stay open after a phone app goes to the background
/// (D34, 03 §5.1).
const Duration kBackgroundGracePeriod = Duration(seconds: 30);

/// How long a link may stay silent after a dead-peer hint before the
/// supervisor closes it as a dead peer [E]. The hint comes as the
/// restarted fast sampler starts, after its restart delay, so the grace
/// covers only the start: the READY deadline (15 s from the opened
/// channel, 03 §6.2) and 5 s for the channel to open. A live peer whose
/// sampler only stalled answers in time, however often it stalled.
const Duration kDeadPeerGrace = Duration(seconds: 20);

/// What the platform does with links while the app is in the background.
enum BackgroundLinkPolicy {
  /// Phones and tablets: links close after [kBackgroundGracePeriod] (D34)
  /// and reconnect on return.
  closeAfterGrace,

  /// Desktops: links stay open; sampling pauses on its own (03 §6.4).
  keepOpen,
}

/// [LinkConnector.connect] as the supervisor calls it; tests pass a fake.
typedef LinkConnect =
    Future<LinkConnectResult> Function(
      ServerConfig config, {
      required ConnectPurpose purpose,
      void Function(LinkStatus phase)? onPhase,
      void Function()? onDialing,
      Future<void>? abandoned,
    });

/// Holds at most one link per server and decides when to dial; every
/// change reaches the app as a [LinkState]. The rules are 03 §5.1 and
/// §5.12 (CN-05, FL-21):
///
/// - Attempts queue for one of [kMaxConnectsInFlight] slots, the user's
///   ([ConnectPurpose.interactive]) first; unattended ones
///   ([ConnectPurpose.background]) wait up to [kConnectJitter] in their
///   slot. A server never has two dials at once, and a link that a
///   given-up attempt brings late is closed.
/// - Only a failure to reach the server and a lost link back off
///   ([samplerRestartDelay]) and redial unattended; any other failure, an
///   unclassified one included, waits for the user (fail2ban, c2 R11),
///   and so does a server whose last connect needed keyboard-interactive
///   answers (c2 R10).
/// - No attempt starts while the app is in the background; under
///   [BackgroundLinkPolicy.closeAfterGrace] links close after
///   [kBackgroundGracePeriod] and redial on return.
/// - A server that leaves the fleet is forgotten ([forget]).
/// - A dead-peer hint ([deadPeerHint]) closes a link that stays silent
///   for [kDeadPeerGrace], as a lost one, sooner than its own ping
///   (CN-06).
///
/// The engine isolate owns it and hands it `Connect`, `Disconnect` and
/// `SetAppActivity`.
final class LinkSupervisor {
  /// [configFor] looks up a fleet server's config by id, null for an
  /// unknown or undialable one. [startTimer], [now] and [random] are test
  /// seams.
  LinkSupervisor({
    required this._connect,
    required this._configFor,
    required this._emit,
    required this._policy,
    this._startTimer = Timer.new,
    this._now = DateTime.now,
    Random? random,
  }) : _random = random ?? Random();

  final LinkConnect _connect;
  final ServerConfig? Function(String serverId) _configFor;
  final void Function(EngineEvent event) _emit;
  final BackgroundLinkPolicy _policy;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final DateTime Function() _now;
  final Random _random;

  final Map<String, _Server> _servers = {};

  /// The ids of servers with a dial, current or given up, that has not
  /// returned yet. Kept apart from the records, which [forget] drops, so
  /// a server that comes back while its old dial runs waits for it too.
  final Set<String> _dialsPending = {};

  /// Attempts waiting for a slot, interactive ones first.
  final List<_Attempt> _queue = [];
  int _inFlight = 0;
  bool _background = false;
  Timer? _grace;

  /// The link held for [serverId], ready or degraded, or null.
  SshLink? link(String serverId) => _servers[serverId]?.link;

  /// Asks for a link to [serverId] for [purpose]. Returns false, changing
  /// nothing, when [configFor] knows no such server.
  ///
  /// An interactive request starts an attempt, ahead of unattended ones,
  /// unless a link or an interactive attempt exists; it makes an
  /// unattended attempt that has not dialed yet interactive, and one that
  /// arrives while an unattended attempt dials takes over when that
  /// attempt fails for want of the user. An unattended request starts one
  /// only for a server with nothing running, no backoff, nothing waiting
  /// for the user and no keyboard-interactive last connect. A blocked
  /// server stays blocked.
  bool connect(String serverId, {required ConnectPurpose purpose}) {
    if (_configFor(serverId) == null) return false;

    final server = _servers.putIfAbsent(serverId, () => _Server(serverId));
    final interactive = purpose == ConnectPurpose.interactive;
    server.wanted = true;
    if (server.hold == _Hold.blocked || server.link != null) return true;

    final attempt = server.attempt;
    if (attempt != null) {
      if (interactive && attempt.purpose == ConnectPurpose.background) {
        _promote(attempt);
      }
      return true;
    }

    if (!interactive &&
        (server.retry != null ||
            server.hold != _Hold.none ||
            server.keyboardInteractive)) {
      return true;
    }
    server.retry?.cancel();
    server.retry = null;
    server.hold = _Hold.none;
    _enqueue(_Attempt(server, purpose));
    return true;
  }

  /// Gives up any attempt, backoff or link to [serverId] (closing the
  /// link) and reports it closed by its owner. A blocked server, or one
  /// waiting for the user, keeps its status.
  void disconnect(String serverId) {
    final server = _servers[serverId];
    if (server == null) return;

    server.wanted = false;
    if (server.hold == _Hold.untilForeground) server.hold = _Hold.none;
    if (!_tearDown(server)) return;

    _set(server, const LinkClosed(LinkClosedReason.closedByOwner));
    _pump();
  }

  /// Forgets [serverIds], which left the fleet (03 §5.1): gives up their
  /// attempts and backoffs and closes their links as [disconnect] does,
  /// but reports nothing, since the app drops a server's status with its
  /// entry, and keeps nothing learned about them (a block, a
  /// keyboard-interactive last connect, the failure count), so a server
  /// that comes back starts over. A given-up dial still on its way holds
  /// the next attempt of a server that comes back until it returns.
  ///
  /// All of them go before a slot they free starts a queued attempt, so
  /// no queued attempt of one of them dials and reports a close.
  void forget(Iterable<String> serverIds) {
    for (final serverId in serverIds) {
      final server = _servers.remove(serverId);
      if (server != null) _tearDown(server);
    }
    _pump();
  }

  /// Follows the app's visibility (D34, 03 §10.1 `SetAppActivity`).
  void setActivity(AppActivity activity) {
    final background = activity == AppActivity.background;
    if (background == _background) return;

    _background = background;
    if (background) {
      if (_policy == BackgroundLinkPolicy.closeAfterGrace) {
        _grace = _startTimer(kBackgroundGracePeriod, _closeForBackground);
      }
      return;
    }

    _grace?.cancel();
    _grace = null;
    for (final server in _servers.values) {
      if (server.hold != _Hold.untilForeground) continue;
      server.hold = _Hold.none;
      _enqueue(_Attempt(server, ConnectPurpose.background));
    }
    _pump();
  }

  /// Takes a dead-peer hint about [link], [serverId]'s current link: a
  /// fast-sampler request missed its deadline (03 §6.2), which only a
  /// stalled sampler or a silent peer explains, and the restarted
  /// sampler is starting. Unless
  /// [clearDeadPeerHint] follows within [kDeadPeerGrace], the link is
  /// closed and reported [LinkClosedReason.pingTimeout], and the server
  /// backs off and redials as after a lost link. A hint about any other
  /// link, or one while a hint runs, changes nothing.
  void deadPeerHint(String serverId, SshLink link) {
    final server = _servers[serverId];
    if (server == null || !identical(server.link, link)) return;
    if (server.deadPeer != null) return;

    server.deadPeer = _startTimer(kDeadPeerGrace, () {
      server.deadPeer = null;
      if (!identical(server.link, link)) return;

      server.link = null;
      unawaited(server.states?.cancel());
      server.states = null;
      _closeLink(link);
      _set(server, const LinkClosed(LinkClosedReason.pingTimeout));
      if (server.wanted) _backoff(server);
    });
  }

  /// Ends the hint [deadPeerHint] took about [link]: its peer answered,
  /// or nothing watches it any more, which leaves its liveness to the
  /// link's own ping.
  void clearDeadPeerHint(String serverId, SshLink link) {
    final server = _servers[serverId];
    if (server == null || !identical(server.link, link)) return;

    server.deadPeer?.cancel();
    server.deadPeer = null;
  }

  void _closeForBackground() {
    _grace = null;
    for (final server in _servers.values) {
      if (!server.wanted || !_tearDown(server)) continue;
      server.hold = server.keyboardInteractive
          ? _Hold.forUser
          : _Hold.untilForeground;
      _set(server, const LinkClosed(LinkClosedReason.closedByOwner));
    }
  }

  /// Makes [attempt] interactive: a queued one moves ahead, one waiting
  /// out its jitter dials now (in the background, it queues), and one
  /// already dialing unattended is followed by an interactive one if it
  /// fails for want of the user.
  void _promote(_Attempt attempt) {
    if (attempt.dialing) {
      attempt.userAsked = true;
      return;
    }

    attempt.purpose = ConnectPurpose.interactive;
    if (!attempt.holdsSlot) {
      _queue.remove(attempt);
      _enqueue(attempt);
    } else if (_background) {
      _requeue(attempt);
    } else {
      attempt.timer?.cancel();
      _dial(attempt);
    }
  }

  void _enqueue(_Attempt attempt) {
    final server = attempt.server;
    server.attempt = attempt;
    final interactive = attempt.purpose == ConnectPurpose.interactive;
    final at = interactive
        ? _queue.indexWhere((a) => a.purpose == ConnectPurpose.background)
        : -1;
    _queue.insert(at < 0 ? _queue.length : at, attempt);
    _set(server, const LinkConnecting());
    // Waiting for a given-up dial, such as a key read stalled on a mount,
    // counts against the deadline, so the wait shows as a timeout and
    // backs off rather than staying connecting.
    if (_dialsPending.contains(server.id)) _armDeadline(attempt);
    _pump();
  }

  /// Starts queued attempts while slots are free and the app is in the
  /// foreground, skipping servers whose given-up dial has not returned.
  void _pump() {
    while (!_background && _inFlight < kMaxConnectsInFlight) {
      final index = _queue.indexWhere(
        (a) => !_dialsPending.contains(a.server.id),
      );
      if (index < 0) return;

      final attempt = _queue.removeAt(index);
      attempt.timer?.cancel();
      _inFlight++;
      attempt.holdsSlot = true;
      if (attempt.purpose == ConnectPurpose.interactive) {
        _dial(attempt);
      } else {
        final jitter = kConnectJitter * _random.nextDouble();
        attempt.timer = _startTimer(
          jitter,
          () => _background ? _requeue(attempt) : _dial(attempt),
        );
      }
    }
  }

  /// Returns [attempt] from its slot to the queue, ahead of unattended
  /// attempts, when the app went to the background before it dialed.
  void _requeue(_Attempt attempt) {
    attempt.timer?.cancel();
    _freeSlot(attempt);
    final at = _queue.indexWhere((a) => a.purpose == ConnectPurpose.background);
    _queue.insert(at < 0 ? _queue.length : at, attempt);
  }

  void _dial(_Attempt attempt) {
    final server = attempt.server;
    final config = _configFor(server.id);
    if (config == null) {
      // The server lost its config while the attempt waited: its entry
      // can no longer be dialed, or it left the fleet without [forget].
      _drop(attempt);
      server.wanted = false;
      _set(server, const LinkClosed(LinkClosedReason.closedByOwner));
      _pump();
      return;
    }

    attempt.dialing = true;
    _dialsPending.add(server.id);
    _armDeadline(attempt);
    unawaited(_run(attempt, config));
  }

  Future<void> _run(_Attempt attempt, ServerConfig config) async {
    LinkConnectResult result;
    try {
      result = await _connect(
        config,
        purpose: attempt.purpose,
        onPhase: (phase) => _onPhase(attempt, phase),
        onDialing: () => attempt.onNetwork = true,
        abandoned: attempt.abandon.future,
      );
    } on Object catch (error) {
      result = LinkConnectFailed(error);
    }
    _freeSlot(attempt);
    final server = attempt.server;
    _dialsPending.remove(server.id);
    // An attempt queued behind this dial now waits only for a slot, which
    // the deadline leaves out. It may be a forgotten server's comeback,
    // with a record of its own.
    final next = _servers[server.id]?.attempt;
    if (next != null && !next.holdsSlot) next.timer?.cancel();
    _settle(attempt, result);
    _pump();
  }

  void _onPhase(_Attempt attempt, LinkStatus phase) {
    final server = attempt.server;
    if (!identical(server.attempt, attempt)) return;

    // The deadline leaves out the user's time: it stops while a prompt
    // is open and starts again once the attempt goes on.
    if (phase is LinkNeedsUser) {
      attempt.timer?.cancel();
      // Questions asked once are asked again, so the server waits for
      // the user from now on, even if this attempt fails.
      if (phase.kind == PromptKind.keyboardInteractive) {
        server.keyboardInteractive = true;
      }
    } else if (server.status is LinkNeedsUser) {
      _armDeadline(attempt);
    }
    _set(server, phase);
  }

  void _armDeadline(_Attempt attempt) {
    attempt.timer?.cancel();
    attempt.timer = _startTimer(kConnectAttemptDeadline, () {
      final server = attempt.server;
      if (!identical(server.attempt, attempt)) return;

      _drop(attempt);
      _set(
        server,
        const LinkClosed(
          LinkClosedReason.connectFailed,
          failure: LinkFailureKind.timedOut,
        ),
      );
      _backoff(server);
      _pump();
    });
  }

  void _settle(_Attempt attempt, LinkConnectResult result) {
    final server = attempt.server;
    if (!identical(server.attempt, attempt)) {
      // Given up: a link that arrives anyway is closed (03 §5.1).
      if (result is LinkConnected) _closeLink(result.link);
      return;
    }

    _detach(attempt);
    switch (result) {
      case LinkConnected(:final link, :final keyboardInteractive):
        server.failures = 0;
        server.keyboardInteractive = keyboardInteractive;
        server.link = link;
        server.states = link.states.listen((s) => _onLinkState(server, s));
      case LinkConnectBlocked(:final reason):
        server.hold = _Hold.blocked;
        _set(server, LinkBlocked(reason));
      case LinkConnectFailed(:final failure):
        _set(
          server,
          LinkClosed(LinkClosedReason.connectFailed, failure: failure),
        );
        if (_redials(failure)) {
          _backoff(server);
        } else if (attempt.userAsked && _promptMayResolve(failure)) {
          _enqueue(_Attempt(server, ConnectPurpose.interactive));
        } else {
          server.hold = _Hold.forUser;
        }
    }
  }

  /// A failure to reach the server; any other waits for the user.
  static bool _redials(LinkFailureKind? failure) => switch (failure) {
    LinkFailureKind.unreachable || LinkFailureKind.timedOut => true,
    _ => false,
  };

  /// A failure of an unattended attempt that an interactive one may not
  /// meet: a declined first-seen host key, or a sign-in that may have
  /// needed answers, rejected or not classified. A key that needs a
  /// passphrase is not one until the passphrase prompt lands (K45b): no
  /// prompt asks for it yet, so the interactive attempt would fail the
  /// same way. Exhaustive, so a new kind takes a decision here.
  static bool _promptMayResolve(LinkFailureKind? failure) => switch (failure) {
    null ||
    LinkFailureKind.hostKeyDeclined ||
    LinkFailureKind.authenticationRejected => true,
    LinkFailureKind.keyPassphraseRequired => false,
    LinkFailureKind.unreachable ||
    LinkFailureKind.timedOut ||
    LinkFailureKind.credentialUnavailable ||
    LinkFailureKind.keyFileHiddenBySandbox ||
    LinkFailureKind.unsupportedAlgorithm ||
    LinkFailureKind.insecureAlgorithmsOnly ||
    LinkFailureKind.keyExchangeTimedOut => false,
  };

  void _onLinkState(_Server server, SshLinkState state) {
    switch (state) {
      case SshLinkReady():
        _set(server, const LinkReady());
      case SshLinkDegraded(:final reason):
        _set(server, LinkDegraded(_degradedReason(reason)));
      case SshLinkClosed(:final reason):
        // Lost underneath: the supervisor's own closes cancel this
        // subscription first.
        server.link = null;
        server.deadPeer?.cancel();
        server.deadPeer = null;
        unawaited(server.states?.cancel());
        server.states = null;
        _set(server, LinkClosed(_closedReason(reason)));
        if (server.wanted) _backoff(server);
      default:
        // Connecting, authenticating and prompts happen before
        // SshLink.connect returns; backoff is the supervisor's own.
        break;
    }
  }

  /// Waits [samplerRestartDelay] and redials unattended; a server whose
  /// last connect needed keyboard-interactive answers waits for the user.
  void _backoff(_Server server) {
    if (server.keyboardInteractive) {
      server.hold = _Hold.forUser;
      return;
    }

    final delay = samplerRestartDelay(server.failures++, _random);
    _set(server, LinkBackoff(_now().add(delay)));
    server.retry = _startTimer(delay, () {
      server.retry = null;
      _enqueue(_Attempt(server, ConnectPurpose.background));
    });
  }

  /// Ends [server]'s attempt, backoff and link; true when there was one.
  bool _tearDown(_Server server) {
    var any = false;
    final attempt = server.attempt;
    if (attempt != null) {
      _drop(attempt);
      any = true;
    }
    final retry = server.retry;
    if (retry != null) {
      retry.cancel();
      server.retry = null;
      any = true;
    }
    final link = server.link;
    if (link != null) {
      server.link = null;
      server.deadPeer?.cancel();
      server.deadPeer = null;
      unawaited(server.states?.cancel());
      server.states = null;
      _closeLink(link);
      any = true;
    }
    return any;
  }

  /// Gives [attempt] up: a dial still running stops if it can. One on
  /// its way to the network cannot, so it keeps its slot until it
  /// returns, which `SshLink.connect` bounds.
  void _drop(_Attempt attempt) {
    _detach(attempt);
    if (!attempt.onNetwork) _freeSlot(attempt);
    if (!attempt.abandon.isCompleted) attempt.abandon.complete();
  }

  /// Takes [attempt] out of its server and the queue, and stops its timer.
  void _detach(_Attempt attempt) {
    attempt.timer?.cancel();
    _queue.remove(attempt);
    if (identical(attempt.server.attempt, attempt)) {
      attempt.server.attempt = null;
    }
  }

  void _freeSlot(_Attempt attempt) {
    if (!attempt.holdsSlot) return;
    attempt.holdsSlot = false;
    _inFlight--;
  }

  /// Closes [link] without waiting; `SshLink.close` is bounded.
  static void _closeLink(SshLink link) =>
      unawaited(link.close().then<void>((_) {}, onError: (Object _) {}));

  void _set(_Server server, LinkStatus status) {
    if (server.status == status) return;
    server.status = status;
    _emit(LinkState(server.id, status));
  }

  static LinkDegradedReason _degradedReason(SshLinkDegradedReason reason) =>
      switch (reason) {
        SshLinkDegradedReason.sessionLimitLearned =>
          LinkDegradedReason.sessionLimitLearned,
      };

  static LinkClosedReason _closedReason(SshLinkClosedReason reason) =>
      switch (reason) {
        SshLinkClosedReason.closedByOwner => LinkClosedReason.closedByOwner,
        SshLinkClosedReason.linkLost => LinkClosedReason.linkLost,
        SshLinkClosedReason.transportError => LinkClosedReason.transportError,
        SshLinkClosedReason.pingTimeout => LinkClosedReason.pingTimeout,
        SshLinkClosedReason.connectFailed => LinkClosedReason.connectFailed,
      };
}

/// Why a server with nothing running does not dial on an unattended
/// request.
enum _Hold {
  none,

  /// A failure only the user can resolve, or a keyboard-interactive
  /// server with nothing running: only an interactive request dials.
  forUser,

  /// A changed host key or endpoint (D46): nothing dials.
  blocked,

  /// Closed by the background grace period: redials on return.
  untilForeground,
}

final class _Server {
  _Server(this.id);

  final String id;
  LinkStatus status = const LinkIdle();

  /// The engine asked for a link and has not disconnected it.
  bool wanted = false;
  SshLink? link;
  StreamSubscription<SshLinkState>? states;

  /// The grace of a dead-peer hint about [link].
  Timer? deadPeer;

  /// The current attempt, queued, in its slot or dialing.
  _Attempt? attempt;

  Timer? retry;

  /// Failed attempts since the last link, for [samplerRestartDelay].
  int failures = 0;
  _Hold hold = _Hold.none;

  /// The last connect asked keyboard-interactive questions.
  bool keyboardInteractive = false;
}

final class _Attempt {
  _Attempt(this.server, this.purpose);

  final _Server server;
  ConnectPurpose purpose;
  bool holdsSlot = false;
  bool dialing = false;

  /// The dial's route is resolved, so giving it up no longer stops it.
  bool onNetwork = false;

  /// An interactive request arrived while this unattended attempt dialed.
  bool userAsked = false;

  /// The jitter before the dial, then the attempt's deadline.
  Timer? timer;

  /// Completed when the supervisor gives the attempt up.
  final Completer<void> abandon = Completer();
}
