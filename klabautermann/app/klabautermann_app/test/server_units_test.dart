import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A11Y-06 and 03 §10.10: server figures are IEC binary units through the
/// chart formatters (`formatChartValue`, `ghostFormatBinarySize`,
/// `ghostFormatBinaryRate`). `ghostFormatFileSize` is decimal on macOS and
/// Linux, so a byte count it formats would disagree with the server's own
/// tools; the app shows no local file sizes, so nothing in lib/ calls it.
void main() {
  test('no server figure goes through ghostFormatFileSize', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (final (index, line) in lines.indexed) {
        // Comments may name it to warn against it.
        final code = line.split('//').first;
        if (code.contains('ghostFormatFileSize')) {
          offenders.add('${entity.path}:${index + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
