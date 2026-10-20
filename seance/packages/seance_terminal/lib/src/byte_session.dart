import 'dart:async';
import 'dart:typed_data';

import 'package:seance_core/seance_core.dart'
    show SessionTransport, TerminalSize;

import 'xterm_engine.dart';

/// Bytes to and from one far end, such as a container's exec stream, with
/// no SSH or Docker type. Rows and columns are named because Docker's
/// resize takes rows first.
abstract interface class TerminalByteTransport {
  /// Far end to terminal. Done when the far end ends.
  Stream<Uint8List> get output;

  /// Terminal to far end.
  void write(Uint8List bytes);

  /// The terminal's new size, for the far end's TTY.
  void resize({required int columns, required int rows});

  /// Ends the far end. Idempotent.
  Future<void> close();
}

/// Wires an [XtermTerminalEngine] to a [TerminalByteTransport] the way
/// Séance's SSH session wires a shell: output feeds the engine, the
/// user's input goes to the far end while the session is open, and the
/// view's size reaches both. [close] disposes the engine, which this
/// session owns from construction (SessionTransport's ownership rule).
///
/// When [TerminalByteTransport.output] ends, input stops and [onClosed]
/// fires once; the engine stays, so the host can keep showing what the
/// far end printed until it calls [close]. When output fails, the
/// session tears down as [close] does, and [onClosed] fires once.
final class TerminalByteSession implements SessionTransport {
  TerminalByteSession({
    required XtermTerminalEngine engine,
    required TerminalByteTransport transport,
  }) : _engine = engine,
       _transport = transport {
    _output = transport.output.listen(
      engine.feed,
      onDone: () => _ended(failed: false),
      onError: (Object _) => _ended(failed: true),
      cancelOnError: true,
    );
    _input = engine.userInput.listen((bytes) {
      if (!_closed && !_endedRemotely) _transport.write(bytes);
    });
    engine.terminal.onResize = (width, height, _, _) =>
        resize(TerminalSize(width, height));
  }

  final XtermTerminalEngine _engine;
  final TerminalByteTransport _transport;
  late final StreamSubscription<Uint8List> _output;
  late final StreamSubscription<Uint8List> _input;

  bool _closed = false;
  bool _endedRemotely = false;
  bool _notified = false;
  Future<void>? _closing;
  void Function()? _onClosed;

  @override
  bool get isClosed => _closed;

  @override
  void Function()? get onClosed => _onClosed;

  /// Fired once when the far end ends on its own; assigning it after that
  /// still fires it.
  @override
  set onClosed(void Function()? callback) {
    _onClosed = callback;
    if (_endedRemotely && callback != null) scheduleMicrotask(_notifyClosed);
  }

  @override
  void resize(TerminalSize size) {
    if (_closed) return;
    _engine.resize(size);
    _transport.resize(columns: size.cols, rows: size.rows);
  }

  @override
  Future<void> close() => _closing ??= _teardown();

  /// The far end ended or failed: nothing more is written, and
  /// [onClosed] fires once. A failure also tears the session down.
  void _ended({required bool failed}) {
    if (_endedRemotely || _closed) return;
    _endedRemotely = true;
    unawaited(_input.cancel());
    if (failed) unawaited(close());
    _notifyClosed();
  }

  void _notifyClosed() {
    final callback = _onClosed;
    if (_notified || callback == null) return;
    _notified = true;
    callback();
  }

  Future<void> _teardown() async {
    _closed = true;
    _engine.terminal.onResize = null;
    await _input.cancel();
    await _output.cancel();
    try {
      await _transport.close();
    } finally {
      await _engine.dispose();
    }
  }
}
