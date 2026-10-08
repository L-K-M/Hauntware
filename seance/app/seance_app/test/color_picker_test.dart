import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/color_picker.dart';

/// Séance's face of ghost_ui's colour picker, whose mechanics ghost_ui's
/// own test covers: the default title and the monospace hex box.
void main() {
  testWidgets('opens titled for a custom colour, the hex box in mono', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showColorPicker(context, initial: const Color(0xFF336699)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Custom colour'), findsOneWidget);
    final style = tester.widget<TextField>(find.byType(TextField)).style!;
    expect(style.fontFamily, SeanceTheme.monoFallback.first);
    expect(style.fontFamilyFallback, SeanceTheme.monoFallback);
  });
}
