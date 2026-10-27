// STK-06's pull and redeploy (03 §7.16, M4 E18, M10) and STK-23's
// per-service and teardown operations (M5 M25a): a verified, unmanaged
// stack's compose commands rebuilt from its labels, run as one detached
// operation (03 §7.17) against the engine the endpoint found.
//
// ```text
//   project's containers ─▶ none ─▶ invalid target
//     ├─ a manager's labels ─▶ refused: managed (no act anyway)
//     ├─ verdict: standalone docker-compose only ─▶ refused: legacy
//     ├─ verdict: anything but verified ─▶ refused: unverified
//     ├─ config --services, and again with --profile '*'
//     │    ─▶ orphans (in neither) and profile-gated services (only in *)
//     └─ runner row ─▶ refused: admin required, sudo right missing
//   steps: config -q (status only), pull, up -d [--remove-orphans]
//   re-validated: the containers' ids, and config --hash '*' against
//   every service's label, right before the launch
// ```
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show HostProfile;

import '../../docker/docker_ladder.dart' show DockerRank;
import '../../docker/stack_sources.dart';
import '../../engine/protocol.dart';
import '../confirmation.dart';
import '../detached_runner.dart';
import '../impact.dart';
import '../operation_plan.dart';
import '../ownership.dart';
import '../plan_types.dart';
import '../protected_targets.dart';
import 'docker_plans.dart' show stackFingerprint, validImageReference;

/// What planning a redeploy on one server sees: its Docker endpoint and
/// stack checks, the host profile the runner row comes from, whether
/// admin mode is on, whether the account's sudo rules let root run a
/// program (D66), the session's protected targets and the login user.
typedef RedeployPlanContext = ({
  DockerClient client,
  DockerEndpointRoute route,
  StackSources stacks,
  HostProfile profile,
  bool adminMode,
  Future<bool> Function(String program) sudoAllows,
  ProtectionContext protection,
  String loginUser,
});

const _running = 'running';

/// Plans [intent], or says why it cannot be planned.
Future<PlanAttempt> planRedeploy(
  RedeployStack intent,
  RedeployPlanContext c,
) async {
  final verified = await _verify(intent.project, c);
  if (verified case _Refusal(:final reason)) return _refused(reason);
  final stack = verified as _VerifiedStack;

  final everyProfile = await c.stacks.serviceNames(
    stack.project,
    allProfiles: true,
  );
  final orphans = <String>[];
  var profileGated = false;
  for (final container in stack.containers) {
    final service = ComposeLabels.fromContainerLabels(
      container.labels,
    )?.service;
    if (service == null || stack.named.contains(service)) continue;
    if (everyProfile != null && everyProfile.contains(service)) {
      profileGated |= container.state == _running;
      continue;
    }
    orphans.add(_nameOf(container));
  }
  orphans.sort();

  return _composePlan(
    intent,
    stack,
    c,
    kind: intent.removeOrphans
        ? OperationKind.redeployRemovingOrphans
        : OperationKind.redeploy,
    targetName: stack.project.name,
    steps: (files) => [
      ShellStep(
        composePull(
          socketPath: files.socketPath,
          project: files.project,
          projectDirectory: files.projectDirectory,
          configFiles: files.configFiles,
          envFiles: files.envFiles,
        ).argv,
      ),
      ShellStep(
        composeUp(
          socketPath: files.socketPath,
          project: files.project,
          projectDirectory: files.projectDirectory,
          configFiles: files.configFiles,
          envFiles: files.envFiles,
          removeOrphans: intent.removeOrphans,
        ).argv,
      ),
    ],
    orphans: orphans,
    warnings: [
      if (profileGated) PlanWarning.profileGatedServices,
      if (everyProfile == null && orphans.isNotEmpty)
        PlanWarning.profilesUnknown,
    ],
  );
}

