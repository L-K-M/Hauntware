import 'package:flutter/foundation.dart';

import 'fleet_controller.dart';

/// What the fleet header's chip and the coverage sheet count (03 §9.5 item
/// 2): the servers in the fleet, and how many of them this device watches.
@immutable
final class FleetCoverage {
  const FleetCoverage({required this.serverCount, required this.watchedCount})
    : assert(0 <= watchedCount && watchedCount <= serverCount);

  /// The coverage of [servers]. A server is watched when FL-21's
  /// [monitorSet] lists it: it is then sampled continuously while the app
  /// is open, the others only while a view has them open. Ids the fleet
  /// does not list count for nothing.
  factory FleetCoverage.of(
    List<FleetServer> servers, {
    Set<String> monitorSet = const {},
  }) => FleetCoverage(
    serverCount: servers.length,
    watchedCount: servers
        .where((server) => monitorSet.contains(server.id))
        .length,
  );

  final int serverCount;
  final int watchedCount;
}

/// The coverage concern's device state (03 §9.5 item 1): whether the
/// first-run card still shows. The composition root restores it from
/// `settings.json` and saves the dismissal there; without a save callback,
/// as in most tests, it is held in memory only.
final class CoverageController extends ChangeNotifier {
  CoverageController({bool firstRunCardDismissed = false, this._saveDismissal})
    : _dismissed = firstRunCardDismissed;

  bool _dismissed;
  final Future<void> Function()? _saveDismissal;

  bool get showsFirstRunCard => !_dismissed;

  /// Hides the first-run card, at once, and saves that it was dismissed.
  /// A save that fails rethrows, and the card stays hidden until the app
  /// restarts, so the caller can say it was not kept. A no-op once
  /// dismissed.
  Future<void> dismissFirstRunCard() async {
    if (_dismissed) return;
    _dismissed = true;
    notifyListeners();
    await _saveDismissal?.call();
  }
}
