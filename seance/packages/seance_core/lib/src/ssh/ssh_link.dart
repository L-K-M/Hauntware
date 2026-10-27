import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:meta/meta.dart';
import 'package:seance_protocol/seance_protocol.dart';

import '../hostkey/tofu.dart';
import 'byte_duplex.dart';
import 'channel_budget.dart';
import 'remote_command.dart';
import 'remote_file_system.dart';
import 'remote_process.dart';
import 'sequential_cleanup.dart';
import 'ssh_session.dart';

/// Lifecycle of one authenticated link, as plain data an engine isolate can
/// carry. Reconnect policy stays outside the link: a dead link is `closed`,
/// and the supervisor above it decides whether to dial again.
sealed class SshLinkState {
  const SshLinkState._();
}

/// Constructed but not yet dialing (the state `SshLink.connect` starts in
/// before the socket seam fires).
final class SshLinkIdle extends SshLinkState {
  const SshLinkIdle() : super._();
}

/// Reaching the target, possibly through resolved jump hosts.
final class SshLinkConnecting extends SshLinkState {
  const SshLinkConnecting() : super._();
}

/// Transport is up; user authentication is in progress.
final class SshLinkAuthenticating extends SshLinkState {
  const SshLinkAuthenticating() : super._();
}

/// Authenticated and working; [seen] is what refused opens have taught the
/// link about the peer so far.
final class SshLinkReady extends SshLinkState {
  const SshLinkReady(this.seen) : super._();

  final SshLinkSeen seen;
}

/// Why the link degraded: typed, not text, so each app renders its own copy.
enum SshLinkDegradedReason {
  /// The peer refused a session channel below the configured budget; the
  /// learned ceiling in [SshLinkSeen.learnedSessionLimit] now shapes queueing.
  sessionLimitLearned,
}

/// Working, but the peer demonstrated a limit below the configured one (for
/// example a tighter `MaxSessions`). [reason] is typed, not text: each app
/// renders its own copy.
final class SshLinkDegraded extends SshLinkState {
  const SshLinkDegraded(this.reason) : super._();

  final SshLinkDegradedReason reason;
}

/// Waiting out a reconnect delay owned by the supervisor above the link.
/// Part of the union so that supervisor can speak it; the link itself never
/// enters this state.
final class SshLinkBackoff extends SshLinkState {
  const SshLinkBackoff(this.until) : super._();

  final DateTime until;
}

/// Authentication or a host key needs a person; [prompt] describes what.
final class SshLinkNeedsUser extends SshLinkState {
  const SshLinkNeedsUser(this.prompt) : super._();

  final LinkPrompt prompt;
}

/// Why the link closed: typed, not text, so each app renders its own copy.
enum SshLinkClosedReason {
  /// [SshLink.close] ran.
  closedByOwner,

  /// The transport ended underneath the link: peer closed or dropped.
  linkLost,

  /// The transport reported an error before it ended.
  transportError,

  /// A keepalive ping went unanswered past the response deadline.
  pingTimeout,

  /// Connect or authentication never produced a transport.
  connectFailed,
}

/// Terminal. [reason] distinguishes an explicit close from a dropped
/// transport or an unanswered ping.
final class SshLinkClosed extends SshLinkState {
  const SshLinkClosed(this.reason) : super._();

  final SshLinkClosedReason reason;
}

/// Which prompt the link is blocked on.
enum LinkPromptKind { hostKey, keyboardInteractive }

/// A credential prompt surfaced while the link connects. Carries the
/// challenge text so a UI can render it without reaching into dartssh2.
final class LinkPrompt {
  const LinkPrompt({
    required this.kind,
    this.name = '',
    this.instruction = '',
    this.prompts = const [],
  });

  final LinkPromptKind kind;
  final String name;
  final String instruction;
  final List<String> prompts;
}

/// One authenticated SSH transport shared by exec, forwarding, and SFTP.
///
/// The link owns liveness: dartssh2's keepalive is disabled at construction
/// (`keepAliveInterval: null`) and the link's own periodic ping carries a
/// response deadline, so a dead peer is detected and closed instead of
/// idling forever. Session channels open through a [ChannelBudget] so a busy
/// link queues at the semaphore rather than tripping the server's
/// `MaxSessions`; forwarding duplexes have their own bound and consume no
/// session budget.
abstract interface class SshLink {
  /// The server this link is connected to.
  ServerConfig get config;

