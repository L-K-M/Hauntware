import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show SidebarMenuAction, SidebarMenuEntry, SidebarMenuSubmenu;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import 'action_entry.dart';
import 'action_preview.dart';

/// The signals offered first, each a top-level verb so the keyboard
/// reaches them (the table's row menu cannot focus a submenu yet).
const _firstSignals = [KillSignal.sigterm, KillSignal.sigkill];

String _signalLabel(AppLocalizations l10n, KillSignal signal) =>
    switch (signal) {
      KillSignal.sigterm => l10n.processTerminate,
      KillSignal.sigkill => l10n.processKill,
      _ => l10n.processSignalName(signal.wireName),
    };

/// [row]'s PRC-02 verbs for the Processes table's row menu: Terminate and
/// Kill, then every other signal in a submenu. None where actions are not
/// allowed, or for a row without its start time, which the guarded kill
/// needs (03 §7.2).
List<SidebarMenuEntry> processActionEntries(
  BuildContext context, {
  required String serverId,
  required ProcessRow row,
}) {
  final ticks = row.startTicks;
  if (ticks == null ||
      !actionsAllowedAt(context, serverId, ActionEntryPoint.processSignal)) {
    return const [];
  }
  final l10n = AppLocalizations.of(context);
  SidebarMenuAction send(KillSignal signal) => SidebarMenuAction(
    label: _signalLabel(l10n, signal),
    onSelected: () => startAction(
      context,
      KillProcess(serverId, pid: row.pid, startTicks: ticks, signal: signal),
    ),
  );
  return [
    for (final signal in _firstSignals) send(signal),
    SidebarMenuSubmenu(
      label: l10n.processSendSignal,
      children: [
        for (final signal in KillSignal.values)
          if (!_firstSignals.contains(signal)) send(signal),
      ],
    ),
  ];
}

/// The same verbs as buttons in a process's details, which phones reach
/// by tapping a row (no destructive swipes, 48 dp targets).
class ProcessActionButtons extends StatelessWidget {
  const ProcessActionButtons({
    super.key,
    required this.serverId,
    required this.row,
  });

  final String serverId;
  final ProcessRow row;

  @override
  Widget build(BuildContext context) {
    final ticks = row.startTicks;
    if (ticks == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    void send(KillSignal signal) => startAction(
      context,
      KillProcess(serverId, pid: row.pid, startTicks: ticks, signal: signal),
    );
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.processSignal,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final signal in _firstSignals)
            OutlinedButton(
              onPressed: () => send(signal),
              child: Text(_signalLabel(l10n, signal)),
            ),
          MenuAnchor(
            menuChildren: [
              for (final signal in KillSignal.values)
                if (!_firstSignals.contains(signal))
                  MenuItemButton(
                    onPressed: () => send(signal),
                    child: Text(_signalLabel(l10n, signal)),
                  ),
            ],
            builder: (context, controller, _) => OutlinedButton.icon(
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.arrow_drop_down),
              label: Text(l10n.processSendSignal),
            ),
          ),
        ],
      ),
    );
  }
}

/// SVC-03's verbs, in the order the unit page and row menu offer them.
const _unitVerbs = [
  SystemctlVerb.start,
  SystemctlVerb.stop,
  SystemctlVerb.restart,
  SystemctlVerb.reload,
];

String _verbLabel(AppLocalizations l10n, SystemctlVerb verb) => switch (verb) {
  SystemctlVerb.start => l10n.unitStart,
  SystemctlVerb.stop => l10n.unitStop,
  SystemctlVerb.restart => l10n.unitRestart,
  SystemctlVerb.reload => l10n.unitReload,
  _ => verb.name,
};

/// [unit]'s SVC-03 verbs for the Services table's row menu, or none where
/// actions are not allowed.
List<SidebarMenuEntry> unitActionEntries(
  BuildContext context, {
  required String serverId,
  required String unit,
}) {
  if (!actionsAllowedAt(context, serverId, ActionEntryPoint.unitVerb)) {
    return const [];
  }
  final l10n = AppLocalizations.of(context);
  return [
    for (final verb in _unitVerbs)
      SidebarMenuAction(
        label: _verbLabel(l10n, verb),
        onSelected: () =>
            startAction(context, UnitAction(serverId, unit: unit, verb: verb)),
      ),
  ];
}

