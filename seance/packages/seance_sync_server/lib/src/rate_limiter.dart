import 'dart:collection';

/// A sliding-window rate limiter, used to blunt online guessing against the
/// login endpoint. Keyed by whatever the caller chooses (username, client IP,
/// or both). The clock is injectable so it can be tested deterministically.
///
/// Each key retains at most [maxAttempts] timestamps. The requested key is
/// pruned on every call, while all keys are swept every 64 calls so stale
/// one-off keys are eventually removed without scanning the map per request.
/// That periodic sweep is O(total tracked buckets), amortizing stale-key
/// cleanup across requests. At [maxBuckets], stale buckets are swept and the
/// least-recently-used live bucket is evicted before a new key is admitted.
/// A hit at exactly `now - window` is expired.
class RateLimiter {
  static const _sweepInterval = 64;

  final int maxAttempts;
  final Duration window;
  final int maxBuckets;
  final DateTime Function() _now;

  final LinkedHashMap<String, List<DateTime>> _hits = LinkedHashMap();
  int _callsUntilSweep = _sweepInterval;

  RateLimiter({
    this.maxAttempts = 10,
    this.window = const Duration(minutes: 1),
    this.maxBuckets = 4096,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (maxAttempts <= 0) {
      throw ArgumentError.value(
        maxAttempts,
        'maxAttempts',
        'must be greater than zero',
      );
    }
    if (window <= Duration.zero) {
      throw ArgumentError.value(window, 'window', 'must be greater than zero');
    }
    if (maxBuckets <= 0) {
      throw ArgumentError.value(
        maxBuckets,
        'maxBuckets',
        'must be greater than zero',
      );
    }
  }

  /// Records an attempt for [key] and returns true if it is within the limit,
  /// false if the caller should be throttled.
  bool allow(String key) {
    final now = _now();
    final cutoff = now.subtract(window);
    _callsUntilSweep--;
    final sweptAll = _callsUntilSweep == 0;
    if (sweptAll) {
      _sweep(cutoff);
      _callsUntilSweep = _sweepInterval;
    }

    // Removing and reinserting makes every access, including a refusal, move
    // the bucket to the most-recent end of the insertion-ordered map.
    var hits = _hits.remove(key);
    if (hits != null) {
      if (!sweptAll) _removeExpired(hits, cutoff);
      if (hits.isEmpty) {
        hits = null;
      } else {
        _hits[key] = hits;
      }
    }
    if (hits == null) {
      if (_hits.length >= maxBuckets) {
        if (!sweptAll) _sweep(cutoff);
        if (_hits.length >= maxBuckets) {
          _hits.remove(_hits.keys.first);
        }
      }
      hits = [];
      _hits[key] = hits;
    }

    if (hits.length >= maxAttempts) return false;
    hits.add(now);
    return true;
  }

  void reset(String key) => _hits.remove(key);

  /// Number of buckets retained, exposed for operational metrics and
  /// deterministic resource-bound tests.
  int get bucketCount => _hits.length;

  void _sweep(DateTime cutoff) {
    _hits.removeWhere((_, hits) {
      _removeExpired(hits, cutoff);
      return hits.isEmpty;
    });
  }

  void _removeExpired(List<DateTime> hits, DateTime cutoff) {
    hits.removeWhere((hit) => !hit.isAfter(cutoff));
  }
}
