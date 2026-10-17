import 'package:klabautermann_core/klabautermann_core.dart'
    show
        ComposeProject,
        DockerStacksPayload,
        HealthStatus,
        StackVerdict,
        StackVerifying;

import 'containers_view.dart' show containerIsUp;

/// [project]'s source verdict in [stacks] (03 §7.16 STK-01): one the
/// engine has not sent yet reads as being checked, as the engine sends
/// an unchecked project.
StackVerdict stackVerdictOf(DockerStacksPayload stacks, String project) =>
    stacks.verdicts[project] ?? const StackVerifying();

/// What a stack's row counts (STK-02): its services, its containers,
/// how many of them are up, and how many report unhealthy.
typedef StackCounts = ({int services, int containers, int up, int unhealthy});

/// [project]'s counts, one-off containers among them.
StackCounts stackCountsOf(ComposeProject project) {
  final containers = project.containers;
  return (
    services: project.services.length,
    containers: containers.length,
    up: containers.where(containerIsUp).length,
    unhealthy: containers
        .where((container) => container.health == HealthStatus.unhealthy)
        .length,
  );
}

/// The project named [name] in [stacks], if listed.
ComposeProject? stackNamed(DockerStacksPayload? stacks, String name) =>
    stacks?.grouping.project(name);

/// What a stack file is to compose: a compose file, or an environment
/// file it interpolates and passes on.
enum StackFileRole { compose, environment }

/// One file of a stack the file view offers.
typedef StackFile = ({String path, StackFileRole role});

/// The name compose reads a project's environment file by, in its
/// working directory.
const _dotEnv = '.env';

/// [project]'s files the engine reads (03 §7.16 STK-04): its compose
/// files, its recorded environment files, and the `.env` in its working
/// directory, in that order and each once, as the engine's own rule
/// names them. The `.env` may not exist; reading it then says so.
List<StackFile> stackFilesOf(ComposeProject project) {
  final directory = project.workingDir;
  final dotEnv = directory == null
      ? null
      : directory.endsWith('/')
      ? '$directory$_dotEnv'
      : '$directory/$_dotEnv';
  final seen = <String>{};
  return [
    for (final path in project.configFiles)
      if (seen.add(path)) (path: path, role: StackFileRole.compose),
    for (final path in [...project.environmentFiles, ?dotEnv])
      if (seen.add(path)) (path: path, role: StackFileRole.environment),
  ];
}

/// [path]'s last segment: the file's name.
String stackFileName(String path) => path.substring(path.lastIndexOf('/') + 1);
