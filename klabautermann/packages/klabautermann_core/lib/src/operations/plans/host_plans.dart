// The host action planners (M4 E14): PRC-02's kill, SVC-03's unit
// actions and JOB-08's run-timer-now. Each reads what it needs over the
// link at planning time, so the preview shows the target as it stands,
// and builds one plan whose steps are exactly what will run.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        HostCommandError,
        HostCommands,
        HostProfile,
        SystemctlVerb,
        kGuardedKillGone,
        kGuardedKillReused;
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, SshLink, quoteShellWord;

import '../../engine/protocol.dart';
import '../confirmation.dart';
import '../impact.dart';
import '../operation_plan.dart';
import '../plan_types.dart';
import '../protected_targets.dart';

/// What planning on one server sees: its ready link, its probe, its
/// session path and marks, and whether admin mode is on.
typedef HostPlanContext = ({
  SshLink link,
  HostProfile profile,
  ProtectionContext protection,
  bool adminMode,
});

/// The verbs SVC-03 offers in the MVP (03 §7.5); enable, disable and the
/// rest are v1.
const _unitVerbs = {
  SystemctlVerb.start: OperationKind.start,
  SystemctlVerb.stop: OperationKind.stop,
  SystemctlVerb.restart: OperationKind.restart,
  SystemctlVerb.reload: OperationKind.reload,
};

/// The guarded kill's statuses that mean its target changed (03 §7.2).
const _killChanged = {
  kGuardedKillGone: RevalidationFailure.processGone,
  kGuardedKillReused: RevalidationFailure.processReused,
};

/// Plans [intent], a host action, or says why it cannot be planned.
Future<PlanAttempt> planHostAction(
  ActionIntent intent,
  HostPlanContext context,
) async {
  try {
    return switch (intent) {
      KillProcess() => await _planKill(intent, context),
      UnitAction() => await _planUnit(intent, context),
      StartTimer() => await _planTimer(intent, context),
      _ => _refused(ActionRefusalReason.notImplemented),
    };
  } on HostCommandError {
    return _refused(ActionRefusalReason.invalidTarget);
  } on RemoteCommandException {
    return _refused(ActionRefusalReason.noLink);
  }
}

/// PRC-02: elevated only when the process belongs to another user;
/// protected processes need the typed confirmation.
Future<PlanAttempt> _planKill(KillProcess intent, HostPlanContext c) async {
  final ticks = await _read(c.link, HostCommands.startTicks(intent.pid));
  if (ticks == null || ticks != '${intent.startTicks}') {
    return _refused(ActionRefusalReason.targetChanged);
  }
  final facts = await _read(c.link, HostCommands.processFacts(intent.pid));
  final space = facts?.indexOf(' ') ?? -1;
  final uid = space < 0 ? null : int.tryParse(facts!.substring(0, space));
  if (uid == null) return _refused(ActionRefusalReason.targetChanged);
  final comm = facts!.substring(space + 1);

  final elevated = uid != c.profile.uid;
  final protected = processProtection(
    pid: intent.pid,
    comm: comm,
    context: c.protection,
  );
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.kill,
      targetName: comm,
      steps: [
        ShellStep(
          HostCommands.guardedKill(
            intent.pid,
            intent.startTicks,
            intent.signal,
          ),
          elevated: elevated,
          exitMeanings: _killChanged,
        ),
      ],
      requiredLevel: elevated ? RequiredLevel.admin : RequiredLevel.login,
      runner: _runner(c, elevated: elevated),
      hostWrites: const [HostWriteRow.loginRecords],
      impact: protected == ProtectedReason.sessionPath
          ? const PlanImpact(ImpactKind.dropsSession)
          : const PlanImpact(ImpactKind.interruptsTarget),
      protected: protected,
      revalidate: [ProcessStarted(intent.pid, intent.startTicks)],
    ),
  );
}

/// SVC-03 (M13): through elevation in admin mode, otherwise unelevated
/// with `--no-ask-password`, in case polkit grants the verb.
Future<PlanAttempt> _planUnit(UnitAction intent, HostPlanContext c) async {
  final kind = _unitVerbs[intent.verb];
  if (kind == null) return _refused(ActionRefusalReason.invalidTarget);
  final argv = HostCommands.systemctl(intent.verb, intent.unit);
  final protected = unitProtection(intent.unit, c.protection);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: kind,
      targetName: intent.unit,
      steps: [ShellStep(argv, elevated: c.adminMode)],
      requiredLevel: c.adminMode ? RequiredLevel.admin : RequiredLevel.login,
      runner: _runner(c, elevated: c.adminMode),
      hostWrites: const [HostWriteRow.loginRecords],
      impact: intent.verb == SystemctlVerb.start
          ? null
          : unitImpact(intent.unit, protected: protected),
      protected: protected,
      revalidate: [UnitLoaded(intent.unit)],
    ),
  );
}

/// JOB-08 (M13): starts the unit the timer activates with SVC-03's
/// guards, and names it for the journal follow.
Future<PlanAttempt> _planTimer(StartTimer intent, HostPlanContext c) async {
  final unit = await _read(c.link, HostCommands.timerActivates(intent.timer));
  if (unit == null || unit.isEmpty) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final argv = HostCommands.timerStart(unit);
  final protected = unitProtection(unit, c.protection);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.runTimerNow,
      targetName: intent.timer,
      steps: [ShellStep(argv, elevated: c.adminMode)],
      requiredLevel: c.adminMode ? RequiredLevel.admin : RequiredLevel.login,
      runner: _runner(c, elevated: c.adminMode),
      hostWrites: const [HostWriteRow.loginRecords],
      protected: protected,
      followUnit: unit,
      revalidate: [UnitLoaded(unit)],
    ),
  );
}

RunnerFacts _runner(HostPlanContext c, {required bool elevated}) => RunnerFacts(
  identity: elevated ? 'root' : (c.profile.user ?? 'login user'),
  credentials: elevated
      ? RunnerCredentials.adminPassword
      : RunnerCredentials.session,
);

/// [argv]'s trimmed stdout, or null when it exits non-zero.
Future<String?> _read(SshLink link, List<String> argv) async {
  final result = await link.run(
    HostCommands.commandLine(argv, quote: quoteShellWord),
    stdin: const [],
  );
  return result.exitCode == 0 ? result.stdout.trim() : null;
}

PlanAttempt _planned(OperationPlan plan) => (plan: plan, refusal: null);

PlanAttempt _refused(ActionRefusalReason reason) =>
    (plan: null, refusal: reason);