  /// Current lifecycle state; [states] replays it to late listeners.
  SshLinkState get state;

  /// Broadcast stream of lifecycle states that replays the current state to
  /// each new listener.
  Stream<SshLinkState> get states;

  /// What refused opens have taught the link about the peer.
  SshLinkSeen get seen;

  /// Runs [command] on a fresh non-PTY channel: the same capture core as
  /// `SshSession.runCommand`, inside the link's channel budget and open
  /// bounds. Assignable to [RemoteCommandRunner]; [timeout] falls back to
  /// the same 30-second default.
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  });

  /// Starts [command] and hands back the live channel: subscribed-at-creation
  /// stdout, always-drained stderr, EOF-capable stdin, exit status and
  /// signals.
  Future<RemoteProcess> start(String command, {PtyRequest? pty});

  /// Opens a `direct-streamlocal` duplex to a remote Unix socket.
  Future<ByteDuplex> openUnixStream(String socketPath);

  /// Opens a `direct-tcpip` duplex to [host]:[port] from the server's side.
  Future<ByteDuplex> openTcpStream(String host, int port);

  /// The remote file system, lazily leasing one SFTP channel inside the
  /// session budget and releasing it after an idle period.
  Future<RemoteFileSystem> openFileSystem();

  /// Idempotent bounded close: pending acquires are failed, channels and
  /// duplexes are closed, then the transport.
  Future<void> close();

  /// Connects and authenticates, reusing `openAuthenticatedClient`'s route
  /// resolution, jump route, TOFU and prompt seams. dartssh2 keepalive is
  /// disabled ([idlePingInterval]/[pingTimeout] own liveness instead).
  ///
  /// [timeout] bounds each blocking network step: the socket connect and
  /// every channel open afterwards.
  static Future<SshLink> connect({
    required ServerConfig config,
    required SshCredentials credentials,
    required TofuVerifier tofu,
    required HostKeyPrompter onHostKey,
    KeyboardInteractiveResponder? onKeyboardInteractive,
    SshJumpHostResolver? resolveJumpHost,
    // The socket seams name dartssh2 types, so they are test seams:
    // production callers pass neither and take the real network path.
    @visibleForTesting
    Future<SSHSocket> Function(String, int, Duration)? connect,
    @visibleForTesting SshForwardConnector? forward,
    SshAgentIdentityLoader? loadAgentIdentities,
    Duration timeout = const Duration(seconds: 15),
    // The remaining knobs are the fake-clock and refusal-fixture seams;
    // production callers take the defaults.
    @visibleForTesting Duration idlePingInterval = const Duration(seconds: 15),
    @visibleForTesting Duration pingTimeout = const Duration(seconds: 30),
    @visibleForTesting Duration closeTimeout = const Duration(seconds: 5),
    @visibleForTesting Duration sftpIdleRelease = const Duration(seconds: 60),
    @visibleForTesting int sessionBudget = 8,
    SshConnectionLog? log,
  }) => _SshLink._connect(
    config: config,
    credentials: credentials,
    tofu: tofu,
    onHostKey: onHostKey,
    onKeyboardInteractive: onKeyboardInteractive,
    resolveJumpHost: resolveJumpHost,
    connect: connect,
    forward: forward,
    loadAgentIdentities: loadAgentIdentities,
    timeout: timeout,
    idlePingInterval: idlePingInterval,
    pingTimeout: pingTimeout,
    closeTimeout: closeTimeout,
    sftpIdleRelease: sftpIdleRelease,
    sessionBudget: sessionBudget,
    log: log,
  );
}

final class _SshLink implements SshLink {
  _SshLink._({
    required this.config,
    required this.openTimeout,
    required this.idlePingInterval,
    required this.pingTimeout,
    required this.closeTimeout,
    required this.sftpIdleRelease,
    required int sessionBudget,
    this.log,
  }) : _budget = ChannelBudget(sessionBudget);

  @override
  final ServerConfig config;

  /// Bounds each blocking network step: socket connect, channel opens.
  final Duration openTimeout;

  /// How often the link decides whether a keepalive ping is owed.
  final Duration idlePingInterval;

