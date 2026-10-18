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

  SamplerSession open({
    SamplerDeadlines deadlines = const SamplerDeadlines(),
    SamplerKind kind = SamplerKind.fast,
  }) {
    session = SamplerSession(
      link: link,
      kind: kind,
      quote: quoteShellWord,
      deadlines: deadlines,
      restartDelay: (failures) {
        delays.add(failures);
        return const Duration(milliseconds: 5);
      },
    );
    session.states.listen(states.add);
    // Per opened session: the deadline and delay tests never open one.
    addTearDown(session.close);
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
    // Only ticks skipped as busy are counted (03 §6.2).
    expect(session.skippedTicks, 0);

    p.ready();
    await _until(() => session.state is SamplerReady);
    final outcome = session.tick([Collector.overview]);
    expect(p.requests, ['hw_t 1 overview']);
    p.emitText(p.reply(1, {'overview': 'cpu 1 2 3'}));
    final reply = (await outcome as SamplerReplied).reply;
    expect(reply.seq, 1);
    expect(utf8.decode(reply.section('overview')!.payload), 'cpu 1 2 3');
  });

  test('starts one process however often start() runs', () async {
    open()
      ..start()
      ..start();
    await link.process(0);
    expect(link.commands, [kSamplerStartCommand]);
  });

  test('skips noise before READY and reads frames split into bytes', () async {
    open().start();
    final p = await link.process(0);
    await p.firstWrite;
    final bytes = latin1.encode(
      'Last login: today\r\n\x1e partial \x1e'
      '\x1e${p.nonce} SELF 4242 4241\n'
      '\x1e${p.nonce} READY HWS/1 $kCollectorSetVersion\n',
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

  test('gives a slow request its derived deadline', () async {
    // fs may start 2 guarded commands: 400 + 2 * 300 ms, past fastRequest
    // and past the margin alone.
    const derived = Duration(milliseconds: 1000);
    open(
      kind: SamplerKind.slow,
      deadlines: const SamplerDeadlines(
        fastRequest: Duration(milliseconds: 100),
        slowMargin: Duration(milliseconds: 400),
        perGuardedCommand: Duration(milliseconds: 300),
      ),
    );
    final p = await ready();
    SamplerOutcome? outcome;
    final sw = Stopwatch()..start();
    unawaited(session.tick([Collector.fs]).then((o) => outcome = o));
    // This timer starts after the request's, so a shorter deadline would
    // have fired first.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect((outcome, p.closeCalls), (null, 0));

    await _until(() => outcome != null);
    final gap = outcome! as SamplerGap;
    expect((gap.seq, gap.reason), (1, SamplerGapReason.deadline));
    expect(p.closeCalls, 1);
    // Timers count whole milliseconds, so the gap may come 1 ms early.
    expect(sw.elapsed, greaterThan(derived - const Duration(milliseconds: 1)));
  });

  test('keeps a healthy sampler running past its deadlines', () async {
    // READY and the reply cancel their deadlines; a timer left running
    // would restart this sampler.
    open(
      deadlines: const SamplerDeadlines(
        ready: Duration(milliseconds: 300),
        fastRequest: Duration(milliseconds: 300),
      ),
    );
    final p = await ready();
    final outcome = session.tick([Collector.overview]);
    p.emitText(p.reply(1, {'overview': ''}));
    expect(await outcome, isA<SamplerReplied>());
    await Future<void>.delayed(const Duration(milliseconds: 750));
    expect(session.state, isA<SamplerReady>());
    expect((session.restarts, p.closeCalls), (0, 0));
  });

  for (final lost in [false, true]) {
    final answer = lost ? 'a lost reply' : 'a reply';
    test('backs off longer after each failure, not after $answer', () async {
      link.startFailures.addAll([StateError('refused'), StateError('refused')]);
      open();
      final p = await ready();
      expect(delays, [0, 1]);
      expect(
        states.whereType<SamplerBackoff>().map((s) => s.cause),
        everyElement(SamplerFault.startFailed),
      );

      // A lost reply still shows the process is alive.
      final outcome = session.tick([Collector.overview]);
      p.emitText(lost ? p.lostReply(1) : p.reply(1, {'overview': ''}));
      await outcome;
      p.end(const RemoteExit(exitCode: 1));
      await link.process(1);
      expect(delays, [0, 1, 0]);
      expect(session.restarts, 3);
    });
  }

  test('backs off longer after a missed deadline despite READY', () async {
    // The count resets on a reply, not on READY, so a sampler that reaches
    // READY and then fails every request still backs off (03 §6.2).
    open(deadlines: _short);
    await ready();
    expect(await session.tick([Collector.overview]), isA<SamplerGap>());
    await ready(1);
    expect(await session.tick([Collector.overview]), isA<SamplerGap>());
    expect(delays, [0, 1]);
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
    expect(session.restarts, 0);
    expect(states.whereType<SamplerBackoff>(), isEmpty);
  });

  test('restarts when a reply answers another request', () async {
    open();
    final p = await ready();
    final outcome = session.tick([Collector.overview]);
    p.emitText(p.reply(2, {'overview': ''}));
    final gap = await outcome as SamplerGap;
    expect(gap.reason, SamplerGapReason.sessionEnded);
    await _until(() => states.whereType<SamplerBackoff>().isNotEmpty);
    expect(
      states.whereType<SamplerBackoff>().single.cause,
      SamplerFault.protocolViolation,
    );
  });

  test('reports a reply lost to a framing error as a gap', () async {
    open();
    final p = await ready();
    final outcome = session.tick([Collector.overview]);
    p.emitText(p.lostReply(1));
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
    'more than 64 KiB arrives before READY': (
      SamplerFault.noReady,
      (p) => p.emitText('x' * (65 * 1024)),
    ),
    'READY names another collector-set version': (
      SamplerFault.versionMismatch,
      (p) => p.ready('1'),
    ),
    'a marker comes out of order': (
      SamplerFault.protocolViolation,
      (p) => p
        ..ready()
        ..emitText('\x1e${p.nonce} E 1\n'),
    ),
    'a reply holds too many sections': (
      SamplerFault.protocolViolation,
      (p) => p
        ..ready()
        ..emitText(
          '\x1e${p.nonce} B 1 1.0\n'
          '${'\x1e${p.nonce} S core ok 0\n\n' * (kMaxReplySections + 1)}',
        ),
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

  test('counts the READY deadline from the opened channel', () async {
    const deadlines = SamplerDeadlines(ready: Duration(milliseconds: 300));
    final hold = link.holdNextStart = Completer<void>();
    open(deadlines: deadlines).start();
    // This timer starts after start(), so a READY deadline counted from
    // start() would fire first.
    await Future<void>.delayed(deadlines.ready * 2);
    hold.complete();
    final p = await link.process(0);
    await p.firstWrite;
    p.ready();
    await _until(() => session.state is SamplerReady);
    expect(session.restarts, 0);
    expect(states.whereType<SamplerBackoff>(), isEmpty);
    expect(link.commands, hasLength(1));
  });

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

  test('close completes once the process has closed', () async {
    open();
    final p = await ready();
    final hold = p.holdClose = Completer<void>();
    var closed = false;
    unawaited(session.close().then((_) => closed = true));
    await pumpEventQueue();
    expect((closed, p.closeCalls), (false, 1));

    hold.complete();
    await session.close();
  });

  test('close waits for a channel that opens late and closes it', () async {
    final hold = link.holdNextStart = Completer<void>();
    open().start();
    var closed = false;
    unawaited(session.close().then((_) => closed = true));
    await pumpEventQueue();
    expect(closed, isFalse);
    expect(link.processes, isEmpty);

    hold.complete();
    await session.close();
    expect(link.processes.single.closeCalls, 1);
  });

  test('refuses requests the encoder or the sampler kind rejects', () async {
    open();
    // Refused before READY too, rather than skipped as not ready.
    await expectLater(
      session.onDemand(Collector.core, ['x']),
      throwsA(isA<HwsRequestError>()),
    );
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
