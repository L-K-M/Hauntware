import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:ghost_ui/src/ghost_file_format.dart';

void main() {
  setUpAll(() => initializeDateFormatting('en'));
  group('ghostFormatFileSize', () {
    test('bytes render bare, mantissas trim their trailing zero', () {
      expect(ghostFormatFileSize(512, platform: TargetPlatform.linux), '512 B');
      expect(ghostFormatFileSize(2048, platform: TargetPlatform.linux), '2 KB');
      expect(
        ghostFormatFileSize(1500, platform: TargetPlatform.linux),
        '1.5 KB',
      );
    });

    test('decimal units on macOS/Linux, binary on Windows', () {
      expect(
        ghostFormatFileSize(1 << 20, platform: TargetPlatform.linux),
        '1 MB',
      );
      expect(
        ghostFormatFileSize(1 << 20, platform: TargetPlatform.windows),
        '1 MB',
      );
      expect(
        ghostFormatFileSize(10 * 1000 * 1000, platform: TargetPlatform.macOS),
        '10 MB',
      );
      expect(
        ghostFormatFileSize(10 * 1024 * 1024, platform: TargetPlatform.windows),
        '10 MB',
      );
    });

    test('rounding never renders the divisor as a mantissa', () {
      expect(
        ghostFormatFileSize(999999, platform: TargetPlatform.macOS),
        '1 MB',
      );
      expect(
        ghostFormatFileSize(1048575, platform: TargetPlatform.windows),
        '1 MB',
      );
    });

    test('a missing size renders the unevaluated dash', () {
      expect(
        ghostFormatFileSize(null, platform: TargetPlatform.linux),
        ghostUnevaluated,
      );
    });
  });

  group('ghostFormatFileModified', () {
    final now = DateTime(2026, 3, 5, 14, 30);
    String fmt(DateTime? at) => ghostFormatFileModified(
      at,
      now: now,
      localeName: 'en',
      today: (t) => 'Today at $t',
      yesterday: (t) => 'Yesterday at $t',
    );

    test('null renders the unevaluated dash', () {
      expect(fmt(null), ghostUnevaluated);
    });

    test('today and yesterday carry the caller-supplied labels', () {
      expect(fmt(DateTime(2026, 3, 5, 9, 15)), startsWith('Today at '));
      expect(fmt(DateTime(2026, 3, 4, 23, 59)), startsWith('Yesterday at '));
    });

    test('older dates render absolute; future dates do not read today', () {
      final older = fmt(DateTime(2025, 12, 28, 22, 58));
      expect(older, isNot(startsWith('Today')));
      expect(older, isNot(startsWith('Yesterday')));
      expect(older, isNot(ghostUnevaluated));
      final future = fmt(DateTime(2026, 3, 6, 8));
      expect(future, isNot(startsWith('Today')));
    });
  });

  group('POSIX mode formatting', () {
    test('symbolic folds special bits into the execute slots', () {
      expect(ghostFormatPosixModeSymbolic(0x1FF), 'rwxrwxrwx');
      expect(ghostFormatPosixModeSymbolic(0x1A4), 'rw-r--r--');
      expect(ghostFormatPosixModeSymbolic(0x9ED), 'rwsr-xr-x');
      expect(ghostFormatPosixModeSymbolic(0x3ED), 'rwxr-xr-t');
      expect(ghostFormatPosixModeSymbolic(0), '---------');
    });

    test('octal renders four digits with the special-bits digit', () {
      expect(ghostFormatPosixModeOctal(0x1ED), '0755');
      expect(ghostFormatPosixModeOctal(0x1A4), '0644');
      expect(ghostFormatPosixModeOctal(0xBED), '5755');
      expect(ghostFormatPosixModeOctal(0xFFFF), '7777');
    });
  });

  group('ghostFileNameIsFlagged', () {
    test('a U+FFFD name is flagged, a clean name is not', () {
      expect(ghostFileNameIsFlagged('log�file'), isTrue);
      expect(ghostFileNameIsFlagged('log file.txt'), isFalse);
    });
  });
}
