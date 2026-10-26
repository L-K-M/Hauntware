/// Parser for PRC-04 and PRC-05's process read (03 §7.2), as
/// [HostCommands.processDetail] prints it.
library;

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show
        HostCommands,
        kProcessDetailDenied,
        kProcessDetailMarker,
        kProcessEnvironLimit;

/// A container runtime a process's cgroup names (PRC-05).
enum ContainerRuntime { docker, podman, containerd, crio }

/// What owns a process (PRC-05), read from its cgroups: the systemd unit
/// whose cgroup holds it, and the container it runs in.
@immutable
final class ProcessAttribution {
  const ProcessAttribution({this.unit, this.containerId, this.runtime});

  /// The innermost systemd unit (`nginx.service`, `session-3.scope`), or
  /// null outside one.
  final String? unit;

  /// The container's full id, or null outside one.
  final String? containerId;
  final ContainerRuntime? runtime;
}

/// One of a process's `limits` rows, soft and hard; null is unlimited.
@immutable
final class ProcessLimit {
  const ProcessLimit({this.soft, this.hard});

  final int? soft;
  final int? hard;
}

/// PRC-04's facts about one process. A field the login user may not read
/// is null with its `...Denied` flag set; one the host does not have is
/// null alone.
@immutable
final class ProcessDetail {
  ProcessDetail({
    this.cwd,
    this.cwdDenied = false,
    this.threads,
    this.swapKb,
    this.voluntarySwitches,
    this.involuntarySwitches,
    required this.attribution,
    this.openFilesLimit,
    this.processesLimit,
    this.openFiles,
    this.openFilesDenied = false,
    List<String>? environment,
    this.environmentDenied = false,
  }) : environment = environment == null
           ? null
           : List.unmodifiable(environment);

  final String? cwd;
  final bool cwdDenied;
  final int? threads;
  final int? swapKb;
  final int? voluntarySwitches, involuntarySwitches;
  final ProcessAttribution attribution;

  /// `Max open files` and `Max processes` from `limits`.
  final ProcessLimit? openFilesLimit, processesLimit;

  /// How many descriptors it holds open.
  final int? openFiles;
  final bool openFilesDenied;

  /// Its environment as `KEY=VALUE` entries, at most
  /// [kProcessEnvironLimit]; callers mask the values before they cross.
  final List<String>? environment;
  final bool environmentDenied;

  /// This detail without its environment, which a caller carries masked
  /// beside it.
  ProcessDetail withoutEnvironment() => ProcessDetail(
    cwd: cwd,
    cwdDenied: cwdDenied,
    threads: threads,
    swapKb: swapKb,
    voluntarySwitches: voluntarySwitches,
    involuntarySwitches: involuntarySwitches,
    attribution: attribution,
    openFilesLimit: openFilesLimit,
    processesLimit: processesLimit,
    openFiles: openFiles,
    openFilesDenied: openFilesDenied,
    environmentDenied: environmentDenied,
  );
}

/// A systemd unit's cgroup name.
final _unit = RegExp(
  r'^[A-Za-z0-9:_.\\@-]+\.(service|scope|socket|mount|swap|slice|timer)$',
);

/// A container's cgroup name, by runtime: `docker-<id>.scope` or
/// `/docker/<id>`, `libpod-<id>.scope`, `cri-containerd-<id>.scope` or a
/// kubepods leaf, and `crio-<id>.scope`.
final _containers = <(RegExp, ContainerRuntime)>[
  (RegExp(r'^docker-([0-9a-f]{64})\.scope$'), ContainerRuntime.docker),
  (RegExp(r'^libpod-([0-9a-f]{64})\.scope$'), ContainerRuntime.podman),
  (
    RegExp(r'^cri-containerd-([0-9a-f]{64})\.scope$'),
    ContainerRuntime.containerd,
  ),
  (RegExp(r'^crio-([0-9a-f]{64})\.scope$'), ContainerRuntime.crio),
];
final _bareId = RegExp(r'^[0-9a-f]{64}$');

