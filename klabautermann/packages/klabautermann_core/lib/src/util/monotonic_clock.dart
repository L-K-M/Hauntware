/// A clock that only moves forward, for due times and pacing, so a stepped
/// wall clock cannot stall them. Each call starts a clock of its own.
library;

/// Elapsed time from a stopwatch started now, which only moves forward.
Duration Function() monotonicClock() {
  final watch = Stopwatch()..start();
  return () => watch.elapsed;
}
