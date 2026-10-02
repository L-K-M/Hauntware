import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:ghost_ui/src/ghost_file_item.dart';
import 'package:ghost_ui/src/ghost_file_row.dart';
import 'package:ghost_ui/src/ghost_file_theme.dart';

const _theme = GhostFileTheme(
  paneBackground: Color(0xFF202020),
  separator: Color(0xFF303030),
  hoverFill: Color(0xFF404040),
  selectionFill: Color(0xFF0060C0),
  onSelection: Color(0xFFFFFFFF),
  inactiveSelectionFill: Color(0xFF383838),
  activePaneIndicator: Color(0xFF50A0F0),
  secondaryText: Color(0xFF909090),
);

GhostFileItem file(
  String name, {
  GhostFileNodeType type = GhostFileNodeType.file,
  int? size = 1500,
  DateTime? modified,
}) => GhostFileItem(name: name, type: type, size: size, modifiedAt: modified);

GhostFileRow row(
  GhostFileItem item, {
  bool outline = false,
  int depth = 0,
  GhostFileDisclosure disclosure = GhostFileDisclosure.none,
  bool selected = false,
  bool active = true,
  bool cursorRing = false,
  bool dropTargeted = false,
  bool highlighted = false,
  bool renaming = false,
  bool touch = false,
  VoidCallback? onToggleDisclosure,
  ValueChanged<PointerDownEvent>? onDisclosurePointerDown,
  VoidCallback? onRename,
  VoidCallback? onTap,
  VoidCallback? onLongPress,
  ValueChanged<PointerDownEvent>? onPointerDown,
  ValueChanged<PointerUpEvent>? onPointerUp,
}) => GhostFileRow(
  item: item,
  outline: outline,
  depth: depth,
  disclosure: disclosure,
  onDisclosurePointerDown: onDisclosurePointerDown,
  onToggleDisclosure: onToggleDisclosure,
  highlighted: highlighted,
  cursorRing: cursorRing,
  selected: selected,
  renaming: renaming,
  dropTargeted: dropTargeted,
  active: active,
  clock: () => DateTime(2026, 3, 5, 14, 30),
  touch: touch,
  onPointerDown: onPointerDown ?? (_) {},
  onPointerMove: (_) {},
  onPointerUp: onPointerUp ?? (_) {},
  onTap: onTap ?? () {},
  onLongPress: onLongPress ?? () {},
  onOpen: () {},
  onRename: onRename,
);

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.linux, extensions: const [_theme]),
  home: Scaffold(body: Center(child: child)),
);

/// The fill the row's background [DecoratedBox] paints, or null.
Color? rowFill(WidgetTester tester) {
  final boxes = tester
      .widgetList<DecoratedBox>(
        find.ancestor(
          of: find.byType(Row),
          matching: find.byType(DecoratedBox),
        ),
      )
      .toList();
  for (final box in boxes) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.color != null) {
      return decoration.color;
    }
  }
  return null;
}

