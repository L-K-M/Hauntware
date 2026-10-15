/// Deadlines for one sampler session (03 §6.2, D47). Its restart delay
/// is the link backoff, `backoffDelay`.
library;

import 'package:klabautermann_host/klabautermann_host.dart';

/// Time from a started channel to the READY marker [E]. It covers the
/// login shell's startup files, which run before the start command, and
/// the program's own start.
const kSamplerReadyDeadline = Duration(seconds: 15);

/// Deadline of a fast-sampler request (03 §6.2) [E].
const kFastRequestDeadline = Duration(seconds: 5);

/// What a slow request may take on top of its guarded commands (D47) [E]:
/// the shell's builtin work, the unguarded `systemctl --version` behind
/// the JSON-or-text choice and the transport.
const kSlowRequestMargin = Duration(seconds: 5);

/// An upper bound on the guarded commands (`hw_run`, `hw_qrun`) one run
/// of [collector]'s fragment starts, each bounded by `timeout 10` when
/// the host has `timeout` (03 §6.2, D47). The count is the calls written in
/// the fragment; where calls sit on exclusive branches (`procs`' `head`
/// or `ps`, the JSON or text calls of `units` and `timers`) only one
/// branch runs, so the bound is high by those. No guarded call sits
/// inside a loop. A test ties each figure to the fragment text, so a
/// program change has to revisit it. The count belongs with the
/// fragments in `klabautermann_host`: once that package exposes it
/// (`Collector.guardedCommands` is planned), this table goes, so the
/// count has one owner.
int guardedCommandBound(Collector collector) => switch (collector) {
  Collector.overview || Collector.core => 0,
  Collector.probe => 17,
  Collector.fs => 2,
  Collector.identity => 2,
  Collector.procs => 3,
  Collector.units => 4,
  Collector.timers => 2,
  Collector.cron => 1,
};

/// A sampler's READY and request deadlines (D47). Tests inject short
/// ones; production takes the defaults.
final class SamplerDeadlines {
  const SamplerDeadlines({
    this.ready = kSamplerReadyDeadline,
    this.fastRequest = kFastRequestDeadline,
    this.slowMargin = kSlowRequestMargin,
    this.perGuardedCommand = const Duration(seconds: kCollectorTimeoutSeconds),
  });

  /// From the started channel to READY.
  final Duration ready;

  /// A request on the fast sampler, whose collectors only read `/proc`
  /// and `/sys` with builtins.
  final Duration fastRequest;

  /// What a slow request may take on top of its guarded commands.
  final Duration slowMargin;

  /// The bound of one guarded command: its `timeout` on the host.
  final Duration perGuardedCommand;

  /// The deadline for one request naming [collectors] on a [kind]
  /// sampler. A slow request gets [slowMargin] plus [perGuardedCommand]
  /// for every guarded command its collectors can start, instead of
  /// one fixed figure: the probe alone may need 17 of them (D47). Without
  /// `timeout` on the host the commands run unguarded, and this deadline
  /// still bounds the request.
  Duration forRequest(SamplerKind kind, Iterable<Collector> collectors) {
    if (kind == SamplerKind.fast) return fastRequest;
    final commands = collectors.fold(0, (n, c) => n + guardedCommandBound(c));
    return slowMargin + perGuardedCommand * commands;
  }
}