  /// Response deadline for one keepalive ping; missing it closes the link.
  final Duration pingTimeout;

  /// Per-action bound on the sequential teardown inside [close].
  final Duration closeTimeout;

  /// How long an idle SFTP channel is held before its budget slot frees.
  final Duration sftpIdleRelease;

  final SshConnectionLog? log;
  final ChannelBudget _budget;
  final _cleanup = SingleFlightCleanup();

  late final ExecCore _execCore = ExecCore(
    isDisconnected: () => _closed || _clientOrNull?.isClosed == true,
    disconnectedMessage: 'The SSH link is closed.',
  );

  SSHClient? _clientOrNull;
  SSHClient get _client {
    final client = _clientOrNull;
    if (client == null) {
      throw const ChannelOpenException(
        ChannelRefusal.other,
        'The SSH link is closed.',
      );
    }
    return client;
  }

  var _closed = false;
  SshLinkState _state = const SshLinkIdle();
  final _stateController = StreamController<SshLinkState>.broadcast();
  late final Stream<SshLinkState> _statesView = Stream.multi((controller) {
    // Replay the current state atomically with the subscription, so a late
    // listener cannot miss a transition that lands between listen and the
    // first broadcast event.
    controller.add(_state);
    final subscription = _stateController.stream.listen(
      controller.add,
      onError: controller.addError,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });

  int? _learnedSessionLimit;
  var _forwardingRefused = false;

  Timer? _pingTimer;
  var _pingOutstanding = false;
  var _dataSinceLastTick = false;
  var _pendingOpens = 0;

  /// Forwarding opens in flight, counted against [_maxDuplexes].
  var _pendingDuplexOpens = 0;

  /// Live resources the close path tears down, in close order.
  final _execChannels = <SSHSession>{};
  final _processes = <RemoteProcess>{};
  final _duplexes = <ByteDuplex>{};
  _LeasedLinkFileSystem? _fileSystem;

  /// Forwarding duplexes do not consume session budget; this bound keeps a
  /// forwarding-heavy feature from exhausting the transport anyway.
  static const _maxDuplexes = 16;

  static Future<SshLink> _connect({
    required ServerConfig config,
    required SshCredentials credentials,
    required TofuVerifier tofu,
    required HostKeyPrompter onHostKey,
    KeyboardInteractiveResponder? onKeyboardInteractive,
    SshJumpHostResolver? resolveJumpHost,
    Future<SSHSocket> Function(String, int, Duration)? connect,
    SshForwardConnector? forward,
    SshAgentIdentityLoader? loadAgentIdentities,
    required Duration timeout,
    required Duration idlePingInterval,
    required Duration pingTimeout,
    required Duration closeTimeout,
    required Duration sftpIdleRelease,
    required int sessionBudget,
    SshConnectionLog? log,
  }) async {
    final link = _SshLink._(
      config: config,
      openTimeout: timeout,
      idlePingInterval: idlePingInterval,
      pingTimeout: pingTimeout,
      closeTimeout: closeTimeout,
      sftpIdleRelease: sftpIdleRelease,
      sessionBudget: sessionBudget,
      log: log,
    );
    link._setState(const SshLinkConnecting());
    try {
      final (client, _) = await openAuthenticatedClient(
        config: config,
        credentials: credentials,
        tofu: tofu,
        onHostKey: (decision) async {
          link._setState(
            const SshLinkNeedsUser(LinkPrompt(kind: LinkPromptKind.hostKey)),
          );
          try {
            return await onHostKey(decision);
          } finally {
            link._setState(const SshLinkAuthenticating());
          }
        },
        onKeyboardInteractive: onKeyboardInteractive == null
            ? null
            : (challenge) async {
                link._setState(
                  SshLinkNeedsUser(
                    LinkPrompt(
                      kind: LinkPromptKind.keyboardInteractive,
                      name: challenge.name,
                      instruction: challenge.instruction,
                      prompts: challenge.prompts,
                    ),
                  ),
                );
                try {
                  return await onKeyboardInteractive(challenge);
                } finally {
                  link._setState(const SshLinkAuthenticating());
                }
              },
        connect: connect == null
            ? null
            : (host, port, socketTimeout) async {
                link._setState(const SshLinkConnecting());
                final socket = await connect(host, port, socketTimeout);
                link._setState(const SshLinkAuthenticating());
                return socket;
              },
        resolveJumpHost: resolveJumpHost,
        forward: forward == null
            ? null
            : (client, host, port, channelTimeout) async {
                link._setState(const SshLinkConnecting());
                final socket = await forward(
                  client,
                  host,
                  port,
                  channelTimeout,
                );
                link._setState(const SshLinkAuthenticating());
                return socket;
              },
        loadAgentIdentities: loadAgentIdentities,
        timeout: timeout,
        // The link owns liveness; a second dartssh2 keepalive clock on the
        // same transport would double the ping traffic.
        keepAliveInterval: null,
        log: log,
      );
      link._attach(client);
      link._setState(SshLinkReady(link.seen));
      return link;
    } catch (_) {
      link._setState(const SshLinkClosed(SshLinkClosedReason.connectFailed));
      rethrow;
    }
  }

  void _attach(SSHClient client) {
    _clientOrNull = client;
    unawaited(
      client.done.then(
        (_) => _transportEnded(false),
        onError: (_) => _transportEnded(true),
      ),
    );
    _pingTimer = Timer.periodic(idlePingInterval, (_) => _tickPing());
  }

  @override
  SshLinkState get state => _state;

  @override
  Stream<SshLinkState> get states => _statesView;

  @override
  SshLinkSeen get seen => SshLinkSeen(
    learnedSessionLimit: _learnedSessionLimit,
    forwardingRefused: _forwardingRefused,
    serverIdentification: _clientOrNull?.remoteVersion,
  );

  void _setState(SshLinkState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  void _noteInbound() => _dataSinceLastTick = true;

  // ---- liveness -----------------------------------------------------------

  void _tickPing() {
    if (_closed || _client.isClosed || _pingOutstanding) return;
    // A queued open and an in-flight SFTP call are their own liveness
    // evidence; an open channel alone is not — a quiet follower or a long
    // command never suppresses pings.
    if (_pendingOpens > 0) return;
    if (_fileSystem?.hasActiveOperations ?? false) return;
    // Fresh inbound bytes prove the peer is alive without asking it.
    if (_dataSinceLastTick) {
      _dataSinceLastTick = false;
      return;
    }
    _pingOutstanding = true;
    unawaited(
      Future.sync(_client.ping)
          .timeout(pingTimeout)
          .then(
            (_) => _pingOutstanding = false,
            onError: (Object error) {
              _pingOutstanding = false;
              if (error is TimeoutException && !_closed) {
                log?.add(
                  'Ping unanswered for ${pingTimeout.inSeconds}s; '
                  'closing the link.',
                );
                unawaited(
                  _cleanup.run(
                    () => _closeOnce(SshLinkClosedReason.pingTimeout),
                  ),
                );
              }
            },
          ),
    );
  }

  void _transportEnded(bool hadError) {
    if (_closed) return;
    unawaited(
      _cleanup.run(
        () => _closeOnce(
          hadError
              ? SshLinkClosedReason.transportError
              : SshLinkClosedReason.linkLost,
        ),
      ),
    );
  }

  // ---- exec ---------------------------------------------------------------

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) => _execCore.run(
    command,
    open: () => _openSessionChannel(command).then((r) => r.$1),
    timeout: timeout,
    maxOutputBytes: maxOutputBytes,
    stdin: stdin,
  );

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) async {
    final (channel, grant) = await _openSessionChannel(
      command,
      pty: pty == null
          ? null
          : SSHPtyConfig(
              type: pty.term ?? 'xterm-256color',
              width: pty.cols,
              height: pty.rows,
            ),
      trackChannel: false,
    );
    late final SshRemoteProcess process;
    process = SshRemoteProcess(
      channel,
      grant,
      onData: _noteInbound,
      onClosed: () => _processes.remove(process),
    );
    _processes.add(process);
    return process;
  }

