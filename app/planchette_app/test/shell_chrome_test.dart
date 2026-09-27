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
    // Spelled with the host's separator. `path.join` only joins the segments
    // it is given, so a hardcoded `a/index.js` becomes a mixed path on Windows
    // — and a path the workspace then has no tab for at all.
    final sep = Platform.pathSeparator;
    final a = 'a${sep}index.js';
    final b = 'b${sep}index.js';
    store.files[testPath(a)] = document(a, 'one');
    store.files[testPath(b)] = document(b, 'two');
    await workspace.open(testPath(a));
    await workspace.open(testPath(b));
    await mount(tester);

    // Both basenames are index.js, so the strip has to disambiguate them with
    // enough of the path to tell the two apart.
    // Asserted by the two labels differing, not by their spelling. The label
    // is derived from a host path, so it is written with the host's separator
    // and a hardcoded `a/index.js` matches nothing on Windows; spelling the
    // expectation out just moves the same guess to the other platform.
    final all = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('planchette.tabs')),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '<rich>')
        .toList();
    final names = all.where((data) => data.contains('index.js')).toList();
    expect(
      names,
      hasLength(2),
      reason: 'both tabs should be labelled, strip holds: $all',
    );
    expect(
      names.toSet(),
      hasLength(2),
      reason:
          'the two are not told apart: '
          '$names',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the active tab is brought into view when it changes',
    (tester) async {
      for (var i = 0; i < 24; i++) {
        store.files[testPath('file-$i.txt')] = document(
          'file-$i.txt',
          'body $i',
        );
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
      ScrollPosition stripPosition() => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const ValueKey('planchette.tabs')),
              matching: find.byType(Scrollable),
            ),
          )
          .position;

      String geometry(String name) {
        final position = stripPosition();
        return 'tab=${tabBox(name)} strip=${stripBox()} '
            'pixels=${position.pixels} max=${position.maxScrollExtent} '
            'viewport=${position.viewportDimension}';
      }

      // Pump until the strip stops moving rather than for a fixed span: the
      // reveal is scheduled from a post-frame callback, animated, and then
      // re-clamped when the surface settles, so any fixed number of frames is
      // a guess about the runner.
      Future<void> settleStrip() async {
        await tester.pump();
        var previous = double.nan;
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          final pixels = stripPosition().pixels;
          if (pixels == previous) return;
          previous = pixels;
        }
      }

      // The active tab is scrolled to, and is on screen. Not that it is wholly
      // visible: a tab is wider than the strip on a narrow window, so nothing
      // can show all of it, and demanding that only measures the runner's
      // surface size. The macOS and Windows jobs report a 150-pixel strip
      // where Linux reports 361, which is how this was found.
      void expectRevealed(String name) {
        final why = geometry(name);
        final box = tabBox(name);
        final strip = stripBox();
        expect(box.left, lessThan(strip.right + 1), reason: '$name $why');
        expect(box.right, greaterThan(strip.left - 1), reason: '$name $why');
        expect(tester.takeException(), isNull);
      }

      await settleStrip();
      expectRevealed('file-23.txt');
      // The strip moved towards the end, but not necessarily all the way: a tab
      // wider than the strip already fills it, and the remaining slack would
      // trade the tab's opening for its tail. The macOS and Windows jobs stop
      // 29.875 pixels short of the end, which is the whole of the slack.
      final scrolledToEnd = stripPosition().pixels;
      expect(
        scrolledToEnd,
        greaterThan(0.0),
        reason: 'strip did not move towards the end tab',
      );

      // And back to the other end.
      workspace.select(workspace.documents.first);
      await settleStrip();
      expectRevealed('file-0.txt');
      expect(
        stripPosition().pixels,
        lessThan(scrolledToEnd),
        reason: 'strip did not move back towards the first tab',
      );
    },
    variant: const TargetPlatformVariant(<TargetPlatform>{
      TargetPlatform.android,
      TargetPlatform.fuchsia,
      TargetPlatform.iOS,
      TargetPlatform.linux,
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );

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

  test('a Windows payload keeps its carriage returns out of the paths', () {
    // A desktop drop on Windows separates with CRLF, so a path that is not
    // trimmed would carry a \r that no file matches.
    expect(droppedPaths('/tmp/one.txt\r\n/tmp/two.txt\r\n'), [
      '/tmp/one.txt',
      '/tmp/two.txt',
    ]);
  });

  // `toFilePath` is the conversion being tested, so the expectation is built
  // with it rather than spelled out: it yields `/home/me/one.txt` on Linux and
  // macOS and `\\home\\me\\one.txt` on Windows, and a hardcoded POSIX
  // expectation fails on the runner that proves the conversion happened.
  String fromUri(String uri) => Uri.parse(uri).toFilePath();

  test('a desktop drop arrives as URIs, with comment lines', () {
    // This is the actual payload: text/uri-list, one file: URI per line, with
    // comment lines a file manager is free to include. Handing a URI straight
    // to File is why this had to be understood rather than split on newlines.
    expect(
      droppedPaths(
        'file:///home/me/one.txt\r\nfile:///home/me/two%20three.txt\r\n',
      ),
      [
        fromUri('file:///home/me/one.txt'),
        fromUri('file:///home/me/two three.txt'),
      ],
    );
    expect(droppedPaths('//comment\r\nfile:///home/me/one.txt\r\n'), [
      fromUri('file:///home/me/one.txt'),
    ]);
    // A plain path still works, so a test-supplied or hand-made drop is fine.
    expect(droppedPaths('/home/me/one.txt'), ['/home/me/one.txt']);
  });

  test('an unconvertible URI is skipped, never thrown out of the handler', () {
    // `toFilePath` throws UnsupportedError — not FormatException — for a UNC
    // share and for an escaped separator. What it throws is host-dependent:
    // off Windows a share has no path and throws, and on Windows it converts
    // to a UNC path, which is the right answer there. The Windows job is the
    // reason this asserts the outcome rather than an exact list.
    //
    // What must hold everywhere: the payload is processed, nothing escapes, and
    // the rest of it still opens.
    expect(() => droppedPaths('file://host/share/one.txt'), returnsNormally);
    expect(() => droppedPaths('file:///a%2Fb'), returnsNormally);
    expect(
      droppedPaths('file://host/share/one.txt\r\nfile:///home/me/ok.txt'),
      contains(fromUri('file:///home/me/ok.txt')),
    );
  });

  test('a payload of only comments opens nothing', () {
    expect(droppedPaths('//a comment\r\n//another\r\n'), isEmpty);
  });

  test('comment lines are skipped whichever marker is used', () {
    // RFC 2483 marks comments in text/uri-list with a number sign; some file
    // managers send two slashes. A real comment must not become a file to open.
    expect(droppedPaths('#rfc comment\r\nfile:///home/me/one.txt'), [
      fromUri('file:///home/me/one.txt'),
    ]);
    expect(droppedPaths('//practical comment\r\nfile:///home/me/one.txt'), [
      fromUri('file:///home/me/one.txt'),
    ]);
    expect(droppedPaths('#a\r\n//b\r\n'), isEmpty);
  });
}
