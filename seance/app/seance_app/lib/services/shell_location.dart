import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

/// Where a session's shell is, for everything that follows it: the Files and
/// Git panes, and the tab's label and header.
///
/// ```text
/// engine ── OSC 7 ────────────────────────────┐
///        ── Enter, full-screen exit, title ─┐  ├─► value ─► Files, Git, tab
///                                           ▼  │
///              RemoteShellDirectory: /proc read
/// ```
///
/// OSC 7 is authoritative. A shell that sends none (TrueNAS's zsh) is read
/// beside it after every cue instead, one read at a time, so the panes and
/// the tab share one exec channel rather than each asking. A title is not a
/// source here: each consumer reads one its own way, below [value].
class ShellLocation extends ChangeNotifier implements ValueListenable<String?> {
  /// The engine's OSC 7 directory.
  final ValueListenable<String?> _reported;

  /// Ticks when the shell may have moved: the cue to read it again.
  final Listenable? _mayHaveMoved;

  /// A title change says the same: a `cd` that ran well after its Enter
  /// (`git clone … && cd repo`) retitles the tab.
  final Listenable? _titleChanged;

  RemoteShellDirectory? _reader;

  /// The last answer from [_reader]. Kept through reads with no answer: the
  /// shell is still somewhere, and the next cue asks again.
  String? _read;

  /// [value] as listeners last heard it.
  String? _announced;

  Timer? _debounce;
  Future<void>? _reading;
  bool _readAgain = false;
  bool _disposed = false;

  /// Gives the shell a moment to run the line before it is asked where it
  /// is, and collapses a burst of Enters (a pasted script) into one read.
  static const Duration _readDelay = Duration(milliseconds: 300);

  /// Until the shell has answered once, a read without an answer asks again
  /// this often, this many times: the read at connect can look before sshd
  /// has started the shell.
  static const Duration _firstAnswerRetryDelay = Duration(seconds: 1);
  static const int _firstAnswerRetries = 2;
  int _firstAnswerRetriesLeft = _firstAnswerRetries;

  ShellLocation({
    required this._reported,
    this._mayHaveMoved,
    this._titleChanged,
  }) {
    _announced = value;
    _reported.addListener(_announce);
    _mayHaveMoved?.addListener(_scheduleRead);
    _titleChanged?.addListener(_scheduleRead);
  }

  /// OSC 7 when the shell sends it, else the directory last read beside it,
  /// else null.
  @override
  String? get value => _absolute(_reported.value) ?? _read;

  /// Asks where the shell is now, as Files opens or follows again: a shell
  /// can move without a cue (a key binding that runs `cd`). Completes once
  /// answered; a read in flight answers for it, and nothing is read while
  /// OSC 7 answers.
  Future<void> readNow() {
    if (!_readWanted) return Future<void>.value();
    return _reading ?? _requestRead();
  }

  /// Reads the shell through [reader] from now on: at once, and after every
  /// cue while OSC 7 is silent.
  void readWith(RemoteShellDirectory reader) {
    _reader = reader;
    if (_readWanted) unawaited(_requestRead());
  }

  /// Stops reading when the connection is gone, keeping the last answer:
  /// the shell was last seen there.
  void stopReading() {
    _reader = null;
    _debounce?.cancel();
  }

  bool get _readWanted =>
      !_disposed &&
      (_reader?.available ?? false) &&
      _absolute(_reported.value) == null;

  void _scheduleRead([Duration delay = _readDelay]) {
    if (!_readWanted) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      if (_readWanted) unawaited(_requestRead());
    });
  }

  /// One read at a time: a cue during a read asks once more after it, so a
  /// slow server never stacks channels.
  Future<void> _requestRead() {
    final inFlight = _reading;
    if (inFlight != null) {
      _readAgain = true;
      return inFlight;
    }
    return _reading = _readShell().whenComplete(() {
      _reading = null;
      if (!_readAgain) return;
      _readAgain = false;
      if (_readWanted) unawaited(_requestRead());
    });
  }

  /// Once the server cannot answer any more, its last answer is dropped:
  /// the consumers' titles lead again.
  Future<void> _readShell() async {
    final reader = _reader!;
    final directory = await reader.read();
    if (_disposed || !identical(reader, _reader)) return;
    if (!reader.available) {
      _read = null;
    } else if (directory != null) {
      _read = directory;
    } else if (_read == null && _firstAnswerRetriesLeft > 0) {
      _firstAnswerRetriesLeft--;
      _scheduleRead(_firstAnswerRetryDelay);
    }
    _announce();
  }

  /// Notifies only a change, as a new OSC 7 report would: an unchanged
  /// answer leaves a manual navigation alone.
  void _announce() {
    final now = value;
    if (now == _announced) return;
    _announced = now;
    notifyListeners();
  }

  static String? _absolute(String? path) =>
      path != null && path.startsWith('/') ? path : null;

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _reported.removeListener(_announce);
    _mayHaveMoved?.removeListener(_scheduleRead);
    _titleChanged?.removeListener(_scheduleRead);
    super.dispose();
  }
}
