import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/log_reads.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import 'actions/action_preview.dart' show startAction;
import 'actions/host_actions.dart';
import 'quick_actions.dart' show PinServiceButton;
import 'failed_units_summary.dart';
import 'logs/log_level.dart';
import 'logs/log_view.dart';
import 'logs/log_view_controller.dart';
import 'services_view.dart';
import 'server_surfaces.dart' show ServerPanel;
import 'sortable_table.dart';
import 'unit_details.dart';
import 'workspace_navigation.dart';

/// The panel width from which the unit table adds its load and description
/// columns and a unit's page opens under the table instead of in its
/// place. It grows with the text scale, as the table's columns do, so
/// larger text takes the narrow layout before the table would scroll
/// sideways.
const double _wideWidth = 600;

/// The share of its height a header takes before it scrolls, so large
/// text never pushes a table or log view out of sight.
const double _headerShare = 0.4;

/// The share of the screen SVC-04's sheet opens at, and the least it
/// drags down to before it closes.
const double _logSheetShare = 0.6;
const double _logSheetMinShare = 0.25;

/// The unit table's columns, whose names key them.
enum _Column { unit, load, active, sub, description }

/// Where a unit's page shows SVC-04's recent journal lines.
enum UnitLogPlacement {
  /// Under the unit's states.
  inline,

  /// In a bottom sheet the page opens, as a phone shows logs (03 §10.5,
  /// PLT-02).
  sheet,
}

/// The Services tab (03 §10.2, §7.5): SVC-01's units with their load,
/// active and sub states, filtered by type and active state; SVC-02's
/// failed units; and a unit's page with its states and SVC-04's recent
/// journal lines.
///
/// It reads the `units` stream its [SampledSurface] subscribes from
/// [MonitoringController]'s box. A unit's page reads its journal lines
/// with [MonitoringController.openLogRead] while [visible], or while the
/// sheet a phone shows them in is open ([logPlacement]), and says what
/// the read is doing until lines arrive. States the host could not read
/// show as unknown (CN-10). Nothing animates (A11Y-11).
class ServicesPanel extends StatefulWidget {
  const ServicesPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
    this.logPlacement = UnitLogPlacement.inline,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// Whether the panel's tab shows; see [SampledSurface.visible].
  final bool visible;

  /// Where a unit's page shows its recent journal lines.
  final UnitLogPlacement logPlacement;

  @override
  State<ServicesPanel> createState() => _ServicesPanelState();
}

class _ServicesPanelState extends State<ServicesPanel> {
  late ValueListenable<Sample?> _units;

  /// Whose units the panel lists: the system manager's, or the login
  /// user's own (SVC-09), whose stream it subscribes while it shows them.
  UnitScope _scope = UnitScope.system;

  /// The subscription that reads the login user's units while [_scope]
  /// is theirs and the panel shows; this panel's own, as each sampled
  /// surface's is, so another panel on the server never ends it.
  late final _userSubscription = widget.monitoring.newSubscriptionId(
    '${ServerPanel.services.name}.user',
  );

  /// The filters, order and open unit, which outlive tab switches: the
  /// workspace keeps a panel built once opened. Services lead, since most
  /// other units are devices, mounts and slices.
  UnitFilter<UnitType> _type = (any: false, value: UnitType.service);
  UnitFilter<UnitActiveState> _state = (any: true, value: null);
  TableSort? _sort;

  /// The open unit, with its page's key: the page and its read keep their
  /// place in the tree across the wide and narrow layouts, as the list
  /// does, and a page per unit and server has a read of its own.
  ({String name, GlobalKey key})? _open;
  final _listKey = GlobalKey();

  /// The list's and the page's focus, and the page's close button. A
  /// narrow panel hides the list behind the page, where a focused table
  /// would still take keys: focus moves to the close button then, and
  /// [_returnFocus], what held it in the list, gets it back when the page
  /// closes (03 §10.10).
  final _listFocus = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _pageFocus = FocusNode(canRequestFocus: false, skipTraversal: true);
  final _closeFocus = FocusNode();
  FocusNode? _returnFocus;

  /// Where the command palette asks for a unit to open.
  WorkspaceNavigation? _navigation;

