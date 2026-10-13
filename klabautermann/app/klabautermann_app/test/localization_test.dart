import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A minimal localization contract (03 §10.10, A11Y-05): every ARB key is
/// referenced from `lib/`, and user-facing widgets take no literal strings.
/// The shared scanner `tool/l10n_contract` replaces this when F1b lands
/// (03 D35), so this stays deliberately small: it greps sources rather
/// than walking the AST like Poltergeist's contract test does.
void main() {
  final arb =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, Object?>;
  final keys = arb.keys
      .where((key) => !key.startsWith('@'))
      .toList(growable: false);

  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (file) =>
            file.path.endsWith('.dart') &&
            // gen-l10n output names every key by construction.
            !file.path.contains('app_localizations'),
      )
      .map((file) => file.readAsStringSync())
      .join('\n');

  test('the catalogue is non-empty', () {
    expect(keys, isNotEmpty);
  });

  test('every ARB key is used by lib/', () {
    for (final key in keys) {
      expect(
        RegExp('\\b$key\\b').hasMatch(sources),
        isTrue,
        reason: 'ARB key "$key" is never referenced in lib/',
      );
    }
  });

  test('no user-facing widget takes a string literal', () {
    // The params and widgets a screen reader or the paint path reaches.
    final literalUse = RegExp(
      r'''\b(Text|text|title|subtitle|label|tooltip|hintText|semanticLabel)\s*[(=:]\s*['"][^'"]''',
    );
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      if (file.path.contains('app_localizations')) continue;
      final match = literalUse.firstMatch(file.readAsStringSync());
      expect(
        match,
        isNull,
        reason:
            '${file.path} carries a literal into a user-facing slot: '
            '${match?[0]}',
      );
    }
  });
}
