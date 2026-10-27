import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        GhostFileTheme,
        SidebarMenuAction,
        SidebarMenuEntry,
        ghostIsDesktopPlatform,
        scaledGhostFileRowExtent,
        showSidebarMenuSheet,
        sidebarMenuWidgets;

import '../l10n/app_localizations.dart';
import 'keyboard_map.dart';

/// Which way a [TableSort] orders its column.
enum TableSortDirection { ascending, descending }

/// Where a column's header and cells sit: text reads from the start edge,
/// figures line up on the end edge.
enum CellAlignment { start, end }

/// Who orders a [SortableTable]'s rows.
enum TableRowOrder {
  /// The table orders them by its [TableSort] ([sortTableRows]).
  bySort,

  /// The caller passes them in order, as a grouped list does that sorts
  /// within each group; the headers still show and change the sort.
  asGiven,
}

/// How a column claims horizontal space in a [SortableTable].
sealed class ColumnExtent {
  const ColumnExtent();
}

/// A width in logical pixels at a text scale of 1. It grows with the
/// ambient text scale, so larger type does not truncate the figures.
final class FixedColumnExtent extends ColumnExtent {
  const FixedColumnExtent(this.width);

  final double width;
}

/// A share of the width the fixed columns and the row-action slot leave.
final class FlexColumnExtent extends ColumnExtent {
  const FlexColumnExtent([this.flex = 1]) : assert(flex > 0);

  final int flex;
}

/// One column of a [SortableTable] over rows of type [R].
@immutable
final class SortableTableColumn<R> {
  const SortableTableColumn({
    required this.id,
    required this.label,
    required this.text,
    this.sortKey,
    this.firstDirection = TableSortDirection.ascending,
    this.extent = const FlexColumnExtent(),
    this.alignment = CellAlignment.start,
    this.cell,
  });

  /// The column's stable identity: what a [TableSort] names, and the
  /// header cell's key (`<tableId>.column.<id>`).
  final String id;

  /// The header text, and the column name announced with every cell
  /// (A11Y-03).
  final String label;

  /// The cell's value as text. It is drawn when [cell] is null and is
  /// always what a screen reader hears, so a drawn cell is never silent.
  final String Function(R row) text;

  /// What the column sorts by; null leaves the header a plain label. A
  /// null result is an unknown value (an LXC reading without lxcfs,
  /// SYS-04), which sorts last in both directions.
  final Comparable<Object>? Function(R row)? sortKey;

  /// The direction the first click on this header sorts in: figures whose
  /// largest values matter (CPU, memory) start descending.
  final TableSortDirection firstDirection;

  final ColumnExtent extent;
  final CellAlignment alignment;

  /// A drawn cell (a bar, an icon with its word) in place of the plain
  /// [text]. It is excluded from semantics, which read [text] instead.
  final Widget Function(BuildContext context, R row)? cell;

  bool get sortable => sortKey != null;
}

/// The column a [SortableTable] is sorted by and the direction.
@immutable
final class TableSort {
  const TableSort(this.columnId, this.direction);

  final String columnId;
  final TableSortDirection direction;

