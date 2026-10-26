import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/admin_controller.dart';
import '../l10n/app_localizations.dart';
import 'admin_mode_chip.dart' show AdminScope;
import 'system_panel.dart' show PanelNotice, PanelSection;

/// NET-06's section of the System tab: the firewall rules of whichever of
/// ufw, firewalld, nftables and iptables the server has, read on request
/// in admin mode, since each needs root. The last read stays until the
/// next one, and a server switch forgets it.
class FirewallSection extends StatefulWidget {
  const FirewallSection({super.key, required this.serverId});

  final String serverId;

  @override
  State<FirewallSection> createState() => _FirewallSectionState();
}

class _FirewallSectionState extends State<FirewallSection> {
  FirewallReport? _report;
  bool _reading = false;

  @override
  void didUpdateWidget(FirewallSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverId == widget.serverId) return;
    _report = null;
    _reading = false;
  }

  Future<void> _read(AdminController admin) async {
    if (_reading) return;
    final serverId = widget.serverId;
    setState(() => _reading = true);
    final report = await admin.readFirewall(serverId);
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
    final read = report?.read;

    return PanelSection(
      title: l10n.systemFirewallTitle,
      children: [
        if (report?.failure case final failure?)
          PanelNotice(
            icon: Icons.error_outline,
            text: l10n.systemFirewallFailed(failure.name),
          ),
        if (read != null) ..._tools(context, l10n, read),
        if (_reading)
          Text(l10n.systemFirewallReading)
        else if (!adminOn || admin == null)
          Text(l10n.systemFirewallAdminNeeded)
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: () => unawaited(_read(admin)),
              child: Text(
                report == null
                    ? l10n.systemFirewallRead
                    : l10n.systemFirewallReadAgain,
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _tools(
    BuildContext context,
    AppLocalizations l10n,
    FirewallRead read,
  ) {
    if (read.noTool) return [Text(l10n.systemFirewallNoTool)];
    return [
      if (read.ufw case final ufw?) _Ufw(ufw: ufw),
      if (read.firewalld case final firewalld?) _Firewalld(status: firewalld),
      if (read.nftables case final chains?)
        _Chains(title: l10n.systemFirewallNftables, chains: chains),
      if (read.iptables case final chains?)
        _Chains(title: l10n.systemFirewallIptables, chains: chains),
      if (read.ip6tables case final chains?)
        _Chains(title: l10n.systemFirewallIp6tables, chains: chains),
    ];
  }
}

/// A tool's name over its lines, read as one node.
class _Tool extends StatelessWidget {
  const _Tool({required this.title, required this.lines});

  final String title;
  final List<Widget> lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          ...lines,
        ],
      ),
    );
  }
}

class _Ufw extends StatelessWidget {
  const _Ufw({required this.ufw});

  final UfwStatus ufw;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Tool(
      title: l10n.systemFirewallUfw,
      lines: [
        Text(l10n.systemFirewallActive(ufw.active.toString())),
        if (ufw.active) ...[
          Text(
            l10n.systemFirewallUfwDefaults(
              ufw.incoming ?? l10n.systemUnknown,
              ufw.outgoing ?? l10n.systemUnknown,
              ufw.routed ?? l10n.systemUnknown,
            ),
          ),
          if (ufw.rules.isEmpty) Text(l10n.systemFirewallNoRules),
          for (final rule in ufw.rules)
            Text(l10n.systemFirewallUfwRule(rule.to, rule.action, rule.from)),
        ],
      ],
    );
  }
}

class _Firewalld extends StatelessWidget {
  const _Firewalld({required this.status});

  final FirewalldStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final shown = [
      for (final zone in status.zones)
        if (zone.active || zone.isDefault) zone,
    ];
    final idle = status.zones.length - shown.length;
    String? listed(List<String> values) =>
        values.isEmpty ? null : values.join(' ');

    return _Tool(
      title: l10n.systemFirewallFirewalld,
      lines: [
        Text(l10n.systemFirewallRunning(status.running.toString())),
        for (final zone in shown) ...[
          Text(
            zone.isDefault
                ? l10n.systemFirewallZoneDefault(zone.name)
                : zone.name,
            style: theme.textTheme.bodyLarge,
          ),
          if (listed(zone.interfaces) case final value?)
            Text(l10n.systemFirewallZoneInterfaces(value), style: muted),
          if (listed(zone.sources) case final value?)
            Text(l10n.systemFirewallZoneSources(value), style: muted),
          Text(
            l10n.systemFirewallZoneServices(
              listed(zone.services) ?? l10n.systemFirewallNone,
            ),
            style: muted,
          ),
          if (listed(zone.ports) case final value?)
            Text(l10n.systemFirewallZonePorts(value), style: muted),
        ],
        if (idle > 0) Text(l10n.systemFirewallZonesIdle(idle), style: muted),
      ],
    );
  }
}

/// nftables' or iptables' chains: those with a policy or rules, each with
/// its policy and how many rules it holds.
class _Chains extends StatelessWidget {
  const _Chains({required this.title, required this.chains});

  final String title;
  final List<FirewallChain> chains;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shown = [
      for (final chain in chains)
        if (chain.policy != null || chain.rules > 0) chain,
    ];
    return _Tool(
      title: title,
      lines: [
        if (shown.isEmpty) Text(l10n.systemFirewallNoRules),
        for (final chain in shown)
          Text(
            l10n.systemFirewallChain(
              [?chain.family, chain.table, chain.name].join(' '),
              chain.policy ?? l10n.systemFirewallNoPolicy,
              chain.rules,
            ),
          ),
      ],
    );
  }
}