  @override
  void initState() {
    super.initState();
    _attach();
    _followUser();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final navigation = WorkspaceNavigationScope.maybeOf(context);
    if (identical(navigation, _navigation)) return;
    _navigation?.removeListener(_onNavigation);
    _navigation = navigation?..addListener(_onNavigation);
    // The palette's request may be what built this panel.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNavigation());
  }

  @override
  void didUpdateWidget(ServicesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId == oldWidget.serverId &&
        widget.monitoring == oldWidget.monitoring) {
      if (widget.visible != oldWidget.visible) _followUser();
      return;
    }

    oldWidget.monitoring.unsubscribe(oldWidget.serverId, _userSubscription);
    _units.removeListener(_onUnits);
    _attach();
    _followUser();
    _open = null;
    _returnFocus = null;
    // A request may have selected the server this panel now shows.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onNavigation());
  }

  @override
  void dispose() {
    _navigation?.removeListener(_onNavigation);
    widget.monitoring.unsubscribe(widget.serverId, _userSubscription);
    _units.removeListener(_onUnits);
    _listFocus.dispose();
    _pageFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  void _attach() {
    _units = widget.monitoring.sampleFor(widget.serverId, switch (_scope) {
      UnitScope.system => SampleStream.units,
      UnitScope.user => SampleStream.userUnits,
    })..addListener(_onUnits);
  }

  /// Reads the login user's units while they are listed and the panel
  /// shows; the system's come with the panel's own streams.
  void _followUser() {
    if (_scope == UnitScope.user && widget.visible) {
      widget.monitoring.subscribe(widget.serverId, _userSubscription, const {
        SampleStream.userUnits,
      });
    } else {
      widget.monitoring.unsubscribe(widget.serverId, _userSubscription);
    }
  }

  void _setScope(UnitScope scope) {
    if (scope == _scope) return;
    _units.removeListener(_onUnits);
    setState(() {
      _scope = scope;
      _open = null;
      _returnFocus = null;
    });
    _attach();
    _followUser();
  }

  void _onUnits() => setState(() {});

  /// Opens [unit]'s page, unless its name ends in no unit type: a text
  /// row the host misread names no unit whose journal it could read.
  void _openUnit(SystemdUnit unit) {
    if (_open?.name == unit.unit || unitStatesOf(unit).type == null) return;
    setState(() => _open = (name: unit.unit, key: GlobalKey()));
  }

  /// Opens the unit the command palette asked for, once this server's.
  void _onNavigation() {
    if (!mounted) return;
    final unit = _navigation?.takeUnit(widget.serverId);
    if (unit == null) return;

    // The palette lists the system manager's units.
    _setScope(UnitScope.system);
    if (_open?.name == unit) return;
    setState(() => _open = (name: unit, key: GlobalKey()));
  }

  void _close() {
    final restore = _pageFocus.hasFocus ? _returnFocus : null;
    _returnFocus = null;
    setState(() => _open = null);
    if (restore == null) return;

    // The list shows again, and may take focus, once rebuilt; a table
    // the list no longer holds has nothing to take.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (restore.parent != null && restore.canRequestFocus) {
        restore.requestFocus();
      }
    });
  }

  /// Moves focus from the hidden list into the page shown in its place.
  void _focusPage() {
    if (!mounted || _open == null || !_listFocus.hasFocus) return;

    _returnFocus = FocusManager.instance.primaryFocus;
    _closeFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final result = _units.value?.result;
    final units = result is UnitsResult ? result.units : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >=
            MediaQuery.textScalerOf(context).scale(_wideWidth);
        final padding = EdgeInsets.all(wide ? 20 : 16);
        final open = _open;
        final page = open == null
            ? null
            : Focus(
                focusNode: _pageFocus,
                includeSemantics: false,
                child: _UnitPage(
                  key: open.key,
                  monitoring: widget.monitoring,
                  serverId: widget.serverId,
                  name: open.name,
                  unit: _find(units, open.name),
                  visible: widget.visible,
                  wide: wide,
                  logPlacement: widget.logPlacement,
                  closeFocus: _closeFocus,
                  onClose: _close,
                  scope: _scope,
                ),
              );
        // The list keeps its place in the tree, so opening a unit keeps the
        // table's focus, active row and scroll position.
        final list = KeyedSubtree(
          key: _listKey,
          child: Focus(
            focusNode: _listFocus,
            includeSemantics: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SegmentedButton<UnitScope>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: UnitScope.system,
                        label: Text(l10n.servicesScopeSystem),
                      ),
                      ButtonSegment(
                        value: UnitScope.user,
                        label: Text(l10n.servicesScopeUser),
                      ),
                    ],
                    selected: {_scope},
                    onSelectionChanged: (selected) =>
                        _setScope(selected.single),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: _list(l10n, units, result, wide: wide)),
              ],
            ),
          ),
        );
        if (page == null) return Padding(padding: padding, child: list);
        if (wide) {
          return Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: list),
                const Divider(height: 24),
                Expanded(flex: 2, child: page),
              ],
            ),
          );
        }

        // A narrow panel shows the page in the list's place, as a phone
        // pushes details (03 §10.5), and Back returns to the list. A
        // hidden tab stays mounted, so Back is left to the route then.
        // Focus the hidden list holds moves to the page once it shows.
        WidgetsBinding.instance.addPostFrameCallback((_) => _focusPage());
        return PopScope(
          canPop: !widget.visible,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && widget.visible) _close();
          },
          child: Padding(
            padding: padding,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Visibility(visible: false, maintainState: true, child: list),
                page,
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _list(
    AppLocalizations l10n,
    UnitsSnapshot? units,
    SampleResult? result, {
    required bool wide,
  }) {
    final theme = Theme.of(context);
    if (units == null) {
      return switch (result) {
        // Without a login session or linger the user manager is not
        // there to ask (SVC-09).
        final CollectorUnavailable unavailable when _scope == UnitScope.user =>
          _notice(
            theme,
            Icons.person_off_outlined,
            l10n.servicesUserUnavailable,
            unavailable.detail,
          ),
        final CollectorUnavailable unavailable => _unavailable(
          l10n,
          theme,
          unavailable,
        ),
        _ => _notice(theme, Icons.hourglass_empty, l10n.servicesWaiting),
      };
    }
    // A reply without a unit list block lists nothing.
    if (units.format == UnitListFormat.none) {
      return _notice(theme, Icons.error_outline, l10n.servicesUnavailableError);
    }

    final states = [for (final unit in units.units) unitStatesOf(unit)];
    return _headed(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (units.format == UnitListFormat.text)
            _notice(theme, Icons.info_outline, l10n.servicesTextFallback),
          FailedUnitsSummary(failed: units.failed, onUnitSelected: _openUnit),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _labelled(
                theme,
                l10n.servicesFilterType,
                _filterMenu(
                  l10n,
                  theme,
                  anyLabel: l10n.servicesFilterTypeAll,
                  choices: filterChoices(
                    states.map((unit) => unit.type),
                    UnitType.values,
                    _type,
                  ),
                  selected: _type,
                  onSelected: (filter) => setState(() => _type = filter),
                ),
              ),
              _labelled(
                theme,
                l10n.servicesFilterState,
                _filterMenu(
                  l10n,
                  theme,
                  anyLabel: l10n.servicesFilterStateAll,
                  choices: filterChoices(
                    states.map((unit) => unit.active),
                    UnitActiveState.values,
                    _state,
                  ),
                  selected: _state,
                  onSelected: (filter) => setState(() => _state = filter),
                ),
              ),
            ],
          ),
        ],
      ),
      body: SortableTable<SystemdUnit>(
        tableId: SampleStream.units.name,
        columns: _columns(l10n, wide: wide),
        rows: filterUnits(units.units, type: _type, state: _state),
        rowKey: (unit) => unit.unit,
        sort: _sort,
        onSort: (sort) => setState(() => _sort = sort),
        onRowActivated: _openUnit,
        // `l` opens the unit's page, which leads with its logs on a
        // desktop; `r` restarts it through the action's confirmation
        // (PLT-06).
        keyActions: [
          TableKeyAction(
            key: LogicalKeyboardKey.keyL,
            label: l10n.keyActionLogs,
            run: _openUnit,
          ),
          if (actionsAllowedAt(
            context,
            widget.serverId,
            ActionEntryPoint.unitVerb,
          ))
            TableKeyAction(
              key: LogicalKeyboardKey.keyR,
              label: l10n.keyActionRestart,
              run: (unit) => startAction(
                context,
                UnitAction(
                  widget.serverId,
                  unit: unit.unit,
                  verb: SystemctlVerb.restart,
                  scope: _scope,
                ),
              ),
            ),
        ],
        // SVC-03's verbs where actions are allowed (M4 E21). Without them
        // the table keeps no slot, as before.
        rowActions:
            actionsAllowedAt(
              context,
              widget.serverId,
              ActionEntryPoint.unitVerb,
            )
            ? (unit) => unitActionEntries(
                context,
                serverId: widget.serverId,
                unit: unit.unit,
                scope: _scope,
              )
            : null,
        empty: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.servicesEmpty),
        ),
      ),
    );
  }
}

