import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  test('monospace defaults resolve a real family per platform', () {
    expect(
      EditorTypography.monospace(TargetPlatform.macOS).fontFamily,
      'Menlo',
    );
    expect(
      EditorTypography.monospace(TargetPlatform.iOS).fontFamily,
      'Menlo',
    );
    expect(
      EditorTypography.monospace(TargetPlatform.windows).fontFamily,
      'Consolas',
    );
    expect(
      EditorTypography.monospace(TargetPlatform.linux).fontFamily,
      'monospace',
    );
    for (final platform in TargetPlatform.values) {
      final style = EditorTypography.monospace(platform);
      expect(style.fontFamilyFallback, contains('monospace'));
      expect(style.fontSize, EditorTypography.defaultFontSize);
      expect(style.height, EditorTypography.defaultLineHeight);
      expect(style.fontFamily, isNotNull);
    }
  });

  testWidgets(
    'editor renders a resolvable monospace family by default',
    (tester) async {
      final controller = EditorController(
        displayPath: 'notes.txt',
        initialText: 'hello',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanchetteEditor(controller: controller),
          ),
        ),
      );

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('planchette.document')),
      );
      // 'monospace' alone resolves to a proportional font on Windows; the
      // default must name a family that platform actually ships.
      expect(field.style!.fontFamily, 'Consolas');
      expect(field.style!.fontFamilyFallback, isNotEmpty);
    },
    variant: const TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets('partial host style keeps the platform family', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'notes.txt',
      initialText: 'hello',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: controller,
            textStyle: const TextStyle(fontSize: 16),
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('planchette.document')),
    );
    expect(field.style!.fontFamily, 'Menlo');
    expect(field.style!.fontSize, 16);
    expect(field.style!.fontFamilyFallback, isNotEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));

  testWidgets('explicit host style overrides the monospace default', (
    tester,
  ) async {
    final controller = EditorController(
      displayPath: 'notes.txt',
      initialText: 'hello',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(
            controller: controller,
            textStyle: const TextStyle(fontFamily: 'HostMono', fontSize: 16),
          ),
        ),
      ),
    );

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('planchette.document')),
    );
    expect(field.style!.fontFamily, 'HostMono');
    expect(field.style!.fontSize, 16);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS}));
}
