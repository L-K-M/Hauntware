import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// `fontFamily: 'monospace'` is a real family only on Linux and Android.
// CoreText and DirectWrite skip the name and draw the proportional system
// font, so code text uses SeanceTheme.mono instead.
final _bareMonospace = RegExp(r'''fontFamily:\s*['"]monospace['"]''');

void main() {
  test('no code text names the bare monospace family', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      for (final (index, line) in entity.readAsLinesSync().indexed) {
        if (line.trimLeft().startsWith('//')) continue;
        if (!_bareMonospace.hasMatch(line)) continue;

        offenders.add('${entity.path}:${index + 1}');
      }
    }

    expect(offenders, isEmpty);
  });
}
