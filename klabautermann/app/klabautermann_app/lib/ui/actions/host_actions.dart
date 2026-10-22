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

/// SVC-05's and SVC-06's verbs (v1), behind "More" on the page and in the
/// row menu: they change the next boot or a unit's state rather than run
/// it.
const _moreUnitVerbs = [
  SystemctlVerb.enable,
  SystemctlVerb.disable,
  SystemctlVerb.mask,
  SystemctlVerb.unmask,
  SystemctlVerb.resetFailed,
];

String _verbLabel(AppLocalizations l10n, SystemctlVerb verb) => switch (verb) {
  SystemctlVerb.start => l10n.unitStart,
  SystemctlVerb.stop => l10n.unitStop,
  SystemctlVerb.restart => l10n.unitRestart,
  SystemctlVerb.reload => l10n.unitReload,
  SystemctlVerb.enable => l10n.unitEnable,
  SystemctlVerb.disable => l10n.unitDisable,
  SystemctlVerb.mask => l10n.unitMask,
  SystemctlVerb.unmask => l10n.unitUnmask,
  SystemctlVerb.resetFailed => l10n.unitResetFailed,
  _ => verb.name,
};

/// [unit]'s SVC-03 verbs for the Services table's row menu, or none where
/// actions are not allowed.
List<SidebarMenuEntry> unitActionEntries(
  BuildContext context, {
  required String serverId,
  required String unit,
  required UnitScope scope,
}) {
  if (!actionsAllowedAt(context, serverId, ActionEntryPoint.unitVerb)) {
    return const [];
  }
  final l10n = AppLocalizations.of(context);
  SidebarMenuAction act(SystemctlVerb verb) => SidebarMenuAction(
    label: _verbLabel(l10n, verb),
    onSelected: () => startAction(
      context,
      UnitAction(serverId, unit: unit, verb: verb, scope: scope),
    ),
  );
  return [
    for (final verb in _unitVerbs) act(verb),
    SidebarMenuSubmenu(
      label: l10n.unitMoreActions,
      children: [for (final verb in _moreUnitVerbs) act(verb)],
    ),
  ];
}

/// The same verbs as buttons on a unit's page.
class UnitActionButtons extends StatelessWidget {
  const UnitActionButtons({
    super.key,
    required this.serverId,
    required this.unit,
    required this.scope,
  });

  final String serverId;
  final String unit;

  /// The manager [unit] belongs to (SVC-09).
  final UnitScope scope;

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
                UnitAction(serverId, unit: unit, verb: verb, scope: scope),
              ),
              child: Text(_verbLabel(l10n, verb)),
            ),
          MenuAnchor(
            menuChildren: [
              for (final verb in _moreUnitVerbs)
                MenuItemButton(
                  onPressed: () => startAction(
                    context,
                    UnitAction(serverId, unit: unit, verb: verb, scope: scope),
                  ),
                  child: Text(_verbLabel(l10n, verb)),
                ),
            ],
            builder: (context, controller, _) => OutlinedButton.icon(
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.arrow_drop_down),
              label: Text(l10n.unitMoreActions),
            ),
          ),
        ],
      ),
    );
  }
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
  onRun: (_, preview) {
    if (preview.followUnit case final unit?) onRun(unit);
  },
);
