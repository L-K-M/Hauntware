/// Test support: draws the bundled fonts in widget and painting tests.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

import 'src/bundled_mono_font.dart';

/// Registers the bundled families with the engine under the names apps use
/// ([BundledMonoFont.family]).
///
/// An app gets them from its font manifest at start-up, but flutter_test
/// draws every family in its own square test font. A test that measures or
/// paints real glyphs awaits this first (inside `tester.runAsync` in a
/// widget test). Reads the manifest rather than a file list, so a family
/// missing from the pubspec fails the tests that need it.
Future<void> loadBundledMonoFonts() async {
  try {
    await (_loaded ??= _load());
  } catch (_) {
    // Not remembered: a later call, say after the binding is up, retries.
    _loaded = null;
    rethrow;
  }
}

Future<void>? _loaded;

Future<void> _load() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json'));
  for (final entry
      in (manifest as List<Object?>).cast<Map<String, Object?>>()) {
    // 'packages/ghost_fonts/<family>' in a dependent's bundle, the bare
    // family in this package's own tests.
    final declared = entry['family']! as String;
    final font = BundledMonoFont.named(declared.split('/').last);
    if (font == null) continue;

    final loader = FontLoader(font.family);
    for (final face
        in (entry['fonts']! as List<Object?>).cast<Map<String, Object?>>()) {
      loader.addFont(rootBundle.load(face['asset']! as String));
    }
    await loader.load();
  }
}
