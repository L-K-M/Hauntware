// The sampling scheduler's policy (03 §6.2, §6.4, D45) on a fake clock:
// real sampler sessions over a link whose processes answer at once, so
// the request lines the samplers write show the cadence. The sessions'
// own request deadlines and restart delays are real timers, since
// SamplerSession has no timer seam, so the tests of misses and restarts
// wait for them in real time, with short figures and a 5 s cap.
import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/sampling/sampler_session.dart';
import 'package:klabautermann_core/src/sampling/sampler_timing.dart';
import 'package:klabautermann_core/src/sampling/sampling_scheduler.dart';
import 'package:klabautermann_core/src/sampling/subscriptions.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show SamplerKind, SectionStatus;
import 'package:seance_core/seance_core.dart' show SshLink, quoteShellWord;
import 'package:test/test.dart';

import '../support/answering_link.dart';
import '../support/fake_clock.dart';

const _s1 = 's1';
const _fast = SamplerKind.fast;
const _slow = SamplerKind.slow;

/// Waits in real time, for what the sessions' own timers do.
Future<void> _until(bool Function() condition) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Matcher _phase(SamplingPhase phase) =>
    isA<SamplingState>().having((e) => e.phase, 'phase', phase);

void main() {
  late FakeClock clock;
  late SamplingSubscriptions subscriptions;
  late Map<String, SshLink> links;
  late List<EngineEvent> events;
  late List<(String, String, SshLink)> hints;
  late List<String> probes;
  late List<SamplerSession> sessions;
  late SamplerDeadlines deadlines;
  late Duration restartDelay;
  late SamplingScheduler scheduler;
  late AnsweringLink link;
  late List<(String, SectionStatus, String)> opsReads;

  SamplingScheduler build({bool readsOps = false}) => SamplingScheduler(
    subscriptions: subscriptions,
    linkFor: (id) => links[id],
    emit: events.add,
    deadPeerHint: (id, l) => hints.add(('hint', id, l)),
    clearDeadPeerHint: (id, l) => hints.add(('clear', id, l)),
    probed: (id, profile) => probes.add(id),
    opsRead: readsOps
        ? (id, section) => opsReads.add((
            id,
            section.status,
            String.fromCharCodes(section.payload),
          ))
        : null,
    openSampler: (l, kind) {
      final session = SamplerSession(
        link: l,
        kind: kind,
        quote: quoteShellWord,
        deadlines: deadlines,
        restartDelay: (_) => restartDelay,
      );
      sessions.add(session);
      return session;
    },
    startTimer: clock.startTimer,
    now: () => clock.now,
    elapsed: () => clock.elapsed,
  );

  setUp(() {
    clock = FakeClock();
    subscriptions = SamplingSubscriptions();
    link = AnsweringLink();
    links = {_s1: link};
    events = [];
    hints = [];
    probes = [];
    sessions = [];
    deadlines = const SamplerDeadlines();
    restartDelay = const Duration(milliseconds: 5);
    opsReads = [];
    scheduler = build();
  });

  tearDown(() => scheduler.close());

  void subscribe(Set<SampleStream> streams, {String id = 'surface'}) {
    final request = Subscribe(
      serverId: _s1,
      subscriptionId: id,
      streams: streams,
    );
    subscriptions.subscribe(request);
    scheduler.subscribed(request);
  }

  void unsubscribe(String id) {
    subscriptions.unsubscribe(Unsubscribe(serverId: _s1, subscriptionId: id));
    scheduler.update(_s1);
  }

  void setLink(SshLink? next) {
    if (next == null) {
      links.remove(_s1);
    } else {
      links[_s1] = next;
    }
    scheduler.update(_s1);
  }

  Future<void> settle() => clock.elapse(Duration.zero);

  /// The samples so far as `<stream>@<seconds>`.
  List<String> samples([SampleStream? only]) => [
    for (final s in events.whereType<Sample>())
      if (only == null || s.stream == only)
        '${s.stream.name}@${s.at.difference(FakeClock.start).inSeconds}',
  ];

  test('the 03 §6.4 periods, in seconds per profile', () {
    final table = {
      for (final stream in SampleStream.values)
        stream.name: [
          for (final profile in CadenceProfile.values)
            samplingPeriod(stream, profile)?.inSeconds,
        ],
    };
    expect(table, {
      'overview': [5, 10, 30],
      'core': [2, 3, 10],
      'fs': [30, 60, 120],
      'identity': [null, null, null],
      'procs': [3, 5, 10],
      'units': [15, 15, 15],
      'failedUnits': [60, 60, 60],
      'timers': [60, 60, null],
      'cron': [60, 60, null],
      'userUnits': [15, 15, 15],
      'userTimers': [60, 60, null],
      'temps': [10, 10, null],
      'gpu': [30, 30, null],
    });
  });

  test('a subscribed server with a ready link probes first, and its fast '
      'sampler waits for the probe while no profile is known', () async {
    link.stalled.add(_slow);
    subscribe({SampleStream.overview});
    expect(events, [_phase(SamplingPhase.sampling)]);
    await clock.elapse(const Duration(seconds: 10));
    expect(link.linesOf(_slow), ['hw_o probe']);
    expect(link.linesOf(_fast), isEmpty);

    final slow = link.running.singleWhere((p) => p.kind == _slow);
    slow.answer(slow.held.single);
    await settle();
    expect(link.linesOf(_fast), ['hw_t overview']);
    expect(events.whereType<HostProfileChanged>(), hasLength(1));
    expect(samples(), ['overview@10']);
  });

  test('CN-17: each probe answer measures the server clock against the '
      'engine\'s', () async {
    final epoch = clock.now.toUtc().millisecondsSinceEpoch ~/ 1000;
    link.probeClock = 'epoch=${epoch + 3600}\noffset=+0000';
    link.stalled.add(_slow);
    subscribe({SampleStream.overview});
    await clock.elapse(const Duration(seconds: 10));
    expect(events.whereType<ServerClock>(), isEmpty);

    final slow = link.running.singleWhere((p) => p.kind == _slow);
    slow.answer(slow.held.single);
    await settle();
    final measured = events.whereType<ServerClock>().single;
    expect(measured.serverId, _s1);
    // The probe's clock read an hour ahead of when it started; its answer
    // came 10 s later, which reads as 10 s less.
    expect(measured.skew.inSeconds, closeTo(3590, 1));
  });

  test('a slow sampler that cannot start does not hold the fast one, and '
      'probes once it is ready', () async {
    // Starts go slow sampler first.
    link.failStarts = 1;
    subscribe({SampleStream.overview});
    await settle();
    expect(link.linesOf(_fast), ['hw_t overview']);

    await _until(() => link.linesOf(_slow).isNotEmpty);
    expect(link.linesOf(_slow), ['hw_o probe']);
  });

  test('a probe that brings no reply releases the fast sampler and goes '
      'out again 15 s later', () async {
    deadlines = const SamplerDeadlines(
      slowMargin: Duration(milliseconds: 50),
      perGuardedCommand: Duration.zero,
    );
    link.stalled.add(_slow);
    subscribe({SampleStream.core});
    await settle();
    final slow = sessions.singleWhere((s) => s.kind == _slow);
    await _until(() => slow.restarts == 1 && slow.state is SamplerReady);
    link.stalled.clear();
    await settle();
    expect(link.linesOf(_fast), ['hw_t core']);

    await clock.elapse(const Duration(seconds: 14));
    expect(link.linesOf(_slow), ['hw_o probe']);
    await clock.elapse(const Duration(seconds: 1));
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_o probe']);
    expect(events.whereType<HostProfileChanged>(), hasLength(1));
  });

  test('each further probe without a reply doubles the wait for the next, '
      'up to 15 minutes', () async {
    link.stalled.add(_slow);
    subscribe({SampleStream.core});
    await settle();
    final slow = sessions.singleWhere((s) => s.kind == _slow);
    for (final (i, wait) in [15, 30, 60, 120, 240, 480, 900, 900].indexed) {
      // Ending the process ends the probe it holds.
      await link.running.singleWhere((p) => p.kind == _slow).close();
      await _until(() => slow.restarts == i + 1 && slow.state is SamplerReady);
      await clock.elapse(Duration(seconds: wait - 1));
      expect(link.linesOf(_slow), hasLength(i + 1));
      await clock.elapse(const Duration(seconds: 1));
      expect(link.linesOf(_slow), hasLength(i + 2));
    }
  });

  test('a new link is probed again, and a profile known from the last one '
      'does not hold the fast sampler', () async {
    subscribe({SampleStream.overview});
    await settle();

    final next = AnsweringLink()..stalled.add(_slow);
    setLink(next);
    await settle();
    expect(next.linesOf(_slow), ['hw_o probe']);
    expect(next.linesOf(_fast), ['hw_t overview']);
    expect(link.running, isEmpty);
  });

  test('every probe answer reaches the capability cache, an unchanged one '
      'included (D59)', () async {
    subscribe({SampleStream.overview});
    await settle();
    setLink(AnsweringLink());
    await settle();

    expect(probes, [_s1, _s1]);
    expect(events.whereType<HostProfileChanged>(), hasLength(1));
  });

  test('ticks the union of the subscriptions at the profile\'s periods, '
      'covered streams riding on their coverer\'s ticks', () async {
    subscribe({SampleStream.overview}, id: 'rail');
    subscribe({SampleStream.core}, id: 'overview');
    subscribe({
      SampleStream.procs,
      SampleStream.units,
      SampleStream.failedUnits,
      SampleStream.fs,
    }, id: 'panels');
    await clock.elapse(const Duration(seconds: 30));

    // `core` every 2 s serves `overview`, which is read about every 5 s.
    expect(link.linesOf(_fast), List.filled(16, 'hw_t core'));
    expect(samples(SampleStream.overview), [
      for (final t in [0, 6, 10, 16, 20, 26, 30]) 'overview@$t',
    ]);
    // Aligned periods share requests; `procs` leads, and `failedUnits`
    // rides on `units`.
    expect(link.linesOf(_slow), [
      'hw_o probe',
      'hw_t procs fs units',
      for (var t = 3; t < 15; t += 3) 'hw_t procs',
      'hw_t procs units',
      for (var t = 18; t < 30; t += 3) 'hw_t procs',
      'hw_t procs fs units',
    ]);
    expect(samples(SampleStream.failedUnits), ['failedUnits@0']);

    // Without `core`, `overview` keeps its own period.
    unsubscribe('overview');
    await clock.elapse(const Duration(seconds: 10));
    expect(link.linesOf(_fast).skip(16), ['hw_t overview', 'hw_t overview']);
    expect(samples(SampleStream.overview).skip(7), [
      'overview@35',
      'overview@40',
    ]);
  });

  test('a new profile takes over at the next aligned tick', () async {
    subscribe({SampleStream.core});
    await clock.elapse(const Duration(seconds: 4));
    subscriptions.profile = CadenceProfile.phone;
    scheduler.profileChanged();
    await clock.elapse(const Duration(seconds: 8));

    expect(samples(), [
      for (final t in [0, 2, 4, 6, 9, 12]) 'core@$t',
    ]);
  });

  test('a server cap samples its server at the slower column, and lifting '
      'it brings the app\'s back at the next aligned tick (SAF-19)', () async {
    subscribe({SampleStream.core});
    await clock.elapse(const Duration(seconds: 4));
    subscriptions.capServer(_s1, CadenceProfile.phone);
    scheduler.profileChanged();
    await clock.elapse(const Duration(seconds: 8));
    subscriptions.capServer(_s1, null);
    scheduler.profileChanged();
    await clock.elapse(const Duration(seconds: 4));

    expect(samples(), [
      for (final t in [0, 2, 4, 6, 9, 12, 14, 16]) 'core@$t',
    ]);
  });

  test('a new profile leaves streams not read yet due at once', () async {
    link.stalled.add(_slow);
    subscribe({SampleStream.core, SampleStream.fs});
    await clock.elapse(const Duration(seconds: 1));
    subscriptions.profile = CadenceProfile.cellularSaver;
    scheduler.profileChanged();

    final slow = link.running.singleWhere((p) => p.kind == _slow);
    link.stalled.clear();
    slow.answer(slow.held.single);
    await settle();
    expect(samples(), unorderedEquals(['core@1', 'fs@1']));
  });

  test(
    'the cellular saver reads timers and cron once per Subscribe naming '
    'them, a repeat included, also one sent while the link is down',
    () async {
      subscriptions.profile = CadenceProfile.cellularSaver;
      scheduler.profileChanged();
      const jobs = {SampleStream.timers, SampleStream.cron};
      subscribe(jobs, id: 'jobs');
      await clock.elapse(const Duration(minutes: 5));
      expect(link.linesOf(_slow), ['hw_o probe', 'hw_t timers cron']);

      subscribe(jobs, id: 'jobs');
      await clock.elapse(const Duration(minutes: 5));
      expect(link.linesOf(_slow).skip(2), ['hw_t timers cron']);

      setLink(null);
      subscribe(jobs, id: 'jobs');
      subscribe(jobs, id: 'jobs');
      await clock.elapse(const Duration(minutes: 1));
      setLink(link);
      await clock.elapse(const Duration(minutes: 5));
      // The link's probe stands; the two resends owe one reading.
      expect(link.linesOf(_slow).skip(3), ['hw_t timers cron']);
    },
  );

  test('identity is read once per link', () async {
    subscribe({SampleStream.identity}, id: 'overview');
    await clock.elapse(const Duration(minutes: 2));
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_t identity']);

    unsubscribe('overview');
    expect(events.last, _phase(SamplingPhase.unsubscribed));
    await settle();
    expect(link.running, isEmpty);
    subscribe({SampleStream.identity}, id: 'system');
    await clock.elapse(const Duration(minutes: 2));
    expect(link.linesOf(_slow), hasLength(2));

    final next = AnsweringLink();
    setLink(next);
    await settle();
    expect(next.linesOf(_slow), ['hw_o probe', 'hw_t identity']);
  });

  test('a refresh reads the subscription\'s streams at once, identity '
      'included, and their periods carry on (PLT-02)', () async {
    subscribe({SampleStream.fs, SampleStream.identity}, id: 'system');
    await clock.elapse(const Duration(seconds: 10));
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_t fs identity']);

    scheduler.refresh(_s1, {SampleStream.fs, SampleStream.identity});
    await settle();
    expect(link.linesOf(_slow).skip(2), ['hw_t fs identity']);
    expect(samples().skip(2), ['fs@10', 'identity@10']);

    await clock.elapse(const Duration(seconds: 20));
    expect(link.linesOf(_slow).skip(3), ['hw_t fs']);
  });

  test('a refresh of a riding stream reads its coverer with it', () async {
    subscribe({SampleStream.units}, id: 'services');
    subscribe({SampleStream.failedUnits}, id: 'health');
    await clock.elapse(const Duration(seconds: 5));

    scheduler.refresh(_s1, {SampleStream.failedUnits});
    await settle();
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_t units', 'hw_t units']);
    expect(samples(SampleStream.failedUnits), [
      'failedUnits@0',
      'failedUnits@5',
    ]);
  });

  test('a refresh a busy sampler holds goes out once the outstanding '
      'request settles, and costs no skipped tick', () async {
    subscribe({SampleStream.procs});
    await settle();
    link.stalled.add(_slow);
    await clock.elapse(const Duration(seconds: 3));
    scheduler.refresh(_s1, {SampleStream.procs});
    await clock.elapse(const Duration(seconds: 1));
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_t procs', 'hw_t procs']);

    link.stalled.clear();
    final process = link.running.singleWhere((p) => p.kind == _slow);
    process.answer(process.held.single);
    await settle();
    expect(link.linesOf(_slow).skip(3), ['hw_t procs']);
    expect(samples().skip(1), ['procs@4', 'procs@4']);
    expect(sessions.singleWhere((s) => s.kind == _slow).skippedTicks, 0);
  });

  test('a refresh while sampling is paused reads nothing then, and '
      'identity again as sampling resumes on the same link', () async {
    subscribe({SampleStream.identity}, id: 'system');
    await settle();
    scheduler.activity = AppActivity.background;
    await settle();

    scheduler
      ..refresh(_s1, {SampleStream.identity})
      // A server the engine does not sample has nothing to refresh.
      ..refresh('s2', {SampleStream.identity});
    await clock.elapse(const Duration(minutes: 1));
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_t identity']);

    scheduler.activity = AppActivity.foreground;
    await settle();
    expect(link.linesOf(_slow).skip(2), ['hw_t identity']);
  });

  test('a tick that would overlap is skipped and counted, never queued, '
      'and leaves no gap', () async {
    subscribe({SampleStream.procs});
    await settle();
    link.stalled.add(_slow);
    await clock.elapse(const Duration(seconds: 9));

    final slow = sessions.singleWhere((s) => s.kind == _slow);
    expect(slow.skippedTicks, 2);
    expect(link.linesOf(_slow), ['hw_o probe', 'hw_t procs', 'hw_t procs']);

    link.stalled.clear();
    final process = link.running.singleWhere((p) => p.kind == _slow);
    process.answer(process.held.single);
    await settle();
    expect(link.linesOf(_slow), hasLength(3));
    await clock.elapse(const Duration(seconds: 3));
    expect(link.linesOf(_slow), hasLength(4));
    expect(events.whereType<Gap>(), isEmpty);
  });

  test('streams subscribed while their sampler is busy are read once the '
      'outstanding request settles, and cost no skipped tick', () async {
    subscribe({SampleStream.procs});
    await settle();
    link.stalled.add(_slow);
    await clock.elapse(const Duration(seconds: 3));
    subscribe({SampleStream.fs, SampleStream.identity}, id: 'system');
    await clock.elapse(const Duration(seconds: 1));

    link.stalled.clear();
    final process = link.running.singleWhere((p) => p.kind == _slow);
    process.answer(process.held.single);
    await settle();
    expect(link.linesOf(_slow), [
      'hw_o probe',
      'hw_t procs',
      'hw_t procs',
      'hw_t fs identity',
    ]);
    expect(samples().skip(2), ['fs@4', 'identity@4']);
    expect(sessions.singleWhere((s) => s.kind == _slow).skippedTicks, 0);
  });

  test(
    'a stream whose tick a busy sampler skipped joins the next tick it '
    'sends, so a period that keeps landing on skips cannot starve it',
    () async {
      subscribe({SampleStream.procs, SampleStream.fs});
      await settle();
      link.stalled.add(_slow);
      final process = link.running.singleWhere((p) => p.kind == _slow);
      // Each request is answered 4 s after it went out, so the ticks at
      // even multiples of 3 s, fs's at 30 s among them, find it busy.
      for (var t = 3; t < 36; t += 6) {
        await clock.elapse(Duration(seconds: t + 4) - clock.elapsed);
        process.answer(process.held.removeLast());
      }
      await settle();

      expect(link.linesOf(_slow), [
        'hw_o probe',
        'hw_t procs fs',
        for (var t = 3; t < 30; t += 6) 'hw_t procs',
        'hw_t procs fs',
      ]);
      expect(samples(SampleStream.fs), ['fs@0', 'fs@37']);
      expect(sessions.singleWhere((s) => s.kind == _slow).skippedTicks, 6);
    },
  );

  test('readings due while a sampler restarts are lost, as gaps, a '
      'covered stream\'s by its coverer\'s ticks, and are read once it is '
      'ready', () async {
    subscribe({SampleStream.overview, SampleStream.core});
    await clock.elapse(const Duration(seconds: 3));
    final fast = sessions.singleWhere((s) => s.kind == _fast);
    link.hangStarts = true;
    await link.running.singleWhere((p) => p.kind == _fast).close();
    await _until(() => fast.restarts == 1 && fast.state is SamplerStarting);
    await clock.elapse(const Duration(seconds: 19));
    link
      ..hangStarts = false
      ..failHungStarts();
    await _until(() => fast.state is SamplerReady);
    await settle();

    expect(samples(SampleStream.core), ['core@0', 'core@2', 'core@22']);
    expect(samples(SampleStream.overview), ['overview@0', 'overview@22']);
    expect(
      events.whereType<Gap>().map(
        (g) => (g.cause, g.streams.single, g.from.second, g.until.second),
      ),
      unorderedEquals([
        (GapCause.readingLost, SampleStream.core, 2, 22),
        (GapCause.readingLost, SampleStream.overview, 0, 22),
      ]),
    );
  });

  test('readings due while the probe holds the slow sampler are lost, as '
      'gaps', () async {
    link.stalled.add(_slow);
    subscribe({SampleStream.procs});
    await settle();
    final slow = sessions.singleWhere((s) => s.kind == _slow);
    // Ends the slow process, and with it the probe it holds.
    Future<void> endProbe(int restarts) async {
      link.stalled.clear();
      await link.running.singleWhere((p) => p.kind == _slow).close();
      await _until(
        () => slow.restarts == restarts && slow.state is SamplerReady,
      );
      await settle();
    }

    // procs had no reading yet, so the first probe loses none.
    await endProbe(1);
    await clock.elapse(const Duration(seconds: 14));
    link.stalled.add(_slow);
    await clock.elapse(const Duration(seconds: 7));
    await endProbe(2);

    expect(link.linesOf(_slow), [
      'hw_o probe',
      ...List.filled(5, 'hw_t procs'),
      'hw_o probe',
      'hw_t procs',
    ]);
    expect(samples(), [
      for (final t in [0, 3, 6, 9, 12, 21]) 'procs@$t',
    ]);
    final gap = events.whereType<Gap>().single;
    expect(
      (gap.cause, gap.streams.single, gap.from.second, gap.until.second),
      (GapCause.readingLost, SampleStream.procs, 12, 21),
    );
  });

  test('the background stops the samplers at once, and the foreground '
      'resumes them on the same link without a probe', () async {
    subscribe({SampleStream.core});
    await clock.elapse(const Duration(seconds: 4));

    scheduler.activity = AppActivity.background;
    expect(events.last, _phase(SamplingPhase.pausedInBackground));
    await settle();
    expect(link.running, isEmpty);
    await clock.elapse(const Duration(minutes: 1));
    expect(link.linesOf(_fast), hasLength(3));

    scheduler.activity = AppActivity.foreground;
    await settle();
    expect(link.running, hasLength(2));
    expect(link.linesOf(_slow), ['hw_o probe']);
    expect(samples().skip(3), ['core@64']);
    final gap = events.whereType<Gap>().single;
    expect(
      (gap.cause, gap.from, gap.until),
      (
        GapCause.background,
        FakeClock.start.add(const Duration(seconds: 4)),
        clock.now,
      ),
    );
  });

  test('a missed fast deadline is a dead-peer hint from the restarted '
      'sampler\'s start, so its restart delay, which grows with each '
      'failure, takes nothing from the grace, and READY clears it', () async {
    deadlines = const SamplerDeadlines(fastRequest: Duration(milliseconds: 50));
    restartDelay = const Duration(milliseconds: 300);
    subscribe({SampleStream.core});
    await settle();
    link.stalled.add(_fast);
    await clock.elapse(const Duration(seconds: 2));

    final fast = sessions.singleWhere((s) => s.kind == _fast);
    await _until(() => fast.state is SamplerBackoff);
    expect(hints, isEmpty);
    await _until(() => hints.length == 2);
    expect(hints, [('hint', _s1, link), ('clear', _s1, link)]);
  });

  test('a dead-peer hint stays while the peer is silent, and is cleared '
      'when sampling stops', () async {
    deadlines = const SamplerDeadlines(fastRequest: Duration(milliseconds: 50));
    subscribe({SampleStream.core});
    await settle();
    link
      ..stalled.add(_fast)
      ..hangStarts = true;
    await clock.elapse(const Duration(seconds: 2));
    await _until(() => hints.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(hints, [('hint', _s1, link)]);

    unsubscribe('surface');
    expect(hints.last, ('clear', _s1, link));
    link.failHungStarts();
  });

  test('a lost link stops the samplers until the next one, and a server '
      'leaving the fleet stops them without an event', () async {
    subscribe({SampleStream.core, SampleStream.fs});
    await settle();
    expect(link.running, hasLength(2));

    setLink(null);
    expect(events.last, _phase(SamplingPhase.waitingForLink));
    await settle();
    expect(link.running, isEmpty);

    final next = AnsweringLink();
    clock.now = clock.now.add(const Duration(seconds: 7));
    setLink(next);
    await settle();
    expect(next.linesOf(_slow).first, 'hw_o probe');
    // One per reply that resumed a stream.
    expect(
      events.whereType<Gap>().map((g) => (g.cause, g.streams.single)),
      unorderedEquals([
        (GapCause.disconnected, SampleStream.core),
        (GapCause.disconnected, SampleStream.fs),
      ]),
    );

    final seen = events.length;
    subscriptions.fleet = {};
    scheduler.retain({});
    await clock.elapse(const Duration(minutes: 1));
    expect(next.running, isEmpty);
    expect(events, hasLength(seen));
  });

  group('ops (03 §7.17)', () {
    setUp(() async {
      await scheduler.close();
      scheduler = build(readsOps: true);
    });

    test('a new link reads ops once, right after the probe, and hands '
        'the section on', () async {
      link.onDemandPayloads['ops'] = 'dir user absent 0 /h/ops';
      subscribe({SampleStream.fs});
      await settle();
      expect(link.linesOf(_slow).take(3), [
        'hw_o probe',
        'hw_o ops',
        'hw_t fs',
      ]);
      expect(opsReads, [(_s1, SectionStatus.ok, 'dir user absent 0 /h/ops')]);

      await clock.elapse(const Duration(minutes: 2));
      expect(link.linesOf(_slow).where((l) => l == 'hw_o ops'), hasLength(1));

      final next = AnsweringLink();
      setLink(next);
      await settle();
      expect(next.linesOf(_slow).take(2), ['hw_o probe', 'hw_o ops']);
      expect(opsReads, hasLength(2));
    });

    test('readOps reads again once the slow sampler is free; a read '
        'without a reply goes out again 15 s later', () async {
      subscribe({SampleStream.fs});
      await settle();
      scheduler.readOps(_s1);
      await settle();
      expect(link.linesOf(_slow).where((l) => l == 'hw_o ops'), hasLength(2));

      link.stalled.add(_slow);
      scheduler.readOps(_s1);
      await settle();
      final stalled = link.running.singleWhere((p) => p.kind == _slow);
      expect(stalled.held.single, endsWith(' ops'));
      await stalled.close();
      link.stalled.clear();
      final slow = sessions.singleWhere((s) => s.kind == _slow);
      await _until(() => slow.restarts == 1 && slow.state is SamplerReady);
      await settle();
      // The held read is the third; no other goes out at once.
      expect(link.linesOf(_slow).where((l) => l == 'hw_o ops'), hasLength(3));

      await clock.elapse(const Duration(seconds: 15));
      expect(link.linesOf(_slow).where((l) => l == 'hw_o ops'), hasLength(4));
      expect(opsReads, hasLength(3));
    });

    test('without a listener no ops read goes out', () async {
      await scheduler.close();
      scheduler = build();
      subscribe({SampleStream.fs});
      await settle();
      scheduler.readOps(_s1);
      await settle();
      expect(link.linesOf(_slow), isNot(contains('hw_o ops')));
    });
  });

  group('diagnostic bundle (CN-18)', () {
    List<String> wireNames(SamplerKind kind) => [
      for (final c in kDiagnosticCollectors)
        if (c.sampler == kind) c.wireName,
    ];

    test('a server not sampled has none', () async {
      expect(await scheduler.readDiagnostics(_s1), isNull);
    });

    test('reads the probe on demand and one tick per sampler after the '
        "regular probe; a request meanwhile shares the answer", () async {
      link.probeClock = 'epoch=1';
      subscribe({SampleStream.fs});
      await settle();
      final first = scheduler.readDiagnostics(_s1);
      final second = scheduler.readDiagnostics(_s1);
      await settle();

      final bundle = (await first)!;
      expect(await second, same(bundle));
      expect(
        link.linesOf(_fast),
        contains('hw_t ${wireNames(_fast).join(' ')}'),
      );
      expect(link.linesOf(_slow).where((l) => l == 'hw_o probe'), hasLength(2));
      expect(
        link.linesOf(_slow),
        contains('hw_t ${wireNames(_slow).join(' ')}'),
      );
      expect(wireNames(_slow), isNot(contains('ops')));
      expect(
        [for (final s in bundle.sections) s.collector],
        ['probe_clock', ...wireNames(_fast), ...wireNames(_slow)],
      );
      expect(bundle.sections.first.text, 'epoch=1');
      expect(bundle.sections.first.status, 'ok');
      expect(bundle.missing, isEmpty);
    });

    test('a collector the reply leaves out is missing, as is the probe '
        'when no area comes back', () async {
      subscribe({SampleStream.fs});
      await settle();
      final skipped = wireNames(_fast).first;
      link.omitted.add(skipped);
      final bundle = (await scheduler.readDiagnostics(_s1))!;

      expect(
        [for (final s in bundle.sections) s.collector],
        [...wireNames(_fast).skip(1), ...wireNames(_slow)],
      );
      expect(bundle.missing, ['probe', skipped]);
    });

    test('a sampler that does not answer leaves its collectors missing '
        'after the wait; a server that stops answers none', () async {
      subscribe({SampleStream.fs});
      await settle();
      link.stalled.add(_slow);
      final waited = scheduler.readDiagnostics(_s1);
      await settle();
      await clock.elapse(kDiagnosticsWait);
      final bundle = (await waited)!;
      expect([for (final s in bundle.sections) s.collector], wireNames(_fast));
      expect(bundle.missing, ['probe', ...wireNames(_slow)]);

      final stopped = scheduler.readDiagnostics(_s1);
      await settle();
      subscriptions.fleet = {};
      scheduler.retain({});
      expect(await stopped, isNull);
    });
  });

  group('lending the slow sampler (M4 E13, plan M6)', () {
    test('a server not sampled has nothing to lend', () async {
      expect(scheduler.samplerSessions(_s1), 0);
      expect(await scheduler.yieldSlowSampler(_s1), isNull);
    });

    test('the slow sampler stops for the step and starts again with its '
        'handshake, while the fast one samples on', () async {
      subscribe({SampleStream.core, SampleStream.units});
      await clock.elapse(const Duration(seconds: 4));
      expect(scheduler.samplerSessions(_s1), 2);
      final opened = sessions.length;

      final giveBack = await scheduler.yieldSlowSampler(_s1);
      expect(giveBack, isNotNull);
      expect(scheduler.samplerSessions(_s1), 1);
      expect(link.running.map((p) => p.kind), [_fast]);
      final fastLines = link.linesOf(_fast).length;
      final slowLines = link.linesOf(_slow).length;
      await clock.elapse(const Duration(seconds: 30));
      expect(link.linesOf(_fast).length, greaterThan(fastLines));
      expect(link.linesOf(_slow), hasLength(slowLines), reason: 'lent');

      giveBack!();
      await _until(() => sessions.length > opened);
      final restarted = sessions.last;
      expect(restarted.kind, _slow);
      await _until(() => restarted.state is SamplerReady);
      expect(scheduler.samplerSessions(_s1), 2);
      expect(link.running.map((p) => p.kind), unorderedEquals([_fast, _slow]));
      // Its streams came due while it was lent: the next tick reads them,
      // and the link probed already, so no probe goes out again.
      await clock.elapse(const Duration(seconds: 15));
      expect(link.linesOf(_slow).length, greaterThan(slowLines));
      expect(
        link.linesOf(_slow).where((l) => l.contains('probe')),
        hasLength(1),
      );

      // Giving it back twice starts nothing more.
      giveBack();
      await settle();
      expect(sessions.last, same(restarted));
    });

    test('steps that overlap share one lending, and the sampler starts '
        'after the last', () async {
      subscribe({SampleStream.core});
      await clock.elapse(const Duration(seconds: 4));
      final opened = sessions.length;

      final first = await scheduler.yieldSlowSampler(_s1);
      final second = await scheduler.yieldSlowSampler(_s1);
      expect(scheduler.samplerSessions(_s1), 1);
      first!();
      await settle();
      expect(sessions, hasLength(opened), reason: 'still lent');
      expect(link.running.map((p) => p.kind), [_fast]);

      second!();
      await _until(() => sessions.length == opened + 1);
      expect(sessions.last.kind, _slow);
    });

    test('a lending that ends after the link went starts no sampler on '
        'it', () async {
      subscribe({SampleStream.core});
      await clock.elapse(const Duration(seconds: 4));
      final giveBack = await scheduler.yieldSlowSampler(_s1);
      setLink(null);
      await settle();
      final opened = sessions.length;

      giveBack!();
      await settle();
      expect(sessions, hasLength(opened));
      expect(scheduler.samplerSessions(_s1), 0);
    });
  });
}
