// The package check (03 §7.8, PKG-01 to PKG-03): pending updates,
// security flags and the reboot flag, read as the login user from the
// package manager's cached metadata, and kept per server for an hour so
// the System tab and the fleet's update counts share one check.
import 'dart:async';

import 'package:klabautermann_host/klabautermann_host.dart'
    show HostCommands, parsePackageCheck;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, SshLink, quoteShellWord;

import '../engine/protocol.dart';

/// How long a check's answer stands before a read checks again (03 §6.1's
/// `packages` cadence).
const kPackagesKeptFor = Duration(minutes: 60);

/// The longest a check may run [E]: dnf and zypper read every repository's
/// cached metadata, which takes seconds on a large mirror set.
const _checkTimeout = Duration(seconds: 120);

/// The most output a check reads: apt prints a few lines per update.
const _checkOutputBytes = 1024 * 1024;

/// Runs the package check on [link]; never throws.
Future<PackagesReport> readPackages(
  String serverId, {
  required String requestId,
  required SshLink link,
  required DateTime Function() now,
}) async {
  try {
    final result = await link.run(
      HostCommands.commandLine(
        HostCommands.packageCheck(),
        quote: quoteShellWord,
      ),
      timeout: _checkTimeout,
      maxOutputBytes: _checkOutputBytes,
      stdin: const [],
    );
    return PackagesReport(
      serverId: serverId,
      requestId: requestId,
      check: parsePackageCheck(result.stdout),
      checkedAt: now(),
    );
  } on RemoteCommandException {
    return PackagesReport(
      serverId: serverId,
      requestId: requestId,
      failure: PackagesReportFailure.transport,
    );
  } on TimeoutException {
    return PackagesReport(
      serverId: serverId,
      requestId: requestId,
      failure: PackagesReportFailure.transport,
    );
  }
}

/// Each server's latest check, and the check in flight, so concurrent
/// reads share one run. Owned by the engine isolate.
final class PackageReports {
  PackageReports({required this._now});

  final DateTime Function() _now;
  final _latest = <String, PackagesReport>{};
  final _running = <String, Future<PackagesReport>>{};

  /// Bumped per server by [forget], so a check that was running then is
  /// answered but not kept.
  final _generations = <String, int>{};

  /// [serverId]'s report for [requestId]: the kept one while it stands
  /// and [fresh] is false, else the one [check] produces. A report that
  /// carries no check (the link failed) is never kept.
  Future<PackagesReport> read(
    String serverId, {
    required String requestId,
    required bool fresh,
    required Future<PackagesReport> Function() check,
  }) async {
    final kept = _latest[serverId];
    final keptAt = kept?.checkedAt;
    if (!fresh &&
        kept != null &&
        keptAt != null &&
        _now().difference(keptAt) < kPackagesKeptFor) {
      return _answer(kept, requestId);
    }

    final generation = _generations[serverId] ?? 0;
    // The block body matters: `remove` returns this very future, which
    // `whenComplete` would otherwise wait on.
    final running = _running[serverId] ??= check().whenComplete(() {
      _running.remove(serverId);
    });
    final report = await running;
    if (report.check != null && (_generations[serverId] ?? 0) == generation) {
      _latest[serverId] = report;
    }
    return _answer(report, requestId);
  }

  /// Drops the kept reports of [serverIds], as when they leave the fleet
  /// or change endpoint.
  void forget(Set<String> serverIds) {
    _latest.removeWhere((id, _) => serverIds.contains(id));
    for (final id in serverIds) {
      _generations[id] = (_generations[id] ?? 0) + 1;
    }
  }

  static PackagesReport _answer(PackagesReport report, String requestId) =>
      PackagesReport(
        serverId: report.serverId,
        requestId: requestId,
        check: report.check,
        checkedAt: report.checkedAt,
        failure: report.failure,
      );
}
