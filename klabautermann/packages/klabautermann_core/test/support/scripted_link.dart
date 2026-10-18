// A scripted SshLink and RemoteProcess for sampler tests: the test plays
// the host's stdout, sees what the client writes, and sees every close.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart'
    show kCollectorSetVersion;
import 'package:seance_core/seance_core.dart';

/// The parts of [SshLink] the samplers and the link supervisor do not
/// use throw.
abstract base class TestLinkBase implements SshLink {
  final _changes = StreamController<SshLinkState>.broadcast();
  SshLinkState _state = const SshLinkReady(SshLinkSeen());
  int closes = 0;

  /// What refused opens taught the link; a test sets a learned limit.
  @override
  SshLinkSeen seen = const SshLinkSeen();

  @override
  SshLinkState get state => _state;

  /// Moves the link to [next] and reports it on [states].
  set state(SshLinkState next) => _changes.add(_state = next);

  /// The current state for each listener, then every change.
  @override
  Stream<SshLinkState> get states => Stream.multi((controller) {
    controller.add(_state);
    final subscription = _changes.stream.listen(controller.add);
    controller.onCancel = subscription.cancel;
  });

  @override
  Future<void> close() async {
    closes++;
    if (_state is SshLinkClosed) return;
    state = const SshLinkClosed(SshLinkClosedReason.closedByOwner);
  }

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// Hands out a [ScriptedProcess] per start, or throws the next queued
/// failure.
final class ScriptedLink extends TestLinkBase {
  final commands = <String>[];
  final processes = <ScriptedProcess>[];

  /// Errors the next starts throw, in order.
  final startFailures = <Object>[];

  /// Holds the next start until completed, to test a late channel.
  Completer<void>? holdNextStart;

  final _waiters = <int, Completer<ScriptedProcess>>{};

  /// The [index]th started process, once it exists.
  Future<ScriptedProcess> process(int index) => index < processes.length
      ? Future.value(processes[index])
      : (_waiters[index] ??= Completer()).future;

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) async {
    commands.add(command);
    final hold = holdNextStart;
    holdNextStart = null;
    if (hold != null) await hold.future;
    if (startFailures.isNotEmpty) throw startFailures.removeAt(0);
    final p = ScriptedProcess();
    processes.add(p);
    _waiters.remove(processes.length - 1)?.complete(p);
    return p;
  }
}

/// A process whose stdout the test writes and whose stdin it reads.
final class ScriptedProcess implements RemoteProcess {
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<RemoteExit>();
  final _written = <int>[];
  final _firstWrite = Completer<void>();
  int closeCalls = 0;

  /// Holds [close] until completed, to test that a closing session waits
  /// for it.
  Completer<void>? holdClose;

  /// Everything the client wrote to stdin.
  String get written => utf8.decode(_written);

  /// Completes once the client has written anything (the program).
  Future<void> get firstWrite => _firstWrite.future;

  /// The nonce the program's first line sets (03 §6.2).
  String get nonce => RegExp(
    r'^N=([0-9a-f]{32})$',
    multiLine: true,
  ).firstMatch(written)!.group(1)!;

  /// The request lines written after the program's READY line.
  List<String> get requests {
    final text = written;
    final at = text.indexOf('READY HWS/1');
    final rest = text.substring(text.indexOf('\n', at) + 1);
    return rest.split('\n').where((l) => l.isNotEmpty).toList();
  }

  bool get exited => _exit.isCompleted;

  void emit(List<int> bytes) => _stdout.add(bytes);

  void emitText(String text) => emit(utf8.encode(text));

  void emitStderr(List<int> bytes) => _stderr.add(bytes);

  /// The program's SELF line, then its READY line with [version].
  void ready([String version = kCollectorSetVersion]) =>
      emitText('\x1e$nonce SELF 4242 4241\n\x1e$nonce READY HWS/1 $version\n');

  /// A complete reply to [seq] with one section per entry of [sections].
  String reply(int seq, Map<String, String> sections) {
    final b = StringBuffer('\x1e$nonce B $seq 12.5\n');
    sections.forEach((name, payload) {
      final bytes = utf8.encode(payload);
      b.write('\x1e$nonce S $name ok ${bytes.length}\n$payload\n');
    });
    b.write('\x1e$nonce E $seq\n');
    return b.toString();
  }

  /// A reply to [seq] that a framing error loses: a byte count over the
  /// section cap, from which the reader resynchronizes on the E marker
  /// (03 §6.2).
  String lostReply(int seq) =>
      '\x1e$nonce B $seq 1.0\n\x1e$nonce S overview ok 99999999\n'
      'junk\n\x1e$nonce E $seq\n';

  /// The process ends on its own with [exit].
  void end([RemoteExit exit = const RemoteExit(exitCode: 0)]) {
    if (_exit.isCompleted) return;
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exit.complete(exit);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  StreamSink<List<int>> get stdin => _RecordingSink(this);

  @override
  Future<RemoteExit> get exit => _exit.future;

  @override
  void signal(RemoteSignal signal) {}

  @override
  Future<void> close() async {
    closeCalls++;
    await holdClose?.future;
    end(const RemoteExit(exitSignal: 'TERM'));
  }
}

final class _RecordingSink implements StreamSink<List<int>> {
  _RecordingSink(this._process);

  final ScriptedProcess _process;

  @override
  void add(List<int> data) {
    if (_process.exited) throw StateError('stdin closed');
    _process._written.addAll(data);
    if (!_process._firstWrite.isCompleted) _process._firstWrite.complete();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => _process.exit;
}
