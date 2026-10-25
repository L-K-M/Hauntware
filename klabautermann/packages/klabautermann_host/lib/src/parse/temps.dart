/// Parser for the `temps` slow-collector payload (03 §6.4, HW-01): the
/// hwmon temperature inputs, and the thermal zones as a fallback where
/// no hwmon chip reports one.
library;

import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// The plausible range of a sensor reading in °C. Outside it a chip
/// reports an unwired input or an error code (-273, 255, a millidegree
/// overflow), which the parser drops with a warning.
const double _minCelsius = -60, _maxCelsius = 250;

/// One temperature sensor (HW-01).
@immutable
final class TempSensor {
  const TempSensor({
    required this.id,
    required this.chip,
    required this.celsius,
    this.label,
    this.highCelsius,
    this.criticalCelsius,
  });

  /// Unique on the host: `hwmon3/temp1`, or the thermal zone's name.
  final String id;

  /// The hwmon chip's `name` (`coretemp`, `k10temp`, `nvme`, `acpitz`),
  /// or a thermal zone's `type`.
  final String chip;

  /// The input's `temp<N>_label` (`Package id 0`, `Composite`), if any.
  final String? label;

  final double celsius;

  /// The chip's `temp<N>_max` and `temp<N>_crit`, where it reports a
  /// plausible one.
  final double? highCelsius, criticalCelsius;

  Map<String, Object?> toJson() => {
    'id': id,
    'chip': chip,
    'label': ?label,
    'celsius': celsius,
    'highCelsius': ?highCelsius,
    'criticalCelsius': ?criticalCelsius,
  };
}

/// Every temperature sensor the host reported.
@immutable
final class TempsSnapshot {
  const TempsSnapshot(this.sensors);

  /// Empty where the host has none, as VMs and containers usually do.
  final List<TempSensor> sensors;

  Map<String, Object?> toJson() => {
    'sensors': [for (final s in sensors) s.toJson()],
  };
}

/// Parses a `temps` section payload; never throws (03 §6.5). The
/// `hwmon` block holds rows of the directory, chip, input, millidegrees,
/// max, crit and label, `|`-separated; the `thermal` block rows of the
/// zone, millidegrees and type. A zone usually repeats a hwmon chip's reading (`acpitz`,
/// `x86_pkg_temp` beside `coretemp`), so zones count only where no hwmon
/// input gave a reading.
ParseResult<TempsSnapshot> parseTemps(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }

  final sensors = <TempSensor>[];
  for (final line in split.blocks['hwmon'] ?? const <String>[]) {
    if (line.trim().isEmpty) continue;
    final f = line.split('|');
    if (f.length < 7 || f[0].isEmpty || f[1].isEmpty || f[2].isEmpty) {
      warnings.add('temps: malformed hwmon row "$line"');
      continue;
    }
    final celsius = _celsius(f[3]);
    if (celsius == null) {
      warnings.add('temps: implausible reading "$line"');
      continue;
    }
    final label = f.sublist(6).join('|').trim();
    sensors.add(
      TempSensor(
        id: '${f[0]}/${f[2]}',
        chip: f[1],
        label: label.isEmpty ? null : label,
        celsius: celsius,
        highCelsius: _limit(f[4]),
        criticalCelsius: _limit(f[5]),
      ),
    );
  }
  if (sensors.isNotEmpty) return ParseResult(TempsSnapshot(sensors), warnings);

  for (final line in split.blocks['thermal'] ?? const <String>[]) {
    if (line.trim().isEmpty) continue;
    final f = line.split('|');
    if (f.length < 3 || f[0].isEmpty) {
      warnings.add('temps: malformed thermal row "$line"');
      continue;
    }
    final celsius = _celsius(f[1]);
    if (celsius == null) {
      warnings.add('temps: implausible reading "$line"');
      continue;
    }
    final type = f.sublist(2).join('|').trim();
    sensors.add(
      TempSensor(id: f[0], chip: type.isEmpty ? f[0] : type, celsius: celsius),
    );
  }
  return ParseResult(TempsSnapshot(sensors), warnings);
}

/// Millidegrees as °C, or null when not an integer in the plausible range.
double? _celsius(String millidegrees) {
  final value = int.tryParse(millidegrees.trim());
  if (value == null) return null;
  final celsius = value / 1000;
  if (celsius < _minCelsius || celsius > _maxCelsius) return null;
  return celsius;
}

/// A chip's limit as °C; null when absent, zero (unset on many chips) or
/// implausible.
double? _limit(String millidegrees) {
  final celsius = _celsius(millidegrees);
  return celsius == null || celsius == 0 ? null : celsius;
}