  /// Opens one session channel inside the budget and returns it with its
  /// grant.
  ///
  /// The caller owns what happens next: [run] registers the channel on
  /// [trackChannel] so its `done` releases the grant and the close path
  /// finds it; [start] hands the grant to the `RemoteProcess`, which owns
  /// both. On open failure the grant is released here. A channel that
  /// arrives after the open timeout is closed on arrival, never leaked.
  Future<(SSHSession, ChannelGrant)> _openSessionChannel(
    String command, {
    SSHPtyConfig? pty,
    bool trackChannel = true,
  }) async {
    _throwIfClosingForChannel();
    final acquire = _budget.acquire(
      ChannelWaitPriority.userAction,
      'exec: $command',
    );
    final ChannelGrant grant;
    try {
      grant = await acquire.timeout(openTimeout);
    } on TimeoutException {
      // The waiter stays queued until a slot frees. Its late grant is
      // released at once, so the command the caller gave up on never runs
      // and the slot goes to the next waiter.
      unawaited(acquire.then((late) => late.release(), onError: (_) {}));
      rethrow;
    }
    _pendingOpens++;
    try {
      final pending = _client.execute(command, pty: pty);
      SSHSession channel;
      try {
        channel = await pending.timeout(openTimeout);
      } catch (_) {
        // The open was abandoned at its bound; whatever arrives late on it
        // is owned by nobody — close it on arrival, never leak it.
        unawaited(pending.then(_discardSession, onError: (_) {}));
        rethrow;
      }
      if (trackChannel) _trackChannel(channel, grant);
      return (channel, grant);
    } catch (e) {
      grant.release();
      throw _classifyOpen(e, ChannelOpenKind.session);
    } finally {
      _pendingOpens--;
    }
  }

