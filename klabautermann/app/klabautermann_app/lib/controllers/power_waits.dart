import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'fleet_controller.dart';
import 'operations_controller.dart';

/// How far `btime` may move between two readings of one boot: the kernel
/// derives it from the uptime and the wall clock, so it can step by a
/// second.
const _sameBoot = Duration(seconds: 2);

/// How long a reboot is waited for before the wait says the server has
/// not answered: long enough for a slow firmware check and a disk check
/// at boot. A later boot read after it still ends the wait.
const Duration kRebootWaitTimeout = Duration(minutes: 15);

/// How long a finished reboot's "answered again" line stays before its
/// wait leaves: long enough to read where it showed, short enough that it
/// does not follow the user around the app for the rest of the run.
const Duration kPowerWaitBackHold = Duration(seconds: 30);

/// Whether a reading is of a boot after the one the reboot started
/// from: its [bootedAt] unlike [before] where that boot was read,
/// otherwise its [uptime] shorter than the time [sinceStart] the reboot
/// was asked for. Both compare the server's readings with each other or
/// durations with durations, so a server clock that runs ahead of this
/// device's cannot pass for a new boot.
@visibleForTesting
bool isLaterBoot(
  DateTime bootedAt, {
  required DateTime? before,
  required Duration? uptime,
  required Duration sinceStart,
}) => before == null
    // The same margin as btime's, for a reading a little older than now.
    ? uptime != null && uptime < sinceStart - _sameBoot
    : bootedAt.difference(before).abs() > _sameBoot;

/// Where one server's power action stands (SYS-03).
enum PowerWaitPhase {
  /// The run goes on; the host has not taken it yet.
  running,

  /// The host took the reboot; the server has not answered on a later
  /// boot yet.
  waiting,

  /// The reboot has been waited for [kRebootWaitTimeout] without a later
  /// boot; one read after this still ends the wait.
  notBack,

  /// The server answered again on a later boot, [PowerWait.backAfter]
  /// after the reboot was asked for.
  back,

  /// The host took the shutdown; the server stays off.
  off,
}

/// One server's power action and the wait after it.
@immutable
final class PowerWait {
  const PowerWait({
    required this.planId,
    required this.verb,
    required this.startedAt,
    required this.bootBefore,
    this.phase = PowerWaitPhase.running,
    this.backAfter,
  });

  /// The run that asked for it, and what it asked for.
  final String planId;
  final PowerVerb verb;

  /// When the run started on this device's clock, and the boot the
  /// server was on then, if a reading said.
  final DateTime startedAt;
  final DateTime? bootBefore;

  final PowerWaitPhase phase;

  /// How long the server took to answer after the reboot, once it did.
  final Duration? backAfter;

  /// Whether a reboot is still waited for: running, or taken and not yet
  /// back. The Overview keeps its quick actions card for it after admin
  /// mode ends (Q1), until the server is back or the wait times out
  /// ([PowerWaitPhase.notBack] is no longer pending).
  bool get rebootPending =>
      verb == PowerVerb.reboot &&
      (phase == PowerWaitPhase.running || phase == PowerWaitPhase.waiting);

  PowerWait _to(PowerWaitPhase phase, {Duration? backAfter}) => PowerWait(
    planId: planId,
    verb: verb,
    startedAt: startedAt,
    bootBefore: bootBefore,
    phase: phase,
    backAfter: backAfter,
  );
}

/// The app's power actions and the waits after them, by server id
/// (SYS-03): one for the run, so a wait outlasts the System tab, the
/// Overview's quick actions and admin mode, which a reboot ends as the
/// link drops. The System tab's Power section and the quick actions card
/// both start and show waits here.
///
/// A wait follows its run through [operations] and the server's boots
/// through `core`'s readings, which it listens to until the server is
/// back or the wait is stopped.
final class PowerWaits extends ChangeNotifier {
  PowerWaits({
    required this._core,
    this.operations,
    this.fleet,
    this._now = DateTime.now,
    this._timeout = kRebootWaitTimeout,
  }) {
    operations?.addListener(_onRuns);
    fleet?.addListener(_onFleet);
  }

  final ValueListenable<Sample?> Function(String serverId) _core;
  final DateTime Function() _now;
  final Duration _timeout;

  /// The runs' ends; without it, as in some tests, a wait stays running.
  final OperationsController? operations;

  /// The fleet's changes: a server that leaves takes its readings with
  /// it, disposed, so a wait still listening to them would never see the
  /// server's next boot and would end as "not answered" while it is up.
  /// Such waits go with the server instead.
  final FleetController? fleet;

  final Map<String, PowerWait> _waits = {};
  final Map<String, _Follow> _follows = {};

  /// The timers that end a finished reboot's short hold.
  final Map<String, Timer> _holds = {};

  /// [serverId]'s power action and its wait, or null without one.
  PowerWait? waitFor(String serverId) => _waits[serverId];

  /// How long [wait] has lasted on this device's clock.
  Duration elapsed(PowerWait wait) => _now().difference(wait.startedAt);

  /// Follows run [planId], which asks [serverId] for [verb], in place of
  /// any earlier wait there.
  void start(String serverId, String planId, PowerVerb verb) {
    _stopFollowing(serverId);
    _cancelHold(serverId);
    final core = _core(serverId);
    _waits[serverId] = PowerWait(
      planId: planId,
      verb: verb,
      startedAt: _now(),
      bootBefore: _bootedAt(core.value),
    );
    void onCore() => _onCore(serverId);
    core.addListener(onCore);
    _follows[serverId] = _Follow(core, onCore);
    // The run can have ended before the wait began.
    _onRuns();
    notifyListeners();
  }

