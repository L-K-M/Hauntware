import 'dart:io' show Platform;

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, SidebarMenuEntry;
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';

final class _Proc {
  const _Proc(this.pid, this.name, this.cpu, this.state);

  final int pid;
  final String name;

  /// Null is an unknown reading.
  final double? cpu;
  final String state;
}

const _tableId = 'procs';
const _desktopRowExtent = 22.0; // ghost_theme's desktop listing row
const _touchRowExtent = 48.0; // ghost_theme's touch listing row

const _procs = [
  _Proc(1, 'systemd', 0.1, 'sleeping'),
  _Proc(2, 'nginx', 4.2, 'running'),
  _Proc(3, 'postgres', null, 'sleeping'),
  _Proc(4, 'sshd', 0.1, 'sleeping'),
];

/// More rows than a 132 px tall table shows.
final _many = [for (var pid = 1; pid <= 40; pid++) _Proc(pid, 'p$pid', 0, '')];

final _columns = <SortableTableColumn<_Proc>>[
  SortableTableColumn(
    id: 'name',
    label: 'Name',
    text: (proc) => proc.name,
    sortKey: (proc) => proc.name,
  ),
  SortableTableColumn(
    id: 'pid',
    label: 'PID',
    text: (proc) => '${proc.pid}',
    sortKey: (proc) => proc.pid,
    extent: const FixedColumnExtent(56),
    alignment: CellAlignment.end,
  ),
  SortableTableColumn(
    id: 'cpu',
    label: 'CPU',
    text: (proc) => proc.cpu == null ? 'unknown' : '${proc.cpu} %',
    sortKey: (proc) => proc.cpu,
    firstDirection: TableSortDirection.descending,
    extent: const FixedColumnExtent(72),
    alignment: CellAlignment.end,
  ),
  SortableTableColumn(
    id: 'state',
    label: 'State',
    text: (proc) => proc.state,
    extent: const FixedColumnExtent(80),
  ),
];

Finder _row(int pid) => find.byKey(ValueKey('$_tableId.row.$pid'));
Finder _header(String id) => find.byKey(ValueKey('$_tableId.column.$id'));

List<int> _pids(Iterable<_Proc> rows) => [for (final row in rows) row.pid];

/// The pids of [_procs] in the order the table draws them.
List<int> _drawnOrder(WidgetTester tester) {
  final drawn = [
    for (final proc in _procs)
      if (_row(proc.pid).evaluate().isNotEmpty)
        (pid: proc.pid, top: tester.getTopLeft(_row(proc.pid)).dy),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final entry in drawn) entry.pid];
}

/// Whether the focus ring is drawn on [row].
bool _ringed(WidgetTester tester, Finder row) => find
    .descendant(
      of: row,
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.foregroundDecoration != null,
      ),
    )
    .evaluate()
    .isNotEmpty;

/// Holds the sort and rows the way a panel controller does, so header
/// clicks and refreshes rebuild the table under test.
class _Host extends StatefulWidget {
  const _Host(this.rows, this.initialSort, this.table);

  final List<_Proc> rows;
  final TableSort? initialSort;
  final Widget Function(_HostState host) table;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late TableSort? sort = widget.initialSort;
  late List<_Proc> rows = widget.rows;

  void update(VoidCallback change) => setState(change);

  @override
  Widget build(BuildContext context) => widget.table(this);
}