  void _trackChannel(SSHSession channel, ChannelGrant grant) {
    _execChannels.add(channel);
    unawaited(
      channel.done.then(
        (_) {
          _execChannels.remove(channel);
          grant.release();
        },
        onError: (_) {
          _execChannels.remove(channel);
          grant.release();
        },
      ),
    );
  }

  // ---- forwarding ---------------------------------------------------------

  @override
  Future<ByteDuplex> openUnixStream(String socketPath) => _openDuplex(
    () => _client.forwardLocalUnix(socketPath),
    ChannelOpenKind.directStreamLocal,
  );

  @override
  Future<ByteDuplex> openTcpStream(String host, int port) => _openDuplex(
    () => _client.forwardLocal(host, port),
    ChannelOpenKind.directTcpip,
  );

  Future<ByteDuplex> _openDuplex(
    Future<SSHForwardChannel> Function() open,
    ChannelOpenKind kind,
  ) async {
    _throwIfClosingForChannel();
    // Opens still in flight count against the bound, or a burst of
    // concurrent opens would all pass this check before any registers.
    if (_duplexes.length + _pendingDuplexOpens >= _maxDuplexes) {
      throw ChannelOpenException(
        ChannelRefusal.other,
        'The link already carries $_maxDuplexes open streams.',
      );
    }
    _pendingOpens++;
    _pendingDuplexOpens++;
    try {
      final pending = open();
      SSHForwardChannel channel;
      try {
        channel = await pending.timeout(openTimeout);
      } catch (_) {
        // The open was abandoned at its bound; whatever arrives late on it
        // is owned by nobody — close it on arrival, never leak it.
        unawaited(pending.then(_discardForward, onError: (_) {}));
        rethrow;
      }
      final duplex = ChannelByteDuplex(channel, onData: _noteInbound);
      _duplexes.add(duplex);
      unawaited(
        duplex.done.then(
          (_) => _duplexes.remove(duplex),
          onError: (_) => _duplexes.remove(duplex),
        ),
      );
      return duplex;
    } catch (e) {
      throw _classifyOpen(e, kind);
    } finally {
      _pendingOpens--;
      _pendingDuplexOpens--;
    }
  }

  // ---- file system --------------------------------------------------------

