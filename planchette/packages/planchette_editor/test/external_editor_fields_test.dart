import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  group('normalizeEditorExtensions', () {
    test('strips dots, globs and case, dedupes and sorts', () {
      expect(
        normalizeEditorExtensions([' .DART ', '*.tar.gz', 'json', '.dart', '']),
        ['dart', 'json', 'tar.gz'],
      );
    });

    test('refuses entries that name a path or a pattern', () {
      for (final value in ['../sh', r'a\b', 'a*b', 'a?', 'a\u0000']) {
        expect(
          () => normalizeEditorExtensions([value]),
          throwsFormatException,
          reason: value,
        );
      }
    });

    test('refuses an extension longer than 32 characters', () {
      expect(normalizeEditorExtensions(['a' * 32]), ['a' * 32]);
      expect(
        () => normalizeEditorExtensions(['a' * 33]),
        throwsFormatException,
      );
    });

    test('allows at most 64 extensions', () {
      final allowed = [for (var i = 0; i < 64; i++) 'e$i'];
      expect(normalizeEditorExtensions(allowed), hasLength(64));
      expect(
        () => normalizeEditorExtensions([...allowed, 'e64']),
        throwsFormatException,
      );
    });
  });

  group('validateEditorDisplayName', () {
    test('trims a valid name', () {
      expect(validateEditorDisplayName('  BBEdit '), 'BBEdit');
    });

    test('refuses non-strings, blanks, control characters and long names', () {
      for (final value in [null, 3, '   ', 'a\nb', 'a' * 101]) {
        expect(
          () => validateEditorDisplayName(value),
          throwsFormatException,
          reason: '$value',
        );
      }
      expect(validateEditorDisplayName('a' * 100), 'a' * 100);
    });
  });
}
