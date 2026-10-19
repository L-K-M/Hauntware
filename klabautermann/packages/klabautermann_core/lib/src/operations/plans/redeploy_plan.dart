// STK-06's pull and redeploy (03 §7.16, M4 E18, M10): a verified,
// unmanaged stack's compose commands rebuilt from its labels, run as one
// detached operation (03 §7.17) against the engine the endpoint found.
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
import 'docker_plans.dart' show stackFingerprint;

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
  final listed = (await c.client.listContainers(
    filters: {
      'label': ['${ComposeLabelKeys.project}=${intent.project}'],
    },
  )).value;
  final project = groupComposeProjects(listed).project(intent.project);
  if (project == null) return _refused(ActionRefusalReason.invalidTarget);
  // The set the stack re-validation fingerprints: one-off containers
  // keep the hash of the run that made them, and compose leaves them be.
  final containers = [
    for (final container in listed)
      if (ComposeLabels.fromContainerLabels(container.labels) case final labels?
          when labels.project == intent.project && !labels.isOneOff)
        container,
  ];
  if (containers.isEmpty) return _refused(ActionRefusalReason.invalidTarget);

  if (stackOwnership(containers.map((c) => c.labels)) != null) {
    return _refused(ActionRefusalReason.stackManaged);
  }
  switch (await c.stacks.verdict(project)) {
    case StackVerified():
      break;
    case StackUnverified(reason: StackUnverifiedReason.standaloneComposeOnly):
      return _refused(ActionRefusalReason.legacyComposeOnly);
    case _:
      return _refused(ActionRefusalReason.stackUnverified);
  }

  final named = await c.stacks.serviceNames(project);
  if (named == null) return _refused(ActionRefusalReason.stackUnverified);
  final everyProfile = await c.stacks.serviceNames(project, allProfiles: true);
  final orphans = <String>[];
  var profileGated = false;
  for (final container in containers) {
    final service = ComposeLabels.fromContainerLabels(
      container.labels,
    )?.service;
    if (service == null || named.contains(service)) continue;
    if (everyProfile != null && everyProfile.contains(service)) {
      profileGated |= container.state == _running;
      continue;
    }
    orphans.add(_nameOf(container));
  }
  orphans.sort();

  // Only the sudo relay (rank 3, E16) needs root: its socket refuses the
  // login user, whom the CLI steps would otherwise run as. The files were
  // read as the login user to verify them either way.
  final level = c.route.rank == DockerRank.sudoRelay
      ? RequiredLevel.admin
      : RequiredLevel.login;
  var choice = selectDetachedRunner(
    profile: c.profile,
    level: level,
    adminMode: c.adminMode,
  );
  // A row that elevates its launch needs a sudo rule for the program it
  // elevates; without one, the rows that elevate nothing remain.
  if (choice.runner case final runner?) {
    final program = elevatedProgram(runner);
    if (program != null && !await c.sudoAllows(program)) {
      choice = selectDetachedRunner(
        profile: c.profile,
        level: level,
        adminMode: c.adminMode,
        sudoCoversRunners: false,
      );
    }
  }
  final runner = choice.runner;
  if (runner == null) {
    return _refused(switch (choice.refusal!) {
      DetachedRefusal.adminRequired => ActionRefusalReason.adminRequired,
      DetachedRefusal.sudoRightMissing => ActionRefusalReason.sudoRightMissing,
    });
  }

  final List<String> hashArgv;
  final List<PlanStep> steps;
  try {
    final socketPath = c.route.socketPath;
    final files = (
      project: project.name,
      projectDirectory: project.workingDir,
      configFiles: project.configFiles,
      envFiles: project.environmentFiles,
    );
    hashArgv = composeConfig(
      socketPath: socketPath,
      project: files.project,
      projectDirectory: files.projectDirectory,
      configFiles: files.configFiles,
      envFiles: files.envFiles,
      hash: '*',
    ).argv;
    steps = [
      ShellStep(
        composeConfig(
          socketPath: socketPath,
          project: files.project,
          projectDirectory: files.projectDirectory,
          configFiles: files.configFiles,
          envFiles: files.envFiles,
          quiet: true,
        ).argv,
        discardOutput: true,
      ),
      ShellStep(
        composePull(
          socketPath: socketPath,
          project: files.project,
          projectDirectory: files.projectDirectory,
          configFiles: files.configFiles,
          envFiles: files.envFiles,
        ).argv,
      ),
      ShellStep(
        composeUp(
          socketPath: socketPath,
          project: files.project,
          projectDirectory: files.projectDirectory,
          configFiles: files.configFiles,
          envFiles: files.envFiles,
          removeOrphans: intent.removeOrphans,
        ).argv,
      ),
    ];
  } on ArgumentError {
    // Verification builds the same invocation, so this is a label that
    // changed in between.
    return _refused(ActionRefusalReason.stackUnverified);
  }

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
      kind: intent.removeOrphans
          ? OperationKind.redeployRemovingOrphans
          : OperationKind.redeploy,
      targetName: project.name,
      steps: steps,
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
        if (profileGated) PlanWarning.profileGatedServices,
        if (everyProfile == null && orphans.isNotEmpty)
          PlanWarning.profilesUnknown,
        if (choice.mayDieAtLogout) PlanWarning.mayDieAtLogout,
      ],
      revalidate: [
        DockerTargetUnchanged(
          DockerTargetKind.stack,
          project.name,
          stackFingerprint(containers),
        ),
        StackConfigUnchanged(hashArgv, _labelHashes(containers, named)),
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
        ApiStep() => throw ArgumentError('a detached step runs in a shell'),
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
