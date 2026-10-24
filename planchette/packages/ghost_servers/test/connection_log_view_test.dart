import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';

const _mono = TextStyle(fontFamily: 'monospace');

void main() {
  Future<void> pump(WidgetTester tester, Widget view) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: view)),
      ),
    );
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
  }

  Iterable<SingleChildScrollView> scrolls(WidgetTester tester) =>
      tester.widgetList<SingleChildScrollView>(
        find.descendant(
          of: find.byType(ExpansionTile),
          matching: find.byType(SingleChildScrollView),
        ),
      );

  testWidgets('a host\'s words and face', (tester) async {
    await pump(
      tester,
      const GhostConnectionLogView(
        text: '',
        monoStyle: _mono,
        strings: GhostConnectionLogStrings(
          title: 'Verbindungsprotokoll',
          copy: 'Kopieren',
          empty: '(kein Protokoll)',
        ),
      ),
    );

    expect(find.text('Verbindungsprotokoll'), findsOneWidget);
    expect(find.text('(kein Protokoll)'), findsOneWidget);
    final shown = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(shown.style?.fontFamily, 'monospace');
    expect(shown.style?.fontSize, 12);
  });

  testWidgets('a transcript scrolls both ways, or from its end when '
      'reversed', (tester) async {
    await pump(
      tester,
      const GhostConnectionLogView(text: 'line', monoStyle: _mono),
    );
    expect(scrolls(tester).map((s) => (s.scrollDirection, s.reverse)), [
      (Axis.vertical, false),
      (Axis.horizontal, false),
    ]);

    await pump(
      tester,
      const GhostConnectionLogView(
        text: 'line',
        monoStyle: _mono,
        reverse: true,
      ),
    );
    expect(scrolls(tester).map((s) => (s.scrollDirection, s.reverse)), [
      (Axis.vertical, true),
    ]);
  });

  testWidgets('a host\'s copy replaces the default one', (tester) async {
    var copies = 0;
    await pump(
      tester,
      GhostConnectionLogView(
        text: 'line',
        monoStyle: _mono,
        onCopy: () async => copies++,
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();

    expect(copies, 1);
    expect(find.text('Log copied'), findsNothing);
  });

  testWidgets('a failed copy is reported and says so', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.setData'
          ? throw PlatformException(code: 'no-clipboard')
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final reported = <Object>[];
    await pump(
      tester,
      GhostConnectionLogView(
        text: 'line',
        monoStyle: _mono,
        onCopyError: (error, _) => reported.add(error),
      ),
    );
    await tester.tap(find.text('Copy'));
    await tester.pump();

    expect(reported.single, isA<PlatformException>());
    expect(find.text('Could not copy the log'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
