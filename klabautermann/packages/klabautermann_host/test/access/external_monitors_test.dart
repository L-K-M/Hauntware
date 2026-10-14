// External-monitor rule tests (03 §9.5 coverage card): node_exporter,
// Netdata, the Zabbix agent and Telegraf are found in the units list, and
// the answer stays unknown until that list has loaded.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

UnitsSnapshot _units(List<SystemdUnit> units) =>
    UnitsSnapshot(units: units, format: UnitListFormat.json);

SystemdUnit _unit(String name, String active, {String load = 'loaded'}) =>
    SystemdUnit(unit: name, load: load, active: active, sub: active);

void main() {
  test('unknown until the units list loads', () {
    final report = detectExternalMonitors(null);
    expect(report.status, AccessStatus.unknown);
    expect(report.units, isEmpty);
  });

  test('unknown when the units collector produced no list', () {
    expect(
      detectExternalMonitors(UnitsSnapshot()).status,
      AccessStatus.unknown,
    );
  });

  test('a loaded list without monitors is missing', () {
    final report = detectExternalMonitors(
      _units([_unit('ssh.service', 'active'), _unit('cron.service', 'active')]),
    );
    expect(report.status, AccessStatus.missing);
    expect(report.running, isEmpty);
  });

  test('each monitor is recognised under its packaged unit names', () {
    final cases = {
      'node_exporter.service': ExternalMonitor.nodeExporter,
      'prometheus-node-exporter.service': ExternalMonitor.nodeExporter,
      'netdata.service': ExternalMonitor.netdata,
      'zabbix-agent.service': ExternalMonitor.zabbixAgent,
      'zabbix-agent2.service': ExternalMonitor.zabbixAgent,
      'telegraf.service': ExternalMonitor.telegraf,
    };
    for (final MapEntry(key: name, value: monitor) in cases.entries) {
      final report = detectExternalMonitors(_units([_unit(name, 'active')]));
      expect(report.status, AccessStatus.ok, reason: name);
      expect(report.running, [monitor], reason: name);
    }
  });

  test('an installed but stopped monitor is listed, not counted', () {
    final report = detectExternalMonitors(
      _units([
        _unit('netdata.service', 'failed'),
        _unit('telegraf.service', 'inactive'),
      ]),
    );
    expect(report.status, AccessStatus.missing);
    expect(report.units.map((u) => (u.monitor, u.running)), [
      (ExternalMonitor.netdata, false),
      (ExternalMonitor.telegraf, false),
    ]);
  });

  test('a unit systemd could not find is not an installed monitor', () {
    final report = detectExternalMonitors(
      _units([_unit('netdata.service', 'inactive', load: 'not-found')]),
    );
    expect(report.status, AccessStatus.missing);
    expect(report.units, isEmpty);
  });

  test('the text format (systemd below 246) is read the same way', () {
    final report = detectExternalMonitors(
      UnitsSnapshot(
        units: [_unit('zabbix-agent.service', 'active')],
        format: UnitListFormat.text,
      ),
    );
    expect(report.running, [ExternalMonitor.zabbixAgent]);
  });
}
