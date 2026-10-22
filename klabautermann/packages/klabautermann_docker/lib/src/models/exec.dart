/// Exec instances (03 §5.7, §7.13 CTX-07 and CTX-08): what
/// `POST /containers/{id}/exec` created and what `GET /exec/{id}/json`
/// reports about it.
library;

import 'package:meta/meta.dart';

import '../docker_parse_result.dart';
import '../json_reader.dart';

/// A terminal size for an exec (03 §5.7). Docker takes rows first
/// everywhere: `ConsoleSize` is `[height, width]` and the resize query
/// is `h` then `w` (c2 R15).
@immutable
final class ExecConsoleSize {
  const ExecConsoleSize({required this.rows, required this.columns})
    : assert(rows > 0 && columns > 0);

  final int rows;
  final int columns;

  @override
  bool operator ==(Object other) =>
      other is ExecConsoleSize &&
      other.rows == rows &&
      other.columns == columns;

  @override
  int get hashCode => Object.hash(rows, columns);
}

/// `GET /exec/{id}/json`: whether the exec still runs and, once it has
/// ended, its exit code.
@immutable
final class ExecInspect {
  const ExecInspect({
    required this.id,
    this.running,
    this.exitCode,
    this.pid,
    this.containerId,
  });

  factory ExecInspect.parse(JsonReader r) => ExecInspect(
    id: r.string('ID') ?? '',
    running: r.boolean('Running'),
    exitCode: r.integer('ExitCode'),
    pid: r.integer('Pid'),
    containerId: r.string('ContainerID'),
  );

  final String id;
  final bool? running;

  /// The process's exit code, meaningful once [running] is false; the
  /// daemon reports null or 0 while it runs.
  final int? exitCode;

  final int? pid;
  final String? containerId;
}

/// Parses `GET /exec/{id}/json`; never throws.
DockerParseResult<ExecInspect> parseExecInspect(Object? decoded) {
  if (decoded is! Map) {
    return const DockerParseResult(ExecInspect(id: ''), [
      'exec inspect is not a JSON object',
    ]);
  }
  final r = JsonReader(asStringMap(decoded));
  return DockerParseResult(ExecInspect.parse(r), r.warnings);
}
