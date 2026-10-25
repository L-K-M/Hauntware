/// The engine's sample pipeline for one server (03 §6.4, §10.1, D43,
/// D44, D50): sampler outcomes in, [Sample], [Gap], [SamplingState] and
/// [HostProfileChanged] events out.
///
/// It owns no sampler, link or timer: the scheduler (K22) reports what
/// the server's sampling depends on
/// ([ServerSamplePipeline.updateConditions]) and hands over each outcome
/// with the engine's clock reading, so the pipeline is a transformation
/// over its own state. The phase follows from the conditions alone:
///
/// ```text
///   no stream subscribed          ─▶ unsubscribed
///   else app in the background    ─▶ pausedInBackground
///   else link not ready           ─▶ waitingForLink
///   else                          ─▶ sampling
/// ```
library;

import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';

import '../engine/protocol.dart';
import 'sample_results.dart';
import 'sampler_session.dart';

/// The engine's [Sample.seq] counters (D44): one per server, rising with
/// every sample for the engine's lifetime. The engine keeps one instance
/// and hands it to every pipeline, so a pipeline built again for a new
/// link or after an unsubscribe continues its server's count.
final class SampleSequence {
  final Map<String, int> _last = {};

  /// The next seq for [serverId], starting at 1.
  int next(String serverId) => _last[serverId] = (_last[serverId] ?? 0) + 1;
}

/// The phase that follows from a server's conditions (03 §10.1): no
/// stream subscribed, the app in the background, the link not ready, or
/// sampling. The background is named first because it is why a phone's
/// link closes (D34).
SamplingPhase samplingPhase({
  required bool subscribed,
  required bool linkReady,
  required AppActivity activity,
}) {
  if (!subscribed) return SamplingPhase.unsubscribed;
  if (activity == AppActivity.background) {
    return SamplingPhase.pausedInBackground;
  }
  if (!linkReady) return SamplingPhase.waitingForLink;
  return SamplingPhase.sampling;
}

/// Profile fields a probe changes every time (the clock) or per session;
/// a [HostProfileChanged] ignores them (03 §10.1), and the device cache
/// keeps none of them (D59).
const volatileProfileKeys = {
  'epochSeconds',
  'zoneOffset',
  'sshConnection',
  'sessionParentPid',
  'sessionParentComm',
};

/// [profile] without its [volatileProfileKeys], for comparing.
String _stableKey(HostProfile profile) => jsonEncode({
  for (final e in profile.toJson().entries)
    if (!volatileProfileKeys.contains(e.key)) e.key: e.value,
});

/// An open [Gap] of one stream: no reading since [from], for [cause].
typedef _OpenGap = ({DateTime from, GapCause cause});

/// One server's sampling state and the events it produces.
///
/// Readings count only while the phase is [SamplingPhase.sampling]; the
/// counters behind rates are dropped whenever it leaves that phase, so
/// the first reading after a background or disconnected stretch starts a
/// new series rather than averaging over the stretch. A lost reading, a
/// framing error or a sampler restart keeps them: the next rate spans
/// the loss, measured by the host's uptime.
final class ServerSamplePipeline {
  /// [profile] is the server's latest known profile when a pipeline is
  /// built again, so the values it withholds (D50) stay withheld before
  /// the next probe answers, and that answer is reported only if it
  /// differs.
  ServerSamplePipeline({
    required this.serverId,
    required this._sequence,
    HostProfile? profile,
  }) : _profile = profile,
       _profileKey = profile == null ? null : _stableKey(profile);

  final String serverId;
  final SampleSequence _sequence;

  SamplingPhase _phase = SamplingPhase.unsubscribed;
  Set<SampleStream> _streams = const {};
  HostProfile? _profile;
  String? _profileKey;

  final _metrics = MetricDeriver();
  ({ProcsSnapshot snapshot, double? uptime})? _lastProcs;

  /// Each subscribed stream's latest reading, by the engine's clock.
  final Map<SampleStream, DateTime> _lastAt = {};
  final Map<SampleStream, _OpenGap> _gaps = {};

  /// What sampling the server is doing.
  SamplingPhase get phase => _phase;

  /// The latest probe's findings, else the profile it was built with.
  HostProfile? get profile => _profile;

