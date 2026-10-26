/// Parser for CPU-07's model and topology (03 §7.1), as
/// [HostCommands.cpuTopology] prints them.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show HostCommands, kCpuInfoMarker, kCpuLscpuMarker, kCpuNprocMarker;

/// The processor's model and how its CPUs are laid out (CPU-07). A figure
/// the host does not report is null: `lscpu` prints `-` for sockets on
/// most arm64 boards, and arm64's `/proc/cpuinfo` names no model.
@immutable
final class CpuTopology {
  CpuTopology({
    required List<String> models,
    this.vendor,
    this.logicalCpus,
    this.usableCpus,
    this.sockets,
    this.cores,
    this.threadsPerCore,
  }) : models = List.unmodifiable(models);

  /// The distinct model names, in the order the host lists them: more than
  /// one on a big.LITTLE board.
  final List<String> models;

  /// `lscpu`'s vendor ID, such as `GenuineIntel` or `ARM`.
  final String? vendor;

  /// The CPUs the kernel counts, online or not.
  final int? logicalCpus;

  /// The CPUs the login's processes may run on (`nproc`): fewer than
  /// [logicalCpus] under a cpuset, as in a container.
  final int? usableCpus;

  final int? sockets;

  /// Physical cores across all sockets and clusters.
  final int? cores;

  /// The most hardware threads one core runs: 2 with SMT.
  final int? threadsPerCore;
}

/// One model's figures from `lscpu`, which lists them after the model's
/// name (or, before util-linux 2.37, before it).
typedef _LscpuGroup = Map<String, String>;

const _model = 'Model name';
const _sockets = 'Socket(s)';
const _clusters = 'Cluster(s)';
const _coresPerSocket = 'Core(s) per socket';
const _coresPerCluster = 'Core(s) per cluster';
const _threadsPerCore = 'Thread(s) per core';
const _topologyFields = {
  _sockets,
  _clusters,
  _coresPerSocket,
  _coresPerCluster,
  _threadsPerCore,
};

final _cpuInfoLine = RegExp(r'^([^:]*?)\s*:\s*(.*)$');

/// The topology in [raw], or null when it is not the read's output.
CpuTopology? parseCpuTopology(String raw) {
  final lines = raw.split('\n');
  final lscpuAt = lines.indexOf(kCpuLscpuMarker);
  final infoAt = lines.indexOf(kCpuInfoMarker);
  if (lines.first != kCpuNprocMarker || lscpuAt < 1 || infoAt < lscpuAt) {
    return null;
  }

  final usable = int.tryParse(lines.sublist(1, lscpuAt).join().trim());
  final fields = _lscpuFields(lines.sublist(lscpuAt + 1, infoAt).join('\n'));
  final info = _CpuInfo.parse(lines.sublist(infoAt + 1));

  // Each model's figures follow its name; the ones before the first name,
  // as older `lscpu` prints them, apply to every model.
  final shared = <String, String>{};
  final groups = <_LscpuGroup>[];
  for (final (name, value) in fields) {
    if (name == _model) {
      groups.add({_model: value});
    } else if (_topologyFields.contains(name)) {
      (groups.lastOrNull ?? shared)[name] = value;
    }
  }
  if (groups.isEmpty && shared.isNotEmpty) groups.add({});
  for (final group in groups) {
    for (final MapEntry(:key, :value) in shared.entries) {
      group.putIfAbsent(key, () => value);
    }
  }

  String? field(String name) => fields
      .where((field) => field.$1 == name)
      .map((field) => field.$2)
      .firstOrNull;

  final models = {
    for (final group in groups)
      if (_text(group[_model]) case final model?) model,
  };
  return CpuTopology(
    models: models.isEmpty ? info.models : models.toList(),
    vendor: _text(field('Vendor ID')),
    logicalCpus: _count(field('CPU(s)')) ?? info.processors,
    usableCpus: usable,
    sockets: groups.isEmpty ? info.sockets : _maxOf(groups, _sockets),
    cores: groups.isEmpty ? info.cores : _coresOf(groups),
    threadsPerCore: groups.isEmpty
        ? info.threadsPerCore
        : _maxOf(groups, _threadsPerCore),
  );
}