  /// The sort a click on [column]'s header asks for after [current]: the
  /// sorted column flips direction, any other column starts in its
  /// [SortableTableColumn.firstDirection].
  static TableSort next<R>(TableSort? current, SortableTableColumn<R> column) {
    if (current == null || current.columnId != column.id) {
      return TableSort(column.id, column.firstDirection);
    }
    return TableSort(
      column.id,
      current.direction == TableSortDirection.ascending
          ? TableSortDirection.descending
          : TableSortDirection.ascending,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TableSort &&
      other.columnId == columnId &&
      other.direction == direction;

  @override
  int get hashCode => Object.hash(columnId, direction);
}

/// [rows] in [sort]'s order, the table's one ordering rule:
///
/// - no sort, or one naming no sortable column, keeps the caller's order;
/// - rows whose keys tie keep the caller's order in both directions, so a
///   live refresh does not shuffle equal rows (Dart's `List.sort` is not
///   stable);
/// - unknown (null) keys sort last in both directions.
List<R> sortTableRows<R>(
  List<R> rows,
  List<SortableTableColumn<R>> columns,
  TableSort? sort,
) {
  if (sort == null) return rows;

  Comparable<Object>? Function(R row)? keyOf;
  for (final column in columns) {
    if (column.id == sort.columnId) keyOf = column.sortKey;
  }
  if (keyOf == null) return rows;

  final sign = sort.direction == TableSortDirection.ascending ? 1 : -1;
  final keyed = [
    for (var index = 0; index < rows.length; index++)
      (index: index, key: keyOf(rows[index])),
  ];
  keyed.sort((a, b) {
    final aKey = a.key;
    final bKey = b.key;
    final int order;
    if (aKey == null || bKey == null) {
      order = (aKey == null ? 1 : 0) - (bKey == null ? 1 : 0);
    } else {
      order = sign * aKey.compareTo(bKey);
    }
    return order != 0 ? order : a.index - b.index;
  });
  return [for (final entry in keyed) rows[entry.index]];
}

/// A single-key verb on a [SortableTable]'s active row (PLT-06, 03
/// §10.6), such as `l` for logs: [key] runs [run] on the row when
/// [appliesTo] holds, and [label] names it in the keyboard map.
@immutable
final class TableKeyAction<R> {
  const TableKeyAction({
    required this.key,
    required this.label,
    required this.run,
    this.appliesTo,
  });

  /// A letter key, pressed without modifiers.
  final LogicalKeyboardKey key;

  final String label;
  final ValueChanged<R> run;

  /// Whether the verb applies to a row; null applies it to every row. A
  /// key whose verb does not apply passes on.
  final bool Function(R row)? appliesTo;
}

/// The sortable semantic table the M2 lists (processes, services, jobs)
/// share, ahead of `ghost_ui`'s `GhostColumnTable` (F5e, v1; 03 §10.10):
///
/// - Columns are announced (A11Y-03): each cell reaches a screen reader
///   as "column: value" inside its row's node, and each header announces
///   its sort state and, when it sorts, a hint.
/// - The row-action slot: [rowActions] draws a trailing "…" button that
///   opens the row's verbs (a menu on desktop, a sheet on touch) and
///   exposes the enabled ones as the row's custom semantics actions.
/// - Keyboard focus: the body is one focus stop (the sortable headers
///   come before it) holding an active row, drawn with a ring while focus
///   is from the keyboard. ↑ and ↓, Page Up and Page Down, Home and End
///   move it, as `j` and `k` do (PLT-06); Enter or Space activates it;
///   Shift+F10 or the context-menu key opens its actions; [keyActions]
///   run single-key verbs on it; `/` moves focus to the list's filter
///   ([filterFocus]) and `?` shows the keyboard map. The active row
///   follows its [rowKey] across re-sorts and refreshes.
/// - Fixed row height: every row is the platform's listing extent (22 px
///   on desktop, 48 on touch) at the ambient text scale, so a refresh
///   never reflows the list and keyboard paging is exact.
///
/// Sort state is the caller's ([sort], [onSort]): a tab view disposes the
/// panes it hides, and the panel's controller keeps the order across
/// that. The table needs a bounded height; when the columns do not fit
/// the width it scrolls sideways rather than overflow. Sized to show
/// every row inside a scrolling page, it scrolls that page to the active
/// row and pages by what the page shows.
///
/// Flutter's table semantics roles are not used: their debug checks
/// require table, row and cell nodes to nest directly, which the
/// virtualized list's scroll node between them breaks.
class SortableTable<R> extends StatefulWidget {
  const SortableTable({
    super.key,
    required this.tableId,
    required this.columns,
    required this.rows,
    required this.rowKey,
    this.sort,
    this.onSort,
    this.onRowActivated,
    this.rowActions,
    this.empty,
    this.rowOrder = TableRowOrder.bySort,
    this.spanningRow,
    this.onShownRowsChanged,
    this.filterFocus,
    this.keyActions = const [],
  });

  /// Prefixes the keys of the header cells (`<tableId>.column.<id>`),
  /// the rows (`<tableId>.row.<rowKey>`) and their action buttons
  /// (`<tableId>.rowActions.<rowKey>`).
  final String tableId;

  final List<SortableTableColumn<R>> columns;

  /// The rows in the caller's order, which ties and an absent sort keep.
  final List<R> rows;

  /// A row's stable identity (a PID, a unit name): the active row follows
  /// it when the rows refresh or re-sort.
  final Object Function(R row) rowKey;

  final TableSort? sort;

  /// Called with [TableSort.next] when a sortable header is clicked; null
  /// leaves every header a plain label.
  final ValueChanged<TableSort>? onSort;

  /// A click or tap on a row, or Enter or Space on the active row.
  final ValueChanged<R>? onRowActivated;

  /// A row's verbs for the row-action slot; null draws no slot, and no
  /// verbs leave the row's slot empty. Shift+F10 opens them only when one
  /// top-level verb is enabled, so give each row one: the keyboard cannot
  /// reach verbs kept only in a submenu until `ghost_ui`'s
  /// `sidebarMenuWidgets` can focus a submenu.
  final List<SidebarMenuEntry> Function(R row)? rowActions;

  /// Shown under the header when [rows] is empty.
  final Widget? empty;

  final TableRowOrder rowOrder;

  /// A row drawn across the table's width in place of its cells, such as
  /// a group's heading; null for a row of cells. The widget carries the
  /// row's semantics label, which its cells would otherwise give.
  final Widget? Function(BuildContext context, R row)? spanningRow;

  /// Called after a frame or a scroll changes which rows the body shows,
  /// with those rows in order: what a view reads live figures for
  /// (CST-01).
  final ValueChanged<List<R>>? onShownRowsChanged;

  /// The list's filter field, which `/` focuses; null leaves `/` to pass
  /// on.
  final FocusNode? filterFocus;

  /// Single-key verbs on the active row, each a distinct letter other than
  /// `j` and `k`.
  final List<TableKeyAction<R>> keyActions;

  @override
  State<SortableTable<R>> createState() => _SortableTableState<R>();
}

/// The narrowest a flex column gets before the table scrolls sideways.
const _minFlexWidth = 64.0;
const _cellPadding = EdgeInsets.symmetric(horizontal: 8);
const _chevronSize = 14.0;
const _actionIconSize = 16.0;
const _focusRingWidth = 2.0;
const _separatorWidth = 1.0;

enum _Step { previous, next, pageUp, pageDown, first, last }

final class _MoveIntent extends Intent {
  const _MoveIntent(this.step);

  final _Step step;
}

final class _OpenRowActionsIntent extends Intent {
  const _OpenRowActionsIntent();
}

final class _ActivateRowIntent extends Intent {
  const _ActivateRowIntent();
}

final class _CloseMenuIntent extends Intent {
  const _CloseMenuIntent();
}

final class _FocusFilterIntent extends Intent {
  const _FocusFilterIntent();
}

final class _ShowKeyboardMapIntent extends Intent {
  const _ShowKeyboardMapIntent();
}

final class _KeyActionIntent extends Intent {
  const _KeyActionIntent(this.index);

  /// The verb's index in [SortableTable.keyActions].
  final int index;
}

/// An action that is enabled only while [enabled] holds, so a key the
/// table cannot use (Enter without [SortableTable.onRowActivated], an
/// arrow over no rows) passes on instead of being swallowed. Its intents
/// are private: under a shared one ([DismissIntent], [ActivateIntent]) a
/// disabled table action would still be the nearest an ancestor's binding
/// of the key finds, and the ancestor's own action would never run.
final class _TableAction<T extends Intent> extends Action<T> {
  _TableAction(this.enabled, this.onInvoke);

  final bool Function() enabled;
  final void Function(T intent) onInvoke;

  @override
  bool isEnabled(T intent) => enabled();

  @override
  Object? invoke(T intent) {
    onInvoke(intent);
    return null;
  }
}

/// Runs a [SortableTable.keyActions] verb on the active row; enabled only
/// while the verb applies to it, so the key otherwise passes on.
final class _KeyAction extends Action<_KeyActionIntent> {
  _KeyAction(this._table);

  final _SortableTableState<Object?> _table;

  @override
  bool isEnabled(_KeyActionIntent intent) => _table._keyActionApplies(intent);

  @override
  Object? invoke(_KeyActionIntent intent) {
    _table._runKeyAction(intent);
    return null;
  }
}

class _SortableTableState<R> extends State<SortableTable<R>> {
  static const _shortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(_Step.previous),
    SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(_Step.next),
    SingleActivator(LogicalKeyboardKey.keyK): _MoveIntent(_Step.previous),
    SingleActivator(LogicalKeyboardKey.keyJ): _MoveIntent(_Step.next),
    SingleActivator(LogicalKeyboardKey.pageUp): _MoveIntent(_Step.pageUp),
    SingleActivator(LogicalKeyboardKey.pageDown): _MoveIntent(_Step.pageDown),
    SingleActivator(LogicalKeyboardKey.home): _MoveIntent(_Step.first),
    SingleActivator(LogicalKeyboardKey.end): _MoveIntent(_Step.last),
    // Repeats may move the active row, never activate it.
    SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
        _ActivateRowIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false):
        _ActivateRowIntent(),
    SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
        _ActivateRowIntent(),
    SingleActivator(LogicalKeyboardKey.contextMenu, includeRepeats: false):
        _OpenRowActionsIntent(),
    SingleActivator(LogicalKeyboardKey.f10, shift: true, includeRepeats: false):
        _OpenRowActionsIntent(),
    SingleActivator(LogicalKeyboardKey.escape): _CloseMenuIntent(),
    SingleActivator(LogicalKeyboardKey.slash, includeRepeats: false):
        _FocusFilterIntent(),
    // `?` is Shift+/ on some layouts and its own key on others.
    CharacterActivator('?', includeRepeats: false): _ShowKeyboardMapIntent(),
  };