/// Plans [intent], one of STK-23's compose operations, or says why it
/// cannot be planned. The stack passes the checks a redeploy does; a
/// service the files do not name, a replica count on any verb but scale
/// or out of range, and a service with `down` are invalid targets.
Future<PlanAttempt> planStackCompose(
  StackComposeAction intent,
  RedeployPlanContext c,
) async {
  final service = intent.service;
  final replicas = intent.replicas;
  final down = intent.verb == StackComposeVerb.down;
  final scale = intent.verb == StackComposeVerb.scaleService;
  if (down != (service == null) ||
      scale != (replicas != null) ||
      (replicas != null && (replicas < 0 || replicas > kComposeMaxScale))) {
    return _refused(ActionRefusalReason.invalidTarget);
  }

  final verified = await _verify(intent.project, c);
  if (verified case _Refusal(:final reason)) return _refused(reason);
  final stack = verified as _VerifiedStack;
  if (service != null && !stack.named.contains(service)) {
    return _refused(ActionRefusalReason.invalidTarget);
  }

  return _composePlan(
    intent,
    stack,
    c,
    kind: switch (intent.verb) {
      StackComposeVerb.pullService => OperationKind.stackServicePull,
      StackComposeVerb.recreateService => OperationKind.stackServiceRecreate,
      StackComposeVerb.scaleService => OperationKind.stackServiceScale,
      StackComposeVerb.down => OperationKind.composeDown,
    },
    targetName: service == null
        ? stack.project.name
        : '${stack.project.name}/$service',
    steps: (files) => [
      ShellStep(
        switch (intent.verb) {
          StackComposeVerb.pullService => composePull(
            socketPath: files.socketPath,
            project: files.project,
            projectDirectory: files.projectDirectory,
            configFiles: files.configFiles,
            envFiles: files.envFiles,
            services: [service!],
          ),
          StackComposeVerb.recreateService => composeUp(
            socketPath: files.socketPath,
            project: files.project,
            projectDirectory: files.projectDirectory,
            configFiles: files.configFiles,
            envFiles: files.envFiles,
            forceRecreate: true,
            noDeps: true,
            services: [service!],
          ),
          StackComposeVerb.scaleService => composeUp(
            socketPath: files.socketPath,
            project: files.project,
            projectDirectory: files.projectDirectory,
            configFiles: files.configFiles,
            envFiles: files.envFiles,
            noDeps: true,
            scale: {service!: replicas!},
            services: [service],
          ),
          StackComposeVerb.down => composeDown(
            socketPath: files.socketPath,
            project: files.project,
            projectDirectory: files.projectDirectory,
            configFiles: files.configFiles,
            envFiles: files.envFiles,
          ),
        }.argv,
      ),
    ],
  );
}

/// The compose files a stack's labels record and the socket the engine
/// listens on: every step names them all.
typedef _ComposeFiles = ({
  String socketPath,
  String project,
  String? projectDirectory,
  List<String> configFiles,
  List<String> envFiles,
});

/// What [_verify] found: a reason not to act, or the stack to act on.
sealed class _Verification {}

final class _Refusal extends _Verification {
  _Refusal(this.reason);

  final ActionRefusalReason reason;
}

/// A verified, unmanaged project: its containers but one-off ones, and
/// the services its files name.
final class _VerifiedStack extends _Verification {
  _VerifiedStack(this.project, this.containers, this.named);

  final ComposeProject project;
  final List<ContainerSummary> containers;
  final Set<String> named;
}

/// The checks every planned compose operation passes (03 §7.16): the
/// project exists, no other manager owns it, its files verify and name
/// its services.
Future<_Verification> _verify(String name, RedeployPlanContext c) async {
  final listed = (await c.client.listContainers(
    filters: {
      'label': ['${ComposeLabelKeys.project}=$name'],
    },
  )).value;
  final project = groupComposeProjects(listed).project(name);
  if (project == null) return _Refusal(ActionRefusalReason.invalidTarget);
  // The set the stack re-validation fingerprints: one-off containers
  // keep the hash of the run that made them, and compose leaves them be.
  final containers = [
    for (final container in listed)
      if (ComposeLabels.fromContainerLabels(container.labels) case final labels?
          when labels.project == name && !labels.isOneOff)
        container,
  ];
  if (containers.isEmpty) return _Refusal(ActionRefusalReason.invalidTarget);

  if (stackOwnership(containers.map((c) => c.labels)) != null) {
    return _Refusal(ActionRefusalReason.stackManaged);
  }
  switch (await c.stacks.verdict(project)) {
    case StackVerified():
      break;
    case StackUnverified(reason: StackUnverifiedReason.standaloneComposeOnly):
      return _Refusal(ActionRefusalReason.legacyComposeOnly);
    case _:
      return _Refusal(ActionRefusalReason.stackUnverified);
  }

  final named = await c.stacks.serviceNames(project);
  if (named == null) return _Refusal(ActionRefusalReason.stackUnverified);
  return _VerifiedStack(project, containers, named);
}