  /// Records the server's subscribed [streams] (the union of its
  /// subscriptions, D45), whether its link is ready and the app's
  /// activity, as of [at]. Returns a [SamplingState] when the phase
  /// changes. Leaving [SamplingPhase.sampling] for the background or a
  /// lost link opens a gap for every stream with a reading. A stream no
  /// longer subscribed is forgotten, gap and counters included, so a
  /// panel opened again starts a new series.
  List<EngineEvent> updateConditions({
    required Set<SampleStream> streams,
    required bool linkReady,
    required AppActivity activity,
    required DateTime at,
  }) {
    _streams = Set.unmodifiable(streams);
    _lastAt.removeWhere((stream, _) => !streams.contains(stream));
    _gaps.removeWhere((stream, _) => !streams.contains(stream));
    if (!streams.contains(SampleStream.core)) _metrics.forgetCore();
    if (!streams.contains(SampleStream.overview) &&
        !streams.contains(SampleStream.core)) {
      _metrics.reset();
    }
    if (!streams.contains(SampleStream.procs)) _lastProcs = null;

    final next = samplingPhase(
      subscribed: streams.isNotEmpty,
      linkReady: linkReady,
      activity: activity,
    );
    if (next == _phase) return const [];

    final previous = _phase;
    _phase = next;
    if (previous == SamplingPhase.sampling) {
      _metrics.reset();
      _lastProcs = null;
    }
    switch (next) {
      case SamplingPhase.pausedInBackground:
        _openGaps(_lastAt.keys, GapCause.background);
      case SamplingPhase.waitingForLink:
        _openGaps(_lastAt.keys, GapCause.disconnected);
      case SamplingPhase.unsubscribed || SamplingPhase.sampling:
        break;
    }
    return [SamplingState(serverId: serverId, phase: next, since: at)];
  }

  /// Takes the outcome of a probe request (03 §6.1). Returns a
  /// [HostProfileChanged] for the first profile (unless the pipeline was
  /// built with it) and whenever a later one differs in more than its
  /// clock and session fields (03 §10.1); every answer replaces
  /// [profile]. A probe without an answer changes nothing.
  List<EngineEvent> addProbe(SamplerOutcome outcome) {
    if (outcome is! SamplerReplied) return const [];

    final sections = [
      for (final s in outcome.reply.sections) ?ProbeSection.fromEvent(s),
    ];
    final profile = parseProbe(sections, ParseContext.standard).value;
    final key = _stableKey(profile);
    _profile = profile;
    if (key == _profileKey) return const [];

    _profileKey = key;
    return [HostProfileChanged(serverId, profile)];
  }

  /// Takes the outcome of a tick that read [streams] at [at], by the
  /// engine's clock. A reply yields a [Sample] for each of them still
  /// subscribed, preceded by a [Gap] for each group of them whose
  /// readings a gap interrupted. A reply's `core` section stands in for
  /// a missing `overview` one, since `core` reads every counter
  /// `overview` does. A reading lost to a deadline, a framing error or a
  /// sampler that is restarting opens a gap instead, as does a reply
  /// without a stream's section. Per-process CPU shares need `procs` to
  /// be the first collector of its request (03 §6.4); a `procs` section
  /// behind another has no shares, nor does the next one.
  /// Outcomes outside [SamplingPhase.sampling] are ignored, as are
  /// samplers that closed (the conditions say why) and ticks skipped
  /// while another request is outstanding. A busy skip is counted, not
  /// lost (03 §6.2), so it opens no gap, also for streams the
  /// outstanding request does not read: their latest [Sample.at] ages
  /// until a later tick reads them.
  List<EngineEvent> addTick(
    Set<SampleStream> streams,
    SamplerOutcome outcome,
    DateTime at,
  ) {
    if (_phase != SamplingPhase.sampling) return const [];

    final read = streams.intersection(_streams);
    switch (outcome) {
      case SamplerReplied(:final reply):
        return _addReply(read, reply, at);
      case SamplerGap(reason: SamplerGapReason.closed) ||
          SamplerSkipped(
            reason: SamplerSkipReason.busy || SamplerSkipReason.stopped,
          ):
        return const [];
      case SamplerGap() || SamplerSkipped():
        _openGaps(read.where(_lastAt.containsKey), GapCause.readingLost);
        return const [];
    }
  }

