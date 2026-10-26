import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show ghostFormatBinaryRate, ghostFormatBinarySize, scaledGhostFileRowExtent;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'accounts.dart';
import 'boots.dart';
import 'chart_strings.dart';
import 'charts/charts.dart' show BarSegment, ChartUnit, StackedBar;
import 'disk_activity.dart';
import 'drive_health.dart';
import 'gpus.dart';
import 'listening_ports.dart';
import 'oom_kills.dart';
import 'power.dart';
import 'sortable_table.dart';
import 'system_view.dart';
import 'temperatures.dart';
import 'updates.dart';

/// The System tab's sections, which key them; the Disks section's id also
/// prefixes its table's keys.
enum SystemSection {
  identity,
  uptime,
  time,
  network,
  disks,
  diskActivity,
  temperatures,
  gpus,
  oomKills,
  ports,
  boots,
  driveHealth,
  updates,
  accounts,
  power,
}

/// The panel width from which the fact sections sit side by side and the
/// mounts table adds its type and bytes columns and usage bars. The desktop
/// workspace passes it at a 1280 px window; at the desktop shell's
/// narrowest, 960 px, it has about 400 px and lays out as on a phone. It
/// grows with the text scale, as the table's columns do, so larger text
/// takes the narrow layout before the wide table would scroll sideways.
const double _wideWidth = 600;

const double _gap = 16;

/// The System tab (03 §10.2, §10.4): SYS-01's identity with SYS-04's
/// container awareness, BOOT-01's uptime and boot time, NET-01's total
/// throughput, and DSK-01's and DSK-02's usage and inodes per mount.
///
/// It reads the streams its [SampledSurface] subscribes (`identity`,
/// `core` and `fs`) from [MonitoringController]'s boxes, and the probe's
/// profile for virtualization and D50's container facts. The slow streams
/// and the profile rebuild the panel; the fast `core` stream rebuilds only
/// the two sections it feeds (03 §10.1). Nothing animates (A11Y-11).
class SystemPanel extends StatefulWidget {
  const SystemPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    this.fleet,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The fleet, for the Updates section's fleet update center (PKG-06);
  /// without it the section offers none.
  final FleetController? fleet;

  @override
  State<SystemPanel> createState() => _SystemPanelState();
}

class _SystemPanelState extends State<SystemPanel> {
  late ValueListenable<Sample?> _identity;
  late ValueListenable<Sample?> _core;
  late ValueListenable<Sample?> _fs;
  late ValueListenable<Sample?> _temps;
  late ValueListenable<Sample?> _gpu;
  late ValueListenable<HostProfile?> _profile;
  late ValueListenable<ServerClock?> _clock;

  /// The latest `fs` sample that listed mounts. While a later one times
  /// out, as on a stale network mount, its mounts stay listed with their
  /// usage unknown rather than vanishing.
  late ValueListenable<Sample?> _listed;

  /// The table's order and the pseudo filter, which outlive tab switches:
  /// the workspace keeps a panel built once opened.
  TableSort? _sort;
  bool _showPseudo = false;

  /// The Disk activity, Temperatures and GPUs tables' orders, which
  /// outlive tab switches too.
  TableSort? _activitySort;
  TableSort? _tempsSort;
  TableSort? _gpuSort;

  List<Listenable> get _slow => [
    _identity,
    _fs,
    _listed,
    _temps,
    _gpu,
    _profile,
    _clock,
  ];

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(SystemPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId == oldWidget.serverId &&
        widget.monitoring == oldWidget.monitoring) {
      return;
    }

    _detach();
    _attach();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _attach() {
    final monitoring = widget.monitoring;
    final serverId = widget.serverId;
    _identity = monitoring.sampleFor(serverId, SampleStream.identity);
    _core = monitoring.sampleFor(serverId, SampleStream.core);
    _fs = monitoring.sampleFor(serverId, SampleStream.fs);
    _temps = monitoring.sampleFor(serverId, SampleStream.temps);
    _gpu = monitoring.sampleFor(serverId, SampleStream.gpu);
    _listed = monitoring.lastReadingFor(serverId, SampleStream.fs);
    _profile = monitoring.profileFor(serverId);
    _clock = monitoring.clockFor(serverId);
    for (final listenable in _slow) {
      listenable.addListener(_onSlowChange);
    }
  }

