import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:poltergeist_core/src/browse/unicode_simple_fold.dart';
import 'package:test/test.dart';

const _unicodeMaximum = 0x10ffff;
const _surrogateStart = 0xd800;
const _surrogateEnd = 0xdfff;
const _scalarBatchSize = 4096;
const _fullMappingCount = 1585;
const _defaultIgnorableRangeCount = 27;
const _defaultIgnorableCodePointCount = 4174;
const _commonFoldStatus = 'C';
const _fullFoldStatus = 'F';
const _simpleFoldStatus = 'S';
const _sourceSha256 =
    'ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183';
const _defaultIgnorableSha256 =
    'fdfaaeddf73e63079c237c9e5f8c1a4be88391de0d8b3974093fad6f694c8a1f';

void main() {
  test('folds ASCII, Latin, Greek, Cyrillic, Armenian, and Georgian', () {
    expect(simpleCaseFold('File-ÀÉŒ-Σςσ-ЖЙ-ԱԲ-ᲐᲑ'), 'file-àéœ-σσσ-жй-աբ-აბ');
  });

  test('folds supplementary scripts without splitting surrogate pairs', () {
    expect(
      simpleCaseFold('\u{10400}\u{104b0}\u{10c80}\u{1e900}'),
      '\u{10428}\u{104d8}\u{10cc0}\u{1e922}',
    );
  });

  test('Cherokee folds to uppercase, including its lowercase tail', () {
    expect(simpleCaseFold('Ꭰꭰ\u13f0\u13f8'), 'ᎠᎠ\u13f0\u13f0');
  });

  test('folds compatibility letters and capital sharp S', () {
    expect(simpleCaseFold('KKkÅÅſSµΜẞß'), 'kkkååssμμßß');
  });

  test('excludes Turkic tailoring and full multi-character expansions', () {
    expect(simpleCaseFold('Iİıißﬀﬃǰΐ'), 'iİıißﬀﬃǰΐ');
    expect(simpleCaseFold('ẞ'), isNot(simpleCaseFold('SS')));
  });

  test('preserves normalization, uncased text, and unpaired surrogates', () {
    expect(simpleCaseFold('ÉE\u0301中文😀'), 'ée\u0301中文😀');
    expect(simpleCaseFold(''), '');
    expect(simpleCaseFold('\ud800A\udfff'), '\ud800a\udfff');
  });

  test('matches pinned C and S mappings and every unmapped scalar', () async {
    final package = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
    );
    if (package == null) {
      fail('Could not resolve poltergeist_core; run tests from source.');
    }

    final source = File.fromUri(
      package.resolve('../tool/unicode/CaseFolding-17.0.0.txt'),
    );
    final bytes = await source.readAsBytes();
    expect(sha256.convert(bytes).toString(), _sourceSha256);

    final mappings = <int, int>{};
    for (final line in await source.readAsLines()) {
      if (line.isEmpty || line.startsWith('#')) continue;

      final fields = line.split(';').map((field) => field.trim()).toList();
      if (fields[1] != _commonFoldStatus && fields[1] != _simpleFoldStatus) {
        continue;
      }

      expect(fields[2].split(' '), hasLength(1));
      mappings[int.parse(fields[0], radix: 16)] = int.parse(
        fields[2],
        radix: 16,
      );
    }
    expect(mappings, hasLength(1512));

    // Check gaps too: compressed ranges must never fold an unlisted scalar.
    for (var start = 0; start <= _unicodeMaximum; start += _scalarBatchSize) {
      final input = StringBuffer();
      final expected = StringBuffer();
      final end = (start + _scalarBatchSize - 1).clamp(0, _unicodeMaximum);
      for (var point = start; point <= end; point++) {
        if (point >= _surrogateStart && point <= _surrogateEnd) continue;

        input.writeCharCode(point);
        expected.writeCharCode(mappings[point] ?? point);
      }
      final folded = simpleCaseFold(input.toString());
      expect(
        folded,
        expected.toString(),
        reason: 'batch U+${start.toRadixString(16)}',
      );
      expect(simpleCaseFold(folded), folded, reason: 'folding is idempotent');
    }
  });

  test('full folding matches every pinned C and F mapping', () async {
    final package = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
    );
    if (package == null) {
      fail('Could not resolve poltergeist_core; run tests from source.');
    }

    final source = File.fromUri(
      package.resolve('../tool/unicode/CaseFolding-17.0.0.txt'),
    );
    final bytes = await source.readAsBytes();
    expect(sha256.convert(bytes).toString(), _sourceSha256);

    final mappings = <int, List<int>>{};
    for (final line in await source.readAsLines()) {
      if (line.isEmpty || line.startsWith('#')) continue;

      final fields = line.split(';').map((field) => field.trim()).toList();
      if (fields[1] != _commonFoldStatus && fields[1] != _fullFoldStatus) {
        continue;
      }

      mappings[int.parse(fields[0], radix: 16)] = fields[2]
          .split(' ')
          .map((value) => int.parse(value, radix: 16))
          .toList();
    }
    expect(mappings, hasLength(_fullMappingCount));

    for (final MapEntry(key: source, value: targets) in mappings.entries) {
      final folded = fullCaseFold(String.fromCharCode(source));
      expect(folded, String.fromCharCodes(targets));
      expect(fullCaseFold(folded), folded, reason: 'folding is idempotent');
    }
  });

  test('removes every pinned default ignorable and no other scalar', () async {
    final package = await Isolate.resolvePackageUri(
      Uri.parse('package:poltergeist_core/poltergeist_core.dart'),
    );
    if (package == null) {
      fail('Could not resolve poltergeist_core; run tests from source.');
    }

    final source = File.fromUri(
      package.resolve('../tool/unicode/DefaultIgnorable-17.0.0.txt'),
    );
    final bytes = await source.readAsBytes();
    expect(sha256.convert(bytes).toString(), _defaultIgnorableSha256);

    final ranges = <({int start, int end})>[];
    for (final line in await source.readAsLines()) {
      if (line.isEmpty || line.startsWith('#')) continue;

      final fields = line.split(';');
      final bounds = fields.first.trim().split('..');
      final start = int.parse(bounds.first, radix: 16);
      ranges.add((
        start: start,
        end: bounds.length == 1 ? start : int.parse(bounds.last, radix: 16),
      ));
    }
    expect(ranges, hasLength(_defaultIgnorableRangeCount));
    expect(
      ranges.fold<int>(0, (sum, range) => sum + range.end - range.start + 1),
      _defaultIgnorableCodePointCount,
    );

    var rangeIndex = 0;
    for (var start = 0; start <= _unicodeMaximum; start += _scalarBatchSize) {
      final input = StringBuffer();
      final expected = StringBuffer();
      final end = (start + _scalarBatchSize - 1).clamp(0, _unicodeMaximum);
      for (var point = start; point <= end; point++) {
        if (point >= _surrogateStart && point <= _surrogateEnd) continue;

        while (rangeIndex < ranges.length && point > ranges[rangeIndex].end) {
          rangeIndex++;
        }
        final ignored =
            rangeIndex < ranges.length && point >= ranges[rangeIndex].start;
        input.writeCharCode(point);
        if (!ignored) expected.writeCharCode(point);
      }
      expect(
        removeDefaultIgnorableCodePoints(input.toString()),
        expected.toString(),
        reason: 'batch U+${start.toRadixString(16)}',
      );
    }
  });
}
