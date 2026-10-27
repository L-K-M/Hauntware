import 'package:flutter/foundation.dart' show immutable;
import 'package:ghost_servers/ghost_servers.dart'
    show GhostProbeState, GhostSessionState;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart' show FleetServer;
import '../controllers/monitoring_controller.dart' show sampleAge;

/// The engine's link truth as the session state `ghost_servers`' indicator
/// resolves (03 §10.3, F4): a limited link is connected, a backoff is an
/// attempt in flight, waiting on the user or on a decision is blocked, and
/// a close is failed unless the engine closed the link on purpose with no
/// failure behind it (03 §10.1, version 3).
GhostSessionState ghostSessionOf(LinkStatus status) => switch (status) {
  LinkIdle() => GhostSessionState.none,
  LinkConnecting() ||
  LinkAuthenticating() ||
  LinkBackoff() => GhostSessionState.connecting,
  LinkReady() || LinkDegraded() => GhostSessionState.connected,
  LinkNeedsUser() || LinkBlocked() => GhostSessionState.blocked,
  LinkClosed(reason: LinkClosedReason.closedByOwner, failure: null) =>
    GhostSessionState.idle,
  LinkClosed() => GhostSessionState.failed,
};

/// The probe's answer as `ghost_servers` reads it (FL-04); null while the
/// engine has sent none, as for an endpoint it does not probe (03 §5.12).
GhostProbeState? ghostProbeOf(ReachabilityStatus? status) => switch (status) {
  null => null,
  ReachabilityStatus.online => GhostProbeState.online,
  ReachabilityStatus.offline => GhostProbeState.offline,
  ReachabilityStatus.unknown => GhostProbeState.unknown,
};

/// How old a reading of each stream may grow before its row shows it as
/// stale (OV-04): twice the stream's slowest cadence in 03 §6.4 (the
/// Cellular saver column), so the normal spacing of no cadence profile
/// reads as stale.
const Map<SampleStream, Duration> kFleetRowStaleAfter = {
  SampleStream.overview: Duration(seconds: 60),
  SampleStream.core: Duration(seconds: 20),
  SampleStream.fs: Duration(seconds: 240),
};

/// What a fleet row shows of one server's readings (FL-07): the CPU,
/// memory and disk shares of its pressure bar and how fresh they are.
@immutable
final class FleetRowReading {
  const FleetRowReading({
    required this.age,
    required this.stale,
    this.cpuPercent,
    this.memoryPercent,
    this.diskPercent,
  });

  /// How old the CPU and memory reading is (03 §9.5 item 4).
  final Duration age;

  /// Whether the values are the last ones before sampling stopped: the
  /// link is connecting, failed, blocked or closed, or the reading is
  /// older than [kFleetRowStaleAfter].
  final bool stale;

  /// Shares from 0 to 100; null when unknown, never zero (03 §10.4).
  final double? cpuPercent, memoryPercent, diskPercent;
}

/// The row's reading from the latest samples of a server's streams, or
/// null while the app holds no `overview` or `core` reading for it, which
/// is what makes a row monitored (03 §10.3): the row then shows
/// reachability only.
///
/// CPU and memory come from the newer of [overview] and [core], whichever
/// surface asked for it; the disk share is the root file system's from
/// [fs], unknown once that reading is stale itself. A link that is
/// connecting, failed, blocked or closed makes the reading stale at once
/// (03 §5.3's dead peer: "stale values turn grey"); no link status at all
/// leaves it to the age.
FleetRowReading? fleetRowReading({
  required Sample? overview,
  required Sample? core,
  required Sample? fs,
  required GhostSessionState session,
  required DateTime now,
}) {
  final metrics = switch ((overview, core)) {
    (null, null) => null,
    (final only?, null) || (null, final only?) => only,
    (final o?, final c?) => o.at.isAfter(c.at) ? o : c,
  };
  if (metrics == null) return null;

  final age = sampleAge(metrics.at, now)!;
  final linkDown = switch (session) {
    GhostSessionState.connected || GhostSessionState.none => false,
    _ => true,
  };
  final (cpu, memory) = switch (metrics.result) {
    OverviewResult(:final cpu, :final memory) ||
    CoreResult(:final cpu, :final memory) => (cpu, memory),
    _ => (null, null),
  };
  return FleetRowReading(
    age: age,
    stale: linkDown || age >= kFleetRowStaleAfter[metrics.stream]!,
    cpuPercent: cpu?.busy,
    memoryPercent: _share(memory?.usedBytes, memory?.totalBytes),
    diskPercent: _rootDiskPercent(fs, now),
  );
}

/// The root file system's use from a fresh `fs` reading: `df`'s capacity,
/// else used out of size; null when [fs] is missing, stale or reports no
/// root mount.
double? _rootDiskPercent(Sample? fs, DateTime now) {
  if (fs == null) return null;
  if (sampleAge(fs.at, now)! >= kFleetRowStaleAfter[SampleStream.fs]!) {
    return null;
  }
  if (fs.result case FsResult(:final fs)) {
    for (final mount in fs.mounts) {
      if (mount.mountPoint != '/') continue;
      return mount.capacityPercent?.toDouble() ??
          _share(mount.usedBytes, mount.sizeBytes);
    }
  }
  return null;
}

double? _share(int? part, int? whole) =>
    part == null || whole == null || whole <= 0 ? null : part / whole * 100;

/// Whether [server] matches the fleet filter's [query] (FL-05): each of
/// its whitespace-separated terms, case-folded, occurs somewhere in the
/// server's search text, the rule Séance's server list applies, so
/// `web eu` finds `prod-web-01.eu-west`. A blank query matches every
/// server. Without the engine's [FleetServer.searchText] (03 §3.2 keeps
/// its haystack function out of the app), the row's name and address
/// stand in.
bool fleetServerMatches(FleetServer server, String query) {
  final terms = query.toLowerCase().split(RegExp(r'\s+'))
    ..removeWhere((term) => term.isEmpty);
  if (terms.isEmpty) return true;

  final haystack =
      server.searchText ??
      '${server.displayName} ${server.address ?? ''}'.toLowerCase();
  return terms.every(haystack.contains);
}
