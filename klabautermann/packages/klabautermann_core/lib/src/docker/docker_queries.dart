part of 'docker_router.dart';

/// What a query read, and whether its connection dropped, so the
/// session resolves the endpoint again.
typedef _Read = ({
  DockerPayload payload,
  List<String> warnings,
  bool routeDropped,
});

Future<_Read> _read(
  DockerRouter router,
  _Endpoint endpoint,
  DockerQuerySpec spec,
) async {
  final client = endpoint.client;
  _Read read(DockerPayload payload, List<String> warnings) =>
      (payload: payload, warnings: warnings, routeDropped: false);

  try {
    switch (spec) {
      case DockerEngineQuery():
        final info = await client.engineInfo();
        return read(
          DockerEnginePayload(info.value, endpoint.version),
          info.warnings,
        );
      case DockerContainerQuery(:final containerId):
        final inspect = await client.inspectContainer(containerId);
        return read(
          DockerContainerPayload(maskContainerInspect(inspect.value)),
          inspect.warnings,
        );
      case DockerContainerTopQuery(:final containerId):
        final top = await _containerTop(client, containerId);
        return read(maskContainerTop(top.value), top.warnings);
      case DockerImageHistoryQuery(:final image):
        final history = await client.imageHistory(image);
        return read(
          DockerImageHistoryPayload(maskImageHistory(history.value)),
          history.warnings,
        );
      case DockerImageUpdatesQuery(:final refresh, :final runner):
        return read(
          await checkImageUpdates(
            client: client,
            run: endpoint.hostRun,
            cache: endpoint.imageUpdates,
            now: router._now(),
            refresh: refresh,
            runner: runner,
          ),
          const [],
        );
      case DockerComposeQuery():
        return read(switch (await endpoint.stacks.detectCli()) {
          final cli? => DockerComposePayload(cli),
          null => const DockerQueryFailed(
            DockerQueryFailure.connectionFailed,
            detail: 'the compose CLI check failed',
          ),
        }, const []);
      case DockerSystemDfQuery():
        // Bounded by the client's request timeout, as every buffered
        // read is: on a relay it holds the one pooled connection.
        final df = await client.systemDf();
        return read(DockerSystemDfPayload(df.value), df.warnings);
      case DockerReviewQuery():
        final (payload, warnings) = await _review(client);
        return read(payload, warnings);
      case DockerStackFileQuery(:final project, :final path):
        return read(
          await endpoint.stacks.readFile(client, project, path),
          const [],
        );
      case DockerStackProfilesQuery(:final project):
        return read(await endpoint.stacks.profiles(client, project), const []);
      case DockerStackScanQuery(:final directories):
        return read(await endpoint.stacks.scan(directories), const []);
    }
  } on DockerException catch (e) {
    final (:failure, :dropped) = dockerReadFailure(e);
    return (
      payload: failure,
      warnings: const <String>[],
      routeDropped: dropped,
    );
  } on Object catch (e) {
    // Nothing else is meant to leave a read, but what it parses comes
    // from the host and its registries. [_run] is not awaited, so an
    // error here would be unhandled in the engine isolate and end it
    // for every server. Only the type is named: the message could
    // repeat host output that was never masked.
    return (
      payload: DockerQueryFailed(
        DockerQueryFailure.connectionFailed,
        detail: 'the read ended with an unexpected error (${e.runtimeType})',
      ),
      warnings: const <String>[],
      routeDropped: false,
    );
  }
}

/// DKE-06 and DKE-07 over every container, up to [kDockerReviewMax],
/// one inspect at a time: on a relay each holds the one pooled
/// connection. A container removed before its inspect is left out; one
/// whose inspect the daemon refuses is counted.
Future<(DockerReviewPayload, List<String>)> _review(DockerClient client) async {
  final info = await client.engineInfo();
  final list = await client.listContainers();
  final userMapped =
      info.value.rootless ||
      info.value.securityOptions.any(
        (option) => option.replaceAll(' ', '').startsWith('name=userns'),
      );
  final warnings = [...info.warnings, ...list.warnings];
  final reviews = <ContainerReview>[];
  var unreadable = 0;
  for (final summary in list.value.take(kDockerReviewMax)) {
    final DockerParseResult<ContainerInspect> inspect;
    try {
      inspect = await client.inspectContainer(summary.id);
    } on DockerNotFoundException {
      continue;
    } on DockerApiException {
      // The daemon refused this one container (a 500 for one stuck in
      // its runtime); the rest still read. A transport failure ends
      // the review as any read's does.
      unreadable++;
      continue;
    }
    warnings.addAll(inspect.warnings);
    reviews.add(
      ContainerReview(
        containerId: summary.id,
        name: summary.name ?? inspect.value.name ?? summary.id,
        state: summary.state,
        project: ComposeLabels.fromContainerLabels(summary.labels)?.project,
        findings: reviewContainer(
          summary,
          inspect.value,
          userMapped: userMapped,
        ),
      ),
    );
  }
  return (
    DockerReviewPayload(
      reviews,
      omitted: (list.value.length - kDockerReviewMax).clamp(
        0,
        list.value.length,
      ),
      unreadable: unreadable,
      tools: [
        for (final summary in list.value)
          if (hostToolOf(summary) case final tool?)
            HostToolContainer(
              tool: tool,
              containerId: summary.id,
              name: summary.name ?? summary.id,
              state: summary.state,
              ports: [
                for (final port in summary.ports)
                  if (port.publicPort != null) port.label,
              ],
            ),
      ],
    ),
    warnings,
  );
}

/// [containerId]'s processes with CTR-10's columns, or with the
/// daemon's default `ps -ef` where `ps` rejects those columns, as a
/// minimal `ps` (BusyBox's) or a Windows daemon, which takes no
/// arguments, does. Either answers 500, so any 500 costs one more
/// request; the container's own state (404, 409) needs no retry.
Future<DockerParseResult<ContainerTop>> _containerTop(
  DockerClient client,
  String containerId,
) async {
  try {
    return await client.containerTop(containerId, psArgs: kContainerTopPsArgs);
  } on DockerServerException {
    return client.containerTop(containerId);
  }
}

/// Whether [spec] names what it reads in a form the engine takes.
bool _valid(DockerQuerySpec spec) => switch (spec) {
  DockerContainerQuery(:final containerId) => containerId.isNotEmpty,
  DockerContainerTopQuery(:final containerId) => containerId.isNotEmpty,
  DockerImageHistoryQuery(:final image) => image.isNotEmpty,
  DockerStackFileQuery(:final project, :final path) =>
    composeNamePattern.hasMatch(project) && _absolute(path),
  DockerStackProfilesQuery(:final project) => composeNamePattern.hasMatch(
    project,
  ),
  DockerStackScanQuery(:final directories) =>
    directories.isNotEmpty &&
        directories.length <= kStackScanDirectoriesMax &&
        directories.every(_absolute),
  _ => true,
};

bool _absolute(String path) {
  try {
    validateAbsolutePath(path);
    return true;
  } on ArgumentError {
    return false;
  }
}
