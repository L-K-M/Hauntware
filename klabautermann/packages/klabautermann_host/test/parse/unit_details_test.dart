// Per-unit read parser tests (03 §7.5): `systemctl show`'s resource
// properties (SVC-08) and `systemctl list-sockets` in both shapes
// (SVC-10). The samples follow systemd's output under `TZ=UTC`.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('unit resources', () {
    test('a running service reports every property, in any order', () {
      final r = parseUnitResources(
        'MainPID=812\n'
        'NRestarts=2\n'
        'ActiveEnterTimestamp=Tue 2026-10-20 09:12:01 UTC\n'
        'MemoryCurrent=18350080\n'
        'TasksCurrent=3\n'
        'CPUUsageNSec=1534000000\n'
        'Unrelated=1\n',
      );
      expect(r.warnings, isEmpty);
      expect(r.value.mainPid, 812);
      expect(r.value.restarts, 2);
      expect(r.value.memoryBytes, 18350080);
      expect(r.value.tasks, 3);
      expect(r.value.cpu, const Duration(milliseconds: 1534));
      expect(r.value.activeSince, DateTime.utc(2026, 10, 20, 9, 12, 1));
    });

    test('an inactive unit without accounting reports nothing', () {
      final r = parseUnitResources(
        'MainPID=0\n'
        'NRestarts=0\n'
        'ActiveEnterTimestamp=\n'
        'MemoryCurrent=[not set]\n'
        'TasksCurrent=18446744073709551615\n'
        'CPUUsageNSec=[not set]\n',
      );
      expect(r.warnings, isEmpty);
      expect(r.value.mainPid, isNull, reason: 'systemd says 0 for none');
      expect(r.value.restarts, 0);
      expect(r.value.memoryBytes, isNull);
      expect(r.value.tasks, isNull);
      expect(r.value.cpu, isNull);
      expect(r.value.activeSince, isNull);
    });

    test('a systemd without NRestarts leaves it unknown', () {
      final r = parseUnitResources('MainPID=1\nMemoryCurrent=4096\n');
      expect(r.value.restarts, isNull);
      expect(r.value.memoryBytes, 4096);
    });

    test('values that do not parse warn and stay unknown', () {
      final r = parseUnitResources(
        'MemoryCurrent=lots\n'
        'ActiveEnterTimestamp=Tue 2026-10-20 11:12:01 CEST\n',
      );
      expect(r.value.memoryBytes, isNull);
      expect(r.value.activeSince, isNull);
      expect(r.warnings, hasLength(2));
    });
  });

  group('sockets', () {
    test('JSON rows, with activated units as a string or a list', () {
      final r = parseUnitSockets(
        '[{"listen":"/run/dbus/system_bus_socket","unit":"dbus.socket",'
        '"activates":"dbus.service"},'
        '{"listen":"[::]:22","unit":"sshd.socket","activates":["sshd@.service"]},'
        '{"listen":"/run/x","unit":"x.socket","activates":""},'
        '{"unit":"broken.socket"}]',
        UnitTableFormat.json,
      );
      expect(r.value.map((s) => s.toJson()), [
        {
          'listen': '/run/dbus/system_bus_socket',
          'unit': 'dbus.socket',
          'activates': ['dbus.service'],
        },
        {
          'listen': '[::]:22',
          'unit': 'sshd.socket',
          'activates': ['sshd@.service'],
        },
        {'listen': '/run/x', 'unit': 'x.socket', 'activates': <String>[]},
      ]);
      expect(r.warnings, ['list-sockets: malformed row skipped']);
    });

    test('output that is not a JSON array warns and yields nothing', () {
      expect(parseUnitSockets('{}', UnitTableFormat.json).value, isEmpty);
      final r = parseUnitSockets('Failed to connect', UnitTableFormat.json);
      expect(r.value, isEmpty);
      expect(r.warnings.single, startsWith('list-sockets: not JSON'));
    });

    test('text rows split at the socket unit, so netlink addresses keep '
        'their space', () {
      final r = parseUnitSockets(
        '/run/dbus/system_bus_socket   dbus.socket                    '
        'dbus.service\n'
        'audit 1                       systemd-journald-audit.socket  '
        'systemd-journald.service\n'
        '/run/a                        a.socket                       '
        'a.service, b.service\n'
        '/run/idle                     idle.socket\n'
        '\n'
        'garbage without a unit\n',
        UnitTableFormat.text,
      );
      expect(r.value.map((s) => s.toJson()), [
        {
          'listen': '/run/dbus/system_bus_socket',
          'unit': 'dbus.socket',
          'activates': ['dbus.service'],
        },
        {
          'listen': 'audit 1',
          'unit': 'systemd-journald-audit.socket',
          'activates': ['systemd-journald.service'],
        },
        {
          'listen': '/run/a',
          'unit': 'a.socket',
          'activates': ['a.service', 'b.service'],
        },
        {'listen': '/run/idle', 'unit': 'idle.socket', 'activates': <String>[]},
      ]);
      expect(r.warnings, hasLength(1));
    });
  });
}
