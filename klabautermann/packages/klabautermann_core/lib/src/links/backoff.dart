import 'dart:math';

/// The link backoff of 03 §5.1 (CN-05), Poltergeist's constants: 1 s
/// doubling to a 30 s cap, less up to 30 % of downward jitter.
const Duration _baseDelay = Duration(seconds: 1);
const Duration _delayCap = Duration(seconds: 30);
const double _jitterFraction = 0.3;

/// The delay before the next try after [failures] earlier failed tries
/// in a row: 1 s doubling to a 30 s cap, less up to 30 % of downward
/// jitter from [random], so links or samplers that failed together do
/// not retry together and the cap is never exceeded. The link supervisor
/// waits this long before a redial, and a sampler session before a
/// restart.
Duration backoffDelay(int failures, Random random) {
  var micros = _baseDelay.inMicroseconds;
  final cap = _delayCap.inMicroseconds;
  // Stop doubling at the cap, so a long outage cannot overflow.
  for (var i = 0; i < failures && micros < cap; i++) {
    micros *= 2;
  }
  final jitter = 1 - _jitterFraction * random.nextDouble();
  return Duration(microseconds: (min(micros, cap) * jitter).round());
}