/// The foreground ring a row paints (DecoratedBox foreground border).
Border? rowRing(WidgetTester tester) {
  final boxes = tester
      .widgetList<DecoratedBox>(
        find.ancestor(
          of: find.byType(Row),
          matching: find.byType(DecoratedBox),
        ),
      )
      .toList();
  for (final box in boxes.reversed) {
    final decoration = box.decoration;
    if (decoration is BoxDecoration && decoration.border != null) {
      return decoration.border as Border?;
    }
  }
  return null;
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  testWidgets('renders the name and the size/date columns', (tester) async {
    await tester.pumpWidget(
      host(row(file('report.txt', modified: DateTime(2026, 3, 5, 9)))),
    );
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.text('1.5 KB'), findsOneWidget);
    expect(find.textContaining('Today at '), findsOneWidget);
    expect(find.byIcon(Icons.description), findsOneWidget);
  });

  testWidgets('a directory renders a folder glyph and unevaluated dashes', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(row(file('docs', type: GhostFileNodeType.directory))),
    );
    expect(find.byIcon(Icons.folder), findsOneWidget);
    // Directory size and the absent date both render the dash.
    expect(find.text('—'), findsNWidgets(2));
  });

  testWidgets('active selection paints the accent fill', (tester) async {
    await tester.pumpWidget(
      host(row(file('a.txt'), selected: true, active: true)),
    );
    expect(rowFill(tester), _theme.selectionFill);
  });

  testWidgets('inactive selection paints the neutral fill', (tester) async {
    await tester.pumpWidget(
      host(row(file('a.txt'), selected: true, active: false)),
    );
    expect(rowFill(tester), _theme.inactiveSelectionFill);
  });

  testWidgets('the drop-target ring outranks the cursor ring', (tester) async {
    await tester.pumpWidget(
      host(row(file('a.txt'), cursorRing: true, dropTargeted: true)),
    );
    final ring = rowRing(tester);
    expect(ring, isNotNull);
    expect(ring!.top.width, 2);
  });

  testWidgets('the cursor ring paints in the active-pane accent', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(row(file('a.txt'), cursorRing: true, active: true)),
    );
    final ring = rowRing(tester);
    expect(ring, isNotNull);
    expect(ring!.top.color, _theme.activePaneIndicator);
  });

  testWidgets('a renaming row hides its name label', (tester) async {
    await tester.pumpWidget(host(row(file('a.txt'), renaming: true)));
    expect(find.text('a.txt'), findsNothing);
  });

  testWidgets('outline rows render depth indent and the disclosure glyph', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        row(
          file('src', type: GhostFileNodeType.directory),
          outline: true,
          depth: 2,
          disclosure: GhostFileDisclosure.expanded,
        ),
      ),
    );
    expect(find.byIcon(Icons.arrow_right), findsOneWidget);
  });

  testWidgets('a loading disclosure shows a spinner, none shows neither', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        row(
          file('src', type: GhostFileNodeType.directory),
          outline: true,
          disclosure: GhostFileDisclosure.loading,
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(
      host(
        row(file('a.txt'), outline: true, disclosure: GhostFileDisclosure.none),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(Icons.arrow_right), findsNothing);
  });

  testWidgets('the triangle reports its own pointer-down', (tester) async {
    var pressed = 0;
    await tester.pumpWidget(
      host(
        row(
          file('src', type: GhostFileNodeType.directory),
          outline: true,
          disclosure: GhostFileDisclosure.collapsed,
          onDisclosurePointerDown: (_) => pressed++,
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.arrow_right));
    expect(pressed, 1);
  });

  testWidgets('desktop rows take raw pointer events, not a tap', (
    tester,
  ) async {
    var downs = 0;
    var ups = 0;
    var taps = 0;
    await tester.pumpWidget(
      host(
        row(
          file('a.txt'),
          onPointerDown: (_) => downs++,
          onPointerUp: (_) => ups++,
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.text('a.txt'));
    // The Listener received the press; the GestureDetector-less desktop
    // row never converts it to a tap.
    expect(downs, 1);
    expect(ups, 1);
    expect(taps, 0);
  });

  testWidgets('pointer hover paints the hover fill', (tester) async {
    await tester.pumpWidget(host(row(file('a.txt'))));
    expect(rowFill(tester), isNull);
    final hover = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await hover.addPointer(location: Offset.zero);
    addTearDown(hover.removePointer);
    await hover.moveTo(tester.getCenter(find.text('a.txt')));
    await tester.pump();
    expect(rowFill(tester), _theme.hoverFill);
  });

  testWidgets('touch rows take tap and long-press', (tester) async {
    var taps = 0;
    var longs = 0;
    await tester.pumpWidget(
      host(
        row(
          file('a.txt'),
          touch: true,
          onTap: () => taps++,
          onLongPress: () => longs++,
        ),
      ),
    );
    await tester.tap(find.text('a.txt'));
    expect(taps, 1);
    await tester.longPress(find.text('a.txt'));
    expect(longs, 1);
  });

  testWidgets('flagged names carry the warning badge and tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(host(row(file('bad�name'))));
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    expect(
      find.byTooltip('Name is not valid UTF-8 — shown approximately'),
      findsOneWidget,
    );
  });

  testWidgets('the semantics node composes name, kind, size, date', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(row(file('report.txt', modified: DateTime(2026, 3, 5, 9)))),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'report\.txt, file, 1\.5 KB')),
    );
    expect(node.label, contains('report.txt'));
    expect(node.label, contains('file'));
    expect(node.label, contains('1.5 KB'));
    expect(node.flagsCollection.isSelected, ui.Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('semantics expose selection, expansion, and rename', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var renamed = 0;
    var toggled = 0;
    await tester.pumpWidget(
      host(
        row(
          file('src', type: GhostFileNodeType.directory),
          outline: true,
          disclosure: GhostFileDisclosure.collapsed,
          selected: true,
          onRename: () => renamed++,
          onToggleDisclosure: () => toggled++,
        ),
      ),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('src, folder')),
    );
    expect(node.flagsCollection.isSelected, ui.Tristate.isTrue);
    expect(node.label, contains('folder'));
    expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
    handle.dispose();
  });

  testWidgets('a long name stays on one line and ellipsizes', (tester) async {
    await tester.pumpWidget(
      host(SizedBox(width: 300, child: row(file('a' * 200 + '.txt')))),
    );
    final text = tester.widget<Text>(find.text('a' * 200 + '.txt'));
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('text scaling grows the shared row extent', (tester) async {
    late double extent;
    await tester.pumpWidget(
      host(
        Builder(
          builder: (context) {
            extent = scaledGhostFileRowExtent(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(extent, 22);
  });
}
