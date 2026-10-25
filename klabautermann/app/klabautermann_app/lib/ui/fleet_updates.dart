import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/package_reads.dart';
import '../l10n/app_localizations.dart';

/// Opens PKG-06's fleet update center over the current route.
Future<void> showFleetUpdates(
  BuildContext context, {
  required PackageReads reads,
  required FleetController fleet,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => FleetUpdatesPage(reads: reads, fleet: fleet),
  ),
);

/// PKG-06's fleet update center (03 §7.8): every server's pending and
/// security updates and restart flag, from the engine's check of the last
/// hour where it has one, so opening it costs a server nothing it did not
/// already run. Servers with the most security updates come first.
class FleetUpdatesPage extends StatefulWidget {
  const FleetUpdatesPage({super.key, required this.reads, required this.fleet});

  final PackageReads reads;
  final FleetController fleet;

  @override
  State<FleetUpdatesPage> createState() => _FleetUpdatesPageState();
}

class _FleetUpdatesPageState extends State<FleetUpdatesPage> {
  final _reports = <String, PackagesReport>{};

  /// Bumped by each "check all", so a slow answer from an earlier round
  /// never replaces a later one.
  int _round = 0;

  @override
  void initState() {
    super.initState();
    _readAll(fresh: false);
  }

  void _readAll({required bool fresh}) {
    final round = ++_round;
    setState(_reports.clear);
    for (final server in widget.fleet.servers) {
      unawaited(
        widget.reads.read(server.id, fresh: fresh).then((report) {
          if (!mounted || round != _round) return;
          setState(() => _reports[server.id] = report);
        }),
      );
    }
  }

  /// Most security updates first, then most updates, then by name; a
  /// server without a check yet sorts last.
  int _compare(FleetServer a, FleetServer b) {
    int security(FleetServer s) => _reports[s.id]?.check?.securityCount ?? -1;
    int updates(FleetServer s) => _reports[s.id]?.check?.updates.length ?? -1;
    final bySecurity = security(b).compareTo(security(a));
    if (bySecurity != 0) return bySecurity;
    final byUpdates = updates(b).compareTo(updates(a));
    if (byUpdates != 0) return byUpdates;
    return a.displayName.compareTo(b.displayName);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: widget.fleet,
      builder: (context, _) {
        final servers = [...widget.fleet.servers]..sort(_compare);
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.fleetUpdatesTitle),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: l10n.fleetUpdatesCheckAll,
                onPressed: () => _readAll(fresh: true),
              ),
            ],
          ),
          body: servers.isEmpty
              ? Center(child: Text(l10n.fleetUpdatesNoServers))
              : ListView(
                  children: [
                    for (final server in servers)
                      _row(context, l10n, server, _reports[server.id]),
                  ],
                ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    FleetServer server,
    PackagesReport? report,
  ) {
    final check = report?.check;
    final colors = Theme.of(context).colorScheme;
    final security = check?.securityCount ?? 0;
    final restart = check?.reboot == RebootState.required;
    final String summary;
    if (report == null) {
      summary = l10n.systemUpdatesChecking;
    } else if (report.failure != null) {
      summary = l10n.systemUpdatesFailed(report.failure!.name);
    } else if (check!.failure case final failure?) {
      summary = switch (failure) {
        PackageCheckFailure.noManager => l10n.systemUpdatesNoManager,
        PackageCheckFailure.noCache => l10n.systemUpdatesNoCache,
        PackageCheckFailure.failed => l10n.systemUpdatesManagerFailed(
          check.detail ?? '',
        ),
      };
    } else {
      summary = l10n.fleetUpdatesSummary(
        check.updates.length,
        security,
        restart.toString(),
      );
    }
    return ListTile(
      leading: Icon(
        security > 0
            ? Icons.gpp_maybe_outlined
            : (check?.updates.isNotEmpty ?? false)
            ? Icons.system_update_alt
            : Icons.check_circle_outline,
        color: security > 0 ? colors.error : null,
      ),
      title: Text(server.displayName),
      subtitle: Text(summary),
    );
  }
}
