import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:test/test.dart';

void main() {
  group('RateLimiter', () {
    late DateTime now;

    setUp(() => now = DateTime.utc(2026, 1, 1));

    test('bounds keyed buckets and shares overflow for rotating keys', () {
      final limiter = RateLimiter(
        maxAttempts: 2,
        maxBuckets: 2,
        now: () => now,
      );

      expect(limiter.allow('a'), isTrue);
      expect(limiter.allow('b'), isTrue);
      expect(limiter.allow('overflow-1'), isTrue);
      expect(limiter.allow('overflow-2'), isTrue);
      expect(limiter.allow('overflow-3'), isFalse);
      expect(limiter.bucketCount, 2);
    });

    test('never evicts an active keyed bucket', () {
      final limiter = RateLimiter(
        maxAttempts: 1,
        maxBuckets: 1,
        now: () => now,
      );

      expect(limiter.allow('target'), isTrue);
      expect(limiter.allow('rotating'), isTrue);
      expect(limiter.allow('target'), isFalse);
      expect(limiter.bucketCount, 1);
    });

    test('expired oldest buckets make room without a global scan', () {
      final limiter = RateLimiter(
        maxAttempts: 1,
        maxBuckets: 2,
        window: const Duration(minutes: 1),
        now: () => now,
      );
      expect(limiter.allow('old-a'), isTrue);
      expect(limiter.allow('old-b'), isTrue);

      now = now.add(const Duration(minutes: 1));
      expect(limiter.allow('new'), isTrue);
      expect(limiter.bucketCount, 1);
    });

    test('reports retry delay and expires at the inclusive cutoff', () {
      final limiter = RateLimiter(
        maxAttempts: 1,
        window: const Duration(minutes: 1),
        now: () => now,
      );
      expect(limiter.check('alice').allowed, isTrue);
      now = now.add(const Duration(seconds: 10));
      final blocked = limiter.check('alice');
      expect(blocked.allowed, isFalse);
      expect(blocked.retryAfter, const Duration(seconds: 50));

      now = now.add(const Duration(seconds: 50));
      expect(limiter.check('alice').allowed, isTrue);
    });

    test('uses a sliding window', () {
      final limiter = RateLimiter(
        maxAttempts: 2,
        window: const Duration(minutes: 1),
        now: () => now,
      );
      expect(limiter.allow('alice'), isTrue);
      now = now.add(const Duration(seconds: 59));
      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);
    });

    test('reset removes keyed attempts', () {
      final limiter = RateLimiter(maxAttempts: 1, now: () => now);
      expect(limiter.allow('alice'), isTrue);
      expect(limiter.allow('alice'), isFalse);
      limiter.reset('alice');
      expect(limiter.allow('alice'), isTrue);
    });

    test('rejects invalid configuration', () {
      expect(() => RateLimiter(maxAttempts: 0), throwsArgumentError);
      expect(() => RateLimiter(window: Duration.zero), throwsArgumentError);
      expect(() => RateLimiter(maxBuckets: 0), throwsArgumentError);
    });
  });
}
