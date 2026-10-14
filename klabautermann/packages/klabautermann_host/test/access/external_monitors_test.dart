// External-monitor rule tests (03 §9.5 coverage card): node_exporter,
// Netdata, the Zabbix agent and Telegraf are found in the units list, and
// the answer stays unknown until a complete list has loaded.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// The rule over one units tick that completed with [status].
ExternalMonitorReport _detect(
  UnitsSnapshot? units, [
  SectionStatus? status = SectionStatus.ok,
]) => detectExternalMonitors(units, status: status);

UnitsSnapshot _units(List<SystemdUnit> units) =>
    UnitsSnapshot(units: units, format: UnitListFormat.json);

SystemdUnit _unit(String name, String active, {String load = 'loaded'}) =>
    SystemdUnit(unit: name, load: load, active: active, sub: active);

void main() {
  test('unknown until the units list loads', () {
    final report = _detect(null, null);
    expect(report.status, AccessStatus.unknown);
    expect(report.units, isEmpty);
  });

  test('unknown when the units collector produced no list', () {
    expect(_detect(UnitsSnapshot()).status, AccessStatus.unknown);
  });

  test('unknown when the list is empty or did not parse', () {
    // A systemd host always lists units (init.scope, -.mount), so an
    // empty list means systemctl failed behind its section header.
    final noBus = parseUnits(
      '== units_json ==\n'
      'System has not been booted with systemd as init system (PID 1).\n'
      '== failed_json ==\n'
      '[]',
      ParseContext.standard,
    ).value;
    final strayLine = parseUnits(
      '== units_json ==\n'
      'Warning: x\n'
      '[{"unit":"netdata.service","load":"loaded","active":"active",'
      '"sub":"running"}]\n'
      '== failed_json ==\n'
      '[]',
      ParseContext.standard,
    ).value;
    for (final units in [_units(const []), noBus, strayLine]) {
      expect(units.format, UnitListFormat.json);
      expect(_detect(units).status, AccessStatus.unknown);
    }
  });

  test('unknown when the units section did not complete', () {
    // A guard cut-off can truncate a text list after the header and
    // some rows, dropping a monitor further down.
    final partial = _units([_unit('ssh.service', 'active')]);
    for (final status in [
      SectionStatus.timeout,
      SectionStatus.error,
      SectionStatus.denied,
      SectionStatus.missing,
      null,
    ]) {
      expect(
        _detect(partial, status).status,
        AccessStatus.unknown,
        reason: '$status',
      );
    }
  });

  test('a loaded list without monitors is missing', () {
    final report = _detect(
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
      final report = _detect(_units([_unit(name, 'active')]));
      expect(report.status, AccessStatus.ok, reason: name);
      expect(report.running, [monitor], reason: name);
    }
  });

  test('an installed but stopped monitor is listed, not counted', () {
    final report = _detect(
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
    final report = _detect(
      _units([_unit('netdata.service', 'inactive', load: 'not-found')]),
    );
    expect(report.status, AccessStatus.missing);
    expect(report.units, isEmpty);
  });

  test('the text format (systemd below 246) is read the same way', () {
    final report = _detect(
      UnitsSnapshot(
        units: [_unit('zabbix-agent.service', 'active')],
        format: UnitListFormat.text,
      ),
    );
    expect(report.running, [ExternalMonitor.zabbixAgent]);
  });
}
