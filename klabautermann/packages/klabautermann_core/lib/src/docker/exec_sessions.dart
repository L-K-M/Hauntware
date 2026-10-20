/// Container shells in the engine (03 §7.13, CTX-07): an exec with a TTY
/// over the API upgrade (03 §5.7) per [OpenTerminal], its output sent to
/// the app in paced [TerminalBytes], its input and resizes passed on, and
/// one [TerminalClosed] when it ends.
///
/// ```text
///   OpenTerminal ─▶ policy, fleet and count checks ─▶ refused (closed)
///        │
///        ▼
///   opening: a connection of its own (DockerRouter.openExec), create
///        │   the exec, start it hijacked ─▶ failed (closed)
///        ▼
///   open: output ─▶ TerminalBytes, input and resizes ─▶ the exec
///        │
///        ▼
///   the shell exits, CloseTerminal, the link drops, or admin mode ends
///   under a sudo relay ─▶ closed: exit code read, slot given back,
///   TerminalClosed and an audit record
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';

import '../admin/safety_policy.dart';
import '../engine/protocol.dart';
import 'docker_ladder.dart' show DockerRank;
import 'docker_router.dart'
    show DockerChannelUnavailable, DockerEndpointUnavailable;
import 'docker_watch.dart' show DockerStreamLease;

/// The fewest milliseconds between two [TerminalBytes] of one shell: at
/// most 20 a second, as [LogBatch]es go [E].
const Duration kTerminalBatchInterval = Duration(milliseconds: 50);

/// The most output one shell buffers before the engine stops reading it,
/// which holds the daemon's writes back until a batch went out [E].
const int kTerminalBufferMax = 256 * 1024;

/// The most input buffered while the exec is still starting [E].
const int _pendingInputMax = 64 * 1024;

/// How long the exit code read after the shell ends may take [E].
const Duration _inspectTimeout = Duration(seconds: 5);

/// What runs when [OpenTerminal.shell] is null: `/bin/bash` where the
/// container has it, `/bin/sh` otherwise (03 §7.13), in one exec.
const List<String> kDefaultShellCommand = [
  '/bin/sh',
  '-c',
  'if [ -x /bin/bash ]; then exec /bin/bash; fi; exec /bin/sh',
];

/// The audit record's action for a container shell (03 §8.10).
const String kTerminalAuditAction = 'ContainerShell';

/// A connection of its own to a server's Docker endpoint, and the rank it
/// runs over ([DockerRouter.openExec]).
typedef ExecOpener =
    Future<({DockerStreamLease lease, DockerRank rank})> Function(
      String serverId,
    );

/// Runs a short call on a server's pooled Docker client
/// ([DockerRouter.useEndpoint]).
typedef ExecControl =
    Future<T> Function<T>(
      String serverId,
      Future<T> Function(DockerClient client) call,
    );

/// The engine's container shells, owned by the engine isolate.
final class ExecSessions {
  /// [open] gives a server's exec connection, which only the hijacked
  /// start uses: a hijacked connection stays counted until it closes, so
  /// the create, the resizes and the exit code run as short calls over
  /// [control], as the Docker CLI makes them on connections of their own.
  /// [fleet] says whether a
  /// server is in the fleet; [audit] records each shell that started
  /// once it ends. [startTimer] and [elapsed], a monotonic clock, pace
  /// the batches; [now] dates the audit records.
  ExecSessions({
    required this._open,
    required this._control,
    required this._emit,
    required this._fleet,
    this._audit,
    this._deviceId,
    this._startTimer = Timer.new,
    Duration Function()? elapsed,
    this._now = DateTime.now,
  }) : _elapsed = elapsed ?? _monotonicClock();

  final ExecOpener _open;
  final ExecControl _control;
  final void Function(EngineEvent event) _emit;
  final bool Function(String serverId) _fleet;
  final Future<void> Function(AuditRecord record)? _audit;
  final String? _deviceId;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final Duration Function() _elapsed;
  final DateTime Function() _now;

  final Map<String, _Terminal> _terminals = {};

  /// Whether a shell is open or opening as [terminalId].
  bool isOpen(String terminalId) => _terminals.containsKey(terminalId);