Future<_HostState> _pump(
  WidgetTester tester, {
  List<_Proc> rows = _procs,
  List<SortableTableColumn<_Proc>>? columns,
  TableSort? sort,
  List<TableSort>? sorts,
  List<int>? activated,
  List<SidebarMenuEntry> Function(_Proc row)? rowActions,
  TargetPlatform platform = TargetPlatform.linux,
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 160),
}) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final theme = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  final host = _Host(
    rows,
    sort,
    (host) => SortableTable<_Proc>(
      tableId: _tableId,
      columns: columns ?? _columns,
      rows: host.rows,
      rowKey: (proc) => proc.pid,
      sort: host.sort,
      onSort: (next) {
        sorts?.add(next);
        host.update(() => host.sort = next);
      },
      onRowActivated: activated == null
          ? null
          : (proc) => activated.add(proc.pid),
      rowActions: rowActions,
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          // The golden captures this boundary, the table's own size.
          child: RepaintBoundary(
            child: SizedBox.fromSize(size: size, child: host),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

void main() {
  group('sortTableRows', () {
    List<int> sorted(TableSort? sort, [List<_Proc> rows = _procs]) =>
        _pids(sortTableRows(rows, _columns, sort));
    TableSort up(String id) => TableSort(id, TableSortDirection.ascending);
    TableSort down(String id) => TableSort(id, TableSortDirection.descending);

    test('keeps the caller order without a usable sort', () {
      expect(sorted(null), [1, 2, 3, 4]);
      expect(sorted(down('state')), [1, 2, 3, 4], reason: 'no sort key');
      expect(sorted(down('missing')), [1, 2, 3, 4], reason: 'no column');
    });

    test('orders by the column key in both directions', () {
      expect(sorted(up('name')), [2, 3, 4, 1]);
      expect(sorted(down('pid')), [4, 3, 2, 1]);
    });

    test('keeps tied rows in the caller order in both directions', () {
      // Over 33 rows: `List.sort` insertion-sorts shorter lists, which is
      // stable by itself and would hide a missing tie-break.
      final tied = [
        for (var pid = 0; pid < 100; pid++)
          _Proc(pid, '', (pid % 3).toDouble(), ''),
      ];
      List<int> cpu(int value) => [
        for (var pid = value; pid < 100; pid += 3) pid,
      ];
      expect(sorted(up('cpu'), tied), [...cpu(0), ...cpu(1), ...cpu(2)]);
      expect(sorted(down('cpu'), tied), [...cpu(2), ...cpu(1), ...cpu(0)]);
    });

    test('puts unknown values last in both directions', () {
      expect(sorted(up('cpu')), [1, 4, 2, 3]);
      expect(sorted(down('cpu')), [2, 1, 4, 3]);
    });

    test('a header click starts a new column in its first direction and '
        'flips the sorted one', () {
      expect(TableSort.next(null, _columns[2]), down('cpu'));
      expect(TableSort.next(down('cpu'), _columns[0]), up('name'));
      expect(TableSort.next(down('cpu'), _columns[2]), up('cpu'));
      expect(TableSort.next(up('cpu'), _columns[2]), down('cpu'));
    });
  });

  group('sorting from the header', () {
    testWidgets('a click sorts, a second click flips', (tester) async {
      final sorts = <TableSort>[];
      await _pump(tester, sorts: sorts);
      expect(_drawnOrder(tester), [1, 2, 3, 4]);

      await tester.tap(_header('cpu'));
      await tester.pumpAndSettle();
      expect(sorts.last, const TableSort('cpu', TableSortDirection.descending));
      expect(_drawnOrder(tester), [2, 1, 4, 3]);

      await tester.tap(_header('cpu'));
      await tester.pumpAndSettle();
      expect(sorts.last, const TableSort('cpu', TableSortDirection.ascending));
      expect(_drawnOrder(tester), [1, 4, 2, 3]);

      // A header without a sort key takes no click.
      await tester.tap(_header('state'));
      await tester.pumpAndSettle();
      expect(sorts, hasLength(2));
    });
  });

  group('semantics (A11Y-03)', () {
    testWidgets('headers announce their label, sort state and hint', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        sort: const TableSort('cpu', TableSortDirection.descending),
      );

      expect(
        tester.getSemantics(_header('cpu')),
        isSemantics(
          label: 'CPU',
          value: 'Sorted descending',
          hint: 'Sort by this column',
          isButton: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(_header('name')),
        isSemantics(label: 'Name', hint: 'Sort by this column', isButton: true),
      );
      expect(tester.getSemantics(_header('name')).value, isEmpty);
      expect(
        tester.getSemantics(_header('state')),
        isSemantics(label: 'State', isButton: false, hasTapAction: false),
      );
      expect(tester.getSemantics(_header('state')).hint, isEmpty);
      handle.dispose();
    });

    testWidgets('a row announces each cell with its column name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, activated: []);

      expect(
        tester.getSemantics(_row(2)),
        isSemantics(
          label: 'Name: nginx\nPID: 2\nCPU: 4.2 %\nState: running',
          isButton: true,
          hasTapAction: true,
          isFocusable: true,
          isFocused: false,
        ),
      );
      handle.dispose();
    });

    testWidgets('a screen reader\'s tap activates a row as a click does', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final activated = <int>[];
      await _pump(tester, activated: activated);

      final row = tester.getSemantics(_row(3));
      row.owner!.performAction(row.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(activated, [3]);
      expect(tester.getSemantics(_row(3)), isSemantics(isFocused: true));
      handle.dispose();
    });

    testWidgets('the row-action slot announces itself and the row exposes '
        'the enabled verbs', (tester) async {
      final handle = tester.ensureSemantics();
      final killed = <int>[];
      await _pump(
        tester,
        rowActions: (proc) => [
          SidebarMenuAction(
            label: 'Kill',
            onSelected: () => killed.add(proc.pid),
          ),
          const SidebarMenuAction(label: 'Renice', onSelected: null),
        ],
      );

      expect(
        tester.getSemantics(
          find.byKey(const ValueKey('$_tableId.rowActions.2')),
        ),
        isSemantics(tooltip: 'Row actions', isButton: true),
      );
      final row = tester.getSemantics(_row(2));
      expect(
        row,
        isSemantics(
          // The slot's button stays a node of its own, out of the label.
          label: 'Name: nginx\nPID: 2\nCPU: 4.2 %\nState: running',
          customActions: [const CustomSemanticsAction(label: 'Kill')],
        ),
      );

      row.owner!.performAction(
        row.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'Kill'),
        ),
      );
      expect(killed, [2]);
      handle.dispose();
    });

    testWidgets('a row without verbs keeps its slot empty: no button, menu, '
        'sheet or actions', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, rowActions: (_) => const []);

      // The slot keeps its width, so verbs added later move no column.
      expect(
        tester.getTopRight(_header('state')).dx,
        tester.getTopRight(find.byType(SortableTable<_Proc>)).dx -
            _desktopRowExtent,
      );
      expect(find.byType(IconButton), findsNothing);
      expect(
        tester.getSemantics(_row(2)),
        isSemantics(label: 'Name: nginx\nPID: 2\nCPU: 4.2 %\nState: running'),
      );
      // A right-click opens no menu, which would have taken focus.
      await tester.tap(_row(2), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(
        FocusManager.instance.primaryFocus?.debugLabel,
        isNot('SortableTable'),
      );
      handle.dispose();
    });

    testWidgets('a long press on a touch row without verbs opens no sheet', (
      tester,
    ) async {
      await _pump(
        tester,
        platform: TargetPlatform.android,
        rowActions: (_) => const [],
      );

      await tester.longPress(_row(2));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('keyboard focus', () {
    testWidgets('Tab reaches the body after the sortable headers and rings '
        'the first row', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);

      // A focused header says so, or a screen reader would not follow it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(_header('name')),
        isSemantics(label: 'Name', isFocusable: true, isFocused: true),
      );

      // Name, PID and CPU sort; State is a plain label.
      for (var stop = 1; stop < 4; stop++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      await tester.pumpAndSettle();

      expect(_ringed(tester, _row(1)), isTrue);
      expect(_ringed(tester, _row(2)), isFalse);
      expect(tester.getSemantics(_row(1)), isSemantics(isFocused: true));
      handle.dispose();
    });

    testWidgets('Tab and Shift+F10 scroll the active row back into view', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        rows: _many,
        size: const Size(400, 132),
        rowActions: (proc) => [
          SidebarMenuAction(label: 'Kill', onSelected: () {}),
        ],
      );
      final scroll = tester.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();

      for (var stop = 0; stop < 4; stop++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(1)), isTrue);
      expect(tester.getSemantics(_row(1)), isSemantics(isFocused: true));

      // The menu opens under the active row, so the row must show.
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(_row(1)).dy, 22);
      expect(find.widgetWithText(MenuItemButton, 'Kill'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('rows that arrive under focus get an active row', (
      tester,
    ) async {
      final host = await _pump(tester, rows: const []);
      for (var stop = 0; stop < 4; stop++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      host.update(() => host.rows = _procs);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(1)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(2)), isTrue, reason: 'Down skips no row');

      // A list that empties and refills, as on a reconnect, starts over.
      host.update(() => host.rows = const []);
      await tester.pumpAndSettle();
      host.update(() => host.rows = _procs);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(1)), isTrue);
    });

    testWidgets('the arrows, paging, Home and End move the active row and '
        'scroll it into view', (tester) async {
      // A 22 px header over a 110 px body: five rows show, a page is four.
      await _pump(tester, rows: _many, size: const Size(400, 132));
      await tester.tap(_row(1));
      await tester.pumpAndSettle();
      // A click focuses without a ring; the first key shows it.
      expect(_ringed(tester, _row(1)), isFalse);

      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.arrowDown);
      expect(_ringed(tester, _row(2)), isTrue);

      await press(LogicalKeyboardKey.pageDown);
      expect(_ringed(tester, _row(6)), isTrue);
      expect(tester.getBottomLeft(_row(6)).dy, 132);

      await press(LogicalKeyboardKey.end);
      expect(_ringed(tester, _row(40)), isTrue);
      expect(tester.getBottomLeft(_row(40)).dy, 132);

      await press(LogicalKeyboardKey.arrowDown);
      expect(_ringed(tester, _row(40)), isTrue, reason: 'stays on the last');

      await press(LogicalKeyboardKey.pageUp);
      expect(_ringed(tester, _row(36)), isTrue);
      expect(tester.getTopLeft(_row(36)).dy, 22);

      await press(LogicalKeyboardKey.home);
      expect(_ringed(tester, _row(1)), isTrue);
      expect(tester.getTopLeft(_row(1)).dy, 22);

      await press(LogicalKeyboardKey.arrowUp);
      expect(_ringed(tester, _row(1)), isTrue, reason: 'stays on the first');
    });

    testWidgets('Enter and a click activate a row', (tester) async {
      final activated = <int>[];
      await _pump(tester, activated: activated);

      await tester.tap(_row(3));
      await tester.pumpAndSettle();
      expect(activated, [3]);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(activated, [3, 4]);
    });

    testWidgets('Shift+F10 opens the active row\'s actions with focus in '
        'the menu', (tester) async {
      final killed = <int>[];
      await _pump(
        tester,
        rowActions: (proc) => [
          SidebarMenuAction(
            label: 'Kill',
            onSelected: () => killed.add(proc.pid),
          ),
        ],
      );
      await tester.tap(_row(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Kill'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(killed, [2]);
      expect(find.widgetWithText(MenuItemButton, 'Kill'), findsNothing);
    });

    testWidgets('the slot button and a right-click open the same actions', (
      tester,
    ) async {
      final killed = <int>[];
      final activated = <int>[];
      await _pump(
        tester,
        activated: activated,
        rowActions: (proc) => [
          SidebarMenuAction(
            label: 'Kill',
            onSelected: () => killed.add(proc.pid),
          ),
        ],
      );

      await tester.tap(find.byKey(const ValueKey('$_tableId.rowActions.3')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Kill'));
      await tester.pumpAndSettle();

      // A right-click leaves focus on the table: Esc closes the menu and
      // an arrow steps into it.
      await tester.tap(_row(4), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Kill'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(MenuItemButton, 'Kill'), findsNothing);

      await tester.tap(_row(4), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(killed, [3, 4]);

      // Enter steps in as an arrow does, never activating the row behind.
      await tester.tap(_row(2), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(activated, isEmpty);
      expect(killed, [3, 4, 2]);
    });

    testWidgets('a key over a menu without an enabled verb leaves the '
        'next menu unfocused', (tester) async {
      await _pump(
        tester,
        rowActions: (proc) => [
          SidebarMenuAction(
            label: 'Kill',
            onSelected: proc.pid == 1 ? null : () {},
          ),
        ],
      );
      await tester.tap(_row(1), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(_row(2), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'SortableTable');
    });

    testWidgets('Esc the table does not use reaches its host', (tester) async {
      await _pump(tester);
      showDialog<void>(
        context: tester.element(find.byType(_Host)),
        builder: (context) => Dialog(
          child: SizedBox(
            width: 300,
            height: 120,
            child: SortableTable<_Proc>(
              tableId: 'dialog',
              columns: _columns,
              rows: _procs,
              rowKey: (proc) => proc.pid,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('dialog.row.1')));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('the active row follows its key across a re-sort', (
      tester,
    ) async {
      // The header click below would otherwise hide the ring.
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      addTearDown(
        () => FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.automatic,
      );
      await _pump(tester);
      await tester.tap(_row(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(2)), isTrue);

      // Sorting by name moves nginx to the top; the ring goes with it.
      await tester.tap(_header('name'));
      await tester.pumpAndSettle();
      expect(_drawnOrder(tester), [2, 3, 4, 1]);
      expect(_ringed(tester, _row(2)), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(3)), isTrue);
    });

    testWidgets('the ring stays in place when its row disappears', (
      tester,
    ) async {
      final host = await _pump(tester);
      await tester.tap(_row(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(2)), isTrue);

      host.update(
        () => host.rows = [
          for (final proc in _procs)
            if (proc.pid != 2) proc,
        ],
      );
      await tester.pumpAndSettle();
      expect(_ringed(tester, _row(3)), isTrue);
    });
  });

  group('fixed row height', () {
    testWidgets('a drawn cell keeps the listing extent and is announced by '
        'its text', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        columns: [
          SortableTableColumn(
            id: 'name',
            label: 'Name',
            text: (proc) => proc.name,
            cell: (context, proc) => const SizedBox(height: 80),
          ),
        ],
      );

      for (final proc in _procs) {
        expect(tester.getSize(_row(proc.pid)).height, _desktopRowExtent);
      }
      expect(
        tester.getSize(find.byKey(const ValueKey('$_tableId.columns'))).height,
        _desktopRowExtent,
      );
      expect(tester.getSemantics(_row(2)), isSemantics(label: 'Name: nginx'));
      handle.dispose();
    });

    testWidgets('a header takes taps across the full row height', (
      tester,
    ) async {
      await _pump(tester, platform: TargetPlatform.android);
      // The touch target minimum, 48 dp.
      expect(tester.getSize(_header('pid')).height, _touchRowExtent);
    });

    testWidgets('rows grow with the text scale; touch rows are taller', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, size: const Size(600, 200));
      expect(tester.getSize(_row(1)).height, 2 * _desktopRowExtent);

      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await _pump(tester, platform: TargetPlatform.android);
      expect(tester.getSize(_row(1)).height, _touchRowExtent);
    });
  });

  testWidgets('a narrow table scrolls sideways instead of overflowing', (
    tester,
  ) async {
    await _pump(tester, size: const Size(200, 160));

    expect(tester.takeException(), isNull);
    final horizontal = find.byWidgetPredicate(
      (widget) =>
          widget is SingleChildScrollView &&
          widget.scrollDirection == Axis.horizontal,
    );
    expect(horizontal, findsOneWidget);
  });

  testWidgets('a narrow table keeps each flex column at its minimum', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(100, 160),
      columns: [
        SortableTableColumn(
          id: 'wide',
          label: 'Wide',
          text: (proc) => proc.name,
          extent: const FlexColumnExtent(3),
        ),
        SortableTableColumn(id: 'thin', label: 'Thin', text: (p) => p.state),
      ],
    );
    expect(tester.getSize(_header('thin')).width, 64);
  });

  group('golden', () {
    // Baselines are rendered on Linux, the platform CI's app job runs on;
    // other hosts rasterize text differently.
    final skip = !Platform.isLinux;

    for (final brightness in Brightness.values) {
      testWidgets('sorted by CPU with the second row focused, '
          '${brightness.name}', (tester) async {
        await _pump(
          tester,
          brightness: brightness,
          sort: const TableSort('cpu', TableSortDirection.descending),
          rowActions: (proc) => [
            SidebarMenuAction(label: 'Kill', onSelected: () {}),
          ],
        );
        await tester.tap(_row(2));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();

        await expectLater(
          find.byType(SortableTable<_Proc>),
          matchesGoldenFile('goldens/sortable_table_${brightness.name}.png'),
        );
      }, skip: skip);
    }
  });
}
