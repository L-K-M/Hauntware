part of 'sampling_scheduler.dart';

/// The run's probe, the slow sampler's first request (03 §6.1). Until it
/// settles the slow sampler sends nothing else and, for a server whose
/// profile is not known yet, the fast one waits too, so the first readings
/// already withhold what a container host's `/proc` would supply (D50).
final class _ProbeRead implements _OwedRead {
  _ProbeRead(this._scheduler);

  final SamplingScheduler _scheduler;

  @override
  Duration? dueAt(_Server server, _Run run, _Sampler sampler) =>
      sampler.kind == SamplerKind.slow && !sampler.busy && run.probeAt != null
      ? run.probeAt
      : null;

  @override
  void send(_Server server, _Run run, _Sampler sampler) {
    assert(identical(sampler, run.slow), 'the probe runs on the slow sampler');
    run.probing = true;
    _scheduler._settle(
      sampler.session.onDemand(Collector.probe, const []),
      recover: () {
        if (!identical(server.run, run)) return;
        // As for a probe that brought no reply: it goes out again.
        run.probing = false;
        run.holdFast = false;
        run.probeAt ??= _scheduler._elapsed() + run.probeRetry;
        _scheduler._schedule(server, run, run.slow);
        _scheduler._schedule(server, run, run.fast);
      },
      (outcome) {
        if (!identical(server.run, run)) return;

        run.probing = false;
        run.holdFast = false;
        if (outcome is SamplerReplied) {
          server.probedOn = run.link;
          run.probeAt = null;
          _scheduler._answered(server, run);
        } else {
          run.probeAt = _scheduler._elapsed() + run.probeRetry;
          // The session closed under the probe (a lending, a stop), so
          // nothing failed and the next wait stays what it was.
          if (outcome is! SamplerGap ||
              outcome.reason != SamplerGapReason.closed) {
            final doubled = run.probeRetry * 2;
            run.probeRetry = doubled < _maxProbeRetry
                ? doubled
                : _maxProbeRetry;
          }
        }
        _scheduler._emitAll(server.pipeline.addProbe(outcome));
        if (outcome is SamplerReplied) {
          final profile = server.pipeline.profile!;
          _scheduler._probed(server.pipeline.serverId, profile);
          if (profile.epochSeconds case final epoch?) {
            final at = _scheduler._now().toUtc();
            _scheduler._emit(
              ServerClock(
                server.pipeline.serverId,
                skew: Duration(
                  milliseconds: epoch * 1000 - at.millisecondsSinceEpoch,
                ),
                at: at,
              ),
            );
          }
        }
        _scheduler._schedule(server, run, run.slow);
        _scheduler._schedule(server, run, run.fast);
      },
    );
    _scheduler._schedule(server, run, run.slow);
  }
}
