// The core barrel's `show` lists are the app's only reach into the
// engine packages (03 §3.2): a name is shown because some file under
// app/ names it. This contract reads every `show` list and fails for a
// shown name nothing under lib/ or test/ uses, so retiring a type means
// dropping its export rather than leaving it reachable to no one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Shown names kept with no user under app/. Empty today; a name belongs
/// here only with the reason it stays, such as a harness outside test/.
const _keptWithoutUser = <String>{};

void main() {
  test('every name the core barrel shows is named under app/', () {
    final barrel = File(
      '../../packages/klabautermann_core/lib/klabautermann_core.dart',
    );
    expect(barrel.existsSync(), isTrue, reason: barrel.path);

    final shown = RegExp(r"export\s+'[^']+'\s+show\s+([^;]+);")
        .allMatches(barrel.readAsStringSync())
        .expand((match) => match.group(1)!.split(','))
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();

    // The parse found the lists: EngineStart is always shown.
    expect(shown, contains('EngineStart'));

    final sources = [
      for (final directory in ['lib', 'test'])
        for (final entity in Directory(directory).listSync(recursive: true))
          if (entity is File && entity.path.endsWith('.dart')) entity,
    ];
    final text = {
      for (final file in sources) file.path: file.readAsStringSync(),
    };

    final orphans =
        shown
            .where((name) => !_keptWithoutUser.contains(name))
            .where(
              (name) => !text.values.any(
                (source) => RegExp('\\b$name\\b').hasMatch(source),
              ),
            )
            .toList()
          ..sort();

    expect(
      orphans,
      isEmpty,
      reason: 'shown with no user under app/: ${orphans.join(', ')}',
    );
  });
}
