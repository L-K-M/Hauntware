import 'dart:async';

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show DockerCancelToken;
import 'package:klabautermann_host/klabautermann_host.dart'
    show HostProfile, OpDirectoryKind;
import 'package:seance_core/seance_core.dart' show SecretRedactor;

import '../admin/admin_mode.dart';
import '../admin/safety_policy.dart';
import '../audit/audit_log.dart';
import '../audit/host_audit_line.dart';
import '../docker/docker_router.dart';
import '../docker/exec_sessions.dart';
import '../engine/protocol.dart';
import '../links/channel_quota.dart';
import '../links/link_supervisor.dart';
import '../operations/confirmation.dart';
import '../operations/detached_runner.dart';
import '../operations/footprint.dart';
import '../operations/operation_plan.dart'
    show
        DockerTargetUnchanged,
        PlanAttempt,
        StackConfigUnchanged,
        refusalDetail;
import '../operations/operation_runner.dart';
import '../operations/operation_tracker.dart';
import '../operations/operations_shown.dart';
import '../operations/plan_registry.dart';
import '../operations/plan_types.dart' show RequiredLevel;
import '../operations/plans/backup_plans.dart';
import '../operations/plans/docker_plans.dart';
import '../operations/plans/edit_plan.dart';
import '../operations/plans/host_plans.dart';
import '../operations/plans/redeploy_plan.dart';
import '../operations/protected_targets.dart';
import '../operations/stack_edits.dart';
import '../sampling/sampling_scheduler.dart';

/// The engine's action handling (ENG-11 step 4, ARC-05), moved out of
/// `engineMain` so a plan's preview, run, cancel, footprint and detached
/// operation acknowledgement live in one place and can be tested without
/// an isolate.
///
/// Every dependency is fixed at construction, except [scheduler], [admin],
/// [docker], [operations], [safetyPolicy] and [deviceName], which the
/// engine assigns or replaces after this object is built and are read
/// through getters so no captured snapshot goes stale.
final class EngineActions {
  EngineActions({
    required this._links,
    required this._admin,
    required this._audit,
    required this._scheduler,
    required this._profiles,
    required this._plans,
    required this._linkGenerations,
    required this._channelQuotas,
    required this._docker,
    required this._operations,
    required this._safetyPolicy,
    required this._deviceName,
    required this._fleetIds,
    required this._send,
    required this._detach,
    required this._reject,
  }) {
    final links = _links;
    _runner = links == null
        ? null
        : OperationRunner(
            linkFor: links.link,
            emit: _send,
            lend: lendSession,
            api: (serverId, planId, step) async {
              final router = _docker();
              if (router == null) {
                throw const DockerEndpointUnavailable(
                  DockerQueryFailure.cancelled,
                );
              }
              final pull = isPullStep(step);
              final cancel = pull
                  ? _pullCancels.start(planId)
                  : DockerCancelToken();
              final int status;
              try {
                status = await router.useEndpoint(
                  serverId,
                  (client, _) => pull
                      ? runPullStep(
                          client,
                          step,
                          cancel: cancel,
                          onProgress: (layers, status) => _send(
                            ImagePullProgress(
                              planId: planId,
                              layers: layers,
                              status: status,
                            ),
                          ),
                        )
                      : runApiStep(client, step),
                );
              } finally {
                if (pull) _pullCancels.finish(planId);
              }
              if (status >= 200 && status < 300) {
                final (:container, :containers, :images, :volumes, :networks) =
                    apiStepChanges(step);
                router.actionRan(
                  serverId,
                  containers: {?container},
                  everyContainer: containers,
                  images: images,
                  volumes: volumes,
                  networks: networks,
                );
              }
              return status;
            },
            exec: (serverId, step) {
              final router = _docker();
              if (router == null) {
                throw const DockerEndpointUnavailable(
                  DockerQueryFailure.cancelled,
                );
              }
              return runOneOffExec(
                step,
                open: () => router.openExec(serverId),
                control: <T>(call) =>
                    router.useEndpoint(serverId, (client, _) => call(client)),
                redact: _execRedactor.redact,
              );
            },
            docker: (serverId, check) async {
              final router = _docker();
              if (router == null) return RevalidationFailure.unreadable;
              try {
                return await router.useStacks(
                  serverId,
                  (client, _, stacks) => switch (check) {
                    final StackConfigUnchanged stack => revalidateStackConfig(
                      stacks,
                      stack,
                    ),
                    final DockerTargetUnchanged target =>
                      revalidateDockerTarget(client, target),
                    _ => Future.value(RevalidationFailure.unreadable),
                  },
                );
              } on Object {
                return RevalidationFailure.unreadable;
              }
            },
            launch: (serverId, plan, session) async {
              final link = links.link(serverId);
              final uid = _profiles[serverId]?.uid;
              final runner = plan.detachedRunner!;
              final id = newOpId();
              if (link == null || uid == null) {
                return (
                  id: id,
                  dir: null,
                  pid: null,
                  failure: LaunchFailure.transport,
                  exitCode: null,
                );
              }
              final launched = await launchDetached(
                link: link,
                runner: runner,
                uid: uid,
                argv: detachedArgv(plan),
                id: id,
                session: session,
              );
              if (launched.failure == null) {
                await _operations()?.launched(
                  serverId,
                  id,
                  directory: runner.runsAsRoot
                      ? OpDirectoryKind.root
                      : OpDirectoryKind.user,
                  launch: OperationLaunch.ofPlan(
                    plan,
                    startedAt: DateTime.now().toUtc(),
                  ),
                );
              }
              return launched;
            },
            // A record that cannot be written is lost; the run itself
            // stands. A started detached operation is audited with its
            // result, once the app has shown it (03 §7.17).
            finished: (result) {
              if (result.plan.intent
                  case EditFile() || KeepLastBackups() || RemoveBackups()) {
                verifyFootprint(result.plan.intent.serverId);
              }
              if (result.plan.detached &&
                  result.finished.outcome == ActionOutcome.succeeded) {
                return;
              }
              unawaited(_audit.recordRun(result).catchError((Object _) {}));
            },
          );
  }

