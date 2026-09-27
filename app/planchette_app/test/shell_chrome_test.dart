import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/planchette_app.dart';
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_workspace.dart';

import 'services/document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments, document, testPath;
import 'services/memory_settings.dart';

void main() {
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  late DocumentWorkspace workspace;
  late SettingsController settings;

  setUp(() async {
    store = MemoryDocuments();
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(store: store, dialogs: dialogs);
    settings = SettingsController(store: MemorySettings());
    addTearDown(settings.dispose);
    await settings.load();
  });
  tearDown(() => workspace.dispose());

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 700),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      PlanchetteApp(workspace: workspace, settings: settings),
    );
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpAndSettle();
  }

  Rect chromeRow(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('planchette.chrome')));

  testWidgets('the header and the tabs are one strip, not two', (tester) async {
    workspace.newDocument();
    store.files[testPath('one.txt')] = document('one.txt', 'on disk');
    await workspace.open(testPath('one.txt'));
    await mount(tester);

    expect(find.byKey(const ValueKey('planchette.chrome')), findsOneWidget);
    // One row, so its height is a row and not a row plus a tab strip.
    expect(chromeRow(tester).height, lessThan(60));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the document starts below a single strip', (tester) async {
    workspace.newDocument();
    await mount(tester);
    final field = tester.getRect(
      find.byKey(const ValueKey('planchette.document')),
    );
    // The strip is above the editor, not two strips.
    expect(field.top, lessThanOrEqualTo(chromeRow(tester).bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a tab label does not change width when it becomes dirty', (
    tester,
  ) async {
    final tab = workspace.newDocument()!;
    await mount(tester);

    final label = find.text('Untitled 1');
    expect(label, findsOneWidget);
    final before = tester.getSize(
      find.ancestor(of: label, matching: find.byType(Row)).first,
    );

    tab.editor.text.text = 'now it has content';
    await tester.pumpAndSettle();

    final after = tester.getSize(
      find.ancestor(of: label, matching: find.byType(Row)).first,
    );
    expect(after, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a dirty tab is marked, and an untouched one is not', (
    tester,
  ) async {
    final tab = workspace.newDocument()!;
    await mount(tester);
    expect(find.byKey(const ValueKey('planchette.dirty')), findsNothing);

    tab.editor.text.text = 'edited';
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('planchette.dirty')), findsOneWidget);

    tab.editor.text.text = '';
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('planchette.dirty')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two files with the same name are told apart', (tester) async {
    store.files[testPath('a/index.js')] = document('a/index.js', 'one');
    store.files[testPath('b/index.js')] = document('b/index.js', 'two');
    await workspace.open(testPath('a/index.js'));
    await workspace.open(testPath('b/index.js'));
    await mount(tester);

    // Both basenames are index.js, so the strip has to disambiguate them.
    expect(find.textContaining('index.js'), findsNWidgets(2));
    expect(find.textContaining('a'), findsWidgets);
    expect(find.textContaining('b'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the active tab is brought into view when it changes', (
    tester,
  ) async {
    for (var i = 0; i < 24; i++) {
      store.files[testPath('file-$i.txt')] = document('file-$i.txt', 'body $i');
    }
    for (var i = 0; i < 24; i++) {
      await workspace.open(testPath('file-$i.txt'));
    }
    await mount(tester, size: const Size(640, 700));

    final strip = find.byKey(const ValueKey('planchette.tabs'));
    Rect stripBox() => tester.getRect(strip);
    Rect tabBox(String name) => tester.getRect(
      find.ancestor(of: find.text(name), matching: find.byType(InkWell)),
    );
    void expectInView(String name) {
      final box = tabBox(name);
      expect(box.left, greaterThanOrEqualTo(stripBox().left - 1), reason: name);
      expect(box.right, lessThanOrEqualTo(stripBox().right + 1), reason: name);
    }

    // The last file opened is the active one, and it is off the end of the strip
    // until something brings it into view.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expectInView('file-23.txt');

    // And back to the other end.
    workspace.select(workspace.documents.first);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expectInView('file-0.txt');
    expect(tester.takeException(), isNull);
  });

  testWidgets('an error does not move the document', (tester) async {
    workspace.newDocument();
    await mount(tester);
    final before = tester.getRect(
      find.byKey(const ValueKey('planchette.document')),
    );

    store.writeError = const FileSystemException('Disk full');
    dialogs.savePath = testPath('never-written.txt');
    await workspace.save(workspace.active!);
    await tester.pumpAndSettle();

    final after = tester.getRect(
      find.byKey(const ValueKey('planchette.document')),
    );
    expect(after, before);
    expect(find.textContaining('Disk full'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an error can be dismissed', (tester) async {
    workspace.newDocument();
    await mount(tester);
    store.writeError = const FileSystemException('Disk full');
    dialogs.savePath = testPath('never-written.txt');
    await workspace.save(workspace.active!);
    await tester.pumpAndSettle();
    expect(find.textContaining('Disk full'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss error'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Disk full'), findsNothing);
    expect(workspace.error, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the window accepts a file drop', (tester) async {
    await mount(tester);
    // Flutter's DragTarget does not receive synthetic drags in flutter_test —
    // a Draggable driven by tester.dragFrom leaves it untouched, in a tree with
    // nothing else in it — so the wiring is asserted here and the payload
    // parsing below. The drop itself needs a real desktop run.
    expect(find.byType(DragTarget<String>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('a drop payload is a list of paths', () {
    expect(droppedPaths('/tmp/one.txt'), ['/tmp/one.txt']);
    expect(droppedPaths('/tmp/one.txt\n/tmp/two.txt'), [
      '/tmp/one.txt',
      '/tmp/two.txt',
    ]);
    expect(droppedPaths('/tmp/a b.txt\n  /tmp/c.txt  '), [
      '/tmp/a b.txt',
      '/tmp/c.txt',
    ]);
    expect(droppedPaths(''), isEmpty);
    expect(droppedPaths('\n\n'), isEmpty);
    expect(droppedPaths('   '), isEmpty);
  });
}