/// [name]'s row in [units], or null once the list no longer holds it.
SystemdUnit? _find(UnitsSnapshot? units, String name) {
  for (final unit in [...?units?.units, ...?units?.failed]) {
    if (unit.unit == name) return unit;
  }
  return null;
}

List<SortableTableColumn<SystemdUnit>> _columns(
  AppLocalizations l10n, {
  required bool wide,
}) {
  String shown(String? value) => value ?? l10n.chartUnknownValue;
  SortableTableColumn<SystemdUnit> state(
    _Column column,
    String label,
    String? Function(UnitStates states) of, {
    Widget Function(BuildContext context, SystemdUnit unit)? cell,
  }) => SortableTableColumn(
    id: column.name,
    label: label,
    text: (unit) => shown(of(unitStatesOf(unit))),
    sortKey: (unit) => of(unitStatesOf(unit)),
    extent: const FixedColumnExtent(104),
    cell: cell,
  );

  return [
    SortableTableColumn(
      id: _Column.unit.name,
      label: l10n.servicesColumnUnit,
      text: (unit) => unit.unit,
      sortKey: (unit) => unit.unit,
      extent: const FlexColumnExtent(2),
    ),
    if (wide)
      state(_Column.load, l10n.servicesColumnLoad, (states) => states.load),
    state(
      _Column.active,
      l10n.servicesColumnActive,
      (states) => states.active?.name,
      cell: (context, unit) => _activeState(
        context,
        unitStatesOf(unit).active,
        shown(unitStatesOf(unit).active?.name),
      ),
    ),
    state(_Column.sub, l10n.servicesColumnSub, (states) => states.sub),
    if (wide)
      SortableTableColumn(
        id: _Column.description.name,
        label: l10n.servicesColumnDescription,
        text: (unit) => shown(unitDescriptionOf(unit)),
        sortKey: unitDescriptionOf,
        extent: const FlexColumnExtent(3),
      ),
  ];
}

