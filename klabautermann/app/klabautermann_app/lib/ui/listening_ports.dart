import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

/// How many characters of a container id name it, as `docker ps` shows.
const _shortIdLength = 12;

/// One port as NET-04 lists it: the sockets the same processes hold on
/// one protocol and port, as a daemon's IPv4 and IPv6 listeners.
typedef PortRow = ({
  PortProtocol protocol,
  int port,
  List<String> addresses,
  List<PortProcess> processes,

  /// Whether one of its sockets accepts connections on every address.
  bool everyAddress,
});

/// [read]'s sockets as rows, in its order (by port, TCP first).
List<PortRow> portRows(ListeningPortsRead read) {
  final rows = <(PortProtocol, int, String), PortRow>{};
  for (final socket in read.sockets) {
    final pids = [for (final p in socket.processes) p.pid]..sort();
    final key = (socket.protocol, socket.port, pids.join(','));
    final row = rows[key];
    rows[key] = (
      protocol: socket.protocol,
      port: socket.port,
      addresses: [...?row?.addresses, socket.address],
      processes: row?.processes ?? socket.processes,
      everyAddress: (row?.everyAddress ?? false) || socket.everyAddress,
    );
  }
  return rows.values.toList();
}

/// NET-04's section of the System tab: what listens on which port, the
/// processes behind each and the systemd unit or container that owns
/// them. It reads when it shows and on request; a server switch reads
/// the new server's.
class ListeningPortsSection extends StatefulWidget {
  const ListeningPortsSection({
    super.key,
    required this.monitoring,
    required this.serverId,
  });

  final MonitoringController monitoring;
  final String serverId;

  @override
  State<ListeningPortsSection> createState() => _ListeningPortsSectionState();
}

class _ListeningPortsSectionState extends State<ListeningPortsSection> {
  HostPayload? _read;
  bool _reading = false;

  /// Bumped per read, so only the newest answer lands.
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ListeningPortsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId &&
        oldWidget.monitoring == widget.monitoring) {
      return;
    }
    _read = null;
    unawaited(_load());
  }

  Future<void> _load() async {
    final ticket = ++_ticket;
    if (mounted) setState(() => _reading = true);
    final result = await widget.monitoring.queryHost(
      widget.serverId,
      const ListeningPortsQuery(),
    );
    if (!mounted || ticket != _ticket) return;
    setState(() {
      _read = result.payload;
      _reading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PanelSection(
      title: l10n.systemPortsTitle,
      children: [
        ..._lines(l10n),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_load()),
            child: Text(l10n.systemPortsReadAgain),
          ),
        ),
      ],
    );
  }

  List<Widget> _lines(AppLocalizations l10n) => switch (_read) {
    null => [
      PanelNotice(icon: Icons.hourglass_empty, text: l10n.systemPortsReading),
    ],
    HostQueryFailed(:final failure, :final detail) => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemPortsFailed(failure.name),
        detail: detail,
      ),
    ],
    ListeningPorts(:final read) => _ports(l10n, read),
    _ => [
      PanelNotice(
        icon: Icons.error_outline,
        text: l10n.systemPortsFailed(HostQueryFailure.failed.name),
      ),
    ],
  };

  List<Widget> _ports(AppLocalizations l10n, ListeningPortsRead read) {
    if (read.tool == PortsTool.none) {
      return [
        PanelNotice(icon: Icons.info_outline, text: l10n.systemPortsNoTool),
      ];
    }
    final rows = portRows(read);
    return [
      if (rows.any((row) => row.processes.isEmpty))
        PanelNotice(icon: Icons.lock_outline, text: l10n.systemPortsHidden),
      if (rows.isEmpty) Text(l10n.systemPortsNone),
      for (final row in rows) _PortLine(row: row, owners: read.owners),
    ];
  }
}

/// One port: its protocol, number and addresses, then each process with
/// the unit or container that owns it, read as one node.
class _PortLine extends StatelessWidget {
  const _PortLine({required this.row, required this.owners});

  final PortRow row;
  final Map<int, ProcessAttribution> owners;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            row.everyAddress
                ? l10n.systemPortsEvery(row.protocol.name, row.port)
                : l10n.systemPortsOn(
                    row.protocol.name,
                    row.port,
                    row.addresses.join(', '),
                  ),
            style: theme.textTheme.bodyLarge,
          ),
          if (row.processes.isEmpty)
            Text(l10n.systemPortsOwnerHidden, style: muted),
          for (final process in row.processes) ...[
            Text(l10n.systemPortsProcess(process.name, process.pid)),
            if (_owner(l10n, owners[process.pid]) case final owner?)
              Text(owner, style: muted),
          ],
        ],
      ),
    );
  }

  /// The container a process runs in, else its systemd unit.
  static String? _owner(AppLocalizations l10n, ProcessAttribution? owner) =>
      switch (owner) {
        ProcessAttribution(containerId: final id?) => l10n.systemPortsContainer(
          id.length > _shortIdLength ? id.substring(0, _shortIdLength) : id,
        ),
        ProcessAttribution(unit: final unit?) => l10n.systemPortsUnit(unit),
        _ => null,
      };
}
