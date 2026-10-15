import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'failed_units_summary.dart';
import 'services_view.dart';
import 'sortable_table.dart';

/// The panel width from which the unit table adds its load and description
/// columns. It grows with the text scale, as the table's columns do, so
/// larger text takes the narrow layout before the table would scroll
/// sideways.
const double _wideWidth = 600;

/// The share of its height a header takes before it scrolls, so large
/// text never pushes the table out of sight.
const double _headerShare = 0.4;

/// The unit table's columns, whose names key them.
enum _Column { unit, load, active, sub, description }

/// The Services tab (03 §10.2, §7.5): SVC-01's units with their load,
/// active and sub states, filtered by type and active state, and SVC-02's
/// failed units.
///
/// It reads the `units` stream its [SampledSurface] subscribes from
/// [MonitoringController]'s box. States the host could not read show as
/// unknown (CN-10). Nothing animates (A11Y-11).
class ServicesPanel extends StatefulWidget {
  const ServicesPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  State<ServicesPanel> createState() => _ServicesPanelState();
}

class _ServicesPanelState extends State<ServicesPanel> {
  late ValueListenable<Sample?> _units;

  /// The filters and order, which outlive tab switches: the
  /// workspace keeps a panel built once opened. Services lead, since most
  /// other units are devices, mounts and slices.
  UnitFilter<UnitType> _type = (any: false, value: UnitType.service);
  UnitFilter<UnitActiveState> _state = (any: true, value: null);
  TableSort? _sort;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(ServicesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId == oldWidget.serverId &&
        widget.monitoring == oldWidget.monitoring) {
      return;
    }

    _units.removeListener(_onUnits);
    _attach();
  }

  @override
  void dispose() {
    _units.removeListener(_onUnits);
    super.dispose();
  }

  void _attach() {
    _units = widget.monitoring.sampleFor(widget.serverId, SampleStream.units)
      ..addListener(_onUnits);
  }

  void _onUnits() => setState(() {});

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
        return Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: _list(l10n, units, result, wide: wide),
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
          FailedUnitsSummary(failed: units.failed),
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _labelled(
                theme,
                l10n.servicesFilterType,
                _filterMenu(
                  l10n,
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
        empty: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(l10n.servicesEmpty),
        ),
      ),
    );
  }
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
        text: (unit) => shown(unit.description),
        sortKey: (unit) => unit.description,
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
/// the height when it would take more.
Widget _headed({required Widget header, required Widget body}) => LayoutBuilder(
  builder: (context, constraints) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: constraints.maxHeight * _headerShare,
        ),
        child: SingleChildScrollView(child: header),
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

/// A label beside its control, read as one.
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
/// systemd's word, never translated (03 §10.10).
Widget _filterMenu<T extends Enum>(
  AppLocalizations l10n, {
  required String anyLabel,
  required List<UnitFilter<T>> choices,
  required UnitFilter<T> selected,
  required ValueChanged<UnitFilter<T>> onSelected,
}) => DropdownButton<UnitFilter<T>>(
  value: selected,
  isDense: true,
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
