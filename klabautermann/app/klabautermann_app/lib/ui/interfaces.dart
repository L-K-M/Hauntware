import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostFormatBinaryRate;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'system_panel.dart' show PanelNotice, PanelSection;

/// The interfaces NET-02 lists first, and how many it folds away until
/// asked: the loopback, and software interfaces with no address beyond
/// their link, as the veth pairs of containers. Bridges, bonds, VLANs
/// and tunnels with a routable address stay. Without `ip`'s addresses
/// only the loopback folds, since nothing tells a veth from a bond.
/// The loopback interface's name on Linux.
const _loopback = 'lo';

({List<NetInterface> shown, int folded}) shownInterfaces(
  InterfacesRead read, {
  required bool showAll,
}) {
  bool folds(NetInterface link) {
    if (link.name == _loopback) return true;
    if (link.physical || !read.addressesRead) return false;
    return !link.addresses.any((address) => address.routable);
  }

  final physical = [
    for (final link in read.interfaces)
      if (link.physical) link,
  ];
  final virtual = [
    for (final link in read.interfaces)
      if (!link.physical) link,
  ];
  final all = [...physical, ...virtual];
  final shown = [
    for (final link in all)
      if (showAll || !folds(link)) link,
  ];
  return (shown: shown, folded: all.where(folds).length);
}

/// NET-02 and NET-03's section of the System tab: each interface with its
/// state, addresses, MTU, speed, current rates from the `core` stream and
/// error and drop counts, and the TCP sockets by state. It reads when it
/// shows and on request; a server switch reads the new server's.
class InterfacesSection extends StatefulWidget {
  const InterfacesSection({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.core,
    required this.fact,
  });

  final MonitoringController monitoring;
  final String serverId;

  /// The server's `core` samples, whose per-interface rates the rows show.
  final ValueListenable<Sample?> core;

  /// Draws a label over its value as the System tab's other facts do.
  final Widget Function(String label, String value) fact;

  @override
  State<InterfacesSection> createState() => _InterfacesSectionState();
}

class _InterfacesSectionState extends State<InterfacesSection> {
  HostPayload? _read;
  bool _reading = false;
  bool _showAll = false;

  /// Bumped per read, so only the newest answer lands.
  int _ticket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(InterfacesSection oldWidget) {
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
      const InterfacesQuery(),
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
      title: l10n.systemNetInterfacesTitle,
      children: [
        ..._lines(context, l10n),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _reading ? null : () => unawaited(_load()),
            child: Text(l10n.systemNetReadAgain),
          ),
        ),
      ],
    );
  }

  List<Widget> _lines(BuildContext context, AppLocalizations l10n) =>
      switch (_read) {
        null => [
          PanelNotice(icon: Icons.hourglass_empty, text: l10n.systemNetReading),
        ],
        HostQueryFailed(:final failure, :final detail) => [
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.systemNetFailed(failure.name),
            detail: detail,
          ),
        ],
        NetInterfaces(:final read) => [
          ..._interfaceLines(l10n, read),
          ..._connectionLines(context, l10n, read.sockets),
        ],
        _ => [
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.systemNetFailed(HostQueryFailure.failed.name),
          ),
        ],
      };

  List<Widget> _interfaceLines(AppLocalizations l10n, InterfacesRead read) {
    final (:shown, :folded) = shownInterfaces(read, showAll: _showAll);
    return [
      if (!read.addressesRead)
        PanelNotice(icon: Icons.info_outline, text: l10n.systemNetNoAddresses),
      if (folded > 0)
        CheckboxListTile(
          value: _showAll,
          onChanged: (show) => setState(() => _showAll = show ?? false),
          title: Text(l10n.systemNetShowAll(folded)),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
        ),
      if (read.interfaces.isEmpty) Text(l10n.systemNetNone),
      // The rates change with every `core` sample; the rest only per read.
      ListenableBuilder(
        listenable: widget.core,
        builder: (context, _) {
          final rates = switch (widget.core.value?.result) {
            CoreResult(:final network) => network,
            _ => null,
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              for (final link in shown)
                _InterfaceLine(link: link, rate: rates?[link.name]),
            ],
          );
        },
      ),
    ];
  }

  /// NET-03: the namespace's TCP sockets by state and its UDP and total
  /// socket counts, where `/proc/net` gave them.
  List<Widget> _connectionLines(
    BuildContext context,
    AppLocalizations l10n,
    SocketCounts sockets,
  ) {
    final tcp = sockets.tcp;
    int count(TcpState state) => tcp[state] ?? 0;
    const named = {
      TcpState.established,
      TcpState.listen,
      TcpState.timeWait,
      TcpState.closeWait,
    };
    final other = [
      for (final MapEntry(:key, :value) in tcp.entries)
        if (!named.contains(key)) value,
    ].fold(0, (a, b) => a + b);
    final fact = widget.fact;
    return [
      Semantics(
        header: true,
        child: Text(
          l10n.systemNetConnectionsTitle,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
      if (tcp.isEmpty && sockets.used == null)
        Text(l10n.systemNetConnectionsUnknown)
      else ...[
        fact(
          l10n.systemNetTcpEstablished,
          count(TcpState.established).toString(),
        ),
        fact(l10n.systemNetTcpListening, count(TcpState.listen).toString()),
        fact(l10n.systemNetTcpTimeWait, count(TcpState.timeWait).toString()),
        fact(l10n.systemNetTcpCloseWait, count(TcpState.closeWait).toString()),
        if (other > 0) fact(l10n.systemNetTcpOther, other.toString()),
        if (sockets.udp case final udp?)
          fact(l10n.systemNetUdp, udp.toString()),
        if (sockets.used case final used?)
          fact(l10n.systemNetSocketsUsed, used.toString()),
      ],
    ];
  }
}

/// One interface: its name and state, then its addresses, link details,
/// current rates and error and drop counts, read as one node.
class _InterfaceLine extends StatelessWidget {
  const _InterfaceLine({required this.link, required this.rate});

  final NetInterface link;
  final NetRate? rate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final rate = this.rate;
    final speed = link.speedMbps;
    final counted = [
      link.rxErrors,
      link.txErrors,
      link.rxDropped,
      link.txDropped,
    ].nonNulls.length;
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(
            l10n.systemNetInterface(link.name, link.state.name),
            style: theme.textTheme.bodyLarge,
          ),
          for (final address in link.addresses)
            Text(
              l10n.systemNetAddress(address.address, address.prefixLength),
              style: address.routable ? null : muted,
            ),
          if (link.mtu case final mtu?) Text(l10n.systemNetMtu(mtu)),
          if (speed != null)
            Text(
              speed >= 1000
                  ? l10n.systemNetSpeedGbps(speed / 1000)
                  : l10n.systemNetSpeedMbps(speed),
            ),
          if (rate != null)
            Text(
              l10n.systemNetRates(
                ghostFormatBinaryRate(rate.rxBytesPerSecond),
                ghostFormatBinaryRate(rate.txBytesPerSecond),
              ),
            ),
          if (counted == 4)
            Text(
              l10n.systemNetErrors(
                link.rxErrors!,
                link.txErrors!,
                link.rxDropped!,
                link.txDropped!,
              ),
            ),
          if (link.mac case final mac?) Text(mac, style: muted),
        ],
      ),
    );
  }
}
