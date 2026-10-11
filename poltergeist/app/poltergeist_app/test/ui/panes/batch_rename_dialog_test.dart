import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_batch_rename.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/ui/panes/batch_rename_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;

const _home = '/home/tester';

RemoteFileEntry _file(String name) => RemoteFileEntry(
  path: '$_home/$name',
  name: name,
  type: RemoteFileType.file,
  size: 3,
);

Finder _key(BatchRenameKey key) => find.byKey(ValueKey(key));

/// Android 14's kind of scaling: small sizes grow more than large ones.
class _NonlinearTextScaler extends TextScaler {
  const _NonlinearTextScaler();

  @override
  double scale(double fontSize) => fontSize * (fontSize < 15 ? 1.9 : 1.7);

  @override
  double get textScaleFactor => 1.9;
}

void main() {
  late controller_test.FakePaneLanes lanes;
  late controller_test.FakePaneChannel channel;
  late PaneController pane;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    channel = controller_test.FakePaneChannel(_home)
      ..listings[_home] = [_file('a.txt'), _file('b.txt'), _file('c.txt')];
    lanes.nextLocalChannel = channel;
    pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
  });

  tearDown(() => pane.dispose());

  Future<void> openDialog(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.linux,
    Size size = const Size(1200, 900),
    GlobalKey<NavigatorState>? navigatorKey,
    TextScaler? textScaler,
  }) async {
    await pane.openLocalHome();
    await tester.pump();
    pane.setCursorIndex(0);
    pane.setCursorIndex(1, update: SelectionUpdate.toggle);

    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(platform: platform),
        builder: textScaler == null
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                child: child!,
              ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showBatchRenameDialog(context, pane: pane),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsOneWidget);
  }

  FilledButton confirm(WidgetTester tester) =>
      tester.widget<FilledButton>(_key(BatchRenameKey.confirm));

  Future<void> chooseMode(WidgetTester tester, String label) async {
    await tester.tap(_key(BatchRenameKey.mode));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('previews every keystroke and blocks a taken name', (
    tester,
  ) async {
    await openDialog(tester);
    expect(find.text('Rename 2 Items'), findsWidgets);
    expect(find.text('No names change.'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);

    await tester.enterText(_key(BatchRenameKey.find), 'a');
    await tester.enterText(_key(BatchRenameKey.replace), 'b');
    await tester.pump();
    // a.txt -> b.txt, but b.txt is selected and stays: the name is taken.
    expect(find.text('“b.txt” already exists in this folder.'), findsOneWidget);
    expect(
      find.text('1 item needs attention before you can rename.'),
      findsOneWidget,
    );
    expect(confirm(tester).onPressed, isNull);

    await tester.enterText(_key(BatchRenameKey.replace), 'z');
    await tester.pump();
    expect(find.text('z.txt'), findsOneWidget);
    expect(find.text('1 item will be renamed.'), findsOneWidget);
    expect(find.text('Rename 1 Item'), findsOneWidget);
    expect(confirm(tester).onPressed, isNotNull);
  });

  testWidgets('a full success renames, closes and reselects', (tester) async {
    await openDialog(tester);
    await chooseMode(tester, 'Add Text');
    await tester.enterText(_key(BatchRenameKey.addText), '-x');
    await tester.pump();
    channel.listings[_home] = [
      _file('a-x.txt'),
      _file('b-x.txt'),
      _file('c.txt'),
    ];

    await tester.tap(_key(BatchRenameKey.confirm));
    await tester.pumpAndSettle();

    expect(channel.renameCalls, [
      ('$_home/a.txt', '$_home/a-x.txt'),
      ('$_home/b.txt', '$_home/b-x.txt'),
    ]);
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(pane.batchRenameActive, isFalse);
    expect(
      [for (final entry in pane.selectedEntries) entry.name],
      ['a-x.txt', 'b-x.txt'],
    );
  });

  testWidgets('a partial failure keeps the outcome until Done', (tester) async {
    await openDialog(tester);
    await chooseMode(tester, 'Add Text');
    await tester.enterText(_key(BatchRenameKey.addText), '-x');
    await tester.pump();
    channel.renameFailures['$_home/a.txt'] = const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'rename',
      message: 'Permission denied',
    );

    await tester.tap(_key(BatchRenameKey.confirm));
    await tester.pumpAndSettle();

    expect(find.text('Renamed 1 of 2 items.'), findsOneWidget);
    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.text('Renamed'), findsOneWidget);
    expect(pane.batchRenameActive, isTrue);

    await tester.tap(_key(BatchRenameKey.done));
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(pane.batchRenameActive, isFalse);
  });

  testWidgets('Escape cancels and closes the session', (tester) async {
    await openDialog(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(pane.batchRenameActive, isFalse);
    expect(channel.renameCalls, isEmpty);
    // The page underneath is still there.
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Esc closes a field\'s context menu before the dialog', (
    tester,
  ) async {
    await openDialog(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(_key(BatchRenameKey.find)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    expect(_key(BatchRenameKey.dialog), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
  });

  testWidgets('Esc closes an open picker, then the dialog from it', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.tap(_key(BatchRenameKey.mode));
    await tester.pumpAndSettle();
    expect(find.text('Format'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Format'), findsNothing);
    expect(_key(BatchRenameKey.dialog), findsOneWidget);

    // Closing the menu leaves focus on the closed picker.
    final focused = FocusManager.instance.primaryFocus!.context!;
    expect(
      focused.findAncestorWidgetOfExactType<DropdownButton<BatchRenameMode>>(),
      isNotNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(pane.batchRenameActive, isFalse);
  });

  testWidgets('a result under another route leaves that route\'s focus', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await openDialog(tester, navigatorKey: navigator);
    await chooseMode(tester, 'Add Text');
    await tester.enterText(_key(BatchRenameKey.addText), '-x');
    await tester.pump();
    final held = Completer<void>();
    channel.heldRename = held;
    channel.renameFailures['$_home/b.txt'] = const RemoteFileException(
      kind: RemoteFileErrorKind.permissionDenied,
      operation: 'rename',
      message: 'Permission denied',
    );
    await tester.tap(_key(BatchRenameKey.confirm));
    await tester.pump();

    final coverFocus = FocusNode();
    addTearDown(coverFocus.dispose);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Material(
            child: TextField(focusNode: coverFocus, autofocus: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(coverFocus.hasPrimaryFocus, isTrue);

    held.complete();
    await tester.pumpAndSettle();
    expect(pane.batchRename!.stage, BatchRenameStage.finished);
    expect(coverFocus.hasPrimaryFocus, isTrue);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    // Done takes focus on return: Space presses it.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
  });

  testWidgets('preview rows fit nonlinearly scaled text', (tester) async {
    await openDialog(tester, textScaler: const _NonlinearTextScaler());
    await tester.enterText(_key(BatchRenameKey.find), 'a');
    await tester.enterText(_key(BatchRenameKey.replace), 'b');
    await tester.pump();
    expect(find.text('“b.txt” already exists in this folder.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Format numbers in list order and checks its start', (
    tester,
  ) async {
    await openDialog(tester);
    await chooseMode(tester, 'Format');
    await tester.enterText(_key(BatchRenameKey.formatName), 'Doc');
    await tester.pump();
    expect(find.text('Doc 1.txt'), findsOneWidget);
    expect(find.text('Doc 2.txt'), findsOneWidget);

    await tester.enterText(_key(BatchRenameKey.startAt), '');
    await tester.pump();
    expect(find.text('Enter a whole number from 0 to 999999.'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);
  });

  testWidgets('a phone-width touch window gets a full-screen page', (
    tester,
  ) async {
    await openDialog(
      tester,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Dialog && widget.insetPadding == EdgeInsets.zero,
      ),
      findsOneWidget,
    );
    expect(find.byType(CloseButton), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(pane.batchRenameActive, isFalse);
  });

  testWidgets('Escape stops a run, then closes its result', (tester) async {
    await openDialog(tester);
    await chooseMode(tester, 'Add Text');
    await tester.enterText(_key(BatchRenameKey.addText), '-x');
    await tester.pump();
    final held = Completer<void>();
    channel.heldRename = held;

    await tester.tap(_key(BatchRenameKey.confirm));
    await tester.pump();
    expect(_key(BatchRenameKey.stop), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(pane.batchRename!.stopRequested, isTrue);
    expect(find.text('Stopping after the current item…'), findsOneWidget);

    held.complete();
    await tester.pumpAndSettle();
    expect(find.text('Stopped after renaming 1 of 2 items.'), findsOneWidget);
    expect(find.text('Not attempted'), findsOneWidget);
    expect(channel.renameCalls, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(pane.batchRenameActive, isFalse);
  });

  testWidgets('a session that ends under another route closes on return', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    channel.listings['$_home/docs'] = const [];
    await openDialog(tester, navigatorKey: navigator);

    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('cover')),
      ),
    );
    await tester.pumpAndSettle();
    // The tab leaves the folder while the dialog is covered.
    pane.navigate('$_home/docs');
    await tester.pumpAndSettle();
    expect(pane.batchRenameActive, isFalse);
    expect(find.text('cover'), findsOneWidget);

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(_key(BatchRenameKey.dialog), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