/// The same verbs as buttons on a unit's page.
class UnitActionButtons extends StatelessWidget {
  const UnitActionButtons({
    super.key,
    required this.serverId,
    required this.unit,
  });

  final String serverId;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ActionEntry(
      serverId: serverId,
      point: ActionEntryPoint.unitVerb,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final verb in _unitVerbs)
            OutlinedButton(
              onPressed: () => startAction(
                context,
                UnitAction(serverId, unit: unit, verb: verb),
              ),
              child: Text(_verbLabel(l10n, verb)),
            ),
        ],
      ),
    );
  }
}

/// A cron line's JOB-19 verb as a button in its details. [onRun] gets
/// the plan id of the run it starts, whose output comes with its end.
class CronRunButton extends StatelessWidget {
  const CronRunButton({
    super.key,
    required this.serverId,
    required this.source,
    required this.raw,
    required this.onRun,
  });

  final String serverId;

  /// The line's source and the line as the row shows it ([RunCronJob]).
  final String source;
  final String raw;
  final void Function(String planId, ActionPreview preview) onRun;

  @override
  Widget build(BuildContext context) => ActionEntry(
    serverId: serverId,
    point: ActionEntryPoint.cronRunNow,
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        onPressed: () => startAction(
          context,
          RunCronJob(serverId, source: source, raw: raw),
          onRunPlan: onRun,
        ),
        icon: const Icon(Icons.play_arrow),
        label: Text(AppLocalizations.of(context).jobsRunNow),
      ),
    ),
  );
}

/// A cron line's JOB-19 verb for the Jobs table's row menu, or none where
/// actions are not allowed.
List<SidebarMenuEntry> cronActionEntries(
  BuildContext context, {
  required String serverId,
  required String source,
  required String raw,
  required void Function(String planId, ActionPreview preview) onRun,
}) {
  if (!actionsAllowedAt(context, serverId, ActionEntryPoint.cronRunNow)) {
    return const [];
  }
  return [
    SidebarMenuAction(
      label: AppLocalizations.of(context).jobsRunNow,
      onSelected: () => startAction(
        context,
        RunCronJob(serverId, source: source, raw: raw),
        onRunPlan: onRun,
      ),
    ),
  ];
}

/// [timer]'s JOB-08 verb for the Jobs table's row menu, or none where
/// actions are not allowed. [onRun] gets the unit the run starts, whose
/// journal shows its output.
List<SidebarMenuEntry> timerActionEntries(
  BuildContext context, {
  required String serverId,
  required String timer,
  required void Function(String unit) onRun,
}) {
  if (!actionsAllowedAt(context, serverId, ActionEntryPoint.timerRunNow)) {
    return const [];
  }
  final l10n = AppLocalizations.of(context);
  return [
    SidebarMenuAction(
      label: l10n.jobsRunNow,
      onSelected: () => _runTimer(context, serverId, timer, onRun),
    ),
  ];
}

/// The same verb as a button in a timer's details.
class TimerRunButton extends StatelessWidget {
  const TimerRunButton({
    super.key,
    required this.serverId,
    required this.timer,
    required this.onRun,
  });

  final String serverId;
  final String timer;
  final void Function(String unit) onRun;

  @override
  Widget build(BuildContext context) => ActionEntry(
    serverId: serverId,
    point: ActionEntryPoint.timerRunNow,
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: OutlinedButton.icon(
        onPressed: () => _runTimer(context, serverId, timer, onRun),
        icon: const Icon(Icons.play_arrow),
        label: Text(AppLocalizations.of(context).jobsRunNow),
      ),
    ),
  );
}

void _runTimer(
  BuildContext context,
  String serverId,
  String timer,
  void Function(String unit) onRun,
) => startAction(
  context,
  StartTimer(serverId, timer: timer),
  onRun: (preview) {
    if (preview.followUnit case final unit?) onRun(unit);
  },
);
