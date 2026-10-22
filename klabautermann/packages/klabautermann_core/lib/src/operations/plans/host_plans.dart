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
        UnitManager,
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

/// The verbs SVC-03 (MVP), SVC-05 and SVC-06 (v1) offer (03 §7.5).
const _unitVerbs = {
  SystemctlVerb.start: OperationKind.start,
  SystemctlVerb.stop: OperationKind.stop,
  SystemctlVerb.restart: OperationKind.restart,
  SystemctlVerb.reload: OperationKind.reload,
  SystemctlVerb.enable: OperationKind.enable,
  SystemctlVerb.disable: OperationKind.disable,
  SystemctlVerb.mask: OperationKind.mask,
  SystemctlVerb.unmask: OperationKind.unmask,
  SystemctlVerb.resetFailed: OperationKind.resetFailed,
};

/// The verbs that change what a unit does now, so the preview names the
/// impact; the others change only what happens at the next boot or
/// start, or clear a failed state.
const _impactVerbs = {
  SystemctlVerb.stop,
  SystemctlVerb.restart,
  SystemctlVerb.reload,
  SystemctlVerb.mask,
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

/// SVC-03, SVC-05 and SVC-06 (M13, M22): a system unit's verb runs
/// through elevation in admin mode, otherwise unelevated with
/// `--no-ask-password`, in case polkit grants it. A user unit's (SVC-09)
/// always runs as the login user, admin mode or not. Protected targets
/// apply in both managers.
Future<PlanAttempt> _planUnit(UnitAction intent, HostPlanContext c) async {
  final kind = _unitVerbs[intent.verb];
  if (kind == null) return _refused(ActionRefusalReason.invalidTarget);
  final manager = _manager(intent.scope, c);
  final elevated = c.adminMode && !manager.isUser;
  final argv = HostCommands.systemctl(
    intent.verb,
    intent.unit,
    manager: manager,
  );
  final protected = unitProtection(intent.unit, c.protection);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: kind,
      targetName: intent.unit,
      steps: [ShellStep(argv, elevated: elevated)],
      requiredLevel: elevated ? RequiredLevel.admin : RequiredLevel.login,
      runner: _runner(c, elevated: elevated),
      hostWrites: const [HostWriteRow.loginRecords],
      impact: _impactVerbs.contains(intent.verb)
          ? unitImpact(intent.unit, protected: protected)
          : null,
      protected: protected,
      revalidate: [UnitLoaded(intent.unit, manager: manager)],
    ),
  );
}

/// The manager [scope] addresses on the host [c] probed.
UnitManager _manager(UnitScope scope, HostPlanContext c) => switch (scope) {
  UnitScope.system => const UnitManager.system(),
  UnitScope.user => UnitManager.userFor(
    uid: c.profile.uid,
    xdgRuntimeDir: c.profile.xdgRuntimeDir,
  ),
};

/// JOB-08 (M13): starts the unit the timer activates with SVC-03's
/// guards, and names it for the journal follow.
Future<PlanAttempt> _planTimer(StartTimer intent, HostPlanContext c) async {
  final manager = _manager(intent.scope, c);
  final elevated = c.adminMode && !manager.isUser;
  final unit = await _read(
    c.link,
    HostCommands.timerActivates(intent.timer, manager: manager),
  );
  if (unit == null || unit.isEmpty) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final argv = HostCommands.timerStart(unit, manager: manager);
  final protected = unitProtection(unit, c.protection);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.runTimerNow,
      targetName: intent.timer,
      steps: [ShellStep(argv, elevated: elevated)],
      requiredLevel: elevated ? RequiredLevel.admin : RequiredLevel.login,
      runner: _runner(c, elevated: elevated),
      hostWrites: const [HostWriteRow.loginRecords],
      protected: protected,
      // The output follow reads the system journal by unit, where a user
      // unit's lines are not found under that name.
      followUnit: manager.isUser ? null : unit,
      revalidate: [UnitLoaded(unit, manager: manager)],
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
