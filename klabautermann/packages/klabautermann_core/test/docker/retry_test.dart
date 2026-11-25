// The shared doubling backoff: each caller keeps its own base, ceiling
// and exponent limit (DKR-11).
import 'package:klabautermann_core/src/docker/retry.dart';
import 'package:test/test.dart';

void main() {
  group('Backoff', () {
    test("the endpoint ladder's sequence, from 5 s to a 2 min cap", () {
      const backoff = Backoff(
        base: Duration(seconds: 5),
        cap: Duration(minutes: 2),
      );
      expect(
        [for (var retries = 0; retries < 8; retries++) backoff.delay(retries)],
        const [
          Duration(seconds: 5),
          Duration(seconds: 10),
          Duration(seconds: 20),
          Duration(seconds: 40),
          Duration(seconds: 80),
          Duration(minutes: 2),
          Duration(minutes: 2),
          Duration(minutes: 2),
        ],
      );
    });

    test("a dropped stream's sequence, from 1 s to a 30 s cap", () {
      expect(
        [
          for (var retries = 0; retries < 8; retries++)
            kDockerStreamBackoff.delay(retries),
        ],
        const [
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
          Duration(seconds: 16),
          Duration(seconds: 30),
          Duration(seconds: 30),
          Duration(seconds: 30),
        ],
      );
    });
  });
}
