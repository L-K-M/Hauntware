// The Docker action planners (M4 E15): CTR-02's state changes, CTR-06's
// removal, IMG-02's image removal, STK-03's stack verbs, VOL-02's
// volume create and remove (M6 N10b), DNW-02's network removal (N11),
// DKE-05's prune (N12) and IMG-03's pull (N13). Each reads its target over the server's Docker endpoint at
// planning time and builds one plan of exact API steps addressed by full
// id, which the runner re-validates by inspect before the first one runs
// (03 §8.5).
import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:meta/meta.dart';

import '../../docker/docker_ladder.dart' show DockerRank;
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
      CreateVolume() => await _planCreateVolume(intent, context),
      RemoveVolume() => await _planRemoveVolume(intent, context),
      RemoveNetwork() => await _planRemoveNetwork(intent, context),
      PruneDocker() => await _planPrune(intent, context),
      PullImage() => _planPullImage(intent, context),
      StackAction() => await _planStack(intent, context),
      ContainerExec() => await _planExec(intent, context),
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
      requiredLevel: _level(c),
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

/// CTX-08: a one-off command in the running container the id names now.
/// A protected container, or one another manager owns, needs the typed
/// confirmation, as any action on it does.
Future<PlanAttempt> _planExec(ContainerExec intent, DockerPlanContext c) async {
  if (intent.argv.isEmpty || intent.argv.first.isEmpty) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  if (intent.user?.isEmpty ?? false) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final container = await _container(c.client, intent.containerId);
  if (container == null) return _refused(ActionRefusalReason.targetChanged);
  // The daemon refuses an exec in a container that is not running.
  if (container.state != _running) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final name = _nameOf(container);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.containerExec,
      targetName: name,
      steps: [
        ExecStep(
          path: _path(c, '/containers/${container.id}/exec'),
          containerId: container.id,
          argv: intent.argv,
          user: intent.user,
        ),
      ],
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
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
      requiredLevel: _level(c),
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
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: imageRemovalImpact(usingContainers: inUse),
      revalidate: [
        DockerTargetUnchanged(DockerTargetKind.image, intent.image, image.id),
      ],
    ),
  );
}

/// The names Docker accepts for a volume (`[a-zA-Z0-9][a-zA-Z0-9_.-]+`,
/// the daemon's `RestrictedNamePattern`). A driver is not held to it: a
/// plugin driver is a reference such as `vieux/sshfs:latest`, which the
/// daemon looks up and refuses itself when it has none.
final _volumeName = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]+$');

/// VOL-02: a new empty volume, after a plain confirmation. A name taken
/// is refused rather than sent: the engine would answer the existing
/// volume as created. For the same reason the runner checks again that
/// the name is still free right before the create.
Future<PlanAttempt> _planCreateVolume(
  CreateVolume intent,
  DockerPlanContext c,
) async {
  final driver = intent.driver;
  if (!_volumeName.hasMatch(intent.name) ||
      (driver != null && driver.trim().isEmpty)) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  try {
    await c.client.inspectVolume(intent.name);
    return _refused(ActionRefusalReason.volumeExists);
  } on DockerNotFoundException {
    // The name is free.
  }
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.createVolume,
      targetName: intent.name,
      steps: [
        ApiStep(
          method: 'POST',
          path: _path(c, '/volumes/create'),
          json: {'Name': intent.name, 'Driver': ?driver},
        ),
      ],
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      revalidate: [
        DockerTargetUnchanged(
          DockerTargetKind.volume,
          intent.name,
          kAbsentTarget,
        ),
      ],
    ),
  );
}

/// VOL-02: removing a volume deletes its data, so it needs the typed
/// confirmation (03 §7.15); one a container mounts, running or not, is
/// refused, as the engine would refuse it.
Future<PlanAttempt> _planRemoveVolume(
  RemoveVolume intent,
  DockerPlanContext c,
) async {
  if (!_volumeName.hasMatch(intent.name)) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final volume = await c.client.inspectVolume(intent.name);
  final users = (await c.client.listContainers(
    filters: {
      'volume': [intent.name],
    },
  )).value;
  if (users.isNotEmpty) return _refused(ActionRefusalReason.volumeInUse);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.removeVolume,
      targetName: intent.name,
      steps: [
        ApiStep(
          method: 'DELETE',
          path: _path(c, '/volumes/${Uri.encodeComponent(intent.name)}'),
        ),
      ],
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: const PlanImpact(ImpactKind.deletesVolumeData),
      revalidate: [
        DockerTargetUnchanged(
          DockerTargetKind.volume,
          intent.name,
          volumeFingerprint(volume),
        ),
      ],
    ),
  );
}

