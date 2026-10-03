import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart' show formatShortcutActivator;
import 'package:planchette_app/widgets/command_palette.dart';

void main() {
  group('fuzzyMatch', () {
    test('matches a subsequence ignoring case and query spaces', () {
      expect(fuzzyMatch('sva', 'Save As…')!.positions, [0, 2, 5]);
      expect(fuzzyMatch('save as', 'Save As…')!.positions, [0, 1, 2, 3, 5, 6]);
      expect(fuzzyMatch('xyz', 'Save As…'), isNull);
      expect(fuzzyMatch('', 'Save')!.positions, isEmpty);
    });

    test('finds initials, but keeps a run over a later word start', () {
      expect(fuzzyMatch('fn', 'Find Next')!.positions, [0, 5]);
      expect(fuzzyMatch('cp', 'Command Palette…')!.positions, [0, 8]);
      expect(fuzzyMatch('fin', 'Find Next')!.positions, [0, 1, 2]);
    });

    test('ranks initials and runs above scattered letters', () {
      int score(String query, String label) => fuzzyMatch(query, label)!.score;
      expect(score('sa', 'Save As…'), greaterThan(score('sa', 'Close Tab')));
      expect(score('fn', 'Find Next'), greaterThan(score('fn', 'Find…')));
      expect(score('fin', 'Find…'), score('fin', 'Find Next'));
    });
  });

  test('shortcut labels follow the platform', () {
    const saveAs = SingleActivator(
      LogicalKeyboardKey.keyS,
      meta: true,
      shift: true,
    );
    expect(formatShortcutActivator(saveAs, TargetPlatform.macOS), '⇧⌘S');
    const next = SingleActivator(LogicalKeyboardKey.tab, control: true);
    expect(formatShortcutActivator(next, TargetPlatform.linux), 'Ctrl+Tab');
    const up = SingleActivator(LogicalKeyboardKey.arrowUp, alt: true);
    expect(formatShortcutActivator(up, TargetPlatform.macOS), '⌥↑');
    expect(formatShortcutActivator(up, TargetPlatform.windows), 'Alt+Up');
  });

  group('CommandPalette', () {
    late List<String> ran;
    late List<PaletteCommand> commands;
    PaletteCommand command(String path, String label) => PaletteCommand(
      id: '$path/$label',
      path: path,
      label: label,
      run: () => ran.add(label),
    );
    setUp(() {
      ran = [];
      commands = [
        command('File', 'New'),
        command('File', 'Save'),
        command('File', 'Save As…'),
        command('Edit', 'Select All'),
        command('Find', 'Find Next'),
        command('Find', 'Replace…'),
      ];
    });

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showCommandPalette(context, commands),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(
        find.byKey(const ValueKey('planchette.palette.query')),
        text,
      );
      await tester.pump();
    }

    testWidgets('lists every command in menu order', (tester) async {
      await open(tester);
      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.textSpan?.toPlainText() ?? text.data)
          .toList();
      expect(
        labels.where(
          (label) => commands.any((command) => command.label == label),
        ),
        ['New', 'Save', 'Save As…', 'Select All', 'Find Next', 'Replace…'],
      );
    });

    testWidgets('a menu name lists its commands after label matches', (
      tester,
    ) async {
      await open(tester);
      List<String> listed() => [
        for (final command in commands)
          if (find.text(command.label).evaluate().isNotEmpty) command.label,
      ];

      await type(tester, 'file');
      expect(listed(), ['New', 'Save', 'Save As…']);

      await type(tester, 'find');
      final next = tester.getTopLeft(find.text('Find Next')).dy;
      final replace = tester.getTopLeft(find.text('Replace…')).dy;
      expect(next, lessThan(replace), reason: 'label match first');
    });

    testWidgets('any label match outranks a menu-name match', (tester) async {
      // 'pe' is scattered in 'Replace…' and scores -1, the value menu-name
      // matches were given, so the two tied and menu order decided.
      expect(fuzzyMatch('pe', 'Replace…')!.score, lessThanOrEqualTo(-1));
      commands = [
        PaletteCommand(id: 'r', path: 'Open', label: 'Recent', run: () {}),
        PaletteCommand(id: 'x', path: 'Find', label: 'Replace…', run: () {}),
      ];
      await open(tester);
      await type(tester, 'pe');
      expect(
        tester.getTopLeft(find.text('Replace…')).dy,
        lessThan(tester.getTopLeft(find.text('Recent')).dy),
      );
    });

    testWidgets('Enter runs the best match after the palette closes', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'save');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Save and Save As tie on the letters; the shorter label wins.
      expect(ran, ['Save']);
      expect(find.byType(CommandPalette), findsNothing);
    });

    testWidgets('arrows move the highlight and wrap', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(ran, ['Replace…']);
    });

    testWidgets('a click runs that command', (tester) async {
      await open(tester);
      await tester.tap(find.text('Select All'));
      await tester.pumpAndSettle();

      expect(ran, ['Select All']);
    });

    testWidgets('Escape closes without running anything', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsNothing);
      expect(ran, isEmpty);
    });

    testWidgets('says when nothing matches, and Enter does nothing', (
      tester,
    ) async {
      await open(tester);
      await type(tester, 'qqq');
      expect(find.text('No matching commands'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(find.byType(CommandPalette), findsOneWidget);
      expect(ran, isEmpty);
    });

    testWidgets('a keyword matches a command and says so', (tester) async {
      commands = [
        PaletteCommand(
          id: 'dedupe',
          path: 'Text > Lines',
          label: 'Remove Duplicate Lines…',
          description: 'Deletes repeated lines, keeping the first of each.',
          keywords: const ['dedupe', 'uniq'],
          run: () => ran.add('dedupe'),
        ),
      ];
      await open(tester);
      await type(tester, 'dedupe');

      expect(find.text('Remove Duplicate Lines…'), findsOneWidget);
      expect(find.text('Text > Lines'), findsOneWidget);
      expect(find.textContaining('matches "dedupe"'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(ran, ['dedupe']);
    });

    testWidgets('a disabled command stays listed greyed and does not run', (
      tester,
    ) async {
      commands = [
        PaletteCommand(
          id: 'sort',
          path: 'Text > Lines',
          label: 'Sort Lines…',
          description: 'Orders lines alphabetically.',
          run: () => ran.add('sort'),
          enabled: false,
        ),
        command('File', 'New'),
      ];
      await open(tester);
      await type(tester, 'sort');

      expect(find.text('Sort Lines…'), findsOneWidget);
      expect(find.text('Orders lines alphabetically.'), findsOneWidget);
      // The row is rendered de-emphasised, not just inert.
      final labelText = tester.widget<Text>(find.text('Sort Lines…'));
      expect(labelText.style?.color?.a, lessThan(1));
      await tester.tap(find.text('Sort Lines…'));
      await tester.pumpAndSettle();
      expect(ran, isEmpty);
      expect(find.byType(CommandPalette), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(ran, isEmpty);
    });

    // A keyword phrase matches on the part typed so far: "trailing"
    // finds "trailing spaces" by subsequence.
    testWidgets('a partial query matches a multi-word keyword', (tester) async {
      commands = [
        PaletteCommand(
          id: 'trim',
          path: 'Text > Whitespace',
          label: 'Detab',
          description: 'Removes spaces and tabs from the ends of lines.',
          keywords: const ['trailing spaces'],
          run: () => ran.add('trim'),
        ),
      ];
      await open(tester);
      await type(tester, 'trailing sp');

      expect(find.text('Detab'), findsOneWidget);
      expect(find.textContaining('matches "trailing spaces"'), findsOneWidget);
    });
  });
}
