// HW-04's drive health (03 §7.11): in admin mode, an elevated
// `smartctl --scan-open`, then `smartctl -n standby -a` for each drive
// it lists, each through the elevation executor, so a spun-down drive is
// never woken.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show ElevationException, RemoteCommandException;

import '../engine/protocol.dart';
import 'admin_mode.dart';

/// The most drives one read reads, one elevated command each, in scan
/// order [E]. The rest are counted in [SmartReport.notRead].
const kSmartDrivesRead = 32;

/// The exit status a shell gives a command it cannot find.
const _commandNotFound = 127;

/// Reads every drive's health on [serverId] through [session]. A probe
/// that found no smartctl in [profile] answers without running anything.
Future<SmartReport> readSmart(
  String serverId, {
  required String requestId,
  required AdminSession session,
  required HostProfile? profile,
}) async {
  SmartReport failed(SmartReportFailure failure) =>
      SmartReport(serverId: serverId, requestId: requestId, failure: failure);
  if (profile?.toolPresent('smartctl') == false) {
    return failed(SmartReportFailure.missing);
  }

  try {
    final scan = await session.executor.run(
      HostCommands.smartScan(),
      password: session.password,
    );
    if (scan.exitCode == _commandNotFound ||
        scan.stderr.contains('command not found')) {
      return failed(SmartReportFailure.missing);
    }
    final drives = parseSmartScan(scan.stdout);
    if (drives == null) return failed(SmartReportFailure.unreadable);

    final read = drives.take(kSmartDrivesRead).toList();
    final disks = <SmartDisk>[];
    for (final drive in read) {
      final List<String> argv;
      try {
        argv = HostCommands.smartRead(drive.device, drive.type);
      } on HostCommandError {
        // A name or type the scan should never print: not read.
        disks.add(
          SmartDisk(device: drive.device, verdict: SmartVerdict.unknown),
        );
        continue;
      }
      final result = await session.executor.run(
        argv,
        password: session.password,
      );
      disks.add(parseSmartDisk(result.stdout, device: drive.device));
    }
    return SmartReport(
      serverId: serverId,
      requestId: requestId,
      disks: disks,
      notRead: drives.length - read.length,
    );
  } on ElevationException {
    return failed(SmartReportFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(SmartReportFailure.transport);
  }
}
