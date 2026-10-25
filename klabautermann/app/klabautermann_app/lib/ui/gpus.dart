import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinarySize, scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart' show GpuDevice;

import '../l10n/app_localizations.dart';
import 'sortable_table.dart';

/// The table's columns with the width each claims before text scaling.
/// The GPU's is the least it is given before the table drops the
/// memory, temperature and power.
enum GpuColumn {
  gpu(160),
  busy(72),
  memory(152),
  temperature(96),
  power(80);

  const GpuColumn(this.width);

  final double width;
}

/// The unscaled width every column needs side by side.
final double _allColumnsWidth = GpuColumn.values.fold(
  0,
  (sum, column) => sum + column.width,
);

/// [gpu]'s product name, or its device name where the driver reports
/// none.
String gpuName(GpuDevice gpu) => gpu.name ?? gpu.id;

/// The memory [gpu] uses out of its total, in IEC units.
String _memory(AppLocalizations l10n, GpuDevice gpu) {
  final used = gpu.memoryUsedBytes;
  final total = gpu.memoryTotalBytes;
  if (used == null) return l10n.systemUnknown;
  if (total == null) return ghostFormatBinarySize(used);
  return l10n.systemUsedOf(
    ghostFormatBinarySize(used),
    ghostFormatBinarySize(total),
  );
}

/// The table's columns (HW-03): the GPU and how busy it is, and its
/// memory, temperature and power draw when [wide]. A figure the driver
/// does not report reads as unknown and sorts last; figures sort largest
/// first.
List<SortableTableColumn<GpuDevice>> gpuColumns(
  AppLocalizations l10n, {
  required bool wide,
}) {
  SortableTableColumn<GpuDevice> figure(
    GpuColumn id,
    String label,
    String Function(GpuDevice gpu) text,
    num? Function(GpuDevice gpu) value,
  ) => SortableTableColumn<GpuDevice>(
    id: id.name,
    label: label,
    text: text,
    sortKey: value,
    firstDirection: TableSortDirection.descending,
    extent: FixedColumnExtent(id.width),
    alignment: CellAlignment.end,
  );

  return [
    SortableTableColumn<GpuDevice>(
      id: GpuColumn.gpu.name,
      label: l10n.systemGpuColumn,
      text: gpuName,
      sortKey: gpuName,
    ),
    figure(
      GpuColumn.busy,
      l10n.systemGpuBusy,
      (gpu) => switch (gpu.busyPercent) {
        final busy? => l10n.chartPercent(busy / 100),
        null => l10n.systemUnknown,
      },
      (gpu) => gpu.busyPercent,
    ),
    if (wide) ...[
      figure(
        GpuColumn.memory,
        l10n.systemGpuMemory,
        (gpu) => _memory(l10n, gpu),
        (gpu) => gpu.memoryUsedBytes,
      ),
      figure(
        GpuColumn.temperature,
        l10n.systemTemperatureReading,
        (gpu) => switch (gpu.celsius) {
          final celsius? => l10n.systemTemperatureCelsius(celsius),
          null => l10n.systemUnknown,
        },
        (gpu) => gpu.celsius,
      ),
      figure(
        GpuColumn.power,
        l10n.systemGpuPower,
        (gpu) => switch (gpu.powerWatts) {
          final watts? => l10n.systemGpuWatts(watts),
          null => l10n.systemUnknown,
        },
        (gpu) => gpu.powerWatts,
      ),
    ],
  ];
}

/// Every GPU of the latest reading, as a table whose rows all show: the
/// page scrolls, not the table. It shows every column where they all fit,
/// and otherwise keeps the GPU and how busy it is rather than scroll
/// sideways.
class GpusTable extends StatelessWidget {
  const GpusTable({
    super.key,
    required this.tableId,
    required this.gpus,
    required this.sort,
    required this.onSort,
  });

  /// The table's identity for its keys and remembered widths.
  final String tableId;
  final List<GpuDevice> gpus;
  final TableSort? sort;
  final ValueChanged<TableSort> onSort;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final allColumns = MediaQuery.textScalerOf(context).scale(_allColumnsWidth);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: (gpus.length + 1) * scaledGhostFileRowExtent(context),
        child: SortableTable<GpuDevice>(
          tableId: tableId,
          columns: gpuColumns(l10n, wide: constraints.maxWidth >= allColumns),
          rows: gpus,
          rowKey: (gpu) => gpu.id,
          sort: sort,
          onSort: onSort,
        ),
      ),
    );
  }
}
