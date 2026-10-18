// The Docker action planners (M4 E15): CTR-02's state changes, CTR-06's
// removal, IMG-02's image removal and STK-03's stack verbs. Each reads its
// target over the server's Docker endpoint at planning time and builds
// one plan of exact API steps addressed by full id, which the runner
// re-validates by inspect before the first one runs (03 §8.5).
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:meta/meta.dart';

import '../../engine/protocol.dart';
import '../confirmation.dart';
import '../impact.dart';
import '../operation_plan.dart';
import '../ownership.dart';
import '../plan_types.dart';
import '../protected_targets.dart';

/// What planning on one server's Docker endpoint sees: its client and
/// route, the session's protected targets and the login user.
typedef DockerPlanContext = ({
  DockerClient client,
  DockerEndpointRoute route,
  ProtectionContext protection,
  String loginUser,
});

/// Docker's answer to starting a running container or stopping a stopped
/// one: nothing to do, which the runner counts as done.
const kDockerNotModified = 304;

const _running = 'running';

const _containerKinds = {
  ContainerVerb.start: OperationKind.start,
  ContainerVerb.stop: OperationKind.stop,
  ContainerVerb.restart: OperationKind.restart,
  ContainerVerb.pause: OperationKind.pause,
  ContainerVerb.unpause: OperationKind.unpause,
  ContainerVerb.kill: OperationKind.kill,
};

const _stackKinds = {
  StackVerb.start: OperationKind.stackStart,
  StackVerb.stop: OperationKind.stackStop,
  StackVerb.restart: OperationKind.stackRestart,
};

/// Plans [intent], a Docker action, or says why it cannot be planned.
Future<PlanAttempt> planDockerAction(
  ActionIntent intent,
  DockerPlanContext context,
) async {
  try {
    return switch (intent) {
      ContainerAction() => await _planContainer(intent, context),
      RemoveContainer() => await _planRemoveContainer(intent, context),
      RemoveImage() => await _planRemoveImage(intent, context),
      StackAction() => await _planStack(intent, context),
      _ => _refused(ActionRefusalReason.notImplemented),
    };
  } on DockerNotFoundException {
    return _refused(ActionRefusalReason.targetChanged);
  }
}

/// CTR-02: one state change on the container the id names now.
Future<PlanAttempt> _planContainer(
  ContainerAction intent,
  DockerPlanContext c,
) async {
  if (intent.signal != null && intent.verb != ContainerVerb.kill) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final container = await _container(c.client, intent.containerId);
  if (container == null) return _refused(ActionRefusalReason.targetChanged);
  final name = _nameOf(container);
  final protected = containerProtection(
    name: name,
    ports: container.ports,
    context: c.protection,
  );
  final interrupts = switch (intent.verb) {
    ContainerVerb.start || ContainerVerb.unpause => false,
    _ => true,
  };
  return _planned(
    OperationPlan(
      intent: intent,
      kind: _containerKinds[intent.verb]!,
      targetName: name,
      steps: [
        ApiStep(
          method: 'POST',
          path: _path(c, '/containers/${container.id}/${intent.verb.name}'),
          query: {
            if (intent.signal case final signal?) 'signal': signal.wireName,
          },
        ),
      ],
      requiredLevel: RequiredLevel.login,
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: interrupts ? _containerImpact(protected) : null,
      ownership: containerOwnership(container.labels),
      protected: protected,
      revalidate: [
        DockerTargetUnchanged(DockerTargetKind.container, name, container.id),
      ],
    ),
  );
}

/// CTR-06: removing the container, its anonymous volumes with `v=1`,
/// which needs the typed confirmation.
Future<PlanAttempt> _planRemoveContainer(
  RemoveContainer intent,
  DockerPlanContext c,
) async {
  final container = await _container(c.client, intent.containerId);
  if (container == null) return _refused(ActionRefusalReason.targetChanged);
  final name = _nameOf(container);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: intent.volumes
          ? OperationKind.removeContainerWithVolumes
          : OperationKind.removeContainer,
      targetName: name,
      steps: [
        ApiStep(
          method: 'DELETE',
          path: _path(c, '/containers/${container.id}'),
          query: {
            'v': intent.volumes ? '1' : '0',
            'force': intent.force ? '1' : '0',
          },
        ),
      ],
      requiredLevel: RequiredLevel.login,
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: containerRemovalImpact(volumes: intent.volumes),
      ownership: containerOwnership(container.labels),
      protected: containerProtection(
        name: name,
        ports: container.ports,
        context: c.protection,
      ),
      revalidate: [
        DockerTargetUnchanged(DockerTargetKind.container, name, container.id),
      ],
    ),
  );
}