  /// Why [request] is malformed, for a [RequestRejected], or null. A
  /// well-formed request the engine cannot honour is answered with a
  /// [TerminalClosed] instead.
  String? validate(OpenTerminal request) {
    if (_terminals.containsKey(request.terminalId)) {
      return 'terminal ${request.terminalId} is already open';
    }
    if (request.containerId.isEmpty) return 'no container';
    if (request.shell?.isEmpty ?? false) return 'an empty shell';
    if (!_validSize(request.columns, request.rows)) {
      return 'terminal size ${request.columns}x${request.rows}';
    }
    return null;
  }

  /// Opens [request]'s shell under [policy], which refuses it on an
  /// observe-only or read-only server. [validate] has passed.
  void open(OpenTerminal request, SafetyPolicy policy) {
    final OpenTerminal(:terminalId, :serverId) = request;
    void refuse(TerminalCloseReason reason) =>
        _emit(TerminalClosed(terminalId, reason));

    if (!_fleet(serverId)) return refuse(TerminalCloseReason.notInFleet);
    switch (safetyRefusal(policy, serverId)) {
      case ActionRefusalReason.readOnly:
        return refuse(TerminalCloseReason.readOnly);
      case ActionRefusalReason.observeOnly:
        return refuse(TerminalCloseReason.observeOnly);
      case _:
        break;
    }
    final held = _terminals.values.where((t) => t.serverId == serverId);
    if (held.length >= kTerminalsPerServerMax) {
      return refuse(TerminalCloseReason.tooMany);
    }

    final terminal = _Terminal(
      request,
      request.shell == null ? kDefaultShellCommand : [request.shell!],
      _now(),
    );
    _terminals[terminalId] = terminal;
    unawaited(_start(terminal));
  }

  /// Passes [request]'s bytes to its shell, or holds them while it starts.
  void input(TerminalInput request) {
    final terminal = _terminals[request.terminalId];
    // An ended shell stays listed while its exit code is read, with its
    // connection already closed.
    if (terminal == null || terminal.ended || terminal.inputEnded) return;
    final duplex = terminal.duplex;
    if (duplex != null) {
      duplex.sink.add(request.bytes);
      return;
    }
    // Input past the bound while the exec starts is dropped, as a
    // terminal drops keystrokes nothing reads.
    if (terminal.pendingLength + request.bytes.length > _pendingInputMax) {
      return;
    }
    terminal.pendingInput.add(request.bytes);
  }

  /// Passes [request]'s size on, after every size before it.
  void resize(TerminalResize request) {
    final terminal = _terminals[request.terminalId];
    if (terminal == null) return;
    if (!_validSize(request.columns, request.rows)) return;
    terminal.size = ExecConsoleSize(
      rows: request.rows,
      columns: request.columns,
    );
    if (terminal.execId != null) _sendSize(terminal);
  }

  /// Half-closes [terminalId]'s input (03 §5.7).
  void endInput(String terminalId) {
    final terminal = _terminals[terminalId];
    if (terminal == null || terminal.inputEnded) return;
    terminal.inputEnded = true;
    final duplex = terminal.duplex;
    if (duplex != null) unawaited(_quietly(duplex.closeWrite()));
  }

  /// Closes [terminalId]'s shell.
  void close(String terminalId) {
    final terminal = _terminals[terminalId];
    if (terminal != null) _end(terminal, TerminalCloseReason.closed);
  }

  /// [serverId]'s link dropped: its shells end with it.
  void linkLost(String serverId) {
    for (final terminal in _of(serverId)) {
      _end(terminal, TerminalCloseReason.linkLost);
    }
  }

  /// Admin mode on [serverId] ended: shells over its sudo relay end with
  /// it, as the relay does (03 §5.9 rank 3).
  void adminEnded(String serverId) {
    for (final terminal in _of(serverId)) {
      if (terminal.rank == DockerRank.sudoRelay) {
        _end(terminal, TerminalCloseReason.adminEnded);
      }
    }
  }

  /// [serverIds] left the fleet: their shells end.
  void forget(Iterable<String> serverIds) {
    final gone = serverIds.toSet();
    for (final terminal in _terminals.values.toList()) {
      if (gone.contains(terminal.serverId)) {
        _end(terminal, TerminalCloseReason.notInFleet);
      }
    }
  }