  /// [_shortcuts] and a binding per [SortableTable.keyActions] verb.
  Map<ShortcutActivator, Intent> get _allShortcuts => {
    ..._shortcuts,
    for (final (index, action) in widget.keyActions.indexed)
      SingleActivator(action.key, includeRepeats: false): _KeyActionIntent(
        index,
      ),
  };

  final _scroll = ScrollController();
  final _focus = FocusNode(debugLabel: 'SortableTable');
  final _firstVerbFocus = FocusNode(debugLabel: 'SortableTable menu');
  final _menu = MenuController();
  final _bodyKey = GlobalKey();
  late final Map<Type, Action<Intent>> _actions = {
    _MoveIntent: _TableAction<_MoveIntent>(
      () => _sorted.isNotEmpty,
      (intent) => _move(intent.step),
    ),
    // Over a menu a pointer opened, Enter steps in as an arrow does
    // rather than activating the row behind it.
    _ActivateRowIntent: _TableAction<_ActivateRowIntent>(
      () =>
          _menu.isOpen ||
          (widget.onRowActivated != null && _activeIndex != null),
      (_) => _menu.isOpen
          ? _focusMenu()
          : widget.onRowActivated!(_sorted[_activeIndex!]),
    ),
    _OpenRowActionsIntent: _TableAction<_OpenRowActionsIntent>(
      () =>
          _activeIndex != null &&
          _semanticsActions(widget.rowActions?.call(_sorted[_activeIndex!])) !=
              null,
      (_) => _openActions(_activeIndex!),
    ),
    // A menu a pointer opened leaves focus on the body: Esc closes it.
    _CloseMenuIntent: _TableAction<_CloseMenuIntent>(
      () => _menu.isOpen,
      (_) => _menu.close(),
    ),
    _FocusFilterIntent: _TableAction<_FocusFilterIntent>(
      () => widget.filterFocus?.canRequestFocus ?? false,
      (_) => widget.filterFocus!.requestFocus(),
    ),
    _ShowKeyboardMapIntent: _TableAction<_ShowKeyboardMapIntent>(
      () => true,
      (_) => showKeyboardMap(context, list: _keyboardMap()),
    ),
    _KeyActionIntent: _KeyAction(this),
  };

