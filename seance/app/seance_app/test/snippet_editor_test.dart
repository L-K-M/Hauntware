import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/snippets_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The snippet editor and the undo history it feeds.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-snippet-editor-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services);
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  /// Lets the save's file write finish and the editor close.
  Future<void> saved(WidgetTester tester) async {
    for (var i = 0; i < 40 && find.byType(Dialog).evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('saving a snippet unchanged writes nothing and leaves nothing '
      'to undo', (tester) async {
    const snippet = Snippet(
      id: 'disk',
      title: 'Disk usage',
      body: 'df -h',
      createdAt: 1,
      updatedAt: 1,
    );
    await tester.runAsync(() => state.saveSnippet(snippet));
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.macOS),
        home: AppScope(
          state: state,
          child: Scaffold(
            body: Builder(
              builder: (inner) {
                context = inner;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );

    unawaited(showSnippetEditor(context, state, snippet));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await saved(tester);

    expect(find.byType(Dialog), findsNothing);
    expect(state.undoHistory.undoName, isNull);
    // Nothing written either: no new stamp to sync or sort by.
    expect(state.snippets.single.updatedAt, 1);
  });

  testWidgets('an edited snippet can be undone', (tester) async {
    const snippet = Snippet(
      id: 'disk',
      title: 'Disk usage',
      body: 'df -h',
      createdAt: 1,
      updatedAt: 1,
    );
    await tester.runAsync(() => state.saveSnippet(snippet));
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.macOS),
        home: AppScope(
          state: state,
          child: Scaffold(
            body: Builder(
              builder: (inner) {
                context = inner;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );

    unawaited(showSnippetEditor(context, state, snippet));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'df -hT');
    await tester.tap(find.text('Save'));
    await saved(tester);

    expect(state.undoHistory.undoName, 'Edit snippet');
  });

  testWidgets('a deleted snippet goes at once, and its notice brings it '
      'back', (tester) async {
    const snippet = Snippet(
      id: 'disk',
      title: 'Disk usage',
      body: 'df -h',
      createdAt: 1,
      updatedAt: 1,
    );
    await tester.runAsync(() => state.saveSnippet(snippet));
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.linux),
        home: AppScope(
          state: state,
          child: const Scaffold(body: SnippetsPane()),
        ),
      ),
    );
    await tester.pump();

    /// Gives the snippet store's file writes real time until [done].
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
    }

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await until(() => state.snippets.isEmpty);

    // No question first: the notice offers the way back.
    expect(find.byType(AlertDialog), findsNothing);
    expect(state.snippets, isEmpty);
    expect(find.text('Deleted “Disk usage”'), findsOneWidget);
    expect(state.undoHistory.undoName, 'Delete snippet');

    await tester.tap(find.text('Undo'));
    await until(() => state.snippets.isNotEmpty);
    expect(state.snippets.single.title, 'Disk usage');
    expect(state.undoHistory.redoName, 'Delete snippet');
    // The notice's timer runs out before the test ends.
    await tester.pump(const Duration(seconds: 10));
  });
}