/// What [cgroupLines] (`/proc/<pid>/cgroup`) say owns the process: the
/// unified hierarchy's path (`0::`) where there is one, else the
/// `name=systemd` one, read leaf first.
ProcessAttribution attributionFromCgroup(List<String> cgroupLines) {
  String? path;
  String? systemdPath;
  for (final line in cgroupLines) {
    final parts = line.split(':');
    if (parts.length < 3) continue;
    final at = parts.sublist(2).join(':');
    if (parts[0] == '0' && parts[1].isEmpty) path = at;
    if (parts[1] == 'name=systemd') systemdPath = at;
  }
  final chosen = (path == null || path == '/') ? systemdPath ?? path : path;
  if (chosen == null) return const ProcessAttribution();

  final segments = chosen.split('/').where((s) => s.isNotEmpty).toList();
  String? unit;
  String? containerId;
  ContainerRuntime? runtime;
  for (final (index, segment) in segments.indexed.toList().reversed) {
    if (containerId == null) {
      for (final (pattern, kind) in _containers) {
        if (pattern.firstMatch(segment) case final match?) {
          containerId = match[1];
          runtime = kind;
        }
      }
      // cgroupfs layouts: /docker/<id>, /kubepods/.../<id>.
      if (containerId == null && _bareId.hasMatch(segment) && index > 0) {
        final parent = segments[index - 1];
        if (parent == 'docker') {
          containerId = segment;
          runtime = ContainerRuntime.docker;
        } else if (segments.contains('kubepods') ||
            segments.contains('kubepods.slice')) {
          containerId = segment;
        }
      }
    }
    if (unit == null &&
        _unit.hasMatch(segment) &&
        !segment.endsWith('.slice') &&
        _containers.every((c) => !c.$1.hasMatch(segment))) {
      unit = segment;
    }
  }
  return ProcessAttribution(
    unit: unit,
    containerId: containerId,
    runtime: runtime,
  );
}

/// The process read in [raw], or null when it holds no `cwd` section,
/// the script's first.
ProcessDetail? parseProcessDetail(String raw) {
  final sections = <String, List<String>>{};
  List<String>? current;
  final lines = raw.split('\n');
  for (final line in lines) {
    if (current != null && identical(current, sections['environ'])) {
      current.add(line);
      continue;
    }
    if (line.startsWith('$kProcessDetailMarker ') &&
        line != kProcessDetailDenied) {
      current = sections[line.substring(kProcessDetailMarker.length + 1)] = [];
      continue;
    }
    current?.add(line);
  }
  final cwd = sections['cwd'];
  if (cwd == null) return null;

  bool denied(List<String>? section) =>
      section != null &&
      section.isNotEmpty &&
      section.first == kProcessDetailDenied;
  List<String> body(List<String>? section) => [
    for (final line in section ?? const <String>[])
      if (line.isNotEmpty) line,
  ];

  final status = <String, int>{};
  for (final line in body(sections['status'])) {
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final value = int.tryParse(
      line.substring(colon + 1).trim().split(RegExp(r'\s+')).first,
    );
    if (value != null) status[line.substring(0, colon)] = value;
  }

  ProcessLimit? limit(String name) {
    for (final line in body(sections['limits'])) {
      if (!line.startsWith(name)) continue;
      final fields = line.substring(name.length).trim().split(RegExp(r'\s+'));
      if (fields.length < 2) return null;
      return ProcessLimit(
        soft: int.tryParse(fields[0]),
        hard: int.tryParse(fields[1]),
      );
    }
    return null;
  }

  final environ = sections['environ'];
  final fds = sections['fds'];
  return ProcessDetail(
    cwd: denied(cwd) ? null : body(cwd).firstOrNull,
    cwdDenied: denied(cwd),
    threads: status['Threads'],
    swapKb: status['VmSwap'],
    voluntarySwitches: status['voluntary_ctxt_switches'],
    involuntarySwitches: status['nonvoluntary_ctxt_switches'],
    attribution: attributionFromCgroup(body(sections['cgroup'])),
    openFilesLimit: limit('Max open files'),
    processesLimit: limit('Max processes'),
    openFiles: denied(fds) ? null : int.tryParse(body(fds).firstOrNull ?? ''),
    openFilesDenied: denied(fds),
    environment: environ == null || denied(environ) ? null : body(environ),
    environmentDenied: denied(environ),
  );
}