  List<EngineEvent> _addReply(
    Set<SampleStream> streams,
    HwsTick reply,
    DateTime at,
  ) {
    final ctx = ParseContext(
      counterWidth: _profile?.counterWidth ?? CounterWidth.bits64,
    );
    HwsSection? section(SampleStream stream) => switch (stream) {
      SampleStream.overview =>
        reply.section(Collector.overview.wireName) ??
            reply.section(Collector.core.wireName),
      _ => reply.section(sampleStreamCollector(stream).wireName),
    };
    String text(HwsSection s) => utf8.decode(s.payload, allowMalformed: true);

    // Metrics first, together, so overview and core diff against the
    // same earlier reading.
    final overviewSection = streams.contains(SampleStream.overview)
        ? section(SampleStream.overview)
        : null;
    final coreSection = streams.contains(SampleStream.core)
        ? section(SampleStream.core)
        : null;
    bool ok(HwsSection? s) => s != null && s.status == SectionStatus.ok;
    final core = ok(coreSection)
        ? parseCore(text(coreSection!), ctx).value
        : null;
    final metrics = _metrics.derive(
      overview: !ok(overviewSection)
          ? null
          : identical(overviewSection, coreSection)
          ? core
          : overviewSection!.collector == Collector.core.wireName
          ? parseCore(text(overviewSection), ctx).value
          : parseOverview(text(overviewSection), ctx).value,
      core: core,
      uptime: reply.uptimeSeconds,
      profile: _profile,
    );

    final results = <SampleStream, SampleResult>{};
    for (final stream in streams) {
      final s = section(stream);
      if (s == null) {
        if (_lastAt.containsKey(stream)) {
          _openGaps([stream], GapCause.readingLost);
        }
        continue;
      }

      final unavailable = collectorUnavailable(s);
      results[stream] =
          unavailable ??
          switch (stream) {
            SampleStream.overview => metrics.overview!,
            SampleStream.core => metrics.core!,
            SampleStream.fs => FsResult(parseFs(text(s), ctx).value),
            SampleStream.identity => identityResult(
              parseIdentity(text(s), ctx).value,
            ),
            SampleStream.procs => _procs(
              parseProcs(text(s), ctx).value,
              // The host reads the `B` uptime before the reply's first
              // collector, so it times `procs` only when `procs` ran
              // first; behind another, its share interval is unknown.
              identical(s, reply.sections.first) ? reply.uptimeSeconds : null,
              _bootedAt(reply.uptimeSeconds, at),
            ),
            SampleStream.units || SampleStream.userUnits => UnitsResult(
              parseUnits(text(s), ctx).value,
            ),
            SampleStream.failedUnits => FailedUnitsResult(
              parseUnits(text(s), ctx).value.failed,
            ),
            SampleStream.timers || SampleStream.userTimers => TimersResult(
              parseTimers(text(s), ctx).value,
            ),
            SampleStream.temps => TempsResult(parseTemps(text(s), ctx).value),
            SampleStream.cron => cronResult(
              parseCron(text(s), ctx).value,
              _profile,
              at,
            ),
          };
    }

    return [
      ..._closeGaps(results.keys, at),
      for (final MapEntry(key: stream, value: result) in results.entries)
        Sample(
          serverId: serverId,
          stream: stream,
          seq: _sequence.next(serverId),
          at: at,
          result: result,
        ),
    ];
  }

  ProcsResult _procs(ProcsSnapshot next, double? uptime, DateTime? bootedAt) {
    final last = _lastProcs;
    _lastProcs = (snapshot: next, uptime: uptime);
    final lastUptime = last?.uptime;
    return procsResult(
      next,
      previous: last?.snapshot,
      elapsed: uptime != null && lastUptime != null && uptime > lastUptime
          ? uptime - lastUptime
          : null,
      bootedAt: bootedAt,
    );
  }

  /// When the kernel booted by the engine's clock, from a reply read at
  /// [at] whose host read [uptime] before its first collector: late by
  /// the time the reply took, under a second for a `procs` tick. Null
  /// unless the probe's lxcfs mounts show that `/proc/uptime` is the
  /// kernel's, which `/proc/<pid>/stat` start ticks count from (D50).
  DateTime? _bootedAt(double? uptime, DateTime at) {
    final profile = _profile;
    final mounts = profile?.lxcfsMounts;
    if (uptime == null || mounts == null) return null;
    if (mounts.isNotEmpty &&
        profile!.showsHostFigures(SystemWideProcFile.uptime) != true) {
      return null;
    }

    return at.subtract(
      Duration(microseconds: (uptime * Duration.microsecondsPerSecond).round()),
    );
  }

  /// Opens a gap for each of [streams] from its latest reading. A gap
  /// already open keeps its start, and a lost reading's cause gives way
  /// to the background or a lost link, which explain more.
  void _openGaps(Iterable<SampleStream> streams, GapCause cause) {
    for (final stream in streams) {
      final open = _gaps[stream];
      if (open == null) {
        _gaps[stream] = (from: _lastAt[stream]!, cause: cause);
      } else if (open.cause == GapCause.readingLost) {
        _gaps[stream] = (from: open.from, cause: cause);
      }
    }
  }

  /// Records readings of [streams] at [at] and returns a [Gap] for each
  /// group of them whose open gap shares a start and cause.
  List<Gap> _closeGaps(Iterable<SampleStream> streams, DateTime at) {
    final groups = <_OpenGap, Set<SampleStream>>{};
    for (final stream in streams) {
      _lastAt[stream] = at;
      final open = _gaps.remove(stream);
      if (open != null) (groups[open] ??= {}).add(stream);
    }
    return [
      for (final MapEntry(key: gap, value: group) in groups.entries)
        Gap(
          serverId: serverId,
          streams: Set.unmodifiable(group),
          from: gap.from,
          until: at,
          cause: gap.cause,
        ),
    ];
  }
}
