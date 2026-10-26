import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/operations_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart';
import 'actions/action_preview.dart' show startAction;
import 'admin_mode_chip.dart' show AdminScope;
import 'system_panel.dart' show PanelSection;

/// How far `btime` may move between two readings of one boot: the kernel
/// derives it from the uptime and the wall clock, so it can step by a
/// second.
const _sameBoot = Duration(seconds: 2);

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
    ? uptime != null && uptime < sinceStart
    : bootedAt.difference(before).abs() > _sameBoot;

/// SYS-03's words for how long the wait has lasted: seconds for the
/// first two minutes, then minutes.
String _elapsed(AppLocalizations l10n, Duration elapsed) =>
    elapsed < const Duration(minutes: 2)
    ? l10n.systemClockSeconds(elapsed.inSeconds)
    : l10n.systemClockMinutes(elapsed.inMinutes);

/// SYS-03's section of the System tab: reboot and shut down, in admin
/// mode, each behind the host's own name typed in the preview. After a
/// reboot it waits for the server to answer again, which a `core`
/// reading of a later boot shows, and says how long that took.
class PowerSection extends StatefulWidget {
  const PowerSection({
    super.key,
    required this.serverId,
    required this.core,
    this.now = DateTime.now,
  });

  final String serverId;

  /// The server's `core` stream, whose `btime` tells one boot from the
  /// next.
  final ValueListenable<Sample?> core;

  /// This device's clock, which a test sets.
  final DateTime Function() now;

  @override
  State<PowerSection> createState() => _PowerSectionState();
}

class _PowerSectionState extends State<PowerSection> {
  /// The run this section started, and what it asked for.
  String? _planId;
  PowerVerb? _verb;

  /// When the run started, and the boot the server was on then.
  DateTime? _startedAt;
  DateTime? _bootBefore;

  /// How long the server took to answer after the reboot, once it did.
  Duration? _backAfter;

  /// Ticks the waiting line's elapsed time while a reboot waits.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.core.addListener(_onCore);
  }

  @override
  void didUpdateWidget(PowerSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.core != widget.core) {
      oldWidget.core.removeListener(_onCore);
      widget.core.addListener(_onCore);
    }
    if (oldWidget.serverId != widget.serverId) _reset();
  }

  @override
  void dispose() {
    widget.core.removeListener(_onCore);
    _ticker?.cancel();
    super.dispose();
  }

  void _reset() {
    _ticker?.cancel();
    _ticker = null;
    _planId = null;
    _verb = null;
    _startedAt = null;
    _bootBefore = null;
    _backAfter = null;
  }

  void _start(PowerVerb verb) {
    startAction(
      context,
      PowerAction(widget.serverId, verb),
      onRun: (planId, _) {
        // The preview can outlast the section, as when the server leaves
        // the fleet behind it.
        if (!mounted) return;
        setState(() {
          _reset();
          _planId = planId;
          _verb = verb;
          _startedAt = widget.now();
          _bootBefore = _bootedAt(widget.core.value);
          if (verb == PowerVerb.reboot) {
            _ticker = Timer.periodic(
              const Duration(seconds: 1),
              (_) => setState(() {}),
            );
          }
        });
      },
    );
  }

  static DateTime? _bootedAt(Sample? sample) => switch (sample?.result) {
    final CoreResult core => core.bootedAt,
    _ => null,
  };

  static Duration? _uptime(Sample? sample) => switch (sample?.result) {
    final CoreResult core => core.uptime,
    _ => null,
  };

  void _onCore() {
    final startedAt = _startedAt;
    if (_verb != PowerVerb.reboot || startedAt == null || _backAfter != null) {
      return;
    }
    final booted = _bootedAt(widget.core.value);
    if (booted == null ||
        !isLaterBoot(
          booted,
          before: _bootBefore,
          uptime: _uptime(widget.core.value),
          sinceStart: widget.now().difference(startedAt),
        )) {
      return;
    }
    _ticker?.cancel();
    _ticker = null;
    setState(() => _backAfter = widget.now().difference(startedAt));
  }

  @override
  Widget build(BuildContext context) {
    // The run's end comes through the operations controller, which its
    // scope does not rebuild on.
    final operations = OperationsScope.maybeOf(context);
    if (operations == null) return _section(context, null);
    return ListenableBuilder(
      listenable: operations,
      builder: (context, _) => _section(context, operations),
    );
  }

  Widget _section(BuildContext context, OperationsController? operations) {
    final l10n = AppLocalizations.of(context);
    final admin = AdminScope.maybeOf(context);
    final adminOn =
        admin?.stateFor(widget.serverId)?.phase == AdminModePhase.on;
    final planId = _planId;
    final run = planId == null ? null : operations?.runOf(planId);
    final taken = switch (run) {
      RunFinished(:final finished) =>
        finished.outcome == ActionOutcome.succeeded,
      _ => false,
    };
    // A run that ended without the host taking it shows no wait, so its
    // clock stops.
    if (run is RunFinished && !taken) {
      _ticker?.cancel();
      _ticker = null;
    }

    return PanelSection(
      title: l10n.systemPowerTitle,
      children: [
        if (taken) ?_progress(l10n),
        if (!adminOn)
          Text(l10n.systemPowerAdminNeeded)
        else if (!taken || _backAfter != null)
          ActionEntry(
            serverId: widget.serverId,
            point: ActionEntryPoint.power,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => _start(PowerVerb.reboot),
                  child: Text(l10n.systemPowerReboot),
                ),
                OutlinedButton(
                  onPressed: () => _start(PowerVerb.poweroff),
                  child: Text(l10n.systemPowerShutDown),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// What became of the power action the host took: the wait for a
  /// rebooted server, its end, or a server shutting down.
  Widget? _progress(AppLocalizations l10n) {
    final startedAt = _startedAt;
    if (startedAt == null) return null;
    if (_verb == PowerVerb.poweroff) return Text(l10n.systemPowerOff);
    if (_backAfter case final back?) {
      return Text(l10n.systemPowerBack(_elapsed(l10n, back)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        const LinearProgressIndicator(),
        Text(
          l10n.systemPowerWaiting(
            _elapsed(l10n, widget.now().difference(startedAt)),
          ),
        ),
        TextButton(
          onPressed: () => setState(_reset),
          child: Text(l10n.systemPowerStopWaiting),
        ),
      ],
    );
  }
}
