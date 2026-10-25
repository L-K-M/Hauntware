import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/admin_controller.dart';
import '../controllers/package_reads.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart';
import 'actions/action_preview.dart' show startAction;
import 'admin_mode_chip.dart' show AdminScope;
import 'sortable_table.dart';
import 'system_panel.dart' show PanelSection;

/// The table's columns with the width each claims before text scaling.
/// The package's is the least it is given before the table drops the
/// installed version.
enum UpdateColumn {
  package(160),
  installed(160),
  available(160),
  security(96);

  const UpdateColumn(this.width);

  final double width;
}

/// The unscaled width every column needs side by side.
final double _allColumnsWidth = UpdateColumn.values.fold(
  0,
  (sum, column) => sum + column.width,
);

/// The most rows the table shows at once; it scrolls past them.
const _visibleRows = 12;

/// The table's columns (PKG-01, PKG-02): the package, the version it
/// updates to and whether it fixes a security issue, and the installed
/// version when [wide]. Security updates sort first.
List<SortableTableColumn<PackageUpdate>> updateColumns(
  AppLocalizations l10n, {
  required bool wide,
}) => [
  SortableTableColumn<PackageUpdate>(
    id: UpdateColumn.package.name,
    label: l10n.systemUpdatesPackage,
    text: (update) => update.name,
    sortKey: (update) => update.name,
  ),
  if (wide)
    SortableTableColumn<PackageUpdate>(
      id: UpdateColumn.installed.name,
      label: l10n.systemUpdatesInstalled,
      text: (update) => update.current ?? l10n.systemUnknown,
      sortKey: (update) => update.current,
      extent: FixedColumnExtent(UpdateColumn.installed.width),
    ),
  SortableTableColumn<PackageUpdate>(
    id: UpdateColumn.available.name,
    label: l10n.systemUpdatesAvailable,
    text: (update) => update.available,
    sortKey: (update) => update.available,
    extent: FixedColumnExtent(UpdateColumn.available.width),
  ),
  SortableTableColumn<PackageUpdate>(
    id: UpdateColumn.security.name,
    label: l10n.systemUpdatesSecurity,
    text: (update) => update.security ? l10n.systemUpdatesSecurityYes : '',
    sortKey: (update) => update.security ? 0 : 1,
    extent: FixedColumnExtent(UpdateColumn.security.width),
  ),
];

/// PKG-01 to PKG-03's section of the System tab: the pending updates and
/// security fixes the server's package manager lists from its cached
/// metadata, and whether the server asks for a restart. It reads when it
/// first shows, from the engine's check of the last hour if there is one,
/// and checks again on request. A server switch reads that server's.
class UpdatesSection extends StatefulWidget {
  const UpdatesSection({
    super.key,
    required this.reads,
    required this.serverId,
    required this.tableId,
  });

  final PackageReads reads;
  final String serverId;

  /// The table's identity for its keys and remembered widths.
  final String tableId;

  @override
  State<UpdatesSection> createState() => _UpdatesSectionState();
}

