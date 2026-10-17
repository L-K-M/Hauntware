import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
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
  BundledMonoFont.cascadiaCode: 1200 / 2048,
  BundledMonoFont.victorMono: 600 / 1100,
  BundledMonoFont.lilex: 600 / 1000,
  BundledMonoFont.zeroXProto: 620 / 1000,
  BundledMonoFont.monaspaceNeon: 1240 / 2000,
  BundledMonoFont.monaspaceArgon: 1240 / 2000,
  BundledMonoFont.monaspaceXenon: 1240 / 2000,
  BundledMonoFont.monaspaceRadon: 1240 / 2000,
  BundledMonoFont.monaspaceKrypton: 1240 / 2000,
  BundledMonoFont.martianMono: 700 / 1000,
  BundledMonoFont.geistMono: 600 / 1000,
  BundledMonoFont.intelOneMono: 614 / 1000,
  BundledMonoFont.fragmentMono: 618 / 1000,
  BundledMonoFont.googleSansCode: 1200 / 2000,
  BundledMonoFont.commitMono: 600 / 1000,
  BundledMonoFont.departureMono: 350 / 550,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadBundledMonoFonts);

  test('Commit Mono enables both coding ligature sets by default', () async {
    final font = BundledMonoFont.commitMono;
    expect(
      await _render(
        font.family,
        '!= ->',
        features: MonoLigatures.on.featuresFor(font.family),
      ),
      await _render(
        font.family,
        '!= ->',
        features: const [ui.FontFeature('ss01'), ui.FontFeature('ss02')],
      ),
    );
    expect(font.hasProgrammingLigatures, isTrue);
  });

  group('each bundled family', () {
    for (final font in BundledMonoFont.values) {
      test('${font.displayName} is declared and fixed-width', () {
        // The test font draws every character 1 em wide, so a width at the
        // font's own advance proves the family was registered.
        for (final text in ['mmmmmmmmmm', 'iiiiiiiiii', '->=!<>|:;.']) {
          expect(
            _layout(
                  font.family,
                  text,
                  features: MonoLigatures.on.featuresFor(font.family),
                ).maxIntrinsicWidth /
                text.length,
            moreOrLessEquals(_advanceEm[font]! * _size, epsilon: 0.01),
            reason: text,
          );
        }
      });

      if (!font.hasProgrammingLigatures) continue;

      test(
        '${font.displayName} draws switchable programming ligatures',
        () async {
          final enabled = MonoLigatures.on.featuresFor(font.family);
          final disabled = MonoLigatures.off.featuresFor(font.family);
          final different = <String>[];
          for (final text in ['->', '!=', '===', '<=', '=>']) {
            if (!listEquals(
              await _render(font.family, text, features: enabled),
              await _render(font.family, text, features: disabled),
            )) {
              different.add(text);
            }
          }
          expect(
            different,
            isNotEmpty,
            reason: 'A real glyph change, not just a feature flag',
          );
          // Commit Mono's calt also applies smart kerning to plain letters.
          if (font == BundledMonoFont.commitMono) return;

          // The control: letters that never ligate draw the same either way.
          expect(
            await _render(font.family, 'ab', features: enabled),
            await _render(font.family, 'ab', features: disabled),
          );
        },
      );
    }
  });

  test(
    'release provenance covers the declared additional files unchanged',
    () async {
      final sources =
          jsonDecode(File('tool/font_releases.json').readAsStringSync())
              as List;
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      final declared = {
        for (final family in manifest)
          for (final face in family['fonts'] as List) face['asset'] as String,
      };
      for (final source in sources) {
        for (final family in source['families'] as List) {
          expect(BundledMonoFont.named(family['name'] as String), isNotNull);
          for (final face in family['files'] as List) {
            final path = face['path'] as String;
            expect(declared, contains(path));
            expect(
              sha256.convert(File(path).readAsBytesSync()).toString(),
              face['sha256'],
              reason: path,
            );
          }
        }
      }
    },
  );

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
