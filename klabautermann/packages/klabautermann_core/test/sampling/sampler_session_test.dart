// SamplerSession against a scripted process (03 §6.2, D47): the test
// plays the host's output byte for byte and reads what the client writes.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_core/src/sampling/sampler_session.dart';
import 'package:klabautermann_core/src/sampling/sampler_timing.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import '../support/scripted_link.dart';

/// Deadlines short enough to miss within a test.
const _short = SamplerDeadlines(
  ready: Duration(seconds: 1),
  fastRequest: Duration(milliseconds: 300),
);

Future<void> _until(bool Function() condition) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late ScriptedLink link;
  late List<int> delays;
  late List<SamplerState> states;
  late SamplerSession session;

  SamplerSession open({SamplerDeadlines deadlines = const SamplerDeadlines()}) {
    session = SamplerSession(
      link: link,
      kind: SamplerKind.fast,
      quote: quoteShellWord,
      deadlines: deadlines,
      restartDelay: (failures) {
        delays.add(failures);
        return const Duration(milliseconds: 5);
      },
    );
    session.states.listen(states.add);
    return session;
  }

  /// Starts (for the first process) and plays READY on process [index].
  Future<ScriptedProcess> ready([int index = 0]) async {
    if (index == 0) session.start();
    final p = await link.process(index);
    await p.firstWrite;
    p.ready();
    await _until(() => session.state is SamplerReady);
    return p;
  }

  setUp(() {
    link = ScriptedLink();
    delays = [];
    states = [];
  });

  tearDown(() => session.close());

  test('starts with the constant command and program, then READY', () async {
    open().start();
    final p = await link.process(0);
    await p.firstWrite;
    expect(link.commands, [kSamplerStartCommand]);
    expect(
      p.written,
      buildSamplerProgram(kind: SamplerKind.fast, nonce: p.nonce),
    );

    // Nothing else is written before READY (03 §6.2).
    final early = await session.tick([Collector.overview]);
    expect((early as SamplerSkipped).reason, SamplerSkipReason.notReady);
    expect(p.requests, isEmpty);

    p.ready();
    await _until(() => session.state is SamplerReady);
    final outcome = session.tick([Collector.overview]);
    expect(p.requests, ['hw_t 1 overview']);
    p.emitText(p.reply(1, {'overview': 'cpu 1 2 3'}));
    final reply = (await outcome as SamplerReplied).reply;
    expect(reply.seq, 1);
    expect(utf8.decode(reply.section('overview')!.payload), 'cpu 1 2 3');
  });

  test('skips noise before READY and reads frames split into bytes', () async {
    open().start();
    final p = await link.process(0);
    await p.firstWrite;
    final bytes = latin1.encode(
      'Last login: today\r\n\x1e partial \x1e'
      '\x1e${p.nonce} READY HWS/1 2\n',
    );
    for (final b in bytes) {
      p.emit([b]);
    }
    await _until(() => session.state is SamplerReady);

    final outcome = session.tick([Collector.core]);
    for (final b in utf8.encode(p.reply(1, {'core': 'é\n\x1e forged'}))) {
      p.emit([b]);
    }
    final reply = (await outcome as SamplerReplied).reply;
    expect(utf8.decode(reply.section('core')!.payload), 'é\n\x1e forged');
    expect(session.restarts, 0);
  });

  test('keeps one request outstanding and counts overlapping ticks', () async {
    open();
    final p = await ready();
    final first = session.tick([Collector.overview]);
    final second = await session.tick([Collector.core]);
    expect((second as SamplerSkipped).reason, SamplerSkipReason.busy);
    // An on-demand read is skipped the same way; 03 §6.2 counts only
    // overlapping ticks.
    final read = await session.onDemand(Collector.core, const []);
    expect((read as SamplerSkipped).reason, SamplerSkipReason.busy);
    expect(session.skippedTicks, 1);
    expect(p.requests, ['hw_t 1 overview']);

    p.emitText(p.reply(1, {'overview': ''}));
    expect(await first, isA<SamplerReplied>());
    final third = session.tick([Collector.core]);
    expect(p.requests.last, 'hw_t 2 core');
    p.emitText(p.reply(2, {'core': ''}));
    expect(await third, isA<SamplerReplied>());
  });

  test('closes the process on a missed deadline and restarts', () async {
    open(deadlines: _short);
    final p = await ready();
    final gap = await session.tick([Collector.overview]) as SamplerGap;
    expect((gap.seq, gap.reason), (1, SamplerGapReason.deadline));
    expect(p.closeCalls, 1);
    await _until(() => states.whereType<SamplerBackoff>().isNotEmpty);
    expect(
      states.whereType<SamplerBackoff>().single.cause,
      SamplerFault.requestDeadline,
    );

    // The next process gets a fresh nonce, and its request numbers
    // start again (D44).
    final next = await ready(1);
    expect(next.nonce, isNot(p.nonce));
    final outcome = session.tick([Collector.overview]);
    expect(next.requests, ['hw_t 1 overview']);
    next.emitText(next.reply(1, {'overview': ''}));
    expect(await outcome, isA<SamplerReplied>());
    expect(session.restarts, 1);
  });

  test('backs off longer after each failure, not after a reply', () async {
    link.startFailures.addAll([StateError('refused'), StateError('refused')]);
    open();
    final p = await ready();
    expect(delays, [0, 1]);
    expect(
      states.whereType<SamplerBackoff>().map((s) => s.cause),
      everyElement(SamplerFault.startFailed),
    );

    final outcome = session.tick([Collector.overview]);
    p.emitText(p.reply(1, {'overview': ''}));
    await outcome;
    p.end(const RemoteExit(exitCode: 1));
    await link.process(1);
    expect(delays, [0, 1, 0]);
    expect(session.restarts, 3);
  });

  test('ends a request as a gap when the process exits', () async {
    open();
    final p = await ready();
    final outcome = session.tick([Collector.overview]);
    p.end(const RemoteExit(exitCode: 2));
    final gap = await outcome as SamplerGap;
    expect(gap.reason, SamplerGapReason.sessionEnded);
    await _until(() => states.whereType<SamplerBackoff>().isNotEmpty);
    expect(
      states.whereType<SamplerBackoff>().single.cause,
      SamplerFault.exited,
    );
  });

  test('stops instead of restarting once the link has closed', () async {
    open();
    final p = await ready();
    link.state = const SshLinkClosed(SshLinkClosedReason.linkLost);
    p.end();
    await _until(() => session.state is SamplerStopped);
    expect(
      (session.state as SamplerStopped).reason,
      SamplerStopReason.linkClosed,
    );
    final late = await session.tick([Collector.overview]);
    expect((late as SamplerSkipped).reason, SamplerSkipReason.stopped);
    expect(link.processes, hasLength(1));
  });

  test('reports a reply lost to a framing error as a gap', () async {
    open();
    final p = await ready();
    final outcome = session.tick([Collector.overview]);
    // A byte count over the section cap is a framing error; the reader
    // resynchronizes on the E marker (03 §6.2).
    p.emitText(
      '\x1e${p.nonce} B 1 1.0\n\x1e${p.nonce} S overview ok 99999999\n'
      'junk\n\x1e${p.nonce} E 1\n',
    );
    final gap = await outcome as SamplerGap;
    expect((gap.seq, gap.reason), (1, SamplerGapReason.lost));
    expect(session.state, isA<SamplerReady>());
    expect(session.restarts, 0);
  });

  final faults = <String, (SamplerFault, void Function(ScriptedProcess))>{
    'READY does not come in time': (
      SamplerFault.readyDeadline,
      (p) => p.emitText('a login banner, but no READY\n'),
    ),
    'READY names another collector-set version': (
      SamplerFault.versionMismatch,
      (p) => p.ready('1'),
    ),
    'a reply answers no request': (
      SamplerFault.protocolViolation,
      (p) => p
        ..ready()
        ..emitText(p.reply(7, {'overview': ''})),
    ),
  };
  for (final MapEntry(key: name, value: (cause, play)) in faults.entries) {
    test('closes the process and restarts when $name', () async {
      open(deadlines: _short).start();
      final p = await link.process(0);
      await p.firstWrite;
      play(p);
      await link.process(1);
      expect(p.closeCalls, 1);
      expect(states.whereType<SamplerBackoff>().single.cause, cause);
    });
  }

  test('keeps the latest stderr without control characters', () async {
    open();
    final p = await ready();
    p.emitStderr(List.filled(5000, 0x61));
    p.emitStderr(utf8.encode('\x1b[31msh: hw_x: not found\x07\n'));
    await _until(() => session.stderrTail.endsWith('\n'));
    expect(session.stderrTail, endsWith('a[31msh: hw_x: not found\n'));
    expect(session.stderrTail.length, lessThan(kSamplerStderrRingBytes));
  });

  test('close ends the request, closes the process and stops', () async {
    open();
    final p = await ready();
    final outcome = session.tick([Collector.overview]);
    await session.close();
    expect((await outcome as SamplerGap).reason, SamplerGapReason.closed);
    expect(p.closeCalls, 1);
    expect((session.state as SamplerStopped).reason, SamplerStopReason.closed);
    final late = await session.tick([Collector.overview]);
    expect((late as SamplerSkipped).reason, SamplerSkipReason.stopped);
  });

  test('close waits for a channel that opens late and closes it', () async {
    final hold = link.holdNextStart = Completer<void>();
    open().start();
    final closed = session.close();
    hold.complete();
    await closed;
    expect(link.processes.single.closeCalls, 1);
  });

  test('refuses requests the encoder or the sampler kind rejects', () async {
    open();
    final p = await ready();
    // Part-1 collectors take no arguments (03 §8.8).
    await expectLater(
      session.onDemand(Collector.core, ['x']),
      throwsA(isA<HwsRequestError>()),
    );
    await expectLater(
      session.tick([Collector.fs]),
      throwsA(isA<HwsRequestError>()),
    );
    expect(p.requests, isEmpty);

    final outcome = session.onDemand(Collector.core, const []);
    expect(p.requests, ['hw_o 1 core']);
    p.emitText(p.reply(1, {'core': ''}));
    expect(await outcome, isA<SamplerReplied>());
  });

  group('deadlines (D47)', () {
    test('a slow request gets its guarded commands plus a margin', () {
      const d = SamplerDeadlines();
      expect(d.forRequest(SamplerKind.fast, [Collector.core]), _seconds(5));
      expect(d.forRequest(SamplerKind.slow, [Collector.probe]), _seconds(175));
      expect(
        d.forRequest(SamplerKind.slow, [Collector.fs, Collector.identity]),
        _seconds(45),
      );
    });

    test('each bound counts the guarded calls in its fragment', () {
      final call = RegExp(r'\bhw_q?run [a-z]');
      for (final c in Collector.values) {
        final code = collectorFragments[c]!
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('#'));
        final calls = code.fold(0, (n, l) => n + call.allMatches(l).length);
        expect(guardedCommandBound(c), calls, reason: c.name);
      }
    });
  });

  test('the restart delay doubles to a 30 s cap with downward jitter', () {
    expect(samplerRestartDelay(0, _FixedRandom(0)), _seconds(1));
    expect(samplerRestartDelay(3, _FixedRandom(0)), _seconds(8));
    expect(samplerRestartDelay(9, _FixedRandom(0)), _seconds(30));
    expect(samplerRestartDelay(1 << 40, _FixedRandom(0)), _seconds(30));
    expect(
      samplerRestartDelay(0, _FixedRandom(1)),
      const Duration(milliseconds: 700),
    );
  });
}

Duration _seconds(int s) => Duration(seconds: s);

final class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}