/// IMG-02: an unused image is removed after a plain confirmation; one in
/// use only with `force`, which needs the typed one. The in-use count is
/// the image list's from API 1.51, the container list's before.
Future<PlanAttempt> _planRemoveImage(
  RemoveImage intent,
  DockerPlanContext c,
) async {
  if (intent.image.isEmpty) return _refused(ActionRefusalReason.invalidTarget);
  final image = (await c.client.inspectImage(intent.image)).value;
  final inUse = await _imageUsers(c.client, image.id);
  if (inUse > 0 && !intent.force) {
    return _refused(ActionRefusalReason.imageInUse);
  }
  // A tag removes that tag; an id or digest removes the image itself.
  final reference = image.repoTags.contains(intent.image)
      ? intent.image
      : image.id;
  return _planned(
    OperationPlan(
      intent: intent,
      kind: inUse > 0
          ? OperationKind.forceRemoveImageInUse
          : OperationKind.removeUnusedImage,
      targetName: intent.image,
      steps: [
        ApiStep(
          method: 'DELETE',
          path: _path(c, '/images/${Uri.encodeComponent(reference)}'),
          query: {'force': intent.force ? '1' : '0', 'noprune': '0'},
        ),
      ],
      requiredLevel: RequiredLevel.login,
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: imageRemovalImpact(usingContainers: inUse),
      revalidate: [
        DockerTargetUnchanged(DockerTargetKind.image, intent.image, image.id),
      ],
    ),
  );
}

/// STK-03: every container of the project, services in dependency order
/// (`com.docker.compose.depends_on`), reversed for stop; one-off
/// containers are left alone and a dependency cycle refuses.
Future<PlanAttempt> _planStack(StackAction intent, DockerPlanContext c) async {
  final containers = await _projectContainers(c.client, intent.project);
  if (containers.isEmpty) return _refused(ActionRefusalReason.invalidTarget);

  final byService = <String, List<ContainerSummary>>{};
  final dependsOn = <String, Set<String>>{};
  for (final container in containers) {
    final labels = ComposeLabels.fromContainerLabels(container.labels);
    final service = labels?.service;
    if (labels == null || service == null) continue;
    byService.putIfAbsent(service, () => []).add(container);
    dependsOn.putIfAbsent(service, () => {}).addAll(labels.dependsOnServices);
  }
  final order = dependencyOrder(dependsOn);
  if (order == null) return _refused(ActionRefusalReason.dependencyCycle);

  final services = intent.verb == StackVerb.stop ? order.reversed : order;
  final steps = [
    for (final service in services)
      for (final container in byService[service]!..sort(_byName))
        ApiStep(
          method: 'POST',
          path: _path(c, '/containers/${container.id}/${intent.verb.name}'),
        ),
  ];
  final targets = [for (final s in services) ...byService[s]!];
  ProtectedReason? protected = stackProtection(intent.project, c.protection);
  for (final container in targets) {
    protected ??= containerProtection(
      name: _nameOf(container),
      ports: container.ports,
      context: c.protection,
    );
  }
  final running = targets.where((t) => t.state == _running).length;
  return _planned(
    OperationPlan(
      intent: intent,
      kind: _stackKinds[intent.verb]!,
      targetName: intent.project,
      steps: steps,
      requiredLevel: RequiredLevel.login,
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: intent.verb == StackVerb.start
          ? null
          : stackImpact(runningContainers: running),
      ownership: stackOwnership(targets.map((t) => t.labels)),
      protected: protected,
      revalidate: [
        DockerTargetUnchanged(
          DockerTargetKind.stack,
          intent.project,
          stackFingerprint(containers),
        ),
      ],
    ),
  );
}

/// The services of [dependsOn] (service to the services it depends on)
/// with each after its dependencies, ties by name; null when they form a
/// cycle. A dependency outside the project (a one-off's, or one removed
/// from the file) does not order anything.
@visibleForTesting
List<String>? dependencyOrder(Map<String, Set<String>> dependsOn) {
  final pending = {
    for (final MapEntry(:key, :value) in dependsOn.entries)
      key: value.where(dependsOn.containsKey).toSet()..remove(key),
  };
  final order = <String>[];
  while (pending.isNotEmpty) {
    final ready = [
      for (final MapEntry(:key, :value) in pending.entries)
        if (value.isEmpty) key,
    ]..sort();
    if (ready.isEmpty) return null;
    for (final service in ready) {
      pending.remove(service);
      for (final deps in pending.values) {
        deps.remove(service);
      }
    }
    order.addAll(ready);
  }
  return order;
}