/// `lscpu -J`'s fields in document order, without their colons. Its
/// `children`, which `--hierarchic` adds, are walked in place.
List<(String, String)> _lscpuFields(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  final out = <(String, String)>[];
  void walk(Object? rows) {
    if (rows is! List) return;
    for (final row in rows) {
      if (row case {'field': final String name, 'data': final String data}) {
        final trimmed = name.trim();
        out.add((
          trimmed.endsWith(':')
              ? trimmed.substring(0, trimmed.length - 1)
              : trimmed,
          data.trim(),
        ));
      }
      if (row case {'children': final List<Object?> children}) {
        walk(children);
      }
    }
  }

  if (decoded case {'lscpu': final List<Object?> rows}) walk(rows);
  return out;
}

/// [value] unless it is empty or `lscpu`'s `-` for unknown.
String? _text(String? value) => switch (value?.trim()) {
  null || '' || '-' => null,
  final text => text,
};

int? _count(String? value) => switch (int.tryParse(value?.trim() ?? '')) {
  final n? when n > 0 => n,
  _ => null,
};

int? _maxOf(List<_LscpuGroup> groups, String name) {
  final counts = [for (final group in groups) _count(group[name])];
  if (counts.contains(null)) return null;
  return counts.cast<int>().reduce((a, b) => a > b ? a : b);
}

/// The cores of every model: per socket times sockets, or per cluster
/// times clusters on arm64, which has no sockets; null when one model's
/// count is unknown, rather than an undercount.
int? _coresOf(List<_LscpuGroup> groups) {
  var total = 0;
  for (final group in groups) {
    final perSocket = _count(group[_coresPerSocket]);
    final sockets = _count(group[_sockets]);
    final perCluster = _count(group[_coresPerCluster]);
    final clusters = _count(group[_clusters]);
    final cores = switch ((perSocket, sockets, perCluster, clusters)) {
      (final per?, final n?, _, _) => per * n,
      (_, _, final per?, final n?) => per * n,
      _ => null,
    };
    if (cores == null) return null;
    total += cores;
  }
  return total;
}

/// What `/proc/cpuinfo`'s kept lines say, for a host without `lscpu`.
final class _CpuInfo {
  const _CpuInfo({
    required this.models,
    this.processors,
    this.sockets,
    this.cores,
  });

  factory _CpuInfo.parse(List<String> lines) {
    final models = <String>{};
    final sockets = <String>{};
    final cores = <String>{};
    var processors = 0;
    var placedCpus = 0;
    String? socket;
    for (final line in lines) {
      final match = _cpuInfoLine.firstMatch(line);
      if (match == null) continue;
      final value = match[2]!.trim();
      switch (match[1]!.trim()) {
        case 'processor':
          processors++;
          socket = null;
        case 'model name' || 'cpu model' || 'cpu' when value.isNotEmpty:
          models.add(value);
        case 'physical id':
          socket = value;
          sockets.add(value);
        case 'core id' when socket != null:
          cores.add('$socket/$value');
          placedCpus++;
      }
    }
    // Every CPU must say where it sits, or the counts would undercount.
    final placed = processors > 0 && placedCpus == processors;
    return _CpuInfo(
      models: models.toList(),
      processors: processors > 0 ? processors : null,
      sockets: placed ? sockets.length : null,
      cores: placed ? cores.length : null,
    );
  }

  final List<String> models;
  final int? processors;
  final int? sockets;
  final int? cores;

  int? get threadsPerCore => switch ((processors, cores)) {
    (final cpus?, final cores?) when cpus % cores == 0 => cpus ~/ cores,
    _ => null,
  };
}
