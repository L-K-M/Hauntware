import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The ghost_ui formatters that print decimal units on macOS and Linux:
/// `ghostFormatFileSize` and `ghostFormatByteRate`, which wraps it.
const _decimalFormatters = ['ghostFormatFileSize', 'ghostFormatByteRate'];

/// The 1-based numbers of [lines] that name a decimal formatter in code.
List<int> _decimalFormatterLines(List<String> lines) => [
  for (final (index, line) in lines.indexed)
    // Comments may name one to warn against it.
    if (_decimalFormatters.any(line.split('//').first.contains)) index + 1,
];

/// A11Y-06 and 03 §10.10: server figures are IEC binary units through the
/// chart formatters (`formatChartValue`, `ghostFormatBinarySize`,
/// `ghostFormatBinaryRate`). A byte count or rate a decimal formatter
/// prints would disagree with the server's own tools; the app shows no
/// local file sizes or transfer rates, so nothing in lib/ calls one.
void main() {
  test('the check finds every decimal formatter, outside comments', () {
    expect(
      _decimalFormatterLines([
        'final size = ghostFormatFileSize(bytes, platform: platform);',
        'final rate = ghostFormatByteRate(bytes, platform: platform);',
        "import 'package:ghost_ui/ghost_ui.dart' show ghostFormatByteRate;",
        '// Not ghostFormatFileSize or ghostFormatByteRate: they are decimal.',
        'final rate = ghostFormatBinaryRate(bytes);',
      ]),
      [1, 2, 3],
    );
  });

  test('no server figure goes through a decimal formatter', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final line in _decimalFormatterLines(entity.readAsLinesSync())) {
        offenders.add('${entity.path}:$line');
      }
    }
    expect(offenders, isEmpty);
  });
}