  @override
  Future<RemoteFileSystem> openFileSystem() {
    if (_closed || _client.isClosed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'open SFTP',
        message: 'The SSH link is closed.',
      );
    }
    return Future.value(_fileSystem ??= _LeasedLinkFileSystem(this));
  }

  // ---- open classification ------------------------------------------------

  void _throwIfClosingForChannel() {
    if (_closed) {
      throw const ChannelOpenException(
        ChannelRefusal.other,
        'The SSH link is closed.',
      );
    }
  }

  Object _classifyOpen(Object e, ChannelOpenKind kind) {
    if (e is! SSHChannelOpenError) return e;
    final refusal = classifyChannelRefusal(
      kind,
      observedOpens: _budget.inUse,
      effectiveLimit: _budget.effectiveLimit,
      reasonCode: e.code,
      description: e.description,
    );
    switch (refusal) {
      case ChannelRefusal.sessionLimit:
        _budget.learnLimit(_budget.inUse);
        _learnedSessionLimit = _budget.learnedLimit;
        _setState(
          const SshLinkDegraded(SshLinkDegradedReason.sessionLimitLearned),
        );
        return ChannelOpenException(
          refusal,
          'The server refused to open a session channel: ${e.description}',
          cause: e,
        );
      case ChannelRefusal.forwardDisabled:
        _forwardingRefused = true;
        // A learned fact re-emits Ready with the updated seen, so listeners
        // see the change without polling; a terminal state stays terminal.
        if (_state is! SshLinkClosed) _setState(SshLinkReady(seen));
        return ChannelOpenException(
          refusal,
          'The server refused forwarding: ${e.description}',
          cause: e,
        );
      case ChannelRefusal.other:
        return ChannelOpenException(
          refusal,
          'The server refused a channel open: ${e.description}',
          cause: e,
        );
    }
  }

  /// Bounded close for a channel that arrived after its caller gave up.
  Future<void> _discardSession(SSHSession channel) => runSequentialCleanup(
    [channel.close, () => channel.done],
    actionTimeout: closeTimeout,
    failureMode: CleanupFailureMode.ignore,
  );

  Future<void> _discardForward(SSHForwardChannel channel) =>
      runSequentialCleanup(
        [channel.close, channel.destroy],
        actionTimeout: closeTimeout,
        failureMode: CleanupFailureMode.ignore,
      );

  // ---- close --------------------------------------------------------------

  @override
  Future<void> close() =>
      _cleanup.run(() => _closeOnce(SshLinkClosedReason.closedByOwner));

  /// One teardown path behind [SingleFlightCleanup]: the ping loop and
  /// queued acquires first, then live processes/duplexes/exec channels, the
  /// SFTP lease, and finally the transport.
  Future<void> _closeOnce(SshLinkClosedReason reason) async {
    if (_closed) return;
    _closed = true;
    _pingTimer?.cancel();
    _pingTimer = null;
    _budget.failWaiters(
      const ChannelOpenException(
        ChannelRefusal.other,
        'The SSH link is closed.',
      ),
    );
    _setState(SshLinkClosed(reason));
    final fileSystem = _fileSystem;
    _fileSystem = null;
    try {
      await runSequentialCleanup(
        [
          for (final process in _processes.toList()) process.close,
          for (final duplex in _duplexes.toList()) duplex.close,
          for (final channel in _execChannels.toList()) channel.close,
          if (fileSystem != null) fileSystem.releaseNow,
          () => _clientOrNull?.close(),
        ],
        actionTimeout: closeTimeout,
        failureMode: CleanupFailureMode.ignore,
      );
    } finally {
      await _stateController.close();
    }
  }
}

/// The link's lazily leased SFTP channel behind a [RemoteFileSystem] facade.
///
/// The lease is shared: every call joins the same in-flight open, so
/// concurrent users never stack channels. Each operation re-arms an idle
/// timer; when it fires the SFTP channel closes and the budget slot frees.
final class _LeasedLinkFileSystem implements RemoteFileSystem {
  _LeasedLinkFileSystem(this._link);

  final _SshLink _link;
  Future<_FsLease>? _lease;
  _FsLease? _leaseValue;
  Timer? _idleTimer;
  var _inFlightOps = 0;

  /// In-flight facade calls plus operations the SFTP adapter itself still
  /// counts; the link's ping tick skips while either is nonzero.
  bool get hasActiveOperations =>
      _inFlightOps > 0 || (_leaseValue?.fs.hasActiveOperations ?? false);

