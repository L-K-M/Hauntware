import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/operations_controller.dart';
import '../controllers/power_waits.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart';
import 'actions/action_preview.dart' show startAction;
import 'admin_mode_chip.dart' show AdminScope;
import 'system_panel.dart' show PanelSection;

/// The app's power waits for the widgets under it; the composition root
/// puts it above every route, and a test may leave it out, which starts
/// power actions without a wait after them.
class PowerWaitsScope extends InheritedNotifier<PowerWaits> {
  const PowerWaitsScope({
    super.key,
    required PowerWaits waits,
    required super.child,
  }) : super(notifier: waits);

  /// The waits for [context], which rebuilds when they change, or null
  /// when none are provided.
  static PowerWaits? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PowerWaitsScope>()?.notifier;
}

/// Starts [verb] on [serverId] through its preview and confirmation, and
/// the app-wide wait after it: the System tab's Power section and the
/// Overview's quick actions both start power actions here.
void startPowerAction(BuildContext context, String serverId, PowerVerb verb) {
  final waits = PowerWaitsScope.maybeOf(context);
  startAction(
    context,
    PowerAction(serverId, verb),
    onRun: (planId, _) => waits?.start(serverId, planId, verb),
  );
}

/// SYS-03's words for how long the wait has lasted: seconds for the
/// first two minutes, then minutes.
String _elapsed(AppLocalizations l10n, Duration elapsed) =>
    elapsed < const Duration(minutes: 2)
    ? l10n.systemClockSeconds(elapsed.inSeconds)
    : l10n.systemClockMinutes(elapsed.inMinutes);

/// What became of [serverId]'s power action once the host took it: the
/// wait for a rebooted server, its end, or a server shutting down. Empty
/// while the run goes on, unless [whileRunning] shows a bare progress bar
/// then, as the quick actions card does when it is shown for the wait
/// alone.
class PowerWaitProgress extends StatefulWidget {
  const PowerWaitProgress({
    super.key,
    required this.serverId,
    this.whileRunning = false,
  });

  final String serverId;
  final bool whileRunning;

  @override
  State<PowerWaitProgress> createState() => _PowerWaitProgressState();
}

class _PowerWaitProgressState extends State<PowerWaitProgress> {
  /// Ticks the waiting line's elapsed time while a reboot waits.
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _tick(bool on) {
    if (!on) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final waits = PowerWaitsScope.maybeOf(context);
    final wait = waits?.waitFor(widget.serverId);
    _tick(wait?.phase == PowerWaitPhase.waiting);
    if (waits == null || wait == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final elapsed = _elapsed(l10n, waits.elapsed(wait));
    final stop = TextButton(
      onPressed: () => waits.stop(widget.serverId),
      child: Text(l10n.systemPowerStopWaiting),
    );
    return switch (wait.phase) {
      PowerWaitPhase.running when widget.whileRunning =>
        const LinearProgressIndicator(),
      PowerWaitPhase.running => const SizedBox.shrink(),
      PowerWaitPhase.off => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [Text(l10n.systemPowerOff), stop],
      ),
      PowerWaitPhase.back => Text(
        l10n.systemPowerBack(_elapsed(l10n, wait.backAfter!)),
      ),
      PowerWaitPhase.notBack => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [Text(l10n.systemPowerNotBack(elapsed)), stop],
      ),
      PowerWaitPhase.waiting => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          const LinearProgressIndicator(),
          Text(l10n.systemPowerWaiting(elapsed)),
          stop,
        ],
      ),
    };
  }
}

/// SYS-03's section of the System tab: reboot and shut down, in admin
/// mode, each behind the host's own name typed in the preview. After a
/// reboot it shows the app-wide wait for the server to answer again
/// ([PowerWaits]), which a `core` reading of a later boot ends, and how
/// long that took.
class PowerSection extends StatelessWidget {
  const PowerSection({super.key, required this.serverId});

  final String serverId;

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
    final adminOn = admin?.stateFor(serverId)?.phase == AdminModePhase.on;
    final wait = PowerWaitsScope.maybeOf(context)?.waitFor(serverId);
    final run = wait == null ? null : operations?.runOf(wait.planId);
    // While the run goes, a second power action would race it, and a
    // reboot being waited for has not finished either.
    final busy =
        run is RunInProgress ||
        wait?.phase == PowerWaitPhase.waiting ||
        wait?.phase == PowerWaitPhase.off;

    return PanelSection(
      title: l10n.systemPowerTitle,
      children: [
        if (wait != null && wait.phase != PowerWaitPhase.running)
          PowerWaitProgress(serverId: serverId),
        if (!adminOn)
          Text(l10n.systemPowerAdminNeeded)
        else if (!busy)
          ActionEntry(
            serverId: serverId,
            point: ActionEntryPoint.power,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () =>
                      startPowerAction(context, serverId, PowerVerb.reboot),
                  child: Text(l10n.systemPowerReboot),
                ),
                OutlinedButton(
                  onPressed: () =>
                      startPowerAction(context, serverId, PowerVerb.poweroff),
                  child: Text(l10n.systemPowerShutDown),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
