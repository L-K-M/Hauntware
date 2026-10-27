import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'admin_mode_chip.dart' show AdminScope;
import 'chart_strings.dart';
import 'charts/charts.dart';

/// Opens the disk space explorer (DSK-07, 03 §7.3) on [root], a mount
/// point of [serverId], on a page of its own.
void openDiskExplorer(
  BuildContext context, {
  required MonitoringController monitoring,
  required String serverId,
  required String root,
}) => unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          DiskExplorer(monitoring: monitoring, serverId: serverId, root: root),
    ),
  ),
);

/// The disk space explorer (DSK-07, 03 §7.3): a folder's entries, largest
/// first, each with its share of the folder, drilled into one folder at a
/// time and never above [root]. Each folder is read once, when it first
/// opens, on [root]'s filesystem only; Refresh reads it again. In admin
/// mode it can read as root, which also counts what the login user may
/// not read. Read-only: it changes nothing on the server.
class DiskExplorer extends StatefulWidget {
  const DiskExplorer({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.root,
  });

  final MonitoringController monitoring;
  final String serverId;
  final String root;

  @override
  State<DiskExplorer> createState() => _DiskExplorerState();
}

class _DiskExplorerState extends State<DiskExplorer> {
  /// The folders opened, [DiskExplorer.root] first, the shown one last.
  late final List<String> _trail = [widget.root];

  /// Each folder's read as it came back, by path; elevated reads apart.
  final Map<(String, bool), DiskUsageReport> _reads = {};
  final Set<(String, bool)> _reading = {};

  /// Whether to read as root; in effect only while admin mode is on.
  bool _wantRoot = false;

  String get _path => _trail.last;

  @override
  void initState() {
    super.initState();
    _read(_path, elevated: false);
  }

  void _read(String path, {required bool elevated, bool again = false}) {
    if (!mounted) return;
    final key = (path, elevated);
    if (_reading.contains(key) || (!again && _reads.containsKey(key))) return;
    setState(() => _reading.add(key));
    unawaited(
      widget.monitoring.diskUsage
          .read(widget.serverId, path, elevated: elevated)
          .then((report) {
            if (!mounted) return;
            setState(() {
              _reading.remove(key);
              _reads[key] = report;
            });
          }),
    );
  }

  void _open(String name, {required bool elevated}) {
    final path = _path == '/' ? '/$name' : '$_path/$name';
    setState(() => _trail.add(path));
    _read(path, elevated: elevated);
  }

  void _up() {
    if (_trail.length < 2) return;
    setState(_trail.removeLast);
  }