/// An active state, a failed one in the error colour after an icon, so
/// colour is never the only cue (A11Y-01).
Widget _activeState(BuildContext context, UnitActiveState? state, String text) {
  final theme = Theme.of(context);
  final failed = state == UnitActiveState.failed;
  final color = failed ? theme.colorScheme.error : null;
  return Row(
    spacing: 4,
    children: [
      if (failed) Icon(Icons.error_outline, size: 14, color: color),
      Flexible(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: theme.textTheme.bodyMedium?.copyWith(color: color),
        ),
      ),
    ],
  );
}

/// A unit's page: its name, description and states, then up to
/// [kUnitLogWindow] recent journal lines, oldest first (SVC-04), under
/// them or in a sheet the page opens ([UnitLogPlacement]).
class _UnitPage extends StatelessWidget {
  const _UnitPage({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.name,
    required this.unit,
    required this.visible,
    required this.wide,
    required this.logPlacement,
    required this.closeFocus,
    required this.onClose,
    required this.scope,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String name;

  /// The unit's row in the latest list; null leaves its states unknown.
  final SystemdUnit? unit;

  final bool visible;
  final bool wide;
  final UnitLogPlacement logPlacement;
  final FocusNode closeFocus;
  final VoidCallback onClose;

  /// The manager the unit belongs to (SVC-09).
  final UnitScope scope;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final unit = this.unit;
    final states = unit == null ? null : unitStatesOf(unit);
    final description = unit == null ? null : unitDescriptionOf(unit);
    String shown(String? value) => value ?? l10n.chartUnknownValue;
    final facts = [
      Row(
        children: [
          IconButton(
            tooltip: l10n.servicesUnitClose,
            focusNode: closeFocus,
            icon: Icon(wide ? Icons.close : Icons.arrow_back),
            onPressed: onClose,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(name, style: theme.textTheme.titleMedium),
            ),
          ),
          // OV-08: pins the unit's restart to the Overview.
          PinServiceButton(serverId: serverId, unit: name, scope: scope),
          // SVC-07 (v1): the unit's file and drop-ins.
          IconButton(
            tooltip: l10n.unitFileShow,
            icon: const Icon(Icons.description_outlined),
            onPressed: () => unawaited(
              openUnitFile(
                context,
                monitoring: monitoring,
                serverId: serverId,
                unit: name,
                scope: scope,
              ),
            ),
          ),
        ],
      ),
      if (description != null) Text(description),
      // Only where actions show, so the page keeps its layout otherwise.
      if (actionsAllowedAt(context, serverId, ActionEntryPoint.unitVerb))
        UnitActionButtons(serverId: serverId, unit: name, scope: scope),
      // SVC-08 (v1): what the unit uses now, after its states.
      UnitResourcesView(
        monitoring: monitoring,
        serverId: serverId,
        unit: name,
        scope: scope,
        revision: (states?.active, states?.sub),
        leading: [
          for (final (label, value) in [
            (l10n.servicesColumnLoad, states?.load),
            (l10n.servicesColumnActive, states?.active?.name),
            (l10n.servicesColumnSub, states?.sub),
          ])
            _labelled(theme, label, Text(shown(value))),
        ],
      ),
    ];
    // The unit logs read the system journal by unit, where a user unit's
    // lines are not found under its name (LOG-22 reads them later).
    if (scope == UnitScope.user) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            ...facts,
            _notice(theme, Icons.info_outline, l10n.servicesUserLogsAbsent),
          ],
        ),
      );
    }
    return switch (logPlacement) {
      UnitLogPlacement.inline => _UnitLogs(
        monitoring: monitoring,
        serverId: serverId,
        name: name,
        visible: visible,
        builder: (context, notice, lines) => _headed(
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              ...facts,
              Semantics(
                header: true,
                child: Text(
                  l10n.servicesLogsTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              ?notice,
            ],
          ),
          body: lines ?? const SizedBox.shrink(),
        ),
      ),
      UnitLogPlacement.sheet => SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            ...facts,
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilledButton.tonalIcon(
                onPressed: () => _showLogs(context),
                icon: const Icon(Icons.article_outlined),
                label: Text(l10n.servicesLogsShow),
              ),
            ),
          ],
        ),
      ),
    };
  }

  /// SVC-04's lines in a bottom sheet that drags from a quarter of the
  /// screen to its full height. The sheet reads them while it is open,
  /// and closing it closes a read still running.
  void _showLogs(BuildContext context) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: _logSheetShare,
          minChildSize: _logSheetMinShare,
          maxChildSize: 1,
          builder: (context, scroll) => _UnitLogs(
            monitoring: monitoring,
            serverId: serverId,
            name: name,
            // The sheet covers the panel, so its tab cannot change.
            visible: true,
            builder: (context, notice, lines) =>
                _logSheet(context, scroll, notice, lines),
          ),
        ),
      ),
    );
  }

  Widget _logSheet(
    BuildContext context,
    ScrollController scroll,
    Widget? notice,
    Widget? lines,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: _headed(
        // Dragging the heading drags the sheet; the lines scroll alone.
        headerScroll: scroll,
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(name, style: theme.textTheme.titleMedium),
                      ),
                      Text(l10n.servicesLogsTitle),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: l10n.servicesLogsClose,
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            ?notice,
          ],
        ),
        body: lines ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// SVC-04's read of [name]'s recent journal lines while [visible], which
