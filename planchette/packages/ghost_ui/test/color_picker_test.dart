import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';

/// A host's words, to prove every label and announcement comes from the bag.
final class _Shouty extends ColorPickerStrings {
  const _Shouty();

  @override
  String get hexLabel => 'HEX';
  @override
  String get hexError => 'SIX';
  @override
  String get hexErrorAlpha => 'SIX OR EIGHT';
  @override
  String get hue => 'HUE';
  @override
  String get saturation => 'SAT';
  @override
  String get brightness => 'BRI';
  @override
  String get opacity => 'OPA';
  @override
  String degrees(int degrees) => '$degrees DEG';
  @override
  String percent(int percent) => '$percent PCT';
  @override
  String get cancel => 'NO';
  @override
  String get use => 'YES';
}

/// The picker the server colour pickers are built on, in the two ways only
/// the Appearance settings use it: without a preview of its own, and with an
/// opacity slider. The server pickers' own tests cover the rest.
void main() {
  final picked = <Color?>[];
  setUp(picked.clear);

  Future<void> open(
    WidgetTester tester, {
    required Color start,
    bool allowAlpha = false,
    TextStyle? hexStyle,
    ColorPickerStrings strings = const ColorPickerStrings(),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => picked.add(
                await showColorPicker(
                  context,
                  initial: start,
                  title: 'Lines',
                  allowAlpha: allowAlpha,
                  hexStyle: hexStyle,
                  strings: strings,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  String hex(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('each slider is named to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await open(tester, start: const Color(0xFF3366CC), allowAlpha: true);
      // The slider's own node carries the name, not only a text beside it.
      final names = ['Hue', 'Saturation', 'Brightness', 'Opacity'];
      for (var i = 0; i < names.length; i++) {
        expect(
          tester.getSemantics(find.byType(Slider).at(i)).label,
          contains(names[i]),
          reason: names[i],
        );
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets('without a preview it shows the colour as a swatch', (
    tester,
  ) async {
    await open(tester, start: const Color(0xFF336699));
    expect(find.text('Lines'), findsOneWidget);
    expect(
      tester.widget<ColorSwatchBox>(find.byType(ColorSwatchBox)).color,
      const Color(0xFF336699),
    );
    expect(find.byType(Slider), findsNWidgets(3));
  });

  testWidgets('with alpha, the opacity slider and eight digits', (
    tester,
  ) async {
    await open(tester, start: const Color(0x80336699), allowAlpha: true);
    expect(find.byType(Slider), findsNWidgets(4));
    expect(hex(tester), '33669980');

    final opacity = find.byType(Slider).last;
    await tester.drag(opacity, Offset(tester.getSize(opacity).width, 0));
    await tester.pumpAndSettle();
    // Fully opaque is written as six digits again.
    expect(hex(tester), '336699');

    await tester.enterText(find.byType(TextField), '3366990');
    await tester.pump();
    expect(find.text('Six or eight hex digits'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '33669940');
    await tester.pump();
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();
    expect(picked.single, const Color(0x40336699));
  });

  testWidgets('without alpha, a translucent colour comes back opaque', (
    tester,
  ) async {
    await open(tester, start: const Color(0x80336699));
    expect(hex(tester), '336699');
    await tester.tap(find.text('Use colour'));
    await tester.pumpAndSettle();
    expect(picked.single, const Color(0xFF336699));
  });

  testWidgets('every word comes from the strings', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await open(
        tester,
        start: const Color(0x80336699),
        allowAlpha: true,
        strings: const _Shouty(),
      );
      expect(find.text('HEX'), findsOneWidget);
      for (final (index, name, value) in [
        (0, 'HUE', '210 DEG'),
        (1, 'SAT', '67 PCT'),
        (2, 'BRI', '60 PCT'),
        (3, 'OPA', '50 PCT'),
      ]) {
        final slider = find.byType(Slider).at(index);
        expect(tester.getSemantics(slider).label, contains(name));
        // The value a screen reader announces, and the drag label.
        final widget = tester.widget<Slider>(slider);
        expect(widget.semanticFormatterCallback!(widget.value), value);
        expect(widget.label, value);
      }
      expect(find.text('NO'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '3366990');
      await tester.pump();
      expect(find.text('SIX OR EIGHT'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '33669940');
      await tester.pump();
      await tester.tap(find.text('YES'));
      await tester.pumpAndSettle();
      expect(picked.single, const Color(0x40336699));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('without alpha the error asks for six digits', (tester) async {
    await open(tester, start: const Color(0xFF336699));

    await tester.enterText(find.byType(TextField), '12345');
    await tester.pump();
    expect(find.text('Six hex digits'), findsOneWidget);
    final use = find.widgetWithText(FilledButton, 'Use colour');
    expect(tester.widget<FilledButton>(use).onPressed, isNull);
  });

  testWidgets('the hex box takes the host\'s monospace style', (tester) async {
    const mono = TextStyle(
      fontFamily: 'Mono A',
      fontFamilyFallback: ['Mono B'],
    );
    await open(tester, start: const Color(0xFF3366CC), hexStyle: mono);

    final style = tester.widget<TextField>(find.byType(TextField)).style!;
    expect(style.fontFamily, 'Mono A');
    expect(style.fontFamilyFallback, ['Mono B']);
  });
}
