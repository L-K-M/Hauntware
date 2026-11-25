import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

import 'server_readings.dart';

/// The longest a refresh waits for its readings (PLT-02) [E]: a slow
/// sampler's reply on a slow link comes well within it, and a hung `df`
/// does not keep the pull indicator spinning. The panel's freshness line
/// keeps telling a reading's age after it.
const Duration kRefreshWait = Duration(seconds: 10);

/// A monitoring refresh waiting for a newer sample of each of its
/// streams, while the server samples, for at most [kRefreshWait].
final class PendingRefresh {
  PendingRefresh(
    this.serverId,
    this._readings,
    Set<SampleStream> streams,
    this._onDone,
  ) : _before = {
        for (final stream in streams) stream: _readings.box(stream).value?.seq,
      } {
    for (final stream in _before.keys) {
      _readings.box(stream).addListener(_check);
    }
    _readings.sampling.addListener(_check);
    _timer = Timer(kRefreshWait, finish);
  }

  final String serverId;
  final ServerReadings _readings;

  /// Each stream's latest seq when the refresh went out.
  final Map<SampleStream, int?> _before;
  final void Function(PendingRefresh refresh) _onDone;
  final Completer<void> _done = Completer();
  late final Timer _timer;

  Future<void> get done => _done.future;

  void _check() {
    final sampling =
        _readings.sampling.value?.state.phase == SamplingPhase.sampling;
    final read = _before.entries.every((entry) {
      final seq = _readings.box(entry.key).value?.seq;
      return seq != null && seq > (entry.value ?? -1);
    });
    if (!sampling || read) finish();
  }

  /// Stops waiting; once only.
  void finish() {
    if (_done.isCompleted) return;
    _timer.cancel();
    for (final stream in _before.keys) {
      _readings.box(stream).removeListener(_check);
    }
    _readings.sampling.removeListener(_check);
    _onDone(this);
    _done.complete();
  }
}
