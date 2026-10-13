import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/src/ghost_file_format.dart';
import 'package:ghost_ui/src/ghost_rate_format.dart';

void main() {
  group('ghostFormatBinarySize', () {
    test('bytes render bare, mantissas trim their trailing zero', () {
      expect(ghostFormatBinarySize(512), '512 B');
      expect(ghostFormatBinarySize(2048), '2 KiB');
      expect(ghostFormatBinarySize(1500), '1.5 KiB');
    });

    test('divisor 1024 with IEC units on every platform', () {
      // 1000 B is under the binary divisor, so it renders bare — the
      // point of the IEC formatter is that decimal never applies.
      expect(ghostFormatBinarySize(1000), '1000 B');
      expect(ghostFormatBinarySize(1 << 20), '1 MiB');
      expect(ghostFormatBinarySize(1 << 30), '1 GiB');
      expect(ghostFormatBinarySize(1 << 40), '1 TiB');
      // Beyond the unit table the top unit keeps scaling.
      expect(ghostFormatBinarySize(1 << 50), '1024 TiB');
    });

    test('rounding never renders the divisor as a mantissa', () {
      // 1048575 B is 1023.999 KiB — rounds to the next unit, so it must
      // read "1 MiB", never "1024 KiB".
      expect(ghostFormatBinarySize(1048575), '1 MiB');
    });

    test('a missing size renders the unevaluated dash', () {
      expect(ghostFormatBinarySize(null), ghostUnevaluated);
    });
  });

  group('ghostFormatBinaryRate', () {
    test('binary size plus the /s suffix', () {
      expect(ghostFormatBinaryRate(2048), '2 KiB/s');
      expect(ghostFormatBinaryRate(512), '512 B/s');
      // A fractional rate rounds before the size renders.
      expect(ghostFormatBinaryRate(2048.4), '2 KiB/s');
    });
  });

  group('ghostFormatByteRate', () {
    test('follows the platform size convention plus /s', () {
      // Decimal on Linux: 1000 B/s is exactly one KB/s; binary on
      // Windows: it stays under the divisor and renders bare.
      expect(
        ghostFormatByteRate(1000, platform: TargetPlatform.linux),
        '1 KB/s',
      );
      expect(
        ghostFormatByteRate(1000, platform: TargetPlatform.windows),
        '1000 B/s',
      );
      expect(
        ghostFormatByteRate(1 << 20, platform: TargetPlatform.macOS),
        '1 MB/s',
      );
    });

    test('a fractional rate rounds before the size renders', () {
      expect(
        ghostFormatByteRate(2048.4, platform: TargetPlatform.linux),
        '2 KB/s',
      );
    });
  });

  group('ghostFormatCompactEta', () {
    test('renders seconds, minutes, hours, and days compactly', () {
      expect(ghostFormatCompactEta(const Duration(seconds: 45)), '45s');
      expect(ghostFormatCompactEta(const Duration(seconds: 260)), '4m 20s');
      expect(ghostFormatCompactEta(const Duration(seconds: 3780)), '1h 3m');
      expect(ghostFormatCompactEta(const Duration(hours: 53)), '2d 5h');
      expect(ghostFormatCompactEta(const Duration(days: 30)), '30d 0h');
    });

    test('a negative duration clamps to zero', () {
      expect(ghostFormatCompactEta(const Duration(seconds: -5)), '0s');
    });
  });

  group('ghostParseByteRate', () {
    const cap = 10 * 1000 * 1000 * 1000;
    int? parse(String input) =>
        ghostParseByteRate(input, maxBytesPerSecond: cap);

    test('rejects a magnitude whose byte product overflows to infinity', () {
      // double.parse saturates an over-range literal to Infinity, and
      // Infinity.round() throws — the field's inline-error contract
      // (invalid input is rejected, never clamped) must cover it.
      expect(parse('9' * 400), isNull);
    });

    test('parses bare numbers, decimal units, and an optional /s', () {
      expect(parse('2048'), 2048);
      expect(parse('2 KB'), 2000);
      expect(parse('1.5 MB/s'), 1500000);
      expect(parse('1,5 MB'), 1500000);
      expect(parse(' 5 MB/S '), 5000000);
    });

    test('rejects input the grammar does not cover', () {
      expect(parse('abc'), isNull);
      expect(parse('0'), isNull);
      // A positive sub-byte rate rounds to nothing — still rejected.
      expect(parse('0.4 B'), isNull);
      // The regex's iB spellings meet no unit-table entry.
      expect(parse('2 KiB'), isNull);
    });

    test('honours the caller-supplied ceiling', () {
      expect(parse('10 GB'), 10000000000);
      expect(parse('11 GB'), isNull);
    });
  });
}