/// DNW-02: a user-defined network no container holds an endpoint on is
/// removed by its id after a plain confirmation; a built-in one is never
/// removed, and one in use is refused, as the engine would refuse it.
Future<PlanAttempt> _planRemoveNetwork(
  RemoveNetwork intent,
  DockerPlanContext c,
) async {
  if (intent.networkId.isEmpty) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  final network = await c.client.inspectNetwork(intent.networkId);
  if (network.isBuiltin) return _refused(ActionRefusalReason.builtinNetwork);
  if (network.containers.isNotEmpty) {
    return _refused(ActionRefusalReason.networkInUse);
  }
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.removeNetwork,
      targetName: network.name,
      steps: [
        ApiStep(
          method: 'DELETE',
          path: _path(c, '/networks/${Uri.encodeComponent(network.id)}'),
        ),
      ],
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      revalidate: [
        DockerTargetUnchanged(DockerTargetKind.network, network.id, network.id),
      ],
    ),
  );
}

/// The image references a pull accepts, loosely as Docker's reference
/// grammar has them: an optional registry host and port, path components
/// of lower-case letters and digits with `.`, `_`, `__` or `-` between,
/// then a tag, a digest or both.
final _imageReference = RegExp(
  r'^(?:[a-zA-Z0-9.-]+(?::[0-9]+)?/)?'
  r'[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*'
  r'(?:/[a-z0-9]+(?:(?:\.|_|__|-+)[a-z0-9]+)*)*'
  r'(?::\w[\w.-]{0,127})?'
  r'(?:@sha256:[a-f0-9]{64})?$',
);

/// Whether [reference] is an image reference a pull accepts.
bool validImageReference(String reference) =>
    _imageReference.hasMatch(reference);

/// IMG-03: one `POST /images/create` after a plain confirmation. The
/// daemon pulls anonymously; the runner streams its progress
/// ([runPullStep]).
PlanAttempt _planPullImage(PullImage intent, DockerPlanContext c) {
  final reference = intent.reference;
  if (!validImageReference(reference)) {
    return _refused(ActionRefusalReason.invalidTarget);
  }
  // The host's own `docker pull` is planned with the stack runners
  // ([planHostPull]).
  if (intent.via != PullRoute.engine) {
    return _refused(ActionRefusalReason.notImplemented);
  }

  final (:fromImage, :tag) = pullTarget(reference);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.pullImage,
      targetName: reference,
      steps: [
        ApiStep(
          method: 'POST',
          path: _path(c, '/images/create'),
          query: {'fromImage': fromImage, 'tag': ?tag},
        ),
      ],
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
    ),
  );
}

/// What `POST /images/create` takes for [reference]: the name, and the
/// tag after its last `:` past the last `/`. A digest reference is sent
/// whole. Without a tag the daemon would pull every tag of the name, so
/// a bare name pulls `latest`, as `docker pull` does.
({String fromImage, String? tag}) pullTarget(String reference) {
  if (reference.contains('@')) return (fromImage: reference, tag: null);
  final colon = reference.lastIndexOf(':');
  if (colon > reference.lastIndexOf('/')) {
    return (
      fromImage: reference.substring(0, colon),
      tag: reference.substring(colon + 1),
    );
  }
  return (fromImage: reference, tag: 'latest');
}

/// The running image pulls' cancel tokens by plan id (IMG-03). A cancel
/// can arrive before its pull starts, while the plan revalidates or the
/// endpoint connects; it is held, so that pull starts cancelled rather
/// than running on behind a closed sheet. Plan ids are never reused, so
/// a cancel held for a plan that never pulls only costs its id.
final class PullCancels {
  final _tokens = <String, DockerCancelToken>{};
  final _early = <String>{};

  /// The token [planId]'s pull runs with, cancelled already when a
  /// cancel came first.
  DockerCancelToken start(String planId) {
    final token = DockerCancelToken();
    _tokens[planId] = token;
    if (_early.remove(planId)) token.cancel();
    return token;
  }

  /// [planId]'s pull ended.
  void finish(String planId) => _tokens.remove(planId);

  /// Stops [planId]'s pull, now or when it starts.
  void cancel(String planId) {
    final token = _tokens[planId];
    if (token == null) {
      _early.add(planId);
    } else {
      token.cancel();
    }
  }
}

/// Whether [step] is an image pull, which [runPullStep] streams.
bool isPullStep(ApiStep step) =>
    step.method == 'POST' && step.path.endsWith('/images/create');