  List<R> _sorted = const [];

  /// The active row by identity, and its index in [_sorted]. The index
  /// outlives a vanished key for one re-sort, so the ring stays where it
  /// was rather than jumping to the top.
  Object? _activeKey;
  int? _activeIndex;

  bool _hasFocus = false;

  /// Whether the body last lost focus to another route or window, or to
  /// the root scope while the app was inactive: its scope then still names
  /// it the focused child, and focus comes back when that closes rather
  /// than by the user's navigation.
  bool _focusParked = false;
  bool _showRing = false;
  double _rowExtent = 0;
  List<SidebarMenuEntry> _menuEntries = const [];

  /// The keys of the rows [SortableTable.onShownRowsChanged] last heard.
  List<Object>? _shownKeys;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_reportShown);
    _resort();
  }

  @override
  void didUpdateWidget(SortableTable<R> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resort();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    _firstVerbFocus.dispose();
    super.dispose();
  }

  void _resort() {
    _sorted = switch (widget.rowOrder) {
      TableRowOrder.bySort => sortTableRows(
        widget.rows,
        widget.columns,
        widget.sort,
      ),
      TableRowOrder.asGiven => widget.rows,
    };
    final key = _activeKey;
    if (key == null) {
      // Rows arriving while the body has focus need an active row.
      if (_hasFocus && _sorted.isNotEmpty) _setActive(0);
      return;
    }

    final found = _sorted.indexWhere((row) => widget.rowKey(row) == key);
    if (found >= 0) {
      _activeIndex = found;
    } else if (_sorted.isEmpty) {
      _activeKey = _activeIndex = null;
    } else {
      _setActive(math.min(_activeIndex ?? 0, _sorted.length - 1));
    }
  }

  /// Tells [SortableTable.onShownRowsChanged] which rows the body shows,
  /// when they changed: the fixed extent makes them exact without
  /// building them.
  void _reportShown() {
    final report = widget.onShownRowsChanged;
    if (report == null || !mounted) return;

    var shown = <R>[];
    if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
      final position = _scroll.position;
      final first = (position.pixels / _rowExtent).floor();
      final end = ((position.pixels + _shownHeight()) / _rowExtent).ceil();
      shown = _sorted.sublist(
        first.clamp(0, _sorted.length),
        end.clamp(0, _sorted.length),
      );
    }
    final keys = [for (final row in shown) widget.rowKey(row)];
    final before = _shownKeys;
    if (before != null && listEquals(before, keys)) return;

    _shownKeys = keys;
    report(shown);
  }

  void _setActive(int index) {
    _activeIndex = index;
    _activeKey = widget.rowKey(_sorted[index]);
  }

  void _onFocusChange(bool focused) {
    // A node taking focus within the scope becomes its focused child.
    if (!focused) _focusParked = _focus.enclosingScope?.focusedChild == _focus;
    setState(() {
      _hasFocus = focused;
      if (focused && _activeIndex == null && _sorted.isNotEmpty) {
        _setActive(0);
      }
    });
    if (!focused) return;

    // Tab may return to a row a wheel or a re-sort moved out of view,
    // where it would be neither built nor ringed. A page around the table
    // follows the user's navigation only: focus that a closed route or a
    // resumed window hands back leaves the page where it was read.
    _revealInBody();
    if (!_focusParked) _revealInPage();
  }

  void _move(_Step step) {
    // A menu a pointer opened leaves focus on the body: a key steps in.
    if (_menu.isOpen) {
      _focusMenu();
      return;
    }

    final current = _activeIndex;
    final page = math.max(1, (_shownHeight() / _rowExtent).floor() - 1);
    // With no active row yet, any key makes the first row active.
    final target = current == null
        ? 0
        : switch (step) {
            _Step.previous => current - 1,
            _Step.next => current + 1,
            _Step.pageUp => current - page,
            _Step.pageDown => current + page,
            _Step.first => 0,
            _Step.last => _sorted.length - 1,
          };
    setState(() => _setActive(target.clamp(0, _sorted.length - 1)));
    _reveal();
  }

  /// How much of the body a screen shows: its own viewport, or less where
  /// a page scrolling around the table is shorter, as for a table sized
  /// to show every row.
  double _shownHeight() {
    final own = _scroll.position.viewportDimension;
    final page = Scrollable.maybeOf(context, axis: Axis.vertical);
    return page == null ? own : math.min(own, page.position.viewportDimension);
  }

  /// Shows the active row whole, in the body and then in any page around
  /// the table.
  void _reveal() {
    _revealInBody();
    _revealInPage();
  }

  /// Scrolls the body the least distance that shows the active row whole;
  /// the fixed extent makes its offset exact without building it.
  void _revealInBody() {
    final index = _activeIndex;
    if (index == null || !_scroll.hasClients) return;

    final position = _scroll.position;
    final top = index * _rowExtent;
    final shown = position.pixels.clamp(
      math.min(top, top + _rowExtent - position.viewportDimension),
      top,
    );
    _scroll.jumpTo(
      shown
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
  }

  /// Asks a page scrolling around the table to show the active row, as for
  /// a table sized to show every row: across the row's full width, so a
  /// sideways scroll stays where it is.
  void _revealInPage() {
    final index = _activeIndex;
    final body = _bodyKey.currentContext?.findRenderObject();
    if (index == null || !_scroll.hasClients) return;
    if (body is! RenderBox || !body.hasSize) return;

    body.showOnScreen(
      rect: Rect.fromLTWH(
        0,
        index * _rowExtent - _scroll.offset,
        body.size.width,
        _rowExtent,
      ),
    );
  }

  void _onRowTap(int index) {
    setState(() => _setActive(index));
    _focus.requestFocus();
    widget.onRowActivated?.call(_sorted[index]);
  }

  bool get _touch => !ghostIsDesktopPlatform(Theme.of(context).platform);

  /// Opens row [index]'s verbs, making it the active row in the focused
  /// body: a sheet on touch, else the menu at the pointer's [global]
  /// position or, from the keyboard, under the row. The keyboard's menu
  /// takes focus once it has mounted, or its arrows would still walk the
  /// rows behind it; a pointer's leaves it on the body, so no verb shows
  /// a focus fill the click did not ask for.
  R? get _activeRow => _activeIndex == null ? null : _sorted[_activeIndex!];

  bool _keyActionApplies(_KeyActionIntent intent) {
    final row = _activeRow;
    if (row == null || intent.index >= widget.keyActions.length) return false;
    return widget.keyActions[intent.index].appliesTo?.call(row) ?? true;
  }

  void _runKeyAction(_KeyActionIntent intent) =>
      widget.keyActions[intent.index].run(_activeRow as R);

  /// The keys this table takes, for its `?` (PLT-06).
  List<KeyboardMapEntry> _keyboardMap() {
    final l10n = AppLocalizations.of(context);
    return [
      KeyboardMapEntry(l10n.keyboardMapMoveKeys, l10n.keyboardMapMove),
      if (widget.onRowActivated != null)
        KeyboardMapEntry(l10n.keyboardMapOpenKeys, l10n.keyboardMapOpen),
      if (widget.rowActions != null)
        KeyboardMapEntry(
          l10n.keyboardMapRowActionsKeys,
          l10n.keyboardMapRowActions,
        ),
      for (final action in widget.keyActions)
        KeyboardMapEntry(action.key.keyLabel, action.label),
      if (widget.filterFocus != null)
        KeyboardMapEntry('/', l10n.keyboardMapFilter),
      KeyboardMapEntry('?', l10n.keyboardMapShow),
    ];
  }

  void _openActions(int index, {Offset? global}) {
    final row = _sorted[index];
    final entries = widget.rowActions!(row);
    setState(() {
      _setActive(index);
      _menuEntries = entries;
    });
    _focus.requestFocus();
    if (_touch) {
      unawaited(
        showSidebarMenuSheet(
          context,
          title: widget.columns.first.text(row),
          entries: entries,
        ),
      );
      return;
    }

    // The keyboard's menu opens under the row, which may be scrolled away.
    if (global == null) _reveal();
    final body = _bodyKey.currentContext!.findRenderObject()! as RenderBox;
    _menu.open(
      position: global == null
          ? Offset(0, (index + 1) * _rowExtent - _scroll.offset)
          : body.globalToLocal(global),
    );
    if (global != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _menu.isOpen) _focusMenu();
    });
  }

  /// Focuses the open menu's first enabled verb, if it has one: a request
  /// on the detached node would wait and seize focus in whichever menu
  /// next mounts it.
  void _focusMenu() {
    if (_firstVerbFocus.parent != null) _firstVerbFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    _rowExtent = scaledGhostFileRowExtent(context);
    // New rows, a new extent or a new viewport may show other rows.
    if (widget.onShownRowsChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reportShown());
    }
    var minWidth = widget.rowActions == null ? 0.0 : _rowExtent;
    final flexes = <int>[];
    for (final column in widget.columns) {
      switch (column.extent) {
        case FixedColumnExtent(:final width):
          minWidth += scaler.scale(width);
        case FlexColumnExtent(:final flex):
          flexes.add(flex);
      }
    }
    if (flexes.isNotEmpty) {
      // The flex columns split their space by flex, so it is sized for
      // the least of them to reach the minimum.
      minWidth +=
          scaler.scale(_minFlexWidth) *
          flexes.reduce((a, b) => a + b) /
          flexes.reduce(math.min);
    }

    final empty = widget.empty;
    final body = MenuAnchor(
      controller: _menu,
      // Focus returns to the table when the menu closes.
      childFocusNode: _focus,
      menuChildren: sidebarMenuWidgets(
        _menuEntries,
        firstFocus: _firstVerbFocus,
      ),
      child: FocusableActionDetector(
        key: _bodyKey,
        focusNode: _focus,
        // The active row carries the focused flag instead: a node for the
        // whole body would announce nothing useful.
        includeFocusSemantics: false,
        // One stop for the body: Shift+F10 reaches a row's actions, not a
        // Tab stop per row.
        descendantsAreFocusable: false,
        shortcuts: _allShortcuts,
        actions: _actions,
        onFocusChange: _onFocusChange,
        onShowFocusHighlight: (show) => setState(() => _showRing = show),
        child: _sorted.isEmpty && empty != null
            ? empty
            : ListView.builder(
                controller: _scroll,
                itemExtent: _rowExtent,
                itemCount: _sorted.length,
                itemBuilder: _row,
              ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget table = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Expanded(child: body),
          ],
        );
        if (constraints.maxWidth < minWidth) {
          table = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: minWidth, child: table),
          );
        }
        // The cells' ink paints on this Material, which also carries the
        // listing's colour.
        return Material(
          color: GhostFileTheme.of(context).paneBackground,
          child: table,
        );
      },
    );
  }

  /// [cells] in the columns' extents, then the row-action slot (empty
  /// when [slot] is null), so the header and every row line up.
  Widget _laidOut(
    BuildContext context,
    List<Widget> cells, {
    Widget? slot,
    CrossAxisAlignment cross = CrossAxisAlignment.center,
  }) {
    final scaler = MediaQuery.textScalerOf(context);
    return Row(
      crossAxisAlignment: cross,
      children: [
        for (var index = 0; index < cells.length; index++)
          switch (widget.columns[index].extent) {
            FixedColumnExtent(:final width) => SizedBox(
              width: scaler.scale(width),
              child: cells[index],
            ),
            FlexColumnExtent(:final flex) => Expanded(
              flex: flex,
              child: cells[index],
            ),
          },
        if (widget.rowActions != null)
          SizedBox(width: _rowExtent, height: _rowExtent, child: slot),
      ],
    );
  }

  Widget _header(BuildContext context) {
    return Container(
      key: ValueKey('${widget.tableId}.columns'),
      height: _rowExtent,
      // Full-height cells under the separator, not above it: a header
      // takes taps across the whole row (48 dp on touch).
      foregroundDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: GhostFileTheme.of(context).separator,
            width: _separatorWidth,
          ),
        ),
      ),
      child: _laidOut(context, [
        for (final column in widget.columns) _headerCell(context, column),
      ], cross: CrossAxisAlignment.stretch),
    );
  }

  Widget _headerCell(BuildContext context, SortableTableColumn<R> column) {
    final l10n = AppLocalizations.of(context);
    final fileTheme = GhostFileTheme.of(context);
    final theme = Theme.of(context);
    final sort = widget.sort;
    final onSort = widget.onSort;
    final sorted = column.sortable && sort?.columnId == column.id;
    final ascending = sort?.direction == TableSortDirection.ascending;
    final VoidCallback? onTap = column.sortable && onSort != null
        ? () => onSort(TableSort.next(sort, column))
        : null;
    final end = column.alignment == CellAlignment.end;

    final label = Flexible(
      child: Text(
        column.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: theme.textTheme.labelSmall?.copyWith(
          color: sorted ? theme.colorScheme.onSurface : fileTheme.secondaryText,
          fontWeight: sorted ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
    // An empty icon keeps the label where it sits while unsorted.
    final chevron = Icon(
      sorted
          ? (ascending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down)
          : null,
      size: _chevronSize,
      color: fileTheme.secondaryText,
    );
    return Semantics(
      key: ValueKey('${widget.tableId}.column.${column.id}'),
      container: true,
      button: onTap != null,
      label: column.label,
      value: sorted
          ? (ascending ? l10n.tableSortedAscending : l10n.tableSortedDescending)
          : null,
      hint: onTap == null ? null : l10n.tableSortHint,
      onTap: onTap,
      // The InkWell's focus flags merge into this node; only the drawn
      // label is excluded, which [label] already says.
      child: InkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        hoverColor: fileTheme.hoverFill,
        child: ExcludeSemantics(
          child: Padding(
            // The label centres clear of the separator.
            padding: _cellPadding.copyWith(bottom: _separatorWidth),
            child: Row(
              mainAxisAlignment: end
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: end ? [chevron, label] : [label, chevron],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, int index) {
    final l10n = AppLocalizations.of(context);
    final fileTheme = GhostFileTheme.of(context);
    final row = _sorted[index];
    final key = widget.rowKey(row);
    final active = index == _activeIndex;
    // A row without verbs keeps its slot, empty, so verbs added later move
    // no column: the Processes tab's slot waits for PRC-02 (M4).
    final entries = switch (widget.rowActions?.call(row)) {
      final verbs? when verbs.isNotEmpty => verbs,
      _ => null,
    };

    final slot = entries == null
        ? null
        : Builder(
            builder: (button) => IconButton(
              key: ValueKey('${widget.tableId}.rowActions.$key'),
              tooltip: l10n.tableRowActions,
              iconSize: _actionIconSize,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_horiz),
              onPressed: () {
                final box = button.findRenderObject()! as RenderBox;
                _openActions(
                  index,
                  global: box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                );
              },
            ),
          );
    return Semantics(
      key: ValueKey('${widget.tableId}.row.$key'),
      container: true,
      button: widget.onRowActivated != null,
      focusable: true,
      focused: active && _hasFocus,
      customSemanticsActions: _semanticsActions(entries),
      // A screen reader's tap is a click: the row becomes active too.
      onTap: widget.onRowActivated == null ? null : () => _onRowTap(index),
      child: InkWell(
        canRequestFocus: false,
        excludeFromSemantics: true,
        hoverColor: fileTheme.hoverFill,
        onTap: () => _onRowTap(index),
        onSecondaryTapUp: entries == null || _touch
            ? null
            : (details) => _openActions(index, global: details.globalPosition),
        onLongPress: entries == null || !_touch
            ? null
            : () => _openActions(index),
        child: Container(
          // Over the cells, so the ring shifts nothing while it shows.
          foregroundDecoration: active && _showRing
              ? BoxDecoration(
                  border: Border.all(
                    color: fileTheme.activePaneIndicator,
                    width: _focusRingWidth,
                  ),
                )
              : null,
          child:
              widget.spanningRow?.call(context, row) ??
              _laidOut(context, [
                for (final column in widget.columns)
                  _cell(context, column, row),
              ], slot: slot),
        ),
      ),
    );
  }

  Widget _cell(BuildContext context, SortableTableColumn<R> column, R row) {
    final text = column.text(row);
    final drawn = column.cell;
    final style = Theme.of(context).textTheme.bodyMedium;
    final end = column.alignment == CellAlignment.end;
    return Semantics(
      label: text.isEmpty
          ? null
          : AppLocalizations.of(context).tableCellSemantics(column.label, text),
      excludeSemantics: true,
      child: Padding(
        padding: _cellPadding,
        child: drawn != null
            ? drawn(context, row)
            : Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                textAlign: end ? TextAlign.end : TextAlign.start,
                // Figures line up digit under digit.
                style: end
                    ? style?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )
                    : style,
              ),
      ),
    );
  }
}

/// A row's enabled top-level verbs as custom semantics actions (TalkBack's
/// and VoiceOver's actions menus), as `ghost_ui`'s sidebar rows expose
/// theirs. Null when there is none, so a verbless row does not advertise
/// an empty actions menu.
Map<CustomSemanticsAction, VoidCallback>? _semanticsActions(
  List<SidebarMenuEntry>? entries,
) {
  final actions = <CustomSemanticsAction, VoidCallback>{
    for (final entry in entries ?? const <SidebarMenuEntry>[])
      if (entry case SidebarMenuAction(:final label, :final onSelected?))
        CustomSemanticsAction(label: label): onSelected,
  };
  return actions.isEmpty ? null : actions;
}