/// The stack's identity for re-validation: its containers' ids, so one
/// added, removed or recreated since the preview changes it.
String stackFingerprint(Iterable<ContainerSummary> containers) =>
    (containers.map((c) => c.id).toList()..sort()).join(',');

/// Runs [step] on [client] exactly as the preview showed it and returns
/// the HTTP status; Docker's "not modified" counts as done (the container
/// was already in the state the step asks for). Transport failures
/// propagate.
Future<int> runApiStep(DockerClient client, ApiStep step) async {
  try {
    final response = await client.request(
      step.method,
      step.path,
      query: step.query,
      versioned: false,
    );
    return response.statusCode;
  } on DockerApiException catch (e) {
    return e.statusCode == kDockerNotModified ? 200 : e.statusCode;
  }
}

/// Checks [check] against the engine: null while the target still has
/// the id the preview saw.
Future<RevalidationFailure?> revalidateDockerTarget(
  DockerClient client,
  DockerTargetUnchanged check,
) async {
  try {
    final id = switch (check.kind) {
      DockerTargetKind.container => (await client.inspectContainer(
        check.target,
      )).value.id,
      DockerTargetKind.image => (await client.inspectImage(
        check.target,
      )).value.id,
      DockerTargetKind.stack => stackFingerprint(
        await _projectContainers(client, check.target),
      ),
    };
    return id == check.id ? null : RevalidationFailure.targetChanged;
  } on DockerNotFoundException {
    return RevalidationFailure.targetChanged;
  } on DockerApiException {
    return RevalidationFailure.unreadable;
  }
}

/// The container [idOrName] names now, by its full id: the list filtered
/// to it, so the plan has its ports and labels in one read. Null when no
/// container, or more than one, matches.
Future<ContainerSummary?> _container(
  DockerClient client,
  String idOrName,
) async {
  if (idOrName.isEmpty) return null;
  final inspected = (await client.inspectContainer(idOrName)).value;
  final listed = (await client.listContainers(
    filters: {
      'id': [inspected.id],
    },
  )).value;
  return listed.length == 1 && listed.single.id == inspected.id
      ? listed.single
      : null;
}

Future<List<ContainerSummary>> _projectContainers(
  DockerClient client,
  String project,
) async {
  final listed = (await client.listContainers(
    filters: {
      'label': ['${ComposeLabelKeys.project}=$project'],
    },
  )).value;
  return [
    for (final container in listed)
      if (ComposeLabels.fromContainerLabels(container.labels) case final labels?
          when labels.project == project && !labels.isOneOff)
        container,
  ];
}

/// How many containers use image [imageId].
Future<int> _imageUsers(DockerClient client, String imageId) async {
  if (client.gates.hasImageContainersCount) {
    final images = (await client.listImages(all: true)).value;
    for (final image in images) {
      // Docker reports -1 when it did not count.
      final count = image.containers;
      if (image.id == imageId && count != null && count >= 0) return count;
    }
  }
  final containers = (await client.listContainers()).value;
  return containers.where((c) => c.imageId == imageId).length;
}

String _nameOf(ContainerSummary container) {
  final name = container.names.isEmpty ? container.id : container.names.first;
  return name.startsWith('/') ? name.substring(1) : name;
}

int _byName(ContainerSummary a, ContainerSummary b) =>
    _nameOf(a).compareTo(_nameOf(b));

PlanImpact _containerImpact(ProtectedReason? protected) =>
    protected == ProtectedReason.publishesSessionPort
    ? const PlanImpact(ImpactKind.dropsSession)
    : const PlanImpact(ImpactKind.interruptsTarget);

/// [path] under the endpoint's negotiated version, as the runner sends it.
String _path(DockerPlanContext c, String path) =>
    '/${c.client.apiVersion.pathSegment}$path';

RunnerFacts _runner(DockerPlanContext c) => RunnerFacts(
  identity: c.loginUser,
  engine: '${c.route.runtime.name} ${c.route.socketPath}',
);

PlanAttempt _planned(OperationPlan plan) => (plan: plan, refusal: null);

PlanAttempt _refused(ActionRefusalReason reason) =>
    (plan: null, refusal: reason);