  @override
  Future<String> canonicalize(String path) =>
      _withFs((fs) => fs.canonicalize(path));

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      _withFs((fs) => fs.listDirectory(path));

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) =>
      _withFs((fs) => fs.stat(path, followLinks: followLinks));

  @override
  Future<void> setMode(String path, int permissions) =>
      _withFs((fs) => fs.setMode(path, permissions));

  @override
  Future<void> setTimes(
    String path, {
    DateTime? accessedAt,
    DateTime? modifiedAt,
  }) => _withFs(
    (fs) => fs.setTimes(path, accessedAt: accessedAt, modifiedAt: modifiedAt),
  );

  @override
  Future<void> setOwner(String path, {int? uid, int? gid}) =>
      _withFs((fs) => fs.setOwner(path, uid: uid, gid: gid));

  @override
  Future<String> readSymbolicLink(String path) =>
      _withFs((fs) => fs.readSymbolicLink(path));

  @override
  Future<void> createSymbolicLink(String linkPath, String targetPath) =>
      _withFs((fs) => fs.createSymbolicLink(linkPath, targetPath));

  @override
  Future<void> createDirectory(String path) =>
      _withFs((fs) => fs.createDirectory(path));

  @override
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
  }) => _withFs((fs) => fs.rename(oldPath, newPath, overwrite: overwrite));

  @override
  Future<void> delete(RemoteFileEntry entry) =>
      _withFs((fs) => fs.delete(entry));

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) => _withFs(
    (fs) => fs.download(
      path,
      destination,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    ),
  );

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) => _withFs(
    (fs) => fs.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    ),
  );

  Future<T> _withFs<T>(Future<T> Function(RemoteFileSystem fs) body) async {
    if (_link._closed || _link._client.isClosed) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'SFTP operation',
        message: 'The SSH link is closed.',
      );
    }
    _idleTimer?.cancel();
    _inFlightOps++;
    try {
      final lease = await _leaseFs();
      return await body(lease.fs);
    } finally {
      _inFlightOps--;
      _armIdle();
    }
  }

  Future<_FsLease> _leaseFs() {
    return _lease ??= _openFs().then(
      (lease) => lease,
      onError: (Object e) {
        _lease = null;
        throw e;
      },
    );
  }

  Future<_FsLease> _openFs() async {
    final grant = await _link._budget.acquire(ChannelWaitPriority.sftp, 'SFTP');
    _link._pendingOpens++;
    try {
      final pending = _link._client.sftp();
      SftpClient sftp;
      try {
        sftp = await pending.timeout(_link.openTimeout);
      } catch (_) {
        // The open was abandoned at its bound; whatever arrives late on it
        // is owned by nobody — close it on arrival, never leak it.
        unawaited(pending.then(_discardSftp, onError: (_) {}));
        rethrow;
      }
      try {
        await sftp.handshake.timeout(_link.openTimeout);
      } catch (_) {
        unawaited(_discardSftp(sftp));
        rethrow;
      }
      return _leaseValue = _FsLease(DartSshRemoteFileSystem(sftp), sftp, grant);
    } catch (e) {
      grant.release();
      if (_link._closed || _link._client.isClosed || e is TimeoutException) {
        throw const RemoteFileException(
          kind: RemoteFileErrorKind.disconnected,
          operation: 'open SFTP',
          message: 'The SSH link is closed.',
        );
      }
      throw RemoteFileException(
        kind: RemoteFileErrorKind.unsupported,
        operation: 'open SFTP',
        message: 'Could not open SFTP on this server: $e',
        cause: e,
      );
    } finally {
      _link._pendingOpens--;
    }
  }

  Future<void> _discardSftp(SftpClient sftp) => runSequentialCleanup(
    [sftp.close],
    actionTimeout: _link.closeTimeout,
    failureMode: CleanupFailureMode.ignore,
  );

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_link.sftpIdleRelease, releaseNow);
  }

  /// Closes the SFTP channel and frees the budget slot immediately. Called
  /// by the idle timer and by the link's close path.
  Future<void> releaseNow() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    final leaseFuture = _lease;
    _lease = null;
    _leaseValue = null;
    if (leaseFuture == null) return;
    try {
      final lease = await leaseFuture;
      await runSequentialCleanup(
        [lease.sftp.close, lease.grant.release],
        actionTimeout: _link.closeTimeout,
        failureMode: CleanupFailureMode.ignore,
      );
    } catch (_) {
      // A lease that never opened holds nothing to release.
    }
  }
}

final class _FsLease {
  _FsLease(this.fs, this.sftp, this.grant);

  final DartSshRemoteFileSystem fs;
  final SftpClient sftp;
  final ChannelGrant grant;
}
