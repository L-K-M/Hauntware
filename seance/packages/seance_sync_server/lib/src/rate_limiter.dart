import 'dart:collection';

/// The outcome of one sliding-window rate-limit check.
final class RateLimitDecision {
  const RateLimitDecision({required this.allowed, this.retryAfter});

  final bool allowed;
  final Duration? retryAfter;
}

final class _Bucket {
  final Queue<DateTime> hits = Queue<DateTime>();
}

/// A bounded sliding-window limiter.
///
/// Keyed buckets are kept in access order. Expired oldest buckets are removed
/// before allocating a new one; active buckets are never evicted because key
/// rotation would otherwise reset the limit. When all [maxBuckets] are active,
/// previously unseen keys share one overflow bucket, keeping memory bounded.
class RateLimiter {
  final int maxAttempts;
  final Duration window;
  final int maxBuckets;
  final DateTime Function() _now;

  final LinkedHashMap<String, _Bucket> _buckets = LinkedHashMap();
  final _Bucket _overflow = _Bucket();

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

  /// Number of keyed buckets retained, exposed for bounded-memory tests.
  int get bucketCount => _buckets.length;

  RateLimitDecision check(String key) {
    final now = _now();
    final cutoff = now.subtract(window);
    var bucket = _buckets.remove(key);
    if (bucket != null) {
      _prune(bucket, cutoff);
      _buckets[key] = bucket;
      return _record(bucket, now);
    }

    _removeExpiredOldest(cutoff);
    if (_buckets.length < maxBuckets) {
      bucket = _Bucket();
      _buckets[key] = bucket;
    } else {
      bucket = _overflow;
      _prune(bucket, cutoff);
    }
    return _record(bucket, now);
  }

  /// Compatibility surface for callers that only need the boolean result.
  bool allow(String key) => check(key).allowed;

  void reset(String key) => _buckets.remove(key);

  RateLimitDecision _record(_Bucket bucket, DateTime now) {
    if (bucket.hits.length >= maxAttempts) {
      final retryAt = bucket.hits.first.add(window);
      final remaining = retryAt.difference(now);
      return RateLimitDecision(
        allowed: false,
        retryAfter: remaining > Duration.zero
            ? remaining
            : const Duration(milliseconds: 1),
      );
    }
    bucket.hits.addLast(now);
    return const RateLimitDecision(allowed: true);
  }

  void _removeExpiredOldest(DateTime cutoff) {
    while (_buckets.isNotEmpty) {
      final key = _buckets.keys.first;
      final bucket = _buckets[key]!;
      _prune(bucket, cutoff);
      if (bucket.hits.isNotEmpty) return;
      _buckets.remove(key);
    }
  }

  void _prune(_Bucket bucket, DateTime cutoff) {
    while (bucket.hits.isNotEmpty && !bucket.hits.first.isAfter(cutoff)) {
      bucket.hits.removeFirst();
    }
  }
}