/// A layer's id in a pull's messages: the first 12 hex digits of its
/// digest. Other ids name the tag being pulled.
final _layerId = RegExp(r'^[a-f0-9]{12}$');

/// Runs the pull [step] on [client], reporting its layers to [onProgress]
/// at most once per [interval] and once more at the end (03 §7.14
/// IMG-03). [cancel] closes the request, which cancels the pull on the
/// daemon unless another client pulls the same image; the call then
/// throws [DockerCancelledException]. An `errorDetail` in the stream, or
/// an error answer, throws [ApiStepError] with the daemon's words.
Future<int> runPullStep(
  DockerClient client,
  ApiStep step, {
  required DockerCancelToken cancel,
  required void Function(List<PullLayer> layers, String? status) onProgress,
  Duration interval = const Duration(milliseconds: 250),
}) async {
  // Insertion order is the order the daemon first named each layer.
  final layers = <String, PullLayer>{};
  String? status;
  final clock = Stopwatch()..start();
  Duration? sent;
  void report({bool last = false}) {
    if (!last && sent != null && clock.elapsed - sent! < interval) return;
    sent = clock.elapsed;
    onProgress(List.of(layers.values), status);
  }

  try {
    final response = await client.requestJsonValues(
      step.method,
      step.path,
      query: step.query,
      versioned: false,
      cancelToken: cancel,
    );
    await for (final value in response.body) {
      final message = parsePullProgress(value).value;
      if (message.isError) {
        throw ApiStepError(message.errorDetail ?? message.error!);
      }
      final id = message.id;
      if (id != null && _layerId.hasMatch(id)) {
        layers[id] = PullLayer(
          id,
          status: message.status,
          current: message.progressDetail?.current,
          total: message.progressDetail?.total,
        );
      } else if (message.status case final text?) {
        status = id == null ? text : '$id: $text';
      }
      report();
    }
    report(last: true);
    return response.statusCode;
  } on DockerApiException catch (e) {
    throw ApiStepError(
      e.daemonMessage ?? 'HTTP ${e.statusCode}',
      status: e.statusCode,
    );
  }
}

/// DKE-05, IMG-06: the objects a prune's filters match now are listed with
/// what they leave and why, and the prune runs after the typed
/// confirmation. The runner reads the same list again before the step
/// and refuses when it changed, so what runs is what the preview showed;
/// the build cache, whose records carry no ids to compare, is the
/// exception.
Future<PlanAttempt> _planPrune(PruneDocker intent, DockerPlanContext c) async {
  final preview = await prunePreview(c.client, intent.kind, all: intent.all);
  if (preview.count == 0) return _refused(ActionRefusalReason.nothingToPrune);

  final target = pruneTarget(intent.kind, all: intent.all);
  return _planned(
    OperationPlan(
      intent: intent,
      kind: OperationKind.prune,
      targetName: target,
      steps: [_pruneStep(c, intent.kind, all: intent.all)],
      requiredLevel: _level(c),
      runner: _runner(c),
      hostWrites: const [HostWriteRow.engineState],
      impact: intent.kind == DockerPruneKind.volumes
          ? PlanImpact(ImpactKind.deletesVolumeData, count: preview.count)
          : null,
      prune: preview,
      revalidate: [
        // The build cache's records have no ids to compare.
        if (intent.kind != DockerPruneKind.buildCache)
          DockerTargetUnchanged(
            DockerTargetKind.prune,
            target,
            pruneFingerprint(preview),
          ),
      ],
    ),
  );
}

/// The prune [kind] names, as a typed confirmation repeats it and the
/// runner reads it back: `images-all` for every unused image.
String pruneTarget(DockerPruneKind kind, {required bool all}) => switch (kind) {
  DockerPruneKind.images when all => 'images-all',
  DockerPruneKind.buildCache => 'build-cache',
  _ => kind.name,
};

/// A prune's identity for re-validation: the names it removes, sorted.
String pruneFingerprint(PrunePreview preview) =>
    ([for (final item in preview.removes) item.name]..sort()).join('\n');

