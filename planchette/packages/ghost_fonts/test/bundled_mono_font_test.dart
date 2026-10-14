import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';
import 'package:ghost_fonts/testing.dart';

const double _size = 100;

ui.Paragraph _layout(
  String family,
  String text, {
  List<ui.FontFeature>? features,
}) {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: _size))
    ..pushStyle(
      ui.TextStyle(fontFamily: family, fontSize: _size, fontFeatures: features),
    )
    ..addText(text);
  return builder.build()..layout(const ui.ParagraphConstraints(width: 1e6));
}

/// The pixels of [text] drawn in [family].
Future<Uint8List> _render(
  String family,
  String text, {
  List<ui.FontFeature>? features,
}) async {
  final paragraph = _layout(family, text, features: features);
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawParagraph(paragraph, ui.Offset.zero);
  final image = await recorder.endRecording().toImage(
    paragraph.maxIntrinsicWidth.ceil(),
    paragraph.height.ceil(),
  );
  final bytes = await image.toByteData();
  return bytes!.buffer.asUint8List();
}

/// Each font's advance in em, from its own metrics: the units per em and
/// the advance every ASCII glyph shares.
const _advanceEm = {
  BundledMonoFont.iosevkaTerm: 500 / 1000,
  BundledMonoFont.jetBrainsMono: 600 / 1000,
  BundledMonoFont.firaCode: 1200 / 1950,
  BundledMonoFont.mapleMono: 600 / 1000,
};

/// Contextual alternates off: what a "no ligatures" setting turns off.
const _noLigatures = [ui.FontFeature.disable('calt')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadBundledMonoFonts);

  group('each bundled family', () {
    for (final font in BundledMonoFont.values) {
      test('${font.displayName} is declared and fixed-width', () {
        // The test font draws every character 1 em wide, so a width at the
        // font's own advance proves the family was registered.
        for (final text in ['mmmmmmmmmm', 'iiiiiiiiii', '->=!<>|:;.']) {
          expect(
            _layout(font.family, text).maxIntrinsicWidth / text.length,
            moreOrLessEquals(_advanceEm[font]! * _size, epsilon: 0.01),
            reason: text,
          );
        }
      });

      test('${font.displayName} draws ligatures', () async {
        // calt is how all four ligate; the Iosevka subset must keep it.
        for (final text in ['->', '!=', '===']) {
          expect(
            await _render(font.family, text),
            isNot(await _render(font.family, text, features: _noLigatures)),
            reason: text,
          );
        }
        // The control: letters that never ligate draw the same either way.
        expect(
          await _render(font.family, 'ab'),
          await _render(font.family, 'ab', features: _noLigatures),
        );
      });
    }
  });

  test('named matches display names loosely and nothing else', () {
    expect(BundledMonoFont.named('Iosevka Term'), BundledMonoFont.iosevkaTerm);
    expect(BundledMonoFont.named('  fira code '), BundledMonoFont.firaCode);
    expect(BundledMonoFont.named('JetBrains Mono NL'), isNull);
    expect(BundledMonoFont.named(''), isNull);
  });

  test('resolveMonoFamily prefers the bundled copy', () {
    expect(resolveMonoFamily('maple mono'), 'packages/ghost_fonts/Maple Mono');
    expect(resolveMonoFamily(' Menlo '), 'Menlo');
  });

  test('the shared stack starts with bundled JetBrains Mono', () {
    expect(ghostMonoFontFamily, BundledMonoFont.jetBrainsMono.family);
    expect(ghostMonoFontFamilies.first, ghostMonoFontFamily);
    expect(ghostMonoFontFamilies.last, 'monospace');
  });

  test("LICENSE carries each font's licence into the app NOTICES", () {
    // Flutter's build splits a package LICENSE on lines of 80 hyphens; each
    // chunk opens with the names it covers and a blank line. The fonts are
    // OFL, which requires its text to travel with them, and the suite's
    // licence gate does not look here, so this is the check.
    final chunks = File('LICENSE').readAsStringSync().split('\n${'-' * 80}\n');
    final byName = {
      for (final chunk in chunks)
        chunk.substring(0, chunk.indexOf('\n\n')): chunk,
    };
    expect(byName['ghost_fonts'], contains('unlicense.org'));
    for (final font in BundledMonoFont.values) {
      expect(
        byName[font.displayName],
        allOf(contains('Copyright'), contains('SIL Open Font License')),
        reason: font.displayName,
      );
    }
  });
}
