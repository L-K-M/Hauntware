import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:ghost_ui/src/ghost_file_compact_row.dart';
import 'package:ghost_ui/src/ghost_file_item.dart';
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

GhostFileCompactRow row(
  GhostFileItem item, {
  bool selected = false,
  bool selecting = false,
  VoidCallback? onTap,
  VoidCallback? onLongPress,
  VoidCallback? onActions,
  VoidCallback? onRename,
  Widget? trailing,
}) => GhostFileCompactRow(
  item: item,
  selected: selected,
  selecting: selecting,
  clock: () => DateTime(2026, 3, 5, 14, 30),
  onTap: onTap ?? () {},
  onLongPress: onLongPress ?? () {},
  onActions: onActions ?? () {},
  onRename: onRename,
  trailing: trailing,
);

Widget host(Widget child) => MaterialApp(
  theme: ThemeData(platform: TargetPlatform.iOS, extensions: const [_theme]),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  testWidgets('the badge morphs into a check while selected', (tester) async {
    await tester.pumpWidget(host(row(file('report.txt'))));
    expect(find.byIcon(Icons.description), findsOneWidget);
    expect(find.byIcon(Icons.check), findsNothing);
    await tester.pumpWidget(host(row(file('report.txt'), selected: true)));
    // The AnimatedSwitcher keeps the outgoing face around briefly —
    // settle past it before asserting the check owns the badge.
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('selection mode rings the unselected badge', (tester) async {
    await tester.pumpWidget(host(row(file('a.txt'), selecting: true)));
    final badge = tester.widget<DecoratedBox>(
      find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.key == const ValueKey(Icons.description),
      ),
    );
    final decoration = badge.decoration as BoxDecoration;
    expect(decoration.shape, BoxShape.circle);
    expect(decoration.border, isNotNull);
  });

  testWidgets('the ⋮ keeps its slot but goes inert while selecting', (
    tester,
  ) async {
    var actions = 0;
    await tester.pumpWidget(
      host(row(file('a.txt'), selecting: true, onActions: () => actions++)),
    );
    final more = tester.widget<IconButton>(
      find.byKey(const ValueKey(('ghostFileRow.more', 'a.txt'))),
    );
    expect(more.onPressed, isNull);
    await tester.tap(find.byIcon(Icons.more_vert));
    expect(actions, 0);
    await tester.pumpWidget(
      host(row(file('a.txt'), onActions: () => actions++)),
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    expect(actions, 1);
  });

  testWidgets('tap and long-press dispatch to the host', (tester) async {
    var taps = 0;
    var longs = 0;
    await tester.pumpWidget(
      host(row(file('a.txt'), onTap: () => taps++, onLongPress: () => longs++)),
    );
    await tester.tap(find.text('a.txt'));
    expect(taps, 1);
    await tester.longPress(find.text('a.txt'));
    expect(longs, 1);
  });

  testWidgets('the detail line names a folder and a link, else size', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(row(file('docs', type: GhostFileNodeType.directory))),
    );
    expect(find.textContaining('Folder ·'), findsOneWidget);
    await tester.pumpWidget(
      host(row(file('link', type: GhostFileNodeType.symbolicLink))),
    );
    expect(find.textContaining('Link ·'), findsOneWidget);
    await tester.pumpWidget(host(row(file('a.txt'))));
    expect(find.textContaining('1.5 KB ·'), findsOneWidget);
  });

  testWidgets('a host trailing widget renders before the ⋮', (tester) async {
    await tester.pumpWidget(
      host(
        row(
          file('a.txt'),
          trailing: const Icon(Icons.cloud_upload, key: Key('badge')),
        ),
      ),
    );
    expect(find.byKey(const Key('badge')), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('semantics expose selection and the rename action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(row(file('a.txt'), selected: true, onRename: () {})),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel(RegExp('a\\.txt, file')),
    );
    expect(node.flagsCollection.isSelected, ui.Tristate.isTrue);
    expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
    handle.dispose();
  });

  testWidgets('the shared compact extent scales with the text scale', (
    tester,
  ) async {
    late double extent;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: host(
          Builder(
            builder: (context) {
              extent = scaledGhostCompactFileRowExtent(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(extent, 112);
  });

  testWidgets('a flagged name carries the warning badge', (tester) async {
    await tester.pumpWidget(host(row(file('bad�name'))));
    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
  });
}