/// [builder] lays out: what the read is doing until lines arrive, and
/// the lines, oldest first, once there are any.
class _UnitLogs extends StatefulWidget {
  const _UnitLogs({
    required this.monitoring,
    required this.serverId,
    required this.name,
    required this.visible,
    required this.builder,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String name;
  final bool visible;
  final Widget Function(BuildContext context, Widget? notice, Widget? lines)
  builder;

  @override
  State<_UnitLogs> createState() => _UnitLogsState();
}

class _UnitLogsState extends State<_UnitLogs> {
  final _lines = LogViewController();
  LogRead? _read;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_UnitLogs oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _release();
    _lines.dispose();
    super.dispose();
  }

  /// Reads while the page shows. A read still running when its tab hides
  /// stops and starts over once the tab shows again, as nothing samples
  /// for a hidden view (03 §6.4); a finished one stays.
  void _sync() {
    final read = _read;
    if (!widget.visible) {
      if (read != null && !read.ended) _release();
      return;
    }
    if (read == null) _start();
  }

  void _start() {
    _read = widget.monitoring.openLogRead(
      LogStreamSpec(
        serverId: widget.serverId,
        source: JournalLogSource(unit: widget.name),
        window: kUnitLogWindow,
        follow: false,
      ),
    )..addListener(_onRead);
  }

  void _release() {
    final read = _read;
    if (read == null) return;

    _read = null;
    read
      ..removeListener(_onRead)
      ..close();
  }

  /// A window arrives newest first and the view lists oldest first, so
  /// each batch rebuilds the lines, [kUnitLogWindow] at most.
  void _onRead() {
    final read = _read!;
    _lines
      ..clear()
      ..addJournal([
        for (final record in read.records.reversed)
          if (record is JournalRecord) JournalEntry(record.fields),
      ], dropped: read.dropped);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final read = _read;
    final notice = read == null ? null : unitLogsNotice(l10n, read);
    return widget.builder(
      context,
      read == null || notice == null
          ? null
          : _notice(
              Theme.of(context),
              read.ended ? Icons.info_outline : Icons.hourglass_empty,
              notice,
              switch (read.state) {
                LogReadReported(status: LogStreamEnded(:final detail)) =>
                  detail,
                _ => null,
              },
            ),
      read == null || read.records.isEmpty
          ? null
          : LogView(controller: _lines, levelOf: LogLevel.ofJournalLine),
    );
  }
}

Widget _unavailable(
  AppLocalizations l10n,
  ThemeData theme,
  CollectorUnavailable unavailable,
) => _notice(theme, Icons.error_outline, switch (unavailable.reason) {
  CollectorUnavailableReason.missing => l10n.servicesUnavailableMissing,
  CollectorUnavailableReason.denied => l10n.servicesUnavailableDenied,
  CollectorUnavailableReason.timeout => l10n.servicesUnavailableTimeout,
  CollectorUnavailableReason.error => l10n.servicesUnavailableError,
}, unavailable.detail);

/// [header] over [body], the header scrolling within [_headerShare] of
/// the height when it would take more, under [headerScroll] if given.
Widget _headed({
  required Widget header,
  required Widget body,
  ScrollController? headerScroll,
}) => LayoutBuilder(
  builder: (context, constraints) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: constraints.maxHeight * _headerShare,
        ),
        child: SingleChildScrollView(controller: headerScroll, child: header),
      ),
      const SizedBox(height: 12),
      Expanded(child: body),
    ],
  ),
);

