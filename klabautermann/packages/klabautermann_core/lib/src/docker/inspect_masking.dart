/// What the engine masks in a Docker read before it crosses (03 §8.9):
/// an inspected container's command line and health-check output, read
/// as Processes reads a command line, the list's command line, which
/// the list drops, and the instruction of each layer of an image's
/// history.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show
        ContainerConfig,
        ContainerHealth,
        ContainerInspect,
        ContainerState,
        ContainerSummary,
        ImageHistoryEntry,
        MaskedValue;

import '../engine/protocol.dart';
import '../sampling/argument_masking.dart';

/// [inspect] as it may cross. `Args` are masked as the words after the
/// program `Path`, which crosses as it is. `Entrypoint` and `Cmd`, the
/// command the container was created with, are masked as one command
/// line, so an option in one and its value in the next still mask. Each health check's output is masked as one
/// argument. One budget bounds the tokens read across them all.
ContainerDetails maskContainerInspect(ContainerInspect inspect) {
  final budget = ArgumentMaskingBudget();
  return ContainerDetails(
    id: inspect.id,
    name: inspect.name,
    created: inspect.created,
    image: inspect.image,
    platform: inspect.platform,
    restartCount: inspect.restartCount,
    path: inspect.path,
    args: _maskAfterProgram(inspect.path, inspect.args, budget),
    state: switch (inspect.state) {
      null => null,
      final state => _maskState(state, budget),
    },
    config: switch (inspect.config) {
      null => null,
      final config => _maskConfig(config, budget),
    },
    hostConfig: inspect.hostConfig,
    mounts: inspect.mounts,
    networkSettings: inspect.networkSettings,
  );
}

/// [history] as it may cross (02 IMG-04): each layer's instruction, such
/// as `RUN |1 TOKEN=abc /bin/sh -c ...` or `ENV API_KEY=...`, masked as
/// one command line, its first word read as the program. One budget
/// bounds the tokens read across the layers.
List<ImageLayer> maskImageHistory(List<ImageHistoryEntry> history) {
  final budget = ArgumentMaskingBudget();
  return [
    for (final entry in history)
      ImageLayer(
        id: entry.id,
        created: entry.created,
        createdBy: entry.createdBy.isEmpty
            ? MaskedValue.plain('')
            : maskCommandLine([entry.createdBy], budget: budget).single,
        size: entry.size,
        comment: entry.comment,
        tags: entry.tags,
      ),
  ];
}

/// [summaries] without their command lines, which [maskContainerInspect]
/// carries masked; a list row shows no command (CTR-01).
List<ContainerSummary> withoutCommands(List<ContainerSummary> summaries) => [
  for (final s in summaries)
    ContainerSummary(
      id: s.id,
      names: s.names,
      image: s.image,
      imageId: s.imageId,
      created: s.created,
      ports: s.ports,
      labels: s.labels,
      state: s.state,
      status: s.status,
      health: s.health,
      mounts: s.mounts,
      networkMode: s.networkMode,
      networks: s.networks,
      sizeRw: s.sizeRw,
      sizeRootFs: s.sizeRootFs,
    ),
];

/// [arguments] masked as the words after [program], which is read as the
/// program and dropped; with no program the first argument is the
/// program.
List<MaskedValue> _maskAfterProgram(
  String? program,
  List<String> arguments,
  ArgumentMaskingBudget budget,
) {
  if (program == null) return maskCommandLine(arguments, budget: budget);
  return maskCommandLine([program, ...arguments], budget: budget).sublist(1);
}

ContainerDetailsState _maskState(
  ContainerState state,
  ArgumentMaskingBudget budget,
) => ContainerDetailsState(
  status: state.status,
  running: state.running,
  paused: state.paused,
  restarting: state.restarting,
  oomKilled: state.oomKilled,
  dead: state.dead,
  pid: state.pid,
  exitCode: state.exitCode,
  error: state.error,
  startedAt: state.startedAt,
  finishedAt: state.finishedAt,
  health: switch (state.health) {
    null => null,
    final health => _maskHealth(health, budget),
  },
);

ContainerDetailsHealth _maskHealth(
  ContainerHealth health,
  ArgumentMaskingBudget budget,
) => ContainerDetailsHealth(
  status: health.status,
  failingStreak: health.failingStreak,
  log: [
    for (final check in health.log)
      ContainerHealthCheck(
        start: check.start,
        end: check.end,
        exitCode: check.exitCode,
        // Read as an argument after an empty program, so the output's
        // first word is never taken for the program.
        output: switch (check.output) {
          null => null,
          final output => maskCommandLine(['', output], budget: budget)[1],
        },
      ),
  ],
);

ContainerDetailsConfig _maskConfig(
  ContainerConfig config,
  ArgumentMaskingBudget budget,
) {
  final command = maskCommandLine([
    ...config.entrypoint,
    ...config.cmd,
  ], budget: budget);
  final split = config.entrypoint.length;
  return ContainerDetailsConfig(
    hostname: config.hostname,
    image: config.image,
    user: config.user,
    workingDir: config.workingDir,
    stopSignal: config.stopSignal,
    tty: config.tty,
    env: config.env,
    entrypoint: command.sublist(0, split),
    cmd: command.sublist(split),
    labels: config.labels,
  );
}
