import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/admin_controller.dart';
import '../l10n/app_localizations.dart';
import 'admin_mode_chip.dart' show AdminScope;
import 'sortable_table.dart';
import 'system_panel.dart' show PanelSection;

/// The table's columns with the width each claims before text scaling.
/// The drive's is the least it is given before the table drops all but
/// the health.
enum DriveColumn {
  drive(160),
  device(112),
  health(96),
  temperature(96),
  wear(72),
  badSectors(104),
  powerOn(112);

  const DriveColumn(this.width);

  final double width;
}

/// The unscaled width every column needs side by side.
final double _allColumnsWidth = DriveColumn.values.fold(
  0,
  (sum, column) => sum + column.width,
);

/// The verdicts, worst first, as the health column sorts them.
const _verdictRank = {
  SmartVerdict.failing: 0,
  SmartVerdict.warning: 1,
  SmartVerdict.unknown: 2,
  SmartVerdict.asleep: 3,
  SmartVerdict.passed: 4,
};

/// The table's columns (HW-04): the drive and its health, and its device,
/// temperature, wear, bad sectors and powered-on time when [wide]. A
/// figure the drive does not report reads as unknown and sorts last.
List<SortableTableColumn<SmartDisk>> driveColumns(
  AppLocalizations l10n, {
  required bool wide,
}) {
  String name(SmartDisk disk) => disk.model ?? disk.device;
  SortableTableColumn<SmartDisk> figure(
    DriveColumn id,
    String label,
    String Function(int value) text,
    int? Function(SmartDisk disk) value,
  ) => SortableTableColumn<SmartDisk>(
    id: id.name,
    label: label,
    text: (disk) => switch (value(disk)) {
      final v? => text(v),
      null => l10n.systemUnknown,
    },
    sortKey: value,
    firstDirection: TableSortDirection.descending,
    extent: FixedColumnExtent(id.width),
    alignment: CellAlignment.end,
  );

  return [
    SortableTableColumn<SmartDisk>(
      id: DriveColumn.drive.name,
      label: l10n.systemDriveColumn,
      text: name,
      sortKey: name,
    ),
    if (wide)
      SortableTableColumn<SmartDisk>(
        id: DriveColumn.device.name,
        label: l10n.systemDriveDevice,
        text: (disk) => disk.device,
        sortKey: (disk) => disk.device,
        extent: FixedColumnExtent(DriveColumn.device.width),
      ),
    SortableTableColumn<SmartDisk>(
      id: DriveColumn.health.name,
      label: l10n.systemDriveHealth,
      text: (disk) => l10n.systemDriveVerdict(disk.verdict.name),
      sortKey: (disk) => _verdictRank[disk.verdict],
      extent: FixedColumnExtent(DriveColumn.health.width),
    ),
    if (wide) ...[
      figure(
        DriveColumn.temperature,
        l10n.systemTemperatureReading,
        (celsius) => l10n.systemTemperatureCelsius(celsius.toDouble()),
        (disk) => disk.celsius,
      ),
      figure(
        DriveColumn.wear,
        l10n.systemDriveWear,
        (percent) => l10n.chartPercent(percent / 100),
        (disk) => disk.percentageUsed,
      ),
      figure(
        DriveColumn.badSectors,
        l10n.systemDriveBadSectors,
        l10n.systemDriveBadSectorCount,
        (disk) => disk.badSectors,
      ),
      figure(
        DriveColumn.powerOn,
        l10n.systemDrivePowerOn,
        l10n.systemDriveHours,
        (disk) => disk.powerOnHours,
      ),
    ],
  ];
}

/// HW-04's section of the System tab: every drive's SMART health, read
/// on request in admin mode, since smartctl needs the drives' device
/// nodes. The last read stays until the next one, and a server switch
/// forgets it.
class DriveHealthSection extends StatefulWidget {
  const DriveHealthSection({
    super.key,
    required this.serverId,
    required this.tableId,
  });

  final String serverId;

  /// The table's identity for its keys and remembered widths.
  final String tableId;

  @override
  State<DriveHealthSection> createState() => _DriveHealthSectionState();
}

class _DriveHealthSectionState extends State<DriveHealthSection> {
  SmartReport? _report;
  bool _reading = false;
  TableSort? _sort;

  @override
  void didUpdateWidget(DriveHealthSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId) return;
    _report = null;
    _reading = false;
  }

  Future<void> _read(AdminController admin) async {
    // A second tap before the button gives way would run smartctl twice.
    if (_reading) return;
    final serverId = widget.serverId;
    setState(() => _reading = true);
    final report = await admin.readSmart(serverId);
    if (!mounted || serverId != widget.serverId) return;
    setState(() {
      _report = report;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final admin = AdminScope.maybeOf(context);
    final adminOn =
        admin?.stateFor(widget.serverId)?.phase == AdminModePhase.on;
    final report = _report;
    final failure = report?.failure;
    final disks = report?.disks ?? const <SmartDisk>[];

    return PanelSection(
      title: l10n.systemDriveHealthTitle,
      children: [
        if (failure != null)
          Text(l10n.systemDriveHealthFailed(failure.name))
        else if (report != null && disks.isEmpty)
          Text(l10n.systemDriveHealthNone),
        if (disks.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height: (disks.length + 1) * scaledGhostFileRowExtent(context),
              child: SortableTable<SmartDisk>(
                tableId: widget.tableId,
                columns: driveColumns(
                  l10n,
                  wide:
                      constraints.maxWidth >=
                      MediaQuery.textScalerOf(context).scale(_allColumnsWidth),
                ),
                rows: disks,
                rowKey: (disk) => disk.device,
                sort: _sort,
                onSort: (sort) => setState(() => _sort = sort),
              ),
            ),
          ),
        if ((report?.notRead ?? 0) > 0)
          Text(l10n.systemDriveHealthNotRead(report!.notRead)),
        if (_reading)
          Text(l10n.systemDriveHealthReading)
        else if (!adminOn || admin == null)
          Text(l10n.systemDriveHealthAdminNeeded)
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: () => unawaited(_read(admin)),
              child: Text(
                report == null
                    ? l10n.systemDriveHealthRead
                    : l10n.systemDriveHealthReadAgain,
              ),
            ),
          ),
      ],
    );
  }
}
