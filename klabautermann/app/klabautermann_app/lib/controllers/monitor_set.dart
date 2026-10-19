import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show MonitorEligibility, kMonitorSetLimit;

/// What FL-21's monitor set holds before the user chooses one on this
/// device (03 §4.3 step 4).
enum MonitorSetDefault {
  /// Desktops: every eligible server, the first [kMonitorSetLimit] in
  /// fleet order.
  allEligible,

  /// Phones: none, so a launch on a phone never fans out to the fleet.
  none,
}

/// The default for [platform]: all eligible on desktops, none on phones.
MonitorSetDefault monitorSetDefaultFor(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => MonitorSetDefault.allEligible,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => MonitorSetDefault.none,
    };

/// The monitor set in force: of [eligible], the eligible fleet servers in
/// fleet order, those [chosen] names, or the [fallback] while the user has
/// chosen none ([chosen] null). Never more than [kMonitorSetLimit], and
/// never a server that left the fleet or stopped being eligible, though
/// [chosen] may still name it until the next save.
Set<String> monitorSetInForce({
  required List<String> eligible,
  required Set<String>? chosen,
  required MonitorSetDefault fallback,
}) {
  final members = switch ((chosen, fallback)) {
    (final chosen?, _) => eligible.where(chosen.contains),
    (null, MonitorSetDefault.allEligible) => eligible,
    (null, MonitorSetDefault.none) => const <String>[],
  };
  return Set.unmodifiable(members.take(kMonitorSetLimit));
}

/// The eligibility called [name], as the settings link carries it; an
/// unknown name throws, since both ends of the link are the same build.
MonitorEligibility monitorEligibilityNamed(String name) =>
    MonitorEligibility.values.byName(name);

/// One fleet server as Settings > Servers lists it for the monitor set.
@immutable
final class MonitorCandidate {
  const MonitorCandidate({
    required this.serverId,
    required this.label,
    required this.eligibility,
    required this.monitored,
  });

  final String serverId;
  final String label;
  final MonitorEligibility eligibility;

  /// Whether the monitor set in force holds it.
  final bool monitored;

  @override
  bool operator ==(Object other) =>
      other is MonitorCandidate &&
      serverId == other.serverId &&
      label == other.label &&
      eligibility == other.eligibility &&
      monitored == other.monitored;

  @override
  int get hashCode => Object.hash(serverId, label, eligibility, monitored);
}

/// What Settings reads and changes of the monitor set, apart from where it
/// runs: the fleet controller in the app, and a copy kept over the
/// settings link in the desktop settings window. [value] lists the fleet's
/// servers in fleet order.
abstract interface class MonitorSetSettings
    implements ValueListenable<List<MonitorCandidate>> {
  /// Adds [serverId] to the monitor set or takes it out; a no-op when it
  /// already is or is not. Throws [MonitorSetFullException] when the set
  /// holds [kMonitorSetLimit] servers, and [MonitorSetNotSavedException]
  /// when the change applied but was not saved; any other throw, an
  /// ineligible server's included, means it did not apply.
  Future<void> setMonitored(String serverId, {required bool monitored});
}

/// The monitor set already holds [kMonitorSetLimit] servers, so another
/// joins only once one leaves.
final class MonitorSetFullException implements Exception {
  const MonitorSetFullException();

  @override
  String toString() =>
      'The monitor set already holds $kMonitorSetLimit servers';
}

/// A monitor set change that applied but was not saved: it lasts until
/// the app restarts unless a later save carries it. [message] is what the
/// failed save printed.
final class MonitorSetNotSavedException implements Exception {
  const MonitorSetNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}