  /// Ends every shell, as the engine stops.
  Future<void> dispose() async {
    final ending = [
      for (final terminal in _terminals.values.toList())
        _end(terminal, TerminalCloseReason.closed),
    ];
    await Future.wait(ending);
  }

  List<_Terminal> _of(String serverId) => [
    for (final terminal in _terminals.values)
      if (terminal.serverId == serverId) terminal,
  ];

  Future<void> _start(_Terminal terminal) async {
    final request = terminal.request;
    final size = terminal.size;
    try {
      final (:lease, :rank) = await _open(request.serverId);
      terminal.lease = lease;
      terminal.rank = rank;
      if (terminal.ended) return await lease.close();

      final execId = await _control(
        request.serverId,
        (client) => client.createExec(
          request.containerId,
          terminal.command,
          tty: true,
          user: request.user,
          consoleSize: size,
        ),
      );
      if (terminal.ended) return;
      final response = await lease.client.startExec(
        execId,
        tty: true,
        consoleSize: size,
      );
      if (terminal.ended) return await response.body.close();

      terminal
        ..execId = execId
        ..duplex = response.body;
      _emit(TerminalOpened(request.terminalId, terminal.command));
      terminal.subscription = response.body.stream.listen(
        (chunk) => _output(terminal, chunk),
        onError: (Object error) =>
            _end(terminal, TerminalCloseReason.failed, detail: '$error'),
        onDone: () => _end(terminal, TerminalCloseReason.exited),
        cancelOnError: true,
      );

      for (final bytes in terminal.pendingInput) {
        response.body.sink.add(bytes);
      }
      terminal.pendingInput.clear();
      if (terminal.inputEnded) unawaited(_quietly(response.body.closeWrite()));
      // A resize while the exec started; the create took the size before.
      if (terminal.size != size) _sendSize(terminal);
    } on DockerEndpointUnavailable catch (e) {
      await _end(
        terminal,
        e.failure == DockerQueryFailure.notInFleet
            ? TerminalCloseReason.notInFleet
            : e.failure == DockerQueryFailure.linkUnavailable
            ? TerminalCloseReason.linkLost
            : TerminalCloseReason.endpointUnavailable,
      );
    } on DockerChannelUnavailable {
      await _end(terminal, TerminalCloseReason.noChannel);
    } on DockerNotFoundException catch (e) {
      await _end(
        terminal,
        TerminalCloseReason.refused,
        detail: e.daemonMessage,
      );
    } on DockerApiException catch (e) {
      await _end(
        terminal,
        TerminalCloseReason.refused,
        detail: e.daemonMessage ?? 'HTTP ${e.statusCode}',
      );
    } on Object catch (e) {
      await _end(terminal, TerminalCloseReason.failed, detail: '$e');
    }
  }

  void _output(_Terminal terminal, List<int> chunk) {
    if (terminal.ended) return;
    terminal.buffer.add(chunk);
    if (terminal.buffer.length >= kTerminalBufferMax) {
      terminal.subscription?.pause();
    }
    _schedule(terminal);
  }

  /// Sends [terminal]'s buffer now if the last batch went out at least
  /// [kTerminalBatchInterval] ago, or arms the send for then.
  void _schedule(_Terminal terminal) {
    if (terminal.flushTimer != null || terminal.buffer.isEmpty) return;
    final last = terminal.lastSent;
    final wait = last == null
        ? Duration.zero
        : kTerminalBatchInterval - (_elapsed() - last);
    if (wait <= Duration.zero) return _flush(terminal);
    terminal.flushTimer = _startTimer(wait, () {
      terminal.flushTimer = null;
      _flush(terminal);
    });
  }

  void _flush(_Terminal terminal) {
    if (terminal.buffer.isEmpty) return;
    terminal.lastSent = _elapsed();
    _emit(
      TerminalBytes(terminal.request.terminalId, terminal.buffer.takeBytes()),
    );
    final subscription = terminal.subscription;
    if (subscription != null && subscription.isPaused && !terminal.ended) {
      subscription.resume();
    }
  }

  /// Sends [terminal]'s latest size after every resize before it, so
  /// the daemon ends at the last one.
  void _sendSize(_Terminal terminal) {
    final execId = terminal.execId!;
    terminal.resizes = terminal.resizes.then((_) {
      if (terminal.ended || terminal.sentSize == terminal.size) return null;
      final size = terminal.size;
      terminal.sentSize = size;
      return _quietly(
        _control(
          terminal.serverId,
          (client) => client.resizeExec(execId, size),
        ),
      );
    });
  }

