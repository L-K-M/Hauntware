import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart';

void main() {
  final results = <MonoFontSelection?>[];
  setUp(results.clear);

  Future<void> open(
    WidgetTester tester, {
    String current = '',
    MonoLigatures ligatures = MonoLigatures.on,
    Size size = const Size(1100, 800),
    Future<Map<String, bool>> Function()? installedFonts,
    double scale = 1,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => results.add(
                await showMonoFontPicker(
                  context,
                  current: current,
                  defaultFont: BundledMonoFont.jetBrainsMono,
                  ligatures: ligatures,
                  installedFonts: installedFonts,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> select(WidgetTester tester, String family) async {
    await tester.enterText(find.byKey(const ValueKey('font.search')), family);
    await tester.pump();
    final row = find.byKey(ValueKey('font.choice.$family'));
    await tester.scrollUntilVisible(
      row,
      160,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('font.list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    final visible = tester
        .getRect(row)
        .intersect(tester.getRect(find.byKey(const ValueKey('font.list'))));
    expect(visible.height, greaterThan(0));
    await tester.tapAt(visible.center);
    await tester.pumpAndSettle();
  }

  TextStyle sample(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('font.sample'))).style!;

  testWidgets('search previews a bundled family before applying it', (
    tester,
  ) async {
    await open(tester);
    expect(results, isEmpty);
    expect(sample(tester).fontFamily, BundledMonoFont.jetBrainsMono.family);

    await select(tester, 'Geist Mono');
    expect(results, isEmpty);
    expect(sample(tester).fontFamily, BundledMonoFont.geistMono.family);
    expect(sample(tester).fontFeatures, contains(const FontFeature('ss11')));
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const ValueKey('font.ligatures')))
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('font.apply')));
    await tester.pumpAndSettle();
    expect(results.single?.family, 'Geist Mono');
    expect(results.single?.ligatures, MonoLigatures.on);
  });

  testWidgets(
    'ligatures can be disabled in both preview and confirmed choice',
    (tester) async {
      await open(tester, current: 'Monaspace Neon');
      await tester.tap(find.byKey(const ValueKey('font.ligatures')));
      await tester.pumpAndSettle();
      expect(
        sample(tester).fontFeatures,
        contains(const FontFeature.disable('ss03')),
      );

      await tester.tap(find.byKey(const ValueKey('font.apply')));
      await tester.pumpAndSettle();
      expect(results.single?.ligatures, MonoLigatures.off);
      expect(results.single?.family, 'Monaspace Neon');
    },
  );

  testWidgets('opening respects an existing disabled preference', (
    tester,
  ) async {
    await open(tester, current: 'Intel One Mono', ligatures: MonoLigatures.off);
    expect(
      sample(tester).fontFeatures,
      contains(const FontFeature.disable('ss01')),
    );
  });

  testWidgets('Cancel discards the previewed font and ligatures', (
    tester,
  ) async {
    await open(tester);
    await select(tester, 'Victor Mono');
    await tester.tap(find.byKey(const ValueKey('font.ligatures')));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('every bundled family can be found offline', (tester) async {
    await open(tester);
    for (final font in BundledMonoFont.values) {
      await tester.enterText(
        find.byKey(const ValueKey('font.search')),
        font.displayName,
      );
      await tester.pump();
      final value = font == BundledMonoFont.jetBrainsMono
          ? ''
          : font.displayName;
      expect(find.byKey(ValueKey('font.choice.$value')), findsOneWidget);
    }
    await tester.enterText(
      find.byKey(const ValueKey('font.search')),
      'not a font',
    );
    await tester.pump();
    expect(find.text('No fonts match your search.'), findsOneWidget);
  });

  testWidgets('bundled fonts remain usable during a slow installed scan', (
    tester,
  ) async {
    final installed = Completer<Map<String, bool>>();
    await open(tester, installedFonts: () => installed.future);
    await tester.enterText(
      find.byKey(const ValueKey('font.search')),
      'Cascadia',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('font.choice.Cascadia Code')),
      findsOneWidget,
    );

    installed.complete({'Cascadia Code': true, 'Menlo': true, 'Inter': false});
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('font.choice.Cascadia Code')),
      findsOneWidget,
    );
    await select(tester, 'Menlo');
    expect(sample(tester).fontFamily, 'Menlo');
  });

  testWidgets('a custom family survives filtering and scan failure', (
    tester,
  ) async {
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {};
    await open(
      tester,
      current: 'My Mono',
      installedFonts: () => throw StateError('unreadable'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('font.search')),
      'My Mono',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font.choice.My Mono')), findsOneWidget);
    expect(sample(tester).fontFamily, 'My Mono');
    expect(tester.takeException(), isNull);
    debugPrint = previous;
  });

  testWidgets('default choice stays distinct from cancellation', (
    tester,
  ) async {
    await open(tester, current: 'Fira Code');
    await tester.tap(find.byKey(const ValueKey('font.choice.')));
    await tester.tap(find.byKey(const ValueKey('font.apply')));
    await tester.pumpAndSettle();
    expect(results.single?.family, '');
  });

  testWidgets('a typed installed name is deduplicated ignoring case', (
    tester,
  ) async {
    await open(
      tester,
      current: 'menlo',
      installedFonts: () async => {'Menlo': true},
    );
    await tester.enterText(find.byKey(const ValueKey('font.search')), 'menlo');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font.choice.Menlo')), findsOneWidget);
    expect(find.byKey(const ValueKey('font.choice.menlo')), findsNothing);
  });

  testWidgets('phone search exposes matches above the preview and keyboard', (
    tester,
  ) async {
    await open(tester, size: const Size(390, 844));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.enterText(
      find.byKey(const ValueKey('font.search')),
      'Geist Mono',
    );
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('font.choice.Geist Mono'));
    expect(row.hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('font.sample')), findsNothing);

    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('font.search')))
          .controller!
          .text,
      isEmpty,
    );
    expect(sample(tester).fontFamily, BundledMonoFont.geistMono.family);
  });

  for (final size in [const Size(320, 640), const Size(640, 320)]) {
    testWidgets('fits $size with enlarged text and keeps Apply reachable', (
      tester,
    ) async {
      await open(tester, size: size, scale: 1.5);
      expect(tester.takeException(), isNull);
      await select(tester, '0xProto');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('font.apply')));
      await tester.pumpAndSettle();
      expect(results.single?.family, '0xProto');
    });
  }
}
