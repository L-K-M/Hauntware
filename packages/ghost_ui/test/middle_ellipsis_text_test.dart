// Ported from Poltergeist app/poltergeist_app/test/ui/middle_ellipsis_text_test.dart
// (itself Séance's @ 15d0fdd).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

Widget _host(double width, String text) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: MiddleEllipsisText(text)),
    ),
  ),
);

String _shown(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byType(MiddleEllipsisText),
        matching: find.byType(Text),
      ),
    )
    .data!;

void _expectWholeGraphemes(String original, String shown) {
  if (shown == original) return;

  final parts = shown.split('…');
  expect(parts, hasLength(2));
  final graphemes = Characters(original).toList(growable: false);
  expect(
    [for (var i = 0; i <= graphemes.length; i++) graphemes.take(i).join()],
    contains(parts.first),
    reason: 'The visible head must end on a grapheme boundary: $shown',
  );
  expect(
    [for (var i = 0; i <= graphemes.length; i++) graphemes.skip(i).join()],
    contains(parts.last),
    reason: 'The visible tail must start on a grapheme boundary: $shown',
  );
}

Future<void> _expectSafeAcrossWidths(WidgetTester tester, String text) async {
  var keptBothEnds = false;
  for (var width = 4.0; width <= 180; width += 4) {
    await tester.pumpWidget(_host(width, text));
    final shown = _shown(tester);
    _expectWholeGraphemes(text, shown);
    if (shown != text) {
      final parts = shown.split('…');
      keptBothEnds |= parts.first.isNotEmpty && parts.last.isNotEmpty;
    }
  }
  expect(keptBothEnds, isTrue);
}

void main() {
  testWidgets('shows the full name when it fits', (tester) async {
    await tester.pumpWidget(_host(1000, 'short-name'));
    expect(_shown(tester), 'short-name');
  });

  testWidgets('measures with the merged style Text actually renders', (
    tester,
  ) async {
    // The rendered Text is DefaultTextStyle.merge(style); the ambient
    // letterSpacing makes that much wider than the raw style, so a slot
    // between the two widths only overflows if measurement merges too.
    const ambient = TextStyle(fontSize: 10, letterSpacing: 50);
    const style = TextStyle(fontSize: 20);
    const name = 'somewhat-long-name';
    final raw = TextPainter(
      text: const TextSpan(text: name, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final merged = TextPainter(
      text: TextSpan(text: name, style: ambient.merge(style)),
      textDirection: TextDirection.ltr,
    )..layout();
    addTearDown(() {
      raw.dispose();
      merged.dispose();
    });
    expect(merged.width, greaterThan(raw.width));
    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTextStyle(
          style: ambient,
          child: Center(
            child: SizedBox(
              width: (raw.width + merged.width) / 2,
              child: const MiddleEllipsisText(name, style: style),
            ),
          ),
        ),
      ),
    );
    // The merged rendering overflows the slot, so it must truncate;
    // measuring with the unmerged style would report a false fit.
    expect(_shown(tester), contains('…'));
    _expectWholeGraphemes(name, _shown(tester));
  });

  testWidgets('truncates in the middle, keeping both ends', (tester) async {
    const long = 'prod-web-server-01.eu-west-1.example.internal';
    await tester.pumpWidget(_host(90, long));
    final shown = _shown(tester);
    expect(shown, contains('…'));
    expect(shown.length, lessThan(long.length));
    final head = shown.split('…').first;
    final tail = shown.split('…').last;
    expect(long.startsWith(head), isTrue);
    expect(long.endsWith(tail), isTrue);
    // A middle ellipsis preserves the distinguishing tail, unlike end-ellipsis.
    expect(tail.isNotEmpty, isTrue);
  });

  testWidgets('does not split surrogate-pair emoji', (tester) async {
    await _expectSafeAcrossWidths(tester, 'alpha-😀-bravo-🚀-charlie');
  });

  testWidgets('does not split combining-mark graphemes', (tester) async {
    await _expectSafeAcrossWidths(
      tester,
      'cafe\u0301-server-na\u0308me-re\u0301mote',
    );
  });

  testWidgets('does not split flag graphemes', (tester) async {
    await _expectSafeAcrossWidths(tester, 'region-🇺🇸-server-🇨🇦-backup');
  });

  testWidgets('does not split family ZWJ graphemes', (tester) async {
    await _expectSafeAcrossWidths(
      tester,
      'home-👨‍👩‍👧‍👦-server-👩‍👩‍👦-backup',
    );
  });

  testWidgets('uses the full label for accessibility when truncated', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      const full = 'production-server-with-a-long-accessible-label';

      await tester.pumpWidget(_host(70, full));

      expect(_shown(tester), isNot(full));
      expect(
        tester
            .getSemantics(
              find.descendant(
                of: find.byType(MiddleEllipsisText),
                matching: find.byType(Text),
              ),
            )
            .label,
        full,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('clips at widths tighter than the ellipsis', (tester) async {
    const text = 'server-👨‍👩‍👧‍👦-name';
    final renderedText = find.descendant(
      of: find.byType(MiddleEllipsisText),
      matching: find.byType(Text),
    );
    for (final width in [0.0, 1.0, 4.0]) {
      await tester.pumpWidget(_host(width, text));
      expect(_shown(tester), '…');
      _expectWholeGraphemes(text, _shown(tester));
      expect(tester.widget<Text>(renderedText).overflow, TextOverflow.clip);
      expect(tester.takeException(), isNull);
    }
    expect(renderedText, paints..clipRect());
  });
}