  void _setAsRoot(bool asRoot) {
    setState(() => _wantRoot = asRoot);
    _read(_path, elevated: asRoot);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final admin = AdminScope.maybeOf(context);
    final adminOn =
        admin?.stateFor(widget.serverId)?.phase == AdminModePhase.on;
    // Admin mode ending under an elevated view reads as the login user.
    final asRoot = _wantRoot && adminOn;
    final key = (_path, asRoot);
    final report = _reads[key];
    final reading = _reading.contains(key);
    return PopScope(
      // Back steps up a folder before it leaves the explorer.
      canPop: _trail.length < 2,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _up();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.diskExplorerTitle(widget.root)),
          actions: [
            IconButton(
              tooltip: l10n.diskExplorerRefresh,
              icon: const Icon(Icons.refresh),
              onPressed: reading
                  ? null
                  : () => _read(_path, elevated: asRoot, again: true),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: l10n.diskExplorerUp,
                      icon: const Icon(Icons.arrow_upward),
                      onPressed: _trail.length < 2 ? null : _up,
                    ),
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _path,
                          style: Theme.of(context).textTheme.titleSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (adminOn)
                SwitchListTile(
                  title: Text(l10n.diskExplorerAsRoot),
                  subtitle: Text(l10n.diskExplorerAsRootDetail),
                  value: asRoot,
                  onChanged: _setAsRoot,
                ),
              Expanded(
                child: switch ((report, reading)) {
                  (_, true) => _Reading(path: _path),
                  (final report?, false) => _Report(
                    report: report,
                    adminOn: adminOn,
                    asRoot: asRoot,
                    onOpen: (name) => _open(name, elevated: asRoot),
                    onRetry: () => _read(_path, elevated: asRoot, again: true),
                  ),
                  // A folder not yet read this way, as after admin mode
                  // ended: read it once the frame is built.
                  (null, false) => _Reading(
                    path: _path,
                    onShown: () => _read(_path, elevated: asRoot),
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Reading extends StatelessWidget {
  const _Reading({required this.path, this.onShown});

  final String path;

  /// Starts the read this spinner waits for, after the frame.
  final VoidCallback? onShown;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (onShown case final start?) {
      WidgetsBinding.instance.addPostFrameCallback((_) => start());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            const CircularProgressIndicator(),
            Text(l10n.diskExplorerReading(path), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Report extends StatelessWidget {
  const _Report({
    required this.report,
    required this.adminOn,
    required this.asRoot,
    required this.onOpen,
    required this.onRetry,
  });

  final DiskUsageReport report;
  final bool adminOn;
  final bool asRoot;
  final ValueChanged<String> onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final listing = report.listing;
    if (listing == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Text(
                diskUsageFailureText(l10n, report.failure!),
                textAlign: TextAlign.center,
              ),
              OutlinedButton(
                onPressed: onRetry,
                child: Text(l10n.diskExplorerRetry),
              ),
            ],
          ),
        ),
      );
    }

    final strings = klabautermannChartStrings(l10n);
    String size(int bytes) =>
        formatChartValue(bytes.toDouble(), ChartUnit.bytes, strings);
    final notes = [
      l10n.diskExplorerTotal(size(listing.totalBytes)),
      if (listing.incomplete)
        asRoot
            ? l10n.diskExplorerIncompleteAsRoot
            : adminOn
            ? l10n.diskExplorerIncompleteAdmin
            : l10n.diskExplorerIncomplete,
      if (listing.truncated) l10n.diskExplorerTruncated(listing.entries.length),
    ];
    return ListView(
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(note),
          ),
        if (listing.entries.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.diskExplorerEmpty),
          ),
        for (final entry in listing.entries)
          _EntryTile(
            entry: entry,
            size: size(entry.bytes),
            share: listing.totalBytes == 0
                ? 0
                : entry.bytes / listing.totalBytes,
            onOpen: entry.isFolder ? () => onOpen(entry.name) : null,
          ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.size,
    required this.share,
    required this.onOpen,
  });

  final DiskUsageEntry entry;
  final String size;
  final double share;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final percent = (share * 100).round();
    return ListTile(
      leading: Icon(
        entry.isFolder ? Icons.folder_outlined : Icons.insert_drive_file,
      ),
      title: Text(entry.name, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: ExcludeSemantics(
          child: LinearProgressIndicator(value: share.clamp(0, 1)),
        ),
      ),
      trailing: Text(l10n.diskExplorerEntrySize(size, percent)),
      onTap: onOpen,
    );
  }
}

/// [failure] in words.
String diskUsageFailureText(
  AppLocalizations l10n,
  DiskUsageReportFailure failure,
) => switch (failure) {
  DiskUsageReportFailure.noLink => l10n.diskExplorerNoLink,
  DiskUsageReportFailure.adminRequired => l10n.diskExplorerAdminRequired,
  DiskUsageReportFailure.elevationRefused => l10n.diskExplorerRefused,
  DiskUsageReportFailure.invalidPath ||
  DiskUsageReportFailure.notFound => l10n.diskExplorerNotFound,
  DiskUsageReportFailure.denied => l10n.diskExplorerDenied,
  DiskUsageReportFailure.unreadable => l10n.diskExplorerUnreadable,
  DiskUsageReportFailure.transport => l10n.diskExplorerTransport,
};
