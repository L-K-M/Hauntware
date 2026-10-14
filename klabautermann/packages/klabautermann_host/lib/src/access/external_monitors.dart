/// The external-monitor rule (03 §9.5 coverage card, 01 §"host-down
/// alerts"): a monitor already running on the host watches it while the
/// app is closed. Read from the `units` list, so the answer stays unknown
/// until that list loads; a monitor outside systemd is not seen.
library;

import 'package:meta/meta.dart';

import '../parse/units.dart';
import 'access_check.dart' show AccessStatus;

/// The monitors the rule recognises, with their packaged unit names.
enum ExternalMonitor {
  nodeExporter([
    'node_exporter.service',
    'prometheus-node-exporter.service',
    'node-exporter.service',
  ]),
  netdata(['netdata.service']),
  zabbixAgent(['zabbix-agent.service', 'zabbix-agent2.service']),
  telegraf(['telegraf.service']);

  const ExternalMonitor(this.units);

  final List<String> units;
}

/// One monitor unit systemd has loaded.
@immutable
final class ExternalMonitorUnit {
  const ExternalMonitorUnit(this.monitor, this.unit, {required this.running});

  final ExternalMonitor monitor;

  /// The unit name, as `systemctl` listed it.
  final String unit;

  /// Whether the unit is `active` (or reloading); a failed or stopped
  /// unit is installed but watches nothing.
  final bool running;
}

/// What the rule found on one host.
@immutable
final class ExternalMonitorReport {
  ExternalMonitorReport(
    this.status, [
    List<ExternalMonitorUnit> units = const [],
  ]) : units = List.unmodifiable(units);

  /// ok when a monitor runs, missing when the loaded list has none
  /// running, unknown before the list loads or when it produced nothing.
  final AccessStatus status;

  /// Every loaded monitor unit, running or not, in `systemctl` order.
  final List<ExternalMonitorUnit> units;

  /// The monitors with a running unit, each once.
  List<ExternalMonitor> get running => [
    for (final m in ExternalMonitor.values)
      if (units.any((u) => u.monitor == m && u.running)) m,
  ];
}

/// Applies the rule to the latest [units] tick; null means the list has
/// not loaded yet.
ExternalMonitorReport detectExternalMonitors(UnitsSnapshot? units) {
  if (units == null || units.format == UnitListFormat.none) {
    return ExternalMonitorReport(AccessStatus.unknown);
  }

  final found = <ExternalMonitorUnit>[];
  for (final u in units.units) {
    // `list-units --all` also lists units that are only referenced.
    if (u.load == 'not-found') continue;
    final monitor = _byUnit[u.unit];
    if (monitor == null) continue;
    found.add(
      ExternalMonitorUnit(
        monitor,
        u.unit,
        running: u.active == 'active' || u.active == 'reloading',
      ),
    );
  }
  final anyRunning = found.any((u) => u.running);
  return ExternalMonitorReport(
    anyRunning ? AccessStatus.ok : AccessStatus.missing,
    found,
  );
}

final _byUnit = {
  for (final m in ExternalMonitor.values)
    for (final unit in m.units) unit: m,
};
