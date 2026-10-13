/// Parser for the `units` slow-collector payload (03 §6.4, §7.5):
/// `systemctl list-units --all` plus `systemctl --failed`, as JSON on
/// systemd 246+ (`== units_json ==`) and as `--plain --no-legend` text
/// below (`== units_text ==`).
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Which shape the `units` and `failed` blocks took (03 §6.4): JSON on
/// systemd 246+, the plain text table below it, or absent output.
enum UnitListFormat { json, text, none }

/// One row of `systemctl list-units` (03 §7.5).
@immutable
final class SystemdUnit {
  const SystemdUnit({
    required this.unit,
    this.load,
    this.active,
    this.sub,
    this.description,
  });

  /// Unit name (`foo.service`); carries the type suffix.
  final String unit;

  /// `load`, `active` and `sub` columns, verbatim when unknown.
  final String? load, active, sub;

  /// The trailing description column; may carry any text.
  final String? description;

  Map<String, Object?> toJson() => {
    'unit': unit,
    'load': load,
    'active': active,
    'sub': sub,
    'description': description,
  };
}

/// One `units` tick (03 §6.4).
@immutable
final class UnitsSnapshot {
  UnitsSnapshot({
    List<SystemdUnit>? units,
    List<SystemdUnit>? failed,
    this.format = UnitListFormat.none,
    this.timeoutAbsent = false,
  }) : units = List.unmodifiable(units ?? []),
       failed = List.unmodifiable(failed ?? []);

  /// All loaded units, in `systemctl` order.
  final List<SystemdUnit> units;

  /// The `systemctl --failed` subset (SVC-02).
  final List<SystemdUnit> failed;

  /// Which wire shape the blocks held.
  final UnitListFormat format;

  /// True when the payload reports the collector ran without `timeout`
  /// (03 §6.3).
  final bool timeoutAbsent;

  Map<String, Object?> toJson() => {
    'units': units.map((u) => u.toJson()).toList(),
    'failed': failed.map((u) => u.toJson()).toList(),
    'format': format.name,
    'timeoutAbsent': timeoutAbsent,
  };
}

/// Parses a `units` section payload; never throws (03 §6.5).
ParseResult<UnitsSnapshot> parseUnits(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.timeoutAbsent) {
    warnings.add('units ran without a timeout guard');
  }
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }
  final blocks = split.blocks;

  List<SystemdUnit> units = const [];
  List<SystemdUnit> failed = const [];
  var format = UnitListFormat.none;
  if (blocks['units_json'] case final lines?) {
    format = UnitListFormat.json;
    units = _parseUnitsJson(lines, 'units_json', warnings);
    failed = _parseUnitsJson(
      blocks['failed_json'] ?? const [],
      'failed_json',
      warnings,
    );
  } else if (blocks['units_text'] case final lines?) {
    format = UnitListFormat.text;
    units = _parseUnitsText(lines, 'units_text', warnings);
    failed = _parseUnitsText(
      blocks['failed_text'] ?? const [],
      'failed_text',
      warnings,
    );
  } else {
    warnings.add('units: no units block');
  }

  return ParseResult(
    UnitsSnapshot(
      units: units,
      failed: failed,
      format: format,
      timeoutAbsent: split.timeoutAbsent,
    ),
    warnings,
  );
}

/// `systemctl list-units --output=json` rows: an array of objects with
/// `unit`, `load`, `active`, `sub` and `description` keys; unknown keys
/// are tolerated and malformed entries warn and skip.
List<SystemdUnit> _parseUnitsJson(
  List<String> lines,
  String block,
  List<String> warnings,
) {
  final text = lines.join('\n').trim();
  if (text.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    warnings.add('units $block: not JSON');
    return const [];
  }
  if (decoded is! List) {
    warnings.add('units $block: JSON is not a list');
    return const [];
  }
  final out = <SystemdUnit>[];
  for (final e in decoded) {
    if (e is! Map) {
      warnings.add('units $block: non-object row skipped');
      continue;
    }
    final unit = e['unit'];
    if (unit is! String || unit.isEmpty) {
      warnings.add('units $block: row without a unit name skipped');
      continue;
    }
    out.add(
      SystemdUnit(
        unit: unit,
        load: _str(e['load']),
        active: _str(e['active']),
        sub: _str(e['sub']),
        description: _str(e['description']),
      ),
    );
  }
  return out;
}

/// A JSON value as a string without throwing: a string stays, a number or
/// bool stringifies, anything else (object, array, null) is unknown.
String? _str(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return '$v';
  return null;
}

/// `systemctl list-units --plain --no-legend` rows: `UNIT LOAD ACTIVE
/// SUB DESCRIPTION...` where only the description may contain spaces
/// (03 §7.5).
List<SystemdUnit> _parseUnitsText(
  List<String> lines,
  String block,
  List<String> warnings,
) {
  final out = <SystemdUnit>[];
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    // Legend and hint lines survive a missing --no-legend on old tools.
    if (t.startsWith('UNIT ') ||
        RegExp(r'^\d+ (loaded )?units? listed\.$').hasMatch(t) ||
        t.startsWith('Pass --all')) {
      continue;
    }
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length < 4) {
      warnings.add('units $block: short row "$t"');
      continue;
    }
    out.add(
      SystemdUnit(
        unit: parts[0],
        load: parts[1],
        active: parts[2],
        sub: parts[3],
        description: parts.length > 4 ? parts.sublist(4).join(' ') : null,
      ),
    );
  }
  return out;
}
