/// Parsers for smartctl's JSON (smartmontools 7.0+, 03 §7.11, HW-04):
/// `--scan-open` for the drives, `-n standby -a` for one drive's health.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

/// One drive `smartctl --scan-open -j` lists.
@immutable
final class SmartScanEntry {
  const SmartScanEntry({required this.device, required this.type});

  /// The device node, such as `/dev/sda`.
  final String device;

  /// The `-d` type smartctl would read it as, such as `sat` or `nvme`.
  final String type;
}

/// The drives in `smartctl --scan-open -j` output, or null when it is
/// not that JSON.
List<SmartScanEntry>? parseSmartScan(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  if (decoded is! Map || decoded['devices'] is! List) return null;
  return [
    for (final device in decoded['devices'] as List)
      if (device case {'name': final String name, 'type': final String type})
        SmartScanEntry(device: name, type: type),
  ];
}

/// A drive's health as HW-04 words it.
enum SmartVerdict {
  /// The drive's own assessment passed and nothing below says otherwise.
  passed,

  /// The assessment passed, but a sign of wear or damage is there:
  /// reallocated or pending sectors, a prefailure attribute at its
  /// threshold, failed self-tests, an NVMe critical warning, or the NVMe
  /// endurance estimate used up.
  warning,

  /// The drive's own assessment failed.
  failing,

  /// The drive was spun down and was left asleep (`-n standby`).
  asleep,

  /// smartctl could not tell, as for a drive without SMART.
  unknown,
}

/// smartctl's exit status bits (smartctl(8) "RETURN VALUES").
const _exitOpenFailed = 2;
const _exitDiskFailing = 8;
const _exitPrefailBelowThreshold = 16;
const _exitSelfTestErrors = 128;

/// The ATA attributes whose raw counts mark damaged sectors.
const _reallocatedSectors = 5;
const _pendingSectors = 197;
const _offlineUncorrectable = 198;

/// One drive's health (HW-04). A figure the drive does not report is
/// null.
@immutable
final class SmartDisk {
  const SmartDisk({
    required this.device,
    required this.verdict,
    this.model,
    this.celsius,
    this.powerOnHours,
    this.percentageUsed,
    this.badSectors,
  });

  final String device;
  final SmartVerdict verdict;
  final String? model;
  final int? celsius;
  final int? powerOnHours;

  /// NVMe's endurance estimate, which may pass 100.
  final int? percentageUsed;

  /// The ATA reallocated, pending and offline-uncorrectable sector
  /// counts, summed.
  final int? badSectors;

  Map<String, Object?> toJson() => {
    'device': device,
    'verdict': verdict.name,
    'model': ?model,
    'celsius': ?celsius,
    'powerOnHours': ?powerOnHours,
    'percentageUsed': ?percentageUsed,
    'badSectors': ?badSectors,
  };
}

/// [device]'s health from `smartctl -n standby -a -j`; never throws. Any
/// output that is not smartctl's JSON reads as [SmartVerdict.unknown].
SmartDisk parseSmartDisk(String raw, {required String device}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return SmartDisk(device: device, verdict: SmartVerdict.unknown);
  }
  if (decoded is! Map) {
    return SmartDisk(device: device, verdict: SmartVerdict.unknown);
  }

  final exit = switch (decoded['smartctl']) {
    {'exit_status': final int status} => status,
    _ => 0,
  };
  final messages = switch (decoded['smartctl']) {
    {'messages': final List list} => [
      for (final m in list)
        if (m case {'string': final String text}) text.toUpperCase(),
    ],
    _ => const <String>[],
  };
  final model = decoded['model_name'] is String
      ? decoded['model_name'] as String
      : null;
  final nvme = decoded['nvme_smart_health_information_log'];
  final percentageUsed = nvme is Map ? _int(nvme['percentage_used']) : null;
  final celsius = switch (decoded['temperature']) {
    {'current': final Object? current} => _int(current),
    _ => nvme is Map ? _int(nvme['temperature']) : null,
  };
  final powerOnHours = switch (decoded['power_on_time']) {
    {'hours': final Object? hours} => _int(hours),
    _ => nvme is Map ? _int(nvme['power_on_hours']) : null,
  };
  final badSectors = _badSectors(decoded['ata_smart_attributes']);

  final asleep =
      exit & _exitOpenFailed != 0 &&
      messages.any((m) => m.contains('STANDBY') || m.contains('SLEEP'));
  final passed = switch (decoded['smart_status']) {
    {'passed': final bool passed} => passed,
    _ => null,
  };
  final worn =
      exit & (_exitPrefailBelowThreshold | _exitSelfTestErrors) != 0 ||
      (badSectors ?? 0) > 0 ||
      (nvme is Map && (_int(nvme['critical_warning']) ?? 0) != 0) ||
      (percentageUsed ?? 0) >= 100;
  final verdict = asleep
      ? SmartVerdict.asleep
      : passed == false || exit & _exitDiskFailing != 0
      ? SmartVerdict.failing
      : passed == true && worn
      ? SmartVerdict.warning
      : passed == true
      ? SmartVerdict.passed
      : SmartVerdict.unknown;

  return SmartDisk(
    device: device,
    verdict: verdict,
    model: model,
    celsius: celsius,
    powerOnHours: powerOnHours,
    percentageUsed: percentageUsed,
    badSectors: badSectors,
  );
}

int? _int(Object? value) => value is int ? value : null;

/// The summed raw counts of the damaged-sector attributes, or null when
/// the drive reports none of them.
int? _badSectors(Object? attributes) {
  if (attributes is! Map || attributes['table'] is! List) return null;
  int? total;
  for (final row in attributes['table'] as List) {
    if (row case {'id': final int id, 'raw': {'value': final int raw}}
        when id == _reallocatedSectors ||
            id == _pendingSectors ||
            id == _offlineUncorrectable) {
      total = (total ?? 0) + raw;
    }
  }
  return total;
}