ApiStep _pruneStep(
  DockerPlanContext c,
  DockerPruneKind kind, {
  required bool all,
}) {
  String filters(Map<String, List<String>> map) => jsonEncode(map);
  return switch (kind) {
    DockerPruneKind.containers => ApiStep(
      method: 'POST',
      path: _path(c, '/containers/prune'),
    ),
    // Without `dangling=false` the engine removes dangling images only.
    DockerPruneKind.images => ApiStep(
      method: 'POST',
      path: _path(c, '/images/prune'),
      query: {
        'filters': filters({
          'dangling': [all ? 'false' : 'true'],
        }),
      },
    ),
    // From 1.42 the engine spares named volumes unless asked for all, so
    // the prune matches the preview's list of every unused one.
    DockerPruneKind.volumes => ApiStep(
      method: 'POST',
      path: _path(c, '/volumes/prune'),
      query: {
        if (c.client.gates.hasVolumePruneAll)
          'filters': filters({
            'all': ['true'],
          }),
      },
    ),
    DockerPruneKind.networks => ApiStep(
      method: 'POST',
      path: _path(c, '/networks/prune'),
    ),
    // `all` removes every record no build uses, which is what the
    // engine's reclaimable figure counts.
    DockerPruneKind.buildCache => ApiStep(
      method: 'POST',
      path: _path(c, '/build/prune'),
      query: const {'all': '1'},
    ),
  };
}

/// The container states a container prune spares: one that runs, is
/// paused or restarting, or is being removed already.
const _livingStates = {'running', 'paused', 'restarting', 'removing'};

/// The `status` filter values of the containers a container prune
/// removes.
const _stoppedStates = ['created', 'exited', 'dead'];

/// What the prune [kind] removes on [client]'s engine now, and what it
/// leaves and why (DKE-05), read with the filters the prune sends.
Future<PrunePreview> prunePreview(
  DockerClient client,
  DockerPruneKind kind, {
  required bool all,
}) async {
  switch (kind) {
    case DockerPruneKind.containers:
      // Sizes are read for the stopped ones only: the engine computes
      // each container's on request.
      final containers = (await client.listContainers(
        sizes: true,
        filters: {'status': _stoppedStates},
      )).value;
      final removes = [
        for (final container in containers)
          if (!_livingStates.contains(container.state))
            PruneItem(_nameOf(container), size: container.sizeRw),
      ];
      return PrunePreview(removes: removes, freed: _sum(removes));

    case DockerPruneKind.images:
      final used = {
        for (final container in (await client.listContainers()).value)
          ?container.imageId,
      };
      final removes = <PruneItem>[];
      final kept = <PruneKept>[];
      for (final image in (await client.listImages()).value) {
        if (!all && !_dangling(image)) continue;
        final name = _imageName(image);
        if (used.contains(image.id)) {
          kept.add(PruneKept(name, PruneExemption.inUse));
        } else {
          removes.add(PruneItem(name, size: image.size));
        }
      }
      return PrunePreview(removes: removes, kept: kept, freed: _sum(removes));

    // The volume list carries no sizes: `/system/df` sums the unused
    // ones' bytes.
    case DockerPruneKind.volumes:
      final unused = {
        for (final volume in (await client.listVolumes(
          filters: {
            'dangling': ['true'],
          },
        )).value)
          volume.name,
      };
      final every = (await client.listVolumes()).value;
      return PrunePreview(
        removes: [for (final name in unused) PruneItem(name)],
        kept: [
          for (final volume in every)
            if (!unused.contains(volume.name))
              PruneKept(volume.name, PruneExemption.inUse),
        ],
        freed: (await client.systemDf(
          type: SystemDfType.volume,
        )).value.volumes?.reclaimable,
      );

    case DockerPruneKind.networks:
      final removes = <PruneItem>[];
      final kept = <PruneKept>[];
      for (final listed in (await client.listNetworks()).value) {
        if (listed.isBuiltin) {
          kept.add(PruneKept(listed.name, PruneExemption.builtin));
          continue;
        }
        // The list leaves the endpoints out.
        final network = await client.inspectNetwork(listed.id);
        if (network.containers.isEmpty) {
          removes.add(PruneItem(network.name));
        } else {
          kept.add(PruneKept(network.name, PruneExemption.inUse));
        }
      }
      return PrunePreview(removes: removes, kept: kept);

    case DockerPruneKind.buildCache:
      final usage = (await client.systemDf(
        type: SystemDfType.buildCache,
      )).value.buildCache;
      final total = usage?.totalCount ?? 0;
      return PrunePreview(
        removes: const [],
        count: total - (usage?.activeCount ?? 0),
        freed: usage?.reclaimable,
      );
  }
}

/// An image no tag names, which a prune without `-a` removes.
bool _dangling(ImageSummary image) =>
    image.repoTags.every((tag) => tag == '<none>:<none>');

/// An image as a prune preview names it: its first tag, or its short id.
String _imageName(ImageSummary image) {
  for (final tag in image.repoTags) {
    if (tag != '<none>:<none>') return tag;
  }
  final id = image.id.startsWith('sha256:') ? image.id.substring(7) : image.id;
  return id.length > 12 ? id.substring(0, 12) : id;
}