/// The level the Docker CLI runs at on [c]'s route: only the sudo relay
/// (rank 3, E16) needs root, since its socket refuses the login user,
/// whom the CLI would otherwise run as.
RequiredLevel _cliLevel(RedeployPlanContext c) =>
    c.route.rank == DockerRank.sudoRelay
    ? RequiredLevel.admin
    : RequiredLevel.login;

/// The detached runner row the host and admin mode allow at [level]
/// (03 §7.17), or why none can run.
Future<RunnerChoice> _detachedRunner(
  RedeployPlanContext c,
  RequiredLevel level,
) async {
  final choice = selectDetachedRunner(
    profile: c.profile,
    level: level,
    adminMode: c.adminMode,
  );
  // A row that elevates its launch needs a sudo rule for the program it
  // elevates; without one, the rows that elevate nothing remain.
  final program = switch (choice.runner) {
    final runner? => elevatedProgram(runner),
    null => null,
  };
  if (program == null || await c.sudoAllows(program)) return choice;
  return selectDetachedRunner(
    profile: c.profile,
    level: level,
    adminMode: c.adminMode,
    sudoCoversRunners: false,
  );
}

ActionRefusalReason _detachedRefusal(DetachedRefusal refusal) =>
    switch (refusal) {
      DetachedRefusal.adminRequired => ActionRefusalReason.adminRequired,
      DetachedRefusal.sudoRightMissing => ActionRefusalReason.sudoRightMissing,
    };

/// REG-01: the host's own `docker pull`, which uses the host's
/// `docker login` and credential helpers that the daemon never reads
/// (03 §7.14). In the foreground it runs over the link and ends with its
/// channel, its output shown at the end; detached it is an operation
/// that outlives the view (03 §7.17), followed through its log.
Future<PlanAttempt> planHostPull(
  PullImage intent,
  RedeployPlanContext c,
) async {
  final reference = intent.reference;
  if (!validImageReference(reference) || intent.via == PullRoute.engine) {
    return _refused(ActionRefusalReason.invalidTarget);
  }

  final argv = dockerPull(
    socketPath: c.route.socketPath,
    reference: reference,
  ).argv;
  final level = _cliLevel(c);
  final engine = '${c.route.runtime.name} ${c.route.socketPath}';
  if (intent.via == PullRoute.host) {
    final elevated = level == RequiredLevel.admin;
    return (
      plan: OperationPlan(
        intent: intent,
        kind: OperationKind.pullImage,
        targetName: reference,
        steps: [ShellStep(argv, elevated: elevated, captureOutput: true)],
        requiredLevel: level,
        runner: RunnerFacts(
          identity: elevated ? 'root' : c.loginUser,
          engine: engine,
          credentials: elevated
              ? RunnerCredentials.adminPassword
              : RunnerCredentials.session,
        ),
        hostWrites: const [HostWriteRow.engineState],
      ),
      refusal: null,
    );
  }

  final choice = await _detachedRunner(c, level);
  final runner = choice.runner;
  if (runner == null) return _refused(_detachedRefusal(choice.refusal!));
  return (
    plan: OperationPlan(
      intent: intent,
      kind: OperationKind.pullImage,
      targetName: reference,
      steps: [ShellStep(argv)],
      requiredLevel: level,
      runner: RunnerFacts(
        identity: runner.runsAsRoot ? 'root' : c.loginUser,
        engine: engine,
        credentials: runner.elevated
            ? RunnerCredentials.adminPassword
            : RunnerCredentials.session,
      ),
      hostWrites: [
        HostWriteRow.engineState,
        runner.runsAsRoot
            ? HostWriteRow.rootOperationRecords
            : HostWriteRow.userOperationRecords,
        if (runner.transientUnit) HostWriteRow.transientUnit,
      ],
      detachedRunner: runner,
      warnings: [if (choice.mayDieAtLogout) PlanWarning.mayDieAtLogout],
    ),
    refusal: null,
  );
}

