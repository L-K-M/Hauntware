/// The backoff for reopening a dropped Docker stream: the container log
/// follow and the events watch both read again after 1 s, 2 s, ... up to
/// the ceiling. The router's own endpoint ladder keeps a different,
/// slower private backoff.
library;

import 'dart:math' as math;

/// The first delay before a dropped Docker stream is opened again.
const Duration kDockerRetryBase = Duration(seconds: 1);

/// The ceiling a Docker stream's reopen delay grows to.
const Duration kDockerRetryCap = Duration(seconds: 30);

/// A retry delay that doubles with each attempt, then stops growing.
///
/// Each caller keeps its own [base], [cap] and [exponentLimit]; only the
/// count of attempts differs between them.
final class Backoff {
  const Backoff({
    required this.base,
    required this.cap,
    this.exponentLimit = 5,
  });

  /// The delay before the first retry.
  final Duration base;

  /// The ceiling a delay never passes.
  final Duration cap;

  /// The highest power of two a delay grows by, so a long outage settles
  /// at [cap].
  final int exponentLimit;

  /// [base] times `2^min(retries, exponentLimit)`, at most [cap]. The
  /// first retry is number 0.
  Duration delay(int retries) {
    final growth = math.pow(2, math.min(retries, exponentLimit)).toInt();
    final scaled = base * growth;
    return scaled < cap ? scaled : cap;
  }
}

/// The reopen backoff of a dropped Docker stream, shared by the events
/// watch and a container log follow.
const kDockerStreamBackoff = Backoff(
  base: kDockerRetryBase,
  cap: kDockerRetryCap,
);