  void _detach() {
    for (final listenable in _slow) {
      listenable.removeListener(_onSlowChange);
    }
  }

  void _onSlowChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profile = _profile.value;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide =
            constraints.maxWidth >=
            MediaQuery.textScalerOf(context).scale(_wideWidth);
        final identity = _identitySection(l10n, profile);
        final uptime = ListenableBuilder(
          listenable: _core,
          builder: (context, _) => _uptimeSection(l10n, profile),
        );
        final time = _timeSection(l10n, profile);
        final network = ListenableBuilder(
          listenable: _core,
          builder: (context, _) => _networkSection(l10n),
        );
        final temperatures = _temperaturesSection(l10n, profile);
        final gpus = _gpusSection(l10n);
        return SingleChildScrollView(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: _gap,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: _gap,
                  children: [
                    Expanded(child: identity),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: _gap,
                        children: [uptime, time, network],
                      ),
                    ),
                  ],
                )
              else ...[
                identity,
                uptime,
                time,
                network,
              ],
              _disksSection(context, l10n, wide: wide),
              ListenableBuilder(
                listenable: _core,
                builder: (context, _) => _diskActivitySection(l10n, profile),
              ),
              ?temperatures,
              ?gpus,
              OomKillsSection(
                key: const ValueKey(SystemSection.oomKills),
                monitoring: widget.monitoring,
                serverId: widget.serverId,
              ),
              ListeningPortsSection(
                key: const ValueKey(SystemSection.ports),
                monitoring: widget.monitoring,
                serverId: widget.serverId,
              ),
              BootsSection(
                key: const ValueKey(SystemSection.boots),
                monitoring: widget.monitoring,
                serverId: widget.serverId,
              ),
              DriveHealthSection(
                key: const ValueKey(SystemSection.driveHealth),
                serverId: widget.serverId,
                tableId: SystemSection.driveHealth.name,
              ),
              UpdatesSection(
                key: const ValueKey(SystemSection.updates),
                reads: widget.monitoring.packages,
                serverId: widget.serverId,
                tableId: SystemSection.updates.name,
                fleet: widget.fleet,
              ),
              AccountsSection(
                key: const ValueKey(SystemSection.accounts),
                reads: widget.monitoring.accounts,
                serverId: widget.serverId,
                tableId: SystemSection.accounts.name,
              ),
              PowerSection(
                key: const ValueKey(SystemSection.power),
                serverId: widget.serverId,
                core: _core,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _identitySection(AppLocalizations l10n, HostProfile? profile) {
    return PanelSection(
      key: const ValueKey(SystemSection.identity),
      title: l10n.systemIdentityTitle,
      children: [
        ..._readingOr<IdentityResult>(
          l10n,
          _identity.value,
          (identity) => [
            _Fact(label: l10n.systemHostname, value: identity.hostname),
            _Fact(
              label: l10n.systemOperatingSystem,
              value: identity.osPrettyName,
            ),
            _Fact(label: l10n.systemKernel, value: kernelText(l10n, identity)),
            _Fact(label: l10n.systemArchitecture, value: identity.arch),
          ],
        ),
        // The probe answers apart from the identity stream (03 §6.1).
        if (profile != null)
          _Fact(
            label: l10n.systemVirtualization,
            value: virtualizationText(l10n, profile),
          ),
        if (inContainer(profile))
          PanelNotice(
            icon: Icons.info_outline,
            text: l10n.systemContainerNotice,
          ),
      ],
    );
  }

  Widget _uptimeSection(AppLocalizations l10n, HostProfile? profile) {
    return PanelSection(
      key: const ValueKey(SystemSection.uptime),
      title: l10n.systemUptimeTitle,
      children: _readingOr<CoreResult>(l10n, _core.value, (core) {
        final uptime = core.uptime;
        final booted = core.bootedAt;
        return [
          _hostFact(
            l10n,
            l10n.systemUptime,
            uptime == null ? null : uptimeText(l10n, uptime),
            withheld: withholdsHostFigure(profile, SystemWideProcFile.uptime),
          ),
          // `btime` is a line of `/proc/stat` (D50).
          _hostFact(
            l10n,
            l10n.systemBooted,
            booted == null ? null : l10n.systemBootedValue(booted.toLocal()),
            withheld: withholdsHostFigure(profile, SystemWideProcFile.stat),
          ),
        ];
      }),
    );
  }

  /// SYS-02 and CN-17, from the probe: the time zone, whether the clock
  /// is in sync, and how far it was from this device's when the probe
  /// answered.
  Widget _timeSection(AppLocalizations l10n, HostProfile? profile) {
    return PanelSection(
      key: const ValueKey(SystemSection.time),
      title: l10n.systemTimeTitle,
      children: [
        _Fact(
          label: l10n.systemTimeZone,
          value: profile?.timezone ?? profile?.zoneOffset,
        ),
        _Fact(label: l10n.systemTimeSync, value: timeSyncText(l10n, profile)),
        _Fact(
          label: l10n.systemClock,
          value: clockSkewText(l10n, _clock.value?.skew),
        ),
      ],
    );
  }

  /// `/proc/net/dev` is the network namespace's own, so a container's
  /// rates stay as measured (D50).
  Widget _networkSection(AppLocalizations l10n) {
    return PanelSection(
      key: const ValueKey(SystemSection.network),
      title: l10n.systemNetworkTitle,
      children: _readingOr<CoreResult>(l10n, _core.value, (core) {
        final totals = networkTotals(core.network);
        return [
          _Fact(
            label: l10n.systemReceive,
            value: totals == null ? null : ghostFormatBinaryRate(totals.rx),
          ),
          _Fact(
            label: l10n.systemTransmit,
            value: totals == null ? null : ghostFormatBinaryRate(totals.tx),
          ),
        ];
      }),
    );
  }

  /// DSK-03 and DSK-04: each whole disk's throughput, operations, await
  /// and busy share since the previous `core` reading. `/proc/diskstats`
  /// is the host's inside a container, so there it is withheld (D50).
  Widget _diskActivitySection(AppLocalizations l10n, HostProfile? profile) {
    return PanelSection(
      key: const ValueKey(SystemSection.diskActivity),
      title: l10n.systemDiskActivityTitle,
      children: _readingOr<CoreResult>(l10n, _core.value, (core) {
        if (withholdsHostFigure(profile, SystemWideProcFile.diskstats)) {
          return [Text(l10n.systemUnknownContainer)];
        }
        final rates = core.disks;
        if (rates == null) return [Text(l10n.systemDiskActivityWaiting)];
        if (rates.isEmpty) return [Text(l10n.systemDiskActivityEmpty)];
        return [
          DiskActivityTable(
            tableId: SystemSection.diskActivity.name,
            rows: diskActivityRows(rates),
            sort: _activitySort,
            onSort: (sort) => setState(() => _activitySort = sort),
          ),
        ];
      }),
    );
  }

  /// HW-01: each temperature sensor and the chip's limits for it, or no
  /// section where the host reports none, as VMs usually do. Inside a
  /// container, sysfs shows the host's sensors, so there is none either.
  Widget? _temperaturesSection(AppLocalizations l10n, HostProfile? profile) {
    if (inContainer(profile)) return null;
    final sensors = switch (_temps.value?.result) {
      TempsResult(:final temps) when temps.sensors.isNotEmpty => temps.sensors,
      _ => null,
    };
    if (sensors == null) return null;

    return PanelSection(
      key: const ValueKey(SystemSection.temperatures),
      title: l10n.systemTemperaturesTitle,
      children: [
        TemperaturesTable(
          tableId: SystemSection.temperatures.name,
          sensors: sensors,
          sort: _tempsSort,
          onSort: (sort) => setState(() => _tempsSort = sort),
        ),
      ],
    );
  }

  /// HW-03: each GPU's busy share, memory, temperature and power, or no
  /// section where the host has no GPU the collector reads. An installed
  /// `nvidia-smi` that fails, as without its driver, says so instead.
  Widget? _gpusSection(AppLocalizations l10n) {
    final gpu = switch (_gpu.value?.result) {
      GpuResult(:final gpu)
          when gpu.devices.isNotEmpty || gpu.nvidiaFailure != null =>
        gpu,
      _ => null,
    };
    if (gpu == null) return null;

    final failure = gpu.nvidiaFailure;
    return PanelSection(
      key: const ValueKey(SystemSection.gpus),
      title: l10n.systemGpusTitle,
      children: [
        if (gpu.devices.isNotEmpty)
          GpusTable(
            tableId: SystemSection.gpus.name,
            gpus: gpu.devices,
            sort: _gpuSort,
            onSort: (sort) => setState(() => _gpuSort = sort),
          ),
        if (failure != null) Text(l10n.systemGpuNvidiaFailed(failure)),
      ],
    );
  }

  /// `df` sees the mount namespace's own filesystems, so a container's
  /// mounts stay as measured too.
  Widget _disksSection(
    BuildContext context,
    AppLocalizations l10n, {
    required bool wide,
  }) {
    final children = switch (_fs.value?.result) {
      null => [_waiting(l10n)],
      CollectorUnavailable(reason: CollectorUnavailableReason.timeout) => [
        PanelNotice(
          icon: Icons.timer_off_outlined,
          text: l10n.systemDisksTimedOut,
        ),
        if (_listed.value case Sample(
          :final at,
          result: FsResult(:final fs),
        )) ...[
          Text(l10n.systemDisksLastListed(at.toLocal())),
          ..._mounts(context, l10n, fs, wide: wide, timedOut: true),
        ],
      ],
      final CollectorUnavailable unavailable => [
        _unavailable(l10n, unavailable),
      ],
      FsResult(:final fs) => [
        if (fs.timeoutAbsent)
          PanelNotice(
            icon: Icons.info_outline,
            text: l10n.systemDisksNoTimeout,
          ),
        ..._mounts(context, l10n, fs, wide: wide, timedOut: false),
      ],
      // Sample's assert admits nothing else on the `fs` stream.
      _ => const <Widget>[],
    };
    return PanelSection(
      key: const ValueKey(SystemSection.disks),
      title: l10n.systemDisksTitle,
      children: children,
    );
  }

  /// [fs]'s pseudo filter and table: every mount's usage as unknown when
  /// [timedOut], since that reading's figures are no longer current.
  List<Widget> _mounts(
    BuildContext context,
    AppLocalizations l10n,
    FsSnapshot fs, {
    required bool wide,
    required bool timedOut,
  }) {
    final pseudo = fs.mounts.where((mount) => mount.isPseudo).length;
    final rows = shownMounts(fs, showPseudo: _showPseudo);
    final columns = _mountColumns(l10n, wide: wide, timedOut: timedOut);
    return [
      if (pseudo > 0)
        CheckboxListTile(
          value: _showPseudo,
          onChanged: (show) => setState(() => _showPseudo = show ?? false),
          title: Text(l10n.systemDisksShowPseudo(pseudo)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      if (rows.isEmpty)
        Text(l10n.systemDisksEmpty)
      else
        // Every row shows: the page scrolls, not the table, and follows
        // the keyboard's active row.
        SizedBox(
          height: (rows.length + 1) * scaledGhostFileRowExtent(context),
          child: SortableTable<FsMount>(
            tableId: SystemSection.disks.name,
            columns: columns,
            rows: rows,
            rowKey: (mount) => mount.mountPoint,
            sort: _sort,
            onSort: (sort) => setState(() => _sort = sort),
            // The mount column may cut a mount point short (A11Y-09).
            onRowActivated: (mount) =>
                _showMountDetails(context, l10n, mount, timedOut: timedOut),
          ),
        ),
    ];
  }

  /// The [facts] of [sample]'s result, or why it has none.
  List<Widget> _readingOr<R extends SampleResult>(
    AppLocalizations l10n,
    Sample? sample,
    List<Widget> Function(R result) facts,
  ) => switch (sample?.result) {
    null => [_waiting(l10n)],
    final CollectorUnavailable unavailable => [_unavailable(l10n, unavailable)],
    final R result => facts(result),
    // Sample's assert admits only the stream's own variant.
    _ => const <Widget>[],
  };
}

enum _MountColumn { mount, type, used, use, inodes, usage }

/// The mounts table's columns: the type, the bytes and a usage bar only
/// when [wide] ([_showMountDetails] shows them for a narrow row), and after
/// a timeout one usage column reading unknown instead of the figures.
/// Figures sort with their largest first; an unknown one sorts last.
List<SortableTableColumn<FsMount>> _mountColumns(
  AppLocalizations l10n, {
  required bool wide,
  required bool timedOut,
}) {
  final mount = SortableTableColumn<FsMount>(
    id: _MountColumn.mount.name,
    label: l10n.systemColumnMount,
    text: (mount) => mount.mountPoint,
    sortKey: (mount) => mount.mountPoint,
  );
  final type = SortableTableColumn<FsMount>(
    id: _MountColumn.type.name,
    label: l10n.systemColumnType,
    text: (mount) => mount.type,
    sortKey: (mount) => mount.type,
    extent: const FixedColumnExtent(80),
  );
  if (timedOut) {
    return [
      mount,
      if (wide) type,
      SortableTableColumn<FsMount>(
        id: _MountColumn.usage.name,
        label: l10n.systemColumnUsage,
        // The run as a whole timed out, not this mount: which one hung is
        // not known, so the usage is unknown, beside the timeout's shape.
        text: (_) => l10n.systemUnknown,
        extent: const FixedColumnExtent(120),
        cell: (context, _) => Row(
          spacing: 4,
          children: [
            const Icon(Icons.timer_off_outlined, size: 14),
            Flexible(
              child: Text(
                l10n.systemUnknown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    ];
  }

  return [
    mount,
    if (wide) type,
    if (wide)
      SortableTableColumn<FsMount>(
        id: _MountColumn.used.name,
        label: l10n.systemColumnUsed,
        text: (mount) => _used(l10n, mount),
        sortKey: (mount) => mount.usedBytes,
        firstDirection: TableSortDirection.descending,
        extent: const FixedColumnExtent(160),
        alignment: CellAlignment.end,
      ),
    SortableTableColumn<FsMount>(
      id: _MountColumn.use.name,
      label: l10n.systemColumnUse,
      text: (mount) => _percent(l10n, mount.capacityPercent),
      sortKey: (mount) => mount.capacityPercent,
      firstDirection: TableSortDirection.descending,
      extent: FixedColumnExtent(wide ? 136 : 64),
      alignment: CellAlignment.end,
      cell: wide
          ? (context, mount) => _UseCell(
              mount: mount,
              percent: _percent(l10n, mount.capacityPercent),
            )
          : null,
    ),
    SortableTableColumn<FsMount>(
      id: _MountColumn.inodes.name,
      label: l10n.systemColumnInodes,
      text: (mount) => _percent(l10n, mount.inodeUsePercent),
      sortKey: (mount) => mount.inodeUsePercent,
      firstDirection: TableSortDirection.descending,
      extent: const FixedColumnExtent(80),
      alignment: CellAlignment.end,
    ),
  ];
}

String _percent(AppLocalizations l10n, int? value) =>
    value == null ? l10n.systemUnknown : l10n.chartPercent(value / 100);

/// The space [mount] uses out of its size, in IEC units (A11Y-06).
String _used(AppLocalizations l10n, FsMount mount) {
  final used = mount.usedBytes;
  final size = mount.sizeBytes;
  if (used == null) return l10n.systemUnknown;
  if (size == null) return ghostFormatBinarySize(used);
  return l10n.systemUsedOf(
    ghostFormatBinarySize(used),
    ghostFormatBinarySize(size),
  );
}

/// A mount's full mount point, device and type with the figures a narrow
/// table leaves out, in a sheet (03 §10.5: details push further). It shows
/// the reading the row had; after a timeout its usage reads as unknown,
/// with the timeout as the reason.
void _showMountDetails(
  BuildContext context,
  AppLocalizations l10n,
  FsMount mount, {
  required bool timedOut,
}) {
  final theme = Theme.of(context);
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              Semantics(
                header: true,
                child: Text(
                  mount.mountPoint,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              _Fact(label: l10n.systemDevice, value: mount.device),
              _Fact(label: l10n.systemColumnType, value: mount.type),
              if (timedOut)
                _Fact(
                  label: l10n.systemColumnUsage,
                  value: null,
                  note: l10n.systemUnavailableTimeout,
                )
              else ...[
                _Fact(label: l10n.systemColumnUsed, value: _used(l10n, mount)),
                _Fact(
                  label: l10n.systemColumnUse,
                  value: _percent(l10n, mount.capacityPercent),
                ),
                _Fact(
                  label: l10n.systemColumnInodes,
                  value: _percent(l10n, mount.inodeUsePercent),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// A fact read from a system-wide `/proc` file: unknown with D50's
/// reason when [withheld], whatever the reading holds (SYS-04).
_Fact _hostFact(
  AppLocalizations l10n,
  String label,
  String? value, {
  required bool withheld,
}) => withheld
    ? _Fact(label: label, value: null, note: l10n.systemUnknownContainer)
    : _Fact(label: label, value: value);

PanelNotice _waiting(AppLocalizations l10n) =>
    PanelNotice(icon: Icons.hourglass_empty, text: l10n.systemWaiting);

/// Why a stream has no reading, with the host's error output, which is
/// server data and never translated.
PanelNotice _unavailable(
  AppLocalizations l10n,
  CollectorUnavailable unavailable,
) {
  final reason = unavailable.reason;
  return PanelNotice(
    icon: reason == CollectorUnavailableReason.timeout
        ? Icons.timer_off_outlined
        : Icons.error_outline,
    text: switch (reason) {
      CollectorUnavailableReason.missing => l10n.systemUnavailableMissing,
      CollectorUnavailableReason.denied => l10n.systemUnavailableDenied,
      CollectorUnavailableReason.timeout => l10n.systemUnavailableTimeout,
      CollectorUnavailableReason.error => l10n.systemUnavailableError,
    },
    detail: unavailable.detail,
  );
}

/// A titled group of facts on its own surface, here and in the Overview
/// tab. Its title is a heading for screen readers, and its children may
/// hold ink (the pseudo filter).
class PanelSection extends StatelessWidget {
  const PanelSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            Semantics(
              header: true,
              child: Text(title, style: theme.textTheme.titleSmall),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A label over its value, read as one node. Text wraps rather than
/// clips at any text scale.
class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, this.note});

  final String label;

  /// Null shows as unknown, never as zero (03 §10.4).
  final String? value;

  /// Why the value is unknown, where there is a reason to give; an icon
  /// beside it marks it apart from a value without colour (A11Y-01).
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final note = this.note;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(color: muted),
          ),
          Text(
            value ?? AppLocalizations.of(context).systemUnknown,
            style: theme.textTheme.bodyLarge,
          ),
          if (note != null)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Icon(Icons.info_outline, size: 16, color: muted),
                Expanded(
                  child: Text(
                    note,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A section's state in words beside an icon, read as one node, here and
/// in the Overview tab; the icon adds a shape, the text carries the
/// meaning (A11Y-01).
class PanelNotice extends StatelessWidget {
  const PanelNotice({
    super.key,
    required this.icon,
    required this.text,
    this.detail,
  });

  final IconData icon;
  final String text;

  /// The host's error output, cut to a few lines.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final detail = this.detail;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Icon(icon, size: 18, color: muted),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Text(text, style: theme.textTheme.bodyMedium),
                if (detail != null)
                  Text(
                    detail,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The wide table's use cell: df's share as a bar and in figures. The bar
/// spans the used plus the available space, the base df computes its
/// share on (reserved blocks count in neither), so bar and figure agree
/// up to df's rounding; without both it spans the size. The table reads
/// the figure to screen readers, so the bar's own summary stays out.
class _UseCell extends StatelessWidget {
  const _UseCell({required this.mount, required this.percent});

  final FsMount mount;
  final String percent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final used = mount.usedBytes;
    final avail = mount.availBytes;
    final total = used != null && avail != null
        ? used + avail
        : mount.sizeBytes;
    return Row(
      spacing: 8,
      children: [
        Expanded(
          child: StackedBar(
            label: l10n.systemColumnUse,
            segments: [
              BarSegment(label: l10n.systemColumnUsed, value: used?.toDouble()),
            ],
            total: total?.toDouble(),
            unit: ChartUnit.bytes,
            strings: klabautermannChartStrings(l10n),
            showLegend: false,
          ),
        ),
        Text(
          percent,
          maxLines: 1,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