/// A state the panel is in rather than data, read out when it changes;
/// [detail] is the server's own error text, shown as it came.
Widget _notice(ThemeData theme, IconData icon, String text, [String? detail]) =>
    Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(text),
                if (detail != null && detail.isNotEmpty)
                  Text(detail, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );

/// A label beside its value or control, read as one.
Widget _labelled(ThemeData theme, String label, Widget child) => MergeSemantics(
  child: Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 8,
    children: [
      Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      Flexible(child: child),
    ],
  ),
);

/// A filter's menu: every unit, or one value, a type or state being
/// systemd's word, never translated (03 §10.10). It is compact on desktop
/// and 48 dp tall on touch, as the table's rows are.
Widget _filterMenu<T extends Enum>(
  AppLocalizations l10n,
  ThemeData theme, {
  required String anyLabel,
  required List<UnitFilter<T>> choices,
  required UnitFilter<T> selected,
  required ValueChanged<UnitFilter<T>> onSelected,
}) => DropdownButton<UnitFilter<T>>(
  value: selected,
  isDense: ghostIsDesktopPlatform(theme.platform),
  items: [
    for (final choice in choices)
      DropdownMenuItem(
        value: choice,
        child: Text(
          choice.any ? anyLabel : choice.value?.name ?? l10n.chartUnknownValue,
        ),
      ),
  ],
  onChanged: (choice) {
    if (choice != null) onSelected(choice);
  },
);