/// The total of [items]' sizes, or null when one is unknown.
int? _sum(List<PruneItem> items) {
  var total = 0;
  for (final item in items) {
    final size = item.size;
    if (size == null) return null;
    total += size;
  }
  return total;
}

/// The identity [DockerTargetUnchanged] expects of a target that must
/// not exist yet, as a volume about to be created. No id, fingerprint or
/// timestamp reads as it, so an existing target never passes for absent.
const kAbsentTarget = '<absent>';

/// A volume's identity for re-validation: its creation time, which a
/// volume removed and created again under the same name changes.
String volumeFingerprint(VolumeSummary volume) =>
    volume.createdAt?.toUtc().toIso8601String() ?? '';

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
  // One service (STK-23) acts on its own containers alone: compose's
  // per-service restart and stop leave its dependencies running.
  final only = intent.service;
  if (only != null && !byService.containsKey(only)) {
    return _refused(ActionRefusalReason.invalidTarget);
  }

  final ordered = intent.verb == StackVerb.stop ? order.reversed : order;
  final services = [
    for (final s in ordered)
      if (only == null || s == only) s,
  ];
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
      targetName: only == null ? intent.project : '${intent.project}/$only',
      steps: steps,
      requiredLevel: _level(c),
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
      json: step.json,
      versioned: false,
    );
    return response.statusCode;
  } on DockerApiException catch (e) {
    return e.statusCode == kDockerNotModified ? 200 : e.statusCode;
  }
}

/// What [step] changes once it succeeds, for the watched lists to read
/// again: the container its path addresses (`/containers/<id>/...`),
/// every container after a container prune, the images after an image
/// removal or prune, and the volumes or networks after one's create,
/// removal or prune.
({String? container, bool containers, bool images, bool volumes, bool networks})
apiStepChanges(ApiStep step) {
  final segments = Uri(path: step.path).pathSegments;
  final prune = segments.isNotEmpty && segments.last == 'prune';
  final at = segments.indexOf('containers');
  if (!prune && at >= 0 && at + 1 < segments.length) {
    return (
      container: segments[at + 1],
      containers: false,
      images: false,
      volumes: false,
      networks: false,
    );
  }
  return (
    container: null,
    containers: at >= 0,
    images: segments.contains('images'),
    volumes: segments.contains('volumes'),
    networks: segments.contains('networks'),
  );
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
      DockerTargetKind.volume => volumeFingerprint(
        await client.inspectVolume(check.target),
      ),
      DockerTargetKind.network => (await client.inspectNetwork(
        check.target,
      )).id,
      // A target no prune names reads as null, which no fingerprint
      // equals, so the step is refused.
      DockerTargetKind.prune => switch (_pruneOf(check.target)) {
        null => null,
        (final kind, final all) => pruneFingerprint(
          await prunePreview(client, kind, all: all),
        ),
      },
    };
    return id == check.id ? null : RevalidationFailure.targetChanged;
  } on DockerNotFoundException {
    return check.id == kAbsentTarget ? null : RevalidationFailure.targetChanged;
  } on DockerApiException {
    return RevalidationFailure.unreadable;
  }
}

/// The prune kind and `all` flag [target] ([pruneTarget]) names, or null
/// for none.
(DockerPruneKind, bool)? _pruneOf(String target) {
  for (final kind in DockerPruneKind.values) {
    for (final all in const [false, true]) {
      if (pruneTarget(kind, all: all) == target) return (kind, all);
    }
  }
  return null;
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

/// Over the sudo relay (rank 3, E16) every API step reaches the engine as
/// root through an elevated relay, which exists only in admin mode.
bool _overRelay(DockerPlanContext c) => c.route.rank == DockerRank.sudoRelay;

RequiredLevel _level(DockerPlanContext c) =>
    _overRelay(c) ? RequiredLevel.admin : RequiredLevel.login;

RunnerFacts _runner(DockerPlanContext c) => RunnerFacts(
  identity: _overRelay(c) ? 'root' : c.loginUser,
  engine: '${c.route.runtime.name} ${c.route.socketPath}',
  credentials: _overRelay(c)
      ? RunnerCredentials.adminPassword
      : RunnerCredentials.session,
);

PlanAttempt _planned(OperationPlan plan) => (plan: plan, refusal: null);

PlanAttempt _refused(ActionRefusalReason reason) =>
    (plan: null, refusal: reason);
