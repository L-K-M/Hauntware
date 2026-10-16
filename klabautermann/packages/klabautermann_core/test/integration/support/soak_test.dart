// The soak's budgets, configuration and parsers (03 §11.4, K28b),
// checked without the fixture.
import 'package:test/test.dart';

import 'soak.dart';

void main() {
  test('the fast-tick budget is 2.5 KB up to 32 CPUs, then 30 B per CPU '
      '(03 §11.4, D48)', () {
    expect(fastTickByteBudget(4), 2500);
    expect(fastTickByteBudget(32), 2500);
    expect(fastTickByteBudget(33), 2530);
    expect(fastTickByteBudget(64), 2500 + 32 * 30);
  });

  group('SoakConfig', () {
    test('is absent without KLABAUTERMANN_SOAK_SECONDS', () {
      expect(SoakConfig.fromEnvironment(const {}), isNull);
    });

    test('warms up for a tenth of the window, from 10 to 60 s, and reads '
        'twenty times', () {
      final ci = SoakConfig.fromEnvironment(const {
        'KLABAUTERMANN_SOAK_SECONDS': '600',
        'KLABAUTERMANN_SOAK_DIR': '/evidence/soak',
      })!;
      expect(ci.window, const Duration(minutes: 10));
      expect(ci.warmup, const Duration(seconds: 60));
      expect(ci.interval, const Duration(seconds: 30));
      expect(ci.evidenceDirectory, '/evidence/soak');

      final smoke = SoakConfig.fromEnvironment(const {
        'KLABAUTERMANN_SOAK_SECONDS': '60',
        'KLABAUTERMANN_SOAK_DIR': '/evidence/soak',
      })!;
      expect(smoke.warmup, const Duration(seconds: 10));
      expect(smoke.interval, const Duration(seconds: 3));

      final long = SoakConfig.fromEnvironment(const {
        'KLABAUTERMANN_SOAK_SECONDS': '3600',
        'KLABAUTERMANN_SOAK_DIR': '/evidence/soak',
      })!;
      expect(long.warmup, const Duration(seconds: 60));
    });

    test('refuses what run.sh would refuse, and a relative directory', () {
      for (final seconds in ['0', '-5', '1.5', '010', 'ten', '']) {
        expect(
          () => SoakConfig.fromEnvironment({
            'KLABAUTERMANN_SOAK_SECONDS': seconds,
            'KLABAUTERMANN_SOAK_DIR': '/evidence/soak',
          }),
          throwsFormatException,
          reason: seconds,
        );
      }
      for (final directory in [null, '', 'build/soak']) {
        expect(
          () => SoakConfig.fromEnvironment({
            'KLABAUTERMANN_SOAK_SECONDS': '60',
            'KLABAUTERMANN_SOAK_DIR': ?directory,
          }),
          throwsFormatException,
          reason: directory,
        );
      }
    });
  });

  group('growthOf', () {
    test('compares the medians of the first and last thirds', () {
      final growth = growthOf('fds', [
        36,
        36,
        99,
        36,
        36,
        36,
        37,
        37,
        37,
      ], tolerance: 0);
      expect(growth.first, 36);
      expect(growth.last, 37);
      expect(growth.growth, 1);
      expect(growth.ok, isFalse);
    });

    test('lets one odd reading pass', () {
      final growth = growthOf('fds', [
        36,
        36,
        36,
        36,
        36,
        36,
        36,
        44,
        36,
      ], tolerance: 0);
      expect(growth.ok, isTrue);
    });

    test('catches a steady rise inside the tolerance of each step', () {
      final growth = growthOf('heap', [
        for (var i = 0; i < 21; i++) 1000 + 100 * i,
      ], tolerance: 1000);
      expect(growth.growth, 1400);
      expect(growth.ok, isFalse);
    });

    test('needs three readings', () {
      expect(() => growthOf('x', [1, 2], tolerance: 0), throwsArgumentError);
    });
  });

  test('countStats gives count, extremes, lower median and mean', () {
    expect(countStats([]), isEmpty);
    expect(countStats([440, 986, 989, 440]), {
      'count': 4,
      'min': 440,
      'median': 440,
      'max': 989,
      'mean': 713.75,
    });
  });

  test('parseShellStats reads pid, ppid and CPU with waited-for children, '
      'whatever comm holds', () {
    // proc(5): pid (comm) state ppid ... utime(14) stime(15) cutime(16)
    // cstime(17) ...
    const sh =
        '54 (sh) S 52 54 54 0 -1 4194560 1100 0 0 0 31 14 2 1 20 0 1 0 '
        '1234 1716224 380 18446744073709551615';
    const odd =
        '77 (a) b (c)) R 1 77 77 0 -1 0 0 0 0 0 5 6 0 0 20 0 1 0 9 0 0 0';
    expect(parseShellStats('$sh\n$odd\n\n'), [
      (pid: 54, ppid: 52, cpuTicks: 31 + 14 + 2 + 1),
      (pid: 77, ppid: 1, cpuTicks: 11),
    ]);
  });

  test('fastShells takes each connection\'s newer shell', () {
    expect(
      fastShells([
        (pid: 53, ppid: 52, cpuTicks: 0),
        (pid: 54, ppid: 52, cpuTicks: 5),
        (pid: 112, ppid: 110, cpuTicks: 0),
        (pid: 111, ppid: 110, cpuTicks: 0),
      ]),
      {54, 112},
    );
  });

  test('parseSsTcpInfo reads each connection\'s payload bytes', () {
    // iproute2 7.2's `ss -tinH state established`, trimmed.
    const output =
        '0      0      127.0.0.1:43276     127.0.0.1:2241\n'
        '\t bbr wscale:10,10 rto:204 cwnd:21 bytes_sent:3554 '
        'bytes_retrans:21 bytes_acked:3534 bytes_received:1181 '
        'segs_out:271\n'
        '0      0      127.0.0.1:43290     127.0.0.1:2241\n'
        '\t cubic bytes_sent:10 bytes_acked:10 bytes_received:20\n'
        '0      0      127.0.0.1:43300     127.0.0.1:2241\n'
        '\t cubic segs_out:3\n';
    expect(parseSsTcpInfo(output), {
      '127.0.0.1:43276': (sent: 3554, received: 1181),
      '127.0.0.1:43290': (sent: 10, received: 20),
    });
  });
}
