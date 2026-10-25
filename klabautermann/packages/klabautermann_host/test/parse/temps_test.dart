import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// HW-01: the `temps` payload.
void main() {
  group('parseTemps', () {
    test('reads each hwmon input with its label and limits, in °C', () {
      final result = parseTemps(
        [
          '== hwmon ==',
          'hwmon2|coretemp|temp1|48000|84000|100000|Package id 0',
          'hwmon2|coretemp|temp2|45500|84000|100000|Core 0',
          'hwmon4|nvme|temp1|38850|81850|84850|Composite',
          'hwmon5|acpitz|temp1|27800|||',
          '== thermal ==',
          'thermal_zone0|27800|acpitz',
        ].join('\n'),
        ParseContext.standard,
      );

      expect(result.warnings, isEmpty);
      final sensors = result.value.sensors;
      expect(
        [for (final s in sensors) s.id],
        ['hwmon2/temp1', 'hwmon2/temp2', 'hwmon4/temp1', 'hwmon5/temp1'],
      );
      expect(sensors.first.chip, 'coretemp');
      expect(sensors.first.label, 'Package id 0');
      expect(sensors.first.celsius, 48.0);
      expect(sensors.first.highCelsius, 84.0);
      expect(sensors.first.criticalCelsius, 100.0);
      expect(sensors[2].celsius, closeTo(38.85, 1e-9));
      // Unset limits and labels stay unknown.
      expect(sensors.last.label, isNull);
      expect(sensors.last.highCelsius, isNull);
      expect(sensors.last.criticalCelsius, isNull);
    });

    test('takes the thermal zones only where no hwmon input reads', () {
      final result = parseTemps(
        [
          '== hwmon ==',
          '== thermal ==',
          'thermal_zone0|41000|x86_pkg_temp',
          'thermal_zone1|39000|',
        ].join('\n'),
        ParseContext.standard,
      );

      expect(result.warnings, isEmpty);
      final sensors = result.value.sensors;
      expect(
        [for (final s in sensors) (s.id, s.chip)],
        [('thermal_zone0', 'x86_pkg_temp'), ('thermal_zone1', 'thermal_zone1')],
      );
      expect(sensors.first.celsius, 41.0);
    });

    test('a host without sensors reads empty, as VMs do', () {
      final result = parseTemps(
        '== hwmon ==\n== thermal ==\n',
        ParseContext.standard,
      );
      expect(result.warnings, isEmpty);
      expect(result.value.sensors, isEmpty);
    });

    test('drops implausible readings and limits and malformed rows with a '
        'warning; a label may hold the separator', () {
      final result = parseTemps(
        [
          '== hwmon ==',
          'hwmon1|it8728|temp3|-128000|||',
          'hwmon1|it8728|temp4|255000|||',
          'hwmon1|it8728|temp5|abc|||',
          'hwmon1|it8728',
          'hwmon1|it8728|temp1|35000|0|127000000|CPU | socket',
        ].join('\n'),
        ParseContext.standard,
      );

      expect(result.warnings, hasLength(4));
      final sensor = result.value.sensors.single;
      expect(sensor.label, 'CPU | socket');
      expect(sensor.highCelsius, isNull);
      expect(sensor.criticalCelsius, isNull);
    });
  });
}
