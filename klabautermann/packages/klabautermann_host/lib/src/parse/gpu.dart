/// Parser for the `gpu` slow-collector payload (03 §6.4, HW-03): the
/// NVIDIA GPUs `nvidia-smi` lists and the amdgpu cards sysfs describes.
library;

import 'package:meta/meta.dart';

import '../hws/program.dart' show kTimeoutAbsentMarker;
import 'models.dart' show splitBlocks;
import 'parse_result.dart';

/// Where a [GpuDevice]'s figures come from.
enum GpuSource {
  /// `nvidia-smi --query-gpu`.
  nvidia,

  /// The amdgpu driver's sysfs files.
  amdgpu,
}

/// One GPU (HW-03). A figure the tool or driver does not report is null.
@immutable
final class GpuDevice {
  const GpuDevice({
    required this.id,
    required this.source,
    this.name,
    this.busyPercent,
    this.memoryUsedBytes,
    this.memoryTotalBytes,
    this.celsius,
    this.powerWatts,
    this.powerLimitWatts,
  });

  /// Unique on the host: `nvidia0`, or the DRM card (`card1`).
  final String id;

  final GpuSource source;

  /// The product name `nvidia-smi` reports; amdgpu has none in sysfs.
  final String? name;

  /// The share of the last sampling period the GPU was busy, 0 to 100.
  final double? busyPercent;

  /// Device memory (VRAM).
  final int? memoryUsedBytes, memoryTotalBytes;

  final double? celsius;

  /// The current draw and the enforced limit, in watts.
  final double? powerWatts, powerLimitWatts;

  Map<String, Object?> toJson() => {
    'id': id,
    'source': source.name,
    'name': ?name,
    'busyPercent': ?busyPercent,
    'memoryUsedBytes': ?memoryUsedBytes,
    'memoryTotalBytes': ?memoryTotalBytes,
    'celsius': ?celsius,
    'powerWatts': ?powerWatts,
    'powerLimitWatts': ?powerLimitWatts,
  };
}

/// Every GPU the host reported.
@immutable
final class GpuSnapshot {
  const GpuSnapshot(this.devices, {this.nvidiaFailure});

  /// Empty where the host has no GPU the collector reads.
  final List<GpuDevice> devices;

  /// The first line of `nvidia-smi`'s output when it is installed but
  /// failed, as when its driver is not loaded (empty if it printed
  /// nothing); null when it ran or is not installed.
  final String? nvidiaFailure;

  Map<String, Object?> toJson() => {
    'devices': [for (final d in devices) d.toJson()],
    'nvidiaFailure': ?nvidiaFailure,
  };
}

/// MiB as `nvidia-smi` reports memory with `nounits`.
const _mib = 1024 * 1024;

/// The number of `nvidia-smi` query fields after the index and name.
const _nvidiaFigures = 6;

/// Parses a `gpu` section payload; never throws (03 §6.5). The `nvidia`
/// block holds `nvidia-smi`'s `rc=` line and its CSV rows (index, name,
/// utilization %, memory used and total in MiB, °C, draw and limit in
/// W); `[N/A]` and `[Not Supported]` read as unknown. The `amdgpu` block
/// holds `|`-separated rows of the card, busy %, VRAM used and total in
/// bytes, millidegrees and microwatts.
ParseResult<GpuSnapshot> parseGpu(String raw, ParseContext ctx) {
  final warnings = <String>[];
  final split = splitBlocks(raw, kTimeoutAbsentMarker);
  if (split.preambleLines > 0) {
    warnings.add('${split.preambleLines} preamble line(s) ignored');
  }

  final devices = <GpuDevice>[];
  String? nvidiaFailure;
  final nvidia = [
    for (final line in split.blocks['nvidia'] ?? const <String>[])
      if (line.trim().isNotEmpty) line,
  ];
  if (nvidia.isNotEmpty) {
    final rc = nvidia.first.startsWith('rc=')
        ? int.tryParse(nvidia.first.substring(3))
        : null;
    final rows = rc == null ? nvidia : nvidia.skip(1).toList();
    if (rc == null) warnings.add('gpu: nvidia block without rc');
    if (rc != null && rc != 0) {
      nvidiaFailure = rows.isEmpty ? '' : rows.first.trim();
    } else {
      for (final row in rows) {
        final device = _nvidiaRow(row);
        if (device == null) {
          warnings.add('gpu: malformed nvidia row "$row"');
          continue;
        }
        devices.add(device);
      }
    }
  }

  for (final line in split.blocks['amdgpu'] ?? const <String>[]) {
    if (line.trim().isEmpty) continue;
    final f = line.split('|');
    final busy = f.length == 6 ? int.tryParse(f[1]) : null;
    if (busy == null || f[0].isEmpty) {
      warnings.add('gpu: malformed amdgpu row "$line"');
      continue;
    }
    final millidegrees = int.tryParse(f[4]);
    final microwatts = int.tryParse(f[5]);
    devices.add(
      GpuDevice(
        id: f[0],
        source: GpuSource.amdgpu,
        busyPercent: busy.clamp(0, 100).toDouble(),
        memoryUsedBytes: int.tryParse(f[2]),
        memoryTotalBytes: int.tryParse(f[3]),
        celsius: millidegrees == null ? null : millidegrees / 1000,
        powerWatts: microwatts == null ? null : microwatts / 1e6,
      ),
    );
  }

  return ParseResult(
    GpuSnapshot(devices, nvidiaFailure: nvidiaFailure),
    warnings,
  );
}

/// One `nvidia-smi` CSV row; a name may itself hold commas, so the index
/// leads and the figures close the row.
GpuDevice? _nvidiaRow(String row) {
  final f = row.split(',').map((field) => field.trim()).toList();
  if (f.length < _nvidiaFigures + 2) return null;
  final index = int.tryParse(f.first);
  if (index == null) return null;

  final figures = f.sublist(f.length - _nvidiaFigures);
  final name = f.sublist(1, f.length - _nvidiaFigures).join(', ');
  double? figure(int i) => double.tryParse(figures[i]);
  int? mib(int i) => switch (figure(i)) {
    final value? => (value * _mib).round(),
    null => null,
  };
  return GpuDevice(
    id: 'nvidia$index',
    source: GpuSource.nvidia,
    name: name.isEmpty ? null : name,
    busyPercent: figure(0)?.clamp(0, 100).toDouble(),
    memoryUsedBytes: mib(1),
    memoryTotalBytes: mib(2),
    celsius: figure(3),
    powerWatts: figure(4),
    powerLimitWatts: figure(5),
  );
}
