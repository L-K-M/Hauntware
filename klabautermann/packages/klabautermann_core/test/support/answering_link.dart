// An SshLink double whose processes play a sampler host for scheduler
// tests: each answers its program with READY and each request line with
// a reply of `ok` sections at once, unless the test holds them.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart'
    show SamplerKind, kCollectorSetVersion;
import 'package:seance_core/seance_core.dart';

import 'scripted_link.dart';

final class AnsweringLink extends TestLinkBase {
  final processes = <AnsweringProcess>[];

  /// Every request line written, with the sampler that wrote it.
  final requests = <({SamplerKind kind, String line})>[];

  /// Samplers whose requests get no reply, as if the process stalled.
  final stalled = <SamplerKind>{};

  /// How many of the next starts fail, as a refused channel does.
  int failStarts = 0;

  /// Starts that hang, as on a silent peer, until [failHungStarts].
  bool hangStarts = false;
  final _hung = <Completer<RemoteProcess>>[];

  /// Fails the hung starts, as the link's channel-open bound would.
  void failHungStarts() {
    for (final start in _hung) {
      start.completeError(TimeoutException('channel open'));
    }
    _hung.clear();
  }

  /// The request lines of [kind] without their sequence numbers, such
  /// as `hw_t procs fs`.
  List<String> linesOf(SamplerKind kind) => [
    for (final r in requests)
      if (r.kind == kind) r.line.replaceFirst(RegExp(r' \d+'), ''),
  ];

  /// The processes still running.
  Iterable<AnsweringProcess> get running => processes.where((p) => !p.exited);

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) {
    if (failStarts > 0) {
      failStarts--;
      return Future.error(StateError('channel refused'));
    }
    if (hangStarts) {
      final hung = Completer<RemoteProcess>();
      _hung.add(hung);
      return hung.future;
    }
    final p = AnsweringProcess._(this);
    processes.add(p);
    return Future.value(p);
  }
}

final class AnsweringProcess implements RemoteProcess {
  AnsweringProcess._(this._link);

  final AnsweringLink _link;
  final _stdout = StreamController<List<int>>();
  final _exit = Completer<RemoteExit>();
  String _buffer = '';
  String? _nonce;

  /// Which program this process runs, once it arrived.
  SamplerKind? kind;

  /// Request lines held while [AnsweringLink.stalled] named [kind].
  final held = <String>[];

  bool get exited => _exit.isCompleted;

  void _onWrite(String text) {
    _buffer += text;
    if (_nonce == null) {
      // The program arrives in one write; only the fast one reads `core`.
      _nonce = RegExp(
        r'^N=([0-9a-f]{32})$',
        multiLine: true,
      ).firstMatch(_buffer)!.group(1);
      kind = _buffer.contains('c_core()') ? SamplerKind.fast : SamplerKind.slow;
      _buffer = '';
      _emit(
        '\x1e$_nonce SELF 4242 4241\n'
        '\x1e$_nonce READY HWS/1 $kCollectorSetVersion\n',
      );
      return;
    }
    for (var at = _buffer.indexOf('\n'); at >= 0; at = _buffer.indexOf('\n')) {
      final line = _buffer.substring(0, at);
      _buffer = _buffer.substring(at + 1);
      _link.requests.add((kind: kind!, line: line));
      if (_link.stalled.contains(kind)) {
        held.add(line);
      } else {
        answer(line);
      }
    }
  }

  /// Replies to [line] with an empty `ok` section per collector it names;
  /// the probe (`hw_o <seq> probe`) gets no sections.
  void answer(String line) {
    final words = line.split(' ');
    final seq = words[1];
    final b = StringBuffer('\x1e$_nonce B $seq 100.0\n');
    if (words.first == 'hw_t') {
      for (final name in words.skip(2)) {
        b.write('\x1e$_nonce S $name ok 0\n\n');
      }
    }
    b.write('\x1e$_nonce E $seq\n');
    _emit(b.toString());
  }

  void _emit(String text) {
    if (!exited) _stdout.add(utf8.encode(text));
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  // Synchronous, so a write is answered before the writer goes on, and
  // a write after the close throws, as a closed channel's does.
  late final _stdin = StreamController<List<int>>(sync: true)
    ..stream.listen((data) => _onWrite(utf8.decode(data)));

  @override
  StreamSink<List<int>> get stdin => _stdin.sink;

  @override
  Future<RemoteExit> get exit => _exit.future;

  @override
  void signal(RemoteSignal signal) {}

  @override
  Future<void> close() async {
    if (exited) return;
    unawaited(_stdout.close());
    unawaited(_stdin.close());
    _exit.complete(const RemoteExit(exitSignal: 'TERM'));
  }
}
