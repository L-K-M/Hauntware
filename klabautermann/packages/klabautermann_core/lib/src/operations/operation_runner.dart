// Runs a confirmed operation plan (03 §8.5, M4 E12): it re-validates the
// target against what the preview saw, then runs the plan's own steps in
// order, the ones the preview showed, and reports each step and the end.
// A step that fails stops the plan; nothing after it runs. A detached
// plan's steps run on the host instead, as one operation the runner
// launches (03 §7.17, M4 E18).
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show DockerApiException, DockerException;
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
import '../docker/docker_router.dart' show DockerEndpointUnavailable;
import '../engine/protocol.dart';
import 'detached_runner.dart' show LaunchFailure, LaunchResult;
import 'operation_plan.dart';
import 'plan_types.dart';

/// Runs one Docker API step on [serverId]'s engine and returns its HTTP
/// status (M4 E15). A [DockerException] or [DockerEndpointUnavailable]
/// it throws ends the run as a transport failure.
typedef ApiStepRunner = Future<int> Function(String serverId, ApiStep step);

/// Runs one [ExecStep] on [serverId]'s engine (CTX-08) and returns the
/// command's exit code, null when the daemon reported none, and its
/// redacted output. A [DockerApiException] it throws, the daemon's
/// refusal, fails the step; any other [DockerException] or a
/// [DockerEndpointUnavailable] ends the run as a transport failure.
typedef ExecStepRunner =
    Future<({int? exitCode, ExecOutput output})> Function(
      String serverId,
      ExecStep step,
    );

/// Checks a [DockerTargetUnchanged] or a [StackConfigUnchanged] on
/// [serverId] through its Docker endpoint: null when unchanged.
typedef DockerRevalidator =
    Future<RevalidationFailure?> Function(String serverId, Revalidation check);

/// Launches a detached [plan] on [serverId] as its runner row says,
/// through [session]'s elevation where the row needs it (03 §7.17).
typedef DetachedLauncher =
    Future<LaunchResult> Function(
      String serverId,
      OperationPlan plan,
      AdminSession? session,
    );

/// Runs [body], a user-initiated step's work on [serverId]'s link, with a
/// session channel free for it: on a link at its learned session limit,
/// the slow sampler lends its own for the while (M4 plan M6).
typedef SessionLender =
    Future<T> Function<T>(String serverId, Future<T> Function() body);

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
    this._exec,
    this._docker,
    this._launch,
    this._finished,
    this._lend,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SshLink? Function(String serverId) _linkFor;
  final void Function(EngineEvent event) _emit;
  final ApiStepRunner? _api;
  final ExecStepRunner? _exec;
  final DockerRevalidator? _docker;
  final DetachedLauncher? _launch;
  final void Function(OperationResult result)? _finished;
  final SessionLender? _lend;
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
    // Shell steps and a detached launch each open a session channel; API
    // steps go through the Docker endpoint instead.
    final lend = _lend;
    final needsSession =
        plan.detached || plan.steps.any((step) => step is ShellStep);
    final finished = lend != null && needsSession
        ? await lend(plan.intent.serverId, () => _run(planId, plan, session))
        : await _run(planId, plan, session);
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
      ExecOutput? output,
    }) => ActionFinished(
      planId: planId,
      outcome: ActionOutcome.failed,
      failure: failure,
      failedStep: step,
      exitCode: exitCode,
      httpStatus: httpStatus,
      revalidation: revalidation,
      output: output,
    );

    // What a one-off command printed, for the answer.
    ExecOutput? output;
    int? exitCode;

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

      if (plan.detachedRunner case final runner?) {
        final launch = _launch;
        if (launch == null) return failed(ActionFailure.unsupportedStep);
        if (runner.elevated && session == null) {
          return failed(ActionFailure.elevationRefused);
        }
        final launched = await launch(serverId, plan, session);
        return switch (launched.failure) {
          null => ActionFinished(
            planId: planId,
            outcome: ActionOutcome.succeeded,
            operationId: launched.id,
          ),
          LaunchFailure.elevationRefused => failed(
            ActionFailure.elevationRefused,
          ),
          LaunchFailure.transport => failed(ActionFailure.transport),
          LaunchFailure.noDirectory || LaunchFailure.failed => failed(
            ActionFailure.launchFailed,
            exitCode: launched.exitCode,
          ),
        };
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
              if (step.exitMeanings[result.exitCode] case final changed?) {
                return failed(
                  ActionFailure.revalidation,
                  step: i,
                  exitCode: result.exitCode,
                  revalidation: changed,
                );
              }
              return failed(
                !step.elevated && _polkitRefused.hasMatch(result.stderr)
                    ? ActionFailure.adminRequired
                    : ActionFailure.stepFailed,
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
          case final ExecStep step:
            final exec = _exec;
            if (exec == null) {
              return failed(ActionFailure.unsupportedStep, step: i);
            }
            final ({int? exitCode, ExecOutput output}) result;
            try {
              result = await exec(serverId, step);
            } on DockerApiException catch (e) {
              // The daemon answered and refused, as for a container that
              // stopped: the step failed, as an API step's error does.
              return failed(
                ActionFailure.stepFailed,
                step: i,
                httpStatus: e.statusCode,
              );
            }
            output = result.output;
            exitCode = result.exitCode;
            if (exitCode != 0) {
              return failed(
                ActionFailure.stepFailed,
                step: i,
                exitCode: exitCode,
                output: output,
              );
            }
        }
      }
    } on ElevationException {
      return failed(ActionFailure.elevationRefused);
    } on RemoteCommandException {
      return failed(ActionFailure.transport);
    } on DockerException {
      return failed(ActionFailure.transport);
    } on DockerEndpointUnavailable {
      return failed(ActionFailure.transport);
    } on ChannelOpenException {
      // The link refused the channel, at its session limit or closing.
      return failed(ActionFailure.transport);
    }
    return ActionFinished(
      planId: planId,
      outcome: ActionOutcome.succeeded,
      exitCode: exitCode,
      output: output,
    );
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
      case DockerTargetUnchanged() || StackConfigUnchanged():
        final docker = _docker;
        if (docker == null) return RevalidationFailure.unreadable;
        return docker(serverId, check);
    }
  }

  Future<RemoteCommandResult> _read(SshLink link, List<String> argv) =>
      link.run(
        HostCommands.commandLine(argv, quote: quoteShellWord),
        stdin: const [],
      );
}

/// polkit's refusal of `systemctl --no-ask-password` without an agent
/// (03 §7.5) [R].
final _polkitRefused = RegExp(
  r'Interactive authentication required|Access denied',
);

/// `klab_ticks`'s status for a process that is gone (proc_stat.dart).
const _kTicksGone = 3;
