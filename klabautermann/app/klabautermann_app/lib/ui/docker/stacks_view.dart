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
