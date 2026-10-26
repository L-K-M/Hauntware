import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart' show TempSensor;

import '../l10n/app_localizations.dart';
import 'sortable_table.dart';

/// The table's columns with the width each claims before text scaling.
/// The sensor's is the least it is given before the table drops the
/// limits.
enum TemperatureColumn {
  sensor(144),
  reading(96),
  high(80),
  critical(80);

  const TemperatureColumn(this.width);

  final double width;
}

/// The unscaled width every column needs side by side.
final double _allColumnsWidth = TemperatureColumn.values.fold(
  0,
  (sum, column) => sum + column.width,
);

/// [sensor]'s name: its chip and the chip's label for it, or the chip
/// alone.
String temperatureSensorName(AppLocalizations l10n, TempSensor sensor) =>
    switch (sensor.label) {
      final label? => l10n.systemTemperatureSensorName(sensor.chip, label),
      null => sensor.chip,
    };

/// The table's columns (HW-01): the sensor and its reading, and the
/// chip's high and critical limits when [wide]. A limit the chip does not
/// report reads as unknown and sorts last; readings sort hottest first.
List<SortableTableColumn<TempSensor>> temperatureColumns(
  AppLocalizations l10n, {
  required bool wide,
}) {
  String celsius(double? value) =>
      value == null ? l10n.systemUnknown : l10n.systemTemperatureCelsius(value);
  SortableTableColumn<TempSensor> figure(
    TemperatureColumn id,
    String label,
    double? Function(TempSensor sensor) value,
  ) => SortableTableColumn<TempSensor>(
    id: id.name,
    label: label,
    text: (sensor) => celsius(value(sensor)),
    sortKey: value,
    firstDirection: TableSortDirection.descending,
    extent: FixedColumnExtent(id.width),
    alignment: CellAlignment.end,
  );

  return [
    SortableTableColumn<TempSensor>(
      id: TemperatureColumn.sensor.name,
      label: l10n.systemTemperatureSensor,
      text: (sensor) => temperatureSensorName(l10n, sensor),
      sortKey: (sensor) => temperatureSensorName(l10n, sensor),
    ),
    figure(
      TemperatureColumn.reading,
      l10n.systemTemperatureReading,
      (sensor) => sensor.celsius,
    ),
    if (wide) ...[
      figure(
        TemperatureColumn.high,
        l10n.systemTemperatureHigh,
        (sensor) => sensor.highCelsius,
      ),
      figure(
        TemperatureColumn.critical,
        l10n.systemTemperatureCritical,
        (sensor) => sensor.criticalCelsius,
      ),
    ],
  ];
}

/// Every temperature sensor of the latest reading, as a table whose rows
/// all show: the page scrolls, not the table. It shows the limits where
/// every column fits, and otherwise drops them rather than scroll
/// sideways.
class TemperaturesTable extends StatelessWidget {
  const TemperaturesTable({
    super.key,
    required this.tableId,
    required this.sensors,
    required this.sort,
    required this.onSort,
  });

  /// The table's identity for its keys and remembered widths.
  final String tableId;
  final List<TempSensor> sensors;
  final TableSort? sort;
  final ValueChanged<TableSort> onSort;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final allColumns = MediaQuery.textScalerOf(context).scale(_allColumnsWidth);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: (sensors.length + 1) * scaledGhostFileRowExtent(context),
        child: SortableTable<TempSensor>(
          tableId: tableId,
          columns: temperatureColumns(
            l10n,
            wide: constraints.maxWidth >= allColumns,
          ),
          rows: sensors,
          rowKey: (sensor) => sensor.id,
          sort: sort,
          onSort: onSort,
        ),
      ),
    );
  }
}