  /// Drops [serverId]'s wait, as Stop waiting does.
  void stop(String serverId) {
    _stopFollowing(serverId);
    _cancelHold(serverId);
    if (_waits.remove(serverId) != null) notifyListeners();
  }

  void _stopFollowing(String serverId) => _follows.remove(serverId)?.cancel();

  /// Drops the waits of servers the fleet no longer lists. Until the
  /// engine's first fleet, [FleetController.servers] is only a seed, so
  /// absence there is not a departure.
  void _onFleet() {
    final fleet = this.fleet;
    if (fleet == null || !fleet.heardFleet) return;
    var changed = false;
    for (final entry in _waits.entries.toList()) {
      if (fleet.servers.any((server) => server.id == entry.key)) continue;
      _stopFollowing(entry.key);
      _cancelHold(entry.key);
      _waits.remove(entry.key);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _cancelHold(String serverId) => _holds.remove(serverId)?.cancel();

  /// Ends the wait once its answer has been readable for
  /// [kPowerWaitBackHold]. A later power action starts a new wait, so
  /// only a wait still in [PowerWaitPhase.back] goes.
  void _holdBack(String serverId) {
    _holds[serverId] = Timer(kPowerWaitBackHold, () {
      _holds.remove(serverId);
      if (_waits[serverId]?.phase != PowerWaitPhase.back) return;
      _waits.remove(serverId);
      notifyListeners();
    });
  }

  static DateTime? _bootedAt(Sample? sample) => switch (sample?.result) {
    final CoreResult core => core.bootedAt,
    _ => null,
  };

  static Duration? _uptime(Sample? sample) => switch (sample?.result) {
    final CoreResult core => core.uptime,
    _ => null,
  };

  void _onRuns() {
    final operations = this.operations;
    if (operations == null) return;
    var changed = false;
    for (final MapEntry(key: serverId, value: wait)
        in _waits.entries.toList()) {
      if (wait.phase != PowerWaitPhase.running) continue;
      switch (operations.runOf(wait.planId)) {
        case RunFinished(:final finished)
            when finished.outcome == ActionOutcome.succeeded:
          _onTaken(serverId, wait);
        // A run the host did not take leaves no wait.
        case RunFinished() || RunRefused():
          _stopFollowing(serverId);
          _cancelHold(serverId);
          _waits.remove(serverId);
        case RunInProgress() || null:
          continue;
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// The host took [wait]'s run: a reboot is waited for, unless a later
  /// boot was already read, and a shutdown says the server stays off,
  /// unless it is already up again.
  void _onTaken(String serverId, PowerWait wait) {
    final backAfter = wait.backAfter;
    if (backAfter == null) {
      // The timeout counts from the host taking the reboot, not from the
      // request: a run that queued behind slower actions still gets its
      // full span before the wait says the server has not answered.
      if (wait.verb == PowerVerb.reboot) {
        _follows[serverId]?.armTimeout(_timeout, () => _onTimeout(serverId));
      }
      _waits[serverId] = wait._to(
        wait.verb == PowerVerb.reboot
            ? PowerWaitPhase.waiting
            : PowerWaitPhase.off,
      );
      return;
    }
    if (wait.verb == PowerVerb.reboot) {
      _stopFollowing(serverId);
      _waits[serverId] = wait._to(PowerWaitPhase.back, backAfter: backAfter);
      _holdBack(serverId);
      return;
    }
    _waits.remove(serverId);
  }

  void _onCore(String serverId) {
    final wait = _waits[serverId];
    final follow = _follows[serverId];
    if (wait == null || follow == null) return;
    final sample = follow.core.value;
    final booted = _bootedAt(sample);
    final sinceStart = _now().difference(wait.startedAt);
    if (booted == null ||
        !isLaterBoot(
          booted,
          before: wait.bootBefore,
          uptime: _uptime(sample),
          sinceStart: sinceStart,
        )) {
      return;
    }
    _stopFollowing(serverId);
    switch (wait.phase) {
      // A server that was shut down and is up again on a later boot has
      // nothing left to say about it.
      case PowerWaitPhase.off:
        _waits.remove(serverId);
      case PowerWaitPhase.waiting || PowerWaitPhase.notBack:
        _waits[serverId] = wait._to(PowerWaitPhase.back, backAfter: sinceStart);
        _holdBack(serverId);
      // A later boot before the host's answer: the run is what says the
      // action was taken, so the wait ends as soon as it does.
      case PowerWaitPhase.running:
        _waits[serverId] = wait._to(
          PowerWaitPhase.running,
          backAfter: sinceStart,
        );
        return;
      case PowerWaitPhase.back:
        return;
    }
    notifyListeners();
  }

  void _onTimeout(String serverId) {
    final wait = _waits[serverId];
    if (wait == null || wait.phase != PowerWaitPhase.waiting) return;
    _waits[serverId] = wait._to(PowerWaitPhase.notBack);
    notifyListeners();
  }

  @override
  void dispose() {
    operations?.removeListener(_onRuns);
    fleet?.removeListener(_onFleet);
    for (final follow in _follows.values) {
      follow.cancel();
    }
    _follows.clear();
    for (final hold in _holds.values) {
      hold.cancel();
    }
    _holds.clear();
    super.dispose();
  }
}

/// What a wait listens to: its server's `core` readings, and the timer
/// that says it has not come back in time.
final class _Follow {
  _Follow(this.core, this.onCore);

  final ValueListenable<Sample?> core;
  final VoidCallback onCore;
  Timer? timeout;

  void armTimeout(Duration after, void Function() onTimeout) {
    timeout?.cancel();
    timeout = Timer(after, onTimeout);
  }

  void cancel() {
    try {
      core.removeListener(onCore);
    } on FlutterError {
      // The monitoring controller disposed these readings first: the
      // listener goes with the notifier, which nothing retains now.
    }
    timeout?.cancel();
  }
}
