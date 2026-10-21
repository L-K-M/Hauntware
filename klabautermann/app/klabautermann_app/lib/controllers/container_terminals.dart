import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Where a [ContainerShell] stands.
@immutable
sealed class ContainerShellState {
  const ContainerShellState();
}

/// [OpenTerminal] went out; nothing has come back yet.
final class ContainerShellOpening extends ContainerShellState {
  const ContainerShellOpening();
}

/// The shell runs [command], as the exec was created.
final class ContainerShellRunning extends ContainerShellState {
  const ContainerShellRunning(this.command);

  final List<String> command;
}

/// The shell ended, or never started. Nothing follows it.
final class ContainerShellEnded extends ContainerShellState {
  const ContainerShellEnded(this.reason, {this.exitCode, this.detail});

  /// Why, as [TerminalClosed] said; null when the engine stopped, which
  /// ends every shell with it.
  final TerminalCloseReason? reason;

  /// The shell's exit code, with [TerminalCloseReason.exited] when the
  /// daemon reported one.
  final int? exitCode;

  /// The daemon's message or the error, shown as is.
  final String? detail;
}

/// One container shell [ContainerTerminals.open] opened (03 §7.13,
/// CTX-07): the far end a terminal view feeds from and writes to.
final class ContainerShell {
  ContainerShell._(
    this._terminals,
    this.id, {
    required this.serverId,
    required this.containerId,
  });

  final ContainerTerminals _terminals;

  /// The [OpenTerminal.terminalId], never reused this engine run.
  final String id;
  final String serverId;
  final String containerId;

  final _state = ValueNotifier<ContainerShellState>(
    const ContainerShellOpening(),
  );
  final _output = StreamController<Uint8List>();

  /// Where the shell stands; [ContainerShellEnded] is the last value.
  ValueListenable<ContainerShellState> get state => _state;

  /// What the shell's TTY wrote, in order; done once the shell ended.
  Stream<Uint8List> get output => _output.stream;

  bool get _ended => _state.value is ContainerShellEnded;
  bool _closing = false;

  /// Keystrokes and pastes, as the terminal encoded them. Dropped once
  /// the shell ended.
  void write(Uint8List bytes) {
    if (_ended || bytes.isEmpty) return;
    _terminals._send(TerminalInput(id, bytes));
  }

  /// The terminal's new size, clamped to what the engine takes.
  void resize({required int columns, required int rows}) {
    if (_ended) return;
    _terminals._send(
      TerminalResize(
        id,
        columns: clampTerminalDimension(columns),
        rows: clampTerminalDimension(rows),
      ),
    );
  }

  /// Closes the shell; the engine answers with [TerminalCloseReason.closed].
  /// Idempotent, and nothing once the shell ended.
  void close() {
    if (_ended || _closing) return;
    _closing = true;
    _terminals._send(CloseTerminal(id));
  }

  void _opened(List<String> command) {
    if (_ended) return;
    _state.value = ContainerShellRunning(command);
  }

  void _bytes(Uint8List bytes) {
    if (!_ended) _output.add(bytes);
  }

  void _end(ContainerShellEnded ended) {
    if (_ended) return;
    _state.value = ended;
    unawaited(_output.close());
  }
}

/// [value] within the engine's terminal dimensions, 1 to
/// [kTerminalDimensionMax].
int clampTerminalDimension(int value) =>
    math.max(1, math.min(value, kTerminalDimensionMax));

/// The app's container shells for one engine run (03 §7.13, §10.1): mints
/// terminal ids, sends [OpenTerminal] and the shell's input, and hands
/// each shell's events to its [ContainerShell].
///
/// A [RequestRejected] names no terminal. The app sends only well-formed
/// opens (a fresh id, a shell that is null or not empty, a clamped size),
/// so the one rejection left is an engine whose links are off, which
/// rejects every open; a rejection of [OpenTerminal] therefore ends every
/// shell that has heard nothing yet.
final class ContainerTerminals {
  ContainerTerminals(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  int _count = 0;
  bool _stopped = false;

  final Map<String, ContainerShell> _shells = {};

  /// Opens a shell in [containerId] on [serverId] at [columns] by [rows]:
  /// [shell] null or blank lets the engine pick `/bin/bash` or `/bin/sh`,
  /// [user] null or blank runs as the container's user.
  ContainerShell open({
    required String serverId,
    required String containerId,
    String? shell,
    String? user,
    required int columns,
    required int rows,
  }) {
    final id = 'shell-${_count++}';
    final opened = ContainerShell._(
      this,
      id,
      serverId: serverId,
      containerId: containerId,
    );
    if (_stopped) {
      opened._end(const ContainerShellEnded(null));
      return opened;
    }

    _shells[id] = opened;
    _send(
      OpenTerminal(
        terminalId: id,
        serverId: serverId,
        containerId: containerId,
        shell: _blankToNull(shell),
        user: _blankToNull(user),
        columns: clampTerminalDimension(columns),
        rows: clampTerminalDimension(rows),
      ),
    );
    return opened;
  }

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  void _send(EngineRequest request) {
    if (_stopped) return;
    try {
      _engine.send(request);
    } on StateError {
      _onEngineDone();
    }
  }

  void _onEvent(EngineEvent event) {
    switch (event) {
      case TerminalOpened(:final terminalId, :final command):
        _shells[terminalId]?._opened(command);
      case TerminalBytes(:final terminalId, :final bytes):
        _shells[terminalId]?._bytes(bytes);
      case TerminalClosed(
        :final terminalId,
        :final reason,
        :final exitCode,
        :final detail,
      ):
        _shells
            .remove(terminalId)
            ?._end(
              ContainerShellEnded(reason, exitCode: exitCode, detail: detail),
            );
      case RequestRejected(:final requestName, :final reason)
          when requestName == '$OpenTerminal':
        final waiting = [
          for (final shell in _shells.values)
            if (shell.state.value is ContainerShellOpening) shell,
        ];
        for (final shell in waiting) {
          _shells.remove(shell.id);
          shell._end(
            ContainerShellEnded(TerminalCloseReason.failed, detail: reason),
          );
        }
      case EngineEvent():
        break;
    }
  }

  void _onEngineDone() {
    if (_stopped) return;
    _stopped = true;
    final shells = _shells.values.toList();
    _shells.clear();
    for (final shell in shells) {
      shell._end(const ContainerShellEnded(null));
    }
  }

  /// Stops listening and ends every shell: the engine run is over.
  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