  /// Ends [terminal] once: reads the exit code of a shell that exited,
  /// sends the rest of its output, gives the connection and its slot
  /// back, and reports [reason].
  Future<void> _end(
    _Terminal terminal,
    TerminalCloseReason reason, {
    String? detail,
  }) {
    final ended = terminal.ending;
    if (ended != null) return ended;
    return terminal.ending = _finish(terminal, reason, detail);
  }

  Future<void> _finish(
    _Terminal terminal,
    TerminalCloseReason reason,
    String? detail,
  ) async {
    terminal.ended = true;
    terminal.flushTimer?.cancel();
    terminal.flushTimer = null;
    final terminalId = terminal.request.terminalId;

    final subscription = terminal.subscription;
    terminal.subscription = null;
    await _quietly(subscription?.cancel());
    _flush(terminal);
    await _quietly(terminal.duplex?.close());

    int? exitCode;
    final execId = terminal.execId;
    final lease = terminal.lease;
    if (reason == TerminalCloseReason.exited && execId != null) {
      try {
        final inspect = await _control(
          terminal.serverId,
          (client) => client.inspectExec(execId),
        ).timeout(_inspectTimeout);
        exitCode = inspect.value.exitCode;
      } on Object {
        // The shell ended either way; only its code is unknown.
      }
    }
    await _quietly(terminal.resizes);
    await _quietly(lease?.close());

    // The id is free again once the app hears of the end.
    if (identical(_terminals[terminalId], terminal)) {
      _terminals.remove(terminalId);
    }
    _emit(
      TerminalClosed(terminalId, reason, exitCode: exitCode, detail: detail),
    );
    if (execId != null) await _record(terminal, reason, exitCode);
  }

  Future<void> _record(
    _Terminal terminal,
    TerminalCloseReason reason,
    int? exitCode,
  ) async {
    final audit = _audit;
    if (audit == null) return;
    final request = terminal.request;
    final user = request.user;
    try {
      await audit(
        AuditRecord(
          serverId: request.serverId,
          action: kTerminalAuditAction,
          targetName: request.containerId,
          steps: [
            'exec ${terminal.command.join(' ')}'
                '${user == null ? '' : ' as $user'}',
          ],
          tier: ConfirmationTier.none,
          outcome: switch (reason) {
            TerminalCloseReason.exited ||
            TerminalCloseReason.closed => ActionOutcome.succeeded,
            _ => ActionOutcome.failed,
          },
          startedAt: terminal.startedAt,
          endedAt: _now(),
          deviceId: _deviceId,
          exitCode: exitCode,
        ),
      );
    } on Object {
      // A record that cannot be written loses this record only, as a
      // run's does.
    }
  }
}

/// One shell, from [OpenTerminal] to [TerminalClosed].
final class _Terminal {
  _Terminal(this.request, this.command, this.startedAt)
    : size = ExecConsoleSize(rows: request.rows, columns: request.columns);

  final OpenTerminal request;
  final List<String> command;
  final DateTime startedAt;

  String get serverId => request.serverId;

  DockerStreamLease? lease;
  DockerRank? rank;
  String? execId;
  HijackedDuplex? duplex;
  StreamSubscription<List<int>>? subscription;

  /// The size the app last asked for, and the last one sent.
  ExecConsoleSize size;
  ExecConsoleSize? sentSize;

  /// The resizes sent so far, chained so they arrive in order.
  Future<void> resizes = Future.value();

  final BytesBuilder buffer = BytesBuilder(copy: false);
  final List<Uint8List> pendingInput = [];
  int get pendingLength =>
      pendingInput.fold(0, (sum, bytes) => sum + bytes.length);
  Duration? lastSent;
  Timer? flushTimer;
  bool inputEnded = false;
  bool ended = false;
  Future<void>? ending;
}

bool _validSize(int columns, int rows) =>
    columns > 0 &&
    rows > 0 &&
    columns <= kTerminalDimensionMax &&
    rows <= kTerminalDimensionMax;

Future<void> _quietly(Future<Object?>? future) async {
  try {
    await future;
  } on Object {
    // Teardown of a connection already gone.
  }
}

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