  final LinkSupervisor? _links;
  final AdminModeController? Function() _admin;
  final AuditLog _audit;
  final SamplingScheduler? Function() _scheduler;
  final Map<String, HostProfile> _profiles;
  final PlanRegistry _plans;
  final Map<String, int> _linkGenerations;
  final ChannelQuotas _channelQuotas;
  final DockerRouter? Function() _docker;
  final OperationTracker? Function() _operations;
  final SafetyPolicy Function() _safetyPolicy;
  final String Function() _deviceName;
  final Set<String> Function() _fleetIds;
  final void Function(EngineEvent event) _send;
  final void Function(
    Future<void>? work, {
    void Function(Object error, StackTrace stack)? onError,
  })
  _detach;
  final void Function(EngineRequest request, String reason) _reject;

  /// The running image pulls by plan id, which [cancelAction] stops
  /// (IMG-03).
  final PullCancels _pullCancels = PullCancels();

  /// One-off commands' output is redacted as the audit log redacts the
  /// steps (CTX-08, 03 §8.10).
  final SecretRedactor _execRedactor = SecretRedactor();

  /// Runs a confirmed plan; null while links are off, where [runAction]
  /// refuses [ActionRefusalReason.notImplemented].
  late final OperationRunner? _runner;

  // A user-initiated step on a link at its learned session limit borrows
  // the slow sampler's session for the while; the fast sampler samples on
  // (M4 plan M6). Elsewhere the step runs as it is.
  Future<T> lendSession<T>(String serverId, Future<T> Function() body) async {
    final link = _links?.link(serverId);
    final inUse =
        (_scheduler()?.samplerSessions(serverId) ?? 0) +
        _channelQuotas.of(serverId).sessionsHeld;
    if (link == null ||
        !leavesNoSession(
          learnedSessionLimit: link.seen.learnedSessionLimit,
          inUse: inUse,
        )) {
      return body();
    }
    final giveBack = await _scheduler()?.yieldSlowSampler(serverId);
    try {
      return await body();
    } finally {
      giveBack?.call();
    }
  }

  // A stack file's edit (STK-07) looks its project up on the server's
  // Docker endpoint, for its read and again for its plan: null while
  // links are off.
  StackEditLookup? stackEditLookup(String serverId) {
    final router = _docker();
    if (router == null) return null;
    return (project, path) async {
      try {
        return await router.useStacks(serverId, (client, route, stacks) async {
          final found = await stacks.editable(client, project, path);
          return (
            project: found.project,
            socketPath: route.socketPath,
            dockerProgram: route.dockerProgram,
            failure: found.failure,
          );
        });
      } on Object {
        // No endpoint, or the list failed: nothing to edit against.
        return (
          project: null,
          socketPath: null,
          dockerProgram: null,
          failure: StackFileFailure.readFailed,
        );
      }
    };
  }

