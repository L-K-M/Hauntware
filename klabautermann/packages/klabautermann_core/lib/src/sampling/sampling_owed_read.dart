part of 'sampling_scheduler.dart';

/// A read the scheduler owes on a free sampler: the run's probe, the
/// `ops` listing, or a diagnostic bundle (03 §6.2, §6.5). `_schedule`
/// asks each job in order before it arms a cadence tick, so an owed
/// request goes out ahead of the tick that would otherwise claim the
/// sampler.
abstract interface class _OwedRead {
  /// When this job next wants [sampler], or null when it does not apply
  /// to it. A time at or before now means its request goes out now.
  Duration? dueAt(_Server server, _Run run, _Sampler sampler);

  /// Sends this job's request on [sampler] and settles it. Before it
  /// returns, [dueAt] must answer null for this job (a busy sampler, a
  /// probing run): the scheduler asks the jobs again while the request
  /// is out, and a job still due would be sent twice.
  void send(_Server server, _Run run, _Sampler sampler);
}
