import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostUndoDeclined, GhostUndoHistory, GhostUndoableChange;
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/ui/menus/edit_history_commands.dart';

void main() {
  late GhostUndoHistory history;
  late List<RegisteredCommand> commands;
  late RegisteredCommand undo;
  late RegisteredCommand redo;
  final l10n = lookupAppLocalizations(const Locale('en'));

  setUp(() {
    history = GhostUndoHistory();
    commands = buildEditHistoryCommands(history: history);
    undo = commands.singleWhere((command) => command.id == 'edit.undo');
    redo = commands.singleWhere((command) => command.id == 'edit.redo');
  });

  tearDown(() => history.dispose());

  void record({String name = 'Delete Favorite'}) => history.record(
    GhostUndoableChange(name: name, undo: () async {}, redo: () async {}),
  );

  test('the pair sits at the top of the Edit menu at app scope', () {
    expect(undo.scope, CommandScope.app);
    expect(redo.scope, CommandScope.app);
    expect(undo.menuPlacement?.menu, AppMenuId.edit);
    expect(redo.menuPlacement?.menu, AppMenuId.edit);
    expect(undo.menuPlacement?.order, 0);
    expect(redo.menuPlacement?.order, 1);
    // Above the selection history's Alt-modified pair (order 10/20) —
    // the document suite's own chords, per 10 §8.
    expect(undo.menuPlacement?.order, lessThan(10));
    expect(redo.menuPlacement?.order, lessThan(10));
  });

  test('chords are the platform suite: ⌘Z/⇧⌘Z, Ctrl+Z/Ctrl+Shift+Z/Ctrl+Y', () {
    expect(undo.activators!(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
    ]);
    expect(redo.activators!(TargetPlatform.macOS), const [
      SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
    ]);
    expect(undo.activators!(TargetPlatform.windows), const [
      SingleActivator(LogicalKeyboardKey.keyZ, control: true),
    ]);
    expect(redo.activators!(TargetPlatform.windows), const [
      SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
      SingleActivator(LogicalKeyboardKey.keyY, control: true),
    ]);
  });

  test('disabled with a reason while empty; the label names the change', () {
    expect(undo.enabled(), isFalse);
    expect(redo.enabled(), isFalse);
    expect(undo.disabledReason!(l10n), 'Nothing to undo');
    expect(redo.disabledReason!(l10n), 'Nothing to redo');
    expect(undo.label(l10n), 'Undo');
    expect(redo.label(l10n), 'Redo');

    record();
    expect(undo.enabled(), isTrue);
    expect(undo.label(l10n), 'Undo Delete Favorite');
    expect(redo.enabled(), isFalse);
  });

  /// A scaffolded context for [stepEditHistory]; the body shows a field
  /// when the stand-down case needs one to focus.
  Future<BuildContext> pumpHost(
    WidgetTester tester, {
    bool withField = false,
  }) async {
    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) {
              host = context;
              return withField
                  ? const TextField(autofocus: true)
                  : const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return host;
  }

  testWidgets('a stepped change toasts its name undone, then redone', (
    tester,
  ) async {
    var undone = 0;
    var redone = 0;
    history.record(
      GhostUndoableChange(
        name: 'Pin to top',
        undo: () async => undone++,
        redo: () async => redone++,
      ),
    );
    final context = await pumpHost(tester);

    await undo.run(context);
    await tester.pump();
    expect(undone, 1);
    expect(find.text('Pin to top undone'), findsOneWidget);

    await redo.run(context);
    await tester.pump();
    expect(redone, 1);
    expect(find.text('Pin to top redone'), findsOneWidget);
  });

  testWidgets('a declined step says why and keeps the change', (tester) async {
    var declined = true;
    history.record(
      GhostUndoableChange(
        name: 'Rename Server',
        undo: () async {
          if (declined) throw const GhostUndoDeclined('It was deleted');
        },
        redo: () async {},
      ),
    );
    final context = await pumpHost(tester);

    await undo.run(context);
    await tester.pump();
    expect(
      find.text('Couldn’t undo “Rename Server”: It was deleted'),
      findsOneWidget,
    );
    // The change stays put — Undo still names it for the retry.
    expect(history.undoName, 'Rename Server');

    declined = false;
    await undo.run(context);
    await tester.pump();
    expect(history.undoName, isNull);
    expect(history.redoName, 'Rename Server');
  });

  testWidgets('a failed step says why; the change leaves the history', (
    tester,
  ) async {
    history.record(
      GhostUndoableChange(
        name: 'Rename Server',
        undo: () async {},
        redo: () async => throw StateError('gone'),
      ),
    );
    final context = await pumpHost(tester);

    await undo.run(context);
    await tester.pump();
    expect(history.redoName, 'Rename Server');

    await redo.run(context);
    await tester.pump();
    expect(
      find.textContaining('Couldn’t redo “Rename Server”:'),
      findsOneWidget,
    );
    // A change that could not apply cannot be stepped back over — it is
    // out of the history rather than silently waiting to fail again.
    expect(history.redoName, isNull);
    expect(history.undoName, isNull);
  });

  testWidgets('a focused text field keeps its own history', (tester) async {
    var stepped = false;
    history.record(
      GhostUndoableChange(
        name: 'Delete Favorite',
        undo: () async => stepped = true,
        redo: () async {},
      ),
    );
    final context = await pumpHost(tester, withField: true);
    await tester.tap(find.byType(TextField));
    await tester.pump();

    // The menu click's app step lands on the field instead — or nowhere
    // — but never on the app history while a text surface holds focus.
    await redo.run(context);
    await tester.pump();
    await undo.run(context);
    await tester.pump();
    expect(stepped, isFalse);
    expect(history.undoName, 'Delete Favorite');
    expect(find.textContaining('undone'), findsNothing);
  });

  testWidgets('a deletion notice targets app data while text has focus', (
    tester,
  ) async {
    var stepped = false;
    history.record(
      GhostUndoableChange(
        name: 'Delete Favorite',
        undo: () async => stepped = true,
        redo: () async {},
      ),
    );
    final context = await pumpHost(tester, withField: true);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await stepEditHistory(
      Overlay.of(context, rootOverlay: true),
      history,
      direction: UndoDirection.undo,
      target: EditHistoryTarget.appData,
    );
    await tester.pump();
    expect(stepped, isTrue);
    expect(find.text('Delete Favorite undone'), findsOneWidget);
  });
}
