/// The engine's sampling scheduler (03 §6.2, §6.4, D45): a fast and a
/// slow [SamplerSession] on each subscribed server's ready link, ticking
/// the union of the server's subscribed streams at the cadence profile's
/// periods, with every outcome fed through the server's
/// [ServerSamplePipeline] and its events sent on.
///
/// A server samples while a stream is subscribed, its link is ready and
/// the app is in the foreground; leaving that state closes both samplers
/// and their timers, and returning starts new ones:
///
/// ```text
///   link ready ─▶ slow: probe (once per link), `ops` (once per link,
///              │        when the engine follows operations), then ticks
///              └▶ fast: ticks, once the probe settles or a profile is known
/// ```
library;

import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart'
    show Collector, HostProfile, HwsSection, SamplerKind;
import 'package:seance_core/seance_core.dart' show SshLink, quoteShellWord;

import '../engine/protocol.dart';
import 'sample_pipeline.dart';
import 'sample_results.dart' show sampleStreamCollector;
import 'sampler_session.dart';
import 'subscriptions.dart';

/// [stream]'s 03 §6.4 period under [profile]; null for `identity`, read
/// once per link, and for `timers` and `cron` under the cellular saver,
/// read once per [Subscribe] naming them.
Duration? samplingPeriod(SampleStream stream, CadenceProfile profile) {
  int? seconds(int desktop, int phone, int? cellularSaver) => switch (profile) {
    CadenceProfile.desktop => desktop,
    CadenceProfile.phone => phone,
    CadenceProfile.cellularSaver => cellularSaver,
  };
  final period = switch (stream) {
    SampleStream.overview => seconds(5, 10, 30),
    SampleStream.core => seconds(2, 3, 10),
    SampleStream.fs => seconds(30, 60, 120),
    SampleStream.procs => seconds(3, 5, 10),
    SampleStream.units => 15,
    SampleStream.failedUnits => 60,
    SampleStream.timers || SampleStream.cron => seconds(60, 60, null),
    SampleStream.identity => null,
  };
  return period == null ? null : Duration(seconds: period);
}

/// How long a read owed once (`identity`, an on-demand stream, the
/// probe) waits before it is tried again when its request brought no
/// reply [E]: the `units` period, the shortest slow period every profile
/// shares, so a lost reading costs no more than a missed `units` tick.
const _owedReadRetry = Duration(seconds: 15);

/// The longest wait before the next probe [E]. Each probe that brings no
/// reply doubles the wait from [_owedReadRetry]: one that hangs holds the
/// slow sampler for its whole deadline, 175 s, and its streams lose their
/// readings meanwhile, which the cap bounds to about 16 % of the time.
const _maxProbeRetry = Duration(minutes: 15);

/// The stream whose collector also serves [stream]'s, or null: a `core`
/// reply serves `overview` (03 §6.4), and one `units` read serves both
/// unit streams. A covered stream rides on its coverer's ticks while the
/// coverer is subscribed instead of costing requests of its own.
SampleStream? _coverer(SampleStream stream) => switch (stream) {
  SampleStream.overview => SampleStream.core,
  SampleStream.failedUnits => SampleStream.units,
  _ => null,
};

SamplerKind _kindOf(SampleStream stream) =>
    sampleStreamCollector(stream).sampler;

/// Opens one sampler session on a link; tests pass short deadlines.
typedef SamplerOpener = SamplerSession Function(SshLink link, SamplerKind kind);

SamplerSession _defaultSamplerOpener(SshLink link, SamplerKind kind) =>
    SamplerSession(link: link, kind: kind, quote: quoteShellWord);

DateTime _utcNow() => DateTime.now().toUtc();

void _ignoreProbe(String serverId, HostProfile profile) {}

Duration Function() _monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}