/// The detached operation that runs [steps] after `config -q` on
/// [stack], with the runner row the host and admin mode allow, or why
/// none can run it.
Future<PlanAttempt> _composePlan(
  ActionIntent intent,
  _VerifiedStack stack,
  RedeployPlanContext c, {
  required OperationKind kind,
  required String targetName,
  required List<ShellStep> Function(_ComposeFiles files) steps,
  List<String> orphans = const [],
  List<PlanWarning> warnings = const [],
}) async {
  // The files were read as the login user to verify them either way.
  final level = _cliLevel(c);
  final choice = await _detachedRunner(c, level);
  final runner = choice.runner;
  if (runner == null) return _refused(_detachedRefusal(choice.refusal!));

  final project = stack.project;
  final List<String> hashArgv;
  final List<PlanStep> planSteps;
  try {
    final files = (
      socketPath: c.route.socketPath,
      project: project.name,
      projectDirectory: project.workingDir,
      configFiles: project.configFiles,
      envFiles: project.environmentFiles,
    );
    hashArgv = composeConfig(
      socketPath: files.socketPath,
      project: files.project,
      projectDirectory: files.projectDirectory,
      configFiles: files.configFiles,
      envFiles: files.envFiles,
      hash: '*',
    ).argv;
    planSteps = [
      ShellStep(
        composeConfig(
          socketPath: files.socketPath,
          project: files.project,
          projectDirectory: files.projectDirectory,
          configFiles: files.configFiles,
          envFiles: files.envFiles,
          quiet: true,
        ).argv,
        discardOutput: true,
      ),
      ...steps(files),
    ];
  } on ArgumentError {
    // Verification builds the same invocation, so this is a label that
    // changed in between.
    return _refused(ActionRefusalReason.stackUnverified);
  }

  final containers = stack.containers;
  ProtectedReason? protected = stackProtection(project.name, c.protection);
  for (final container in containers) {
    protected ??= containerProtection(
      name: _nameOf(container),
      ports: container.ports,
      context: c.protection,
    );
  }
  return (
    plan: OperationPlan(
      intent: intent,
      kind: kind,
      targetName: targetName,
      steps: planSteps,
      requiredLevel: level,
      runner: RunnerFacts(
        identity: runner.runsAsRoot ? 'root' : c.loginUser,
        engine: '${c.route.runtime.name} ${c.route.socketPath}',
        credentials: runner.elevated
            ? RunnerCredentials.adminPassword
            : RunnerCredentials.session,
      ),
      hostWrites: [
        HostWriteRow.engineState,
        runner.runsAsRoot
            ? HostWriteRow.rootOperationRecords
            : HostWriteRow.userOperationRecords,
        if (runner.transientUnit) HostWriteRow.transientUnit,
      ],
      detachedRunner: runner,
      impact: stackImpact(
        runningContainers: containers.where((c) => c.state == _running).length,
      ),
      protected: protected,
      orphans: orphans,
      warnings: [
        ...warnings,
        if (choice.mayDieAtLogout) PlanWarning.mayDieAtLogout,
      ],
      revalidate: [
        DockerTargetUnchanged(
          DockerTargetKind.stack,
          project.name,
          stackFingerprint(containers),
        ),
        StackConfigUnchanged(hashArgv, _labelHashes(containers, stack.named)),
      ],
    ),
    refusal: null,
  );
}

/// Checks [check] through [stacks]: null while `config --hash '*'` still
/// prints every service's hash the preview saw.
Future<RevalidationFailure?> revalidateStackConfig(
  StackSources stacks,
  StackConfigUnchanged check,
) async {
  final hashes = await stacks.serviceHashes(check.hashArgv);
  if (hashes == null) return RevalidationFailure.unreadable;
  for (final MapEntry(key: service, value: hash) in check.hashes.entries) {
    if (hashes[service] != hash) return RevalidationFailure.targetChanged;
  }
  return null;
}

/// The argv a detached operation runs for [plan]'s steps: each step's
/// command line, the next only once it succeeded, so the operation's exit
/// status is the first failure's.
List<String> detachedArgv(OperationPlan plan) => [
  '/bin/sh',
  '-c',
  [
    for (final step in plan.steps)
      switch (step) {
        ShellStep(:final commandLine) => commandLine,
        ApiStep() ||
        ExecStep() => throw ArgumentError('a detached step runs in a shell'),
      },
  ].join(' && '),
];

/// The hash of each service the files [named] from its containers'
/// labels; a verified stack has one per such service. `config --hash`
/// prints the services `config --services` does.
Map<String, String> _labelHashes(
  List<ContainerSummary> containers,
  Set<String> named,
) => {
  for (final container in containers)
    if (ComposeLabels.fromContainerLabels(container.labels) case ComposeLabels(
      :final service?,
      :final configHash?,
    ) when named.contains(service))
      service: configHash,
};

String _nameOf(ContainerSummary container) {
  final name = container.names.isEmpty ? container.id : container.names.first;
  return name.startsWith('/') ? name.substring(1) : name;
}

PlanAttempt _refused(ActionRefusalReason reason) =>
    (plan: null, refusal: reason);
