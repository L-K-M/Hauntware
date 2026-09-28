import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  const expected = {
    TargetPlatform.macOS: 'Menlo',
    TargetPlatform.iOS: 'Menlo',
    TargetPlatform.windows: 'Cascadia Mono',
    TargetPlatform.linux: 'monospace',
    TargetPlatform.android: 'monospace',
    TargetPlatform.fuchsia: 'monospace',
  };

  testWidgets('the document uses a real monospace family on each platform', (
    tester,
  ) async {
    await mount(tester);
    final style = documentStyle(tester);
    expect(style.fontFamily, expected[defaultTargetPlatform]);
    expect(style.fontFamilyFallback, isNotEmpty);
    // Every stack ends in the generic family where the platform has one.
    expect([
      style.fontFamily,
      ...style.fontFamilyFallback!,
    ], contains('monospace'));
    expect(style.fontSize, 14);
    expect(style.height, 1.35);
  }, variant: TargetPlatformVariant(expected.keys.toSet()));

  testWidgets('a host family and size replace the defaults', (tester) async {
    await mount(
      tester,
      style: const TextStyle(fontFamily: 'Host Mono', fontSize: 18),
    );
    final style = documentStyle(tester);
    expect(style.fontFamily, 'Host Mono');
    expect(style.fontSize, 18);
    expect(style.height, 1.35);
    // The platform stack remains behind a host family that may be missing.
    expect(style.fontFamilyFallback, isNotEmpty);
  });

  // Ported from #15.
  testWidgets('a size-only host style keeps the platform family', (
    tester,
  ) async {
    await mount(tester, style: const TextStyle(fontSize: 16));
    final style = documentStyle(tester);
    expect(style.fontFamily, 'Menlo');
    expect(style.fontSize, 16);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('the generic monospace name means the platform family', (
    tester,
  ) async {
    // Hosts written for the old default pass the generic name, which only
    // fontconfig and Android resolve.
    for (final generic in ['monospace', 'Monospace']) {
      await mount(tester, style: TextStyle(fontFamily: generic));
      expect(documentStyle(tester).fontFamily, 'Menlo');
      expect(documentStyle(tester).fontFamilyFallback, isNotEmpty);
    }
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('the family follows the operating system, not the theme', (
    tester,
  ) async {
    // Installed fonts belong to the OS; a theme may style another platform.
    await mount(tester, theme: ThemeData(platform: TargetPlatform.android));
    expect(documentStyle(tester).fontFamily, 'Menlo');
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
}
