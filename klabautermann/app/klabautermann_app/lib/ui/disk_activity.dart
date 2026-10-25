import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinaryRate, scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart' show DiskRate;

import '../l10n/app_localizations.dart';
import 'sortable_table.dart';

/// One block device's rates in the Disk activity table.
typedef DiskActivityRow = ({String device, DiskRate rate});

/// [rates] as table rows, by device name.
List<DiskActivityRow> diskActivityRows(Map<String, DiskRate> rates) => [
  for (final MapEntry(key: device, value: rate) in rates.entries)
    (device: device, rate: rate),
]..sort((a, b) => a.device.compareTo(b.device));

/// The table's columns with the width each claims before text scaling,
/// room for its header with the sort chevron and for "Unknown". The
/// device's is the least it is given before the table drops the counts
/// and waits.
enum DiskActivityColumn {
  device(72),
  read(80),
  write(80),
  readsPerSecond(80),
  writesPerSecond(80),
  readAwait(88),
  writeAwait(88),
  busy(72);

  const DiskActivityColumn(this.width);

  final double width;
}

/// The unscaled width every column needs side by side.
final double _allColumnsWidth = DiskActivityColumn.values.fold(
  0,
  (sum, column) => sum + column.width,
);

/// The table's columns (DSK-03, DSK-04): every figure when [wide], else
/// the device, its throughput and how busy it is. A figure the collector
/// set could not give (no timings, or no completed request for an await)
/// reads as unknown and sorts last; figures sort largest first.
List<SortableTableColumn<DiskActivityRow>> diskActivityColumns(
  AppLocalizations l10n, {
  required bool wide,
}) {
  String ms(double? value) =>
      value == null ? l10n.systemUnknown : l10n.systemDiskMilliseconds(value);
  SortableTableColumn<DiskActivityRow> figure(
    DiskActivityColumn id,
    String label,
    String Function(DiskRate rate) text,
    double? Function(DiskRate rate) value,
  ) => SortableTableColumn<DiskActivityRow>(
    id: id.name,
    label: label,
    text: (row) => text(row.rate),
    sortKey: (row) => value(row.rate),
    firstDirection: TableSortDirection.descending,
    extent: FixedColumnExtent(id.width),
    alignment: CellAlignment.end,
  );

  return [
    SortableTableColumn<DiskActivityRow>(
      id: DiskActivityColumn.device.name,
      label: l10n.systemDevice,
      text: (row) => row.device,
      sortKey: (row) => row.device,
    ),
    figure(
      DiskActivityColumn.read,
      l10n.systemDiskRead,
      (rate) => ghostFormatBinaryRate(rate.readBytesPerSecond),
      (rate) => rate.readBytesPerSecond,
    ),
    figure(
      DiskActivityColumn.write,
      l10n.systemDiskWrite,
      (rate) => ghostFormatBinaryRate(rate.writeBytesPerSecond),
      (rate) => rate.writeBytesPerSecond,
    ),
    if (wide) ...[
      figure(
        DiskActivityColumn.readsPerSecond,
        l10n.systemDiskReadsPerSecond,
        (rate) => l10n.systemDiskOperations(rate.readsPerSecond.round()),
        (rate) => rate.readsPerSecond,
      ),
      figure(
        DiskActivityColumn.writesPerSecond,
        l10n.systemDiskWritesPerSecond,
        (rate) => l10n.systemDiskOperations(rate.writesPerSecond.round()),
        (rate) => rate.writesPerSecond,
      ),
      figure(
        DiskActivityColumn.readAwait,
        l10n.systemDiskReadAwait,
        (rate) => ms(rate.readAwaitMs),
        (rate) => rate.readAwaitMs,
      ),
      figure(
        DiskActivityColumn.writeAwait,
        l10n.systemDiskWriteAwait,
        (rate) => ms(rate.writeAwaitMs),
        (rate) => rate.writeAwaitMs,
      ),
    ],
    figure(
      DiskActivityColumn.busy,
      l10n.systemDiskBusy,
      (rate) => switch (rate.busyPercent) {
        final busy? => l10n.chartPercent(busy / 100),
        null => l10n.systemUnknown,
      },
      (rate) => rate.busyPercent,
    ),
  ];
}

/// Every block device's rates since the last reading, as a table whose
/// rows all show: the page scrolls, not the table. It shows every column
/// where they all fit, and otherwise drops the counts and waits rather
/// than scroll sideways.
class DiskActivityTable extends StatelessWidget {
  const DiskActivityTable({
    super.key,
    required this.tableId,
    required this.rows,
    required this.sort,
    required this.onSort,
  });

  /// The table's identity for its keys and remembered widths.
  final String tableId;
  final List<DiskActivityRow> rows;
  final TableSort? sort;
  final ValueChanged<TableSort> onSort;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final allColumns = MediaQuery.textScalerOf(context).scale(_allColumnsWidth);
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: (rows.length + 1) * scaledGhostFileRowExtent(context),
        child: SortableTable<DiskActivityRow>(
          tableId: tableId,
          columns: diskActivityColumns(
            l10n,
            wide: constraints.maxWidth >= allColumns,
          ),
          rows: rows,
          rowKey: (row) => row.device,
          sort: sort,
          onSort: onSort,
        ),
      ),
    );
  }
}