  // Verifies a server's footprint (SAF-14, P13) and sends what it found:
  // on every connect, when admin mode turns on (root's part), after an
  // edit or a backup removal, and on request. readFootprint answers
  // rather than throws; a lend that fails still answers, with nothing
  // verified, rather than leaving an unhandled error to end the engine.
  void verifyFootprint(String serverId) {
    final link = _links?.link(serverId);
    final profile = _profiles[serverId];
    if (link == null || profile == null) return;
    unawaited(
      lendSession(
        serverId,
        () => readFootprint(serverId, (
          link: link,
          profile: profile,
          admin: _admin()?.session(serverId),
        )),
      ).then(
        _send,
        onError: (Object error) => _send(
          FootprintState(
            serverId,
            rootUnchecked: true,
            warnings: ['footprint: $error'],
          ),
        ),
      ),
    );
  }

  void planAction(PlanAction message) {
    final intent = message.intent;
    void refuse(ActionRefusalReason reason, {String? detail}) => _send(
      ActionRefused(reason, intent: intent, detail: refusalDetail(detail)),
    );
    // The policy first (M4 plan M4).
    if (safetyRefusal(_safetyPolicy(), intent.serverId) case final reason?) {
      refuse(reason);
      return;
    }
    final serverId = intent.serverId;
    final link = _links?.link(serverId);
    final profile = _profiles[serverId];
    if (link == null || profile == null) {
      refuse(ActionRefusalReason.noLink);
      return;
    }
    // The plan holds the generation it was made on, so a reconnect
    // while it waits for the user makes it stale.
    final generation = _linkGenerations[serverId] ?? 0;
    final protection = protectionContextOf(
      samplerPids: _scheduler()?.samplerPids(serverId) ?? const {},
      profile: profile,
      safety: _safetyPolicy().servers[serverId],
    );
    final Future<PlanAttempt> attempt;
    switch (intent) {
      case KillProcess() ||
          UnitAction() ||
          StartTimer() ||
          RunCronJob() ||
          RunSnippet() ||
          RefreshPackageLists() ||
          PowerAction():
        // Planning reads the target over the link, as the run will.
        final session = _admin()?.session(serverId);
        attempt = lendSession(
          serverId,
          () => planHostAction(
            intent,
            (
              link: link,
              profile: profile,
              protection: protection,
              adminMode: session != null,
            ),
            elevated: session == null
                ? null
                : (argv) =>
                      session.executor.run(argv, password: session.password),
          ),
        );
      case ContainerAction() ||
          RemoveContainer() ||
          ContainerBulkAction() ||
          RemoveImage() ||
          CreateVolume() ||
          RemoveVolume() ||
          RemoveNetwork() ||
          PruneDocker() ||
          PullImage(via: PullRoute.engine) ||
          StackAction() ||
          ContainerExec():
        final router = _docker();
        if (router == null) {
          refuse(ActionRefusalReason.engineUnavailable);
          return;
        }
        attempt = router
            .useEndpoint(
              serverId,
              (client, route) => planDockerAction(intent, (
                client: client,
                route: route,
                protection: protection,
                loginUser: profile.user ?? 'login user',
              )),
            )
            .catchError(
              (Object error) => (
                plan: null,
                refusal: ActionRefusalReason.engineUnavailable,
                detail: '$error',
              ),
            );
      case RedeployStack() || StackComposeAction() || PullImage():
        final router = _docker();
        if (router == null) {
          refuse(ActionRefusalReason.engineUnavailable);
          return;
        }
        // Planning verifies the stack and lists its services over the
        // link, so it borrows a session as a run does.
        attempt =
            lendSession(
              serverId,
              () => router.useStacks(serverId, (client, route, stacks) {
                final RedeployPlanContext context = (
                  client: client,
                  route: route,
                  stacks: stacks,
                  profile: profile,
                  adminMode: _admin()?.session(serverId) != null,
                  sudoAllows: (program) async {
                    final session = _admin()?.session(serverId);
                    if (session == null) return true;
                    return sudoAllowsProgram(
                      link: link,
                      session: session,
                      profile: profile,
                      program: program,
                    );
                  },
                  protection: protection,
                  loginUser: profile.user ?? 'login user',
                );
                return switch (intent) {
                  final RedeployStack redeploy => planRedeploy(
                    redeploy,
                    context,
                  ),
                  final StackComposeAction compose => planStackCompose(
                    compose,
                    context,
                  ),
                  final PullImage pull => planHostPull(pull, context),
                  _ => throw StateError(
                    'not a compose intent: ${intent.runtimeType}',
                  ),
                };
              }),
            ).catchError(
              (Object error) => (
                plan: null,
                refusal: ActionRefusalReason.engineUnavailable,
                detail: '$error',
              ),
            );
      case KeepLastBackups() || RemoveBackups():
        attempt = lendSession(
          serverId,
          () => planBackupRemoval(intent, (
            link: link,
            profile: profile,
            admin: _admin()?.session(serverId),
          )),
        );
      case EditFile():
        // Planning reads the target again over the link, through admin
        // mode where it needs root, as the run will.
        attempt = lendSession(
          serverId,
          () => planEdit(intent, (
            link: link,
            profile: profile,
            admin: _admin()?.session(serverId),
          ), stacks: stackEditLookup(serverId)),
        );
    }
    // Not awaited: planning reads over the link, and the queue keeps
    // serving the app meanwhile. A planner that throws rather than
    // refusing still answers, or the app's preview would stay
    // pending for good.
    _detach(
      attempt
          .catchError(
            (Object error) => (
              plan: null,
              refusal: ActionRefusalReason.engineUnavailable,
              detail: '$error',
            ),
          )
          .then((attempt) {
            final plan = attempt.plan;
            if (plan == null) {
              refuse(attempt.refusal!, detail: attempt.detail);
              return;
            }
            // The switch and name as they are now, when the user sees
            // the plan; the preview lists the line among the steps.
            final held = withHostAuditLine(
              withAdminCredentials(plan, _admin()?.session(serverId)),
              enabled: _safetyPolicy().servers[serverId]?.hostAuditLine ?? true,
              deviceName: _deviceName(),
            );
            final planId = _plans.hold(held, linkGeneration: generation);
            _send(ActionPlanned(planId, held.preview));
          }),
      // What follows the planner can throw too, such as the audit
      // line's own checks: the preview is refused, not left pending.
      onError: (error, _) =>
          refuse(ActionRefusalReason.engineUnavailable, detail: '$error'),
    );
  }