/// Runs the samplers of every subscribed server by 03 §6.4's scheduling
/// rules. The engine isolate owns it, records requests in the
/// [SamplingSubscriptions] it shares, and tells it what changed:
/// [subscribed] and [update] after a subscription or a link changed,
/// [refresh] for a subscription read at once, [profileChanged],
/// [activity], and [retain] for the fleet. A tick that
/// would overlap its sampler's outstanding request is skipped and
/// counted by the session ([SamplerSession.skippedTicks]), never queued;
/// one due while its sampler restarts or waits for the probe is a
/// reading lost, a gap. A missed fast deadline makes the restarted fast
/// sampler's start a dead-peer hint to the link supervisor until the
/// link next shows a sign of life.
final class SamplingScheduler {
  /// [linkFor] gives a server's ready link, null while it has none.
  /// [deadPeerHint] and [clearDeadPeerHint] reach the link supervisor.
  /// [probed] hears every probe answer, changed or not, for the
  /// capability cache (D59). [opsRead] hears each `ops` section (03
  /// §7.17); without it the scheduler never reads `ops`.
  /// [openSampler], [startTimer], [now] (the clock events carry) and
  /// [elapsed] (a monotonic clock, which due times follow so that a
  /// changed wall clock cannot stall sampling) are test seams.
  SamplingScheduler({
    required this._subscriptions,
    required this._linkFor,
    required this._emit,
    required this._deadPeerHint,
    required this._clearDeadPeerHint,
    this._probed = _ignoreProbe,
    this._opsRead,
    this._openSampler = _defaultSamplerOpener,
    this._startTimer = Timer.new,
    this._now = _utcNow,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _monotonicClock();

  final SamplingSubscriptions _subscriptions;
  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final void Function(String serverId, SshLink link) _deadPeerHint;
  final void Function(String serverId, SshLink link) _clearDeadPeerHint;
  final void Function(String serverId, HostProfile profile) _probed;
  final void Function(String serverId, HwsSection section)? _opsRead;
  final SamplerOpener _openSampler;
  final Timer Function(Duration duration, void Function() callback) _startTimer;
  final DateTime Function() _now;
  final Duration Function() _elapsed;

  /// One per engine, so a server's [Sample.seq] keeps rising (D44).
  final _sequence = SampleSequence();
  final Map<String, _Server> _servers = {};

  /// The PIDs of [serverId]'s running sampler shells and their parents,
  /// the sshd processes serving them (03 §8.6, E07): acting on one would
  /// end this session's sampling. A parent outside the shells' PID
  /// namespace reads 0 and is left out.
  Set<int> samplerPids(String serverId) {
    final run = _servers[serverId]?.run;
    if (run == null) return const {};
    return {
      for (final sampler in [run.fast, run.slow])
        if (sampler.session.self case (:final pid, :final parentPid)) ...[
          pid,
          if (parentPid > 0) parentPid,
        ],
    };
  }

  final Set<Future<void>> _closing = {};
  AppActivity _activity = AppActivity.foreground;

  /// Follows [request], which the shared subscriptions have recorded. A
  /// stream the cellular saver reads on demand is owed one reading per
  /// [Subscribe] naming it, a repeat included (03 §10.1).
  void subscribed(Subscribe request) {
    final serverId = request.serverId;
    if (_subscriptions.profile == CadenceProfile.cellularSaver) {
      final owed = request.streams.where(
        (s) => _onDemand(s) && _subscriptions.streamsFor(serverId).contains(s),
      );
      if (owed.isNotEmpty) _server(serverId).owed.addAll(owed);
    }
    update(serverId);
  }

  /// Follows a [RefreshSubscription] of [streams], the refreshed
  /// subscription's: each is read once more, at once while the server
  /// samples, and as its sampling resumes otherwise. Such a reading is
  /// held, as a first reading is, while its sampler is busy, restarts or
  /// waits for the probe, rather than lost, and a stream that rides on
  /// its coverer's ticks is read with its coverer.
  void refresh(String serverId, Set<SampleStream> streams) {
    final server = _servers[serverId];
    if (server == null) return;

    // A new run reads every periodic stream at once, but not these.
    if (streams.contains(SampleStream.identity)) server.identityReadOn = null;
    server.owed.addAll(streams.where(_onDemand));
    final run = server.run;
    if (run == null) return;

    final now = _elapsed();
    for (final stream in streams.where(run.streams.contains)) {
      for (final read in [stream, if (_rides(run, stream)) _coverer(stream)!]) {
        run.due[read] = now;
        run.unread.add(read);
      }
    }
    _schedule(server, run, run.fast);
    _schedule(server, run, run.slow);
  }

  /// Reads [serverId]'s `ops` once more (03 §7.17): at once while the
  /// server samples and its slow sampler is free, otherwise as soon as
  /// it is. A server that does not sample reads them when it next does.
  void readOps(String serverId) {
    if (_opsRead == null) return;
    final server = _servers[serverId];
    if (server == null) return;

    server.opsOwed = true;
    if (server.run case final run?) _schedule(server, run, run.slow);
  }

  /// Re-reads [serverId]'s subscriptions and link, starting or stopping
  /// its samplers.
  void update(String serverId) {
    final streams = _subscriptions.streamsFor(serverId);
    if (streams.isEmpty && !_servers.containsKey(serverId)) return;

    final server = _server(serverId);
    final link = _linkFor(serverId);
    _emitAll(
      server.pipeline.updateConditions(
        streams: streams,
        linkReady: link != null,
        activity: _activity,
        at: _now(),
      ),
    );
    server.owed.retainAll(streams);

    if (streams.isEmpty ||
        link == null ||
        _activity == AppActivity.background) {
      _stop(server);
      return;
    }
    if (!identical(server.run?.link, link)) _stop(server);
    final run = server.run ??= _start(server, link);
    _follow(server, run, streams);
  }

  /// Follows a new [SamplingSubscriptions.profile]: periods change at
  /// the next aligned tick, a stream not read yet stays due at once, and
  /// owed on-demand reads lapse once the profile reads those streams on
  /// its own.
  void profileChanged() {
    final profile = _subscriptions.profile;
    for (final server in _servers.values) {
      if (profile != CadenceProfile.cellularSaver) server.owed.clear();
      final run = server.run;
      if (run == null) continue;

      final now = _elapsed();
      run.missed.clear();
      for (final stream in run.streams) {
        final period = samplingPeriod(stream, profile);
        if (period != null) {
          if (!run.due.containsKey(stream)) {
            run.unread.add(stream);
            run.due[stream] = now;
          } else if (!run.unread.contains(stream)) {
            run.due[stream] = _aligned(run.epoch, period, now);
          }
        } else if (_onDemand(stream) && !server.owed.contains(stream)) {
          run.due.remove(stream);
        }
      }
      _schedule(server, run, run.fast);
      _schedule(server, run, run.slow);
    }
  }

  /// Follows the app's visibility (03 §6.4, D34): the background stops
  /// every sampler, and the foreground starts them again.
  set activity(AppActivity activity) {
    if (activity == _activity) return;
    _activity = activity;
    for (final serverId in _servers.keys.toList()) {
      update(serverId);
    }
  }

  /// Forgets every server outside [fleet] without an event, since the
  /// app drops a server's state with its entry (03 §5.1).
  void retain(Set<String> fleet) {
    _servers.removeWhere((serverId, server) {
      if (fleet.contains(serverId)) return false;
      _stop(server);
      return true;
    });
  }

  /// Stops every sampler; completes once their processes have closed.
  Future<void> close() async {
    for (final server in _servers.values) {
      _stop(server);
    }
    _servers.clear();
    while (_closing.isNotEmpty) {
      await Future.wait(_closing.toList());
    }
  }

  _Server _server(String serverId) => _servers.putIfAbsent(
    serverId,
    () =>
        _Server(ServerSamplePipeline(serverId: serverId, sequence: _sequence)),
  );

  bool _onDemand(SampleStream stream) =>
      stream != SampleStream.identity &&
      samplingPeriod(stream, _subscriptions.profile) == null;

  // -- runs -----------------------------------------------------------

  _Run _start(_Server server, SshLink link) {
    final now = _elapsed();
    final run = _Run(
      link,
      now,
      holdFast: server.pipeline.profile == null,
      probeAt: identical(server.probedOn, link) ? null : now,
    );
    // `ops` is read once on each link, as `identity` is (03 §6.4).
    if (_opsRead != null && !identical(server.opsReadOn, link)) {
      server.opsOwed = true;
    }
    // The slow sampler first: its first request is the probe (03 §6.1).
    run.slow = _open(server, run, SamplerKind.slow);
    run.fast = _open(server, run, SamplerKind.fast);
    return run;
  }

  _Sampler _open(_Server server, _Run run, SamplerKind kind) {
    final sampler = _Sampler(kind, _openSampler(run.link, kind));
    sampler.states = sampler.session.states.listen(
      (state) => _onSamplerState(server, run, sampler, state),
    );
    sampler.session.start();
    return sampler;
  }

  void _stop(_Server server) {
    final run = server.run;
    if (run == null) return;

    server.run = null;
    // Nothing watches the link's samplers now, so its liveness goes back
    // to the link's own ping.
    if (run.hinted) _clearDeadPeerHint(server.pipeline.serverId, run.link);
    for (final sampler in [run.fast, run.slow]) {
      sampler.timer?.cancel();
      unawaited(sampler.states?.cancel());
      final closing = sampler.session.close();
      _closing.add(closing);
      unawaited(closing.whenComplete(() => _closing.remove(closing)));
    }
  }

  /// Records [streams] as [run]'s subscribed streams: a stream new to
  /// it is due at once, if it is read at all.
  void _follow(_Server server, _Run run, Set<SampleStream> streams) {
    final now = _elapsed();
    run.streams = streams;
    run.due.removeWhere((stream, _) => !streams.contains(stream));
    run.unread.retainAll(streams);
    run.missed.retainAll(streams);
    for (final stream in streams) {
      if (run.due.containsKey(stream)) continue;
      final read = switch (stream) {
        SampleStream.identity => !identical(server.identityReadOn, run.link),
        _ when _onDemand(stream) => server.owed.contains(stream),
        _ => true,
      };
      if (read) {
        run.due[stream] = now;
        run.unread.add(stream);
      }
    }
    _schedule(server, run, run.fast);
    _schedule(server, run, run.slow);
  }

  void _onSamplerState(
    _Server server,
    _Run run,
    _Sampler sampler,
    SamplerState state,
  ) {
    if (!identical(server.run, run)) return;

    switch (state) {
      case SamplerReady():
        _answered(server, run);
      case SamplerBackoff() || SamplerStopped():
        // A slow sampler that cannot answer soon does not hold the fast
        // one back; the probe follows when it is ready.
        if (sampler.kind == SamplerKind.slow && run.holdFast) {
          run.holdFast = false;
          _schedule(server, run, run.fast);
        }
      case SamplerStarting()
          when sampler.kind == SamplerKind.fast && run.deadlineMissed:
        // The hint's grace covers this start, not the restart delay
        // before it, which grows with each failure (6.2).
        run.deadlineMissed = false;
        run.hinted = true;
        _deadPeerHint(server.pipeline.serverId, run.link);
      case SamplerIdle() || SamplerStarting():
        break;
    }
    _schedule(server, run, sampler);
  }

  /// Sends the probe, the first request of a run's ready slow sampler
  /// unless the link already answered one (03 §6.1). Until it settles
  /// the slow sampler sends nothing else and, for a server whose profile
  /// is not known yet, the fast one waits too, so the first readings
  /// already withhold what a container host's `/proc` would supply
  /// (D50). A probe that brings no reply goes out again after
  /// [_owedReadRetry], as a read owed once does, and each later one after
  /// twice the last wait, up to [_maxProbeRetry]; a reply that framing
  /// loses every time therefore cannot turn into a loop.
  void _probe(_Server server, _Run run) {
    run.probing = true;
    unawaited(
      run.slow.session.onDemand(Collector.probe, const []).then((outcome) {
        if (!identical(server.run, run)) return;

        run.probing = false;
        run.holdFast = false;
        if (outcome is SamplerReplied) {
          server.probedOn = run.link;
          run.probeAt = null;
          _answered(server, run);
        } else {
          run.probeAt = _elapsed() + run.probeRetry;
          final doubled = run.probeRetry * 2;
          run.probeRetry = doubled < _maxProbeRetry ? doubled : _maxProbeRetry;
        }
        _emitAll(server.pipeline.addProbe(outcome));
        if (outcome is SamplerReplied) {
          _probed(server.pipeline.serverId, server.pipeline.profile!);
        }
        _schedule(server, run, run.slow);
        _schedule(server, run, run.fast);
      }),
    );
    _schedule(server, run, run.slow);
  }

  /// Sends the `ops` read the server owes on [run]'s free slow sampler,
  /// which counts as busy until it settles. A read that brings no `ops`
  /// section stays owed and goes out again after [_owedReadRetry].
  void _readOps(_Server server, _Run run) {
    final sampler = run.slow;
    sampler.busy = true;
    unawaited(
      sampler.session.onDemand(Collector.ops, const []).then((outcome) {
        sampler.busy = false;
        if (!identical(server.run, run)) return;

        final section = outcome is SamplerReplied
            ? outcome.reply.section(Collector.ops.wireName)
            : null;
        if (outcome
            case SamplerReplied() ||
                SamplerGap(reason: SamplerGapReason.lost)) {
          _answered(server, run);
        }
        if (section == null) {
          run.opsAt = _elapsed() + _owedReadRetry;
        } else {
          server.opsOwed = false;
          server.opsReadOn = run.link;
          run.opsAt = null;
          _opsRead!(server.pipeline.serverId, section);
        }
        _schedule(server, run, sampler);
      }),
    );
    _schedule(server, run, sampler);
  }

  // -- ticks ----------------------------------------------------------

  /// Arms [sampler]'s timer for its earliest due stream that drives
  /// ticks; a free slow sampler owing the probe sends it first. A
  /// sampler that cannot tick arms it for the streams it would lose. The
  /// session's state is read here rather than from its
  /// [SamplerSession.states], which reports a change a turn later.
  void _schedule(_Server server, _Run run, _Sampler sampler) {
    sampler.timer?.cancel();
    sampler.timer = null;
    // A stopped session's link closed; the conditions say why.
    if (sampler.session.state is SamplerStopped) return;
    if (!_canTick(run, sampler)) {
      final next = _next(run, sampler, (stream) => _losable(run, stream));
      if (next != null) _arm(sampler, next, () => _lose(server, run, sampler));
      return;
    }
    if (sampler.lost.isNotEmpty) {
      final now = _elapsed();
      for (final stream in sampler.lost) {
        if (run.due.containsKey(stream)) run.due[stream] = now;
      }
      sampler.lost.clear();
    }

    final probeAt = sampler.kind == SamplerKind.slow && !sampler.busy
        ? run.probeAt
        : null;
    if (probeAt != null && probeAt <= _elapsed()) {
      _probe(server, run);
      return;
    }
    // `ops` follows the probe, so the first read already knows the host.
    final opsAt =
        sampler.kind == SamplerKind.slow &&
            !sampler.busy &&
            run.probeAt == null &&
            server.opsOwed
        ? run.opsAt ?? Duration.zero
        : null;
    if (opsAt != null && opsAt <= _elapsed()) {
      _readOps(server, run);
      return;
    }

    final next = _next(run, sampler, (s) => !_held(run, sampler, s));
    final wake = switch ((probeAt, opsAt)) {
      (final p?, final o?) => p < o ? p : o,
      (final p, final o) => p ?? o,
    };
    if (wake != null && (next == null || wake <= next)) {
      _arm(sampler, wake, () => _schedule(server, run, sampler));
    } else if (next != null) {
      _arm(sampler, next, () => _tick(server, run, sampler));
    }
  }

  /// Whether [sampler] may send a tick: it is ready, and neither waiting
  /// for the probe (the fast one) nor sending it (the slow one).
  static bool _canTick(_Run run, _Sampler sampler) =>
      sampler.session.state is SamplerReady &&
      switch (sampler.kind) {
        SamplerKind.fast => !run.holdFast,
        SamplerKind.slow => !run.probing,
      };

  /// The earliest due time of [sampler]'s streams that drive ticks and
  /// pass [test].
  static Duration? _next(
    _Run run,
    _Sampler sampler,
    bool Function(SampleStream stream) test,
  ) {
    Duration? next;
    for (final MapEntry(key: stream, value: due) in run.due.entries) {
      if (_kindOf(stream) != sampler.kind ||
          _rides(run, stream) ||
          !test(stream)) {
        continue;
      }
      if (next == null || due < next) next = due;
    }
    return next;
  }

  void _arm(_Sampler sampler, Duration at, void Function() callback) {
    final wait = at - _elapsed();
    sampler.timer = _startTimer(
      wait.isNegative ? Duration.zero : wait,
      callback,
    );
  }

  /// Whether [stream] rides on its coverer's ticks in [run].
  static bool _rides(_Run run, SampleStream stream) {
    final coverer = _coverer(stream);
    return coverer != null && run.streams.contains(coverer);
  }

  /// Whether [stream] waits for [sampler]'s outstanding tick to settle
  /// rather than go out in a tick the session skips: a first reading, or
  /// one owed once, is no cadence tick, and skipping it would lose it.
  bool _held(_Run run, _Sampler sampler, SampleStream stream) =>
      sampler.busy &&
      (run.unread.contains(stream) ||
          samplingPeriod(stream, _subscriptions.profile) == null);

  /// Whether [stream] is a reading lost when it comes due while its
  /// sampler cannot tick: a cadence reading, not a first one or one owed
  /// once, which wait for the sampler instead.
  bool _losable(_Run run, SampleStream stream) =>
      !run.unread.contains(stream) &&
      samplingPeriod(stream, _subscriptions.profile) != null;

  /// Reports the streams a tick would read now as readings lost to a
  /// sampler that restarts or waits for the probe (03 §6.2: a missed
  /// tick shows as a gap), and moves them to their next period as a sent
  /// tick would. The sampler reads them as soon as it can tick again.
  void _lose(_Server server, _Run run, _Sampler sampler) {
    sampler.timer = null;
    if (!identical(server.run, run)) return;
    if (_canTick(run, sampler)) {
      _schedule(server, run, sampler);
      return;
    }

    final now = _elapsed();
    final profile = _subscriptions.profile;
    final lost = {
      for (final MapEntry(key: stream, value: due) in run.due.entries)
        if (_kindOf(stream) == sampler.kind &&
            due <= now &&
            _losable(run, stream))
          stream,
    };
    lost.removeWhere(
      (stream) => _rides(run, stream) && !lost.contains(_coverer(stream)),
    );
    for (final stream in lost) {
      run.due[stream] = _aligned(
        run.epoch,
        samplingPeriod(stream, profile)!,
        now,
      );
    }
    sampler.lost.addAll(lost);
    _emitAll(
      server.pipeline.addTick(
        lost,
        const SamplerSkipped(SamplerSkipReason.notReady),
        _now(),
      ),
    );
    _schedule(server, run, sampler);
  }

  void _tick(_Server server, _Run run, _Sampler sampler) {
    sampler.timer = null;
    if (!identical(server.run, run)) return;
    // A sampler that failed since the timer was armed loses its streams
    // until it can tick again.
    if (!_canTick(run, sampler)) {
      _schedule(server, run, sampler);
      return;
    }

    final now = _elapsed();
    final read = {
      for (final MapEntry(key: stream, value: due) in run.due.entries)
        if (_kindOf(stream) == sampler.kind &&
            due <= now &&
            !_held(run, sampler, stream))
          stream,
    };
    if (read.isNotEmpty && !sampler.busy) {
      read.addAll(run.missed.where((s) => _kindOf(s) == sampler.kind));
    }
    read.removeWhere(
      (stream) => _rides(run, stream) && !read.contains(_coverer(stream)),
    );
    if (read.isEmpty) {
      _schedule(server, run, sampler);
      return;
    }

    for (final stream in read) {
      final period = samplingPeriod(stream, _subscriptions.profile);
      // A read owed once stays owed until a reply carries it.
      run.due[stream] = period == null
          ? now + _owedReadRetry
          : _aligned(run.epoch, period, now);
    }
    run.unread.removeAll(read);
    // The session skips and counts a tick while another is outstanding;
    // only a tick it sends makes the sampler busy.
    final sent = !sampler.busy;
    if (sent) {
      run.missed.removeAll(read);
    } else {
      run.missed.addAll(read);
    }
    sampler.busy = true;
    final outcome = sampler.session.tick(_collectors(read));
    _schedule(server, run, sampler);
    unawaited(
      outcome.then((o) {
        if (sent) sampler.busy = false;
        _onTick(server, run, sampler, read, o);
      }),
    );
  }

  void _onTick(
    _Server server,
    _Run run,
    _Sampler sampler,
    Set<SampleStream> read,
    SamplerOutcome outcome,
  ) {
    if (!identical(server.run, run)) return;

    switch (outcome) {
      case SamplerReplied(:final reply):
        _answered(server, run);
        for (final stream in read) {
          if (samplingPeriod(stream, _subscriptions.profile) != null) continue;
          if (reply.section(sampleStreamCollector(stream).wireName) == null) {
            continue;
          }
          run.due.remove(stream);
          if (stream == SampleStream.identity) {
            server.identityReadOn = run.link;
          } else {
            server.owed.remove(stream);
          }
        }
      case SamplerGap(reason: SamplerGapReason.lost):
        // The program answered; only the reply was lost.
        _answered(server, run);
      case SamplerGap(reason: SamplerGapReason.deadline)
          when sampler.kind == SamplerKind.fast:
        // The fast collectors read /proc with builtins only, so a missed
        // deadline means a stalled sampler or a silent peer (03 §6.2);
        // whether the restarted sampler starts tells which.
        run.deadlineMissed = true;
      case SamplerGap() || SamplerSkipped():
        break;
    }
    // By the engine's clock as the reply arrived (03 §10.1).
    _emitAll(server.pipeline.addTick(read, outcome, _now()));
    // A reading held while the tick was outstanding goes out now.
    _schedule(server, run, sampler);
  }

  /// A sign of life on [run]'s link clears a dead-peer hint, or makes
  /// one that a missed deadline would open unnecessary.
  void _answered(_Server server, _Run run) {
    run.deadlineMissed = false;
    if (!run.hinted) return;
    run.hinted = false;
    _clearDeadPeerHint(server.pipeline.serverId, run.link);
  }

  /// The collectors that read [streams]: `core` stands in for `overview`
  /// (03 §6.4), and `procs` leads, since the reply's uptime times its
  /// CPU shares only then.
  static List<Collector> _collectors(Set<SampleStream> streams) {
    final collectors = {for (final s in streams) sampleStreamCollector(s)};
    if (collectors.contains(Collector.core)) {
      collectors.remove(Collector.overview);
    }
    return [
      if (collectors.contains(Collector.procs)) Collector.procs,
      for (final c in Collector.values)
        if (c != Collector.procs && collectors.contains(c)) c,
    ];
  }

  /// The first multiple of [period] after [epoch] that is later than
  /// [now].
  static Duration _aligned(Duration epoch, Duration period, Duration now) {
    final step = period.inMicroseconds;
    final since = (now - epoch).inMicroseconds;
    return epoch + Duration(microseconds: (since ~/ step + 1) * step);
  }

  void _emitAll(List<EngineEvent> events) => events.forEach(_emit);
}

/// One server's sampling: its pipeline for the server's time in the
/// fleet, and the samplers while it samples.
final class _Server {
  _Server(this.pipeline);

  final ServerSamplePipeline pipeline;

  /// On-demand streams owed a reading (03 §10.1); kept while the link is
  /// down or the app is in the background.
  final Set<SampleStream> owed = {};

  /// The link a probe last answered on (03 §6.1), and the one
  /// `identity` was last read on (03 §6.4: once per session).
  SshLink? probedOn;
  SshLink? identityReadOn;

  /// An `ops` read is owed (03 §7.17), and the link the last one was
  /// read on.
  bool opsOwed = false;
  SshLink? opsReadOn;
  _Run? run;
}

/// The samplers of one stretch of sampling on one link.
final class _Run {
  _Run(this.link, this.epoch, {required this.holdFast, required this.probeAt});

  final SshLink link;

  /// When the run started, by the monotonic clock; periods align to it.
  final Duration epoch;
  late final _Sampler fast;
  late final _Sampler slow;
  Set<SampleStream> streams = const {};

  /// When each stream read in this run is next due, by the monotonic
  /// clock.
  final Map<SampleStream, Duration> due = {};

  /// Streams due at once since they joined the run, until a tick sends
  /// them.
  final Set<SampleStream> unread = {};

  /// Streams of ticks the session skipped as busy. They join the next
  /// tick their sampler sends, which costs no request of its own, so a
  /// period that keeps landing on skipped ticks cannot starve them.
  final Set<SampleStream> missed = {};

  /// The fast sampler waits for the probe (see `_probe`).
  bool holdFast;

  /// When the probe goes out, by the monotonic clock, while the link
  /// owes one; null once one is answered.
  Duration? probeAt;
  bool probing = false;

  /// When an owed `ops` read that brought no reply goes out again; null
  /// to send it as soon as the slow sampler is free.
  Duration? opsAt;

  /// How long the next probe that brings no reply delays the one after.
  Duration probeRetry = _owedReadRetry;

  /// The fast sampler missed a deadline: its restart's start opens a
  /// dead-peer hint.
  bool deadlineMissed = false;

  /// A dead-peer hint about [link] is open with the supervisor.
  bool hinted = false;
}

final class _Sampler {
  _Sampler(this.kind, this.session);

  final SamplerKind kind;
  final SamplerSession session;
  StreamSubscription<SamplerState>? states;
  Timer? timer;

  /// A tick it sent is outstanding.
  bool busy = false;

  /// Streams whose readings came due while it could not tick; they are
  /// due at once when it can again.
  final Set<SampleStream> lost = {};
}
