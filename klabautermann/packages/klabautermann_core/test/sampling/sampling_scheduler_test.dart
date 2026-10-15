// The sampling scheduler's policy (03 §6.2, §6.4, D45) on a fake clock:
// real sampler sessions over a link whose processes answer at once, so
// the request lines the samplers write show the cadence.
import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/sampling/sampler_session.dart';
import 'package:klabautermann_core/src/sampling/sampler_timing.dart';
import 'package:klabautermann_core/src/sampling/sampling_scheduler.dart';
import 'package:klabautermann_core/src/sampling/subscriptions.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show SamplerKind;
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
  late List<SamplerSession> sessions;
  late SamplerDeadlines deadlines;
  late SamplingScheduler scheduler;
  late AnsweringLink link;

  setUp(() {
    clock = FakeClock();
    subscriptions = SamplingSubscriptions();
    link = AnsweringLink();
    links = {_s1: link};
    events = [];
    hints = [];
    sessions = [];
    deadlines = const SamplerDeadlines();
    scheduler = SamplingScheduler(
      subscriptions: subscriptions,
      linkFor: (id) => links[id],
      emit: events.add,
      deadPeerHint: (id, l) => hints.add(('hint', id, l)),
      clearDeadPeerHint: (id, l) => hints.add(('clear', id, l)),
      openSampler: (l, kind) {
        final session = SamplerSession(
          link: l,
          kind: kind,
          quote: quoteShellWord,
          deadlines: deadlines,
          restartDelay: (_) => const Duration(milliseconds: 5),
        );
        sessions.add(session);
        return session;
      },
      startTimer: clock.startTimer,
      now: () => clock.now,
      elapsed: () => clock.elapsed,
    );
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

  test('a missed fast deadline is a dead-peer hint, cleared by the '
      'restarted sampler\'s READY', () async {
    deadlines = const SamplerDeadlines(fastRequest: Duration(milliseconds: 50));
    subscribe({SampleStream.core});
    await settle();
    link.stalled.add(_fast);
    await clock.elapse(const Duration(seconds: 2));

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
}