  void runAction(RunAction message) {
    final planId = message.planId;
    final confirmation = message.confirmation;
    // A plan is taken once: a refused run needs a new preview.
    final (:plan, :missing) = _plans.take(
      planId,
      linkGeneration: (id) => _linkGenerations[id] ?? 0,
    );
    void refuse(ActionRefusalReason reason) =>
        _send(ActionRefused(reason, planId: planId));
    if (plan == null) {
      refuse(switch (missing!) {
        PlanMissing.unknown => ActionRefusalReason.unknownPlan,
        PlanMissing.expired => ActionRefusalReason.expiredPlan,
        PlanMissing.stale => ActionRefusalReason.stalePlan,
      });
      return;
    }
    final serverId = plan.intent.serverId;
    if (safetyRefusal(_safetyPolicy(), serverId) case final reason?) {
      refuse(reason);
      return;
    }
    if (!confirmationSatisfies(
      required: plan.tier,
      given: confirmation.tier,
      targetName: plan.targetName,
      phrase: confirmation.phrase,
    )) {
      refuse(ActionRefusalReason.confirmationMismatch);
      return;
    }
    final planRunner = _runner;
    if (planRunner == null) {
      refuse(ActionRefusalReason.notImplemented);
      return;
    }
    final session = _admin()?.session(serverId);
    if (plan.requiredLevel == RequiredLevel.admin && session == null) {
      refuse(ActionRefusalReason.adminRequired);
      return;
    }
    if (session != null) _admin()?.touch(serverId);
    // Not awaited, like the reads: a plan's steps take as long as
    // they take, and the queue keeps serving the app meanwhile.
    // The runner always answers with one ActionFinished, so an error
    // here comes from after it and is a fault, not a second answer.
    _detach(
      planRunner.run(planId, plan, session: session).then((finished) {
        if (session != null) _admin()?.touch(serverId);
      }),
    );
  }

  void cancelAction(CancelAction message) {
    _pullCancels.cancel(message.planId);
  }

  void footprintQuery(FootprintQuery message) {
    final serverId = message.serverId;
    if (!_fleetIds().contains(serverId)) {
      _reject(message, 'no fleet server $serverId');
    } else if (_links?.link(serverId) == null || _profiles[serverId] == null) {
      _reject(message, 'no connection to $serverId');
    } else {
      verifyFootprint(serverId);
    }
  }

  void acknowledgeOperation(AcknowledgeOperation message) {
    final serverId = message.serverId;
    final id = message.id;
    final tracker = _operations();
    if (tracker == null) {
      _reject(message, 'links are off');
      return;
    }
    // Not awaited: the answer waits for the server's listing in
    // flight, which reads over the link, and the queue keeps serving
    // the app meanwhile. The tracker is not expected to throw; if it
    // does, the engine answers rather than dying with every link.
    unawaited(
      tracker.acknowledge(serverId, id).then(
        (reason) {
          if (reason != null) _reject(message, reason);
        },
        onError: (Object error) => _reject(message, 'acknowledgement: $error'),
      ),
    );
  }
}
