import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/color_picker.dart';
import 'package:seance_app/ui/server_appearance.dart';
import 'package:seance_app/ui/server_color_picker.dart';
import 'package:seance_core/seance_core.dart';

/// Séance's face of the shared colour pickers, whose mechanics ghost_ui's
/// and ghost_marks' own tests cover: the default title and the monospace
/// hex box.
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

  testWidgets('the server colour picker opens the same way, on its mark', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showServerColorPicker(
                context,
                initial: const Color(0xFF336699),
                mark: const ServerGlyphMark(ServerIcon.rocket),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Custom colour'), findsOneWidget);
    expect(find.byType(ServerBadge), findsOneWidget);
    expect(find.text('336699'), findsOneWidget);
    expect(
      find.text(
        'Drawn as picked, with the mark kept legible on it in both themes. '
        'Devices running an older version show the nearest of the named colours '
        'instead.',
      ),
      findsOneWidget,
    );
    final style = tester.widget<TextField>(find.byType(TextField)).style!;
    expect(style.fontFamily, SeanceTheme.monoFallback.first);
    expect(style.fontFamilyFallback, SeanceTheme.monoFallback);
  });
}
