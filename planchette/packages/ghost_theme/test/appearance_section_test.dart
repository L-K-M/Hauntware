// The shared Appearance editor (design docs/design/ghost-theme.md §3, §4)
// over a fake model, for a host with terminals (Séance's style) and one
// without (Poltergeist's): writes go through the model, the terminal
// colours section follows the style's seam, the host's sections land
// where Séance's sat, and every word comes from the strings bag.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';

import 'support/host_styles.dart';

final class _Model implements GhostAppearanceModel {
  _Model(this.value);

  @override
  AppAppearance value;
  final writes = <AppAppearance>[];
  Object? failWith;

  @override
  Future<void> setAppearance(
    ThemePalette palette,
    ThemeModePreference mode,
  ) async {
    if (failWith case final error?) throw error;
    value = AppAppearance(palette: palette, mode: mode);
    writes.add(value);
  }
}

/// Words a localizing host would supply.
final class _Pirate extends GhostAppearanceStrings {
  const _Pirate();

  @override
  String get themeTitle => 'Colours of the ship';

  @override
  String presetLabel(String storedName) => '$storedName (arr)';
}

Widget _header(String title, {String? helpTitle, String? help}) =>
    Text('# $title');

Future<_Model> _pump(
  WidgetTester tester, {
  GhostThemeStyle style = seanceStyle,
  ThemePalette? palette,
  GhostAppearanceStrings strings = const GhostAppearanceStrings(),
  bool terminals = true,
  List<Widget> Function(BuildContext, ThemePalette, Brightness)?
  terminalSection,
  Widget Function(BuildContext)? terminalColoursLead,
}) async {
  final model = _Model(
    AppAppearance(palette: palette ?? GhostThemePresets(style).initial),
  );
  tester.view.physicalSize = const Size(900, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: GhostTheme.light(style),
      home: Scaffold(
        body: GhostAppearanceSection(
          style: style,
          model: model,
          page: (children) => ListView(children: children),
          header: _header,
          strings: strings,
          defaultTerminalColors: terminals
              ? (_) => seancePresets.terminal.terminal!
              : null,
          terminalSection: terminalSection,
          terminalColoursLead: terminalColoursLead,
        ),
      ),
    ),
  );
  return model;
}

void main() {
  testWidgets('picking a preset writes it whole through the model', (
    tester,
  ) async {
    final model = await _pump(tester);
    await tester.tap(find.byTooltip('Use the Paper theme'));
    await tester.pump();
    expect(model.writes.single.palette, seancePresets.paper);
    expect(find.text('Using Paper.'), findsOneWidget);
  });

  testWidgets('a palette with its own surface disables the mode and says '
      'why', (tester) async {
    await _pump(tester, palette: seancePresets.paper);
    final mode = tester.widget<SegmentedButton<ThemeModePreference>>(
      find.byType(SegmentedButton<ThemeModePreference>),
    );
    expect(mode.onSelectionChanged, isNull);
    expect(find.textContaining('own surface, so it is always light'), findsOne);
  });

  testWidgets('a slot taken off Automatic starts from what it draws as', (
    tester,
  ) async {
    final model = await _pump(tester, palette: seancePresets.brand);
    await tester.tap(find.bySemanticsLabel('Surface: Automatic'));
    await tester.pump();
    final written = model.writes.single.palette;
    expect(
      written.surface,
      GhostTheme.resolvedSlots(
        seanceStyle,
        seancePresets.brand,
        Brightness.light,
      )[ThemeSlot.surface],
    );
    expect(written.name, ThemePalette.customName);
  });

  testWidgets('the terminal colours section follows the style seam, with '
      "the host's sections where Séance keeps them", (tester) async {
    await _pump(
      tester,
      palette: seancePresets.brand,
      terminalSection: (context, palette, drawnAt) => [
        Text('# Host terminal at ${drawnAt.name}'),
      ],
      terminalColoursLead: (_) => const Text('host lead'),
    );
    final order = [
      '# Status colours',
      '# Host terminal at light',
      '# Terminal colours',
      'host lead',
      '# Shape and type',
    ];
    final ys = [
      for (final text in order) tester.getTopLeft(find.text(text)).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));

    await tester.tap(find.text("Use the theme's terminal colours"));
    await tester.pump();
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.byTooltip('Choose the Bright cyan colour'), findsOneWidget);
  });

  testWidgets('a host without terminals has no terminal colours section', (
    tester,
  ) async {
    await _pump(tester, style: poltergeistStyle, terminals: false);
    expect(find.text('# Terminal colours'), findsNothing);
    expect(find.text('# Shape and type'), findsOneWidget);
    expect(
      find.byTooltip('Choose an installed font'),
      findsNothing,
      reason: 'no installed-font picker was given',
    );
  });

  testWidgets('every word comes from the strings bag', (tester) async {
    await _pump(tester, strings: const _Pirate());
    expect(find.text('# Colours of the ship'), findsOneWidget);
    expect(find.text('Paper (arr)'), findsOneWidget);
    expect(find.byTooltip('Use the Paper (arr) theme'), findsOneWidget);
    expect(find.text('Reset to Terminal (arr)'), findsOneWidget);
  });

  testWidgets('a clipboard without a theme leaves the palette alone', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, Object?>{'text': 'not a theme'}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final model = await _pump(tester);
    await tester.tap(find.text('Paste theme'));
    await tester.pump();
    expect(model.writes, isEmpty);
    expect(find.textContaining('does not hold a theme'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a write that fails says so and keeps the edit', (tester) async {
    final model = await _pump(tester)
      ..failWith = Exception('disk full');
    await tester.tap(find.byTooltip('Use the Paper theme'));
    await tester.pump();
    expect(find.textContaining('Appearance not saved'), findsOneWidget);
    expect(find.text('Using Paper.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
    expect(model.writes, isEmpty);
  });
}
