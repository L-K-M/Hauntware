part of 'sampling_scheduler.dart';

/// A diagnostic bundle (CN-18, 03 §6.5): the probe on demand and one
/// tick of [kDiagnosticCollectors] per sampler, each once its sampler is
/// free, which counts as busy meanwhile. A request made while a bundle is
/// owed shares its answer; a sampler that has not answered after
/// [kDiagnosticsWait] leaves its collectors out.
final class _DiagnosticsRead implements _OwedRead {
  _DiagnosticsRead(this._scheduler);

  final SamplingScheduler _scheduler;

  /// Starts [serverId]'s bundle if none is owed and returns its answer;
  /// null when the server is not sampled or stops before it is read.
  Future<DiagnosticBundle?> read(String serverId) {
    final server = _scheduler._servers[serverId];
    final run = server?.run;
    if (server == null || run == null) return Future.value();

    final read = server.diagnostics ??= _Diagnostics(
      _scheduler._startTimer(
        kDiagnosticsWait,
        () => _finishDiagnostics(server),
      ),
    );
    final answer = Completer<DiagnosticBundle?>();
    read.answers.add(answer);
    _scheduler._schedule(server, run, run.fast);
    _scheduler._schedule(server, run, run.slow);
    return answer.future;
  }

  @override
  Duration? dueAt(_Server server, _Run run, _Sampler sampler) {
    final read = server.diagnostics;
    if (read == null) return null;
    if (sampler.busy || run.probeAt != null || !read.needs(sampler.kind)) {
      return null;
    }
    return Duration.zero;
  }

  @override
  void send(_Server server, _Run run, _Sampler sampler) {
    final read = server.diagnostics;
    if (read == null) return;
    final kind = sampler.kind;
    final probe = kind == SamplerKind.slow && read.probe == null;
    final collectors = [
      for (final c in kDiagnosticCollectors)
        if (c.sampler == kind) c,
    ];
    sampler.busy = true;
    final request = probe
        ? sampler.session.onDemand(Collector.probe, const [])
        : sampler.session.tick(collectors);
    _scheduler._settle(
      request,
      recover: () {
        sampler.busy = false;
        if (identical(server.run, run)) {
          _scheduler._schedule(server, run, sampler);
        }
      },
      (outcome) {
        sampler.busy = false;
        if (!identical(server.run, run)) return;

        if (outcome
            case SamplerReplied() ||
                SamplerGap(reason: SamplerGapReason.lost)) {
          _scheduler._answered(server, run);
        }
        if (identical(server.diagnostics, read) && outcome is! SamplerSkipped) {
          final sections = outcome is SamplerReplied
              ? outcome.reply.sections
              : const <HwsSection>[];
          // A tick's collector the reply has no section for gave no
          // answer, as does the probe when no area came back. The probe's
          // sections are its areas, named apart from the collector.
          final answered = {for (final s in sections) s.collector};
          read.missing.addAll([
            if (probe && sections.isEmpty) Collector.probe.wireName,
            if (!probe)
              for (final c in collectors)
                if (!answered.contains(c.wireName)) c.wireName,
          ]);
          switch ((probe, kind)) {
            case (true, _):
              read.probe = sections;
            case (false, SamplerKind.fast):
              read.fast = sections;
            case (false, SamplerKind.slow):
              read.slow = sections;
          }
          if (!read.needs(SamplerKind.fast) && !read.needs(SamplerKind.slow)) {
            _finishDiagnostics(server);
          }
        }
        _scheduler._schedule(server, run, sampler);
      },
    );
    // The pump returns after this call, so the other streams' timers are
    // armed here while the request is out.
    _scheduler._schedule(server, run, sampler);
  }
}

/// A diagnostic bundle being read (CN-18): what each request has
/// brought so far, null until it answers, and who waits for it.
final class _Diagnostics {
  _Diagnostics(this.deadline);

  final Timer deadline;
  final List<Completer<DiagnosticBundle?>> answers = [];
  final Set<String> missing = {};
  List<HwsSection>? probe;
  List<HwsSection>? fast;
  List<HwsSection>? slow;

  /// Whether a request of [kind]'s sampler is still owed.
  bool needs(SamplerKind kind) => switch (kind) {
    SamplerKind.fast => fast == null,
    SamplerKind.slow => probe == null || slow == null,
  };
}

/// Answers [server]'s owed bundle with what its samplers sent; the
/// collectors of a sampler that has not answered are missing.
void _finishDiagnostics(_Server server) {
  final read = server.diagnostics;
  if (read == null) return;

  server.diagnostics = null;
  read.deadline.cancel();
  final missing = {
    ...read.missing,
    if (read.probe == null) Collector.probe.wireName,
    for (final c in kDiagnosticCollectors)
      if (read.needs(c.sampler)) c.wireName,
  };
  final bundle = DiagnosticBundle(
    [
      for (final section in [...?read.probe, ...?read.fast, ...?read.slow])
        DiagnosticSection(
          collector: section.collector,
          status: section.status.name,
          text: utf8.decode(section.payload, allowMalformed: true),
        ),
    ],
    missing: [
      for (final name in [
        Collector.probe.wireName,
        for (final c in kDiagnosticCollectors) c.wireName,
      ])
        if (missing.contains(name)) name,
    ],
  );
  for (final answer in read.answers) {
    answer.complete(bundle);
  }
}
