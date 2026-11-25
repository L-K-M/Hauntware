part of 'sampling_scheduler.dart';

/// The `ops` listing a run owes once per link (03 §7.17): the app's own
/// records rather than the host's state, read on the slow sampler after
/// the probe.
final class _OpsRead implements _OwedRead {
  _OpsRead(this._scheduler);

  final SamplingScheduler _scheduler;

  @override
  Duration? dueAt(_Server server, _Run run, _Sampler sampler) =>
      sampler.kind == SamplerKind.slow &&
          !sampler.busy &&
          run.probeAt == null &&
          server.opsOwed
      ? run.opsAt ?? Duration.zero
      : null;

  @override
  void send(_Server server, _Run run, _Sampler sampler) {
    assert(identical(sampler, run.slow), 'ops reads on the slow sampler');
    sampler.busy = true;
    void recover() {
      sampler.busy = false;
      if (identical(server.run, run)) {
        _scheduler._schedule(server, run, sampler);
      }
    }

    _scheduler._settle(
      sampler.session.onDemand(Collector.ops, const []),
      recover: recover,
      (outcome) {
        sampler.busy = false;
        if (!identical(server.run, run)) return;

        final section = outcome is SamplerReplied
            ? outcome.reply.section(Collector.ops.wireName)
            : null;
        if (outcome
            case SamplerReplied() ||
                SamplerGap(reason: SamplerGapReason.lost)) {
          _scheduler._answered(server, run);
        }
        if (section == null) {
          run.opsAt = _scheduler._elapsed() + _owedReadRetry;
        } else {
          server.opsOwed = false;
          server.opsReadOn = run.link;
          run.opsAt = null;
          _scheduler._opsRead!(server.pipeline.serverId, section);
        }
        _scheduler._schedule(server, run, sampler);
      },
    );
    _scheduler._schedule(server, run, sampler);
  }
}
