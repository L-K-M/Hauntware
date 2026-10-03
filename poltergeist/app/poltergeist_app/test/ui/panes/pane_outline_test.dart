import 'dart:async';

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/ui/panes/pane_column_header.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// 02 §2.5: desktop folder rows carry a disclosure triangle that opens
/// the folder in place, indented below it.
const _home = '/home/tester';

RemoteFileEntry _entry(
  String parent,
  String name, {
  RemoteFileType type = RemoteFileType.file,
}) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: type,
  size: type == RemoteFileType.file ? 10 : null,
);

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late WorkspaceController workspace;
  late FocusNode leftNode;
  late FocusNode rightNode;
  late controller_test.FakePaneChannel channel;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(right),
    );
    leftNode = FocusNode();
    rightNode = FocusNode();
  });

  tearDown(() {
    workspace.dispose();
    leftNode.dispose();
    rightNode.dispose();
  });

  Future<void> pumpPane(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    channel = controller_test.FakePaneChannel(_home);
    channel.listings[_home] = [
      _entry(_home, 'cache', type: RemoteFileType.directory),
      _entry(_home, 'docker', type: RemoteFileType.directory),
      _entry(_home, 'notes.txt'),
    ];
    channel.listings['$_home/cache'] = [
      _entry('$_home/cache', 'runtimes', type: RemoteFileType.directory),
      _entry('$_home/cache', 'state.json'),
    ];
    channel.listings['$_home/cache/runtimes'] = [
      _entry('$_home/cache/runtimes', 'a'),
    ];
    lanes.nextLocalChannel = channel;
    await left.openLocalHome();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: debugDefaultTargetPlatformOverride ?? TargetPlatform.linux,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaneView(
            controller: left,
            pane: workspace.left,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () => rightNode.requestFocus(),
            onCancelRecovery: () => unawaited(left.cancelRecovery()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The triangle on [name]'s row (closed or open).
  Finder triangleOf(WidgetTester tester, String name) {
    final y = tester.getCenter(find.text(name)).dy;
    return find
        .byWidgetPredicate((widget) {
          if (widget is! Icon || widget.icon != Icons.arrow_right) return false;
          return true;
        })
        .evaluate()
        .where((element) {
          final box = element.renderObject! as RenderBox;
          return (box.localToGlobal(box.size.center(Offset.zero)).dy - y)
                  .abs() <
              1;
        })
        .map((element) => find.byElementPredicate((e) => e == element))
        .first;
  }

  List<String> names() => [for (final entry in left.entries) entry.name];

  Future<void> pressTriangle(WidgetTester tester, String name) async {
    await tester.tap(triangleOf(tester, name));
    await tester.pump();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
  }

  testWidgets('the triangle opens a folder in place without selecting it', (
    tester,
  ) async {
    await pumpPane(tester);
    await pressTriangle(tester, 'cache');
    expect(names(), ['cache', 'runtimes', 'state.json', 'docker', 'notes.txt']);
    expect(left.selectedCount, 0);
    expect(left.cursorIndex, isNull);
    expect(left.location!.path, _home);

    await pressTriangle(tester, 'cache');
    expect(names(), ['cache', 'docker', 'notes.txt']);
  });

  testWidgets('a quick second press on the triangle closes, never opens '
      'the folder', (tester) async {
    await pumpPane(tester);
    final triangle = triangleOf(tester, 'cache');
    await tester.tap(triangle);
    await tester.pump();
    await tester.tap(triangle);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(left.location!.path, _home, reason: 'no double-click open');
    expect(names(), ['cache', 'docker', 'notes.txt']);
  });

  testWidgets('rows inside indent one step per level; names line up', (
    tester,
  ) async {
    await pumpPane(tester);
    await pressTriangle(tester, 'cache');
    await pressTriangle(tester, 'runtimes');
    double x(String name) => tester.getTopLeft(find.text(name)).dx;
    expect(x('notes.txt'), x('docker'), reason: 'files keep the column');
    expect(x('runtimes') - x('cache'), PaneColumnMetrics.depthIndent);
    expect(x('a') - x('runtimes'), PaneColumnMetrics.depthIndent);
  });

  testWidgets('→ opens the cursor folder, ← steps out and closes it', (
    tester,
  ) async {
    await pumpPane(tester);
    leftNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump();
    expect(names(), ['cache', 'runtimes', 'state.json', 'docker', 'notes.txt']);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(left.entries[left.cursorIndex!].name, 'runtimes');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(left.entries[left.cursorIndex!].name, 'cache');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(names(), ['cache', 'docker', 'notes.txt']);
  });

  testWidgets('screen readers hear whether a folder is open', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPane(tester);
    Finder row(String name) => find
        .ancestor(of: find.text(name), matching: find.byType(Semantics))
        .first;
    expect(
      tester.getSemantics(row('cache')),
      isSemantics(hasExpandedState: true, isExpanded: false),
    );
    expect(
      tester.getSemantics(row('notes.txt')),
      isSemantics(hasExpandedState: false),
    );
    await pressTriangle(tester, 'cache');
    expect(
      tester.getSemantics(row('cache')),
      isSemantics(hasExpandedState: true, isExpanded: true),
    );
    semantics.dispose();
  });

  testWidgets('touch rows keep their layout and have no triangle', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpPane(tester);
      expect(find.byIcon(Icons.arrow_right), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
