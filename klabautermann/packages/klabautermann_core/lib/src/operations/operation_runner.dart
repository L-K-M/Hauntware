// Runs a confirmed operation plan (03 §8.5, M4 E12): it re-validates the
// target against what the preview saw, then runs the plan's own steps in
// order, the ones the preview showed, and reports each step and the end.
// A step that fails stops the plan; nothing after it runs.
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ElevationException,
        RemoteCommandException,
        RemoteCommandResult,
        SshLink,
        quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';
import 'operation_plan.dart';
import 'plan_types.dart';

/// Runs one Docker API step on [serverId]'s engine and returns its HTTP
/// status. The Docker planners supply it (M4 E15).
typedef ApiStepRunner = Future<int> Function(String serverId, ApiStep step);

/// Checks a [DockerTargetUnchanged] on [serverId]: null when unchanged.
typedef DockerRevalidator =
    Future<RevalidationFailure?> Function(
      String serverId,
      DockerTargetUnchanged check,
    );

/// What became of one run, for the audit log (8.10, E12b).
typedef OperationResult = ({
  String planId,
  OperationPlan plan,
  ActionFinished finished,
  DateTime startedAt,
  DateTime endedAt,
});

/// The first non-2xx HTTP status.
const _httpOk = 200, _httpMultipleChoices = 300;

final class OperationRunner {
  OperationRunner({
    required this._linkFor,
    required this._emit,
    this._api,
    this._docker,
    this._finished,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final ApiStepRunner? _api;
  final DockerRevalidator? _docker;
  final void Function(OperationResult result)? _finished;
  final DateTime Function() _now;

  /// Runs [plan] as [planId]. The caller took it from the registry,
  /// checked its confirmation and, for [RequiredLevel.admin], handed the
  /// admin [session]. Always ends with one [ActionFinished].
  Future<ActionFinished> run(
    String planId,
    OperationPlan plan, {
    AdminSession? session,
  }) async {
    final startedAt = _now();
    final finished = await _run(planId, plan, session);
    _emit(finished);
    _finished?.call((
      planId: planId,
      plan: plan,
      finished: finished,
      startedAt: startedAt,
      endedAt: _now(),
    ));
    return finished;
  }

  Future<ActionFinished> _run(
    String planId,
    OperationPlan plan,
    AdminSession? session,
  ) async {
    ActionFinished failed(
      ActionFailure failure, {
      int? step,
      int? exitCode,
      int? httpStatus,
      RevalidationFailure? revalidation,
    }) => ActionFinished(
      planId: planId,
      outcome: ActionOutcome.failed,
      failure: failure,
      failedStep: step,
      exitCode: exitCode,
      httpStatus: httpStatus,
      revalidation: revalidation,
    );

    final serverId = plan.intent.serverId;
    final link = _linkFor(serverId);
    if (link == null) return failed(ActionFailure.noLink);
    // An elevated step needs the session whatever level the plan names.
    final elevates =
        plan.requiredLevel == RequiredLevel.admin ||
        plan.steps.any((step) => step is ShellStep && step.elevated);
    if (elevates && session == null) {
      return failed(ActionFailure.elevationRefused);
    }

    try {
      for (final check in plan.revalidate) {
        final found = await _revalidate(serverId, link, check);
        if (found != null) {
          return failed(ActionFailure.revalidation, revalidation: found);
        }
      }

      for (var i = 0; i < plan.steps.length; i++) {
        _emit(
          ActionProgress(
            planId: planId,
            stepIndex: i,
            stepCount: plan.steps.length,
          ),
        );
        switch (plan.steps[i]) {
          case final ShellStep step:
            final result = step.elevated
                ? await session!.executor.run(
                    step.argv,
                    password: session.password,
                  )
                : await link.run(step.commandLine, stdin: const []);
            if (result.exitCode != 0) {
              return failed(
                ActionFailure.stepFailed,
                step: i,
                exitCode: result.exitCode,
              );
            }
          case final ApiStep step:
            final api = _api;
            if (api == null) {
              return failed(ActionFailure.unsupportedStep, step: i);
            }
            final status = await api(serverId, step);
            if (status < _httpOk || status >= _httpMultipleChoices) {
              return failed(
                ActionFailure.stepFailed,
                step: i,
                httpStatus: status,
              );
            }
        }
      }
    } on ElevationException {
      return failed(ActionFailure.elevationRefused);
    } on RemoteCommandException {
      return failed(ActionFailure.transport);
    } on ChannelOpenException {
      // The link refused the channel, at its session limit or closing.
      return failed(ActionFailure.transport);
    }
    return ActionFinished(planId: planId, outcome: ActionOutcome.succeeded);
  }

  Future<RevalidationFailure?> _revalidate(
    String serverId,
    SshLink link,
    Revalidation check,
  ) async {
    switch (check) {
      case UnitLoaded(:final unit):
        final result = await _read(link, HostCommands.unitLoadState(unit));
        if (result.exitCode != 0) return RevalidationFailure.unreadable;
        return result.stdout.trim() == 'loaded'
            ? null
            : RevalidationFailure.unitMissing;
      case ProcessStarted(:final pid, :final startTicks):
        final result = await _read(link, HostCommands.startTicks(pid));
        return switch (result.exitCode) {
          0 when result.stdout.trim() == '$startTicks' => null,
          0 => RevalidationFailure.processReused,
          _kTicksGone => RevalidationFailure.processGone,
          _ => RevalidationFailure.unreadable,
        };
      case final DockerTargetUnchanged docker:
        final check = _docker;
        if (check == null) return RevalidationFailure.unreadable;
        return check(serverId, docker);
    }
  }

  Future<RemoteCommandResult> _read(SshLink link, List<String> argv) =>
      link.run(
        HostCommands.commandLine(argv, quote: quoteShellWord),
        stdin: const [],
      );
}

/// `klab_ticks`'s status for a process that is gone (proc_stat.dart).
const _kTicksGone = 3;
