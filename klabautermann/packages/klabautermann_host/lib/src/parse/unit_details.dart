/// Parsers for the per-unit reads of the v1 Services view (03 §7.5):
/// `systemctl show`'s resource properties (SVC-08) and
/// `systemctl list-sockets` (SVC-10). Both take the output of a
/// [HostCommands] builder run through `commandLine`, which exports
/// `TZ=UTC`, and never throw on host input.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show HostCommands, UnitTableFormat, kUnitResourceProperties;
import 'parse_result.dart';

/// What systemd prints for an unset 64-bit counter: `UINT64_MAX`, which
/// `systemctl show` writes out unless it prints `[not set]`.
const String _unsetCounter = '18446744073709551615';

/// One unit's resource use (SVC-08, 03 §7.5). Each field is null when
/// systemd did not report it: accounting off, the unit inactive, or a
/// systemd too old for the property.
@immutable
final class UnitResources {
  const UnitResources({
    this.memoryBytes,
    this.cpu,
    this.tasks,
    this.restarts,
    this.mainPid,
    this.activeSince,
  });

  /// `MemoryCurrent`: the unit's cgroup memory, in bytes.
  final int? memoryBytes;

  /// `CPUUsageNSec`: CPU time used since the unit started.
  final Duration? cpu;

  /// `TasksCurrent`: processes and threads in the unit's cgroup.
  final int? tasks;

  /// `NRestarts`: automatic restarts since the unit was last started by
  /// hand (systemd 235+).
  final int? restarts;

  /// `MainPID`, null when the unit has no main process (systemd's 0).
  final int? mainPid;

  /// `ActiveEnterTimestamp`: when the unit last became active, in UTC.
  final DateTime? activeSince;

  Map<String, Object?> toJson() => {
    'memoryBytes': memoryBytes,
    'cpuMicros': cpu?.inMicroseconds,
    'tasks': tasks,
    'restarts': restarts,
    'mainPid': mainPid,
    'activeSince': activeSince?.toIso8601String(),
  };
}

/// `ActiveEnterTimestamp` under `TZ=UTC`: `Tue 2026-10-20 09:12:01 UTC`.
final _utcTimestamp = RegExp(
  r'^\w+ (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) UTC$',
);

/// Reads [HostCommands.unitResources]' output, `KEY=VALUE` lines in any
/// order. Unknown keys are ignored; a value that does not parse warns
/// and stays null.
ParseResult<UnitResources> parseUnitResources(String raw) {
  final warnings = <String>[];
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(raw)) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq);
    if (!kUnitResourceProperties.contains(key)) continue;
    values[key] = line.substring(eq + 1).trim();
  }

  int? counter(String key) {
    final value = values[key];
    if (value == null || value.isEmpty) return null;
    if (value == _unsetCounter || value == '[not set]') return null;
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 0) warnings.add('$key: "$value"');
    return parsed != null && parsed >= 0 ? parsed : null;
  }

  final cpuNanos = counter('CPUUsageNSec');
  final mainPid = counter('MainPID');
  return ParseResult(
    UnitResources(
      memoryBytes: counter('MemoryCurrent'),
      cpu: cpuNanos == null ? null : Duration(microseconds: cpuNanos ~/ 1000),
      tasks: counter('TasksCurrent'),
      restarts: counter('NRestarts'),
      mainPid: mainPid == 0 ? null : mainPid,
      activeSince: _timestamp(values['ActiveEnterTimestamp'], warnings),
    ),
    warnings,
  );
}

DateTime? _timestamp(String? value, List<String> warnings) {
  if (value == null || value.isEmpty || value == 'n/a') return null;
  final m = _utcTimestamp.firstMatch(value);
  if (m == null) {
    warnings.add('ActiveEnterTimestamp: "$value"');
    return null;
  }
  int g(int i) => int.parse(m.group(i)!);
  return DateTime.utc(g(1), g(2), g(3), g(4), g(5), g(6));
}

/// One row of `systemctl list-sockets` (SVC-10, 03 §7.5).
@immutable
final class UnitSocket {
  UnitSocket({
    required this.listen,
    required this.unit,
    List<String> activates = const [],
  }) : activates = List.unmodifiable(activates);

  /// The address, path or netlink family the socket listens on.
  final String listen;

  /// The socket unit (`dbus.socket`).
  final String unit;

  /// The units a connection starts.
  final List<String> activates;

  Map<String, Object?> toJson() => {
    'listen': listen,
    'unit': unit,
    'activates': activates,
  };
}

/// Reads [HostCommands.unitSockets]' output in the [format] it asked
/// for. Malformed rows warn and are skipped.
ParseResult<List<UnitSocket>> parseUnitSockets(
  String raw,
  UnitTableFormat format,
) {
  final warnings = <String>[];
  final sockets = switch (format) {
    UnitTableFormat.json => _socketsJson(raw, warnings),
    UnitTableFormat.text => _socketsText(raw, warnings),
  };
  return ParseResult(List.unmodifiable(sockets), warnings);
}

/// `--output=json`: an array of objects keyed by the lower-cased column
/// headers, `listen`, `unit` and `activates` (a string, or a list on
/// some versions).
List<UnitSocket> _socketsJson(String raw, List<String> warnings) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    warnings.add('list-sockets: not JSON (${e.message})');
    return const [];
  }
  if (decoded is! List) {
    warnings.add('list-sockets: not a JSON array');
    return const [];
  }

  final sockets = <UnitSocket>[];
  for (final entry in decoded) {
    final listen = entry is Map ? entry['listen'] : null;
    final unit = entry is Map ? entry['unit'] : null;
    if (listen is! String || unit is! String || unit.isEmpty) {
      warnings.add('list-sockets: malformed row skipped');
      continue;
    }
    final activates = switch (entry['activates']) {
      final String s => _activates(s),
      final List<Object?> l => [
        for (final a in l)
          if (a is String && a.isNotEmpty) a,
      ],
      _ => const <String>[],
    };
    sockets.add(UnitSocket(listen: listen, unit: unit, activates: activates));
  }
  return sockets;
}

/// `--no-legend` text: `LISTEN UNIT ACTIVATES`. A netlink address holds
/// a space (`audit 1`), so the row splits at its last `.socket` word, the
/// unit: an address may end in `.socket` too (`/run/dm-event.socket`),
/// while a socket only activates services.
List<UnitSocket> _socketsText(String raw, List<String> warnings) {
  final sockets = <UnitSocket>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line.trim().isEmpty) continue;
    final words = line.trim().split(RegExp(r'\s+'));
    final at = words.lastIndexWhere((w) => w.endsWith('.socket'));
    if (at < 1) {
      warnings.add('list-sockets: row without a socket unit skipped');
      continue;
    }
    sockets.add(
      UnitSocket(
        listen: words.take(at).join(' '),
        unit: words[at],
        activates: _activates(words.skip(at + 1).join(' ')),
      ),
    );
  }
  return sockets;
}

/// Activated units as systemd joins them: `a.service, b.service`.
List<String> _activates(String joined) => [
  for (final unit in joined.split(RegExp(r'[,\s]+')))
    if (unit.isNotEmpty) unit,
];