class _UpdatesSectionState extends State<UpdatesSection> {
  PackagesReport? _report;
  bool _reading = false;
  bool _refreshStarted = false;
  RestartReport? _restarts;
  bool _readingRestarts = false;
  int _ticket = 0;
  TableSort? _sort = TableSort(
    UpdateColumn.security.name,
    TableSortDirection.ascending,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_read(fresh: false));
  }

  @override
  void didUpdateWidget(UpdatesSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.reads == widget.reads) {
      return;
    }
    _report = null;
    _refreshStarted = false;
    _restarts = null;
    _readingRestarts = false;
    unawaited(_read(fresh: false));
  }

  Future<void> _readRestarts(AdminController admin) async {
    final serverId = widget.serverId;
    setState(() => _readingRestarts = true);
    final report = await admin.readRestarts(serverId);
    if (!mounted || serverId != widget.serverId) return;
    setState(() {
      _restarts = report;
      _readingRestarts = false;
    });
  }

  Future<void> _read({required bool fresh}) async {
    final ticket = ++_ticket;
    setState(() => _reading = true);
    final report = await widget.reads.read(widget.serverId, fresh: fresh);
    // Only the newest read lands, so a slow answer for another server
    // never replaces a later one.
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _report = report;
      _reading = false;
      if (fresh) _refreshStarted = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final report = _report;
    final check = report?.check;
    final failure = report?.failure;
    final checkFailure = check?.failure;
    final updates = check?.updates ?? const <PackageUpdate>[];

    return PanelSection(
      title: l10n.systemUpdatesTitle,
      children: [
        if (failure != null)
          Text(l10n.systemUpdatesFailed(failure.name))
        else if (checkFailure != null)
          Text(switch (checkFailure) {
            PackageCheckFailure.noManager => l10n.systemUpdatesNoManager,
            PackageCheckFailure.noCache => l10n.systemUpdatesNoCache,
            PackageCheckFailure.failed => l10n.systemUpdatesManagerFailed(
              check!.detail ?? '',
            ),
          })
        else if (check != null)
          Text(
            updates.isEmpty
                ? l10n.systemUpdatesNone
                : l10n.systemUpdatesCount(updates.length),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        if (check != null && checkFailure == null) ?_securityLine(l10n, check),
        if (check != null) ?_rebootLine(context, l10n, check),
        if (updates.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              height:
                  (math.min(updates.length, _visibleRows) + 1) *
                  scaledGhostFileRowExtent(context),
              child: SortableTable<PackageUpdate>(
                tableId: widget.tableId,
                columns: updateColumns(
                  l10n,
                  wide:
                      constraints.maxWidth >=
                      MediaQuery.textScalerOf(context).scale(_allColumnsWidth),
                ),
                rows: updates,
                rowKey: (update) => update.name,
                sort: _sort,
                onSort: (sort) => setState(() => _sort = sort),
              ),
            ),
          ),
        if (updates.length >= kPackageUpdatesKept)
          Text(l10n.systemUpdatesCut(kPackageUpdatesKept)),
        if (check?.cachedAt case final cachedAt?)
          Text(l10n.systemUpdatesListsFrom(cachedAt.toLocal())),
        if (_reading)
          Text(l10n.systemUpdatesChecking)
        else
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: () => unawaited(_read(fresh: true)),
                child: Text(l10n.systemUpdatesCheckAgain),
              ),
              ?_refreshButton(context, l10n, check),
              if (report?.checkedAt case final checkedAt?)
                Text(l10n.systemUpdatesCheckedAt(checkedAt.toLocal())),
            ],
          ),
        if (_refreshStarted) Text(l10n.systemUpdatesRefreshStarted),
        ..._restartLines(context, l10n),
      ],
    );
  }

  /// PKG-05's refresh, in admin mode, for a manager it refreshes; a
  /// note that it needs admin mode where the lists were never downloaded.
  Widget? _refreshButton(
    BuildContext context,
    AppLocalizations l10n,
    PackageCheck? check,
  ) {
    final manager = check?.manager;
    if (manager == null || manager == PackageManager.pacman) return null;
    final admin = AdminScope.maybeOf(context);
    final adminOn =
        admin?.stateFor(widget.serverId)?.phase == AdminModePhase.on;
    if (!adminOn) {
      return check?.failure == PackageCheckFailure.noCache
          ? Text(l10n.systemUpdatesRefreshAdminNeeded)
          : null;
    }
    return ActionEntry(
      serverId: widget.serverId,
      point: ActionEntryPoint.packageRefresh,
      child: OutlinedButton(
        onPressed: () => startAction(
          context,
          RefreshPackageLists(widget.serverId),
          onRun: (_, _) => setState(() => _refreshStarted = true),
        ),
        child: Text(l10n.systemUpdatesRefresh),
      ),
    );
  }

  /// PKG-04: the services still running replaced libraries, read on
  /// request in admin mode, and a newer kernel waiting for a reboot.
  List<Widget> _restartLines(BuildContext context, AppLocalizations l10n) {
    final admin = AdminScope.maybeOf(context);
    final adminOn =
        admin?.stateFor(widget.serverId)?.phase == AdminModePhase.on;
    final report = _restarts;
    final check = report?.check;
    final failure = report?.failure;
    return [
      Text(
        l10n.systemUpdatesRestartsTitle,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      if (failure != null)
        Text(l10n.systemUpdatesRestartsFailed(failure.name))
      else if (check != null) ...[
        if (check.services.isEmpty)
          Text(l10n.systemUpdatesRestartsNone)
        else
          Text(l10n.systemUpdatesRestartsList(check.services.join(', '))),
        if (check.kernel
            case KernelState.abiCompatibleUpgrade || KernelState.versionUpgrade)
          Text(l10n.systemUpdatesKernelWaiting),
      ],
      if (_readingRestarts)
        Text(l10n.systemUpdatesRestartsReading)
      else if (!adminOn || admin == null)
        Text(l10n.systemUpdatesRestartsAdminNeeded)
      else
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: () => unawaited(_readRestarts(admin)),
            child: Text(
              report == null
                  ? l10n.systemUpdatesRestartsRead
                  : l10n.systemUpdatesRestartsReadAgain,
            ),
          ),
        ),
    ];
  }

  Widget? _securityLine(AppLocalizations l10n, PackageCheck check) {
    final count = check.securityCount;
    if (count == null || count == 0) return null;
    return Text(
      check.manager == PackageManager.zypper
          ? l10n.systemUpdatesSecurityPatches(count)
          : l10n.systemUpdatesSecurityCount(count),
    );
  }

  Widget? _rebootLine(
    BuildContext context,
    AppLocalizations l10n,
    PackageCheck check,
  ) {
    switch (check.reboot) {
      case RebootState.unknown:
        return null;
      case RebootState.notRequired:
        return Text(l10n.systemUpdatesNoRestart);
      case RebootState.required:
        final packages = check.rebootPackages;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Icon(
              Icons.restart_alt,
              size: 20,
              color: Theme.of(context).colorScheme.error,
            ),
            Expanded(
              child: Text(
                packages.isEmpty
                    ? l10n.systemUpdatesRestart
                    : l10n.systemUpdatesRestartFor(packages.join(', ')),
              ),
            ),
          ],
        );
    }
  }
}
