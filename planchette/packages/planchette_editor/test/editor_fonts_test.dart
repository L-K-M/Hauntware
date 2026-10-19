import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:planchette_editor/planchette_editor.dart';

TextStyle documentStyle(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
    .style!;

Future<void> mount(
  WidgetTester tester, {
  TextStyle? style,
  ThemeData? theme,
}) async {
  final c = EditorController(displayPath: 'a.txt', initialText: 'text');
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: style == null
            ? PlanchetteEditor(controller: c)
            : PlanchetteEditor(controller: c, textStyle: style),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final bundled = BundledMonoFont.jetBrainsMono.family;

  test('font-specific coding ligatures follow the editor switch', () {
    final style = TextStyle(fontFamily: BundledMonoFont.geistMono.family);
    expect(
      EditorLigatures.on.applyTo(style).fontFeatures,
      contains(const FontFeature('ss11')),
    );
    expect(
      EditorLigatures.off.applyTo(style).fontFeatures,
      contains(const FontFeature.disable('ss11')),
    );
  });

  // Each platform's first own face behind the bundled family.
  const platformFace = {
    TargetPlatform.macOS: 'Menlo',
    TargetPlatform.iOS: 'Menlo',
    TargetPlatform.windows: 'Cascadia Mono',
    TargetPlatform.linux: 'DejaVu Sans Mono',
    TargetPlatform.android: 'DejaVu Sans Mono',
    TargetPlatform.fuchsia: 'DejaVu Sans Mono',
  };

  testWidgets('the document draws bundled JetBrains Mono on each platform', (
    tester,
  ) async {
    await mount(tester);
    final style = documentStyle(tester);
    expect(style.fontFamily, bundled);
    expect(style.fontFamilyFallback!.take(2), [
      bundled,
      platformFace[defaultTargetPlatform],
    ]);
    // Every stack ends in the generic family where the platform has one.
    expect([
      style.fontFamily,
      ...style.fontFamilyFallback!,
    ], contains('monospace'));
    expect(style.fontSize, 14);
    expect(style.height, 1.35);
  }, variant: TargetPlatformVariant(platformFace.keys.toSet()));

  testWidgets('a host family and size replace the defaults', (tester) async {
    await mount(
      tester,
      style: const TextStyle(fontFamily: 'Host Mono', fontSize: 18),
    );
    final style = documentStyle(tester);
    expect(style.fontFamily, 'Host Mono');
    expect(style.fontSize, 18);
    expect(style.height, 1.35);
    // The editor's stack remains behind a host family that may be missing.
    expect(style.fontFamilyFallback!.first, bundled);
  });

  testWidgets("a bundled font's name draws the bundled copy", (tester) async {
    // As a settings file stores it: the display name, any case.
    await mount(tester, style: const TextStyle(fontFamily: ' iosevka term'));
    final style = documentStyle(tester);
    expect(style.fontFamily, BundledMonoFont.iosevkaTerm.family);
    expect(style.fontFamilyFallback!.first, bundled);
  });

  // Ported from #15.
  testWidgets('a size-only host style keeps the editor family', (tester) async {
    await mount(tester, style: const TextStyle(fontSize: 16));
    final style = documentStyle(tester);
    expect(style.fontFamily, bundled);
    expect(style.fontSize, 16);
  });

  testWidgets('the generic monospace name means the editor family', (
    tester,
  ) async {
    // Hosts written for the old default pass the generic name, which only
    // fontconfig and Android resolve.
    for (final generic in ['monospace', 'Monospace']) {
      await mount(tester, style: TextStyle(fontFamily: generic));
      expect(documentStyle(tester).fontFamily, bundled);
      expect(documentStyle(tester).fontFamilyFallback, isNotEmpty);
    }
  });

  testWidgets('the family follows the operating system, not the theme', (
    tester,
  ) async {
    // Installed fonts belong to the OS; a theme may style another platform.
    await mount(tester, theme: ThemeData(platform: TargetPlatform.android));
    expect(documentStyle(tester).fontFamilyFallback, contains('Menlo'));
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  test('review fix: every platform falls back to a fixed-width face', () {
    // A host family replaces the first choice; if it is not installed and
    // no listed face is either, the generic alias still finds one.
    for (final platform in TargetPlatform.values) {
      expect(
        editorMonospaceFor(platform).fontFamilyFallback,
        contains('monospace'),
        reason: '$platform',
      );
    }
  });

  test('no editor text names the bare monospace family', () {
    // A real family only on Linux and Android; elsewhere the name draws the
    // proportional system font. Code text takes the editor's style.
    final bare = RegExp(r'''fontFamily:\s*['"]monospace['"]''');
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      for (final (index, line) in entity.readAsLinesSync().indexed) {
        if (line.trimLeft().startsWith('//')) continue;
        if (!bare.hasMatch(line)) continue;

        offenders.add('${entity.path}:${index + 1}');
      }
    }

    expect(offenders, isEmpty);
  });
}
